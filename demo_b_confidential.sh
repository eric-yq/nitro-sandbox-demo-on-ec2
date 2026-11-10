#!/bin/bash
# Demo B：Confidential 模式 + KMS attestation
#
# ⚠ 现状：setup / run / negative 需要一个「预先构建好、且带 sandbox 能力标志」的 EIF。
#   目前没有公开工具能产出这种 EIF：nitro-cli build-enclave 产出的是传统 Nitro Enclaves
#   的 EIF，缺少 sandbox 能力标志，会在 InstanceStart 失败（见 docs/nitro-sandboxes/
#   features.md）。而让 Firecracker 自动组装 EIF 的那条路不报告 PCR，无法 attestation。
#   所以这三个子命令现在跑不通，代码按正确设计保留，等有了 EIF 构建手段即可用。
#   不依赖 attestation 的那部分验证（内存隔离）见 demo_b_memtest.sh，那个现在就能跑。
#
# 用法：
#   EIF=/opt/sb/secure.eif PCR0=<hex> PCR2=<hex> [REGION=...] bash demo_b_confidential.sh setup
#   EIF=... bash demo_b_confidential.sh run        # 正向：解密成功
#   EIF=... bash demo_b_confidential.sh negative   # 反向：不带 attestation / debug_mode / entropy / 能力标志不一致
#   bash demo_b_confidential.sh cleanup
#
# EIF 要求：
#   - 内核带 DMB 补丁 + CONFIG_NSM=y（宿主机的 AL2023 kernel6.18 两者都满足）
#   - initrd 里包含 /opt/secure_runner.py 和 kmstool_enclave_cli（后者要从
#     aws-nitro-enclaves-sdk-c 源码编译）
#   - 能力标志必须和下面 enclave 配置推导出来的完全一致（这里只用 cpu_overcommit）
# IAM：实例角色需要 kms:CreateKey / Encrypt / PutKeyPolicy / ScheduleKeyDeletion
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ACT=${1:-run}

# 默认从 IMDS 取本实例所在区域，不要写死（KMS key 必须和实例同区）
if [ -z "${REGION:-}" ]; then
  _T=$(curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token \
       -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
  REGION=$(curl -s -m 3 -H "X-aws-ec2-metadata-token: $_T" \
           http://169.254.169.254/latest/meta-data/placement/region || true)
  REGION=${REGION:-us-east-1}
fi

W=/run/sb/conf; ST=/opt/sb/demo_b.env
PROXY_PID=$W/proxy.pid
PROXY_PORT=${PROXY_PORT:-8000}
mkdir -p $W

need_eif() {
  : "${EIF:?需要 EIF=预先构建的 .eif 路径}"
  [ -f "$EIF" ] || { echo "EIF 文件不存在：$EIF" >&2; exit 1; }
  # EIF 头部魔数是 ASCII ".eif"（aws-nitro-enclaves-image-format 的 EIF_MAGIC）
  if [ "$(head -c 4 "$EIF")" != ".eif" ]; then
    echo "错误：$EIF 不是 EIF 文件（头 4 字节不是 .eif）" >&2
    echo "      Firecracker 也接受普通内核镜像并自动组装 EIF，但那样不报告 PCR，" >&2
    echo "      attestation 条件永远匹配不上，所以这里必须用预先构建的 .eif。" >&2
    exit 1
  fi
}

# 按 cmdline 精确匹配本 demo 的 firecracker 进程再杀。
# 不用 pkill -f：如果调用方的命令行里本身含有同样的字符串，pkill 会把调用方自己杀掉。
stop_sandbox() {
  if [ -f $W/fc.pid ]; then kill "$(cat $W/fc.pid)" 2>/dev/null || true; rm -f $W/fc.pid; fi
  for p in $(pgrep -x firecracker 2>/dev/null || true); do
    if tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q "$W/api.sock"; then
      kill $p 2>/dev/null || true
    fi
  done
  sleep 1
}

launch() {   # $1 = enclave 配置 JSON；$2 = 额外设备 JSON 片段（可选）
  stop_sandbox
  # 只删这两个确定的名字。不要用 $W/v.sock* 通配：guest 发起的连接走
  # v.sock_<port>，那个是 KMS 代理在监听的，删掉代理就断了。
  # api.sock 必须删，Firecracker 不复用已存在的 socket 文件，残留会直接导致
  # "Failed to open the API socket ... Check that it is not already used."
  rm -f $W/api.sock $W/v.sock
  cat > $W/vm.json <<EOF
{
  "boot-source":   { "kernel_image_path": "$EIF" },
  "machine-config":{ "vcpu_count": 2, "mem_size_mib": 2048 },
  "vsock":  { "guest_cid": 200, "uds_path": "$W/v.sock", "dmb_size_mib": 4 }${2:-},
  "enclave": $1
}
EOF
  firecracker --api-sock $W/api.sock --config-file $W/vm.json > $W/fc.log 2>&1 &
  echo $! > $W/fc.pid
}

# guest 里的 kmstool 用 --proxy-port 连宿主机，Firecracker 会把它转到
# $W/v.sock_<port>，所以这里必须有个监听该 UDS 的转发器。详见 kms_uds_proxy.py。
start_proxy() {
  if [ -f $PROXY_PID ] && kill -0 "$(cat $PROXY_PID)" 2>/dev/null; then return; fi
  nohup python3 "$HERE/kms_uds_proxy.py" "$W/v.sock" "$PROXY_PORT" \
        "kms.$REGION.amazonaws.com" 443 > $W/proxy.log 2>&1 &
  echo $! > $PROXY_PID
  sleep 1
  kill -0 "$(cat $PROXY_PID)" 2>/dev/null \
    || { echo "KMS 代理启动失败："; cat $W/proxy.log; exit 1; }
  echo "KMS 代理：$W/v.sock_$PROXY_PORT -> kms.$REGION.amazonaws.com:443"
}

stop_proxy() {
  if [ -f $PROXY_PID ]; then kill "$(cat $PROXY_PID)" 2>/dev/null || true; rm -f $PROXY_PID; fi
  rm -f "$W/v.sock_$PROXY_PORT"
}

send_req() {  # 从 IMDS 取临时凭证，通过 vsock 发给 guest，打印 guest 返回的结果
  [ -f /opt/sb/secret.b64 ] || { echo "缺少 /opt/sb/secret.b64，先跑 setup" >&2; exit 1; }
  TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  ROLE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/)
  [ -n "$ROLE" ] || { echo "IMDS 里没有实例角色，Demo B 需要一个带 KMS 权限的角色" >&2; exit 1; }
  CRED=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE)
  python3 - "$W/v.sock" "$CRED" "$REGION" "$(cat /opt/sb/secret.b64)" <<'PY'
import socket, sys, json, time, struct
sock, cred, region, ct = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3], sys.argv[4]
u = None
for _ in range(1200):
    try:
        s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
        s.sendall(b"CONNECT 5001\n")
        if s.recv(64).startswith(b"OK"): u = s; break
        s.close()
    except OSError: pass
    time.sleep(0.05)
