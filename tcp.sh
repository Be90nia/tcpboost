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
KERNEL_NAME="tcpboost"
CONF_DIR="/etc/tcpboost"
BACKUP_DIR="/etc/tcpboost/backup"
SYSCTL_FILE="/etc/sysctl.d/99-tcpboost.conf"
LIMITS_FILE="/etc/security/limits.d/tcpboost.conf"

# ===== 镜像源配置 =====
# GitHub 加速镜像列表（国内环境自动切换）
# 格式: 镜像前缀 + 原始 GitHub URL
GH_MIRRORS=(
  "https://gh-proxy.com"
  "https://ghfast.top"
  "https://ghp.ci"
)

# GitHub 直连 URL 模板
GH_RELEASE_BASE="https://github.com/${REPO}/releases/download"
GH_RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

# 网络环境标记（detect_network 中设置）
NET_MODE="direct"

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

# ===== 网络环境检测 =====

# 判断是否为国内网络环境
# 策略: 优先测试 GitHub 直连 → 回退 IP 地理位置判断
is_china() {
  # 1. 测试 GitHub 直连可达性（5 秒超时）
  if command -v curl >/dev/null 2>&1; then
    if curl -sf --connect-timeout 5 --max-time 8 https://github.com >/dev/null 2>&1; then
      return 1  # GitHub 可达，非国内（或已有代理）
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=8 -O /dev/null https://github.com >/dev/null 2>&1; then
      return 1
    fi
  fi

  # 2. GitHub 不可达，进一步确认（避免代理环境误判）
  # 测试国内可达站点，若可达则确认国内环境
  if command -v curl >/dev/null 2>&1; then
    if curl -sf --connect-timeout 3 --max-time 5 https://mirrors.aliyun.com >/dev/null 2>&1; then
      return 0  # 国内镜像可达 + GitHub 不可达 = 国内环境
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=5 -O /dev/null https://mirrors.aliyun.com >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 3. 两者都不可达，可能是离线环境，保守判定为国内
  return 0
}

# 检测并设置网络环境
detect_network() {
  if is_china; then
    NET_MODE="mirror"
    info "检测到国内网络环境，将使用加速镜像"
  else
    NET_MODE="direct"
    info "检测到国际网络环境，将直连 GitHub"
  fi
}

# ===== 下载函数 =====

# 单次下载尝试（curl 优先，回退 wget）
_dl_once() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 2 --retry-delay 3 --connect-timeout 10 --max-time 300 -o "$output" "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=300 --tries=2 -O "$output" "$url" 2>/dev/null
  else
    error "需要 curl 或 wget"
    return 1
  fi
}

# 下载函数 — 支持 GitHub URL 自动镜像回退
# 对于 github.com 和 raw.githubusercontent.com 的 URL，自动构建镜像链
# 用法: dl <url> <output_path>
dl() {
  local url="$1" output="$2"

  # 构建 URL 尝试列表
  local -a urls=()
  urls+=("$url")

  # 如果是 GitHub URL 且为镜像模式，添加加速镜像
  if [ "$NET_MODE" = "mirror" ]; then
    case "$url" in
      https://github.com/*|https://raw.githubusercontent.com/*)
        for mirror in "${GH_MIRRORS[@]}"; do
          urls+=("${mirror}/${url}")
        done
        ;;
    esac
  fi

  # 依次尝试各 URL
  local tried=0
  for try_url in "${urls[@]}"; do
    tried=$((tried + 1))
    if [ $tried -eq 1 ]; then
      info "下载: $(basename "$output")"
    else
      warn "主源失败，尝试镜像 [$((tried - 1))/${#GH_MIRRORS[@]}]: ${try_url%%/https*}..."
    fi

    if _dl_once "$try_url" "$output"; then
      # 验证文件非空
      if [ -s "$output" ]; then
        return 0
      fi
      warn "下载文件为空，尝试下一个源"
      rm -f "$output"
    fi
  done

  error "所有下载源均失败: $(basename "$output")"
  return 1
}

