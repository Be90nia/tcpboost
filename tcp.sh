#!/bin/bash
#================================================================
#  TCPBoost — Linux VPS TCP 网络加速一键脚本
#  基于 CloudPassenger/Cloud-Kernel-BBRv3 内核 + 系统级网络优化
#  支持: Debian 11+/Ubuntu 20.04+ (.deb) | Rocky 9/Alma 9 (.rpm)
#  架构: x86_64
#  许可证: GPLv2
#================================================================

set -e
export LANG=en_US.UTF-8

# ===== 全局变量 =====
VERSION="1.0.0-dev"
REPO="Be90nia/tcpboost"
RELEASE_URL="https://github.com/${REPO}/releases"
KERNEL_NAME="tcpboost"
CONF_DIR="/etc/tcpboost"
BACKUP_DIR="/etc/tcpboost/backup"
SYSCTL_FILE="/etc/sysctl.d/99-tcpboost.conf"
LIMITS_FILE="/etc/security/limits.d/tcpboost.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== 工具函数 =====

info()  { echo -e "${GREEN}[信息]${NC} $*"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
error() { echo -e "${RED}[错误]${NC} $*"; }

# 检查 root 权限
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 用户运行此脚本"
    exit 1
  fi
}

# 下载工具
dl() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 --retry-delay 2 -o "$output" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" --tries=3 "$url"
  else
    error "需要 curl 或 wget"
    return 1
  fi
}

# ===== 系统检测 =====

detect_os() {
  if [ -f /etc/debian_version ]; then
    OS_FAMILY="debian"
    OS_NAME=$(cat /etc/os-release | grep -i "^ID=" | cut -d= -f2 | tr -d '"')
    OS_VERSION=$(cat /etc/debian_version | grep -oE '^[0-9]+' | head -1)
    PKG_FMT="deb"
    PKG_INSTALL="dpkg -i"
    PKG_REMOVE="dpkg -r"
  elif [ -f /etc/redhat-release ] || [ -f /etc/rocky-release ] || [ -f /etc/almalinux-release ]; then
    OS_FAMILY="rhel"
    OS_NAME=$(cat /etc/os-release | grep -i "^ID=" | cut -d= -f2 | tr -d '"')
    OS_VERSION=$(cat /etc/os-release | grep -i "^VERSION_ID=" | cut -d= -f2 | tr -d '"' | cut -d. -f1)
    PKG_FMT="rpm"
    PKG_INSTALL="dnf install -y"
    PKG_REMOVE="dnf remove -y"
  else
    OS_FAMILY="unknown"
    error "不支持的操作系统"
    exit 1
  fi

  ARCH=$(uname -m)
  if [ "$ARCH" != "x86_64" ]; then
    error "当前仅支持 x86_64 架构，检测到: $ARCH"
    exit 1
  fi
}

check_os_version() {
  case "$OS_FAMILY" in
    debian)
      if [ "$OS_NAME" = "debian" ] && [ "$OS_VERSION" -lt 11 ]; then
        error "Debian 版本过低 (当前: ${OS_VERSION})，需要 Debian 11+"
        exit 1
      fi
      if [ "$OS_NAME" = "ubuntu" ] && [ "$OS_VERSION" -lt 20 ]; then
        error "Ubuntu 版本过低 (当前: ${OS_VERSION})，需要 Ubuntu 20.04+"
        exit 1
      fi
      ;;
    rhel)
      if [ "$OS_VERSION" -lt 9 ]; then
        error "RHEL 系列版本过低 (当前: ${OS_VERSION})，需要 Rocky 9 / Alma 9 / CentOS Stream 9"
        exit 1
      fi
      ;;
  esac
}

# ===== 内核管理 =====

# 获取最新 Release 版本号
get_latest_version() {
  local version
  version=$(curl -sf "${RELEASE_URL}/latest" 2>/dev/null | grep -oP 'tag/\Kv[0-9.]+' | head -1 | sed 's/^v//')
  if [ -z "$version" ]; then
    version="6.12.73"
    warn "无法获取最新版本，使用默认: $version"
  fi
  echo "$version"
}