if u is None:
    print(json.dumps({"ok": False, "err": "vsock not ready (sandbox 未启动或启动失败，查看 fc.log)"})); sys.exit()

def recv_exact(u, n):
    b = b""
    while len(b) < n:
        d = u.recv(n - len(b))
        if not d: return None
        b += d
    return b

# 4 字节大端长度前缀分帧；不能用 shutdown(SHUT_WR)，Firecracker 读到宿主机侧 EOF 后会给
# guest 发一个同时带 SHUTDOWN_RCV+SHUTDOWN_SEND 的 vsock shutdown，应答就发不回来了
req = json.dumps({"region": region, "ak": cred["AccessKeyId"], "sk": cred["SecretAccessKey"],
                  "tk": cred["Token"], "ct": ct}).encode()
u.sendall(struct.pack("!I", len(req)) + req)
hdr = recv_exact(u, 4)
if hdr is None:
    print(json.dumps({"ok": False, "err": "guest 未返回长度头（查看 fc.log）"})); sys.exit()
body = recv_exact(u, struct.unpack("!I", hdr)[0])
if body is None:
    print(json.dumps({"ok": False, "err": "guest 应答不完整"})); sys.exit()
print(body.decode())
PY
}

case $ACT in
setup)
  need_eif
  : "${PCR0:?需要 PCR0}" "${PCR2:?需要 PCR2}"
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  ROLE_ARN=$(aws sts get-caller-identity --query Arn --output text | sed -E 's#:sts::([0-9]+):assumed-role/([^/]+)/.*#:iam::\1:role/\2#')
  KEY_ID=$(aws kms create-key --region $REGION --description nitro-sandbox-demo --query KeyMetadata.KeyId --output text)
  # 最后那条 Deny 是必须的：Admin 语句把 kms:* 授给了账号 root 主体，这在 KMS 里等于
  # 「允许 IAM 身份策略生效」。如果实例角色的 IAM 策略里有 kms:Decrypt，它就能绕过
  # attestation 条件直接解密，反向1 会"失败"而其实是策略写漏了。显式 Deny 优先级
  # 高于任何 Allow，把「请求里没有 attestation」的解密一律挡掉，反向1 才是确定性的。
  cat > /opt/sb/key-policy.json <<EOF
{ "Version": "2012-10-17", "Statement": [
  { "Sid": "Admin", "Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::$ACCOUNT:root"},
    "Action": "kms:*", "Resource": "*" },
  { "Sid": "EncryptFromParent", "Effect": "Allow", "Principal": {"AWS": "$ROLE_ARN"},
    "Action": "kms:Encrypt", "Resource": "*" },
  { "Sid": "DecryptOnlyFromAttestedSandbox", "Effect": "Allow", "Principal": {"AWS": "$ROLE_ARN"},
    "Action": "kms:Decrypt", "Resource": "*",
    "Condition": { "StringEqualsIgnoreCase": {
      "kms:RecipientAttestation:ImageSha384": "$PCR0",
      "kms:RecipientAttestation:PCR2": "$PCR2" } } },
  { "Sid": "DenyDecryptWithoutAttestation", "Effect": "Deny", "Principal": "*",
    "Action": "kms:Decrypt", "Resource": "*",
    "Condition": { "Null": { "kms:RecipientAttestation:ImageSha384": "true" } } } ] }
