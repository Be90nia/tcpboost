# Wave-1 离线仿真报告: 跨域算法移植四票验证 (2026-10-17)

> 分支 `wave1/offline-sim`, 代码 `scripts/wave1_sim/`, 统一入口 `python scripts/wave1_sim/run_all.py` (~85s, 纯 CPU, rc=0)。
> 数据: `D:/tmp/atj_harvest/` 三轮 CI soak (bbrplusv3=38887594698 / cubic=38887614387 / bbr=38913043898), 每轮 8 流 × ~61min 每秒速率 (iperf3 server log 解析)。

## 结论速览

| 票 | 算法 | VERDICT | 一句话依据 |
|---|---|---|---|
| 5pe | SPRT 序贯检验 | **REJECT** | 三轮×5 配置全负: FP 比朴素 N-连击持久化高 4-50×, recall 无增益 |
| e18 | HMM+Viterbi | **REJECT** | 4 种参数化 (含 EM 拟合 steelman) 误报恒劣于 7 行阈值基线, 还漏 dead 段 |
| b9z | HMM+SPRT 分层 | **REJECT** | 分层只削 ~20% 误报秒, 仍比 persist5 差一个数量级, 且丢 recall (cubic 4/5) |
| 3wi | cp-1 证据重设计 | **INCONCLUSIVE** | 残差+门控使 FP 减半, 但 cp 框架对缓变侵蚀型 onset 结构性失明 (cubic 0/5); B 证据 (min_rtt) 离线不可测; 票面自设重启条件 (S8 环境) 未满足 |

**贯穿性发现**: 在 8 流争抢 + netem trace 上, "持续 N 秒低于份额阈值" 的 level 检测 (persist5/10) 在 recall 与 FP 两个维度同时统治全部四种跨域算法——
bbrplusv3: dep30 3/3, FP 1.2/sh (persist10) vs SPRT 9.9-11.6 / HMM 17.7 / 分层 9.0 / cp 链 1.5-3.2 但 recall ≤2/3。
**简化前沿明确: 内核侧若要饿死早判, 先做持久化计数, 不要上模型。**

## 1. 数据与方法

### 1.1 数据源与 loader 决策

- **权威流级序列 = iperf3-server-*.log**: 每个 log 含 7 个顺序连接块 (Interval 从 0 重启) + 每块结尾 summary 行。loader 按 `start < 前一 end` 检测块边界做全局偏移拼接, summary 行仅填 NaN 槽 (否则会覆写每秒数据)。
- ⚠️ **数据质量上报 (PM 关注)**:
  1. `timeseries.csv` 的 `total_mbps` 是**派生列**: total = 16 × p50 逐桶精确成立 (779.75=16×48.73, 2143.79=16×133.98), 非真实求和; 该列不能当总吞吐用时序分析。`active_streams=16` vs 实际 8 端口也待解释。
  2. `streams/stream-*.jsonl` (修复产物) 与 log/CSV 均不可对齐 (逐端口×多偏移最大 corr 0.357, 成对重复含相位漂移+精度混杂), **弃用作输入**, 仅存档。
- 每轮 8 流 (端口 5202-5209), 有效时长 3603-3681s (7 块拼接, 末块 ~29s teardown)。

### 1.2 观测域映射 (票面 loss/RTT 域 → trace 吞吐域)

trace 无逐包 loss、无 RTT、无 ECN, 唯一观测是每秒每流速率。统一映射:

```
r_t = rate(s,t) / median_s' rate(s',t)   (跨流份额归一, 每秒中位数=1)
```

票面参数移植: 5pe 的 p_random/p_congestion → H0: N(1,σ) vs H1: N(0.45,σ) (σ=滚动 MAD);
e18 的 RTT+30%/+100% 状态定义 → 速率域 OK N(1.0,σ²)/Slow N(0.5,σ²)/Dead N(0.15,σ²)。
**映射局限性**: 见 §7 限制。

### 1.3 真值标签 (与检测器解耦)

