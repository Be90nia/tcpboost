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

  KERNEL_TMPDIR=$(mktemp -d)

  info "下载 TCPBoost 内核 ${version}..."

  case "$PKG_FMT" in
    deb)
      local files="linux-image-${version}-tcpboost_${version}-1_amd64.deb
                   linux-libc-dev_${version}-1_amd64.deb"
      for f in $files; do
        dl "$(get_release_url "$version" "$f")" "${KERNEL_TMPDIR}/${f}" || {
          warn "下载失败: $f（可能不存在，跳过）"
        }
      done
      # 验证至少有 linux-image
      if ! ls "${KERNEL_TMPDIR}"/linux-image-*.deb >/dev/null 2>&1; then
        error "下载失败: linux-image deb 包"
        rm -rf "$KERNEL_TMPDIR"
        exit 1
      fi
      ;;
    rpm)
      local files="kernel-${version}_tcpboost-2.x86_64.rpm
                   kernel-devel-${version}_tcpboost-2.x86_64.rpm"
      for f in $files; do
        dl "$(get_release_url "$version" "$f")" "${KERNEL_TMPDIR}/${f}" || {
          warn "下载失败: $f（可能不存在，跳过）"
        }
      done
      if ! ls "${KERNEL_TMPDIR}"/kernel-*.rpm >/dev/null 2>&1; then
        error "下载失败: kernel rpm 包"
        rm -rf "$KERNEL_TMPDIR"
        exit 1
      fi
      ;;
  esac

  echo "$KERNEL_TMPDIR"
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

  download_kernel "$version"

  info "安装内核 ${version}-tcpboost..."

  case "$PKG_FMT" in
    deb)
      dpkg -i "${KERNEL_TMPDIR}"/*.deb
      ;;
    rpm)
      dnf install -y "${KERNEL_TMPDIR}"/*.rpm
      ;;
  esac

  rm -rf "$KERNEL_TMPDIR"

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

# 清理多余内核（确认 tcpboost 能用后删除所有其他内核）
cleanup_kernels() {
  local current_kernel
  current_kernel=$(uname -r)

  info "扫描已安装内核..."
  echo ""
  echo "  当前运行: ${GREEN}${current_kernel}${NC}"
  echo ""
  echo "  已安装内核:"
  echo "  ─────────────────────────────────────────"

  local kernel_list=()
  for vmlinuz in /boot/vmlinuz-*; do
    [ -f "$vmlinuz" ] || continue
    local kver
    kver=$(basename "$vmlinuz" | sed 's/vmlinuz-//')
    kernel_list+=("$kver")
    if [ "$kver" = "$current_kernel" ]; then
      echo "  ${GREEN}[运行]${NC}  $kver"
    else
      echo "  ${YELLOW}[可删]${NC}  $kver"
    fi
  done
  echo "  ─────────────────────────────────────────"

  # 安全检查 1: 当前必须运行 tcpboost 内核
  if ! echo "$current_kernel" | grep -q "tcpboost"; then
    error "当前未运行 tcpboost 内核！"
    echo "  请先安装 tcpboost 内核并重启成功后，再执行清理。"
    return 1
  fi
  info "安全检查 1/2: 当前正在运行 tcpboost 内核 ✓"

  # 安全检查 2: bbrplusv3 可用（证明内核功能正常）
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbrplusv3"; then
    error "bbrplusv3 不可用！tcpboost 内核可能有问题，拒绝清理。"
    return 1
  fi
  info "安全检查 2/2: bbrplusv3 算法可用，内核功能正常 ✓"
  echo ""

  # 收集要删除的内核（除了当前运行的）
  local removable=()
  for kver in "${kernel_list[@]}"; do
    [ "$kver" != "$current_kernel" ] && removable+=("$kver")
  done

  if [ ${#removable[@]} -eq 0 ]; then
    info "没有其他内核需要清理"
    return 0
  fi

  warn "即将删除以下 ${#removable[@]} 个内核:"
  for kver in "${removable[@]}"; do
    echo "    ✗ $kver"
  done
  echo "  保留: $current_kernel"
  echo ""
  read -p "  确认清理？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    info "已取消"
    return 0
  fi

  # 执行清理
  for kver in "${removable[@]}"; do
    info "删除 $kver ..."
    local deleted=false

    # 尝试 apt-get (Debian/Ubuntu) — apt 自动处理 meta 包依赖
    if command -v apt-get >/dev/null 2>&1 && \
       dpkg -l "linux-image-$kver" >/dev/null 2>&1; then
      # 先检查是否有 meta 包依赖（linux-image-amd64 等）
      local meta_pkg
      meta_pkg=$(dpkg -S "linux-image-$kver" 2>/dev/null | grep -oP '^[^:]+(?=:)' | head -1)
      if [ -n "$meta_pkg" ] && echo "$meta_pkg" | grep -q "^linux-image-"; then
        info "  检测到 meta 包依赖 ($meta_pkg)，先删除 meta 包..."
        apt-get purge -y "$meta_pkg" 2>/dev/null || true
      fi
      # 现在 purge 内核包
      if apt-get purge -y "linux-image-$kver" 2>/dev/null; then
        deleted=true
      fi
    fi

    # 尝试 dnf (CentOS/Fedora)
    if [ "$deleted" = false ] && command -v dnf >/dev/null 2>&1 && \
       rpm -q "kernel-$kver" >/dev/null 2>&1; then
      dnf remove -y "kernel-$kver" 2>/dev/null && deleted=true
    fi

    # Fallback: 直接删除文件（如果包管理器失败或找不到包）
    if [ "$deleted" = false ] || [ -f "/boot/vmlinuz-$kver" ]; then
      info "  包管理器未完全删除，fallback 到强制 rm..."
      rm -rf "/lib/modules/$kver" 2>/dev/null || true
      rm -f "/boot/vmlinuz-$kver" "/boot/initrd.img-$kver" \
            "/boot/config-$kver" "/boot/System.map-$kver" 2>/dev/null || true
    fi

    # 验证删除
    if [ -f "/boot/vmlinuz-$kver" ]; then
      error "未能删除 $kver，请手动执行: apt purge linux-image-$kver"
    else
      info "  $kver 已删除 ✓"
    fi
  done

  info "更新 GRUB..."
  update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true

  echo ""
  info "清理完成！剩余内核:"
  ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-|    |' || echo "    (无)"
}

# 生成 BBRPlusV3 systemd service 文件（共享函数）
# 修复 4 个历史 Bug:
#   1. Boot竞态: 模块未加载时 [ -d "$PD" ] 跳过所有参数 → 加入 modprobe + 重试
#   2. 静默失败: 2>/dev/null || true 隐藏错误 → 移除，错误输出到 journal
#   3. profile重置: 写 profile=2 会重置所有参数为 aggressive 默认值 → 不写 profile
#   4. service覆盖: 三处 service 模板不同步 → 统一入口
#
# 用法: write_bbrplusv3_service [key=value ...]
#   覆盖参数: min_pacing_rate=<bps> probe_rtt_win_ms=<ms> probe_rtt_mode_ms=<ms> pacing_gain_down=<n>
#   不传覆盖参数 = aggressive 基线 (beta=76, loss_thresh=38, ...)
write_bbrplusv3_service() {
  # 基线参数 (aggressive 优化覆盖)
  local s_loss_thresh=8
  local s_beta=76
  local s_pacing_gain_down=217
  local s_probe_rtt_mode_ms=100
  local s_probe_rtt_win_ms=5000
  local s_gc_enable=0
  local s_gc_base_down=217
  local s_min_pacing_rate=""
  local description="TCPBoost BBRPlusV3 Parameters"

  # 解析覆盖参数
  local override
  for override in "$@"; do
    case "$override" in
      min_pacing_rate=*)   s_min_pacing_rate="${override#min_pacing_rate=}" ;;
      probe_rtt_win_ms=*)  s_probe_rtt_win_ms="${override#probe_rtt_win_ms=}" ;;
      probe_rtt_mode_ms=*) s_probe_rtt_mode_ms="${override#probe_rtt_mode_ms=}" ;;
      pacing_gain_down=*)  s_pacing_gain_down="${override#pacing_gain_down=}" ;;
      gc_base_down=*)      s_gc_base_down="${override#gc_base_down=}" ;;
      description=*)       description="${override#description=}" ;;
    esac
  done

  # 构建 ExecStart 参数写入链
  # 设计要点:
  #   - 用 ; 分隔（非 &&），单个参数失败不影响其余参数
  #   - 不写 profile：写 profile=N 会触发内核重置所有参数为 profile 默认值
  #   - modprobe + 重试：确保 sysfs 参数目录存在
  #   - 不吞错误：失败信息输出到 systemd journal
  local params="loss_thresh=${s_loss_thresh} beta=${s_beta} pacing_gain_down=${s_pacing_gain_down} probe_rtt_mode_ms=${s_probe_rtt_mode_ms} probe_rtt_win_ms=${s_probe_rtt_win_ms} gc_enable=${s_gc_enable} gc_base_down=${s_pacing_gain_down}"
  if [ -n "$s_min_pacing_rate" ]; then
    params="${params} min_pacing_rate=${s_min_pacing_rate}"
    description="TCPBoost BBRPlusV3 Parameters (with min_pacing_rate)"
  fi

  # 生成参数写入脚本：retry modprobe → 逐个写入
  local exec_script='PD=/sys/module/tcp_bbrplusv3/parameters; '
  exec_script+='for i in 1 2 3; do [ -d "$PD" ] && break; /sbin/modprobe tcp_bbrplusv3 2>/dev/null; sleep 1; done; '
  exec_script+='[ -d "$PD" ] || { echo "tcpboost: tcp_bbrplusv3 module sysfs not found after 3 attempts" >&2; exit 1; }; '

  # 逐个参数写入（; 分隔，独立执行）
  local kv
  for kv in $params; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    exec_script+="echo ${v} > \$PD/${k}; "
  done
  # 移除末尾多余空格
  exec_script="${exec_script% }"

  cat > /etc/systemd/system/tcpboost-bbrplusv3.service <<EOF
[Unit]
Description=${description}
After=network-online.target systemd-modules-load.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '${exec_script}'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || warn "systemctl daemon-reload 失败"
  systemctl enable tcpboost-bbrplusv3 || warn "systemctl enable 失败"
}

# BBRPlusV3 参数设置（科学上网平衡优化配置）
# 基于 BBRv3 核心机制 + 跨太平洋链路断流根因分析:
#   保留: STARTUP 激进探测(startup_pacing_gain=2.885, cwnd_gain=2.5)
#   保留: PROBE_BW UP 激进(pacing_gain_up=1.5) — 跨太平洋带宽探测优势
#   保留: min_rtt_win=20s — 长 RTT 链路 min_rtt 估值稳定
#   调整: loss_thresh=15% — 容忍跨太平洋正常丢包(1-5%)，真实拥塞(>15%)降速
#   调整: beta=30% — BBRPlus 经典值，丢包后恢复 70%
#   调整: pacing_gain_down=0.85 — 减少下载速率周期性波动(原 0.75)
#   调整: probe_rtt 每5s/100ms — 减少游戏延迟峰值频率和深度(原 2.5s/50ms)
#   测试基线 (跨太平洋链路, RTT ~161ms): vs cubic 提升 10-100x
apply_bbrplusv3_params() {
  local param_dir="/sys/module/tcp_bbrplusv3/parameters"
  if [ ! -d "$param_dir" ]; then
    modprobe tcp_bbrplusv3 2>/dev/null || true
  fi
  if [ ! -d "$param_dir" ]; then
    warn "tcp_bbrplusv3 模块不可用，跳过参数设置（内核未含 BBRPlusV3？）"
    return 0
  fi

  # 1. aggressive profile 作为基线（保留 STARTUP/PROBE_BW UP 激进探测优势）
  echo 2 > "$param_dir/profile" || warn "写入 profile 失败"

  # 2. 平衡优化覆盖（在 aggressive 基线上调整稳定性参数）
  # 注：新 aggressive profile 已包含这些值，覆盖作为双保险
  # loss_thresh: 3% (8/256) — 匹配新aggressive默认，CF/SSH安全
  echo 8 > "$param_dir/loss_thresh" || warn "写入 loss_thresh 失败"
  # beta: 30% (76/256) — 匹配新aggressive默认，BBRPlus 经典值
  echo 76 > "$param_dir/beta" || warn "写入 beta 失败"
  # pacing_gain_down: 0.85 (217/256) — 匹配新aggressive默认
  echo 217 > "$param_dir/pacing_gain_down" || warn "写入 pacing_gain_down 失败"
  # gc_base_down: 同步 pacing_gain_down (C7修复：参数覆盖时GC基准值保持一致)
  if [ -w "$param_dir/gc_base_down" ]; then
    echo 217 > "$param_dir/gc_base_down" || warn "写入 gc_base_down 失败"
  fi
  # probe_rtt_mode_ms: 100 — 匹配新aggressive默认
  echo 100 > "$param_dir/probe_rtt_mode_ms" || warn "写入 probe_rtt_mode_ms 失败"
  # probe_rtt_win_ms: 5000 — 匹配新aggressive默认
  echo 5000 > "$param_dir/probe_rtt_win_ms" || warn "写入 probe_rtt_win_ms 失败"

  # min_pacing_rate: 默认关闭(0)，用户根据 VPS 带宽设置
  # 用法: ./tcp.sh set-min-pacing-rate <Mbps>
  # 1Gbps VPS 推荐: set-min-pacing-rate 500
  # 跨太平洋高丢包链路推荐: set-min-pacing-rate 100
  if [ -w "$param_dir/min_pacing_rate" ]; then
    echo 0 > "$param_dir/min_pacing_rate" || warn "写入 min_pacing_rate 失败"
  fi
  # gc_enable: 默认关闭 (6.12.90 上 GC 打破 UP/DOWN 平衡)
  if [ -w "$param_dir/gc_enable" ]; then
    echo 0 > "$param_dir/gc_enable" || warn "写入 gc_enable 失败"
  fi

  mkdir -p "$CONF_DIR"
  cat > "$CONF_DIR/bbrplusv3.conf" <<'EOF'
# BBRPlusV3 科学上网平衡优化参数
# 新 aggressive profile 已包含这些值，conf 文件作为持久化备份
profile=2
loss_thresh=8
beta=76
pacing_gain_down=217
probe_rtt_mode_ms=100
probe_rtt_win_ms=5000
gc_enable=0
gc_base_down=217
EOF

  # modules-load.d: 确保模块在 systemd service 之前加载
  # 修复 Boot 竞态：service ExecStart 有 modprobe 兜底，但 modules-load.d 更可靠
  echo "tcp_bbrplusv3" > /etc/modules-load.d/tcpboost-bbrplusv3.conf

  info "BBRPlusV3 参数已设置 (loss=3%, beta=30%, pacing_down=0.85, probe_rtt=5s/100ms, gc=off)"
}

# 设置 min_pacing_rate（保底速率）+ 自动应用全套配套优化
# 一站式入口：输入保底速率 → 自动优化 PROBE_RTT + pacing_down + bufferbloat
#
# 用法: set_min_pacing_rate <Mbps>
#   ./tcp.sh set-min-pacing-rate 100   (100 Mbps VPS)
#   ./tcp.sh set-min-pacing-rate 500   (500 Mbps VPS)
#   ./tcp.sh set-min-pacing-rate 1000  (1 Gbps VPS)
#   ./tcp.sh set-min-pacing-rate 0     (关闭保底 + 恢复默认参数)
#
# 自动优化内容（mbps > 0 时）：
#   PROBE_RTT: 5s/100ms → 10s/50ms（减少 cwnd 骤降频率和深度）
#   pacing_gain_down: 0.85 → 0.90（减少周期性降速）
set_min_pacing_rate() {
  local mbps="${1:-0}"
  local param_dir="/sys/module/tcp_bbrplusv3/parameters"

  if [ ! -w "$param_dir/min_pacing_rate" ]; then
    warn "min_pacing_rate 参数不可用（需要 BBRPlusV3 优化内核）"
    return 1
  fi

  # Mbps → bytes/sec
  local bps=$((mbps * 1000000 / 8))

  # 写入 min_pacing_rate
  if ! echo "$bps" > "$param_dir/min_pacing_rate" 2>&1; then
    warn "写入 min_pacing_rate 失败"
  fi

  # 关闭保底：恢复默认参数 + 重写 service（恢复 aggressive 基线，不含 min_pacing_rate）
  if [ "$mbps" -eq 0 ]; then
    echo 5000 > "$param_dir/probe_rtt_win_ms" || warn "写入 probe_rtt_win_ms 失败"
    echo 100 > "$param_dir/probe_rtt_mode_ms" || warn "写入 probe_rtt_mode_ms 失败"
    echo 217 > "$param_dir/pacing_gain_down" || warn "写入 pacing_gain_down 失败"
    if [ -w "$param_dir/gc_base_down" ]; then
      echo 217 > "$param_dir/gc_base_down" || warn "写入 gc_base_down 失败"
    fi

    if [ -f "$CONF_DIR/bbrplusv3.conf" ]; then
      sed -i "/^min_pacing_rate=/d; /^probe_rtt_win_ms=/d; /^probe_rtt_mode_ms=/d; /^pacing_gain_down=/d; /^gc_base_down=/d" "$CONF_DIR/bbrplusv3.conf"
    fi

    # 恢复 service 到 aggressive 基线（不含 min_pacing_rate 覆盖）
    write_bbrplusv3_service

    info "min_pacing_rate 已关闭，配套参数已恢复 aggressive 基线"
    return 0
  fi

  info "min_pacing_rate = ${mbps} Mbps，自动应用配套优化..."

  # === 自动配套优化 ===

  # 1. PROBE_RTT 优化（核心！旧内核 cwnd=4 packets 无视 pacing 保底）
  #    延长周期 5s→10s（骤降频率减半）+ 缩短持续 100ms→50ms（深度减半）
  echo 10000 > "$param_dir/probe_rtt_win_ms" || warn "写入 probe_rtt_win_ms 失败"
  echo 50 > "$param_dir/probe_rtt_mode_ms" || warn "写入 probe_rtt_mode_ms 失败"

  # 2. pacing_gain_down: 0.85→0.90（减少 PROBE_BW DOWN 周期性降速）
  echo 230 > "$param_dir/pacing_gain_down" || warn "写入 pacing_gain_down 失败"
  if [ -w "$param_dir/gc_base_down" ]; then
    echo 230 > "$param_dir/gc_base_down" || warn "写入 gc_base_down 失败"
  fi

  # === 持久化 ===
  mkdir -p "$CONF_DIR"
  local conf_file="$CONF_DIR/bbrplusv3.conf"
  if [ -f "$conf_file" ]; then
    sed -i "/^min_pacing_rate=/d; /^probe_rtt_win_ms=/d; /^probe_rtt_mode_ms=/d; /^pacing_gain_down=/d; /^gc_base_down=/d" "$conf_file"
  else
    : > "$conf_file"
  fi
  cat >> "$conf_file" <<EOF
min_pacing_rate=$bps
probe_rtt_win_ms=10000
probe_rtt_mode_ms=50
pacing_gain_down=230
gc_base_down=230
EOF

  # systemd service 持久化（统一入口，包含全套参数 + min_pacing_rate 覆盖）
  write_bbrplusv3_service min_pacing_rate=$bps probe_rtt_win_ms=10000 probe_rtt_mode_ms=50 pacing_gain_down=230

  echo ""
  info "全套优化已应用（基于 ${mbps} Mbps 保底）"
  echo -e "  ${CYAN}min_pacing_rate:${NC}    ${mbps} Mbps（pacing 保底）"
  echo -e "  ${CYAN}PROBE_RTT:${NC}         10s/50ms（原 5s/100ms，骤降频率/深度减半）"
  echo -e "  ${CYAN}pacing_gain_down:${NC}  0.90（原 0.85，减少周期性降速）"
  echo ""
  echo -e "  ${GREEN}预期:${NC} 视频流不再需要刷新 | 持续大流量吞吐更稳定"
  echo -e "  ${YELLOW}恢复默认:${NC} ./tcp.sh set-min-pacing-rate 0"
}

# 测试 VPS 真实带宽并自动设置 min_pacing_rate
# 用法: ./tcp.sh speedtest
# 原理: 从 Cloudflare 下载 100MB 文件测速 → 推荐 70% 作为 min_pacing_rate
speedtest_bandwidth() {
  local param_dir="/sys/module/tcp_bbrplusv3/parameters"

  if [ ! -d "$param_dir" ]; then
    modprobe tcp_bbrplusv3 2>/dev/null || true
  fi

  info "测试 VPS 真实带宽（下载 100MB）..."
  echo ""

  # 测速源列表（全球 CDN 优先，HTTP 避免 SSL 问题）
  local -a test_urls=(
    "http://cachefly.cachefly.net/100mb.test"
    "https://speed.cloudflare.com/__down?bytes=104857600"
    "http://speedtest.tele2.net/100MB.zip"
    "https://speed.hetzner.de/100MB.bin"
    "http://proof.ovh.net/files/100Mb.dat"
  )

  # 找一个能连通的测速源
  local test_url=""
  local test_host=""
  for url in "${test_urls[@]}"; do
    test_host=$(echo "$url" | awk -F/ '{print $3}')
    info "  尝试: ${test_host}..."
    # 快速连通性检查（只下载 1 字节）
    if curl -so /dev/null --connect-timeout 5 --max-time 8 \
       "$(echo "$url" | sed 's/100[mM][bB]/1/; s/104857600/1/')" 2>/dev/null; then
      test_url="$url"
      break
    fi
  done

  if [ -z "$test_url" ]; then
    error "所有测速源均不可达"
    echo "  手动测试:"
    echo "    curl -so /dev/null -w '%{speed_download}' http://cachefly.cachefly.net/100mb.test"
    return 1
  fi

  info "  使用: ${test_host}"

  # 测试 2 次取最大值
  local max_mbps=0
  local i
  for i in 1 2; do
    local raw_speed
    raw_speed=$(curl -so /dev/null -w '%{speed_download}' \
      --connect-timeout 10 --max-time 60 \
      "$test_url" 2>/dev/null || echo 0)

    if [ -z "$raw_speed" ] || [ "$raw_speed" = "0" ]; then
      warn "  第 ${i} 次测试失败，跳过"
      continue
    fi

    local mbps
    mbps=$(awk "BEGIN {printf \"%.1f\", $raw_speed / 125000}")
    info "  第 ${i} 次: ${mbps} Mbps"

    # 取最大值（整数比较）
    local mbps_int
    mbps_int=$(awk "BEGIN {printf \"%d\", $raw_speed / 125000}")
    if [ "$mbps_int" -gt "$max_mbps" ] 2>/dev/null; then
      max_mbps=$mbps_int
    fi
  done

  if [ "$max_mbps" -eq 0 ] 2>/dev/null; then
    error "带宽测试失败（Cloudflare CDN 不可达？）"
    echo "  手动测试: curl -so /dev/null -w '%{speed_download}' https://speed.cloudflare.com/__down?bytes=104857600"
    return 1
  fi

  # 推荐 min_pacing_rate = 实测带宽 × 70%（留 30% 余量给控制开销）
  local recommended
  recommended=$((max_mbps * 70 / 100))
  [ "$recommended" -lt 10 ] && recommended=10

  echo ""
  info "实测最大带宽: ${max_mbps} Mbps"
  echo -e "  ${CYAN}推荐 min_pacing_rate:${NC} ${recommended} Mbps（实测 × 70%）"
  echo -e "  ${YELLOW}原理:${NC} min_pacing_rate 不应超过实际带宽，否则过度发送导致丢包"
  echo ""

  # 自动设置
  if [ -d "$param_dir" ] && [ -w "$param_dir/min_pacing_rate" ]; then
    read -p "  自动设置 min_pacing_rate = ${recommended} Mbps? (Y/n): " confirm
    if [ "$confirm" != "n" ] && [ "$confirm" != "N" ]; then
      set_min_pacing_rate "$recommended"
    else
      info "已跳过。手动设置: ./tcp.sh set-min-pacing-rate <Mbps>"
    fi
  else
    warn "tcp_bbrplusv3 模块不可用，仅显示测试结果"
    echo "  手动设置: ./tcp.sh set-min-pacing-rate ${recommended}"
  fi
}

# 开机自动应用 bbrplusv3 参数
setup_bbrplusv3_persistent() {
  write_bbrplusv3_service
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

# === Cloudflare TCP collapse（接收侧优化） ===
net.ipv4.tcp_collapse_max_bytes = 2097152
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

# === Cloudflare TCP collapse（接收侧优化） ===
net.ipv4.tcp_collapse_max_bytes = 8388608
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
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535

# === 锐速风格 TCP 栈优化（稳定性修正） ===
# tcp_retries2: 默认 15，过低会导致连接在临时拥塞时被过早杀死
# tcp_synack_retries/syn_retries: 必须足够大以覆盖跨太平洋 SYN 丢包重传
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_syn_retries = 6
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_limit_output_bytes = $((buf_max / 4))

# === 网络队列 ===
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 10000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_recycle = 0

# === Keepalive（稳定性修正） ===
# 空闲 30 分钟后开始探测，总超时 30min + 9*60s = 39min（原 15min 过激进）
net.ipv4.tcp_keepalive_time = 1800
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 9

# === Cloudflare TCP collapse（接收侧优化） ===
net.ipv4.tcp_collapse_max_bytes = $((buf_max / 2))
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

  info "已应用激进方案 (bbrplusv3 15%/30% 平衡优化 + 锐速风格 TCP 栈优化)"
  echo ""
  echo -e "  ${CYAN}无感切换已启用:${NC}"
  echo "    xray / sing-box / 通用网络 → 自动使用 BBRPlusV3"
  echo "    sing-box 如需确定性带宽 → 配置 multiplex.brutal"
  echo ""
  echo -e "  ${YELLOW}建议:${NC} 设置 min_pacing_rate 提升单流性能"
  echo "    ./tcp.sh set-min-pacing-rate 500  (500 Mbps VPS)"
  echo "    ./tcp.sh set-min-pacing-rate 1000 (1 Gbps VPS)"
}

# Profile 4: TLS 握手优化方案（跨太平洋稳定性推荐）
# 适用: RTT 100ms+ 高延迟 + 1-5% 丢包的跨洋链路, xray/sing-box 代理
# 核心: aggressive profile + apply_bbrplusv3_params覆盖 + TLS sysctl 握手优化 + IW10
# 注意: 不使用 tls_optimized profile（已移除，与 aggressive 重复）
#       不启用 ACD（负优化：cwnd双重缩减 + 破坏PROBE_BW DOWN排空）
apply_profile_tls_optimized() {
  backup_configs

  # BDP 动态计算（同激进方案）
  local mem_total_kb
  mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  local mem_total_mb=$((mem_total_kb / 1024))
  local buf_max_mb=$((mem_total_mb / 16))
  [ "$buf_max_mb" -lt 16 ] && buf_max_mb=16
  [ "$buf_max_mb" -gt 128 ] && buf_max_mb=128
  local buf_max=$((buf_max_mb * 1024 * 1024))

  info "内存: ${mem_total_mb}MB, Buffer 上限: ${buf_max_mb}MB"
  info "应用 TLS 握手优化方案 (aggressive profile + TLS sysctl + IW10)..."

  cat > "$SYSCTL_FILE" <<EOF
# TCPBoost Profile: TLS 握手优化方案
# 适用: 跨太平洋高延迟(100ms+)高丢包(1-5%)链路, xray/sing-box 代理
# 核心: aggressive profile(2.885/2.5/1.5/0.75) + loss/beta覆盖 + TLS sysctl
# 生成时间: $(date)

# === 拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplusv3

# === TCP Buffer (动态 BDP, 跨洋 1Gbps×161ms≈20MB) ===
net.core.rmem_max = ${buf_max}
net.core.wmem_max = ${buf_max}
net.ipv4.tcp_rmem = 4096 131072 ${buf_max}
net.ipv4.tcp_wmem = 4096 65536 ${buf_max}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# === TLS 握手优化核心（区别于激进方案）===
# SYN/SYN-ACK 重传: 跨洋 1-5% 丢包下快速失败重试，避免长时间挂起
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
# TCP Fast Open: client + server, 配合 TLS 1.3 0-RTT 节省 1 RTT
net.ipv4.tcp_fastopen = 3
# 持久连接不重置 cwnd（代理工具 keep-alive 关键）
net.ipv4.tcp_slow_start_after_idle = 0
# PMTU 探测: 应对跨洋 ICMP 黑洞导致大包丢弃
net.ipv4.tcp_mtu_probing = 1

# === TCP 连接优化 ===
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fin_timeout = 15
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
net.ipv4.tcp_keepalive_time = 1800
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 9

# === Cloudflare TCP collapse（接收侧优化） ===
net.ipv4.tcp_collapse_max_bytes = $((buf_max / 2))
EOF

  # limits.conf 调优
  cat > "$LIMITS_FILE" <<'EOF'
# TCPBoost: 文件描述符限制
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

  # systemd 调优
  if pidof systemd >/dev/null 2>&1; then
    if [ -f /etc/systemd/system.conf ]; then
      sed -i 's/^#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=65535/' /etc/systemd/system.conf
      sed -i 's/^#DefaultLimitNPROC=.*/DefaultLimitNPROC=65535/' /etc/systemd/system.conf
    fi
    systemctl daemon-reload 2>/dev/null || true
  fi

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1

  # BBRPlusV3 aggressive profile + apply_bbrplusv3_params 覆盖（与激进方案一致）
  # TLS 优化方案不降速: 使用与激进方案完全相同的 CC 参数
  # 区别仅在 sysctl 层面（TLS 握手优化）+ IW10
  apply_bbrplusv3_params
  setup_bbrplusv3_persistent

  # IW10: 初始拥塞窗口 10 (RFC 6928, TLS 证书链约 2 MSS, IW10 足够覆盖)
  local DEF_ROUTE
  DEF_ROUTE=$(ip route show default 2>/dev/null | head -1)
  if [ -n "$DEF_ROUTE" ]; then
    ip route change $DEF_ROUTE initcwnd 10 initrwnd 10 2>/dev/null && \
      info "初始拥塞窗口已设为 10 (IW10, RFC 6928)" || true
  fi

  echo ""
  info "已应用 TLS 握手优化方案"
  echo -e "  ${CYAN}CC 参数:${NC} aggressive profile + loss=15%/beta=30%（与激进方案一致，不降速）"
  echo -e "  ${CYAN}TLS sysctl:${NC} synack_retries=2, syn_retries=3, fastopen=3, slow_start_after_idle=0"
  echo -e "  ${CYAN}IW10:${NC} 初始拥塞窗口 10（TLS 证书链全覆盖）"
  echo ""
  echo -e "  ${YELLOW}预期效果:${NC}"
  echo "    TLS 握手延迟 -30~50% | 跨洋 SYN 丢包重试更快"
  echo "    持久连接 keep-alive 不重置 cwnd（代理稳定性↑）"
  echo ""
  echo -e "  ${YELLOW}可选:${NC} 设置 min_pacing_rate 进一步提升单流性能"
  echo "    ./tcp.sh set-min-pacing-rate 100  (100 Mbps VPS)"
  echo "    ./tcp.sh set-min-pacing-rate 500  (500 Mbps VPS)"
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
  info "正在检测环境..."
  detect_proxy

  echo ""
  echo -e "  ${CYAN}检测结果:${NC}"
  echo "  xray:      ${PROXY_XRAY}"
  echo "  sing-box:  ${PROXY_SINGBOX}"
  echo "  Hysteria2: ${PROXY_HY2}"
  echo "  丢包等级:  ${PACKET_LOSS}"
  echo ""

  # 所有场景统一使用 bbrplusv3（tcpboost 内核唯一最优选择）
  if [ "$PROXY_HY2" = "yes" ]; then
    modprobe tcp_brutal 2>/dev/null && info "已加载 tcp_brutal（Hysteria2 可用）"
  fi

  echo -e "  ${GREEN}→ 应用 BBRPlusV3 (15%/30%) 平衡优化配置${NC}"
  echo ""

  # 直接应用激进方案
  apply_profile_aggressive

  # 提示设置 min_pacing_rate
  echo ""
  echo -e "  ${YELLOW}建议设置 min_pacing_rate 提升单流下载性能${NC}"
  echo "  推荐值：100 (100Mbps) 或 500 (500Mbps)"
  read -p "  设置 min_pacing_rate? 输入 Mbps (0=跳过): " mpr_input
  if [ -n "$mpr_input" ] && [ "$mpr_input" != "0" ]; then
    set_min_pacing_rate "$mpr_input"
  fi

  info "一键优化完成"
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
      local lt beta mpr gc pgd prt_mode prt_win
      lt=$(cat "$param_dir/loss_thresh" 2>/dev/null || echo "?")
      beta=$(cat "$param_dir/beta" 2>/dev/null || echo "?")
      mpr=$(cat "$param_dir/min_pacing_rate" 2>/dev/null || echo "?")
      gc=$(cat "$param_dir/gc_enable" 2>/dev/null || echo "?")
      pgd=$(cat "$param_dir/pacing_gain_down" 2>/dev/null || echo "?")
      prt_mode=$(cat "$param_dir/probe_rtt_mode_ms" 2>/dev/null || echo "?")
      prt_win=$(cat "$param_dir/probe_rtt_win_ms" 2>/dev/null || echo "?")
      local lt_pct=$((lt * 100 / 256))
      local beta_pct=$((beta * 100 / 256))
      local mpr_mb=$((mpr * 8 / 1000000))
      local pgd_pct=$((pgd * 100 / 256))
      echo "  loss_thresh:    ${lt} (${lt_pct}%)"
      echo "  beta:           ${beta} (${beta_pct}%)"
      echo "  pacing_down:    ${pgd} (${pgd_pct}%)"
      echo "  probe_rtt:      ${prt_win}ms周期/${prt_mode}ms持续"
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
  echo ""
  echo "  ── 网络优化方案 ──"
  echo "  2) 保守方案  ≤100Mbps 小带宽 VPS"
  echo "     bbrplusv3 + 保守 sysctl + 标准 TCP 缓冲"
  echo ""
  echo "  3) 均衡方案  1Gbps VPS"
  echo "     bbrplusv3 + 激进 sysctl + 锐速风格 TCP 栈"
  echo ""
  echo "  4) 激进方案  科学上网推荐"
  echo "     bbrplusv3 15%/30% 平衡优化 + 锐速风格 + 可设保底速率"
  echo ""
  echo "  5) TLS优化方案  跨太平洋握手稳定性推荐"
  echo "     aggressive profile + TLS sysctl + IW10（不降速）"
  echo ""
  echo "  ── 高级 ──"
  echo "  6) 一键优化 (检测环境 + 自动应用最优)"
  echo "  7) 手动切换算法"
  echo "  8) 测速并设置保底速率 (speedtest 自动测带宽)"
  echo "  9) 手动设置保底速率 (min_pacing_rate)"
  echo " 10) 清理多余内核 (只保留当前 tcpboost)"
  echo " 11) 恢复默认配置"
  echo " 12) 卸载 TCPBoost 内核"
  echo "  0) 退出"
  echo ""
  read -p "  请选择 [0-12]: " choice

  case "$choice" in
    1) install_kernel ;;
    2) apply_profile_conservative ;;
    3) apply_profile_balanced ;;
    4) apply_profile_aggressive
       echo ""
       read -p "  设置最低保底速率? 输入 Mbps (如 500=500M, 1000=1G, 0=跳过): " mpr_input
       if [ -n "$mpr_input" ] && [ "$mpr_input" != "0" ]; then
         set_min_pacing_rate "$mpr_input"
       fi
       ;;
    5) apply_profile_tls_optimized
       echo ""
       read -p "  设置最低保底速率? 输入 Mbps (如 100=100M, 500=500M, 0=跳过): " mpr_input
       if [ -n "$mpr_input" ] && [ "$mpr_input" != "0" ]; then
         set_min_pacing_rate "$mpr_input"
       fi
       ;;
    6) smart_recommend ;;
    7) menu_switch_algorithm ;;
    8) speedtest_bandwidth ;;
    9) echo ""; read -p "  输入 Mbps (500=500M, 1000=1G, 0=关闭): " mpr_input
       set_min_pacing_rate "${mpr_input:-0}" ;;
   10) cleanup_kernels ;;
   11) restore_configs ;;
   12) uninstall_kernel ;;
    0) exit 0 ;;
    *) error "无效选择" ;;
  esac
}

