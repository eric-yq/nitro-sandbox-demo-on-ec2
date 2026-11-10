#!/usr/bin/env python3
# Demo B guest 端程序：用 NSM attestation 向 KMS 解密 secret（凭证和密文由父实例通过 vsock 端口 5001 发进来）
# 依赖 guest 里有 kmstool_enclave_cli（来自 aws-nitro-enclaves-sdk-c）和 /dev/nsm（CONFIG_NSM=y）
#
# 分帧协议：4 字节大端长度前缀 + payload（收发两个方向都一样）。
# 不能用 shutdown/EOF 分帧：Firecracker 读到宿主机 UDS 的 0 长度（SHUT_WR）后，会给 guest
# 发一个同时带 SHUTDOWN_RCV + SHUTDOWN_SEND 的 vsock shutdown 包并启动 kill timer，
# 回传方向会被一起拆掉，应答发不回来。
import socket, subprocess, json, os, struct

def recv_exact(c, n):
    buf = b""
    while len(buf) < n:
        d = c.recv(n - len(buf))
        if not d:
            return None
        buf += d
    return buf

s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.bind((socket.VMADDR_CID_ANY, 5001)); s.listen(1)
while True:
    c, _ = s.accept()
    try:
        hdr = recv_exact(c, 4)
        if hdr is None:
            continue
        buf = recv_exact(c, struct.unpack("!I", hdr)[0])
        if buf is None:
            continue
        req = json.loads(buf)
        res = {"nsm": os.path.exists("/dev/nsm"), "ok": False, "secret_len": 0, "err": ""}
        # kmstool 相关的异常必须转成应答里的 err 返回，不能让它冒到外层：
        # FileNotFoundError 是 OSError 的子类，被外层 except 吞掉的话父实例只会看到
        # 连接被关、没有应答，完全没法判断是"guest 里没装 kmstool"还是"vsock 坏了"。
        try:
            p = subprocess.run(["kmstool_enclave_cli", "decrypt", "--region", req["region"], "--proxy-port", "8000",
                "--aws-access-key-id", req["ak"], "--aws-secret-access-key", req["sk"], "--aws-session-token", req["tk"],
                "--ciphertext", req["ct"]], capture_output=True, text=True, timeout=60)
            res["ok"] = p.returncode == 0
            res["secret_len"] = len(p.stdout.strip()) if res["ok"] else 0    # 只回报长度，不回传明文
            res["err"] = p.stderr[-500:]
        except FileNotFoundError:
            res["err"] = "kmstool_enclave_cli not found in guest (需要 aws-nitro-enclaves-sdk-c)"
        except subprocess.TimeoutExpired:
            res["err"] = "kmstool_enclave_cli timeout (vsock-proxy 没起来？)"
        except Exception as e:                      # 兜底，保证一定有应答
            res["err"] = f"{e.__class__.__name__}: {e}"[:500]
        body = json.dumps(res).encode()
        c.sendall(struct.pack("!I", len(body)) + body)
    except OSError:
        pass                                        # 这里只兜 socket 层的错
    finally:
        c.close()