| 标签 | 定义 | bbrplusv3 | cubic | bbr |
|---|---|---|---|---|
| dead | r<0.25 连续≥10s (重度饿死) | 5 段 (10-14s) | 0 | 0 |
| dep30 | r<0.5 连续≥30s (必须捕获的持续 depression) | 3 段 (含 310s) | 5 段 (含 301s,536s) | 0 |
| slow | r<0.5 连续≥10s (轻度参考) | 30 段 | 31 段 | 6 段 |

正向证据分布: 重度段仅 bbrplusv3 有; **depression 的两种形态**: bbrplusv3 以突降为主 (cp 可见), cubic 以缓变侵蚀为主 (1.0→0.45 漂移数分钟) — 这一形态差异直接决定 3wi 的结论 (§5)。

### 1.4 评分口径 (预注册)

- dep30/dead recall + 检测延迟 (秒; 检测器已在动作态覆盖段起点记 0, FP 风暴下延迟列区分度弱, **判决主要看 FP**);
- **FP = 与任何真值段无重叠的触发段** (段按 gap=30s 合并, 对齐 30s 粒度契约), 报 FP 段数/流时与误动作秒;
- 判据: KEEP 需 FP 比 persist 基线降 ≥2× 且 recall≥0.6; recall 持平而 FP 劣化 → REJECT; 无法在 30s 粒度分出 → INCONCLUSIVE。

## 2. tcpboost-5pe: SPRT 序贯检验 → REJECT

实现: 分段高斯 SPRT, LLR 逐秒累积, 界 ±log{4,8,16}, 过界判并复位; 对照自参照版 (r/自身 300s 滚动中位, 内核可实现形态); 基线 = 单点阈值 r<0.5 与 persist{3,5,10}。

| round | 检测器 | dep30 | dead | FP/sh | 误动作秒 |
|---|---|---|---|---|---|
| bbrplusv3 | sprt log8 | 3/3 | 5/5 | 11.1 | 3344 |
| bbrplusv3 | sprt log8 self | 3/3 | 5/5 | 10.5 | 3829 |
| bbrplusv3 | **persist10** | **3/3** | **5/5** | **1.2** | **160** |
| cubic | sprt log8 | 5/5 | - | 6.5 | 1685 |
| cubic | **persist10** | **5/5** | - | **0.25** | **12** |
| bbr | sprt log8 | - | - | 13.6 | 6844 |
| bbr | **persist10** | - | - | **0.62** | **37** |

分析:
1. SPRT 的理论卖点 (少样本早判) 在此无变现: 深度持续下坠信号太响, 所有检测器延迟都≈0; 差异全部在 FP, 而 SPRT 全配置劣于 persist3, 更劣于 persist5/10。
2. 根因: 争抢噪声的真实散布 (r 的 MAD≈0.2-0.4, 单秒 r<0.5 占 4-10%) 使高斯 H0/H1 的似然比在瞬态抖动上持续正漂移; σ/H0 均值/参照模式三种修法 (滚动 MAD、自参照、界加严) 都不稳健。
3. 简单持久化计数 5-10 个样本即达 5/5+3/3 recall 且 FP 低一个数量级——票面要替代的 "boolean thresh" 加个计数器就够。

**VERDICT: REJECT** (吞吐比域, 三轮一致)。范围注记: 票面原始形态是逐 loss event 的 Bernoulli-SPRT, 离线无逐包数据不可测; 本结论否定的是"序贯似然比在 tcpboost 现有可观测信号上有优势"这一命题; 若将来内核侧有 per-flow retrans/loss 计数器遥测, 可用同框架在 S8 环境复测。

## 3. tcpboost-e18: HMM+Viterbi → REJECT

实现: 3 态高斯 HMM, 粘滞转移 (diag .99-.996); 全序列 Viterbi (离线上界) 与在线前向滤波 (内核可实现); 观测双形态 (绝对 r = 遥测辅助上界 / r÷trailing-max = 逐流可实现); 基线 = 票面所称"现行隐式启发式"单点分段。

