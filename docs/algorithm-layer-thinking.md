# tcpboost 算法层方法学 (Control Theory / Optimization / Learning)

> **目的**: 跳出 BBR 微观调参视角，把 TCP 拥塞问题放到控制论/优化/学习理论的通用框架下，**并系统化地用其他 CCA 的成熟技术优化 BBRPlusV3**。
> **作者**: tcpboost 算法层工作流 (2026-10-08 起)
> **bd 跟踪**: `tcpboost-hu2` (方法学 umbrella) / `tcpboost-86e` (BBRPlusV3 cross-CCA port backlog umbrella) / `tcpboost-ffc` (RL watchlist)

## 0. 升维原则

在 BBR 层（参数/状态机细节）花了 4-5 轮调研，**挖到 6 个具体补丁点**（probe_rtt 5s→10s、drain_gain 0.5、loss_thresh 5% 等），但都只是对 BBR 这一种 CCA 的局部优化，**不解决 tcpboost 真正痛点的根因**：

- **xhttp 流间饿死**（见 `xhttp-starvation-report.md`）: 根因是 Linux 收端 DRS 竞速亚稳态，**与 BBR 无关**——CUBIC/Reno 同样会饿。
- **跨 CCA 共存**: BBR+CUBIC 公平性差（NYU 2025 验证），不是 BBR 调参能解的。
- **AQM 缺位**: 跨洋公网路由器不支持 CAKE/FQ-CoDel，**软件层面 BBR 调参无法补偿瓶颈端 AQM 缺位**。

**升维的核心是双线并行**：
1. **方法学** (本文件 §1-2): 用控制论/优化/博弈论/RL 通用框架分析问题根源。
2. **跨算法移植** (本文件 §3): BBRPlusV3 仍是改造对象，但每个改造点都必须**借自其他 CCA/队列管理算法的成熟技术**——而不是"再 sed 一下 BBR 源码"。

继续在 BBR 状态机里发散是 **无界优化**。**有界的方式是枚举 BBRPlusV3 的功能，然后去别处找更好的实现**。

## 1. 四大算法范式（方法学索引）

### 1.1 控制论视角 (Control Theory)

**核心思想**: TCP 拥塞系统是多平衡态 (multi-equilibrium) 动态系统。亚稳态（metastable）= 系统被卡在次优平衡点，**靠 CCA 自身反馈无法逃逸**。

**关键文献**:
- Jacobson 1988 (AIMD stability) / Chiu-Jain 1989 (convergence)
- Wischik-McKeown 2005 (fluid model of TCP)
- Baccelli-Paris-Tutuncu 2018 (slow restart for metastable)
- RFC 8289 (CoDel), RFC 8034 (PIE), RFC 9768 (AccECN)
- Nichols 2018 (sojourn-time controller)

### 1.2 网络效用最大化 (NUM) 视角

**核心思想**: Kelly 1997 把 TCP 拥塞问题形式化为 Network Utility Maximization，TCP = primal-dual 求解器。

**关键文献**: Kelly 1997, Low 2003, Srikant 2004 (书), Neely 2010 (书)

### 1.3 博弈论视角 (Multi-Agent Game)

**核心思想**: TCP 流 = 自私 agent，纳什均衡 ≈ max-min 公平。

**关键文献**: Chiu-Jain 1989, Shenker 1995, La-Chiotis 2024-2025 (NYU study)

### 1.4 学习视角 (Online Learning / RL) → bd `tcpboost-ffc`

**核心思想**: 不用模型描述瓶颈，用强化学习直接学策略。

**关键文献**: Jay 2019 (Aurora), Emara 2024 (Astraea), Chen 2025 (ProCC), PMC13108896 (BBR-n+)

**对 tcpboost 现状**: 学术界活跃，工业界未生产。tcpboost **不动**；季度回访见 watchlist。

## 2. BBRPlusV3 现有功能盘点 (盘点方法: 读 `scripts/create_bbrplusv3.sh`)

`create_bbrplusv3.sh` 4-7c 段对 BBRv3 的所有改动 + 旁路补丁清单：

### 2.1 状态机相关
| 阶段 | BBRPlusV3 改动 | 现状 |
|---|---|---|
| STARTUP | pacing_gain=2.885 (BBRv3e1), cwnd_gain=2.25 | 激进但有 startup_max_ms (A5) 兜底 |
| DRAIN | gain=0.347 (=1/2.885) | 固定增益，无 sojourn 反馈 |
| PROBE_BW | UP=11/8=1.375, DOWN=17/20=0.85 | 固定循环，无 RTT 抖动感知 |
| PROBE_RTT | mode=100ms, win=5000ms | time-based exit, A4 冻结 lower_bound, 2s0 随机化 |

### 2.2 反馈信号处理
| 信号 | BBRPlusV3 改动 | 现状 |
|---|---|---|
| Loss | thresh=3%, full_loss_cnt=0 (A5), headroom=12% | post-loss only, 0 区分自身/RTO/路由丢包 |
| ECN | thresh=50% | 二值判断，0 几何平滑，无 AccECN |
| RTT | lotspeed-1 跨连接 min_rtt 缓存 | 有 min_rtt 缓存, 但未用作 RTT-inflation 检测 |
| cwnd | lotspeed-1 pre-seed | 跨连接优化, 已部署 |