# 下载内核包
download_kernel() {
  local version="$1"
  local tmpdir
  tmpdir=$(mktemp -d)

  info "下载 TCPBoost 内核 ${version}..."

  case "$PKG_FMT" in
    deb)
      # 下载 linux-headers, linux-image, linux-libc-dev
      local files="linux-headers-${version}-tcpboost_${version}-tcpboost-1_amd64.deb
                   linux-image-${version}-tcpboost_${version}-tcpboost-1_amd64.deb
                   linux-libc-dev_${version}-tcpboost-1_amd64.deb"
      for f in $files; do
        info "下载: $f"
        dl "${RELEASE_URL}/download/v${version}-tcpboost/${f}" "${tmpdir}/${f}" || {
          error "下载失败: $f"
          rm -rf "$tmpdir"
          exit 1
        }
      done
      ;;
    rpm)
      # RPM 包下载
      local files="linux-headers-${version}-tcpboost-${version}_tcpboost-1.x86_64.rpm
                   linux-image-${version}-tcpboost-${version}_tcpboost-1.x86_64.rpm"
      for f in $files; do
        info "下载: $f"
        dl "${RELEASE_URL}/download/v${version}-tcpboost/${f}" "${tmpdir}/${f}" || {
          error "下载失败: $f"
          rm -rf "$tmpdir"
          exit 1
        }
      done
      ;;
  esac

  echo "$tmpdir"
}

