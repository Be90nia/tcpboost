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
| `full_loss_cnt` | 0 (A5禁用) | STARTUP loss 退出事件数，0=禁用。跨太背景丢包不再误退出 STARTUP |
| `startup_max_ms` | 10000 | STARTUP 超时兜底(ms)，防止 bw plateau 检测失败时永不退出，0=禁用 |
| `historical_cache_enable` | 0 (off) | 跨连接 min_rtt 缓存开关 (0=关闭, 1=开启)。aggressive/wifi profile 默认开启 |
| `rtt_hist_ttl_sec` | 300 | RTT 缓存 TTL（秒），超过后样本重置 |
| `rtt_hist_min_samples` | 8 | 信任缓存 min_rtt 所需最小样本数 |
| `rtt_hist_max_entries` | 4096 | RTT 缓存最大条目数（per-daddr），防止内存膨胀 |
| `profile` | aggressive (2) | 参数预设：conservative/standard/aggressive/wifi |

> **保留的激进参数**（不变）：`startup_pacing_gain=2.885`、`startup_cwnd_gain=2.25`、`pacing_gain_up=1.375`、`drain_gain=0.347`、`min_rtt_win_sec=10s` — 这些是跨太平洋加速的核心优势。
>
> **tcpboost-A5 新增**：`full_loss_cnt=0`（禁用 STARTUP loss 退出）+ `startup_max_ms=10000`（10s 兜底）— 消除跨太平洋背景丢包(1-3%)导致的 STARTUP 误退出，STARTUP 持续到真正 bw plateau。来源 BBRv3e2 论文，Oracle 架构审核确认纯正向。
>
> **tcpboost-lotspeed-1 新增**：跨连接 min_rtt 历史缓存（per-daddr hashtable）— 解决新连接 STARTUP 早期 `tcp_min_rtt` 含排队延迟导致 BDP 估计过高的问题。机制：同 daddr 历史样本预填 BBR 滤波器。学术基础 RFC 3124 macroflow + qiuxiuya/lotspeed zeta_history_map。Oracle 审核通过（RCU 读 + spinlock 写 + 容量上限 + TTL + fast-path）。默认关闭（conservative/standard），aggressive/wifi profile 自动启用。

**运行时调参**（无需重编译）：