EOF
  aws kms put-key-policy --region $REGION --key-id $KEY_ID --policy-name default --policy file:///opt/sb/key-policy.json
  SECRET=$(mktemp); echo -n "sk-demo-$(openssl rand -hex 8)" > "$SECRET"
  aws kms encrypt --region $REGION --key-id $KEY_ID --plaintext "fileb://$SECRET" \
    --query CiphertextBlob --output text > /opt/sb/secret.b64
  echo "明文 secret 长度: $(wc -c < "$SECRET")"; shred -u "$SECRET"
  printf 'EIF=%s\nKEY_ID=%s\nREGION=%s\n' "$EIF" "$KEY_ID" "$REGION" > $ST
  echo "setup 完成：KEY_ID=$KEY_ID REGION=$REGION"
  ;;

run)
  source $ST; need_eif
  echo "== [正向] Confidential 模式启动 + 解密 =="
  launch '{ "cpu_overcommit": true }'
  start_proxy
  send_req
  echo "期望：nsm=true ok=true secret_len>0；去 CloudTrail 查 Decrypt 事件，应带 recipient 信息"
  ;;

negative)
  source $ST; need_eif

  echo "== [反向1] 在父实例上直接解密（请求不带 attestation）=="
  # aws cli 的 fileb:// 需要可 seek 的真实文件，不能用 <(...) 进程替换（那是管道）
  CT=$(mktemp); base64 -d /opt/sb/secret.b64 > "$CT"
  if aws kms decrypt --region $REGION --ciphertext-blob "fileb://$CT" \
       --query Plaintext --output text >/dev/null 2>&1; then
    echo "!! 解密成功（不符合预期：检查 key policy 里的 DenyDecryptWithoutAttestation）"
  else
    echo "AccessDenied（符合预期）"
  fi
  rm -f "$CT"

  echo "== [反向2] 加上 debug_mode：PCR 会被清零 =="
  launch '{ "cpu_overcommit": true, "debug_mode": true }'
  start_proxy; send_req; echo "期望：ok=false"

  echo "== [反向3] 加上 entropy 设备（Confidential 模式不允许 virtio-rng）=="
  launch '{ "cpu_overcommit": true }' ', "entropy": {}'
  sleep 3
  if grep -q 'NE_ERR_DEVICE_DISALLOWED' $W/fc.log; then
    echo "启动被拒：NE_ERR_DEVICE_DISALLOWED（符合预期）"
  else
    tail -3 $W/fc.log
  fi

  echo "== [反向4] 配置和 EIF 能力标志不一致（多开 hotplug_mode）=="
  launch '{ "cpu_overcommit": true, "hotplug_mode": true }'
  sleep 3; tail -3 $W/fc.log; echo "期望：InstanceStart 失败"

  stop_sandbox; stop_proxy
  echo
  echo "注：「父实例能否读到 sandbox 内存」的验证不在这里，见 demo_b_memtest.sh。"
  echo "    原先用 gcore dump Firecracker 进程再搜明文的测法是错的：guest 内存是"
  echo "    /dev/nitro_enclaves 的 file-backed shared 映射，而默认 coredump_filter=0x33"
  echo "    不包含该类映射，gcore 会整段跳过 —— 实测 Direct 模式的对照组也搜不到明文，"
  echo "    也就是说不管隔离有没有生效都会报通过，属于假通过，已移除。"
  ;;

cleanup)
  [ -f $ST ] && source $ST || true
  stop_sandbox; stop_proxy
  if [ -n "${KEY_ID:-}" ]; then
    aws kms schedule-key-deletion --region $REGION --key-id $KEY_ID \
      --pending-window-in-days 7 --query KeyState --output text || true
  fi
  rm -rf $W $ST /opt/sb/secret.b64 /opt/sb/key-policy.json
  echo "已清理：sandbox / KMS 代理 / 中间文件（KMS key 排 7 天后删除）"
  ;;

*)
  echo "用法：bash $0 {setup|run|negative|cleanup}" >&2; exit 1
  ;;
esac