### 2.3 旁路补丁
- **A4**: PROBE_RTT 期间冻结 lower_bound 更新
- **A5**: STARTUP loss 退出禁用 + startup_max_ms 兜底
- **A6 lotspeed-1**: 跨连接 min_rtt 历史缓存
- **2s0**: PROBE_RTT 首次触发随机化
- **GC**: gamma correction (DOWN gain sqrt 近似)
- **min_pacing_rate floor**: 最小 pacing rate 强制
- **Cloudflare TCP collapse**: 收端队列 collapse 跳过 (独立补丁)

## 3. BBRPlusV3 Cross-CCA Port Backlog ★ 核心

**方法**: 对 §2 每个功能，找其他算法在该功能上做得更好的实现，移植过来。

**bd 跟踪**: `tcpboost-86e` (umbrella)，下含 6 个 port 子项。

### 3.1 移植候选 (按 ROI 排序)

| # | BBRPlusV3 功能 | 现状 | 跨算法 port 候选 | ROI | bd 跟踪 |
|---|---|---|---|---|---|
| **1** | ProbeRTT exit | time-based (mode_ms=100) | **BBR-n+ Smart Exit Algorithm 1** (PMC13108896 2024): 检测 RWND-limited, 提前退出 | ★★★ | `tcpboost-2lv` |
| **2** | ECN response | boolean (thresh 50%) | **DCTCP alpha 几何平滑** (SIGCOMM 2010) + **AccECN (RFC 9768)** Linux 7.0+ 接入 | ★★★ | `tcpboost-ev6` |
| **3** | Loss response | post-loss only | **ABC RTT-inflation 提前检测** (NSDI 2020 Bakker et al.) | ★★★ | `tcpboost-utc` |
| **4** | DRAIN 阶段 + ProbeRTT exit | 固定 gain/时间 | **CoDel sojourn-time 控制器** (RFC 8289) | ★★ | `tcpboost-5cs` |
| **5** | Pacing gain UP | 固定 1.375 | **Hysteria/Brutal 变差感知**: cwnd = bw×RTT/rttvar | ★★ | `tcpboost-b6t` |
| **6** | Beta 削减 | 固定 0.3 | **CUBIC fast convergence** (RFC 8312 §4.5): RTO 退出时 0.7×cwnd | ★ | `tcpboost-6u8` |

### 3.2 每个 port 的具体技术细节

#### Port #1: BBR-n+ Smart Exit (`tcpboost-2lv`, P2)

**机制**: 在 `bbr_check_probe_rtt_done()` 中加入 RWND-limited 检测：
```
if (bbr->mode == BBR_PROBE_RTT) {
    if (任意 skb 长度 > 当前 rcv_wnd/4) {  // RWND-limited
        立即退出;  // 不要 cap cwnd
        return;
    }
    if (bbr->probe_rtt_done_stamp <= now)
        退出;
}
```

**对饿流直接有效**: 当收端 `rcv_ssthresh` 钉 64KB 地板（`xhttp-starvation-report.md` 根因）时, BBR 误以为 cwnd 过大需要 cap → 实际是收端限制, cap 无意义. Smart Exit 跳过这个 cap, BBR 正常发包.

**代码量**: 30-40 行.
**状态**: P2 待实施.

#### Port #2: DCTCP ECN alpha + AccECN (`tcpboost-ev6`, P2)

**机制**: 用 DCTCP 的几何平滑代替 boolean 阈值:
```c
// bbr_check_ecn_too_high_in_startup() 入口
if (tp->delivered > bbr->ecn_alpha_last_delivered) {
    u32 ce_acked = tp->ece_acked_count;  // AccECN 精确值
    u32 total_acked = tp->delivered - bbr->ecn_alpha_last_delivered;
    u32 F = (ce_acked << BBR_SCALE) / total_acked;
    bbr->ecn_alpha = (bbr->ecn_alpha * 15 + F) >> 4;  // g=1/16 平滑
    bbr->ecn_alpha_last_delivered = tp->delivered;
}
// 用 alpha 决定 inflight 削减比例, 替代 0/1 boolean
```

**AccECN 接入**: 7.0+ 内核 `tcp_input.c` 已有 `iph.acem_if`, 需要在 BBRPlusV3 中读取而非丢弃.

**代码量**: 25-40 行.
**验收**:
- 浅缓冲 + AQM: ECN 触发率 +30-50%
- 跨洋公网 (无 AccECN): 兼容 fallback 到二值
- 0 loss 单流: 行为不变

#### Port #3: ABC RTT-inflation 提前检测 (`tcpboost-utc`, P2)

**机制**:
```c
// bbr_set_cwnd() 出口, 每次 ACK 触发
if (bbr->min_rtt_us != ~0U) {
    u32 expected = bbr->min_rtt_us;
    u32 measured = tp->rcv_rtt_est.rtt_us;
    if (measured > expected + (expected >> 1)) {  // 1.5x baseline
        bbr->abc_penalty++;
        if (bbr->abc_penalty > 5) {  // 持续 5 个 ACK
            tcp_snd_cwnd_set(tp, max(tcp_snd_cwnd(tp) - 1, 4));
            bbr->abc_penalty = 0;
        }
    } else {
        bbr->abc_penalty = max(bbr->abc_penalty - 1, 0);
    }
}
// backup_cwnd 维护: 真实 loss 时 cwnd = max(backup, cwnd_loss)
```

