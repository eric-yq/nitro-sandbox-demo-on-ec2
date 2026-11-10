#!/bin/bash
# 准备 guest 内核和 rootfs，产物放在 /opt/sb/
# 对齐 Firecracker v1.18 官方文档：
#   - docs/getting-started.md#getting-a-rootfs-and-guest-kernel-image
#   - docs/nitro-sandboxes/getting-started.md#guest-kernel
set -euo pipefail

# HERE 必须在 cd 之前算，否则 $0 的相对路径会相对于 $OUT 解析
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=/opt/sb; mkdir -p "$OUT"; cd "$OUT"
ARCH=$(uname -m)
S3="https://s3.amazonaws.com/spec.ccfc.min"

# sandbox 走 UEFI 引导，内核必须是 EFI 可启动镜像：
#   x86_64  -> 必须用 EFI-stub 的 bzImage，KVM microVM 用的 vmlinux 启不了 sandbox
#   aarch64 -> vmlinux- 工件本身就是 EFI 可启动的 Image（CONFIG_EFI_STUB=y 默认开）
if [ "$ARCH" = "x86_64" ]; then KPFX=bzImage-; else KPFX=vmlinux-; fi

dnf install -y squashfs-tools e2fsprogs >/dev/null

# guest 工件桶里带版本号的前缀（firecracker-ci/v1.x/）只发布到 v1.15 为止，
# v1.16+ 改用日期戳前缀 firecracker-ci/YYYYMMDD-<hash>-N/。
# 所以这里不能填 Firecracker 的发布版本号（v1.18.0）——官方 v1.18 文档的做法
# 就是取最新的日期戳构建。可用 CI_PREFIX 覆盖以固定某次构建。
echo "== 解析 CI 工件前缀 =="
PREFIX=${CI_PREFIX:-$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
  | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" \
  | sort | tail -1 || true)}
[ -n "$PREFIX" ] || { echo "没能解析 CI 工件前缀，请检查网络或手动指定 CI_PREFIX=" >&2; exit 1; }
echo "prefix: $PREFIX"

echo "== 下载 guest 内核 (${KPFX}) =="
# grep 无匹配时返回 1，配合 set -e/pipefail 会让脚本静默退出（不打印下面的报错），
# 所以用 `|| true` 兜住，把报错交给显式检查
KEY=$(curl -fsSL "$S3?list-type=2&prefix=${PREFIX}${ARCH}/${KPFX}" \
  | grep -oP "(?<=<Key>)(${PREFIX}${ARCH}/${KPFX}[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
  | sort -V | tail -1 || true)
[ -n "$KEY" ] || { echo "在 $PREFIX$ARCH/ 下没找到 ${KPFX} 内核" >&2; exit 1; }
curl -fsSL "$S3/$KEY" -o kernel.img
KVER=${KEY##*/${KPFX}}
echo "kernel: $KEY"

# Confidential 模式需要 guest 内核带 DMB virtio 补丁；CI 的 6.18 线才带，
# 老的 5.10/6.1 线不带。Direct 模式（Demo A）不需要 DMB。
case "$KVER" in
  6.18.*|6.[2-9][0-9].*|[7-9].*) ;;
  *) echo "警告：内核 $KVER 不是 6.18 线，没有 DMB 补丁，只能跑 Direct 模式（Demo A）" ;;
esac

echo "== 下载 Ubuntu rootfs =="
RKEY=$(curl -fsSL "$S3?list-type=2&prefix=${PREFIX}${ARCH}/ubuntu-" \
  | grep -oP "(?<=<Key>)(${PREFIX}${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
  | sort -V | tail -1 || true)
[ -n "$RKEY" ] || { echo "在 $PREFIX$ARCH/ 下没找到 ubuntu squashfs" >&2; exit 1; }
curl -fsSL "$S3/$RKEY" -o ubuntu.squashfs
echo "rootfs: $RKEY"
rm -rf squashfs-root && unsquashfs -q ubuntu.squashfs

echo "== 注入 SSH key 和 vsock 执行器 =="
[ -f sb.id_rsa ] || ssh-keygen -q -f sb.id_rsa -N ""
mkdir -p squashfs-root/root/.ssh && cp sb.id_rsa.pub squashfs-root/root/.ssh/authorized_keys
install -D -m 755 "$HERE/guest/runner.py"         squashfs-root/opt/runner.py
install -D -m 755 "$HERE/guest/secure_runner.py"  squashfs-root/opt/secure_runner.py
install -D -m 755 "$HERE/guest/sb-net-setup.sh"  squashfs-root/usr/local/bin/sb-net-setup.sh
install -D -m 644 "$HERE/guest/sb-runner.service" squashfs-root/etc/systemd/system/sb-runner.service
install -D -m 644 "$HERE/guest/sb-net.service"    squashfs-root/etc/systemd/system/sb-net.service
ln -sf /etc/systemd/system/sb-runner.service \
  squashfs-root/etc/systemd/system/multi-user.target.wants/sb-runner.service
ln -sf /etc/systemd/system/sb-net.service \
  squashfs-root/etc/systemd/system/multi-user.target.wants/sb-net.service
[ -x squashfs-root/usr/bin/python3 ] || echo "警告：rootfs 里没有 python3，需要自己 chroot 安装（apt install python3）"
chown -R root:root squashfs-root

rm -f rootfs.ext4 && truncate -s 1G rootfs.ext4
mkfs.ext4 -q -d squashfs-root -F rootfs.ext4
rm -rf squashfs-root ubuntu.squashfs

echo "== 校验产物 =="
e2fsck -fn rootfs.ext4 >/dev/null && echo "rootfs.ext4: ext4 文件系统正常"
debugfs -R "stat /opt/runner.py" rootfs.ext4 2>/dev/null | grep -q "Inode:" \
  && echo "rootfs.ext4: /opt/runner.py 已注入"
ls -lh "$OUT"
echo "完成：$OUT/kernel.img ($KVER)  $OUT/rootfs.ext4"