```bash
# 查看参数
cat /sys/module/tcp_bbrplusv3/parameters/loss_thresh
cat /sys/module/tcp_bbrplusv3/parameters/startup_max_ms  # A5: STARTUP 兜底(ms), 0=禁用, 默认10000
cat /sys/module/tcp_bbrplusv3/parameters/historical_cache_enable  # lotspeed-1: 跨连接缓存, 0=关, 1=开

# 设置保底速率（推荐匹配 VPS 实际带宽）
./tcp.sh set-min-pacing-rate 100   # 100 Mbps
./tcp.sh set-min-pacing-rate 500   # 500 Mbps
./tcp.sh set-min-pacing-rate 0     # 关闭

# 启用跨连接 min_rtt 缓存（aggressive profile 已默认开启，conservative/standard 需手动开启）
echo 1 > /sys/module/tcp_bbrplusv3/parameters/historical_cache_enable
echo 300 > /sys/module/tcp_bbrplusv3/parameters/rtt_hist_ttl_sec       # TTL 5min (默认)
echo 8   > /sys/module/tcp_bbrplusv3/parameters/rtt_hist_min_samples   # 最少 8 样本才信任 (默认)
echo 4096 > /sys/module/tcp_bbrplusv3/parameters/rtt_hist_max_entries  # 最大条目数 (默认)

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
- **STARTUP loss 退出禁用 (tcpboost-A5)** — `full_loss_cnt=0` 移除 STARTUP loss 退出条件。跨太平洋 1-3% 背景丢包会触发误退出导致吞吐不足。移除后仅靠 bw plateau 退出 + `startup_max_ms=10000` (10s) 兜底防永不退出。来源 BBRv3e2 (Mahmud et al. ICNC 2026)，Oracle 架构审核确认 `inflight_hi` 保持 `~0U` 安全（代码 line 1746 显式处理）
- **跨连接 min_rtt 种子化 (tcpboost-lotspeed-1)** — per-daddr hashtable 缓存历史 min_rtt，新连接 `bbr_init` 预填 BBR 滤波器，避免 STARTUP 早期 `tcp_min_rtt` 含排队延迟导致 BDP 估计过高。`bbr_update_min_rtt` 实时回写。RCU 读路径（lookup）+ spinlock 写路径（update）+ fast-path 跳过同秒写入 + 容量上限 4096 + TTL 5min + min_samples=8。`module_exit` 调用 `synchronize_rcu` + `hash_for_each_safe` 安全释放全部条目。学术基础 RFC 3124 macroflow + qiuxiuya/lotspeed zeta_history_map。Oracle 审核 bg_5ccfb6cf：10 问 P0/P1/P2 全部已修
- **DRAIN gain** — `drain_gain` 保持 0.347 (= 1/startup_pacing_gain，数学对称)，三轮审计确认 0.416 DRAIN 不充分
- **快爬升** — `startup_pacing_gain` 2.77→2.885 (BBRv3e1: 2/ln(2))
- **min_rtt 窗口** — `min_rtt_win_sec` 保持 10s (BBRv3 原版值)，三轮审计确认 20s 导致 RTT 不公平性
- **丢包容忍** — `loss_thresh` 2%→3%，容忍跨太平洋正常丢包(1-3%)，真实拥塞(>3%)降速
- **稳定性优化** — `pacing_gain_down`=0.85、`probe_rtt` 5s/100ms，减少下载波动和游戏延迟峰值
- **TLS 握手优化** — tls-optimize 命令叠加 TLS sysctl（synack_retries=2/fastopen=3/slow_start_after_idle=0）+ IW10，不降速
- **保底 pacing** — `min_pacing_rate` 防 STARTUP 阶段 pacing 过低

### 丢包容忍理论依据 (tcpboost-G1)

**Lakshman-Madhow 模型**（IEEE/ACM ToN 1997）描述了随机丢包链路上 loss-based TCP（Reno/CUBIC）的稳态吞吐量：

```
T ≈ MSS × 1.22 / (RTT × √p)
```

其中 T = 吞吐量，MSS = 1460 bytes，RTT = 往返时延，p = 随机丢包率。

**跨太平洋场景反解**（RTT=161ms，反解可容忍最大丢包率 p）：

| 目标吞吐量 | 可容忍 p | 跨太背景丢包 1-3% |
|-----------|----------|-------------------|
| 100 Mbps | 0.00005% | ❌ 超 20000-60000x |
| 10 Mbps | 0.005% | ❌ 超 200-600x |
| 1 Mbps | 0.05% | ❌ 超 20-60x |
| 0.3 Mbps（CUBIC 实测）| 0.5% | 接近 |

这从理论上解释了 **CUBIC 在跨太平洋实测仅 0.3 Mbps** — Reno/CUBIC 的 loss-based AIMD 根本无法在高 BDP + 背景丢包链路上工作。

**BBR 不受此限制**：BBR 用 delivery rate 直接测量瓶颈带宽，不依赖丢包估算吞吐量。`loss_thresh` 的作用仅是**判断丢包是否表示真实拥塞**：

| 丢包率 | 语义 | BBRPlusV3 响应 |
|--------|------|----------------|
| 0-3% | 跨太平洋背景噪声 | 忽略，维持速率 |
| 3-5% | 可能开始拥塞 | 收紧 `inflight_lo` |
| >5% | 真实拥塞 (buffer overflow) | 降低发送速率 |

`loss_thresh=3%` 的理论依据：
1. **下界 ≥ 背景噪声上限**：跨太平洋入境丢包 1-3%（Zhu et al. SIGMETRICS 2020），必须 ≥ 3% 避免误判
2. **上界 < 严重拥塞下限**：真实拥塞丢包通常 >5%，应 < 5% 保留响应能力
3. **3% 是平衡点**：高于噪声上限、低于拥塞下限

> 参考文献：Lakshman & Madhow, "The Performance of TCP/IP for Networks with High Bandwidth-Delay Products and Random Loss", IEEE/ACM Trans. Networking, 5(5), 1997.

### 跨连接 min_rtt 种子化 (tcpboost-lotspeed-1)

**问题**：BBR STARTUP 阶段使用 `bbr->min_rtt_us` 计算 BDP（`inflight_hi = bw * min_rtt_us * gain`）。新连接初始 `min_rtt_us = tcp_min_rtt(tp)`，但早期样本常含排队延迟（前面连接留下的 buffer queue），导致 BDP 估计偏高，cwnd/pacing 过度激进，触发丢包和 PROBE_RTT 频繁介入。

**机制**：per-daddr hashtable 缓存历史 min_rtt，新连接在 `bbr_init` 预填滤波器：

```
新连接 bbr_init()
  └─ bbrplusv3_rtt_hist_lookup(daddr)
       └─ 找到 cached min_rtt → 覆盖 bbr->min_rtt_us

