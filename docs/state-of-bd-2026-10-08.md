# bd 状态快照 (2026-10-08)

> **目的**: 记录 2026-10-08 会话结束时 bd backlog 的完整状态
> **时间**: 2026-10-08
> **总问题数**: 31 (14 P2 + 17 P3, 0 in-progress)
> **文档总长**: algorithm-layer-thinking.md (675) + cross-domain-deep-dive.md (643) = 1318 行

## 1. 顶层架构 (4 个 umbrella + 1 个 watchlist + 1 个 research 跟踪 + 26 个 sub-issue)

```
tcpboost-hu2 (P2)  - 算法层方法学 (umbrella) ── 4 范式
├─ tcpboost-86e (P2)  - BBRPlusV3 跨算法移植 backlog (cross-CCA)
│  ├─ tcpboost-2lv (P2)  - #1 Smart Exit (BBR-n+) ★★★ 深扒
│  ├─ tcpboost-ev6 (P2)  - #2 DCTCP+AccECN
│  ├─ tcpboost-utc (P2)  - #3 ABC RTT-inflation
│  ├─ tcpboost-5cs (P3)  - #4 CoDel sojourn-time
│  ├─ tcpboost-b6t (P3)  - #5 Hysteria/Brutal variance
│  ├─ tcpboost-6u8 (P3)  - #6 CUBIC fast convergence
│  ├─ tcpboost-a9x (P3)  - research/survey (BBR 文献)
│  └─ tcpboost-atj (P3)  - e2e 验证 (5h 混跑)
│
├─ tcpboost-9l5 (P2)  - 跨域移植 backlog (cross-domain) - 17 项
│  ├─ 横轴 (资源分配):
│  │  ├─ tcpboost-afi (P2)  - #1 CFS vruntime ★★★
│  │  ├─ tcpboost-32e (P2)  - #3 WFQ/DRR ★★★
│  │  ├─ tcpboost-9tu (P2)  - #14 Work stealing ★★★ 深扒
│  │  └─ tcpboost-i6a (P3)  - #5 HTB
│  ├─ 纵轴 (时序调度):
│  │  ├─ tcpboost-0w6 (P2)  - #2 MLFQ ★★★ 深扒
│  │  └─ tcpboost-8bf (P3)  - #6 Priority-Flood
│  ├─ 深度 (输出调度):
│  │  ├─ tcpboost-qpm (P2)  - #4 PI controller ★★ 深扒
│  │  └─ tcpboost-hw3 (P3)  - #7 MPC
│  ├─ 精度 (估计质量):
│  │  ├─ tcpboost-daw (P2)  - F. Kalman filter (foundation) ★★★
│  │  ├─ tcpboost-ucg (P3)  - #13 RLS
│  │  ├─ tcpboost-8vv (P3)  - #15 LMS
│  │  ├─ tcpboost-bgy (P2)  - #8 Bayesian 估计 ★★★
│  │  └─ tcpboost-bfe (P3)  - #17 LQG
│  ├─ 检测 (变化/假设):
│  │  ├─ tcpboost-6oa (P2)  - #9 Bayesian change-point ★★★ 深扒
│  │  ├─ tcpboost-5pe (P3)  - #11 SPRT
│  │  └─ tcpboost-e18 (P3)  - #12 HMM + Viterbi
│  └─ 探索 (explore/exploit):
│     ├─ tcpboost-pek (P3)  - #10 UCB1 bandit
│     └─ tcpboost-kb3 (P3)  - #16 Bellman DP
│
└─ tcpboost-ffc (P3)  - Watchlist: RL 拥塞控制 (季度回访)
```

## 2. 完整列表 (按 ID 排序)

### 2.1 P2 (14 项, 全部深扒或粗扒)

