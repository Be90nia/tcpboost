# BBRPlusV3 跨域 Port 深扒 (5 个 P2 全部摸透)

> **目的**: 把 backlog 中优先级最高的 5 个 P2 port 读到原始 paper / RFC, 精确到 BBRPlusV3 代码位置 + 风险/边界
> **范围**: cross-domain #1 (Smart Exit), #2 (MLFQ), #14 (Work stealing), #9 (Bayesian change-point), #4 (PI controller)
> **bd 跟踪**: `tcpboost-2lv`, `tcpboost-0w6`, `tcpboost-9tu`, `tcpboost-6oa`, `tcpboost-qpm`

---

## 0. 真移植 vs 贴牌 — 诚实分级表 (2026-10-08 晚用户原话驱动)

> **用户原话**: "说真的我们的优先浸没算法能用到 BBR? 用不了吧??" — 是的,真的.
> **核心原则**: 跨域 port 必须满足**算法本体 (而非仅数据结构/思想) 能直接套用**,否则就是贴牌.

| 等级 | 标准 | 例子 |
|---|---|---|
| ✅ **真移植** | 算法公式/规则/数据结构直接套 BBR, 行为可预测 | Smart Exit, MLFQ, PI, Bayesian change-point, Work stealing, CFS, WFQ, Kalman, DCTCP+AccECN, ABC |
| ⚠️ **半真** | 框架对, 但 BBR 场景下问题简化为 toy, 或参数难拟合 | UCB1 bandit (ProbeBW gain 选哪个本来就是 4 相位), HMM-Viterbi (3 状态 emission matrix 难拟合), SPRT (2-decision, 简化), MPC (8 步预测, BBR 非线性) |
| ❌ **贴牌** | 仅借用数据结构或思想, 算法本体不适配 | **Priority-Flood (邻居结构不存在)**, LMS (EWMA 覆盖), Bellman DP (算力不可行), LQG (BBR 非线性), RLS (Kalman 覆盖) |

**已关闭的 7 个贴牌 P3** (2026-10-08 晚):
- `tcpboost-8vv` LMS - EWMA 完全覆盖, 零边际收益
- `tcpboost-kb3` Bellman DP - 实时 value iteration 算力不可行
- `tcpboost-bfe` LQG - BBR 非线性, 线性假设违反
- `tcpboost-ucg` RLS - Kalman 已覆盖, RLS 无噪声模型在 BBR 噪声下脆弱
- `tcpboost-8bf` Priority-Flood - **邻居结构不存在**, 仅借用 PQ
- `tcpboost-pek` UCB1 bandit - ProbeBW gain 选哪个是 toy 问题
- `tcpboost-hw3` MPC - 8 步预测在 BBR 动态状态空间下难收敛

---

## 0.5 组合效应分析: 正正得负 & 负负得正 (2026-10-08 深夜)

> **用户原话**: "不要太早下结论..你要结合有可能负负得正呢??..也有可能正正得负呢.."
> **框架**: 单点评估不够, 必须 pair-wise interaction 分析. 同 Group 内多 port = 冲突高风险.

### Port 分组 (按打击变量)

| Group | Port | 打击变量 |
|---|---|---|
| A. 状态机 | 2lv Smart Exit | ProbeRTT exit 时机 |
| B. Gain 控制 | 0w6 MLFQ / qpm PI / b6t Hysteria | pacing_gain |
| C. 拥塞判定 | utc ABC / 6u8 CUBIC conv | cwnd/inflight |
| D. 估计 | daw Kalman / bgy Bayesian / 6oa change-point 部分 | bw/rtt estimate |
| E. 跨连接 | afi CFS / 9tu Work stealing / i6a HTB | 跨 conn 调度 |
| F. ECN | ev6 DCTCP+AccECN | ECN alpha |

### ⚠️ 正正得负 (5 个高危组合)

**❌ 1. MLFQ (0w6) × 现有 bbr_beta (0.3)** — ACD 教训重演
- 单独 MLFQ L2 gain=0.7 OK; 单独 beta cwnd=0.7×cwnd OK
- 组合: `0.7 × 0.7 = 0.49` — **双重惩罚**, Plan.md 2.5 移除 ACD 的原因
- **缓解**: MLFQ level 2 时**禁用 beta cut**, 或 beta 仅在 level 0 生效

**❌ 2. MLFQ (0w6) × PI controller (qpm)** — 离散 vs 连续打架
- MLFQ 离散 level jump (1.375→1.0→0.7), PI 连续 (Kp×err + Ki×∫err)
- MLFQ 跳 level 时, PI 看到大 err, 积分累积; MLFQ 回来时 PI 积分反向 → **振荡**
- **缓解**: MLFQ 管 coarse level, PI 只在 level 内 fine adjust (PI 输出限幅 ±10%)

**❌ 3. MLFQ (0w6) × ABC (utc)** — 同一拥塞信号双重响应
- MLFQ loss/ECN → level++; ABC RTT +50% → cwnd -1 MSS
- RTT + loss 同时出现 → **过度退让**
- **缓解**: MLFQ 只看 loss/ECN, ABC 只看 RTT inflation (无 loss 时)

**⚠️ 4. Bayesian estimation (bgy) × Kalman (daw)** — 冗余状态
- 都是更好的 BW 估计; 若噪声 Gaussian 则等效
- 双份 state, 可能不一致
- **裁定**: 选 Kalman (成熟); bgy 降 P3

**⚠️ 5. Change-point (6oa) × Kalman (daw)** — 误触发 reset
- Change-point 误触发 (噪声当变化) → 破坏 Kalman 平滑估计
- **缓解**: change-point 阈值调高 (P(ended) > 0.7, 不是 0.5)

### 💡 负负得正 (2 个组合)

**💡 1. Work stealing (9tu) + HTB (i6a)** — 互相补救
- Work stealing 单独: steal 循环可能反循环
- HTB 单独: 仅 cgroup 场景
- **组合**: HTB per-cgroup rate ceiling **限死 steal 速率**, steal 无法跑飞

