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

| 方向 | CUBIC | BBRPlusV3 (30%/80%) | 提升 |
|------|-------|---------------------|------|
| 下载单流 | 0.3 Mbps | 53.5 Mbps | **178x** |
| 下载多流 | 2.6 Mbps | 77.7 Mbps | **30x** |
| 上传多流 | — | 120.5 Mbps | — |

> CUBIC 在跨太平洋高丢包链路上几乎完全失效，BBRPlusV3 是该场景下的正确选择。

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

  ── 高级 ──
  5) 一键优化 (检测环境 + 自动应用最优)
  6) 手动切换算法
  7) 设置最低保底速率 (min_pacing_rate)
  8) 清理多余内核 (只保留当前 tcpboost)
  9) 恢复默认配置
 10) 卸载 TCPBoost 内核
  0) 退出
```

## 命令行模式

```bash
./tcp.sh install                 # 安装内核
./tcp.sh optimize                # 应用均衡优化
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

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `loss_thresh` | 30% (77/256) | 丢包阈值，低于此值不降速 |
| `beta` | 80% (204/256) | 丢包响应幅度，越高越不降速 |
| `min_pacing_rate` | 0 (关闭) | 保底发送速率，防 STARTUP 早退 |
| `profile` | aggressive (2) | 参数预设：conservative/standard/aggressive/wifi |
| `gc_enable` | 0 (关闭) | BBR-GC 自适应 pacing gain（实验性） |

**运行时调参**（无需重编译）：

```bash
# 查看参数
cat /sys/module/tcp_bbrplusv3/parameters/loss_thresh

# 设置保底速率（推荐匹配 VPS 实际带宽）
./tcp.sh set-min-pacing-rate 100   # 100 Mbps
./tcp.sh set-min-pacing-rate 500   # 500 Mbps
./tcp.sh set-min-pacing-rate 0     # 关闭
```

## 网络优化方案

| 方案 | 适用场景 | CC 算法 | TCP 缓冲 | 特殊优化 |
|------|---------|---------|---------|---------|
| 保守 | ≤100Mbps VPS | bbrplusv3 | 标准 | — |
| 均衡 | 1Gbps VPS | bbrplusv3 | 锐速风格 | initcwnd=32 |
| 激进 | 科学上网 | bbrplusv3 30%/80% | 锐速风格 + sysctl 调优 | initcwnd=32 + 可设 min_pacing |

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

- **STARTUP 抗早退** — `full_bw_thresh` 1.25→2.0，高丢包链路不轻易退出 STARTUP
- **温和 DRAIN** — `drain_gain` 0.347→0.416，减少 STARTUP 后的过度排空
- **快爬升** — `startup_pacing_gain` 2.77→2.885 (BBRv3e1: 2/ln(2))
- **长 RTT 稳定** — `min_rtt_win_sec` 10→20s，跨太平洋链路 min_rtt 估值更稳
- **丢包容忍** — `loss_thresh` 2%→30%，高丢包链路不降速
- **BBR-ACD 检测** — cong_control wrapper 检测随机丢包并补偿 pacing（实验性）
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