# 安装内核
install_kernel() {
  local version
  version=$(get_latest_version)

  detect_os
  check_os_version

  info "系统: ${OS_NAME} ${OS_VERSION} (${OS_FAMILY})"
  info "架构: ${ARCH}"
  info "包格式: ${PKG_FMT}"
  echo ""

  local tmpdir
  tmpdir=$(download_kernel "$version")

  info "安装内核 ${version}-tcpboost..."

  case "$PKG_FMT" in
    deb)
      dpkg -i "${tmpdir}"/*.deb
      ;;
    rpm)
      dnf install -y "${tmpdir}"/*.rpm
      ;;
  esac

  rm -rf "$tmpdir"

  # 更新 GRUB
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
  fi

  echo ""
  info "内核 ${version}-tcpboost 安装完成！"
  warn "需要重启服务器才能生效。"
  echo ""
  read -p "是否现在重启？(y/N): " confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    reboot
  fi
}

# 卸载内核
uninstall_kernel() {
  detect_os

  info "当前已安装的 tcpboost 内核:"
  case "$PKG_FMT" in
    deb)
      dpkg -l | grep tcpboost || true
      echo ""
      read -p "确认卸载所有 tcpboost 内核包？(y/N): " confirm
      if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        dpkg -l | grep tcpboost | awk '{print $2}' | xargs dpkg -r
        update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null
        info "已卸载，重启后将恢复原内核。"
      fi
      ;;
    rpm)
      rpm -qa | grep tcpboost || true
      echo ""
      read -p "确认卸载所有 tcpboost 内核包？(y/N): " confirm
      if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        rpm -qa | grep tcpboost | xargs dnf remove -y
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null
        info "已卸载，重启后将恢复原内核。"
      fi
      ;;
  esac
}

# ===== 网络优化 =====

# 备份当前配置
backup_configs() {
  mkdir -p "$BACKUP_DIR"
  local ts
  ts=$(date +%Y%m%d_%H%M%S)

  if [ -f "$SYSCTL_FILE" ]; then
    cp "$SYSCTL_FILE" "${BACKUP_DIR}/99-tcpboost.conf.${ts}"
  fi
  if [ -f "$LIMITS_FILE" ]; then
    cp "$LIMITS_FILE" "${BACKUP_DIR}/tcpboost-limits.conf.${ts}"
  fi

  # 备份 sysctl 当前运行值
  sysctl -a 2>/dev/null > "${BACKUP_DIR}/sysctl-runtime.${ts}"

  info "配置已备份到 ${BACKUP_DIR}/"
}

# Profile 1: 保守方案（≤100Mbps）
apply_profile_conservative() {
  backup_configs

  cat > "$SYSCTL_FILE" <<'EOF'
# TCPBoost Profile: 保守方案 (≤100Mbps)
# 适用: 低配 VPS，小内存，低带宽

# === 拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === TCP Buffer (4MB) ===
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304

# === TCP 连接优化 ===
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
EOF

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
  info "已应用保守方案 (≤100Mbps)"
}

# Profile 2: 均衡方案（1Gbps）
apply_profile_balanced() {
  backup_configs

  cat > "$SYSCTL_FILE" <<'EOF'
# TCPBoost Profile: 均衡方案 (1Gbps)
# 适用: 常规 VPS，通用场景

# === 拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplus

# === TCP Buffer (16MB) ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# === TCP 连接优化 ===
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535

# === 网络队列 ===
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
EOF

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
  info "已应用均衡方案 (1Gbps)"
}

# Profile 3: 激进方案（高性能 + BDP）
apply_profile_aggressive() {
  backup_configs

  # BDP 动态计算
  local mem_total_kb
  mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  local mem_total_mb=$((mem_total_kb / 1024))
  # buffer 上限不超过物理内存的 1/16
  local buf_max_mb=$((mem_total_mb / 16))
  [ "$buf_max_mb" -lt 16 ] && buf_max_mb=16
  [ "$buf_max_mb" -gt 128 ] && buf_max_mb=128
  local buf_max=$((buf_max_mb * 1024 * 1024))

  info "内存: ${mem_total_mb}MB, Buffer 上限: ${buf_max_mb}MB (${buf_max} bytes)"

  cat > "$SYSCTL_FILE" <<EOF
# TCPBoost Profile: 激进方案 (高性能)
# 适用: 高带宽高延迟链路，大内存 VPS
# 生成时间: $(date)
# 内存: ${mem_total_mb}MB, Buffer 上限: ${buf_max_mb}MB

# === 拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplus

# === TCP Buffer (动态 BDP) ===
net.core.rmem_max = ${buf_max}
net.core.wmem_max = ${buf_max}
net.ipv4.tcp_rmem = 4096 131072 ${buf_max}
net.ipv4.tcp_wmem = 4096 65536 ${buf_max}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# === TCP 连接优化 ===
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535

# === 网络队列 ===
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 10000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_recycle = 0

# === Keepalive ===
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
EOF

  # limits.conf 调优
  cat > "$LIMITS_FILE" <<'EOF'
# TCPBoost: 文件描述符限制
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

  # systemd 调优（如果存在 systemd）
  if pidof systemd >/dev/null 2>&1; then
    if [ -f /etc/systemd/system.conf ]; then
      sed -i 's/^#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=65535/' /etc/systemd/system.conf
      sed -i 's/^#DefaultLimitNPROC=.*/DefaultLimitNPROC=65535/' /etc/systemd/system.conf
    fi
    systemctl daemon-reload 2>/dev/null || true
  fi

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
  info "已应用激进方案 (高性能, BDP 动态计算)"
}

# 恢复默认配置
restore_configs() {
  if [ ! -d "$BACKUP_DIR" ]; then
    warn "无备份记录"
    return
  fi

  info "可用备份:"
  ls -la "$BACKUP_DIR/" | tail -n +2

  echo ""
  read -p "确认恢复到默认配置？(y/N): " confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    sysctl --system >/dev/null 2>&1
    info "已恢复默认网络配置"
  fi
}

# ===== 算法管理 =====

show_algorithm_status() {
  echo ""
  echo "=========================================="
  echo "  TCPBoost 当前状态"
  echo "=========================================="

  local current_algo
  current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  local available_algos
  available_algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
  local qdisc
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
  local kernel
  kernel=$(uname -r)

  echo "  当前内核:     ${kernel}"
  echo "  拥塞控制:     ${current_algo}"
  echo "  可用算法:     ${available_algos}"
  echo "  队列调度:     ${qdisc}"

  # 检查是否为 tcpboost 内核
  if echo "$kernel" | grep -q "tcpboost"; then
    echo "  内核状态:     ${GREEN}TCPBoost 内核已加载${NC}"
  else
    echo "  内核状态:     ${YELLOW}未安装 TCPBoost 内核${NC}"
  fi

  echo "=========================================="
  echo ""
}