**💡 2. HMM (e18) + SPRT (5pe)** — 分层决策
- HMM 单独: 3 状态 emission matrix 难拟合
- SPRT 单独: 2-decision 太简单
- **组合**: HMM 做 coarse classification (OK/Slow/Dead), SPRT 在每个 HMM state 内做 fine decision

### ✅ 安全组合 (跨 Group, 互不干扰)

| Port 组合 | 原因 |
|---|---|
| Smart Exit + 任何 | 只管 ProbeRTT exit, 不碰 gain/cwnd |
| DCTCP+AccECN + 任何 | 只管 ECN alpha, 正交于 cwnd/gain |
| CoDel sojourn + 任何 | 只管 DRAIN/ProbeRTT exit 时机 |
| **Smart Exit + PI + DCTCP** | A/B/F 三 Group, **推荐第 1 批三件套** |

### 🎯 修订的部署批次

**第 1 批 (零冲突, 稳赚)**:
- 2lv Smart Exit + 5cs CoDel sojourn + ev6 DCTCP+AccECN
- 3 个独立 Group, 验证基线

**第 2 批 (单独上, 严格回归)**:
- qpm PI + daw Kalman + utc ABC
- 每个单独上, 不叠加, 各自跑 0-loss 基线 + netem 复现

**第 3 批 (高风险, 需重设计)**:
- 0w6 MLFQ (与 beta/PI/ABC 三重冲突)
- 6oa change-point (阈值调高)
- bgy Bayesian est (降 P3 或关闭)

**第 4 批 (场景化)**:
- 9tu Work stealing + i6a HTB (负负得正)
- afi CFS (Work stealing 被动版)
- b6t Hysteria variance

**保留下来的 24 个 open**:
- 10 个真移植 P2 (5 深扒 + 5 待深扒)
- 4 个 cross-CCA P3 (5cs / 6u8 / b6t / a9x / atj)
- 3 个半真 P3 (5pe / e18 / i6a)
- 3 个 umbrella (hu2 / 86e / 9l5)
- 1 个 watchlist (ffc)
- 3 个独立 (yve / a9x / atj - 实际重复统计)

---

## 1. Smart Exit (BBR-n+ Algorithm 1) — `tcpboost-2lv`

### 1.1 原始 paper

**Ahsan, M. & Hussain, M. (2026)** "BBR-n+ congestion control: Real-time performance with smart exit and advanced AQMs." *PLOS One* 21(4): e0330972. PMID 42030353.
**DOI**: 10.1371/journal.pone.0330972
**GitHub**: <https://github.com/ahsanjamil88/BBR-n-plus> (待核实, 这是 BBR-n+ 作者仓库, tcpboost 落地前需先读其源码)

### 1.2 算法核心 (Algorithm 1 原文, Ahsan 2026 §2.3.1)

```c
// Algorithm 1: BBR-n+ Startup Exit Condition with RWND Limitation Detection
// Input: current_bw, current_rtt, min_rtt, full_bw, full_bw_cnt
// Parameters: α=0.85, N=3, Δ=5ms
// Output: stay_in_startup (bool)

// 1. Thresholds
bw_thresh = α × full_bw           // α = 0.85
rtt_diff   = current_rtt - min_rtt

// 2. RWND-limited state detection
if (current_bw < bw_thresh) AND (rtt_diff > Δ)   // Δ = 5ms
    full_bw_cnt++
else
    full_bw = current_bw          // reset plateau counter
    full_bw_cnt = 0

// 3. Exit decision
stay_in_startup = (full_bw_cnt < N)              // N = 3
```

**双条件检测原理**:
- (1) `current_bw < 0.85 × full_bw` → 吞吐量停在 plateau
- (2) `rtt_diff > 5ms` → 队列真在涨 (RTT inflation)

**关键洞察**: RWND-limit 时, **没有 RTT inflation** (因为 TCP sender 主动限速了, 没压瓶颈). 所以双条件 AND 排除 RWND 误判.

### 1.3 BBRPlusV3 集成位置

**核心函数**: `bbr_check_probe_rtt_done()` (BBRPlusV3 步骤 4 状态机 ProbeRTT 退出)

**当前 BBRPlusV3 逻辑** (Borne from BBRv3 line 919-944):
```c
if (bbr_param(sk, probe_rtt_mode_ms) > 0 && probe_rtt_expired &&
    !bbr->idle_restart && bbr->mode != BBR_PROBE_RTT) {
    bbr->mode = BBR_PROBE_RTT;
    ...
}
```

**修改** (加 Smart Exit gate):
```c
// tcpboost-SmartExit-1: 双条件 gate, 防止 RWND-limit 误判
static bool bbr_smart_exit_check_rwnd_limit(struct sock *sk, struct bbr *bbr) {
    u32 current_bw = bbr_max_bw(sk);          // BBR 已有
    u32 min_rtt    = bbr->min_rtt_us;
    u32 cur_rtt    = tcp_sk(sk)->rcv_rtt_est.rtt_us;
    
    // 1. 计算阈值 (与 Ahsan 2026 一致)
    u32 bw_thresh = (bbr->full_bw_now ? bbr->full_bw : 0) * 85 / 100;
    u32 rtt_diff  = (cur_rtt > min_rtt) ? (cur_rtt - min_rtt) : 0;
    
    // 2. 双条件 AND
    if (current_bw < bw_thresh && rtt_diff > 5000 /* 5ms in us */)
        return true;   // 是真 plateau, 退出
    return false;      // 是 RWND-limit, 不退出
}

// bbr_check_probe_rtt_done() 内 (约 line 940):
if (bbr->probe_rtt_done_stamp && after(tcp_jiffies32, bbr->probe_rtt_done_stamp)) {
    if (bbr_smart_exit_check_rwnd_limit(sk, bbr)) {
        bbr_exit_probe_rtt(sk);
    } else {
        // RWND-limit, 延后退出, 让 BBR 继续探
        bbr->probe_rtt_done_stamp = tcp_jiffies32 + 
                                     msecs_to_jiffies(bbr_param(sk, probe_rtt_mode_ms));
    }
}
```

