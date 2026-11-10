import os, socket, subprocess

def tcp(host, port, timeout=3.0):
    """返回 (是否建连成功, 说明)。连接被拒说明对端可达但端口没开，和超时/不可达要区分开。"""
    try:
        s = socket.create_connection((host, port), timeout); s.close()
        return True, "open"
    except ConnectionRefusedError:
        return False, "refused(可达)"
    except socket.timeout:
        return False, "timeout"
    except OSError as e:
        return False, f"{e.__class__.__name__}"

def nic():
    out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split()
        if len(f) > 3 and f[1] != "lo":
            return f[1], f[3]
    return None, None

dev, cidr = nic()
gw = None
if cidr:
    p = cidr.split("/")[0].split(".")
    gw = ".".join(p[:3] + [str(int(p[3]) - 1)])

print("host_creds_visible:", os.path.exists("/root/.aws/credentials"))
print("peer_disk_visible:", os.path.exists("/run/sb/0/rootfs.ext4"))
print("nic:", f"{dev or 'none'} {cidr or '-'}")

# 1) 链路通不通：ping 宿主机 tap 地址
if gw:
    r = subprocess.run(["ping", "-c", "1", "-W", "2", gw], capture_output=True)
    print("gw_reachable:", r.returncode == 0)
else:
    print("gw_reachable:", False)

# 2) NAT 出网通不通（证明"不可达"不是因为没网）
ok, why = tcp("1.1.1.1", 443)
print("egress_ok:", ok, f"({why})" if not ok else "")

# 3) IMDS：期望被拦住
ok, why = tcp("169.254.169.254", 80)
print("imds_reachable:", ok, f"({why})" if not ok else "")

print("hostname:", os.uname().nodename)
print("done")
