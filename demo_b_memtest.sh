#!/bin/bash
# Demo B 的核心主张验证：Confidential 模式下父实例读不到 sandbox 内存，Direct 模式下能读到。
#
# 做法：guest 里起一个常驻进程把 canary 持有在内存里，然后父实例直接读
#       /proc/<fc_pid>/mem 里那段 /dev/nitro_enclaves 的映射，搜 canary。
#       两种模式各跑一遍做 A/B 对照 —— 对照组能读到，才说明这个测法有判别力。
#
# 为什么不用 gcore：guest 内存是 file-backed shared 映射（/dev/nitro_enclaves），
#       而默认 coredump_filter=0x33 没开 file-backed 的位（bit 2/3），
#       gcore 会直接跳过这段，512 MiB 的 guest 只 dump 出 3 MB，对照组也是 0 命中，
#       等于白测。直接读 /proc/pid/mem 才是真正的"父实例能不能看到"。
#
# 用法：sudo bash demo_b_memtest.sh [MEM_MiB]
set -euo pipefail
MEM=${1:-512}
CANARY="SB-CANARY-9f41c7e2a6b80d3f"
W=/run/sb/memtest
[ -f /opt/sb/kernel.img ] && [ -f /opt/sb/rootfs.ext4 ] || { echo "先运行 00_build_guest.sh"; exit 1; }

cleanup() { pkill -f "api-sock $W/api.sock" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT

run_one() {   # $1 = 模式名; $2 = enclave JSON
  local mode="$1" enc="$2"
  pkill -f "api-sock $W/api.sock" 2>/dev/null || true; sleep 1
  rm -rf "$W"; mkdir -p "$W"
  cp --reflink=auto /opt/sb/rootfs.ext4 "$W/rootfs.ext4"
  # dmb_size_mib 只能在 Confidential 模式设，Direct 模式设了会被拒
  local vsock='{ "guest_cid": 200, "uds_path": "'"$W"'/v.sock", "dmb_size_mib": 4 }'
  [[ "$enc" == *direct_mode* ]] && vsock='{ "guest_cid": 200, "uds_path": "'"$W"'/v.sock" }'
  cat > "$W/vm.json" <<EOF
{
  "boot-source":   { "kernel_image_path": "/opt/sb/kernel.img" },
  "machine-config":{ "vcpu_count": 2, "mem_size_mib": $MEM },
  "drives": [{ "drive_id": "rootfs", "path_on_host": "$W/rootfs.ext4",
               "is_root_device": true, "is_read_only": false }],
  "vsock": $vsock,
  "enclave": $enc
}
EOF
  firecracker --api-sock "$W/api.sock" --config-file "$W/vm.json" > "$W/fc.log" 2>&1 &
  local pid=""
  for _ in $(seq 100); do
    pid=$(pgrep -f "api-sock $W/api.sock" | head -1 || true); [ -n "$pid" ] && break
    sleep 0.1
  done
  [ -n "$pid" ] || { echo "  -> firecracker 没起来，看 $W/fc.log"; return; }

  # 让 guest 起一个常驻进程持有 canary
  python3 - "$W/v.sock" "$CANARY" <<'PY'
import socket, sys, struct, json, time
sock, canary = sys.argv[1], sys.argv[2]
payload = f'''
import subprocess, time
open("/tmp/hold.py","w").write(
    "import time\\n"
    "buf = (\\"{canary}\\" * 4096).encode()\\n"
    "while True: time.sleep(1)\\n")
subprocess.Popen(["setsid","python3","/tmp/hold.py"],
                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(2)
print("holder_running:", subprocess.run(["pgrep","-f","/tmp/hold.py"],
      capture_output=True).returncode == 0)
'''.encode()
u = None
for _ in range(1200):
    try:
        s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
        s.sendall(b"CONNECT 5000\n")
        if s.recv(64).startswith(b"OK"): u = s; break
        s.close()
    except OSError: pass
    time.sleep(0.05)
if not u:
    print("  -> guest 连不上"); sys.exit(1)
u.sendall(struct.pack("!I", len(payload)) + payload)
def rx(n):
    b=b""
    while len(b)<n:
        d=u.recv(n-len(b))
        if not d: return None
        b+=d
    return b
h = rx(4)
if h is None: print("  -> guest 没应答"); sys.exit(1)
print("  ->", json.loads(rx(struct.unpack("!I", h)[0]))["out"].strip())
PY

  # 父实例直接读 /proc/<pid>/mem
  python3 - "$pid" "$CANARY" <<'PY'
import sys, os, re
pid, canary = sys.argv[1], sys.argv[2].encode()
regions = []
with open(f"/proc/{pid}/maps") as f:
    for line in f:
        parts = line.split()
        if len(parts) < 5: continue
        rng, perms = parts[0], parts[1]
        path = parts[5] if len(parts) > 5 else ""
        if "r" not in perms: continue
        a, b = (int(x, 16) for x in rng.split("-"))
        if b - a >= 64 * 1024 * 1024:       # 只看大块，guest RAM 在这里
            regions.append((a, b, perms, path))
if not regions:
    print("  -> 没找到 >=64MiB 的可读映射"); sys.exit()
total_read = total_err = hits = 0
for a, b, perms, path in regions:
    size = b - a
    print(f"  -> 映射 {a:#x}-{b:#x} {perms} {size//1048576} MiB {path}")
    fd = os.open(f"/proc/{pid}/mem", os.O_RDONLY)
    chunk, overlap, off, prev = 8 << 20, len(canary), a, b""
    read_ok = err = 0
    try:
        while off < b:
            n = min(chunk, b - off)
            try:
                buf = os.pread(fd, n, off)
                read_ok += len(buf)
                hits += (prev + buf).count(canary)
                prev = buf[-overlap:] if len(buf) >= overlap else buf
            except OSError:
                err += n
                prev = b""
            off += n
    finally:
        os.close(fd)
    total_read += read_ok; total_err += err
    print(f"     读成功 {read_ok/1048576:.0f} MiB / 读失败 {err/1048576:.0f} MiB")
print(f"  => canary 命中 {hits} 处；"
      + ("父实例读到了 guest 内存" if hits > 0 else "父实例读不到 guest 内存"))
PY
}

echo "=== [A] Confidential 模式（无 direct_mode）==="
run_one confidential '{ "cpu_overcommit": true }'
echo
echo "=== [B] Direct 模式（对照组）==="
run_one direct '{ "direct_mode": true, "cpu_overcommit": true }'
echo
echo "期望：A 命中 0（读不到），B 命中 >0（读到）。B 必须能读到，否则这个测法没有判别力。"