### 1.4 性能预期 (Ahsan 2026 实测)

| 场景 | 改善 |
|---|---|
| 64KB RWND 限制 | 15-20% median throughput 提升 |
| HTTP 延迟 (vs BBRv3) | -150ms |
| HTTP 延迟 (vs Cubic) | -300ms |
| Ping 延迟 (wired) | -17% (vs BBRv3), -45% (vs Cubic) |
| 8+ 流与 Cubic 共存 | **未改善** (论文明确: BBR-n+ 仍继承 BBRv3 公平性缺陷) |

### 1.5 风险与边界

| 风险 | 缓解 |
|---|---|
| α=0.85 / Δ=5ms 是 hardcoded, 不同场景需调 | 加 `module_param smart_exit_alpha, smart_exit_delta_us` 暴露 |
| 与 A4 (PROBE_RTT freeze lower_bound) 冲突 | A4 是单向冻结, Smart Exit 是 gate 退出, 互不冲突 |
| RWND 限制来源复杂: 应用层 stall 也可能 | 加 `is_app_limited` 排除 (Smart Exit 只在 non-app-limited 触发) |
| ProbeRTT 永驻不退 (极端 RWND 场景) | 加 max wait (默认 1s), 强制退出 |

### 1.6 测试矩阵

- **0 loss 单流**: 行为不变 (Smart Exit 默认 alpha=0.85, 不影响 ProbeRTT 通过)
- **64KB RWND 强制限制** (sysctl net.ipv4.tcp_rmem="4096 8192 65536"): 期望 +15-20% 吞吐
- **netem loss 0.5% 8 并发**: 期望 0 饿流 (主要靠 Smart Exit)
- **8 并发 1 vs 7 (混合)**: 期望 Jain's index ≥ 0.85 (RWND 限制被正确识别)

---

## 2. MLFQ (Multi-Level Feedback Queue) — `tcpboost-0w6`

### 2.1 原始 paper / 来源

**Corbato, F. J., Daggett, M. M., Daley, R. C. (1962)** "An Experimental Time-Sharing System." *IFIPS 1962*. (CTSS - 首创 MLFQ)
**Arpaci-Dusseau, R. H. (2018)** "Operating Systems: Three Easy Pieces" Chapter 8. <https://pages.cs.wisc.edu/~remzi/OSTEP/cpu-sched-mlfq.pdf> (教科书标准实现)
**Solaris TS 调度器** (AD00): 60 队列, quantum 20ms (top) → 几百ms (bottom), boost 1s
**FreeBSD 4.3**: decay-usage 公式, 不直接 MLFQ

### 2.2 算法核心 (5 Rules, Arpaci-Dusseau OSTEP §8.1-8.6)

```text
Rule 1: If Priority(A) > Priority(B), A runs.
Rule 2: If Priority(A) = Priority(B), A & B run in RR.
Rule 3: New job → highest priority (topmost queue).
Rule 4: Used up allotment at level → demote (next lower queue).
Rule 5: After period S, all jobs → topmost queue (anti-starvation).
```

**Parameters**:
- **Quantum per level**: 顶部 10ms, 底部 100s ms (几何递增)
- **Allotment**: 一个 job 在某 level 能用多久
- **Boost period S**: 默认 1s
- **# queues**: Solaris 60, Linux (2.6 O(1) scheduler) 140 levels

**核心思想**: 长跑 CPU-bound job 慢慢沉到底, 短跑交互 job 留顶部. 反馈 (feedback) = history → predict future.

### 2.3 BBRPlusV3 集成 (Cross-Domain #2 详细设计)

**3-level MLFQ for BBRPlusV3 pacing_gain**:

| Level | pacing_gain UP | pacing_gain DOWN | 行为 | 触发条件 |
|---|---|---|---|---|
| 0 (top) | 1.375 | 0.85 | 激进探 | 持续 1s 无 loss/ECN, RTT 稳定 |
| 1 (mid) | 1.0 | 0.85 | 持平 | 偶发 loss 或 ECN |
| 2 (bottom) | 0.7 | 0.7 | 保守 | 持续 0.5s loss 或 ECN > 50% |

**实施位置**: `bbr_set_pacing_gain()` 内 (BBRPlusV3 由 `bbr_main` 调用)

```c
// tcpboost-MLFQ-1: 3-level MLFQ for pacing gain
enum bbr_mlfq_level { BBR_MLFQ_L0_AGGRESSIVE, BBR_MLFQ_L1_NEUTRAL, BBR_MLFQ_L2_CONSERVATIVE };

static void bbr_mlfq_update(struct sock *sk, struct bbr *bbr, 
                            u32 loss_event, u32 ecn_event) {
    u32 now = tcp_jiffies32;
    if (loss_event || ecn_event) {
        bbr->mlfq_loss_count++;
        bbr->mlfq_last_event = now;
        if (bbr->mlfq_level < BBR_MLFQ_L2_CONSERVATIVE &&
            bbr->mlfq_loss_count >= 5) {     // 持续 5 个事件降级
            bbr->mlfq_level++;
            bbr->mlfq_loss_count = 0;
        }
    } else if (now - bbr->mlfq_last_event > 1000 /* 1s boost period */) {
        if (bbr->mlfq_level > BBR_MLFQ_L0_AGGRESSIVE) {
            bbr->mlfq_level--;
            bbr->mlfq_loss_count = 0;
        }
    }
    // Rule 5: 每 1s boost 一次, 不论 history
    if (now - bbr->mlfq_last_boost > 1000) {
        bbr->mlfq_level = BBR_MLFQ_L0_AGGRESSIVE;  // 全部回顶
        bbr->mlfq_last_boost = now;
    }
}

static int bbr_mlfq_get_pacing_gain(struct sock *sk, struct bbr *bbr) {
    switch (bbr->mlfq_level) {
        case BBR_MLFQ_L0_AGGRESSIVE: return bbr_param(sk, pacing_gain_up_l0);
        case BBR_MLFQ_L1_NEUTRAL:    return BBR_UNIT;
        case BBR_MLFQ_L2_CONSERVATIVE: return bbr_param(sk, pacing_gain_up_l2);
    }
    return BBR_UNIT;
}
```

