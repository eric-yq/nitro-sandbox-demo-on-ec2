#!/bin/bash
# Nitro Sandbox 宿主机准备脚本（AL2023 kernel-6.18, 实例需 --enclave-options Enabled=true）
# 用法：sudo bash nitro_sandbox_parent_setup.sh [stage1|stage2]
#   stage1：检查环境 + 设置内存池内核参数（之后需重启）
#   stage2：重启后执行，设置 slot 预算 + 安装 Firecracker
set -euo pipefail
STAGE=${1:-stage1}
MEMPOOL=${MEMPOOL:-48G}     # 预留给 Sandbox 的内存
SLOTS=${SLOTS:-32}          # Sandbox 并发上限（8 的倍数）
FC_REL=${FC_REL:-v1.18.0}

if [ "$STAGE" = "stage1" ]; then
  echo "== 内核版本（需 >= 6.18.51-120.162.amzn2023）=="
  uname -r
  echo "== Nitro Enclaves 驱动 =="
  ls -la /dev/nitro_enclaves || { echo "未找到 /dev/nitro_enclaves：实例未开启 enclave-options 或内核不支持"; exit 1; }

  # 内存池是从父实例"划走"的，不能接近物理内存，否则重启后父实例自己起不来或者
  # 内存池根本分配不出来（而且要等到重启后才发现）。这里先挡一下。
  TOTAL_MIB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  case "${MEMPOOL}" in
    *[Gg]) WANT_MIB=$(( ${MEMPOOL%[Gg]} * 1024 )) ;;
    *[Mm]) WANT_MIB=${MEMPOOL%[Mm]} ;;
    *)     WANT_MIB=$(( MEMPOOL / 1048576 )) ;;
  esac
  echo "== 内存检查：物理 ${TOTAL_MIB} MiB，拟划给 Sandbox ${WANT_MIB} MiB =="
  if [ "$WANT_MIB" -ge $(( TOTAL_MIB - 2048 )) ]; then
    echo "MEMPOOL=${MEMPOOL} 太大：至少要给父实例留 2 GiB。" >&2
    echo "本机建议 MEMPOOL=$(( (TOTAL_MIB - 4096) / 1024 ))G 以内，例如：" >&2
    echo "  sudo MEMPOOL=$(( (TOTAL_MIB - 4096) / 1024 ))G bash $0 stage1" >&2
    exit 1
  fi

  echo "== 设置内存池 nitro_enclaves.mempool=${MEMPOOL} =="
  grubby --update-kernel=ALL --args="nitro_enclaves.mempool=${MEMPOOL}"
  echo "完成。请执行 reboot，重启后运行：sudo bash $0 stage2"
  exit 0
fi

if [ "$STAGE" = "stage2" ]; then
  cd /sys/class/misc/nitro_enclaves
  echo "== CPU 池 total/free =="
  cat cpu_pool/total cpu_pool/free
  echo "== 内存池剩余 MiB =="
  echo $(( $(cat mem_pool/free) / 1048576 ))
  echo "== 设置 slot 预算为 ${SLOTS} =="
  echo "${SLOTS}" > pcie_slots
  echo "pcie_slots_total / pcie_slots / pcie_slots_in_use:"
  cat pcie_slots_total pcie_slots pcie_slots_in_use
  cd /tmp
  ARCH=$(uname -m)
  echo "== 安装 Firecracker ${FC_REL} (${ARCH}) =="
  curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_REL}/firecracker-${FC_REL}-${ARCH}.tgz" | tar -xz
  install "release-${FC_REL}-${ARCH}/firecracker-${FC_REL}-${ARCH}" /usr/local/bin/firecracker
  firecracker --version
  echo "宿主机准备完成。"
fi