# 获取 GitHub Release 下载 URL
# 用法: get_release_url <version> <filename>
get_release_url() {
  local version="$1" filename="$2"
  echo "${GH_RELEASE_BASE}/v${version}-tcpboost/${filename}"
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
  local -a api_urls=(
    "https://github.com/${REPO}/releases/latest"
  )

  # 国内环境添加镜像
  if [ "$NET_MODE" = "mirror" ]; then
    for mirror in "${GH_MIRRORS[@]}"; do
      api_urls+=("${mirror}/https://github.com/${REPO}/releases/latest")
    done
  fi

  for api_url in "${api_urls[@]}"; do
    version=$(curl -sf --connect-timeout 10 --max-time 15 -L "$api_url" 2>/dev/null | grep -oP 'tag/\Kv[0-9.]+' | head -1 | sed 's/^v//')
    if [ -n "$version" ]; then
      break
    fi
  done

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
      local files="linux-headers-${version}-tcpboost_${version}-tcpboost-1_amd64.deb
                   linux-image-${version}-tcpboost_${version}-tcpboost-1_amd64.deb
                   linux-libc-dev_${version}-tcpboost-1_amd64.deb"
      for f in $files; do
        dl "$(get_release_url "$version" "$f")" "${tmpdir}/${f}" || {
          error "下载失败: $f"
          rm -rf "$tmpdir"
          exit 1
        }
      done
      ;;
    rpm)
      local files="linux-headers-${version}-tcpboost-${version}_tcpboost-1.x86_64.rpm
                   linux-image-${version}-tcpboost-${version}_tcpboost-1.x86_64.rpm"
      for f in $files; do
        dl "$(get_release_url "$version" "$f")" "${tmpdir}/${f}" || {
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

# BBRPlusV3 参数设置（科学上网场景最优配置）
# 基于跨太平洋真实链路测试验证 (tsunami-v3 优化内核):
#   loss_thresh=50%: 高丢包链路下保持发送速率
#   beta=90%: 极轻微降速（仅降 10%）
#   min_pacing_rate: 保底 pacing rate，防 STARTUP 早退
# 测试结果 (VPS 199.115.231.188, RTT ~161ms):
#   上传单流: 79.8 Mbps (cubic 85.7)
#   下载单流: 26.1 Mbps (cubic 仅 0.3, 提升 87x)
apply_bbrplusv3_params() {
  local param_dir="/sys/module/tcp_bbrplusv3/parameters"
  if [ ! -d "$param_dir" ]; then
    modprobe tcp_bbrplusv3 2>/dev/null || true
  fi
  if [ ! -d "$param_dir" ]; then
    warn "tcp_bbrplusv3 模块不可用，跳过参数设置（内核未含 BBRPlusV3？）"
    return 0
  fi

  # 设置 profile = aggressive (2)
  echo 2 > "$param_dir/profile" 2>/dev/null || true

  # 50%/90% 激进参数 (BBR_UNIT=256)
  echo 128 > "$param_dir/loss_thresh" 2>/dev/null || true
  echo 230 > "$param_dir/beta" 2>/dev/null || true

  # min_pacing_rate: 默认关闭(0)
  # 用户可通过 set_min_pacing_rate 设置（推荐 50Mbps = 6250000 bytes/sec）
  if [ -w "$param_dir/min_pacing_rate" ]; then
    local current_mpr
    current_mpr=$(cat "$param_dir/min_pacing_rate" 2>/dev/null || echo 0)
    # 保持已设置的值，不覆盖
    [ -z "$current_mpr" ] && echo 0 > "$param_dir/min_pacing_rate" 2>/dev/null || true
  fi

  # 持久化到配置文件
  mkdir -p "$CONF_DIR"
  cat > "$CONF_DIR/bbrplusv3.conf" <<'EOF'
# BBRPlusV3 科学上网最优参数 (tsunami-v3 内核测试验证)
# profile=2(aggressive), loss_thresh=50%, beta=90%
profile=2
loss_thresh=128
beta=230
EOF

  info "BBRPlusV3 参数已设置 (loss_thresh=50%, beta=90%)"
}

# 设置 min_pacing_rate（保底速率，防单流 STARTUP 早退）
# 用法: set_min_pacing_rate <Mbps>
#   推荐: set_min_pacing_rate 50  (50 Mbps VPS)
#         set_min_pacing_rate 100 (100 Mbps VPS)
#         set_min_pacing_rate 0    (关闭)
set_min_pacing_rate() {
  local mbps="${1:-0}"
  local param_dir="/sys/module/tcp_bbrplusv3/parameters"

  if [ ! -w "$param_dir/min_pacing_rate" ]; then
    warn "min_pacing_rate 参数不可用（需要 tsunami-v3 优化内核）"
    return 1
  fi

  # Mbps → bytes/sec
  local bps=$((mbps * 1000000 / 8))
  echo "$bps" > "$param_dir/min_pacing_rate" 2>/dev/null

  if [ "$mbps" -eq 0 ]; then
    info "min_pacing_rate 已关闭"
  else
    info "min_pacing_rate 已设为 ${mbps} Mbps (${bps} bytes/sec)"
    echo "  下载方向单流性能预计提升 3x+ (测试: 8.5→26.1 Mbps)"
  fi

  # 持久化
  if [ -f "$CONF_DIR/bbrplusv3.conf" ]; then
    sed -i "/^min_pacing_rate/d" "$CONF_DIR/bbrplusv3.conf"
    echo "min_pacing_rate=$bps" >> "$CONF_DIR/bbrplusv3.conf"
  fi
}

# 开机自动应用 bbrplusv3 参数
setup_bbrplusv3_persistent() {
  cat > /etc/systemd/system/tcpboost-bbrplusv3.service <<'EOF'
[Unit]
Description=TCPBoost BBRPlusV3 Parameters
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'PARAM_DIR=/sys/module/tcp_bbrplusv3/parameters; [ -d "$PARAM_DIR" ] && echo 2 > $PARAM_DIR/profile && echo 128 > $PARAM_DIR/loss_thresh && echo 230 > $PARAM_DIR/beta && echo 1 > $PARAM_DIR/gc_enable 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable tcpboost-bbrplusv3 2>/dev/null || true
}

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
net.ipv4.tcp_congestion_control = bbrplusv3

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

# === 锐速风格 TCP 栈优化 ===
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_limit_output_bytes = $((buf_max / 4))

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

  # BBRPlusV3 最优参数（科学上网场景测试验证）
  apply_bbrplusv3_params
  setup_bbrplusv3_persistent

  # 锐速风格：增大初始拥塞窗口（默认 10 → 32）
  local DEF_ROUTE
  DEF_ROUTE=$(ip route show default 2>/dev/null | head -1)
  if [ -n "$DEF_ROUTE" ]; then
    ip route change $DEF_ROUTE initcwnd 32 initrwnd 32 2>/dev/null && \
      info "初始拥塞窗口已设为 32 (initcwnd/initrwnd)" || true
  fi

  info "已应用激进方案 (bbrplusv3 + 50%/90% 参数 + 锐速风格 TCP 栈优化)"
  echo ""
  echo -e "  ${CYAN}无感切换已启用:${NC}"
  echo "    xray / sing-box / 通用网络 → 自动使用 BBRPlusV3"
  echo "    sing-box 如需确定性带宽 → 配置 multiplex.brutal"
  echo ""
  echo -e "  ${YELLOW}建议:${NC} 设置 min_pacing_rate 进一步提升下载性能"
  echo "    ./tcp.sh set-min-pacing-rate 50  (50 Mbps VPS)"
  echo "    测试数据: 下载单流 8.5→26.1 Mbps (+207%)"
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

# ===== 代理检测与智能推荐 =====

# 检测 VPS 上运行的代理软件
# 返回值通过全局变量:
#   PROXY_XRAY="yes"/"no"
#   PROXY_SINGBOX="yes"/"no"
#   PROXY_HY2="yes"/"no"
#   PACKET_LOSS="low"/"medium"/"high"
detect_proxy() {
  PROXY_XRAY="no"
  PROXY_SINGBOX="no"
  PROXY_HY2="no"
  PACKET_LOSS="low"

  # 1. 检测 xray 进程
  if pgrep -x "xray" >/dev/null 2>&1; then
    PROXY_XRAY="yes"
    info "检测到 xray 进程"
  fi

  # 2. 检测 sing-box 进程
  if pgrep -x "sing-box" >/dev/null 2>&1; then
    PROXY_SINGBOX="yes"
    info "检测到 sing-box 进程"

    # 3. 检测 sing-box 配置中是否包含 hysteria2 协议
    # 尝试找到配置文件路径
    local config_path=""
    local -a candidates=(
      "/etc/sing-box/config.json"
      "/usr/local/etc/sing-box/config.json"
      "/etc/sing-box/config.jsonc"
    )

    # 从进程参数中提取配置路径
    local proc_args
    proc_args=$(pgrep -a -x "sing-box" 2>/dev/null | head -1) || true
    if echo "$proc_args" | grep -qE '\-[cC]\s+\S+'; then
      local arg_config
      arg_config=$(echo "$proc_args" | grep -oE '\-[cC]\s+\S+' | awk '{print $2}')
      [ -n "$arg_config" ] && candidates=("$arg_config" "${candidates[@]}")
    fi

    # 搜索配置文件中的 hysteria2 标识
    for cfg in "${candidates[@]}"; do
      if [ -f "$cfg" ]; then
        config_path="$cfg"
        break
      fi
    done

    if [ -n "$config_path" ] && [ -f "$config_path" ]; then
      # 检查配置中是否有 hysteria2 类型
      if grep -qiE '"type"\s*:\s*"hysteria2"' "$config_path" 2>/dev/null; then
        PROXY_HY2="yes"
        info "检测到 sing-box 配置包含 Hysteria2 协议"
      fi
    else
      # 找不到配置文件时，检查已加载的内核模块判断
      # 如果 tcp_brutal 模块已加载，很可能是在用 Hy2
      if lsmod 2>/dev/null | grep -q "tcp_brutal"; then
        PROXY_HY2="yes"
        warn "无法定位 sing-box 配置文件，但 tcp_brutal 模块已加载，推测使用 Hysteria2"
      fi
    fi
  fi

  # 4. 快速丢包检测 — ping 默认网关 20 次
  local gateway
  gateway=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
  if [ -n "$gateway" ]; then
    local loss_pct
    loss_pct=$(ping -c 20 -W 2 "$gateway" 2>/dev/null | grep -oE '[0-9]+%' | tail -1 | tr -d '%')
    if [ -n "$loss_pct" ]; then
      if [ "$loss_pct" -ge 5 ]; then
        PACKET_LOSS="high"
        warn "丢包率 ${loss_pct}% (≥5%)，线路质量较差"
      elif [ "$loss_pct" -ge 1 ]; then
        PACKET_LOSS="medium"
        info "丢包率 ${loss_pct}% (1-5%)，线路质量一般"
      else
        PACKET_LOSS="low"
        info "丢包率 ${loss_pct}% (<1%)，线路质量良好"
      fi
    fi
  else
    # 无法获取网关，跳过丢包检测
    info "无法检测默认网关，跳过丢包测试"
  fi
}

# 智能推荐拥塞控制算法
# 检测代理环境后推荐最合适的算法并确认切换
smart_recommend() {
  info "正在检测代理环境..."
  detect_proxy

  echo ""
  echo -e "  ${CYAN}检测结果:${NC}"
  echo "  xray:      ${PROXY_XRAY}"
  echo "  sing-box:  ${PROXY_SINGBOX}"
  echo "  Hysteria2: ${PROXY_HY2}"
  echo "  丢包等级:  ${PACKET_LOSS}"
  echo ""

  local recommend_algo=""
  local recommend_reason=""

  # 推荐逻辑 — 代理场景统一推荐 bbrplusv3（30%/80%最优参数）
  if [ "$PROXY_HY2" = "yes" ]; then
    if modprobe tcp_brutal 2>/dev/null; then
      info "已加载 tcp_brutal 内核模块（sing-box Hy2 socket 将自动使用 brutal）"
    else
      warn "tcp_brutal 模块加载失败，Hysteria2 可能无法使用 TCP Brutal"
    fi
    recommend_algo="bbrplusv3"
    recommend_reason="检测到 Hysteria2 + 代理场景, brutal 供 Hy2 per-connection, 全局 BBRPlusV3(30%/80%) 最优"
  elif [ "$PROXY_XRAY" = "yes" ] || [ "$PROXY_SINGBOX" = "yes" ]; then
    # xray / sing-box 代理场景 → bbrplusv3
    recommend_algo="bbrplusv3"
    if [ "$PACKET_LOSS" = "high" ]; then
      recommend_reason="代理场景 + 高丢包(≥5%), BBRPlusV3(30%/80%) 单流111M/多流222M, xray/sing-box 自动使用"
    elif [ "$PACKET_LOSS" = "medium" ]; then
      recommend_reason="代理场景 + 中丢包(1-5%), BBRPlusV3(30%/80%) 抗丢包+高吞吐, xray/sing-box 自动使用"
    else
      recommend_reason="代理场景 + 低丢包, BBRPlusV3(30%/80%) 均衡最优, xray/sing-box 自动使用"
    fi
  elif [ "$PACKET_LOSS" = "high" ]; then
    # 高丢包无代理 → BBRPlusV3 抗丢包
    recommend_algo="bbrplusv3"
    recommend_reason="高丢包(≥5%), BBRPlusV3(30%/80%) 抗丢包性能提升 3-4 倍"
  elif [ "$PACKET_LOSS" = "medium" ]; then
    recommend_algo="bbrplusv3"
    recommend_reason="丢包 1-5%, BBRPlusV3 在丢包场景下优于 BBRv3"
  else
    recommend_algo="bbr"
    recommend_reason="未检测到代理, 低丢包, BBRv3 公平性最优"
  fi

  echo -e "  ${GREEN}推荐算法: ${recommend_algo}${NC}"
  echo -e "  原因: ${recommend_reason}"
  echo ""

  # 无感切换说明
  if [ "$recommend_algo" = "bbrplusv3" ]; then
    echo -e "  ${CYAN}无感切换说明:${NC}"
    if [ "$PROXY_XRAY" = "yes" ]; then
      echo "    xray:      自动使用 BBRPlusV3, 无需额外配置"
    fi
    if [ "$PROXY_SINGBOX" = "yes" ]; then
      echo "    sing-box:  自动使用 BBRPlusV3"
      echo "               如需确定性带宽, 在 sing-box 配置中启用 multiplex.brutal"
    fi
    echo "    通用网络:  自动使用 BBRPlusV3"
    echo ""
  fi

  read -p "  是否切换到 ${recommend_algo}？(Y/n): " confirm
  if [ "$confirm" != "n" ] && [ "$confirm" != "N" ]; then
    switch_algorithm "$recommend_algo"
    info "智能推荐完成"
  else
    info "已跳过"
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

  # 显示 BBRPlusV3 参数（如果使用中）
  if [ "$current_algo" = "bbrplusv3" ]; then
    local param_dir="/sys/module/tcp_bbrplusv3/parameters"
    if [ -d "$param_dir" ]; then
      local lt beta mpr gc
      lt=$(cat "$param_dir/loss_thresh" 2>/dev/null || echo "?")
      beta=$(cat "$param_dir/beta" 2>/dev/null || echo "?")
      mpr=$(cat "$param_dir/min_pacing_rate" 2>/dev/null || echo "?")
      gc=$(cat "$param_dir/gc_enable" 2>/dev/null || echo "?")
      local lt_pct=$((lt * 100 / 256))
      local beta_pct=$((beta * 100 / 256))
      local mpr_mb=$((mpr * 8 / 1000000))
      echo "  loss_thresh:    ${lt} (${lt_pct}%)"
      echo "  beta:           ${beta} (${beta_pct}%)"
      if [ "$mpr" = "?" ] || [ "$mpr" = "0" ]; then
        echo "  min_pacing_rate: off"
      else
        echo "  min_pacing_rate: ${mpr} (${mpr_mb} Mbps)"
      fi
      if [ "$gc" = "1" ]; then
        echo "  BBR-GC:         on (adaptive pacing gain)"
      elif [ "$gc" = "0" ]; then
        echo "  BBR-GC:         off"
      else
        echo "  BBR-GC:         ${gc}"
      fi
    fi
  fi

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
    echo "请指定算法: bbr | bbrplusv3 | bbrplus | brutal | cubic"
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

  # 切换到 bbrplusv3 时自动设置最优参数（无感切换）
  if [ "$algo" = "bbrplusv3" ]; then
    apply_bbrplusv3_params
    setup_bbrplusv3_persistent
  fi

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
  echo "  5) 智能推荐算法 (自动检测代理环境)"
  echo "  6) 手动切换算法"
  echo "  7) 恢复默认配置"
  echo "  8) 卸载 TCPBoost 内核"
  echo "  0) 退出"
  echo ""
  read -p "  请选择 [0-8]: " choice

  case "$choice" in
    1) install_kernel ;;
    2) apply_profile_conservative ;;
    3) apply_profile_balanced ;;
    4) apply_profile_aggressive ;;
    5) smart_recommend ;;
    6) menu_switch_algorithm ;;
    7) restore_configs ;;
    8) uninstall_kernel ;;
    0) exit 0 ;;
    *) error "无效选择" ;;
  esac
}