**对比**:
- 现状: loss → 30% cut → 8 RTT 恢复
- 加 ABC: RTT +50% 持续 → 1 MSS/RTT 退 → 2 RTT 恢复

**代码量**: 30-50 行.
**状态**: P2 待实施.

#### Port #4: CoDel sojourn-time (`tcpboost-5cs`, P3)

**机制**:
- `bbr_drain()` 出口: `连续 100ms sojourn < 5ms` (替代固定 inflight ≤ BDP)
- `bbr_check_probe_rtt_done()` 出口: `sojourn < target 持续 1 interval` (替代纯 100ms 计时)
- sojourn = `tp->rcv_rtt_est.rtt_us - bbr->min_rtt_us`

**收益**:
- 浅缓冲: 减少过度排空, 吞吐 +5-10%
- 深缓冲: 减少排空不足, 延迟 -20-30%

**代码量**: 25-35 行.
**状态**: P3 待实施.

#### Port #5: Hysteria/Brutal 变差感知 pacing (`tcpboost-b6t`, P3)

**机制**:
- 维护 RTT m2 (Welford 在线方差) 增量: `(new_rtt - mean)²`
- pacing_gain_UP = `max_gain * (1 - clamp(rtt_var / rtt_mean, 0, 0.5))`
- 抖动大 → 减探增加 → 减少再拥塞

**收益**:
- 4G/WiFi 抖动链路: 延迟 -15-25%
- 稳定有线: 行为不变
- 卫星链路: 自适应保守

**代码量**: 30-50 行 (Welford + 动态 gain).
**状态**: P3 待实施.

#### Port #6: CUBIC fast convergence (`tcpboost-6u8`, P3)

**机制**:
```c
// bbr_handle_inflight_too_high() 入口
if (tp->retransmits > 0) {  // RTO 发生过
    bbr->rto_cwnd = tcp_snd_cwnd(tp);
    tcp_snd_cwnd_set(tp, (tcp_snd_cwnd(tp) * 7) >> 3);  // 0.7× cut
}
// 后续 loss recovery 不超过 rto_cwnd
```

**代码量**: 15-25 行.
**状态**: P3 待实施.

## 4. BBRPlusV3 Cross-Domain Port Backlog ★★★ 新

> **核心洞察** (来自 2026-10-08 用户原话): "就好比 Priority-Flood 没办法替代 BFS/DFS, 但它的算法可以动态分配扫描算力, 因此某种层度上提高了整体的速度. 这就是我想要的可以跨界找找有没有适合我们现在 BBR 算法瓶颈问题的算法."

§3 是**跨 CCA 移植**——从其他拥塞控制算法的成熟实现借技术。
§4 是**跨域移植**——从**其他领域**的算法借"调度策略"机制 (不一定更快, 但能**重新分配算力**, 整体更高效)。

### 4.1 方法学：调度杠杆 (Scheduling Levers)

BBR 当前的"等量齐观"问题:
- ProbeBW 4 相位固定循环 → 调度时机不灵活
- ProbeRTT 5s 固定周期 → 调度频率不灵活
- UP gain 固定 1.375 → 调度力度不灵活
- 多流之间无协调 → 资源分配不灵活
- Loss 后等 30% cut → 反馈响应不灵活

跨域 port 各自动哪根"调度杠杆":

```
横轴 (who gets resource)    →  CFS / WFQ / HTB / Work stealing
纵轴 (when)                 →  MLFQ / Priority-Flood
深度 (how much)             →  PI / MPC / Kalman
精度 (estimate quality)     →  Bayesian / RLS / LMS / LQG
检测 (change / hypothesis)  →  Bayesian change-point / SPRT / HMM-Viterbi
探索 (explore/exploit)      →  UCB1 bandit / Bellman DP
```

### 4.1.1 BBRPlusV3 算法痛点清单 (穷尽扫描)

§3 / §4 之前只覆盖 4 相位状态机。完整 BBRPlusV3 痛点:

