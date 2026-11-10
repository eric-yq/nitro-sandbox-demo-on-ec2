#!/usr/bin/env python3
"""把 guest 发起的 vsock 连接转发到一个 TCP 端点（Demo B 用它让沙箱访问 KMS）。

为什么不能用 aws-nitro-enclaves-cli 自带的 vsock-proxy：
那个工具监听的是内核 AF_VSOCK，适用于传统 Nitro Enclaves。而 Firecracker 的
virtio-vsock 后端是 Unix socket —— guest 连宿主机 CID 的端口 N 时，Firecracker 会去找
一个名为 <uds_path>_N 的 AF_UNIX socket（见 Firecracker docs/vsock.md 的
"Guest-Initiated Connections"），完全不碰 AF_VSOCK。所以 vsock-proxy 永远收不到
沙箱的连接，guest 只会拿到 RST。

这里监听 <uds_path>_<port>，收到连接后开一条 TCP 到上游做字节级双向转发。
kmstool_enclave_cli 自己负责 TLS，这一层只需要透传，不要解析内容。

用法：
    python3 kms_uds_proxy.py /run/sb/conf/v.sock 8000 kms.us-east-2.amazonaws.com 443
"""
import argparse
import os
import socket
import sys
import threading


def pipe(src, dst):
    """单向搬运，直到任意一端关闭。"""
    try:
        while True:
            buf = src.recv(65536)
            if not buf:
                break
            dst.sendall(buf)
    except OSError:
        pass
    finally:
        # 关掉双向，让另一个方向的 pipe 也能退出
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(conn, host, port):
    try:
        upstream = socket.create_connection((host, port), timeout=10)
    except OSError as e:
        print(f"上游连接失败 {host}:{port}: {e}", file=sys.stderr, flush=True)
        conn.close()
        return
    threading.Thread(target=pipe, args=(conn, upstream), daemon=True).start()
    pipe(upstream, conn)
    for s in (conn, upstream):
        try:
            s.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description="vsock(UDS) -> TCP 转发")
    ap.add_argument("uds", help="vsock 设备的 uds_path，例如 /run/sb/conf/v.sock")
    ap.add_argument("port", type=int, help="guest 侧连接的 vsock 端口，例如 8000")
    ap.add_argument("host", help="上游主机名，例如 kms.us-east-2.amazonaws.com")
    ap.add_argument("upstream_port", type=int, nargs="?", default=443)
    a = ap.parse_args()

    path = f"{a.uds}_{a.port}"
    # 残留的 socket 文件会让 bind 报 EADDRINUSE，先清掉
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(16)
    os.chmod(path, 0o600)
    print(f"listening {path} -> {a.host}:{a.upstream_port}", flush=True)
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=handle, args=(conn, a.host, a.upstream_port),
                             daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()
        if os.path.exists(path):
            os.unlink(path)


if __name__ == "__main__":
    main()
