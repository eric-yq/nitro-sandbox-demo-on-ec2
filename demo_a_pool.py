#!/usr/bin/env python3
# Demo A 编排器：并发拉起 N 个 Direct 模式沙箱 -> 下发 evil.py -> 汇总 -> 销毁
import subprocess, shutil, os, time, socket, json, sys, struct, statistics, concurrent.futures as cf
N = int(os.environ.get("N", "8")); VCPU = int(os.environ.get("VCPU", "1")); MEM = int(os.environ.get("MEM", "1024"))
BASE = "/run/sb"; SB = "/opt/sb"; HERE = os.path.dirname(os.path.abspath(__file__))
EVIL = open(os.path.join(HERE, "evil.py")).read()

def cfg(i):
    return {
        "boot-source": {"kernel_image_path": f"{SB}/kernel.img"},
        "machine-config": {"vcpu_count": VCPU, "mem_size_mib": MEM},
        "drives": [{"drive_id": "rootfs", "path_on_host": f"{BASE}/{i}/rootfs.ext4",
                    "is_root_device": True, "is_read_only": False}],
        "vsock": {"guest_cid": 100 + i, "uds_path": f"{BASE}/{i}/v.sock"},
        # guest 侧 IP 由 rootfs 自带的 fcnet-setup.sh 从 MAC 推导：
        # 06:00: 之后的 4 组十六进制转十进制 -> 06:00:ac:10:<i>:02 = 172.16.<i>.2/30
        "network-interfaces": [{"iface_id": "eth0",
                                "guest_mac": f"06:00:ac:10:{i:02x}:02",
                                "host_dev_name": f"sbtap{i}"}],
        "entropy": {},
        "enclave": {"direct_mode": True, "cpu_overcommit": True, "cpu_accounting": True,
                    "debug_mode": os.environ.get("DEBUG", "0") == "1"},
    }

def launch(i):
    d = f"{BASE}/{i}"; shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    subprocess.run(["cp", "--reflink=auto", f"{SB}/rootfs.ext4", f"{d}/rootfs.ext4"], check=True)
    json.dump(cfg(i), open(f"{d}/vm.json", "w"))
    t0 = time.time()
    p = subprocess.Popen(["firecracker", "--api-sock", f"{d}/api.sock", "--config-file", f"{d}/vm.json"],
                         stdout=open(f"{d}/fc.log", "w"), stderr=subprocess.STDOUT)
    return i, p, t0

def connect(i, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        try:
            u = socket.socket(socket.AF_UNIX); u.settimeout(30); u.connect(f"{BASE}/{i}/v.sock")
            u.sendall(b"CONNECT 5000\n")
            if u.recv(64).startswith(b"OK"): return u
            u.close()
        except OSError: pass
        time.sleep(0.05)
    raise TimeoutError(f"sb-{i} vsock not ready (see {BASE}/{i}/fc.log)")

def recv_exact(u, n):
    buf = b""
    while len(buf) < n:
        d = u.recv(n - len(buf))
        if not d:
            return None
        buf += d
    return buf

def run(v):
    i, p, t0 = v
    try:
        u = connect(i); ready = time.time() - t0
        # 用 4 字节大端长度前缀分帧，不能用 shutdown(SHUT_WR)：Firecracker 读到
        # 宿主机侧 EOF 后会给 guest 发 RCV+SEND 双向 shutdown，应答就发不回来了
        code = EVIL.encode()
        u.sendall(struct.pack("!I", len(code)) + code)
        hdr = recv_exact(u, 4)
        if hdr is None:
            raise IOError("guest 未返回长度头（见 fc.log）")
        body = recv_exact(u, struct.unpack("!I", hdr)[0])
        if body is None:
            raise IOError("guest 应答不完整")
        return i, ready, json.loads(body), None
    except Exception as e:
        return i, None, None, str(e)

def main():
    print(f"== 拉起 {N} 个 Direct 沙箱（{VCPU} vCPU / {MEM} MiB）==")
    with cf.ThreadPoolExecutor(N) as ex:
        vms = list(ex.map(launch, range(N)))
        res = list(ex.map(run, vms))
    ready = []
    for i, t, r, err in sorted(res):
        if err: print(f"sb-{i:02d} FAIL {err}"); continue
        ready.append(t)
        flat = " ".join(l for l in r["out"].splitlines() if ":" in l)
        print(f"sb-{i:02d} ready={t:.2f}s rc={r['rc']} {flat}")
    if ready:
        ready.sort()
        print(f"== 启动到可用：P50={statistics.median(ready):.2f}s  max={ready[-1]:.2f}s  成功 {len(ready)}/{N}")
    print("== CPU 计费（fc_vcpu 线程）==")
    os.system("ps -eT -o pid,tid,comm | grep fc_vcpu | head -5")
    if os.environ.get("KEEP", "0") != "1":
        for i, p, _ in vms:
            p.kill(); p.wait(); shutil.rmtree(f"{BASE}/{i}", ignore_errors=True)
        print("== 已全部销毁 ==")

if __name__ == "__main__":
    main()