| round | 检测器 | dep30 | dead | 误状态秒 | FP 折算桶/sh |
|---|---|---|---|---|---|
| bbrplusv3 | viterbi_abs | 3/3 | 5/5 | 4338 | 17.7 |
| bbrplusv3 | viterbi_flow | 3/3 | 5/5 | 27373 | 111.5 |
| bbrplusv3 | heuristic(单点分段) | 3/3 | 5/5 | **1834** | **7.5** |
| cubic | viterbi_abs | 5/5 | - | 4687 | 19.5 |
| cubic | heuristic | 5/5 | - | **1873** | **7.8** |
| bbr | viterbi_abs | - | - | 3889 | 16.0 |
| bbr | heuristic | - | - | **1192** | **4.9** |

分析:
1. 混淆矩阵 (bbrplusv3, viterbi_abs): 真 OK 秒被判 Slow 4240s (15%)——健康争抢波动大规模误入 Slow 态; recall 全满但由 FP 风暴"铺"出来, 无信息量。
2. **模型类与数据形态错配** (EM 3-Gaussian 拟合 r 边缘分布证实): 三峰是 [输家份额 0.44 (8-20%) / 主模式 0.98 (62-79%) / 赢家 1.6-2.1 (13-20%)]——**份额不平等, 不是路径状态**。票面三态 (OK/Slow/Dead) 的发射把输家流的常态稳态误标为 Slow; Dead 段 (56s) 稀缺到无监督 EM 拟不出。
3. Steelman (EM 参数 + 慢自参照 1800s 消份额) 仍三轮全负 (FP 11.8/8.5/10.9 vs 基线 7.5/7.8/4.9), 且 dead 掉到 4/5。Viterbi≈online (平滑无增益)。
4. 逐流可实现形态 (trailing-max 归一) 灾难性 (111 桶/sh): 追峰归一在 depression 中迟滞, 慢自参照则自吸收。

**VERDICT: REJECT** (4 参数化 × 2 观测形态 × 2 解码方式 × 3 轮一致)。范围注记: 票面观测域是 RTT/loss; 若 RTT 遥测可用, "路径 OK/Slow/Dead" 假设在 RTT 域可能成立, 但那需要 S8/内核遥测, 现有数据不支持投入内核实现。

## 4. tcpboost-b9z: HMM+SPRT 分层 → REJECT

实现: L1 = e18 最强形态在线滤波 (EM 参数+慢自参照); L2 = 自参照 SPRT (log8), 仅 L1∉OK 时累积; 动作需两层一致。对照: L1-only, L2-only。

| round | l1_only | l2_only | hier (组合) | hier recall 代价 |
|---|---|---|---|---|
| bbrplusv3 | FP 9.3/sh, 2634s | 10.5/sh, 3829s | **9.0/sh, 2179s** | dep30 3/3, dead 5/5 (无损失) |
| cubic | 6.4/sh, 1718s | 7.4/sh, 2737s | **6.2/sh, 1230s** | dep30 **4/5 (丢 1)** |
| bbr | 13.1/sh, 4438s | 14.3/sh, 6318s | **12.5/sh, 2860s** | - |

分析: 分层确实按票面机制工作 (L2 在 L1=OK 时被关门, 误报秒削 17-55%), 但:
1. 削后水平仍比 persist5 (0.87-3.3/sh) 差 3-7×, 比 persist10 差 10-20×;
2. cubic 上丢 1 段 dep30 (L2 门控反而压制了一次真阳性);
3. 复杂度 = 两层参数 (6 发射 + 9 转移 + σ + 界) 换一个仍被 7 行计数器支配的系统。"负负得正"假设在这些 trace 上不成立——两层各自的 FP 缺陷相加, 协同只抵一小半。

**VERDICT: REJECT**。

## 5. tcpboost-3wi: cp-1 争抢感知证据重设计 → INCONCLUSIVE

实现: 证据 A (bw 突降) 链, 真值 = dep30 段起点; **证据 B (min_rtt +10%) 离线不可测** (trace 无 RTT), 如实缺测。

