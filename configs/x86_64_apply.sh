#!/bin/bash
# tcpboost - x86_64 内核编译选项配置
# 基于 CloudPassenger/Cloud-Kernel-BBRv3 configs/x86_64_apply.sh
# 许可证：GPLv2

set -e

KERNEL_DIR="${1:-.}"
cd "$KERNEL_DIR"

# 确保 .config 存在
if [ ! -f .config ]; then
  echo "正在准备内核配置..."

  # 必须使用发行版完整 config 作为基线，不能用 make defconfig。
  # x86_64_defconfig 是上游最小可启动配置，默认禁用大量协议：
  #   - Netfilter 完整栈 (iptables/nftables REDIRECT/TPROXY/CONNTRACK/NAT)
  #   - TUN/TAP (sing-box/xray 透明代理必需)
  #   - WireGuard / VXLAN / IPIP / GRE / FOU / UDP Tunnel
  #   - XFRM / IPSec (INET_ESP/AH)
  #   - NET_CLS_BPF / NET_ACT_* (tc 流量分类)
  #   - NET_SCH_HTB/TBF/HFSC/PRIO/SFQ/RED (除 fq 外的 qdisc)
  #   - Bridge / VLAN / VETH / DUMMY / MACVLAN (容器网络)
  #   - IP_VS (kube-proxy IPVS)
  # 这些缺失会导致 sing-box TUN、xray ws/xhttp、Docker/K8s、tc filter 等全部失效。
  DISTRO_CONFIG=""
  for cfg_pattern in \
    "/boot/config-$(uname -r)" \
    /boot/config-*-cloud-amd64 \
    /boot/config-*-generic \
    /boot/config-*-amd64 \
    /boot/config-*-linux-*; do
    if ls $cfg_pattern >/dev/null 2>&1; then
      DISTRO_CONFIG=$(ls -1v $cfg_pattern 2>/dev/null | tail -1)
      break
    fi
  done

  if [ -n "$DISTRO_CONFIG" ]; then
    echo "✅ 使用发行版完整配置作为基线: $DISTRO_CONFIG"
    cp "$DISTRO_CONFIG" .config
    make olddefconfig
  else
    echo "⚠️  警告: 未找到任何发行版 config，回退到 x86_64_defconfig"
    echo "⚠️  警告: defconfig 默认禁用大量网络协议 (netfilter/tc/tun/wireguard/vxlan/ipsec)"
    echo "           这会导致 sing-box TUN、xray ws/xhttp、iptables、tc、Docker/K8s 等失效"
    make defconfig
  fi
fi

echo "正在应用 tcpboost 内核编译选项..."

# ============================================
# TCP 拥塞控制算法
# ============================================
# BBRv3 (Google BBR 最新版, XanMod 补丁提供)
./scripts/config --enable CONFIG_TCP_CONG_BBR
# BBRv1 (原版 BBR, 4.9+ 内置)
./scripts/config --enable CONFIG_TCP_CONG_BBR1
# TCP Brutal (apernet/Hysteria2 专用)
./scripts/config --enable CONFIG_TCP_CONG_BRUTAL
# BBRPlus (dog250 修改版, 高丢包优化)
# 注意: 需要先打 BBRPlus 补丁才能启用此选项，否则 make olddefconfig 会将其移除
if grep -q "tcp_bbrplus" net/ipv4/Makefile 2>/dev/null || \
   grep -q "CONFIG_TCP_CONG_BBRPLUS" init/Kconfig 2>/dev/null || \
   [ -f "net/ipv4/tcp_bbrplus.c" ]; then
  echo "检测到 BBRPlus 补丁已应用，启用 CONFIG_TCP_CONG_BBRPLUS"
  ./scripts/config --enable CONFIG_TCP_CONG_BBRPLUS
else
  echo "⚠️ 未检测到 BBRPlus 补丁，跳过 CONFIG_TCP_CONG_BBRPLUS"
fi

# BBRPlusV3 (BBRv3 + BBRPlus 激进探测, 高丢包链路首选)
# 基于 Google BBRv3 基线，融合 BBRPlus 激进探测思想
if grep -q "tcp_bbrplusv3" net/ipv4/Makefile 2>/dev/null || \
   grep -q "CONFIG_TCP_CONG_BBRPLUSV3" init/Kconfig 2>/dev/null || \
   [ -f "net/ipv4/tcp_bbrplusv3.c" ]; then
  echo "检测到 BBRPlusV3 已创建，启用 CONFIG_TCP_CONG_BBRPLUSV3"
  ./scripts/config --enable CONFIG_TCP_CONG_BBRPLUSV3
else
  echo "⚠️ 未检测到 BBRPlusV3，跳过 CONFIG_TCP_CONG_BBRPLUSV3"
fi

# 默认拥塞控制设为 BBRv3
./scripts/config --enable CONFIG_DEFAULT_BBR
./scripts/config --set-str CONFIG_DEFAULT_TCP_CONG "bbr"

# 禁用默认 Cubic
./scripts/config --disable CONFIG_DEFAULT_CUBIC

# ============================================
# 队列调度
# ============================================
# fq (BBR/BBRPlus 必须配合 fq 进行 pacing)
./scripts/config --enable CONFIG_NET_SCH_FQ
./scripts/config --module CONFIG_NET_SCH_FQ_CODEL
./scripts/config --module CONFIG_NET_SCH_CAKE
./scripts/config --enable CONFIG_NET_SCH_HTB
./scripts/config --enable CONFIG_NET_SCH_TBF
./scripts/config --enable CONFIG_NET_SCH_PRIO
./scripts/config --enable CONFIG_NET_SCH_SFQ
./scripts/config --enable CONFIG_NET_SCH_RED
./scripts/config --enable CONFIG_NET_SCH_HFSC