**集成入口** (在 bbr_set_pacing_rate 中):
```c
bbr->pacing_gain = bbr_mlfq_get_pacing_gain(sk, bbr);
```

### 2.4 风险与边界

| 风险 | 缓解 |
|---|---|
| Gaming: 流故意短暂 loss 触发降级, 占便宜 | 需要 cwnd-based feedback (而非 loss rate) |
| 频繁升降级 | 加 hysteresis (已用 mlfq_loss_count >= 5) |
| Rule 5 boost 太频繁破坏 probe | boost 周期默认 1s, 不可配 |
| 与现有 Profile 系统冲突 | MLFQ level 作为 Profile 内部子状态 |

### 2.5 测试矩阵

- **0 loss 单流**: MLFQ 永远 L0, 行为不变
- **稳定 +RTT +loss 单流**: MLFQ 升 L2 后 1s 自动回 L0
- **8 并发同向**: 输家流 0.5s 升 L2, 增益 0.7; 健康流 L0, 增益 1.375 → 输家快速恢复
- **RTT 抖动 + loss 持续**: 维持 L2, 保守行为

---

## 3. Work Stealing (Blumofe-Leiserson 1999) — `tcpboost-9tu`

### 3.1 原始 paper

**Blumofe, R. D. & Leiserson, C. E. (1999)** "Scheduling multithreaded computations by work stealing." *Journal of the ACM* 46(5): 720-748.
**PDF**: <https://www.csd.uwo.ca/~mmorenom/CS433-CS9624/Resources/Scheduling_multithreaded_computations_by_work_stealing.pdf>
**应用**: Cilk (MIT), TBB (Intel), Go scheduler, Tokio (Rust), Java ForkJoinPool

### 3.2 算法核心 (Work-Stealing Algorithm)

**数据结构**: per-processor **ready deque** (double-ended queue)
- **Top**: 被偷的线程 (LIFO - 后进先出)
- **Bottom**: 自己的线程 (stack-like, push/pop)

**4 Rules** (per processor):
```text
(1) Spawns:    push parent to bottom, work on child
(2) Stalls:    pop bottom of own deque; if empty → start work stealing
(3) Dies:      same as stalls
(4) Enables:   push enabled thread to bottom of own deque
```

**Work stealing step** (when idle):
```text
1. Thief picks random victim
2. If victim's deque non-empty: pop top (steal), work on it
3. If empty: retry with different victim
```

**关键定理**:
- **Theorem 1 (Greedy)**: T(schedule) ≤ T₁/P + T_∞
- **Theorem 5 (Space)**: S(schedule) ≤ S₁P for fully strict computations
- **Communication**: O(PT_∞(1+n_d)S_max) - 比 work-sharing 少

**Busy-leaves property**: at every time step, every leaf in spawn subtree has a processor working on it.

### 3.3 BBRPlusV3 集成 (Cross-Domain #14 详细设计)

**挑战**: BBRPlusV3 是 per-sock 单 connection 视角, work stealing 需要**跨 connection 协调**——这是 kernel 内 BBR 无法直接做的。

**两个落地方案**:
- **方案 A (userspace daemon + BPF)**: 适合 server (xray ingress) 大量 connection
- **方案 B (cgroup 级别)**: 适合容器化部署

**方案 A 设计**:
```c
// tcpboost-WorkSteal-1: per-sock BBR state extension
// 新增: bbrplusv3_vruntime + 共享 priority queue
struct bbrplusv3_ws_state {
    u64  vruntime;           // CFS-style 累积虚拟时间
    u32  deficit;            // DRR-style 不足量
    struct list_head ws_node; // 链入全局 priority queue
};

// tcp_pacing_check() hook: 选 vruntime 最小者
// (需要 BPF 拦截或 kernel cross-sock 协调)
```

**算法映射**:
- **Ready deque**: per-cgroup 的"饿死流 vruntime 队列"
- **Top (steal)**: 饿死流从忙流偷"剩余带宽"
- **Bottom (own)**: 流自己用自己 quota
- **Steal 触发**: vruntime 最小者 (饿死) 主动向 vruntime 最大者 (忙) 借

