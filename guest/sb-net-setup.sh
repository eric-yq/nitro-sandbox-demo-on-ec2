#!/usr/bin/env bash
# fcnet-setup.sh 只按 MAC 给网卡配了 /30 的 IP，没有默认路由。
# 这里补上：/30 子网里宿主机 tap 的地址就是 guest IP - 1（如 guest 172.16.0.2 -> gw 172.16.0.1）。
set -eu
for dev in $(ls /sys/class/net | grep -v '^lo$'); do
    cidr=$(ip -4 -o addr show dev "$dev" | awk '{print $4}' | head -1)
    [ -n "$cidr" ] || continue
    ip=${cidr%/*}
    gw=$(echo "$ip" | awk -F. '{printf "%s.%s.%s.%d", $1, $2, $3, $4 - 1}')
    ip route replace default via "$gw" dev "$dev"
    echo "sb-net: $dev $cidr -> default via $gw"
    exit 0
done
echo "sb-net: 没找到已配置 IP 的网卡" >&2