# ============================================
# 网络 Buffer 优化
# ============================================
# 注意: CONFIG_NET_CORE_RMEM_MAX / WMEM_MAX 不是 Kconfig 选项，
# 而是 sysctl 运行时参数 (net.core.rmem_max / wmem_max)。
# 编译时无法设置，需在运行时通过 sysctl 配置：
#   sysctl -w net.core.rmem_max=67108864
#   sysctl -w net.core.wmem_max=67108864

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
# 禁用签名/证书/BTF 等 CI 编译陷阱
# ============================================
# 发行版 config (Ubuntu/Debian) 默认启用大量证书相关特性，引用 CI 不存在的密钥文件，
# 会导致 vmlinux 链接阶段 Error 255 (ld 失败) 或 bindeb-pkg 失败。
# 这里把所有相关项全部 disable / set-str 空，确保 CI 能干净编译。

# 1. 模块签名（最常见的 vmlinux Error 255 元凶）
./scripts/config --disable CONFIG_MODULE_SIG
./scripts/config --disable CONFIG_MODULE_SIG_ALL
./scripts/config --disable CONFIG_MODULE_SIG_FORCE
./scripts/config --disable CONFIG_MODULE_SIG_SHA256
./scripts/config --disable CONFIG_MODULE_SIG_SHA384
./scripts/config --disable CONFIG_MODULE_SIG_SHA512
./scripts/config --set-str CONFIG_MODULE_SIG_KEY ""
./scripts/config --disable CONFIG_MODULE_SIG_KEYTYPE
./scripts/config --set-str CONFIG_MODULE_SIG_HASH ""
./scripts/config --set-str CONFIG_MODULE_SIG_HASH_OLD ""

# 2. 系统信任根 / 吊销列表 (Ubuntu config: CONFIG_SYSTEM_TRUSTED_KEYS="debian/canonical-certs.pem")
./scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# 3. 各类 keyring (引用更多证书文件)
./scripts/config --disable CONFIG_SYSTEM_TRUSTED_KEYRING
./scripts/config --disable CONFIG_SYSTEM_BLACKLIST_KEYRING
./scripts/config --disable CONFIG_SYSTEM_REVOCATION_KEYRING
./scripts/config --disable CONFIG_SECONDARY_TRUSTED_KEYRING
./scripts/config --disable CONFIG_IMA_KEYRINGS_PERMIT_SIGNED_BY_BUILTIN_OR_SECONDARY

# 4. 安全锁定 (发行版默认启用，CI 编译会触发多种依赖问题)
./scripts/config --disable CONFIG_SECURITY_LOCKDOWN_LSM
./scripts/config --disable CONFIG_SECURITY_LOCKDOWN_LSM_EARLY
./scripts/config --disable CONFIG_SECURITY_SECURELEVEL

# 5. BTF 调试信息 (pahole 版本/工具链问题经常导致 resolve_btfids 失败)
# BTF 仅 BPF CO-RE 需要，对 TCP 加速、科学上网、容器等场景无影响
./scripts/config --disable CONFIG_DEBUG_INFO_BTF
./scripts/config --disable CONFIG_DEBUG_INFO_BTF_MODULES
./scripts/config --disable CONFIG_DEBUG_INFO_BTF_MODULES_PERF_MODULE
./scripts/config --disable CONFIG_DEBUG_INFO

# 6. 阻止 build 阶段读证书的杂项
./scripts/config --disable CONFIG_SIGNED_PE_FILE_VERIFICATION
./scripts/config --disable CONFIG_EFI_SECRET

# ============================================
# Scheduler / EEVDF 配置 (版本自适应)
# ============================================
# CONFIG_SCHED_DEBUG: 调试fs接口 (debugfs/sched_features)，生产禁用减小内核体积 (srx)
./scripts/config --disable CONFIG_SCHED_DEBUG

# 7.0+ x86 取消 PREEMPT_NONE/PREEMPT_VOLUNTARY, 默认 PREEMPT_LAZY
# 6.12/6.18: 保持 PREEMPT_VOLUNTARY (默认)
KERNEL_MAJOR=$(grep -oP '^VERSION\s*=\s*\K\d+' Makefile 2>/dev/null || echo 6)
KERNEL_MINOR=$(grep -oP '^PATCHLEVEL\s*=\s*\K\d+' Makefile 2>/dev/null || echo 12)
if [ "$KERNEL_MAJOR" -ge 7 ]; then
  echo "Linux $KERNEL_MAJOR.$KERNEL_MINOR: 启用 PREEMPT_LAZY"
  ./scripts/config --disable CONFIG_PREEMPT_NONE
  ./scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
  ./scripts/config --enable CONFIG_PREEMPT_LAZY
else
  echo "Linux $KERNEL_MAJOR.$KERNEL_MINOR: 保持 PREEMPT_VOLUNTARY"
fi

# ============================================
# 固定配置
# ============================================
# 确保配置一致性
make olddefconfig

echo "tcpboost 内核编译选项应用完成。"
echo ""
echo "=== 已启用的 TCP 拥塞控制 ==="
grep -E 'CONFIG_TCP_CONG_(BBR|BRUTAL|BBRPLUS|BBR1)' .config || true
echo "=== 默认拥塞控制 ==="
grep 'CONFIG_DEFAULT_TCP_CONG' .config || true
