# TCPBoost — Linux VPS TCP 网络加速一键脚本

基于 Linux 6.12 LTS 内核，集成 **BBRPlusV3** 自研拥塞控制算法 + BBRPlus / TCP Brutal + 系统级网络优化。

专为科学上网（xray / sing-box / Hysteria2）场景优化，跨太平洋高丢包链路实测下载速度提升 **10-100x**。

## 核心特性

- **BBRPlusV3 自研算法** — Google BBRv3 + BBRPlus 激进探测 + tsunami-v3 STARTUP 优化
- **GitHub Actions 云端编译** — 编译过程完全透明，可审计
- **无感切换** — 安装即用，xray / sing-box / 通用网络自动受益
- **参数运行时可调** — module_param 支持 sysfs 动态调参，无需重编译
- **安全内核清理** — 智能检测 meta 包依赖，一键清理多余内核
- **国内外自适应** — 自动检测网络环境，国内使用加速镜像

## 性能数据

跨太平洋链路实测（RTT ~161ms，Debian 12 VPS）：

| 方向 | CUBIC | BBRPlusV3 (3%/30%) | 提升 |
|------|-------|---------------------|------|
| 下载单流 | 0.3 Mbps | 53.5 Mbps | **178x** |
| 下载多流 | 2.6 Mbps | 77.7 Mbps | **30x** |
| 上传多流 | — | 120.5 Mbps | — |

> CUBIC 在跨太平洋高丢包链路上几乎完全失效，BBRPlusV3 是该场景下的正确选择。

### TLS 握手优化方案

`tls-optimize` 命令在 aggressive profile 基础上叠加 TLS 握手优化 sysctl，不降速：

| 优化项 | 效果 |
|--------|------|
| synack_retries=2 / syn_retries=3 | SYN/SYN-ACK 重传次数降低，握手超时减少 |
| tcp_fastopen=3 | TFO 双向启用，TLS 1.3 0-RTT 可省 1 RTT |
| slow_start_after_idle=0 | 代理 keep-alive 连接不重新慢启动 |
| initcwnd=10 (RFC 6928) | TLS 证书链(约 2 MSS)全覆盖，握手不卡 |
| mtu_probing=1 | 自动探测路径 MTU，避免 PMTU 黑洞 |

> 启用方式：`./tcp.sh tls-optimize`。该方案保持 aggressive profile 的全部加速参数，仅叠加 TLS sysctl 优化。

## 支持系统

| 系统 | 最低版本 | 包格式 |
|------|---------|--------|
| Debian | 11 (Bullseye) | .deb |
| Ubuntu | 20.04 (Focal) | .deb |
| Rocky Linux | 9 | .rpm |
| AlmaLinux | 9 | .rpm |
| CentOS Stream | 9 | .rpm |

**架构**: 仅 x86_64

## 快速开始

```bash
# 国际网络（GitHub 直连）
bash <(curl -fsSL https://raw.githubusercontent.com/Be90nia/tcpboost/main/tcp.sh)

# 国内网络（加速镜像）
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Be90nia/tcpboost/main/tcp.sh)
```

## 交互式菜单

```
  1) 安装 TCPBoost 内核 (6.12 LTS)

  ── 网络优化方案 ──
  2) 保守方案  ≤100Mbps 小带宽 VPS
  3) 均衡方案  1Gbps VPS
  4) 激进方案  科学上网推荐
  5) TLS优化方案  跨太平洋握手稳定性推荐

  ── 高级 ──
  6) 一键优化 (检测环境 + 自动应用最优)
  7) 手动切换算法
  8) 设置最低保底速率 (min_pacing_rate)
  9) 清理多余内核 (只保留当前 tcpboost)
 10) 恢复默认配置
 11) 卸载 TCPBoost 内核
  0) 退出
```

## 命令行模式

```bash
./tcp.sh install                 # 安装内核
./tcp.sh optimize                # 应用均衡优化
./tcp.sh tls-optimize            # 应用 TLS 握手优化（跨太平洋稳定性推荐）
./tcp.sh auto                    # 一键优化（自动检测 + 应用激进方案 + 提示 min_pacing_rate）
./tcp.sh switch bbrplusv3        # 切换到 BBRPlusV3
./tcp.sh status                  # 查看当前状态
./tcp.sh set-min-pacing-rate 100 # 设置保底速率 100Mbps
./tcp.sh cleanup                 # 清理多余内核
./tcp.sh restore                 # 恢复默认配置
./tcp.sh uninstall               # 卸载内核
```

## 拥塞控制算法

| 算法 | 推荐场景 | 说明 |
|------|---------|------|
| **BBRPlusV3** | 科学上网首选 | BBRv3 + 激进探测 + tsunami-v3 单流优化 |
| **BBRPlus** | 高丢包链路 | 原版 BBRPlus，丢包场景性能好 |
| **TCP Brutal** | sing-box mux | 需 sing-mux 配合，确定性带宽 |
| **CUBIC** | 系统默认 | 公平性好，适合多用户共享 |
| **Reno** | 兼容性 | 经典算法 |

### BBRPlusV3 参数

平衡优化配置（保留跨太平洋加速优势 + 消除断流根因）：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `loss_thresh` | 3% (7/256) | 丢包阈值，容忍跨太平洋正常丢包(1-3%)，真实拥塞(>3%)降速 |
| `beta` | 30% (76/256) | BBRPlus 经典值，丢包后恢复 70% |
| `pacing_gain_down` | 0.85 (217/256) | PROBE_BW DOWN 阶段速率，减少下载波动 |
| `probe_rtt_mode_ms` | 100 | PROBE_RTT 持续时间，延迟峰值深度 |
| `probe_rtt_win_ms` | 5000 | PROBE_RTT 触发周期，游戏延迟峰值频率 |
| `min_pacing_rate` | 0 (关闭) | 全局 pacing 保底速率（PROBE_RTT 除外，需匹配 VPS 带宽）|
| `profile` | aggressive (2) | 参数预设：conservative/standard/aggressive/wifi |