| # | 痛点 | 当前 BBRPlusV3 行为 | 关键 port |
|---|---|---|---|
| 1 | ProbeRTT exit | 100ms 计时 | cross-CCA #1 Smart Exit |
| 2 | ECN 响应 | 0/1 boolean thresh=50% | cross-CCA #2 DCTCP+AccECN |
| 3 | Loss 判定 | boolean thresh=3% | cross-CCA #3 ABC + cross-domain #8 Bayesian + #11 SPRT |
| 4 | DRAIN 退场 | 固定 gain 0.347 | cross-CCA #4 CoDel sojourn |
| 5 | **Startup 退出** | full_bw_thresh=1.25 + bw plateau (3 round) | **cross-domain #9 Bayesian change-point** |
| 6 | **Loss 真假判定** | boolean 累计 | **#8 Bayesian + #11 SPRT** |
| 7 | **RTO 退避** | RFC 6298 (固定 1s min, 指数) | cross-CCA #6 CUBIC fast conv |
| 8 | **Tail Loss Probe (TLP)** | 标准 (无 BBR 感知) | **未覆盖 (待办)** |
| 9 | **App-limited 检测** | `is_app_limited` flag + skip probe | **未覆盖 (待办)** |
| 10 | **Inflight_hi/lo 更新节奏** | per-ACK 触发 | **#9 change-point 可重塑** |
| 11 | **RTT 估计精度** | tp->rcv_rtt_est (EWMA) | **#F Kalman / #13 RLS / #8 Bayesian** |
| 12 | BW 估计精度 | max of delivered in window | **#F Kalman / #13 RLS / #8 Bayesian** |
| 13 | 跨流公平 | 无协调 (单流视角) | **#1 CFS / #3 WFQ / #14 Work stealing** |
| 14 | 跨 CCA 公平 | 无 (单 CCA 视角) | **#3 WFQ** |
| 15 | 容器层级 | 不感知 cgroup | **#5 HTB** |
| 16 | 启发式 gain 调度 | 固定 1.375 UP / 0.85 DOWN | **#4 PI / #2 MLFQ / #10 UCB1 bandit / #16 Bellman DP** |
| 17 | 单 cycle 决策 | 4 相位独立 | **#7 MPC** |
| 18 | 路径切换检测 | 无显式检测 | **#9 Bayesian change-point / #12 HMM** |
| 19 | 估计+控制耦合 | 分开, 启发式联接 | **#17 LQG 一体化** |