| ID | 标题 | ROI | 深扒? |
|---|---|---|---|
| `tcpboost-hu2` | 算法层方法学 (umbrella) | - | 方法论文档 |
| `tcpboost-86e` | BBRPlusV3 跨算法移植 backlog (umbrella) | - | 6 项 cross-CCA |
| `tcpboost-9l5` | 跨域移植 backlog (umbrella) | - | 17 项 cross-domain |
| `tcpboost-2lv` | Smart Exit (BBR-n+ Algorithm 1) | ★★★ | ✅ docs/cross-domain-deep-dive.md §1 |
| `tcpboost-ev6` | DCTCP ECN alpha + AccECN (RFC 9768) | ★★★ | ⏳ 待深扒 |
| `tcpboost-utc` | ABC RTT-inflation 提前检测 | ★★★ | ⏳ 待深扒 |
| `tcpboost-afi` | CFS vruntime (跨连接公平 pacing) | ★★★ | ⏳ 待深扒 |
| `tcpboost-0w6` | MLFQ (adaptive pacing gain 反馈) | ★★★ | ✅ docs/cross-domain-deep-dive.md §2 |
| `tcpboost-32e` | WFQ/DRR (跨 CCA 比例公平) | ★★★ | ⏳ 待深扒 |
| `tcpboost-9tu` | Work stealing (跨流偷带宽) | ★★★ | ✅ docs/cross-domain-deep-dive.md §3 |
| `tcpboost-bgy` | Bayesian 估计 (后验分布) | ★★★ | ⏳ 待深扒 |
| `tcpboost-6oa` | Bayesian change-point (路径变化) | ★★★ | ✅ docs/cross-domain-deep-dive.md §4 |
| `tcpboost-daw` | Kalman filter (foundation) | ★★★ | ⏳ 待深扒 |
| `tcpboost-qpm` | PI 反馈控制器 (替换启发式 gain) | ★★ | ✅ docs/cross-domain-deep-dive.md §5 |

### 2.2 P3 (17 项, 粗扒)

| ID | 标题 | ROI |
|---|---|---|
| `tcpboost-yve` | AQM hardening: CAKE / FQ-CoDel | (独立 P3) |
| `tcpboost-a9x` | BBRPlusV3 算法优化研究汇总 | (research) |
| `tcpboost-atj` | 5h 长跑 + 混跑 BBRv1/Cubic 对比 (e2e) | (验证) |
| `tcpboost-5cs` | Port #4 cross-CCA: CoDel sojourn-time | ★★ |
| `tcpboost-6u8` | Port #6 cross-CCA: CUBIC fast convergence | ★ |
| `tcpboost-b6t` | Port #5 cross-CCA: Hysteria/Brutal variance | ★★ |
| `tcpboost-i6a` | Port #5 cross-domain: HTB | ★★ |
| `tcpboost-8bf` | Port #6 cross-domain: Priority-Flood | ★★ |
| `tcpboost-hw3` | Port #7 cross-domain: MPC | ★★ |
| `tcpboost-ucg` | Port #13 cross-domain: RLS | ★★ |
| `tcpboost-8vv` | Port #15 cross-domain: LMS | ★ |
| `tcpboost-bfe` | Port #17 cross-domain: LQG | ★★ |
| `tcpboost-5pe` | Port #11 cross-domain: SPRT | ★★ |
| `tcpboost-e18` | Port #12 cross-domain: HMM + Viterbi | ★★ |
| `tcpboost-pek` | Port #10 cross-domain: UCB1 bandit | ★★ |
| `tcpboost-kb3` | Port #16 cross-domain: Bellman DP | ★ |
| `tcpboost-ffc` | Watchlist: 学习式 (RL) 拥塞控制 | (跟踪) |

## 3. 跨域算法深扒档案 (docs/cross-domain-deep-dive.md)

**5 个 P2 已深扒到原始 paper, 含 BBRPlusV3 代码骨架 + 风险 + 测试矩阵**:

| # | 算法 | 原始 paper | BBRPlusV3 hook | 风险 |
|---|---|---|---|---|
| 1 | Smart Exit | Ahsan & Hussain 2026 PLOS One | `bbr_check_probe_rtt_done()` | ★ |
| 2 | MLFQ | Corbato 1962 + Arpaci-Dusseau OSTEP §8 | `bbr_set_pacing_gain()` | ★★ |
| 3 | Work Stealing | Blumofe-Leiserson 1999 JACM | BPF + cgroup 协调 | ★★★★ |
| 4 | Bayesian Change-Point | Adams-MacKay 2007 arXiv:0710.3742 | `bbr_update_model_parameters()` | ★★★ |
| 5 | PI Controller | RFC 8034 | `bbr_set_pacing_rate()` | ★★★ |

## 4. 实施路线图 (推荐顺序)

按风险低→高, 依赖小→大:

```
1. Smart Exit (tcpboost-2lv)         ★ 风险  | 30-50 行 | 独立函数
2. MLFQ       (tcpboost-0w6)         ★★      | 30-50 行 | 3-level state
3. PI Controller (tcpboost-qpm)      ★★★     | 40-60 行 | Kp/Ki 调参
4. Change-Point  (tcpboost-6oa)      ★★★     | 60-100 行 | 浮点→定点化
5. Work Stealing (tcpboost-9tu)      ★★★★    | 80-120 行 + BPF | 需 cgroup 集成
```

**针对 xhttp 饿死 (跨域三件套)**: 1+2+5 → 0 饿流
**针对 RTT/loss 综合**: 3+4 + cross-CCA 1+2+3 (Smart Exit / DCTCP / ABC)

## 5. 文档索引

| 文档 | 行数 | 作用 |
|---|---|---|
| `docs/algorithm-layer-thinking.md` | 675 | 4 算法范式 + 19 痛点 + 17 跨域 port 完整索引 |
| `docs/cross-domain-deep-dive.md` | 643 | 5 个 P2 深扒 (论文 + 代码 + 风险) |
| `xhttp-starvation-report.md` | (原文件) | 根因: 收端 DRS 竞速亚稳态 |
| `docs/state-of-bd-2026-10-08.md` | (本文) | bd 状态快照 |

## 6. 关键决策记录

### 6.1 升维原则 (2026-10-08)

不再"在 BBR 状态机里发散 sed 优化". 改用**双线并行**:
- **A. cross-CCA port**: 借其他 CCA 已有技术 (DCTCP / ABC / CoDel)
- **B. cross-domain port**: 借其他领域通用方法 (OS 调度 / GIS / DSP / 控制论 / 统计)

**核心洞察 (用户原话, 2026-10-08)**: "就好比 Priority-Flood 没办法替代 BFS/DFS, 但它的算法可以动态分配扫描算力, 因此某种层度上提高了整体的速度. 这就是我想要的可以跨界找找有没有适合我们现在 BBR 算法瓶颈问题的算法."

### 6.2 调度杠杆分类 (2026-10-08)

跨域 port 各自动哪根调度杠杆:
- **横轴 (who gets resource)**: CFS / WFQ / HTB / Work stealing
- **纵轴 (when)**: MLFQ / Priority-Flood
- **深度 (how much)**: PI / MPC
- **精度 (estimate quality)**: Kalman / Bayesian / RLS / LMS / LQG
- **检测 (change/hypothesis)**: Bayesian change-point / SPRT / HMM-Viterbi
- **探索 (explore/exploit)**: UCB1 bandit / Bellman DP

### 6.3 不在 BBR 层 (反合理化)

明确**不**做:
- ❌ 继续 BBR 内部 sed 优化 (已穷尽, 6+17=23 项候选)
- ❌ userspace mux 共享连接 (bd gam0 单独)
- ❌ 自研 RL-CCA 替换 BBR (跟 watchlist 联动)
- ❌ IETF 标准化 (跨组织)
- ❌ 改 `tcp_rcv_ssthresh_unstick` (已独立完成)

## 7. 遗留 / TODO

### 7.1 待深扒 P2 (5 个)
- `tcpboost-ev6` DCTCP+AccECN — 待深扒
- `tcpboost-utc` ABC RTT-inflation — 待深扒
- `tcpboost-afi` CFS vruntime — 待深扒
- `tcpboost-bgy` Bayesian 估计 — 待深扒
- `tcpboost-daw` Kalman filter — 待深扒

### 7.2 未覆盖痛点 (3 个)
- **#8 TLP (Tail Loss Probe)**: BBR 感知化
- **#9 App-limited 检测**: 在线 change-point
- 跨域 search: 还可继续扫 (MCMC / SMC / particle filter / ABC algorithm)

### 7.3 实施层 TODO
- [ ] 编译验证 7.2 LTS + bbrplusv3 完整
- [ ] 单流 0 loss baseline (iperf3)
- [ ] netem loss 0.5% + 150ms RTT 8 并发复现
- [ ] ss -tin 0.5s 采样 + 饿流比例统计
- [ ] 5h 长跑 (tcpboost-atj)

## 8. bd 命令快速参考

```bash
bd list                    # 全部 open
bd list --priority P2      # 14 P2
bd list --priority P3      # 17 P3
bd show <id>               # 看详情
bd link <parent> <child>   # 加依赖
bd update <id> --title/--description
bd reopen <id>             # 重开
bd close <id> --reason "..."
```

## 9. 更新历史

- 2026-10-08: 初版, 31 issues 全部记录, 5 个 P2 深扒完毕