> **保留的激进参数**（不变）：`startup_pacing_gain=2.885`、`startup_cwnd_gain=2.25`、`pacing_gain_up=1.375`、`drain_gain=0.347`、`min_rtt_win_sec=10s` — 这些是跨太平洋加速的核心优势。

**运行时调参**（无需重编译）：

```bash
# 查看参数
cat /sys/module/tcp_bbrplusv3/parameters/loss_thresh

# 设置保底速率（推荐匹配 VPS 实际带宽）
./tcp.sh set-min-pacing-rate 100   # 100 Mbps
./tcp.sh set-min-pacing-rate 500   # 500 Mbps
./tcp.sh set-min-pacing-rate 0     # 关闭

# 应用 TLS 握手优化（aggressive profile + TLS sysctl + IW10，不降速）
./tcp.sh tls-optimize
```

## 网络优化方案

| 方案 | 适用场景 | CC 算法 | TCP 缓冲 | 特殊优化 |
|------|---------|---------|---------|---------|
| 保守 | ≤100Mbps VPS | bbrplusv3 | 标准 | — |
| 均衡 | 1Gbps VPS | bbrplusv3 | 锐速风格 | initcwnd=32 |
| 激进 | 科学上网 | bbrplusv3 3%/30% | 锐速风格 + sysctl 调优 | initcwnd=32 + 可设 min_pacing |
| **TLS优化** | **跨太平洋握手稳定性** | **bbrplusv3 aggressive** | **BDP 动态** | **TLS sysctl + IW10（不降速）** |

## 无感切换

安装 tcpboost 内核后，所有 TCP 连接自动使用 BBRPlusV3：

- **xray** — 无需改配置，自动享受加速
- **sing-box** — 无需改配置，自动享受加速
  - 如需确定性带宽：配置 `multiplex.brutal.{enabled,up_mbps,down_mbps}`，自动切换到 TCP Brutal
- **Hysteria2** — 基于 QUIC，使用内置拥塞控制，不依赖内核 CC
- **通用网络** — Web、SSH、SCP 等全部受益

## 技术细节

### BBRPlusV3 算法

BBRPlusV3 = Google BBRv3 核心 + BBRPlus 激进参数 + tsunami-v3 单流优化：

- **STARTUP 抗早退** — `full_bw_thresh` 保持 1.25 (BBRv3 原版值)，三轮审计确认 1.10 导致 STARTUP 持续过久
- **DRAIN gain** — `drain_gain` 保持 0.347 (= 1/startup_pacing_gain，数学对称)，三轮审计确认 0.416 DRAIN 不充分
- **快爬升** — `startup_pacing_gain` 2.77→2.885 (BBRv3e1: 2/ln(2))
- **min_rtt 窗口** — `min_rtt_win_sec` 保持 10s (BBRv3 原版值)，三轮审计确认 20s 导致 RTT 不公平性
- **丢包容忍** — `loss_thresh` 2%→3%，容忍跨太平洋正常丢包(1-3%)，真实拥塞(>3%)降速
- **稳定性优化** — `pacing_gain_down`=0.85、`probe_rtt` 5s/100ms，减少下载波动和游戏延迟峰值
- **TLS 握手优化** — tls-optimize 命令叠加 TLS sysctl（synack_retries=2/fastopen=3/slow_start_after_idle=0）+ IW10，不降速
- **保底 pacing** — `min_pacing_rate` 防 STARTUP 阶段 pacing 过低

### 编译架构

```
Debian kernel source
  ├─ Xanmod BBRv3 patches (quilt, 19 patches)
  ├─ CloudPassenger patches (patch -p1, BBRv1/BBRPlus/Brutal)
  ├─ create_bbrplusv3.sh (sed 补丁生成 BBRPlusV3)
  └─ Compatibility fixes (ICSK_CA_PRIV_SIZE, Makefile/Kconfig)
```

## 项目结构

```
tcpboost/
├── .github/workflows/
│   └── build-kernel.yml          # GitHub Actions 内核编译
├── configs/
│   └── x86_64_apply.sh           # x86_64 内核编译选项
├── patches/
│   └── xanmod-bbrv3/             # Xanmod BBRv3 补丁
├── scripts/
│   └── create_bbrplusv3.sh       # BBRPlusV3 算法生成脚本
├── tcp.sh                         # 主脚本
└── README.md
```

## 致谢

- [CloudPassenger/Cloud-Kernel-BBRv3](https://github.com/CloudPassenger/Cloud-Kernel-BBRv3) — 内核补丁和 BBRPlus/Brutal 算法
- [Xanmod Project](https://xanmod.org/) — BBRv3 内核补丁
- [Zhousiru/tsunami-v3](https://github.com/Zhousiru/tsunami-v3) — STARTUP/DRAIN 参数优化验证
- [tcp-nanqinlang](https://github.com/tcp-nanqinlang/tested) — full_bw_thresh STARTUP 抗早退
- [apernet/tcp-brutal](https://github.com/apernet/tcp-brutal) — TCP Brutal 算法
- [ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed) — tcp.sh 网络优化参考

## 许可证

GPLv2 — 与 Linux 内核许可证一致