switch_algorithm() {
  local algo="$1"

  if [ -z "$algo" ]; then
    echo "请指定算法: bbr | bbrplus | brutal | bbr1 | cubic"
    return 1
  fi

  local available
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)

  if ! echo "$available" | grep -qw "$algo"; then
    error "算法 '$algo' 不可用。可用: $available"
    return 1
  fi

  # 设置队列调度
  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
  # 设置拥塞控制
  sysctl -w "net.ipv4.tcp_congestion_control=${algo}" >/dev/null 2>&1

  # 持久化
  if [ -f "$SYSCTL_FILE" ]; then
    sed -i "s/net.ipv4.tcp_congestion_control = .*/net.ipv4.tcp_congestion_control = ${algo}/" "$SYSCTL_FILE"
  else
    echo "net.core.default_qdisc = fq" > "$SYSCTL_FILE"
    echo "net.ipv4.tcp_congestion_control = ${algo}" >> "$SYSCTL_FILE"
  fi

  info "已切换到: ${algo}"
  info "队列调度: fq"
  info "已持久化到 ${SYSCTL_FILE}"
}

# ===== 菜单系统 =====

show_banner() {
  clear
  echo -e "${CYAN}"
  cat << 'BANNER'
  ╔═══════════════════════════════════════╗
  ║       TCPBoost v1.0.0-dev            ║
  ║   Linux TCP 网络加速一键脚本          ║
  ║   内核: 6.12 LTS (BBRv3/Plus/Brutal) ║
  ╚═══════════════════════════════════════╝
BANNER
  echo -e "${NC}"
}

show_menu() {
  show_banner
  show_algorithm_status

  echo "  1) 安装 TCPBoost 内核 (6.12 LTS)"
  echo "  2) 网络优化 — 保守方案 (≤100Mbps)"
  echo "  3) 网络优化 — 均衡方案 (1Gbps)"
  echo "  4) 网络优化 — 激进方案 (高性能)"
  echo "  5) 切换拥塞控制算法"
  echo "  6) 恢复默认配置"
  echo "  7) 卸载 TCPBoost 内核"
  echo "  0) 退出"
  echo ""
  read -p "  请选择 [0-7]: " choice

  case "$choice" in
    1) install_kernel ;;
    2) apply_profile_conservative ;;
    3) apply_profile_balanced ;;
    4) apply_profile_aggressive ;;
    5) menu_switch_algorithm ;;
    6) restore_configs ;;
    7) uninstall_kernel ;;
    0) exit 0 ;;
    *) error "无效选择" ;;
  esac
}

menu_switch_algorithm() {
  echo ""
  echo "  可用算法:"
  echo "  1) bbr     — BBRv3 (推荐通用)"
  echo "  2) bbrplus — BBRPlus (高丢包优化)"
  echo "  3) brutal  — TCP Brutal (Hysteria2 专用)"
  echo "  4) bbr1    — BBRv1 (兼容性)"
  echo "  5) cubic   — Cubic (公平性好)"
  echo ""
  read -p "  选择算法 [1-5]: " algo_choice

  case "$algo_choice" in
    1) switch_algorithm bbr ;;
    2) switch_algorithm bbrplus ;;
    3) switch_algorithm brutal ;;
    4) switch_algorithm bbr1 ;;
    5) switch_algorithm cubic ;;
    *) error "无效选择" ;;
  esac
}

# ===== 入口 =====

main() {
  check_root

  # 命令行参数模式
  case "${1:-}" in
    install)  install_kernel ;;
    optimize) apply_profile_balanced ;;
    status)   show_algorithm_status ;;
    switch)
      if [ -z "${2:-}" ]; then
        error "用法: $0 switch <bbr|bbrplus|brutal|bbr1|cubic>"
        exit 1
      fi
      switch_algorithm "$2"
      ;;
    uninstall) uninstall_kernel ;;
    restore)  restore_configs ;;
    *)
      # 交互式菜单
      while true; do
        show_menu
        echo ""
        read -p "按 Enter 继续..."
      done
      ;;
  esac
}

main "$@"
