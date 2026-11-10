#!/usr/bin/env python3
# guest 内 vsock 代码执行器：收代码 -> 执行 -> 回传 JSON
# 分帧协议：4 字节大端长度前缀 + payload（收发两个方向都一样）。
# 不能用 shutdown/EOF 分帧：Firecracker 读到宿主机 UDS 的 0 长度（SHUT_WR）后，
# 会给 guest 发一个同时带 SHUTDOWN_RCV + SHUTDOWN_SEND 的 vsock shutdown 包并启动
# kill timer，回传方向会被一起拆掉，guest 的应答发不回来。
import socket, subprocess, json, struct

def recv_exact(c, n):
    buf = b""
    while len(buf) < n:
        d = c.recv(n - len(buf))
        if not d:
            return None
        buf += d
    return buf

s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.bind((socket.VMADDR_CID_ANY, 5000)); s.listen(4)
while True:
    c, _ = s.accept()
    try:
        hdr = recv_exact(c, 4)
        if hdr is None:
            continue
        buf = recv_exact(c, struct.unpack("!I", hdr)[0])
        if buf is None:
            continue
        open("/tmp/task.py", "wb").write(buf)
        try:
            p = subprocess.run(["python3", "/tmp/task.py"], capture_output=True, text=True, timeout=20)
            r = {"rc": p.returncode, "out": p.stdout[-4000:], "err": p.stderr[-4000:]}
        except subprocess.TimeoutExpired:
            r = {"rc": -1, "out": "", "err": "timeout"}
        body = json.dumps(r).encode()
        c.sendall(struct.pack("!I", len(body)) + body)
    except OSError:
        pass
    finally:
        c.close()