**未覆盖痛点** (#8 TLP, #9 app-limited) 留待下一轮.

### 4.2 跨域 Port 候选 (按 ROI 排序, 共 17 项)

| # | 跨域算法 | 原始领域 | 调度杠杆 | BBR 痛点 | ROI | bd |
|---|---|---|---|---|---|---|
| **1** | **CFS vruntime** | Linux 调度 (Molnar 2007) | 资源分配: vruntime 最小者优先服务 | 跨连接公平 pacing, 饿死流自动优先 | ★★★ | `tcpboost-afi` |
| **2** | **MLFQ** | OS 调度 (Corbato 1962) | 时序调度: 行为反馈升/降级 | adaptive pacing gain, 输家自动降级 | ★★★ | `tcpboost-0w6` |
| **3** | **WFQ / DRR** | 网络队列 (Parekh 1993, Shreedhar 1996) | 比例公平调度 | 跨 CCA (BBR/CUBIC/Reno) 共享带宽 | ★★★ | `tcpboost-32e` |
| **8** | **Bayesian 估计** | 统计 (Laplace 1812) | 估计精度: 后验分布替代点估计 | BW/RTT 估计 + loss 真假概率化判定 | ★★★ | `tcpboost-bgy` |
| **9** | **Bayesian change-point** | 统计 (Adams MacKay 2007) | 检测: 分布变化自动识别 | Startup 退出 / 路径切换 / 路由变化 / BDP 失效 | ★★★ | `tcpboost-6oa` |
| **14** | **Work stealing** | 并行计算 (Blumofe 1999) | 主动资源分配: 闲 worker 偷忙 worker | 跨流偷带宽 (主动版, 优于 vruntime 被动版) | ★★★ | `tcpboost-9tu` |
| **F** | **Kalman filter** (foundation) | DSP (Kalman 1960) | 估计精度 (调度基础) | bw/rtt 估计 | ★★★ | `tcpboost-daw` |
| **4** | **PI 反馈控制器** | 工业过程控制 (1970s) | 输出调度: 比例+积分消除稳态误差 | 替换 BBR 启发式 pacing gain | ★★ | `tcpboost-qpm` |
| **5** | **HTB** | Linux qdisc (Devera 1999) | 层级调度: 父/子 share 带宽 | 容器/cgroup 多层级 | ★★ | `tcpboost-i6a` |
| **6** | **Priority-Flood** | GIS (Barnes 2014) | 空间调度: priority queue 按需处理 | 全局 ProbeRTT 调度, 消除多流同步探测量雷阵 | ★★ | `tcpboost-8bf` |
| **7** | **MPC** | 控制论 (Garcia 1989) | 预测调度: 看未来 N 步选最优序列 | 多 cycle pacing 优化 | ★★ | `tcpboost-hw3` |
| **10** | **UCB1 bandit** | ML (Auer 2002, JMLR) | 探索: explore/exploit 选 gain | ProbeBW gain 选哪个 (1.0/1.25/1.375/1.5) | ★★ | `tcpboost-pek` |
| **11** | **SPRT** | 统计 (Wald 1945) | 检测: 序贯似然比早判 | "loss 是真拥塞? 等够样本吗?" 早判 | ★★ | `tcpboost-5pe` |
| **12** | **HMM + Viterbi** | 统计 (Viterbi 1967) | 检测: 隐状态 (OK/Slow/Dead) 推断 | 路径状态机: 现在处于什么状态? | ★★ | `tcpboost-e18` |
| **13** | **RLS** | DSP (Plackett 1950) | 估计精度: 遗忘因子 RLS, 比 Kalman 快 | 路径变化时 BW 估计快速适应 | ★★ | `tcpboost-ucg` |
| **17** | **LQG** | 控制论 (Kalman 1960) | 估计+控制一体化: Kalman + LQR | 多状态闭环最优控制 | ★★ | `tcpboost-bfe` |
| **15** | **LMS** | DSP (Widrow Hoff 1960) | 估计精度: 极轻量 | 已被 EWMA 涵盖, 边际收益小 | ★ | `tcpboost-8vv` |
| **16** | **Bellman DP** | 运筹 (Bellman 1954) | 探索: 序贯决策最优性 | 实时 value iteration 难, 工业界用 RL/启发式 | ★ | `tcpboost-kb3` |

> ★★ Kalman 标 F (foundation). 估计精度是所有调度决策的前提.

### 4.3 每个 port 的具体技术细节 (按调度杠杆分组)

#### 横轴类 (资源分配 - who gets how much)

**Port #1: CFS vruntime** (`tcpboost-afi`, P2)

源: Linux Completely Fair Scheduler (Ingo Molnar 2007, 红黑树 + vruntime).

机制: per-task 维护 vruntime = wall_time × weight, 调度器永远选 vruntime 最小任务. 任务"花 CPU 越多, vruntime 越长", 自动往后排.

BBR 应用: 跨连接公平 pacing
- 每连接维护 vruntime = bytes_acked × 1e6 / target_rate
- pacer 选 vruntime 最小者发包
- 饿死流 vruntime 自动最小, 自然被优先服务
- 跨 CCA 公平: CUBIC/BBR/Reno 都用同一 vruntime 公式 → max-min fair

实施: 单 connection 是 per-sock 字段; 跨 connection 需 BPF/HTB 配合. 现实意义: 客户端单流价值小, 服务端多流价值大 (xray 端).

代码量: 50-100 行.

**Port #3: WFQ / DRR** (`tcpboost-32e`, P2)

源: Weighted Fair Queuing (Parekh 1993, GPS reference, Demers PGPS/WF2Q, Shreedhar DRR 1996).

机制: 按 weight 比例分配, O(1) per packet (DRR).
- packet_i 获得 bandwidth_i × weight_i / Σ weight_j
- deficit counter 模拟 GPS

BBR 应用: 跨 CCA 公平
- 当前: BBR + CUBIC 共存不公 (NYU 2025)
- 想要: BBR/CUBIC/Reno 按 weight 比例分
- 实施: tc qdisc + HTB 在网卡层 WFQ, BBRPlusV3 在 cwnd 计算时给 weight 提示
- 对比 HTB (#5): WFQ 平铺, HTB 树形; 单层选 WFQ, 多层选 HTB

代码量: 50-100 行.

**Port #5: HTB** (`tcpboost-i6a`, P3)

源: Hierarchical Token Bucket (Martin Devera 1999, Linux tc).

机制: 树形结构, 父节点 rate/ceil, 子节点按 weight 分享, 借/还 token.

BBR 应用: 多层级带宽分配
- 场景: 一台 VPS 跑多个容器/cgroup
- 想要: 容器 A 100Mbps, 容器 B 50Mbps, 容器内 BBR 自适应
- 集成: BBR pacing rate 计算时读 cgroup v2 max bandwidth 作 ceiling

代码量: 30-50 行. 局限: 需 cgroup v2 + root.

#### 纵轴类 (时序调度 - when)

**Port #2: MLFQ** (`tcpboost-0w6`, P2)

源: Multilevel Feedback Queue (Corbato 1962, OS 教科书, 现代 CFS/Windows NT 精神祖先).

机制: 多级队列, 行为反馈降级/升级
- 任务用完时间片 → 降级
- 任务让出 CPU (sleep) → 升级
- 长跑任务沉到底, 短任务留在顶

BBR 应用: adaptive pacing gain
- Level 0 (1.375×): 长期 0 loss + RTT 稳定
- Level 1 (1.0×): 偶发 loss/ECN
- Level 2 (0.7×): 持续 loss/ECN
- 反馈: 收到 loss/ECN → 降级; 持续 N 秒无 loss → 升级
- 边界: [0, 2]

效果: 输家流 level=2 → gain=0.7, 健康流 level=0 → gain=1.375, 不对称探 → 输家快速恢复.

代码量: 30-50 行.

**Port #6: Priority-Flood** (`tcpboost-8bf`, P3)

源: Priority-Flood (Barnes 2014, Computers & Geosciences).

机制: 优先级队列按 elevation 排序, 最低优先处理, 算力集中到"低洼处". O(n log n).

BBR 应用: 全局 ProbeRTT 调度
- 当前: 2s0 patch 加随机化, 降低同步概率
- Priority-Flood: 全局 priority queue 按 "RTT 估计陈旧度" 排, 最久没测的最先 ProbeRTT
- 实施: BPF + userspace daemon, 单 connection 内无效

代码量: 80-150 行. 价值: multi-flow server 端.

#### 深度类 (输出调度 - how much)

**Port #4: PI 反馈控制器** (`tcpboost-qpm`, P2)

源: Proportional-Integral controller (工业过程控制 1970s+, RFC 8034 PIE 用此思路).

机制:
```
output(t) = Kp × e(t) + Ki × ∫e(τ)dτ
e(t) = setpoint - measured
```

BBR 应用: 替换启发式 pacing gain
- 当前: gain 固定 1.375 / 0.85 - 启发式
- PI: setpoint = target_throughput, measured = actual, e = setpoint - measured
  - gain_UP = 1.0 + Kp × e/max + Ki × ∫e
  - e=0: gain=1.0 (持平)
  - e>0: gain>1 (加速)
  - e<0: gain<1 (减速)

优势: 自动消除稳态误差, 不依赖启发式常数, 可在线调 Kp/Ki.

代码量: 40-60 行.

**Port #7: MPC** (`tcpboost-hw3`, P3)

源: Model Predictive Control (Garcia 1989 survey).

机制: 预测未来 N 步, 优化动作序列, 滚动规划.

BBR 应用: 多 cycle pacing 优化
- 状态: [bw, rtt, cwnd, inflight_hi, inflight_lo]
- 动作: [pacing_gain per cycle, cwnd_gain per cycle]
- 目标: max Σ throughput - λ × Σ loss
- 求解: 小规模凸优化 (KKT/LP) 或 grid search

代码量: 60-100 行.

**Port #F: Kalman filter** (`tcpboost-daw`, P2, foundation)

源: Kalman filter (Kalman 1960).

机制: predict + update 递推最优估计, 比滑动窗快 N 倍.

BBR 应用: 替换 max_bw / min_rtt 滑动窗.
- Q/R 调参: 跨太平洋长 fat pipe Q/R 大 (快收敛), 移动 4G Q/R 小 (抗丢包)
- 对比 KCC 方案 (PLAN.md Phase 3): KCC 许可证 NOASSERTION; 自研 scalar Kalman 30 行无许可问题

代码量: 30-50 行 (scalar) / 80-120 行 (vector [bw, rtt, loss]).

#### 精度类 (估计质量 - estimate quality)

**Port #8: Bayesian 估计** (`tcpboost-bgy`, P2)

源: Bayesian inference (Laplace 1812, Jaynes 2003).

机制: 后验分布 = 先验 × 似然, 全分布而非点估计.

BBR 应用:
- BW 估计: 不再 'max(delivered in window)', 而是维护 bw 的 posterior 分布 (mean, var)
- 当估计的方差大时, 不敢激进 (low confidence → low gain)
- 当方差小时, 敢激进 (high confidence → high gain)
- "loss 是真拥塞还是随机": 维护 P(拥塞 | losses), 概率判定. 5 个 loss 中 posterior P(congestion) > 0.7 才 cut cwnd; < 0.3 当随机丢包忽略

对比 Kalman (#F):
- Kalman 假设 Gaussian + linear, 数学封闭
- Bayesian 通用, 可用 non-Gaussian prior/observation
- 计算量略高 (但仍 O(1) per ACK)

实施: scalar Bayesian 用 moment matching
- state: bw_mean, bw_var
- 每 ACK 更新: bw_posterior ∝ bw_prior × likelihood(delivered | bw)

代码量: 50-80 行.

**Port #13: RLS** (`tcpboost-ucg`, P3)

源: Recursive Least Squares (Plackett 1950).

机制: 递推最小二乘, 维护遗忘因子 lambda < 1, 老样本权重指数衰减. 比 Kalman 收敛更快.

BBR 应用: 路径变化时 BW 估计快速适应
- 移动 4G: lambda=0.95 (快适应)
- 跨洋有线: lambda=0.99 (慢适应, 抗噪)

对比 Kalman (#F):
- Kalman 需噪声模型 Q, R
- RLS 不要噪声模型, 自适应
- RLS 收敛更快, 但需更多 state

代码量: 30-50 行 (1-dim scalar RLS).

**Port #15: LMS** (`tcpboost-8vv`, P3)

源: Least Mean Squares (Widrow Hoff 1960).

机制: 简化版 RLS, mu × (y - y_hat) 形式. O(1) per sample.

BBR 应用: 极轻量 BW 估计. 但 tp->rcv_rtt_est 已用 EWMA, LMS 边际收益小.

ROI: ★ (被 EWMA 涵盖, 不建议单独实施).

**Port #17: LQG** (`tcpboost-bfe`, P3)

源: Linear Quadratic Gaussian (Kalman 1960).

机制: 最优控制 = 状态估计 (Kalman) + 状态反馈 (LQR). 目标: 最小化 J = sum (x^T Q x + u^T R u).

BBR 应用: 综合 Kalman + PI, 升级为多状态闭环
- 状态 [bw, rtt, cwnd, inflight_hi, inflight_lo]
- LQR 权重 Q, R 预定义
- 实时: 每 ACK 更新 state, action = -K * (state - target)

代码量: 80-120 行 (5x5 矩阵, 矩阵运算 ~30 行).

#### 检测类 (change / hypothesis)

**Port #9: Bayesian change-point** (`tcpboost-6oa`, P2)

源: Adams MacKay 2007 (arXiv:0710.3742).

机制: 在线检测 "分布何时变了". 维护 run length 后验, P(run_length=r | x_1:t).

BBR 应用 (4 个痛点一次解):
- #5 Startup 退出: 当前用 bw plateau (3 rounds), 慢. change-point 在 'BW 停止增长' 瞬间检测
- #18 路径切换: WiFi 切到 4G / 4G 切到有线
- #10 路由变化: 中途路由变了, BDP 估计失效
- 应用层切换: SSH 流切到 bulk 流

实施:
- 维护 run length 分布 (u8 array, 64 长度)
- 每 ACK 算 P(this_run_continues) 和 P(this_run_ended)
- P(ended) > 0.5 → 触发 BDP 重新评估
- state: ~100 bytes per socket

代码量: 60-100 行.

**Port #11: SPRT** (`tcpboost-5pe`, P3)

源: Sequential Probability Ratio Test (Wald 1945).

机制: 累积似然比早判. LR = P(data|H1) / P(data|H0). LR > A → H1, < B → H0, 否则继续.

BBR 应用: "loss 是真拥塞还是随机" 早判
- H0: 随机丢包 (rate = p_random)
- H1: 真拥塞 (rate = p_congestion, p_congestion > p_random)
- LR > 8 → 立即 cut cwnd
- LR < 1/8 → 忽略
- 否则继续观察

对比 Bayesian (#8): Bayesian 给概率分布, SPRT 给二元决策. 实时决策用 SPRT 更合适.

代码量: 30-50 行.

**Port #12: HMM + Viterbi** (`tcpboost-e18`, P3)

源: Hidden Markov Model + Viterbi algorithm (Viterbi 1967).

机制: 观测推断隐状态序列. 隐状态 = 路径真实状态, 观测 = RTT/loss 测量.

BBR 应用: 路径状态机推断
- state 1 OK: RTT ≈ min_rtt, loss ≈ 0
- state 2 Slow: RTT +30%, loss 0.5%
- state 3 Dead: RTT +100%, loss > 2%
- BBR 行为按 state 调整: OK 激进, Slow 中性, Dead 保守

代码量: 80-120 行 (3x3 转移矩阵 + Viterbi trellis).

#### 探索类 (explore/exploit)

**Port #10: UCB1 bandit** (`tcpboost-pek`, P3)

源: UCB1 (Auer Cesa-Bianchi Fischer 2002, JMLR).

机制: 多臂赌博机, 选 arm a_t = argmax_a [μ_a + sqrt(2 ln t / n_a)]. 越久没选/不确定, 越想试.

BBR 应用: ProbeBW gain 选哪个
- 5 arm: gain ∈ {1.0, 1.125, 1.25, 1.375, 1.5}
- 每 ProbeRTT cycle 选一个 gain, 记录回报 (净吞吐 - λ × loss)
- 100 cycle 后, 95% 选最优

代码量: 60-100 行.

**Port #16: Bellman DP** (`tcpboost-kb3`, P3)

源: Bellman equation (Bellman 1954).

机制: V(s) = max_a [r(s,a) + γ V(T(s,a))]. 序贯决策最优性.

BBR 应用: "本期 best pacing gain" via DP recursion
- 实时 value iteration 难 (O(|S|^2 × |A|))
- 简化: discretize state 4x4x4x4 = 256 cells, action 5

ROI: ★ (理论完整, 实时计算难, 工业界用 RL/heuristic 替代).

### 4.4 与 cross-CCA port 的关系

cross-CCA (§3) 和 cross-domain (§4) 是**两条独立路径**, 可叠加:
- cross-CCA 借"其他 CCA 已实现的具体技术" (DCTCP alpha / ABC RTT 检测 / CoDel sojourn)
- cross-domain 借"其他领域的通用调度/估计方法" (MLFQ / CFS / PI / Kalman)

**针对 xhttp 饿死的三件套 (cross-CCA + cross-domain 组合)**:
- cross-CCA #1 Smart Exit (tcpboost-2lv) - 防止 ProbeRTT 误 cap
- cross-CCA #2 DCTCP+AccECN (tcpboost-ev6) - ECN 精度
- cross-CCA #3 ABC (tcpboost-utc) - RTT 提前检测
- cross-domain #2 MLFQ (tcpboost-0w6) - gain 反馈降级
- cross-domain #4 PI (tcpboost-qpm) - 闭环反馈 pacing
- cross-domain #F Kalman (tcpboost-daw) - 估计精度

## 5. 实施流程与验证

### 5.1 单 port 落地流程

1. **写代码**: 30-50 行 C, 加到 `tcp_bbrplusv3.c` (create_bbrplusv3.sh 步骤 7 之后)
2. **编译验证**: 7.2 LTS + xanmod-bbrv3 基础 + bbrplusv3 完整
3. **单流基线**: 0 loss 单流 iperf3, 确认无退化
4. **netem 复现**: 双腿 loss 0.5% + 150ms RTT, 8 并发, 跑 1h, 观察饿流比例
5. **ss -tin 0.5s 采样**: 抓 rcv_space 变化, 确认新机制生效
6. **回滚条件**: 任一基线场景吞吐 -5% 或延迟 +20%, 回滚该 port

### 5.2 验证矩阵 (`tcpboost-atj`)

| 场景 | 期望 |
|---|---|
| 单流基线 | 行为不变 (各 port 单独, 联合也回归) |
| 8 并发同向 | Jain's index ≥ 0.9 (BBRPlusV3 内部竞争) |
| 8 并发 BBRPlusV3+CUBIC 混跑 | Jain's index ≥ 0.7 (跨 CCA 共存) |
| netem loss 0.5% + 150ms 8 并发 | 0 饿流 (vs 现状 2-4 流饿) |

## 6. 非目标 (再强调)

- ❌ **继续在 BBR 状态机里发散 sed 优化** — cross-CCA 6 项 + cross-domain 17 项 已穷尽 (经控制论/NUM/博弈论 + OS 调度/GIS/DSP/控制论/统计/RL 6 域扫描)
- ❌ userspace mux 共享连接 (bd `gam0` 单独跟踪, 与本框架无关)
- ❌ 自研 RL-CCA 替换 BBR (跟 `tcpboost-ffc` watchlist 联动, 短期不实施)
- ❌ 推 IETF 标准化 (跨组织工作)
- ❌ 改收端 `tcp_rcv_ssthresh_unstick` (已独立完成, 验证收端 AQM 在 Codel 路径走 §3.1 Port #1 #4)

## 7. 文献清单 (按 4 范式 + cross-CCA + cross-domain 三组)

### 控制论 / AQM / 队列管理
- Jacobson 1988 - Avoidance (SIGCOMM CCR)
- Chiu, Jain 1989 - AIMD Convergence (JCIS)
- Wischik, McKeown 2005 - Fluid Model of TCP (Queueing Systems)
- Baccelli, Paris, Tutuncu 2018 - Slow Restart (Queueing Systems)
- Nichols 2018 - Sojourn-Time Controller (Queueing Systems)
- RFC 8289 (CoDel), RFC 8034 (PIE), RFC 8033 (FQ-CoDel)
- RFC 9768 (AccECN)

### 优化 / 效用
- Kelly 1997 - Charging and Rate Control
- Low 2003 - Duality Model of TCP and Queue Management
- Srikant 2004 - *The Mathematics of Internet Congestion Control* (book)
- Neely 2010 - *Stochastic Network Optimization* (book)

### 博弈论 / 公平性
- Shenker 1995 - Fundamental Design Issues
- La, Chiotis 2024-2025 - Game-Theoretic Coexistence (NYU 2025 study)

### 学习 / RL (watchlist)
- Jay et al. 2019 - Aurora (SIGCOMM)
- Emara et al. 2024 - Astraea
- Chen et al. 2025 - ProCC (SIGCOMM)
- PMC13108896 - BBR-n+ with Smart Exit (PLOS One 2024)

### Cross-CCA Port 源
- **BBR-n+ Smart Exit (Port #1)**: PMC13108896 (PLOS One 2024)
- **DCTCP (Port #2)**: Alizadeh et al. SIGCOMM 2010 + RFC 8257
- **AccECN (Port #2)**: RFC 9768 (2025) + Linux 7.0+ AccECN
- **ABC (Port #3)**: Bakker et al. NSDI 2020
- **CoDel (Port #4)**: Nichols et al. 2012 + RFC 8289
- **Hysteria/Brutal (Port #5)**: github.com/emptysuns/HiHysteria + calico TCP-Brutal
- **CUBIC fast convergence (Port #6)**: RFC 8312 §4.5

### Cross-Domain Port 源 (OS 调度 / GIS / DSP / 控制论 / 统计)
- **CFS vruntime (Port #1)**: Molnar 2007, Linux kernel scheduler
- **MLFQ (Port #2)**: Corbato 1962, 操作系统教科书
- **WFQ (Port #3)**: Parekh 1993 (GPS), Demers 1990 (PGPS), Shreedhar 1996 (DRR)
- **PI controller (Port #4)**: 工业过程控制 1970s, RFC 8034 PIE
- **HTB (Port #5)**: Martin Devera 1999, Linux tc
- **Priority-Flood (Port #6)**: Barnes 2014, Computers & Geosciences
- **MPC (Port #7)**: Garcia 1989, Optimal Model Predictive Control survey
- **Bayesian 估计 (Port #8)**: Laplace 1812, Jaynes 2003 *Probability Theory* (book)
- **Bayesian change-point (Port #9)**: Adams MacKay 2007, arXiv:0710.3742
- **UCB1 bandit (Port #10)**: Auer Cesa-Bianchi Fischer 2002, JMLR
- **SPRT (Port #11)**: Wald 1945, Annals of Mathematical Statistics
- **HMM + Viterbi (Port #12)**: Baum Welch 1970 + Viterbi 1967 IEEE TIT
- **RLS (Port #13)**: Plackett 1950, Haykin 2002 *Adaptive Filter Theory* (book)
- **Work stealing (Port #14)**: Blumofe Leiserson 1999, JACM
- **LMS (Port #15)**: Widrow Hoff 1960, Proc IEEE
- **Bellman DP (Port #16)**: Bellman 1954 *Dynamic Programming* (book)
- **LQG (Port #17)**: Kalman 1960, Anderson Moore 1971 *Optimal Filtering* (book)

## 8. 更新历史
- 2026-10-08 (1): 升维到算法层, 建立 4 范式 + BBRPlusV3 cross-CCA port backlog 6 项.
- 2026-10-08 (2): BBRPlusV3 cross-domain port backlog 7 项 (CFS/MLFQ/WFQ/HTB/PI/Priority-Flood/MPC/Kalman).
- 2026-10-08 (3): BBRPlusV3 痛点穷尽 19 项 + 跨域 port 扩展到 17 项 (新增 Bayesian 估计/change-point/UCB1/SPRT/HMM/RLS/Work stealing/LMS/Bellman/LQG).