| round | old_A (mean-3σ) | resid (4×MAD, 5-of-7) | gated (争抢门控 8-of-10) |
|---|---|---|---|
| bbrplusv3 | 1/3, FP 3.2/sh | 2/3, FP 1.6/sh | 2/3, FP 1.5/sh |
| cubic | 1/5 (dly=300s), 2.0/sh | **0/5**, 1.7/sh | **0/5**, 1.6/sh |
| bbr | - , 4.2/sh | -, 2.8/sh | -, 2.2/sh |

发现:
1. **离线复现不出 batch-3 的误触发风暴**: old_A 每轮 FP 仅 16-34 段——内核 cp-1 的误触发发生在 per-RTT 窗 bw 采样粒度 (每秒 ~20 样本) + min_rtt 证据 B, 每秒聚合把两部分都抹掉了。**离线只能评价"证据 A 重设计", 不能仲裁 batch-3 失效模式**。
2. **cp 框架对缓变侵蚀结构性失明**: cubic 的 depression 是 1.0→0.45 的分钟级漂移, 30s 基线窗的 mean/MAD 都跟着漂 → 残差恒小 → 0/5 漏检; 基线窗拉长到 300s 反而 FP 涨 (4.2-7.5/sh) recall 仍 0/5。change-point 检测的对象是"突变", 而这批 trace 的主要失效形态是"慢侵蚀"。
3. 残差滤波 + 争抢门控方向本身有效: 同 recall 下 FP 减半 (bbrplusv3 2/3@1.5 vs old 1/3@3.2), 若 cp-1 保留, 应采用。

**VERDICT: INCONCLUSIVE** — 依据: (a) 决定性失效模式离线不可复现; (b) 证据 B 不可测; (c) 票面自设重启条件 (S8 路径切换环境) 未满足。**定向证据 (供 PM/后续支线)**: cp-1 若要复活, 除证据重设计外需增加 **level/侵蚀证据臂** (跨流份额持续低于阈值的 level 检测, persist 类) ——本轮数据表明它对主要失效形态的覆盖是 cp 框架的 5/5 vs 0-2/5。

## 6. 交叉综合

1. **算法排序** (FP/sh @ 全 recall, 三轮): persist10 (0.25-1.2) ≪ resid+gating (1.5-2.8, 但 recall 缺) < 分层 (6.2-12.5) < SPRT (5-14) < HMM (16-19) ≪ HMM_flow (110+)。
2. **信息集分层结论**: 绝对份额观测 (跨流遥测) 上界与逐流可实现形态之间差距巨大 (HMM: 17.7 vs 111.5); 单流归一化 (追峰/追中位) 引入的自吸收/迟滞伪态比它消除的份额混淆更多。**任何依赖"份额归一"的内核方案需要显式跨流遥测, 否则不可实现**。
3. **现象学基线** (供后续票引用): 争抢 trace 单秒 r<0.5 占 4-10% (3σ 波动是常态, 与 3wi 尸检一致); 持续 depression 稀少 (dep30 0-5 段/轮) 且分突降/缓变两型; 份额三峰结构稳定复现。

## 7. 限制 (诚实清单)

- 观测域替换: 四票原始观测 (loss event / RTT) 均不可得, 结论限定于吞吐比域; RTT/loss 域复测需内核遥测 (S8)。
- 正样本稀少: dead 仅 5 段 (56s, 单轮); dep30 8 段/三轮。recall 数字粒度粗。
- 标签与阈值基线部分同构 (r<0.5 系), recall 区分度弱, 判决实际由 FP 驱动——已按此解释。
- 每-RTT 窗粒度动力学 (batch-3 真实失效现场) 不可离线重建。
- 三轮同为 8 流同构争抢; 未覆盖 S8 式路径切换/异构 CCA 混跑 (atj Wave-0 产线另测)。

## 8. 复现

```
python scripts/wave1_sim/run_all.py   # ~85s, 输出汇总表 + scripts/wave1_sim/results_all.json
```

代码: `common.py` (loader/标签/评分) + `t5pe_sprt.py` / `e18_hmm.py` / `b9z_hier.py` / `t3wi_cp1.py` / `run_all.py`。