menu_switch_algorithm() {
  local available
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
  echo ""
  echo "  可用算法: $available"
  echo ""
  echo "  1) bbrplusv3   — BBRPlusV3 (科学上网首选, BBRv3+激进探测)"
  echo "  2) bbrplus     — BBRPlus (高丢包优化, 原版)"
  echo "  3) brutal      — TCP Brutal (Hysteria2 专用)"
  echo "  4) cubic       — Cubic (系统默认, 公平性好)"
  echo "  5) reno        — Reno (最基础)"
  echo ""
  read -p "  选择算法 [1-5]: " algo_choice

  case "$algo_choice" in
    1) switch_algorithm bbrplusv3 ;;
    2) switch_algorithm bbrplus ;;
    3) switch_algorithm brutal ;;
    4) switch_algorithm cubic ;;
    5) switch_algorithm reno ;;
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
    tls-optimize|tls) apply_profile_tls_optimized ;;
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
    cleanup)  cleanup_kernels ;;
    restore)  restore_configs ;;
    set-min-pacing-rate)
      if [ -z "${2:-}" ]; then
        echo "用法: $0 set-min-pacing-rate <Mbps>"
        echo "  推荐: 50 (50Mbps VPS), 100 (100Mbps VPS), 0 (关闭)"
        echo "  或: $0 speedtest 自动测试带宽并设置"
        exit 1
      fi
      set_min_pacing_rate "$2"
      ;;
    speedtest) speedtest_bandwidth ;;
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
