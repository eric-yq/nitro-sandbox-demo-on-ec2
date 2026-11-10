#!/bin/bash
# Demo A：Direct 模式。用法：N=8 VCPU=1 MEM=1024 [DEBUG=1] [KEEP=1] [LEAK_IMDS=1] bash demo_a_direct.sh
#
# 网络：每个沙箱一条 /30，sbtap<i> = 172.16.<i>.1，guest = 172.16.<i>.2
#       （guest 侧 IP 由 rootfs 自带的 fcnet-setup.sh 按 MAC 推出来，
#         默认路由由我们注入的 sb-net.service 补上）
#       宿主机做 NAT 让沙箱有真实出网能力，再单独 drop 掉 169.254.0.0/16，
#       这样 imds_reachable=False 才是"被拦住"而不是"压根没网"。
#       LEAK_IMDS=1 可以去掉这条 drop，用来演示只做 NAT 不拦链路本地时 IMDS 会泄漏。
set -euo pipefail
N=${N:-8}; MEM=${MEM:-1024}
NE=/sys/class/misc/nitro_enclaves
NFT_TABLE=firecracker
GUEST_NET=172.16.0.0/16     # 沙箱专用网段，和宿主机的 172.31.0.0/20 不重叠

[ -f /opt/sb/kernel.img ] && [ -f /opt/sb/rootfs.ext4 ] || { echo "先运行 00_build_guest.sh"; exit 1; }
command -v firecracker >/dev/null || { echo "先运行 nitro_sandbox_parent_setup.sh stage2"; exit 1; }
command -v nft >/dev/null || { echo "需要 nftables：dnf install -y nftables"; exit 1; }
[ "$N" -le 250 ] || { echo "N 最大 250（受 172.16.<i>.0/30 的第三段限制）"; exit 1; }

UPLINK=${UPLINK:-$(ip route show default | awk '/default/{print $5; exit}')}
[ -n "$UPLINK" ] || { echo "找不到默认出口网卡，用 UPLINK=<dev> 指定"; exit 1; }

# ip_forward 的原值要落盘：cleanup 子命令是独立进程启动的，
# 直接读当前值会把我们自己改过的 1 当成"原值"存下来
FWD_STATE=/run/sb-ipfwd.saved

net_down() {   # 幂等清理；只删我们自己建的东西
  for i in $(seq 0 255); do ip link del "sbtap$i" 2>/dev/null || true; done
  nft list table ip $NFT_TABLE >/dev/null 2>&1 && nft delete table ip $NFT_TABLE || true
  if [ -f "$FWD_STATE" ]; then
    cat "$FWD_STATE" > /proc/sys/net/ipv4/ip_forward; rm -f "$FWD_STATE"
  else
    echo 0 > /proc/sys/net/ipv4/ip_forward
  fi
}

# 支持单独清理：bash demo_a_direct.sh cleanup
if [ "${1:-}" = "cleanup" ]; then
  pkill -f "firecracker --api-sock /run/sb" 2>/dev/null || true
  net_down; rm -rf /run/sb; echo "已清理 tap / nft / ip_forward / /run/sb"; exit 0
fi

# KEEP=1 时要保留沙箱的网络，不然留着的 VM 会断网；清理交给 cleanup 子命令
trap '[ "${KEEP:-0}" = "1" ] \
  && echo "KEEP=1：tap/nft 已保留，清理请执行 sudo bash demo_a_direct.sh cleanup" \
  || net_down' EXIT

net_up() {
  echo "== 配置网络（出口 $UPLINK）=="
  for i in $(seq 0 $((N-1))); do
    ip link del "sbtap$i" 2>/dev/null || true
    ip tuntap add "sbtap$i" mode tap
    ip addr add "172.16.$i.1/30" dev "sbtap$i"
    ip link set "sbtap$i" up
  done
  [ -f "$FWD_STATE" ] || cat /proc/sys/net/ipv4/ip_forward > "$FWD_STATE"
  echo 1 > /proc/sys/net/ipv4/ip_forward
  # 用独立的 table，清理时整表删掉，不碰宿主机已有规则
  nft list table ip $NFT_TABLE >/dev/null 2>&1 && nft delete table ip $NFT_TABLE
  nft add table ip $NFT_TABLE
  nft "add chain ip $NFT_TABLE postrouting { type nat hook postrouting priority srcnat; policy accept; }"
  nft "add chain ip $NFT_TABLE forward { type filter hook forward priority filter; policy accept; }"
  if [ "${LEAK_IMDS:-0}" = "1" ]; then
    echo "!! LEAK_IMDS=1：不拦 169.254.0.0/16，预期 imds_reachable=True（演示 NAT 裸奔会泄漏 IMDS）"
  else
    # 这条必须在 accept 之前；链路本地整段都拦，不只是 169.254.169.254
    nft add rule ip $NFT_TABLE forward ip saddr $GUEST_NET ip daddr 169.254.0.0/16 counter drop
  fi
  nft add rule ip $NFT_TABLE forward ip saddr $GUEST_NET oifname "$UPLINK" counter accept
  nft add rule ip $NFT_TABLE postrouting ip saddr $GUEST_NET oifname "$UPLINK" counter masquerade
}

echo "== 资源预检 =="
SLOTS=$(cat $NE/pcie_slots); USED=$(cat $NE/pcie_slots_in_use)
FREE_MIB=$(( $(cat $NE/mem_pool/free) / 1048576 ))
NEED_MIB=$(( N * (MEM + 2) ))
echo "slot: ${USED}/${SLOTS}  内存池剩余: ${FREE_MIB} MiB  需要约: ${NEED_MIB} MiB"
if [ $(( SLOTS - USED )) -lt "$N" ]; then
  T=$(( (USED + N + 7) / 8 * 8 )); echo "slot 不够，调大到 $T"; echo $T > $NE/pcie_slots
fi
[ "$FREE_MIB" -ge "$NEED_MIB" ] || { echo "内存池不够：调小 N/MEM，或者调大 nitro_enclaves.mempool 后重启"; exit 1; }

net_up

mkdir -p /run/sb
cd "$(dirname "$0")"
N=$N python3 demo_a_pool.py

echo
echo "期望：host_creds_visible / peer_disk_visible 为 False；"
echo "      gw_reachable / egress_ok 为 True（证明网卡和 NAT 真的通）；"
if [ "${LEAK_IMDS:-0}" = "1" ]; then
  echo "      imds_reachable 为 True（LEAK_IMDS=1，说明这项检查确实有判别力）"
else
  echo "      imds_reachable 为 False（被 nft 规则拦住，而不是因为没网）"
  echo "== IMDS drop 规则命中计数 =="
  nft -a list chain ip $NFT_TABLE forward | grep -E "169\.254|counter packets" | head -5
fi
