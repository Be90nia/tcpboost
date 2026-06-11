#!/bin/bash
# tcpboost - x86_64 内核编译选项配置
# 基于 CloudPassenger/Cloud-Kernel-BBRv3 configs/x86_64_apply.sh
# 许可证：GPLv2

set -e

KERNEL_DIR="${1:-.}"
cd "$KERNEL_DIR"

# 确保 .config 存在
if [ ! -f .config ]; then
  echo "正在生成 x86_64 默认配置..."
  make defconfig
fi

echo "正在应用 tcpboost 内核编译选项..."

# ============================================
# TCP 拥塞控制算法
# ============================================
# BBRv3 (Google BBR 最新版)
./scripts/config --enable CONFIG_TCP_CONG_BBR
# BBRv1 (原版 BBR, 4.9+ 内置)
./scripts/config --enable CONFIG_TCP_CONG_BBR1
# TCP Brutal (apernet/Hysteria2 专用)
./scripts/config --enable CONFIG_TCP_CONG_BRUTAL
# BBRPlus (dog250 修改版, 高丢包优化)
# 注意: 需要先打 BBRPlus 补丁才能启用此选项
./scripts/config --enable CONFIG_TCP_CONG_BBRPLUS

# 默认拥塞控制设为 BBRv3
./scripts/config --enable CONFIG_DEFAULT_BBR
./scripts/config --set-val CONFIG_DEFAULT_TCP_CONG "bbr"

# 禁用默认 Cubic
./scripts/config --disable CONFIG_DEFAULT_CUBIC

# ============================================
# 队列调度
# ============================================
# fq (BBR/BBRPlus 必须配合 fq 进行 pacing)
./scripts/config --enable CONFIG_NET_SCH_FQ
./scripts/config --module CONFIG_NET_SCH_FQ_CODEL
./scripts/config --module CONFIG_NET_SCH_CAKE

# ============================================
# 网络 Buffer 优化
# ============================================
# 增大 TCP buffer 上限以支持高 BDP 链路
./scripts/config --set-val CONFIG_NET_CORE_RMEM_MAX 67108864
./scripts/config --set-val CONFIG_NET_CORE_WMEM_MAX 67108864

# ============================================
# 通用优化
# ============================================
# TCP Fast Open
./scripts/config --enable CONFIG_TCP_FASTOPEN

# BPF (用于高级网络调试)
./scripts/config --enable CONFIG_BPF
./scripts/config --enable CONFIG_BPF_SYSCALL

# 多核网络处理优化
./scripts/config --enable CONFIG_RPS
./scripts/config --enable CONFIG_RFS_ACCEL
./scripts/config --enable CONFIG_XPS

# 虚拟化支持 (VPS 环境)
./scripts/config --module CONFIG_VIRTIO
./scripts/config --module CONFIG_VIRTIO_PCI
./scripts/config --module CONFIG_VIRTIO_NET
./scripts/config --module CONFIG_VIRTIO_BLK

# ============================================
# 固定配置
# ============================================
# 确保配置一致性
make olddefconfig

echo "tcpboost 内核编译选项应用完成。"
echo "已启用的拥塞控制算法: BBRv3, BBRv1, TCP Brutal, BBRPlus"
echo "默认拥塞控制: BBRv3"
echo "默认队列调度: fq"
