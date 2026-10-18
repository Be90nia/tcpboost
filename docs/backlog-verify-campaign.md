# Backlog 全量验证战役 (2026-10-16)

> 用户拍板: 全部 open backlog 开支线验证; **每支线 A/B 门禁 keep/reject — 有效才合并主线, 无效即弃, 主线零影响** (2026-10-16)。
> **环境政策 (2026-10-16 追加): 实验一律跑 GitHub Actions CI (QEMU guest), 禁用用户 VPS**; VPS 仅存数据/生产, 使用需用户逐次批准。
> Epic: bd (backlog 全量验证战役)。CI: workflow 'Build TCPBoost Kernel', QEMU guest 支持 DURATION/LOSS/NSTREAMS/netem, 单 job 6h 硬上限。生产 199.115.231.188 与全部 VPS 不碰。

## 跑法协议 (2026-10-16 用户拍板, 我跳步教训)

5h soak 是出厂稳定性门禁, **不是诊断工具**。任何长跑前必须:
1. 30m 探针先行 (soak_duration=30m, 单次迭代成本 ~30m)
2. 30m 全绿 + 30m 探针连稳 2 轮 = code 成熟标志
3. 才上 5h/24h 出厂一次定生死, 不循环
4. 探索阶段禁直接派长跑; 错了就 worktree 修再 30m, 不烧 5h

## Wave-0 (数据/实验类, 3 并行, 2026-10-16 派发)

| 票 | 支线 | 环境 | 门禁判据 | 报告 |
|---|---|---|---|---|
| c4j | soak 仪表噪声: min 流跨 run 不可比 | 104 现有 24h run (2817 采样) + FAILED-4h | 噪声定量 (窗口 CV/分布) + 鲁棒指标提案, 新指标须在 24h 数据上判"无饿死" | docs/soak-noise-analysis.md |
| atj | 5h 混跑 BBRv1/Cubic 对比 | **CI QEMU**, 4×bbrplusv3+2×bbr1+2×cubic, loss 0.5%/RTT150ms | 混跑是否拖累 bbrplusv3 (per-CCA 聚合 + Jain 公平指数); 供"用户环境混跑"结论 | docs/cca-mix-comparison.md |
| yve | AQM hardening: CAKE/FQ-CoDel 选项 | **CI QEMU**, fq 基线 vs fq_codel vs cake × (净腿/loss 腿) | 三指标 (total/min/加载 RTT) 任一 qdisc 显著优于 fq → KEEP | docs/aqm-hardening-ab.md |

## Wave-1 (离线仿真, Python 原型 vs 现有 JSONL, 无需内核)

5pe (SPRT 早判 loss) / e18 (HMM+Viterbi) / b9z (分层组合) / 3wi (cp-1 争抢证据重设计)。
数据源: 104 run 的 samples.jsonl + streams/*.jsonl。判据: 原型在真实 trace 上检出率/误报率优于现行单点阈值。

## Wave-1 结果 (2026-10-17 闭环: 3 REJECT + 1 DEFERRED)

5pe/e18/b9z **REJECT** (高级算法全输给 level-persist 计数器 4-50×), 3wi **DEFERRED** (FP 减半方向有效; 复活需 level/侵蚀证据臂 + S8 内核遥测)。详见 docs/wave1-sim-report.md。
**贯穿结论**: 内核饿死早判先做计数器再谈模型; "负负得正"组合假说被证伪。原型: 分支 wave1/offline-sim (65f5b8c)。

## Wave-2 门禁 (2026-10-18 已解: cake 败 + REPRO_WEAK → 全线 DEFERRED)

yve 终局 (run 39070138587, 六腿全量): **REJECT** — cake 全指标略差 (loss 腿 total −14%, min p5 0.89×), fq_codel +7~12% 总吞吐未过预声明显著门槛; **关键: 环境 gate=REPRO_WEAK, 差分饿死三臂全零未复现** → 9tu/i6a/32e/25d/ohk 的饿死/公平前提在本 harness 不可验证, 按"无效即弃"全部 **DEFERRED**, 复活条件 = 能复现差分饿死的环境 (VPS 真实链路或 harness 重构)。
意外收获: netem 抖动 × rto-1 门 → 虚假 RTO 风暴 (8 流塌缩 0.6Mbps, cwnd 钉 RTO 地板) — 新票 **tcpboost-7hn (P2)**, 这是从战役里捞到的最有价值的病理。

## 收官汇总 (2026-10-18)

| 票 | 支线 | VERDICT | 去向 |
|---|---|---|---|
| c4j | soak 仪表噪声分析 | **KEEP** | 方法论沉淀 (CV≈1.8 @30m, 防抖三采取 max), docs/soak-noise-analysis.md |
| atj | 5h 混跑 BBRv1/Cubic | **KEEP** | bbrplusv3 vs 原版 total +8%/min +76% 双同向稳健; analyzer 修复已并 main (e72240b) |
| yve | AQM cake/fq_codel | **REJECT** | 不并主线; harness 存 feature/aqm-ab-ci (4bf56c5) 可复用; 意外发现 → 7hn |
| 5pe/e18/b9z | SPRT/HMM/分层 | **REJECT ×3** | 计数器优先原则; 原型工具 wave1/offline-sim (65f5b8c) |
| 3wi | cp-1 重设计 | DEFERRED | FP 减半方向有效; 复活需 S8 遥测 |
| 9tu/i6a/32e/25d/ohk | Wave-2 内核实做 | **DEFERRED** | REPRO_WEAK 门控; 复活条件见上 |
| 86e/9l5/hu2/ffc/a9x | 研究类 | 携带完毕 | Wave-1 结论已注入各票 (模型败于计数器; RL 立项前置门) |

**战役净收益**: ① bbrplusv3 核心卖点首次实测坐实 (抗饿死 +76%) ② soak_analyze 修复回主线 ③ 计数器优先 + 预注册门槛两条方法论沉淀 ④ 抖动×rto-1 病理新票 ⑤ 五个 harness 修复实锤 (ifb/引号/抖动/死锁/netem 串链)。
**尾巴**: 120.79 残留 iperf3 (惰性未清, 无害); fq_codel 吞吐复核候选 (并入 7hn 备注)。

## Wave-2 门禁 (2026-10-17: 被 yve 结果门控) — 原始逻辑存档

**9tu+i6a (work stealing+HTB) 与 32e (WFQ/DRR) 的核心诉求 = "流间公平 + 空闲带宽借用" — 正是 CAKE qdisc 的原生能力。**
次序强制: **yve 的 cake-vs-fq A/B 先出结果**:
- cake 显著优 → 9tu+i6a/32e 大概率 REJECT (tcp.sh 加 cake 选项即可, 零内核代码), Wave-2 缩水为 25d 一票
- cake 平/劣 → 自定义调度才有立项空间
25d (延迟基) 独立于该门禁, 但票面自设"需设计评审"前置。

## Wave-2 (写码 + CI, feature/ 支线分支)

25d 延迟基 (先设计评审) / 9tu+i6a ohk 组合 (design-of-record 已有) / 32e WFQ/DRR。
判据: qemu A/B (measure_rsa 三采取 max) + 30m 探针, 复用 batch 门禁模式。

## 研究类 (不单独立验证, 随实做票携带)

86e / 9l5 / hu2 / ffc / a9x — 无独立可跑产物, 由 Wave-1/2 对应设计文档携带更新。

## 收官

keep/reject 汇总表 → 有效支线合并主线 (PM commit) → bd 核销 → CHANGELOG。