**vs CFS (#1)**:
- CFS: 排 pacer 顺序, 饿死流自然先被服务 (passive)
- Work Stealing: 饿死流**主动**"偷"忙流的额度 (active)
- 主动版更及时, 但需更多 state 维护

### 3.4 风险与边界

| 风险 | 缓解 |
|---|---|
| BBR 是 per-sock, 跨 sock 需 BPF/HTB 协调 | 单 cgroup 内 OK, 跨 cgroup 需 net_sched 集成 |
| Work stealing 增加 cross-conn 通信 | 阈值触发 (仅 vruntime 差距 > X 才 steal) |
| 饿死流 "偷" 可能反循环 | 限速: 偷的最大速率 = min(stealer_credit, victim_spare) |
| Linux kernel BPF 复杂度 | 方案 B (cgroup level) 可用 `net_cls` + HTB 替代, 不改 BBR |

### 3.5 测试矩阵

- **0 loss 单流**: vruntime 0 → 不参与 steal, 行为不变
- **8 并发同向 BBRPlusV3 (xhttp 复现)**: 饿死流 vruntime 最小, 主动偷健康流 0 饿死
- **混合 CCA (BBR + CUBIC)**: 偷带宽边界需 BPF 跨 CCA 协调, 复杂, 标 P3
- **容器化 (cgroup)**: 方案 B 验证

---

## 4. Bayesian Online Change-Point Detection — `tcpboost-6oa`

### 4.1 原始 paper

**Adams, R. P. & MacKay, D. J. C. (2007)** "Bayesian Online Changepoint Detection." arXiv:0710.3742.
**PDF**: <https://arxiv.org/pdf/0710.3742>
**应用**: 过程控制, EEG, DNA 分割, 经济计量, 气候变迁

### 4.2 算法核心 (Algorithm 1, Adams-MacKay 2007)

**核心思想**: 维护 "run length" 后验分布 P(r_t | x_{1:t})
- r_t = "当前这个分布已持续多久"
- 变化点 (changepoint) = r_t 跳回 0

**Algorithm 1 步骤** (10 步):
```text
1. Initialize: P(r_0 = 0) = 1
2. Observe x_t
3. Evaluate predictive probability: π_t^{(r)} = P(x_t | ν_t^{(r)}, χ_t^{(r)})
4. Growth: P(r_t = r_{t-1}+1) = P(r_{t-1}, x_{1:t-1}) × π_t^{(r)} × (1 - H(r_{t-1}))
5. Changepoint: P(r_t = 0) = Σ_{r_{t-1}} P(r_{t-1}, x_{1:t-1}) × π_t^{(r)} × H(r_{t-1})
6. Evidence: P(x_{1:t}) = Σ_{r_t} P(r_t, x_{1:t})
7. Run length distribution: P(r_t | x_{1:t}) = P(r_t, x_{1:t}) / P(x_{1:t})
8. Update sufficient statistics: ν_{t+1}^{(0)} = ν_prior, ν_{t+1}^{(r+1)} = ν_t^{(r)} + 1
9. Predict: P(x_{t+1} | x_{1:t}) = Σ_{r_t} P(x_{t+1} | x_t^{(r)}, r_t) × P(r_t | x_{1:t})
10. Return to step 2
```

**Hazard function**: H(τ) = P_gap(g=τ) / Σ_{t=τ}^∞ P_gap(g=t)
- 当 P_gap 是 geometric (exponential discrete): H(τ) = 1/λ (常数)
- 实际实现: λ = 250 (well-log 实验值), 默认 100-1000

**复杂度**:
- Worst case: O(t) per step
- Tail truncation (mass < 10^-4): O(E[r]) per step

### 4.3 BBRPlusV3 集成 (Cross-Domain #9 详细设计)

**解决的 4 个 BBR 痛点**:
1. **#5 Startup 退出**: 当前 full_bw plateau (3 round), change-point 能在 "BW 停止增长" 瞬间检测
2. **#18 路径切换**: WiFi → 4G, 4G → wired, 移动漫游
3. **#10 Inflight 更新节奏**: 路径变化时 inflight_hi/lo 需重置
4. **路由变化**: 中途路由变了, BDP 估计失效

**State 设计** (per-sock, ~100 bytes):
```c
struct bbrplusv3_cp_state {
    u32  cp_lambda;          // hazard rate (1/平均 run length)
    u32  cp_max_len;         // run length 数组最大长度, 默认 64
    u32  cp_bw_mean;         // 假设 Gaussian: 当前 run 的 bw 均值
    u32  cp_bw_var;          // 假设 Gaussian: 当前 run 的 bw 方差
    u32  cp_bw_n;            // 当前 run 累积样本数
    u32 *cp_run_prob;        // P(r_t | x_{1:t}) 数组
    u32  cp_run_prob_sum;    // 归一化常数
    u8   cp_bw_threshold;    // changepoint 触发阈值, 默认 0.5
};
```

**Hook 位置**: `bbr_update_model_parameters()` (每 ACK 触发)

```c
// tcpboost-ChangePoint-1: Bayesian change-point 检测
static void bbrplusv3_cp_update(struct sock *sk, struct bbr *bbr, u32 bw_sample) {
    struct bbrplusv3_cp_state *cp = &bbr->cp_state;
    
    // 3. Predictive probability (Gaussian)
    // π_t^{(r)} = N(bw_sample; μ_r, σ_r²)
    u32 sigma2 = max(cp->cp_bw_var, 1);
    s64 diff = (s64)bw_sample - (s64)cp->cp_bw_mean;
    u32 pi = exp_approx(-(diff * diff) / (2 * sigma2)) / sqrt(sigma2);
    
    // 4-5. Growth + Changepoint (vectorized)
    u32 new_run_prob[CP_MAX_LEN + 1] = {0};
    u32 sum = 0;
    for (u32 r = 0; r < cp->cp_max_len; r++) {
        // Growth
        new_run_prob[r + 1] += cp->cp_run_prob[r] * pi * (1 - H(cp_lambda, r));
        // Changepoint
        new_run_prob[0] += cp->cp_run_prob[r] * pi * H(cp_lambda, r);
        sum += new_run_prob[r + 1] + new_run_prob[0];
    }
    // Normalize
    for (u32 r = 0; r <= cp->cp_max_len; r++)
        cp->cp_run_prob[r] = new_run_prob[r] * 1000 / sum;  // 定点化
    
    // 6. Check changepoint
    if (cp->cp_run_prob[0] > cp->cp_bw_threshold * 1000) {
        // Changepoint detected! Reset bw estimate
        bbr->bw_lo = ~0U;
        bbr->bw_hi[0] = bw_sample;
        bbr->bw_hi[1] = bw_sample;
        bbr->inflight_latest = 0;
        bbr->inflight_hi = ~0U;
        // ... reset more
    }
    
    // 8. Update sufficient statistics
    cp->cp_bw_n++;
    cp->cp_bw_mean = cp->cp_bw_mean + (bw_sample - cp->cp_bw_mean) / cp->cp_bw_n;
    cp->cp_bw_var = cp->cp_bw_var + ((s64)bw_sample - (s64)cp->cp_bw_mean) * 
                              ((s64)bw_sample - (s64)cp->cp_bw_mean);
}

static u32 H(u32 lambda, u32 tau) {
    // For discrete exponential, H = 1/lambda
    return (tau == 0) ? (1000 / lambda) : 0;
}
```

### 4.4 风险与边界

| 风险 | 缓解 |
|---|---|
| Run length 数组固定大小, 长 run 溢出 | Truncation 阈值 (P < 10^-4 截断) |
| 浮点运算 (exp, sqrt) kernel 不友好 | 定点化 (×1000 整数运算) + 查表 |
| 误触发 changepoint (RTT 抖动) | 阈值从 0.5 调到 0.7 需更严 |
| 计算量: per-ACK O(run_length) | 64 长度 × per-ACK = ~64 次乘加, 可接受 |

### 4.5 测试矩阵

- **0 loss 单流稳定**: run_prob[0] 始终低, 不触发
- **WiFi → 4G 切换**: run_prob[0] 飙 1.0, 1 RTT 内触发, BDP 重估
- **4 流同步启动**: 不同 run 长度, 各自收敛
- **5% 突然 loss 注入**: 触发 changepoint, BBR 重置

---

## 5. PI Controller (RFC 8034 PIE / DOCSIS-PIE) — `tcpboost-qpm`

### 5.1 原始 RFC

**RFC 8034** (2017) "Active Queue Management (AQM) Based on Proportional Integral Controller Enhanced (PIE) for Data-Over-Cable Service Interface Specifications (DOCSIS) Cable Modems."
**RFC 8033** (2017) "Proportional Integral Controller Enhanced (PIE): A Lightweight Control Scheme to Address the Bufferbloat Problem." (the base PIE RFC)
**DOCSIS-PIE 算法**: Appendix A 完整 pseudocode, 是 PIE 的 DOCSIS 扩展版

### 5.2 算法核心 (DOCSIS-PIE control_path)

**Configuration Parameters**:
- LATENCY_TARGET (default 10ms)
- PEAK_RATE, MSR, BUFFER_SIZE

**Constants** (Appendix A.1.2):
- A = 0.25 (proportional weight)
- B = 2.5 (integral weight)
- INTERVAL = 16ms (update interval)
- BURST_RESET_TIMEOUT = 1s
- MAX_BURST = 142ms
- MEAN_PKTSIZE = 1024, MIN_PKTSIZE = 64
- PROB_LOW = 0.85, PROB_HIGH = 8.5
- LATENCY_LOW = 5ms, LATENCY_HIGH = 200ms

**3 States** (aqm_state_):
- INACTIVE: queue < BUFFER/3, 抑制 drop
- QUIESCENT: 过渡, 第一次 drop 后转 ACTIVE
- ACTIVE: 正常 AQM, 150ms burst protection

**Drop probability 更新 (per INTERVAL=16ms)**:
```c
control_path_init() {
    drop_prob_ = 0;
    qdelay_old_ = 0;
    burst_reset_ = 0;
    aqm_state_ = INACTIVE;
}

calculate_drop_prob() {
    if (queue.byte_length() <= msrtokens()) {
        qdelay = queue.byte_length() / PEAK_RATE;
    } else {
        qdelay = (queue.byte_length() - msrtokens()) / MSR + msrtokens() / PEAK_RATE;
    }
    
    if (burst_allowance_ > 0) {
        drop_prob_ = 0;
        burst_allowance_ = max(0, burst_allowance_ - INTERVAL);
    } else {
        // PI 控制律
        p = A × (qdelay - LATENCY_TARGET) + B × (qdelay - qdelay_old_);
        
        // Auto-tuning: drop_prob 越小, p 越被缩小 (避免过冲)
        if (drop_prob_ < 0.000001)      p /= 2048;
        else if (drop_prob_ < 0.00001)  p /= 512;
        else if (drop_prob_ < 0.0001)   p /= 128;
        else if (drop_prob_ < 0.001)    p /= 32;
        else if (drop_prob_ < 0.01)     p /= 8;
        else if (drop_prob_ < 0.1)      p /= 2;
        else if (drop_prob_ < 1)        p /= 0.5;
        else if (drop_prob_ < 10)       p /= 0.125;
        else                            p /= 0.03125;
        
        if (drop_prob_ >= 0.1 && p > 0.02)
            p = 0.02;  // 限幅
        
        drop_prob_ += p;
        
        // 特殊情况
        if (qdelay < LATENCY_LOW && qdelay_old_ < LATENCY_LOW)
            drop_prob_ *= 0.98;  // 指数衰减
        else if (qdelay > LATENCY_HIGH)
            drop_prob_ += 0.02;  // 紧急升
        
        drop_prob_ = clamp(drop_prob_, 0, PROB_LOW * MEAN_PKTSIZE / MIN_PKTSIZE);
    }
    
    // 状态机
    quiet = (qdelay < 0.5 × LATENCY_TARGET) && (qdelay_old_ < 0.5 × LATENCY_TARGET)
            && (drop_prob_ == 0) && (burst_allowance_ == 0);
    
    if (aqm_state_ == ACTIVE && quiet) aqm_state_ = QUIESCENT;
    else if (aqm_state_ == QUIESCENT) {
        if (quiet) { burst_reset_ += INTERVAL; if (burst_reset_ > 1s) aqm_state_ = INACTIVE; }
        else burst_reset_ = 0;
    }
    
    qdelay_old_ = qdelay;
}
```

**核心机制**:
- p = A × (qdelay - target) + B × (qdelay - qdelay_old_)
- A: proportional - 当前偏差
- B × Δqdelay: integral/delta - 偏差变化率
- Auto-tuning: 防止低 drop_prob 时的过冲

### 5.3 BBRPlusV3 集成 (Cross-Domain #4 详细设计)

**核心思想**: 用 PI 控制律替换 BBRPlusV3 的固定 pacing_gain UP=1.375 / DOWN=0.85

**类比**:
- LATENCY_TARGET → BBR target_throughput
- qdelay → 当前 throughput 偏差
- drop_prob_ → pacing_gain 调整量

```c
// tcpboost-PI-1: PI 控制器替换 BBRPlusV3 启发式 pacing_gain
struct bbrplusv3_pi_state {
    s32 pi_target_rate;      // bps, setpoint
    s32 pi_actual_rate;      // bps, 滑动平均 measured
    s32 pi_integrated_err;   // 累积误差
    s32 pi_kp;               // Kp, default 0.25
    s32 pi_ki;               // Ki, default 2.5
    u32 pi_last_update;      // jiffies of last update
    u32 pi_update_interval;  // 16ms 类似 INTERVAL
};

static s32 bbrplusv3_pi_compute(struct sock *sk, struct bbr *bbr) {
    struct bbrplusv3_pi_state *pi = &bbr->pi_state;
    
    // 1. 计算偏差
    s32 err = pi->pi_target_rate - pi->pi_actual_rate;
    
    // 2. PI 控制律
    s32 output = (pi->pi_kp * err + pi->pi_ki * pi->pi_integrated_err) / 1000;
    
    // 3. Anti-windup: 限幅
    output = clamp(output, -500, 500);  // ±50% 范围
    
    // 4. 累积分量
    pi->pi_integrated_err += err;
    pi->pi_integrated_err = clamp(pi->pi_integrated_err, -100000, 100000);
    
    return output;  // pacing_gain 调整量 (BBR_UNIT 单位)
}

// Hook: bbr_set_pacing_rate 中
bbr->pacing_gain = bbr_param(sk, pacing_gain_up) + 
                   bbrplusv3_pi_compute(sk, bbr) / BBR_UNIT;
```

### 5.4 风险与边界

| 风险 | 缓解 |
|---|---|
| Kp, Ki 调参 (0.25 / 2.5 是 DOCSIS 经验值) | 加 `module_param` 暴露, 用户可调 |
| Anti-windup 不当会过冲 | 限制 integrated_err 范围 |
| PI 输出可能负 → 增益 < 1 → 减 | clamp(output, -500, 500) |
| 16ms 更新间隔, 慢于 ACK (per-ACK) | per-ACK 更新 OK, 但要 throttle (避免 1ms 内多次更新) |
| 与 #2 MLFQ 冲突 (都是动态 gain) | MLFQ 调度 level, PI 在 level 内调微调 |

### 5.5 测试矩阵

- **0 loss 单流**: err=0, integrated_err 缓慢累积, 行为基本不变 (单流 baseline 强)
- **8 并发同向**: err 波动, PI 平滑
- **netem 0.5% loss**: err 持续负, integrated_err 负, PI 输出负, 增益减
- **路径切换 (4G→WiFi)**: target_rate 突变, PI 需 ~10 INTERVAL 收敛

---

## 6. 实施顺序与依赖

按依赖最小→最大, 风险低→高:

| 顺序 | Port | 风险 | 工作量 | 依赖 |
|---|---|---|---|---|
| **1** | **Smart Exit** (#1) | ★ | 30-50 行 C | 无 (独立函数) |
| **2** | **MLFQ** (#2) | ★★ | 30-50 行 C | 无 (state extension) |
| **3** | **PI Controller** (#4) | ★★★ | 40-60 行 C | 无 (state extension) |
| **4** | **Bayesian change-point** (#9) | ★★★ | 60-100 行 C | 无 (独立 state, 但需谨慎调参) |
| **5** | **Work stealing** (#14) | ★★★★ | 80-120 行 C + BPF | 需 BPF/HTB 集成, server 端 |

**集成建议**: 先 1+2+3 (单 connection 内, 独立), 验证无退化. 再上 4 (单 connection, 但需回归). 最后 5 (跨 connection, 最复杂).

## 7. 与 cross-CCA port 的组合效应

5 个 P2 + 之前 5 个 P2 cross-CCA = **10 个 P2 候选** (Smart Exit / DCTCP+AccECN / ABC / CFS / MLFQ / Bayesian / change-point / Work stealing / Kalman / PI).

**针对 xhttp 饿死的三件套** (推荐组合):
1. Smart Exit (防止 ProbeRTT 误 cap)
2. MLFQ (输家流自动降级 + 1s boost 避免饿死)
3. Work stealing (跨流主动偷带宽)

**估计综合收益**:
- 0 饿流 (vs 现状 2-4 流饿)
- 整体吞吐 +10-20% (variance-aware 优化)
- RTT 波动 -30% (PI 平滑)

## 8. 参考文献

### 控制论 / AQM
- **RFC 8034** (2017) "Active Queue Management (AQM) Based on Proportional Integral Controller Enhanced (PIE) for DOCSIS Cable Modems." White & Pan.
- **RFC 8033** (2017) "Proportional Integral Controller Enhanced (PIE): A Lightweight Control Scheme to Address the Bufferbloat Problem." Pan, Natarajan, Baker, White.
- Pan, R. et al. (2015) "PIE: A Lightweight Control Scheme to Address the Bufferbloat Problem." IETF Draft.

### OS 调度
- **Blumofe, R. D. & Leiserson, C. E. (1999)** "Scheduling multithreaded computations by work stealing." *JACM* 46(5): 720-748.
- **Arpaci-Dusseau, R. H. (2018)** "Operating Systems: Three Easy Pieces" Chapter 8 (MLFQ). <https://pages.cs.wisc.edu/~remzi/OSTEP/cpu-sched-mlfq.pdf>
- **Corbato, F. J. et al. (1962)** "An Experimental Time-Sharing System." *IFIPS 1962*.

### BBR / 拥塞控制
- **Ahsan, M. & Hussain, M. (2026)** "BBR-n+ congestion control: Real-time performance with smart exit and advanced AQMs." *PLOS One* 21(4): e0330972. DOI: 10.1371/journal.pone.0330972.
- Cardwell, N. et al. (2024) "BBR Congestion Control." IETF draft-ietf-ccwg-bbr-02.
- Cardwell, N. et al. (2023) "BBRv3: Algorithm Bug Fixes and Public Internet Deployment."

### 统计 / 学习
- **Adams, R. P. & MacKay, D. J. C. (2007)** "Bayesian Online Changepoint Detection." arXiv:0710.3742.
- Wald, A. (1945) "Sequential Tests of Statistical Hypotheses." *Annals of Mathematical Statistics* 16(2): 117-186.

## 9. 更新历史

- 2026-10-08: 初版, 5 个 P2 port 全部深扒到原始 paper + BBRPlusV3 代码集成.
- 2026-10-08 (2): batch-1 实施 (smartexit-1 + codel-1 已注入 create_bbrplusv3.sh, commit 78293d5); ev6 关闭 (基座已实现).

---

## 10. 引用纠错 + daw 深扒 (2026-10-08 晚, batch-2 准备)

### 10.1 utc 关闭 — 引用纠错

原 backlog 写的 "ABC = Additive Decrease with Backup, Bakker NSDI 2020, RTT-inflation 提前检测" **是虚构引用**。

**真 ABC** = **Accel-Brake Control** (Prateesh Goyal, Anup Agarwal, Ravi Netravali, Mohammad Alizadeh, Hari Balakrishnan. "ABC: A Simple Explicit Congestion Controller for Wireless Networks." NSDI 2020):
- **机制**: 瓶颈路由器按 dequeue rate 计算加速比 f(t), 复用 ECN 位标记 accel (01)/brake (10); 发端每 ACK cwnd +1/-1 包; MAIMD (加 AI 保公平, Chiu-Jain 收敛)
- **部署前提**: 路由器必须实现 ABC 标记 (论文实现于 OpenWrt Wi-Fi AP / 蜂窝代理)
- **对 tcpboost**: 公网跨洋路径**无 ABC 路由器 → 不可部署** → 关闭 (`tcpboost-utc`)

底层需求 (提前于 loss 的温和响应) 仍真实, 正确源家族是**延迟基 CC**, 已立 `tcpboost-25d` (P3):
- Vegas (Brakmo & Peterson 1995): 绝对阈值, RTT 噪声敏感
- Copa (Goyal et al. NSDI 2018): standing queue × 可配 δ
- **Swift RTT-gradient (SIGCOMM 2020): 优先候选**, gradient 对跨洋 RTT 噪声更鲁棒

**前置门** (吸取 pair-wise 教训): 只吃 RTT gradient 不吃 loss/ECN (与 MLFQ 分离); 与 beta 双重削减评审; 与 smartexit-1 的 rtt_diff 测量统一。

### 10.2 daw (Kalman) 深扒 — scalar Kalman + BBRPlusV3 集成设计 of record

**原始来源**: Kalman, R. E. (1960). "A New Approach to Linear Filtering and Prediction Problems." *ASME J. Basic Eng.* 82(1):35-45. 实用教程: Welch & Bishop, "An Introduction to the Kalman Filter" (UNC/TR 95-041). KCC (PLAN.md Phase 3 引用) 许可证 NOASSERTION 不可并入 → **自研 scalar 版** (~30 行)。

**Scalar Kalman (随机游走模型, A=1, H=1)**:
```
predict:  x⁻ = x ;  P⁻ = P + Q
gain:     K  = P⁻ / (P⁻ + R)
update:   x  = x⁻ + K·(z − x⁻)
          P  = (1 − K)·P⁻
```
- z = 本次 ACK 的测量 (delivery rate 或 rtt 样本)
- Q = 过程噪声 (模型不确定度), R = 测量噪声 (丢包/乱序/ACK 压缩)
- **Q/R 比是唯一调参**: 大 → 信任测量快收敛 (跨洋长肥管); 小 → 信任模型抗噪 (4G/WiFi 抖动)

**定点化**: x/P/K 全用 u32, 状态量左移 BBR_SCALE(8) 存小数; Q/R 用 module_param 暴露 (默认 Q=BR_UNIT/16, R=BR_UNIT/4, 即 Q/R=1/4 温和收敛)。

**集成边界 (防正正得负, 关键!)**:
| BBRv3 既有估计 | 处理 | 理由 |
|---|---|---|
| `bbr->bw_latest` (上轮 max) | **Kalman 替换** | 这是 pacing/BDP 基线, 均值估计更稳 |
| `bbr_max_bw()` max 滤波器 | **保留不动** | max 是带宽探测的**故意**语义 (PROBE_UP 依赖峰值), Kalman 均值会杀死探测 |
| `bbr->min_rtt_us` min 滤波器 | **保留不动** | min 语义不可用均值替代, ProbeRTT 触发依赖它 |
| `tp->rcv_rtt_est` (EWMA) | 不动 (TCP 栈共享) | 只在 bbr 层内加 Kalman |

**注入点** (create_bbrplusv3.sh):
1. struct bbr 加 `u32 kalman_x, kalman_p;` (定点状态)
2. `bbr_calculate_bw_sample()` 之后插入 `bbrplusv3_kalman_update(sk, ctx)` — 消费 ctx->sample_bw, 输出写 `bbr->bw_latest`
3. module_param: `kalman_enable(1) / kalman_q(16) / kalman_r(64)`

**消费顺序冲突检查**: `bbr_update_latest_delivery_signals()` 在 `bbr_calculate_bw_sample()` 后用 bw_latest 更新 bw_lo/hi — Kalman 放在 sample 计算后、signals 更新前, 单点替换, 不碰滤波器族。与 codel-1 (消费 rtt) / smartexit-1 (消费 rtt_diff+full_bw) 无共享变量 ✅。与 change-point (6oa) 的集成按 `tcpboost-6oa` design-of-record: change-point 只做触发器并 reset kalman_x/p。

**验收**: 0-loss 单流 baseline (Kalman 均值 ≈ EWMA, 允许 ±2%); 4G 抖动 trace (codel/bbr 抖动方差下降); netem 复现回归。