menu_switch_algorithm() {
  echo ""
  echo "  可用算法:"
  echo "  1) bbr         — BBRv3 (推荐通用)"
  echo "  2) bbrplusv3   — BBRPlusV3 (高丢包首选, BBRv3+激进探测)"
  echo "  3) bbrplus     — BBRPlus (高丢包优化, 原版)"
  echo "  4) brutal      — TCP Brutal (Hysteria2 专用)"
  echo "  5) cubic       — Cubic (公平性好)"
  echo ""
  read -p "  选择算法 [1-5]: " algo_choice

  case "$algo_choice" in
    1) switch_algorithm bbr ;;
    2) switch_algorithm bbrplusv3 ;;
    3) switch_algorithm bbrplus ;;
    4) switch_algorithm brutal ;;
    5) switch_algorithm cubic ;;
    *) error "无效选择" ;;
  esac
}

# ===== 入口 =====

main() {
  check_root
  detect_network

  # 命令行参数模式
  case "${1:-}" in
    install)  install_kernel ;;
    optimize) apply_profile_balanced ;;
    auto)     smart_recommend ;;
    status)   show_algorithm_status ;;
    switch)
      if [ -z "${2:-}" ]; then
        error "用法: $0 switch <bbr|bbrplusv3|bbrplus|brutal|cubic>"
        exit 1
      fi
      switch_algorithm "$2"
      ;;
    uninstall) uninstall_kernel ;;
    restore)  restore_configs ;;
    set-min-pacing-rate)
      if [ -z "${2:-}" ]; then
        echo "用法: $0 set-min-pacing-rate <Mbps>"
        echo "  推荐: 50 (50Mbps VPS), 100 (100Mbps VPS), 0 (关闭)"
        exit 1
      fi
      set_min_pacing_rate "$2"
      ;;
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