bbr_update_min_rtt() (周期性)
  └─ bbrplusv3_rtt_hist_update(daddr, bbr->min_rtt_us)
       └─ 更新缓存（带 EMA 平滑 + 同秒 fast-path 跳过）

module_exit (卸载)
  └─ synchronize_rcu + hash_for_each_safe + kfree
```

**数据结构**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `daddr` | `__be32` | 目的 IPv4 地址（IPv6 返回 0，no-op） |
| `min_rtt_us` | `u32` | EMA 平滑后的 min_rtt（权重 3:1） |
| `sample_cnt` | `u32` | 累计样本数，低于 `min_samples=8` 不被信任 |
| `last_update_jif` | `u64` | 上次更新 jiffies，配合 TTL=300s 判定过期 |

**并发安全**：
- **读路径**（`bbrplusv3_rtt_hist_lookup`）：`rcu_read_lock` + `hash_for_each_possible_rcu`，无锁查找
- **写路径**（`bbrplusv3_rtt_hist_update`）：先 RCU peek 同秒 fast-path 跳过（per-ACK 热路径优化），再 `spin_lock_bh` + `hash_for_each_possible` 安全更新
- **内存序**：`WRITE_ONCE` + `smp_store_release` 写，`smp_load_acquire` 读，跨 CPU 内存屏障严格
- **容量上限**：`atomic_t cnt` 跟踪条目数，达到 `max_entries=4096` 时 fail-open（直接跳过插入，不阻塞）
- **TTL 过期**：超过 `ttl_sec=300`（5min）的条目在下次 update 时重置 `sample_cnt=1`，防止陈旧数据

**profile 默认值**：

| Profile | `historical_cache_enable` | 说明 |
|---------|---------------------------|------|
| conservative | 0 | 关闭（保守，不引入跨连接耦合） |
| standard | 0 | 关闭（标准） |
| aggressive | 1 | 启用（科学上网首选） |
| wifi | 1 | 启用（WiFi 场景） |

**安全性**：默认关闭（`historical_cache_enable=0`），用户显式开启或选择 aggressive/wifi profile 才生效。卸载模块时 `synchronize_rcu` 双屏障 + `hash_for_each_safe` 安全释放全部条目。

> 学术基础：RFC 3124 macroflow（跨连接信息共享）+ [qiuxiuya/lotspeed](https://github.com/qiuxiuya/lotspeed) zeta_history_map。Oracle 架构审核 bg_5ccfb6cf：10 问全部 P0/P1/P2 已修。

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
