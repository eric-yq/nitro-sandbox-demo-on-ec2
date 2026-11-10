# 脚本解读

这一份是 `nitro_sandbox_demo/` 里每个文件的逐个解读：它负责什么、关键代码为什么这么写、
以及踩过的坑。环境要求和 step-by-step 操作步骤在 [README.md](README.md)。

基于 Firecracker **v1.18.0**（Nitro Sandbox 支持是 v1.18.0 由 [#6393](https://github.com/firecracker-microvm/firecracker/pull/6393) 引入的）。
实测环境：EC2 Graviton（aarch64）+ AL2023 kernel `6.18.56-126.188.amzn2023.aarch64`。

---

## 0. 先理解两个概念

**Nitro Sandbox 不是 KVM。** Firecracker 平时通过 `/dev/kvm` 建虚机，Nitro Sandbox 模式下它改为
驱动 Nitro Enclaves 驱动 `/dev/nitro_enclaves`，由 Nitro Hypervisor 从父实例里切出一台隔离虚机。
API、jailer、virtio 设备模型都保持原样，新增一个 `PUT /enclave` 配置端点。
代码和报错里一律把 sandbox 叫 "enclave"（和 AWS Nitro Enclaves 产品不是一回事）。

**两种内存模式，决定了整个 Demo 的分界：**

| | Direct 模式（Demo A） | Confidential 模式（Demo B） |
|---|---|---|
| 父实例能否读 sandbox 内存 | 能（读写） | 不能 |
| attestation | 无 | 有（NSM / PCR） |
| guest 是否需要 DMB virtio 驱动 | 不需要 | 需要 |
| entropy 设备 | 允许 | 被 Nitro 拒绝（`NE_ERR_DEVICE_DISALLOWED`） |
| 启动镜像 | 普通 kernel + ext4 rootfs | 预先构建的 EIF |

所以 Demo A 用 `00_build_guest.sh` 产出的 kernel+rootfs，Demo B 必须自己准备 EIF —— 两者
**不共用启动镜像**。

---

## 1. 文件关系与执行顺序

```
nitro_sandbox_parent_setup.sh   宿主机一次性准备（stage1 -> 重启 -> stage2）
        │   stage1: 查内核/驱动, 设 nitro_enclaves.mempool（需重启）
        │   stage2: 设 pcie_slots 预算, 装 firecracker v1.18.0
        ▼
00_build_guest.sh               产出 /opt/sb/kernel.img + /opt/sb/rootfs.ext4
        │   把 guest/ 下的 runner.py / sb-net* / sb-runner.service 烤进 rootfs
        ▼
demo_a_direct.sh                Demo A 外层：资源预检 + 宿主机网络(tap/nft) + 收尾清理
        │
        ├─> demo_a_pool.py      编排器：并发拉 N 个沙箱, 下发代码, 汇总, 销毁
        │        │
        │        └─ vsock ─────> guest/runner.py （沙箱内, 端口 5000）
        │                              │
        │                              └─ 执行 ─> evil.py（下发进去的被测代码）
        ▼
demo_b_memtest.sh               Confidential vs Direct 的内存隔离 A/B 验证（现在就能跑）

demo_b_confidential.sh          Demo B：需要预先构建好的 EIF（setup/run/negative 暂不可跑）
         ├─ vsock 5001 ───────> guest/secure_runner.py（沙箱内）
         └─ kms_uds_proxy.py    监听 v.sock_8000，把 guest 发起的连接转发到 KMS:443
                     <───────── guest 里的 kmstool 通过 --proxy-port 8000 连出来
```

关键依赖：`demo_a_pool.py` 里写死了 `/opt/sb/kernel.img`、`/opt/sb/rootfs.ext4` 和 `evil.py`
的路径；`guest/` 下的文件改了以后**必须重跑 `00_build_guest.sh`**，否则沙箱里跑的还是旧版本。

---

## 2. `nitro_sandbox_parent_setup.sh` — 宿主机准备

分两段，中间必须重启，因为改的是内核启动参数。

**stage1**
- 检查 `uname -r`（需 ≥ `6.18.51-120.162.amzn2023`，父实例侧支持是从这个版本进的）。
- 检查 `/dev/nitro_enclaves` 是否存在。不存在通常是实例没开 `--enclave-options Enabled=true`。
- `grubby --update-kernel=ALL --args="nitro_enclaves.mempool=48G"` 预留内存池。
  这块内存是**从父实例划走**给沙箱用的，划多少直接决定能并发多少沙箱。

**stage2**（重启后）
- 往 `/sys/class/misc/nitro_enclaves/pcie_slots` 写 slot 预算（默认 32，**必须是 8 的倍数**）。
  一个沙箱占一个 PCIe slot，所以这是并发上限的硬约束。
- 下载并安装 `firecracker-v1.18.0`。`FC_REL=v1.18.0` 这里是**对的**，别和下面
  `00_build_guest.sh` 的 CI 工件前缀搞混（见下一节的坑）。

读取资源现状的几个 sysfs 节点，排查问题时常用：

```
/sys/class/misc/nitro_enclaves/cpu_pool/{total,free}
/sys/class/misc/nitro_enclaves/mem_pool/free        # 单位是字节
/sys/class/misc/nitro_enclaves/{pcie_slots,pcie_slots_in_use,pcie_slots_total}
```

---

## 3. `00_build_guest.sh` — 造 guest 内核和 rootfs

产物固定放 `/opt/sb/`：`kernel.img`、`rootfs.ext4`、`sb.id_rsa{,.pub}`。

### 流程
1. 解析 CI 工件前缀 → 下载 guest 内核 → 下载 Ubuntu squashfs
2. `unsquashfs` 展开，注入 SSH 公钥和我们自己的 guest 程序
3. `truncate -s 1G` + `mkfs.ext4 -d squashfs-root` 打成 ext4 镜像
4. `e2fsck -fn` + `debugfs` 校验产物（确认文件系统正常、`/opt/runner.py` 真的在镜像里）

### 三个关键点

**(a) CI 工件前缀不能按 Firecracker 版本号拼。**
`spec.ccfc.min` 这个桶里带版本号的前缀 `firecracker-ci/v1.x/` **只发布到 v1.15 为止**；
v1.16 以后改用日期戳前缀 `firecracker-ci/YYYYMMDD-<hash>-N/`。所以脚本按官方 v1.18
`docs/getting-started.md` 的做法，自动取最新的日期戳构建：

```bash
PREFIX=${CI_PREFIX:-$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
  | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" | sort | tail -1)}
```

想固定某次构建就传 `CI_PREFIX=`。这一点很容易踩：原始脚本写的是 `CI_VERSION=v1.18`，
查出来 `KeyCount=0`，而且因为 `set -e` + `pipefail`，`grep` 无匹配返回 1 会让脚本**静默退出**，
连它自己准备的报错都打不出来。现在所有解析都加了 `|| true` 再显式检查。

**(b) 内核版本要 6.18 线。** `sort -V | tail -1` 选出来的是 `vmlinux-6.18.56`。
这不只是"越新越好"：对比过 `.config`，`CONFIG_VIRTIO_DMB_ZEROCOPY` 这个符号**只在 6.18
线存在**，6.1 线完全没有 —— 说明 DMB 补丁只打在 6.18 线上。Confidential 模式必须有 DMB。
脚本里有一段版本检查，选到非 6.18 线时会警告"只能跑 Direct 模式"。

**(c) 架构决定内核镜像格式，不能统一用 vmlinux。**

```bash
if [ "$ARCH" = "x86_64" ]; then KPFX=bzImage-; else KPFX=vmlinux-; fi
```

sandbox 走 **UEFI 引导**，内核必须是 EFI 可启动镜像：x86_64 必须用带 EFI stub 的 `bzImage`，
KVM microVM 常用的 `vmlinux` **启不了 sandbox**；aarch64 的 `vmlinux-` 工件本身就是 EFI 可启动
的 Image（`CONFIG_EFI_STUB=y` 默认开）。注意通用的 `docs/getting-started.md` 两个架构都用
`vmlinux-`，照搬会把 x86_64 弄坏 —— 要按 `docs/nitro-sandboxes/getting-started.md` 来。

实测产物可以这样验：`kernel.img` 偏移 0 是 `MZ`（PE 头，EFI stub 的标志），偏移 0x38 是
`ARM\x64`（arm64 Image magic）。

### 注入了什么

| 注入到 rootfs 的路径 | 来源 | 作用 |
|---|---|---|
| `/root/.ssh/authorized_keys` | `sb.id_rsa.pub` | 配了网卡时可以 ssh 进去调试 |
| `/opt/runner.py` | `guest/runner.py` | vsock 代码执行器 |
| `/opt/secure_runner.py` | `guest/secure_runner.py` | Demo B 用（实际 Demo B 走 EIF，这里基本是摆设） |
| `/etc/systemd/system/sb-runner.service` | 同名 | 开机起执行器 |
| `/etc/systemd/system/sb-net.service` | 同名 | 开机补默认路由 |
| `/usr/local/bin/sb-net-setup.sh` | 同名 | 上面那个单元调用的脚本 |

两个 service 都通过 `multi-user.target.wants/` 软链接启用（离线改镜像没法跑
`systemctl enable`，只能手动建链接）。

---

## 4. `demo_a_direct.sh` — Demo A 外层

职责是**宿主机侧的准备和收尾**，真正的编排交给 `demo_a_pool.py`。

### 资源预检
```bash
NEED_MIB=$(( N * (MEM + 2) ))     # 每个沙箱 MEM 再加 2 MiB 开销
```
slot 不够会自动把 `pcie_slots` 往上调到 8 的倍数；内存池不够直接退出并提示调小 N/MEM
或加大 `nitro_enclaves.mempool` 后重启。

### 网络模型

每个沙箱一条 `/30`：

| | 地址 |
|---|---|
| 宿主机 tap `sbtap<i>` | `172.16.<i>.1/30` |
| guest `eth0` | `172.16.<i>.2/30` |
| guest 默认网关 | `172.16.<i>.1` |

`/30` 刚好 4 个地址（网络号、.1、.2、广播），是放两个端点的最小子网，这也是 Firecracker
官方文档和集成测试的习惯做法。

`GUEST_NET=172.16.0.0/16` 是给 nft 规则用的汇总网段。**注意不能写成 `172.16.0.0/12`** ——
那会覆盖到 `172.31.x.x`，把宿主机自己的地址也包进去，masquerade 规则就会误伤宿主机流量。

nft 部分建在**独立的表** `firecracker` 里：

```bash
nft add table ip firecracker
nft "add chain ip firecracker postrouting { type nat hook postrouting priority srcnat; policy accept; }"
nft "add chain ip firecracker forward    { type filter hook forward priority filter; policy accept; }"
nft add rule ip firecracker forward     ip saddr $GUEST_NET ip daddr 169.254.0.0/16 counter drop   # 必须在 accept 之前
nft add rule ip firecracker forward     ip saddr $GUEST_NET oifname "$UPLINK" counter accept
nft add rule ip firecracker postrouting ip saddr $GUEST_NET oifname "$UPLINK" counter masquerade
```

用独立表的好处是清理时 `nft delete table ip firecracker` 整表删掉，**绝不碰宿主机已有规则**。
规则里都带 `counter`，跑完能直接看命中计数，这是"IMDS 确实被拦住了"的硬证据。

### 为什么要故意让沙箱能上网

这是这个 Demo 最容易做成"假验证"的地方。如果沙箱压根没网卡，`imds_reachable=False`
是必然的，什么都证明不了。所以这里反过来做：

1. 配 NAT，让沙箱有**真实出网能力** → `egress_ok=True` 证明数据通路是好的
2. 再单独 drop 掉 `169.254.0.0/16` → 此时的 `imds_reachable=False` 才是"被拦住"

`LEAK_IMDS=1` 会跳过那条 drop 规则，用来证明这项检查有判别力。实测结论：

- 默认（有 drop）：`imds_reachable: False`，drop 规则计数 9 包 540 字节
- `LEAK_IMDS=1`：`imds_reachable: True`，而且沙箱里能**完整取到父实例 IAM 角色的临时凭证**
  （IMDSv2 token 200 OK → 角色名 → 1574 字节凭证文档，含 `SecretAccessKey` 和 `Token`）

IMDS 的 hop limit 并没有挡住，因为宿主机 NAT 转发后 PUT token 照样返回 200。
**所以那条 drop 规则不是可选项。** 拦的是整个 `169.254.0.0/16` 而不只是 `169.254.169.254`，
因为链路本地段里还有别的东西（比如 `169.254.169.253` 是 VPC DNS）。

### 清理

三处容易出问题，都处理了：

- `trap ... EXIT`：`KEEP=1` 时**不拆网络**（否则留下来的沙箱会断网），改为提示用 cleanup 子命令。
- `bash demo_a_direct.sh cleanup`：杀进程 + 删 tap + 删 nft 表 + 恢复 `ip_forward` + 删 `/run/sb`。
- `ip_forward` 原值落盘到 `/run/sb-ipfwd.saved`。cleanup 是**独立进程**启动的，
  如果它直接读当前值当"原值"，就会把我们自己改成的 1 存回去 —— 实测踩过，清理完
  `ip_forward` 还是 1。现在 `net_up` 时先落盘，cleanup 从文件读，文件不存在则回落到 0。
- `net_down` 里删 tap 的循环写的是 `seq 0 255` 而不是 `seq 0 $((N-1))`，这样上一次用更大的 N
  跑剩下的 tap 也能被清掉。

---

## 5. `demo_a_pool.py` — 编排器

### `cfg(i)` 生成每个沙箱的 vm.json

```python
"vsock": {"guest_cid": 100 + i, "uds_path": f"{BASE}/{i}/v.sock"},
"network-interfaces": [{"iface_id": "eth0",
                        "guest_mac": f"06:00:ac:10:{i:02x}:02",
                        "host_dev_name": f"sbtap{i}"}],
"entropy": {},
"enclave": {"direct_mode": True, "cpu_overcommit": True, "cpu_accounting": True,
            "debug_mode": os.environ.get("DEBUG", "0") == "1"},
```

**MAC 是精心挑的，不是随便填的。** rootfs 自带 `/usr/local/bin/fcnet-setup.sh`，它按 MAC 推 IP：
取 `06:00:` 之后的 4 组十六进制，逐组转十进制拼成 IP，配成 `/30`。所以

```
06:00:ac:10:<i>:02  ->  0xac.0x10.0xi.0x02  ->  172.16.<i>.2/30
```

这样 guest 侧的 IP 配置**完全不用我们管**，直接复用镜像自带的机制。这也是 Firecracker
集成测试的套路。`{i:02x}` 保证十六进制两位，`N` 上限 250 就是受这一段限制。

`enclave` 字段说明：`direct_mode` 选内存模式；`cpu_overcommit` 让沙箱 vCPU 和父实例超卖；
`cpu_accounting` 开启 CPU 计费统计；`debug_mode` 打开后 guest 串口输出会进 `fc.log`
（Demo B 里要注意：debug_mode 会把 PCR 清零，attestation 就过不了）。
`entropy` 只在 Direct 模式允许。

### `launch(i)`
```python
subprocess.run(["cp", "--reflink=auto", f"{SB}/rootfs.ext4", f"{d}/rootfs.ext4"], check=True)
```
每个沙箱一份**独立的 rootfs 副本**，这样沙箱里的破坏只影响自己那份（`evil.py` 的
`peer_disk_visible` 就是在验证看不到邻居的盘）。`--reflink=auto` 在支持 CoW 的文件系统上
走写时复制，省时间省空间；不支持就退化成普通拷贝。

### `connect(i)` — vsock 握手

Firecracker 的 host→guest vsock 是通过 Unix socket 多路复用的，协议是文本握手：

```
host: connect() 到 uds_path
host: send "CONNECT 5000\n"
host: recv "OK <分配的宿主机侧端口>\n"      # 比如 OK 1073741840
```

guest 侧没人 listen 的话 Firecracker 会直接断开连接，所以这里是 50ms 一次的重试循环，
一直等到 guest 里的 `runner.py` 起来（实测约 2 秒）。

### `run(v)` — ⚠️ 这里有个必须避开的坑

**Firecracker 的 vsock 不支持半关闭。** 原始实现是"发完代码 `shutdown(SHUT_WR)` 表示结束，
然后读到 EOF 为止"，这个模式在 Firecracker 上**永远不可能成功**。看
`src/vmm/src/devices/virtio/vsock/csm/connection.rs`：

```rust
if read_cnt == 0 {
    // A 0-length read means the host stream was closed down. In that case,
    // we'll ask our peer to shut down the connection. We can neither send nor
    // receive any more data.
    self.state = ConnState::LocalClosed;
    pkt.hdr.set_op(uapi::VSOCK_OP_SHUTDOWN)
        .set_flag(uapi::VSOCK_FLAGS_SHUTDOWN_RCV)
        .set_flag(uapi::VSOCK_FLAGS_SHUTDOWN_SEND);
}
```

宿主机侧一旦 `SHUT_WR`，Firecracker 读到 0 字节，就给 guest 发一个**同时带 RCV 和 SEND
两个标志**的双向 shutdown，还启动 kill timer。guest 虽然拿到了它要的 EOF，但回传方向
在同一瞬间被拆掉，应答根本发不回来。表现是 `json.loads(b"")` 报
`Expecting value: line 1 column 1 (char 0)`。

所以两个方向都改成 **4 字节大端长度前缀分帧**，谁都不需要靠关连接来划消息边界：

```python
code = EVIL.encode()
u.sendall(struct.pack("!I", len(code)) + code)
hdr  = recv_exact(u, 4)
body = recv_exact(u, struct.unpack("!I", hdr)[0])
```

`recv_exact()` 必须循环收满 n 字节 —— TCP/vsock 流式语义下一次 `recv` 不保证给够。

### `main()`
```python
with cf.ThreadPoolExecutor(N) as ex:
    vms = list(ex.map(launch, range(N)))   # 先全部拉起
    res = list(ex.map(run, vms))           # 再并发下发
```
先全部 launch 再全部 run，这样 `ready` 时间量的是"从拉起到可用"，N 个沙箱的启动是重叠的，
P50/max 才有意义。最后 `ps -eT | grep fc_vcpu` 展示 CPU 计费线程，
`KEEP=1` 时跳过销毁。

---

## 6. `evil.py` — 被下发进沙箱的被测代码

在沙箱里以 root 执行，输出被 `runner.py` 收集成 JSON 回传。每行 `key: value`，
外层按 `":" in l` 过滤后平铺打印。

| 检查项 | 期望 | 在测什么 |
|---|---|---|
| `host_creds_visible` | False | 看不到宿主机的 `/root/.aws/credentials` |
| `peer_disk_visible` | False | 看不到邻居沙箱的 `/run/sb/0/rootfs.ext4` |
| `nic` | `eth0 172.16.<i>.2/30` | 网卡确实配上了 |
| `gw_reachable` | True | ping 通网关 → 二层/三层链路正常 |
| `egress_ok` | True | TCP 到 `1.1.1.1:443` → NAT 出网正常 |
| `imds_reachable` | **False** | IMDS 被拦住 |

`tcp()` 刻意区分三种失败：

```python
except ConnectionRefusedError: return False, "refused(可达)"
except socket.timeout:         return False, "timeout"
except OSError as e:           return False, f"{e.__class__.__name__}"
```

因为"连接被拒"说明**对端可达只是端口没开**，和"超时/路由不可达"是完全不同的结论。
如果混成一个 False，就没法区分"被防火墙 drop"和"压根没路由"。
网关探测用 `ping`（镜像里有 `/usr/bin/ping`），不用 TCP，避免上面这个歧义。

> 前一版这里还有个 `os.system("rm -rf /usr/share/doc")`，本意是演示"破坏只影响自己那份
> rootfs"。但 CI 的 Ubuntu 是 minimized 镜像，`/usr/share/doc` 本来就不存在，这个动作既没
> 效果也没法验证，已经去掉。要演示破坏隔离的话得挑一个镜像里确实存在的目标。

---

## 7. `guest/runner.py` — 沙箱内的代码执行器

绑 `AF_VSOCK` 端口 5000，循环 accept。分帧协议和宿主机侧严格对称（4 字节大端长度前缀）。
收到的代码落到 `/tmp/task.py`（**`/tmp` 是 tmpfs**，所以事后从 ext4 镜像里是看不到这个文件的），
用 `python3` 子进程执行，20 秒超时，把 `rc/out/err` 打包成 JSON 回传，`out`/`err` 各截断 4000 字节。

```python
try:
    ...
except OSError:
    pass
finally:
    c.close()
```

单个连接出错不能让整个 listener 挂掉，否则这个沙箱就彻底失联了。

安全提示：它会执行收到的**任意代码**，没有任何鉴权 —— 这正是"沙箱"的用途，
但也意味着这个端口等于远程代码执行，只能用在隔离环境里。

---

## 8. `guest/sb-runner.service` / `sb-net.service` / `sb-net-setup.sh`

**`sb-net-setup.sh`** 补默认路由。rootfs 自带的 `fcnet-setup.sh` 只配 IP **不配路由**，
所以这一步必须自己做。`/30` 子网里对端（宿主机 tap）地址就是 guest IP 减 1：

```bash
gw=$(echo "$ip" | awk -F. '{printf "%s.%s.%s.%d", $1, $2, $3, $4 - 1}')
ip route replace default via "$gw" dev "$dev"
```

这样算的好处是**不用把地址硬编码进镜像** —— 同一个 rootfs 镜像可以给任意 `<i>` 的沙箱用。
用 `route replace` 而不是 `add`，重复执行不会报错。

**`sb-net.service`** 是 `Type=oneshot` + `RemainAfterExit=yes`，`After=fcnet.service`
（必须等 IP 配好）。

**`sb-runner.service`** 加了 `After=sb-net.service`，保证执行器**接活之前网络已经就绪**，
否则 `evil.py` 的网络检查会撞上竞态，偶发 `gw_reachable=False`。
用 `Wants=` 而不是 `Requires=`：网络配置失败也让执行器照常起来，这样至少能连进去看错误，
而不是整个沙箱失联。

---

## 9. Demo B 相关（部分实跑验证）

### 已经实跑验证过的部分

**Confidential 模式本身是通的。** 去掉 `direct_mode` 即为 Confidential 模式，用
`00_build_guest.sh` 产出的 CI 内核就能起来，DMB 协商成功：

```
Enclave VM created: ... direct_mode=false, cpu_overcommit=true, create_flags=0xa40
Allocated 16 MiB DMB for Block id=rootfs
Allocated 4 MiB DMB for Vsock id=vsock
EifLoader: NSM bound at 0000:00:02.0 (DID 0x1061)
[0.799] virtio_blk virtio1: Enabled 16777216-byte Virtio DMB (lockless bitmap, 4096 slots)
[0.814] vmw_vsock_virtio_transport virtio2: Enabled 4194304-byte Virtio DMB
VFS: Mounted root (ext4 filesystem) on device 254:0.
```

**内存隔离（Demo B 最核心的主张）已验证**，见 `demo_b_memtest.sh`：

| 模式 | 父实例侧结果 |
|---|---|
| Confidential | 进程里**根本没有** ≥64 MiB 的可读映射，guest RAM 没被映射进来 |
| Direct（对照组） | `/dev/nitro_enclaves` 的 512 MiB 映射，512 MiB 全部读成功，canary 命中 **8195 处** |

对照组能读到，才说明这个测法有判别力。

**两个反向用例已验证**，报错和文档完全一致：

```
Confidential + entropy  -> NE_ERR_DEVICE_DISALLOWED (errno=547): the requested device type is not permitted
Direct + dmb_size_mib   -> dmb_size_mib cannot be set in direct mode (no DMB is used)
```

**`/dev/nsm` 可以拿到。** CI 内核没开 `CONFIG_NSM`，但宿主机的 AL2023 内核
`6.18.56-126.188.amzn2023` 有 `CONFIG_NSM=m`，而且文档明确说这个内核可以直接当 guest
内核用（DMB 补丁也带）。它的 `virtio_pci`/`nsm` 都是模块，所以要配一个 initramfs：

```bash
dracut --no-hostonly --force \
  --add-drivers "virtio_pci virtio_blk virtio_net vmw_vsock_virtio_transport vsock nsm" \
  /opt/sb/sb-initrd.img $(uname -r)
```

然后 `kernel_image_path=/boot/vmlinuz-<ver>`、`initrd_path=/opt/sb/sb-initrd.img`，
`boot_args` 里加 `rd.driver.pre=virtio_pci,virtio_blk,vmw_vsock_virtio_transport,nsm`。
实测 guest 里 `/dev/nsm` 是字符设备 10:260，`/proc/misc` 里有 `260 nsm`。
（注意 `virtio_console` 在这个内核里不是模块，写进 `--add-drivers` 会让 dracut 整个失败，
而且失败后仍会留下一个不完整的 initramfs 文件，容易误以为成功。）

**vsock 通路已修通。** 修完分帧后端到端往返正常：

```json
{"nsm": true, "ok": false, "secret_len": 0,
 "err": "kmstool_enclave_cli not found in guest (需要 aws-nitro-enclaves-sdk-c)"}
```

### 还没打通的部分（卡在工具链，不是脚本 bug）

完整的 KMS attestation 解密流程跑不了，两个硬卡点：

1. **拿不到可用的 PCR。** [features.md](https://github.com/firecracker-microvm/firecracker/blob/firecracker-v1.18/docs/nitro-sandboxes/features.md)
   原话：*"Firecracker does not report the measurements of an EIF it builds."*
   也就是说让 Firecracker 自动组装 EIF（给它一个 kernel 路径）这条路，PCR 没法用来做
   attestation，KMS key policy 里 `kms:RecipientAttestation:ImageSha384` 这个条件
   就没有已知值可以匹配。必须自己预先构建 EIF 并用 `kernel_image_path` 指向 `.eif`。
   另外 `debug_mode: true` 会把 PCR 锁成全 0，所以调试用的那些跑法本身也没法 attest。

2. **没有现成工具能构建 sandbox 能用的 EIF。** 同一份文档：
   *"An EIF built for Nitro Enclaves lacks the sandbox capability flags, so it fails at
   `InstanceStart`."* EIF 头部要声明的能力标志必须和 Firecracker 从 enclave 配置推出来的
   完全一致（`cpu_overcommit` / `cpu_accounting` / `hotplug_mode` / 多节点 `numa_nodes`），
   而 `nitro-cli build-enclave` 产出的是给 Nitro Enclaves 用的，不带这些标志。
   原脚本注释里"未核实具体工具"是对的 —— 答案是 nitro-cli 不是那个工具。

3. 次要的：`kmstool_enclave_cli` 不在任何 rpm 包里，要从
   aws-nitro-enclaves-sdk-c 源码编（一串 aws-c-* 依赖），还得塞进 EIF 的 initrd。

所以 Demo B 的 `setup` / `run` 这两个子命令目前没法实跑。能跑的是上面那些不依赖
attestation 的部分，其中内存隔离是最有价值的一条。

### 修掉的 bug

**(0) `vsock-proxy` 根本收不到沙箱的连接 —— 这是个架构性错误。**

原脚本在 `setup` 里起 `aws-nitro-enclaves-cli` 的 `vsock-proxy 8000 kms...:443`，
让 guest 里的 kmstool 通过 `--proxy-port 8000` 访问 KMS。但 `vsock-proxy` 监听的是
**内核 AF_VSOCK**（适用于传统 Nitro Enclaves），而 Firecracker 的 virtio-vsock 后端是
**Unix socket**。[docs/vsock.md](https://github.com/firecracker-microvm/firecracker/blob/firecracker-v1.18/docs/vsock.md)
的 "Guest-Initiated Connections" 写得很明确：

> Connections initiated from within the guest will be forwarded to AF_UNIX sockets
> expected to be listening at `./v.sock_<port_num>`.

也就是 guest 连宿主机端口 8000 时，Firecracker 去找名为 `$W/v.sock_8000` 的
**AF_UNIX socket**，完全不碰 AF_VSOCK。所以 `vsock-proxy` 永远收不到连接，
guest 只会拿到 RST。

改法：新增 `kms_uds_proxy.py`，监听 `<uds_path>_<port>` 这个 Unix socket，
收到连接就开一条 TCP 到上游做字节级双向转发（kmstool 自己做 TLS，这层只透传）。
已实测：通过该代理和真实 KMS 端点完成了 TLS 1.3 握手（证书 CN =
`kms.us-east-2.amazonaws.com`），未签名请求返回 `HTTP/1.1 400`，证明确实打到了 KMS 服务。

**(0b) key policy 让反向1 变成不确定的。**

原 key policy 里 `Admin` 语句把 `kms:*` 授给账号 root 主体 —— 在 KMS 里这等于
「允许 IAM 身份策略生效」。如果实例角色的 IAM 策略里带 `kms:Decrypt`，它就能绕过
attestation 条件直接解密，反向1（期望 AccessDenied）会"失败"，而真实原因是策略写漏了。
原脚本的注释恰好说反了。

改法：加一条显式 `Deny`，把「请求里没有 attestation」的 Decrypt 一律挡掉。
显式 Deny 优先级高于任何 Allow，反向1 才是确定性的：

```json
{ "Sid": "DenyDecryptWithoutAttestation", "Effect": "Deny", "Principal": "*",
  "Action": "kms:Decrypt", "Resource": "*",
  "Condition": { "Null": { "kms:RecipientAttestation:ImageSha384": "true" } } }
```

**(0c) 其他已修**

- `fileb://<(base64 -d ...)`：AWS CLI 的 `fileb://` 需要可 seek 的真实文件，
  进程替换给的是管道。改成先落临时文件。
- `launch()` 不再用 `$W/v.sock*` 通配删除 —— 那会把 KMS 代理正在监听的
  `v.sock_8000` 一起删掉。现在只删 `api.sock` 和 `v.sock` 两个确定的名字。
- `stop_sandbox()` 改为遍历 `pgrep -x firecracker` 再比对 `/proc/<pid>/cmdline`，
  不用 `pkill -f`（见本节末尾那个自杀坑）。
- 加了 EIF 预检：校验头 4 字节是否为 `.eif`（`EIF_MAGIC`），
  避免有人拿普通内核镜像当 EIF 传进来，然后在"为什么 attestation 过不了"上浪费时间。

### 之前修掉的三个 bug

1. **同样的 vsock 半关闭问题**（和 Demo A 一模一样）。`send_req()` 里是
   `shutdown(SHUT_WR)` + 读到 EOF，`secure_runner.py` 里是读到 EOF，必然拿不到应答。
   两边都改成 4 字节大端长度前缀分帧。
2. **`REGION` 写死 `us-east-1`。** KMS key 必须和实例同区，写死会让 `setup` 在别的区
   建出一个用不了的 key。改成默认从 IMDS 取 `placement/region`，取不到才回落。
3. **`FileNotFoundError` 被吞掉。** 我第一版修复里 `except OSError: pass` 把
   `subprocess.run` 找不到 `kmstool_enclave_cli` 时抛的 `FileNotFoundError`
   （它是 `OSError` 的子类）一起吞了，连接直接关掉不回应答。父实例看到的就是
   "EOF 没应答"，完全没法区分是 guest 里没装 kmstool 还是 vsock 坏了。
   现在 kmstool 相关的异常全部转成应答里的 `err` 字段返回，外层 `except OSError`
   只兜 socket 层的错。

### 原脚本里 `negative` 反向5 的测法是错的

原来用 `gcore` dump Firecracker 进程再搜明文。实测这个测法会给出**假通过**：
guest 内存是 `/dev/nitro_enclaves` 的 file-backed shared 映射，而默认
`coredump_filter=0x33` 没开 file-backed 的位（bit 2/3），gcore 直接跳过这一段 ——
512 MiB 的 guest 只 dump 出 3 MB，**Direct 模式的对照组也是 0 命中**。
也就是说不管隔离有没有生效，这个测法都会报"没找到明文"。
正确做法是直接读 `/proc/<pid>/mem`（见 `demo_b_memtest.sh`），这也更贴近攻击者的实际做法。

**这条反向用例已经从 `demo_b_confidential.sh` 里删掉了**，因为一个永远会"通过"的
测试比没有测试更糟 —— 它会让人误以为隔离被验证过了。替代品是 `demo_b_memtest.sh`。

---

## 9b. `demo_b_memtest.sh` — 内存隔离 A/B 验证（新增）

不依赖 KMS / EIF / attestation，所以现在就能跑：

```bash
sudo bash demo_b_memtest.sh 512
```

做法：guest 里起一个常驻进程把 canary 字符串反复写进内存并持有，然后父实例解析
`/proc/<fc_pid>/maps`，对 ≥64 MiB 的可读映射逐块 `pread` 搜 canary。
Confidential 和 Direct 各跑一遍。跨块边界用 `len(canary)` 的重叠避免漏匹配。

---

## 9c. Demo B 原脚本其余部分

### `guest/secure_runner.py`
绑 vsock 端口 5001，从父实例收 `{region, ak, sk, tk, ct}`，调 `kmstool_enclave_cli decrypt`
向 KMS 解密。设计上值得注意的一点：**只回报明文长度，不回传明文**

```python
res["secret_len"] = len(p.stdout.strip()) if res["ok"] else 0    # 只回报长度，不回传明文
```

这是对的 —— 明文一旦回传到父实例，Confidential 模式的意义就没了。
依赖 guest 里有 `kmstool_enclave_cli`（来自 aws-nitro-enclaves-sdk-c）和 `/dev/nsm`。

### `demo_b_confidential.sh`
四个子命令：

- **`setup`** 建 KMS key，把 key policy 的 Decrypt 语句绑在 attestation 条件上
  （`kms:RecipientAttestation:ImageSha384` = PCR0，`kms:RecipientAttestation:PCR2`），
  加密一个随机 secret。（原来这里还会起 `vsock-proxy`，已改为 `run`/`negative` 里
  按需起 `kms_uds_proxy.py`，原因见本节的 bug (0)。）
- **`run`** 正向：Confidential 模式启动 → 解密成功。
- **`negative`** 五个反向测试，逐条的实测状态：

  | # | 内容 | 状态 |
  |---|---|---|
  | 1 | 父实例直接解密（不带 attestation）→ 期望 AccessDenied | 未跑（依赖 setup 建的 KMS key） |
  | 2 | `debug_mode: true` → PCR 清零 → 期望解密失败 | 未跑（依赖 KMS）；PCR 清零本身文档已确认 |
  | 3 | 加 `entropy` → 期望 `NE_ERR_DEVICE_DISALLOWED` | **已验证**，报错与文档一致 |
  | 4 | 配置与 EIF 能力标志不一致 → 期望 InstanceStart 失败 | 未跑（需要预构建 EIF） |
  | 5 | dump Firecracker 进程内存搜明文 → 期望搜不到 | **测法本身是错的**（见第 9 节），已另写 `demo_b_memtest.sh` 验证 |

- **`cleanup`** 杀进程，`schedule-key-deletion`（7 天窗口），删中间文件。

### 剩下还没核实的小问题

- 反向1 用了 `fileb://<(base64 -d ...)` 进程替换。AWS CLI 的 `fileb://` 读的文件可能需要
  可 seek，进程替换给的是管道，这里有风险，建议先落成临时文件。
- `launch()` 里的 `rm -f $W/api.sock $W/v.sock` 是必要的，不能省：Firecracker 不复用
  已存在的 api.sock，残留文件会直接导致
  `Failed to open the API socket ... Check that it is not already used.`（实测踩过）。
- `cleanup` 里 `source $ST || true` 配合 `set -u`：`$ST` 不存在时靠后面的 `${KEY_ID:-}`
  兜住，这个写法是安全的。
- `pkill -f "$W/api.sock"` 这类按命令行匹配的写法有个坑：如果从一个命令行**本身就含有
  该字符串**的 shell（比如 `bash -c '...'`）里调用，会把自己一起杀掉（实测踩过，
  表现是脚本中途 `Terminated`、退出码 143）。写在脚本文件里没这个问题，
  临时手敲时建议改用 `pgrep -x firecracker` 按进程名精确匹配。

---

## 10. 排查问题的入口

| 现象 | 看哪里 |
|---|---|
| 沙箱起不来 | `/run/sb/<i>/fc.log`，加 `DEBUG=1` 能看到 guest 串口全部输出 |
| guest 不应答 | 先确认 `fc.log` 里有 `Started sb-runner.service`；再查是不是 EOF 分帧问题 |
| 网络不通 | `nft -a list table ip firecracker` 看各条规则的 counter 命中情况 |
| 资源不够 | `pcie_slots_in_use` / `mem_pool/free` |
| 想进沙箱手工看 | 配了网卡后 `ssh -i /opt/sb/sb.id_rsa root@172.16.<i>.2` |
| 想看镜像内容 | `mount -o ro,loop /opt/sb/rootfs.ext4 /mnt/x`，或 `debugfs -R "stat <路径>"` |

留现场调试的姿势：`sudo N=1 KEEP=1 DEBUG=1 bash demo_a_direct.sh`，
看完用 `sudo bash demo_a_direct.sh cleanup` 收。
