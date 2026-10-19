# 68m 恢复时间线分析 — 2026-10-19

**VERDICT: C1/C2（发端恢复动力学）** — 深跌 411 次，39 次（9.5%）在 60s 内未回到跌前 80%；无 <2 Mbps 持续空窗；无绝对地板；无规律锯齿。
**路由后果**: 0tg 前置门（68m 结果1 = 发端侧）**开启**，不因 DRS 搁置。

数据: `D:/tmp/atj_harvest`（与 `D:/d/tmp/atj_harvest` md5 相同，同源副本）三轮 atj A/B/C：
bbrplusv3 `38887594698` / bbr `38913043898` / cubic `38887614387`。
每轮 8 流 × ~1800s 每秒序列，loss 0.5% + 150ms RTT。

复现:
```
python scripts/analysis/recovery_timeline.py --selftest
python scripts/analysis/recovery_timeline.py --out reports/68m
```
机器可读: `reports/68m/recovery-timeline.json`（判定参数第一节）。

## 1. 数据管线修正（先于判定）

| 源 | 结论 |
|---|---|
| `iperf3-server-*.log` | **权威**每秒序列。发现 `scripts/wave1_sim/common.py:load_stream_log` 把每段测试的 summary 行（0.00–300.xx）当成 300s 平台拼接，导致时间轴**翻倍**且 50% 样本是恒值。已在 `common.py:62` 跳过 `b-a>5` 的行。 |
| `streams/stream-*.jsonl` | 每 300s 测试末尾 summary 造成相位错位，成对去重假设失效；**弃用**（与 `wave1-sim-report.md` 结论一致）。 |
| `timeseries.csv` | `total_mbps = 16 × p50_mbps` 派生列；`min_mbps` 是 30s 瞬时 ss 采样，非持续地板。仅作交叉校验。 |

修正前 `load_stream_log` 输出 3600–3700s / 轮，修正后 1802–1841s / 轮；分析器内置 `validate_series()` 对单值占比 >20% 直接报错，防回归。

## 2. 三分法证据（每轮 8 流汇总）

| 指标 | bbrplusv3 | bbr | cubic |
|---|---:|---:|---:|
| 有效秒数 | 1841 | 1822 | 1802 |
| 真实总吞吐均值 (Mbps, 8 流逐秒求和) | **380.8** | 308.2 | 402.5 |
| 真实总吞吐中位 (Mbps) | 348.1 | 298.8 | 408.2 |
| 最弱流均值 (Mbps, 逐秒 min) | **19.58** | 17.13 | 18.95 |
| 深跌次数 (<50% × 30s 滚动中位) | 411 | 272 | 428 |
| 60s 内未恢复 (跌前 80%) | **39 (9.5%)** | 14 (5.1%) | 15 (3.5%) |
| 恢复中位 / p90 (s) | 5.0 / 21.2 | 4.0 / 23.5 | 4.2 / 21.8 |
| 恢复斜率中位 (Mbps/s) | 4.36 | 3.46 | 4.32 |
| <2 Mbps 持续 ≥2s（发端空窗） | 0 | 0 | 0 |
| <12 Mbps 持续 ≥10s（绝对地板/DRS） | **0** | **0** | 6 |
| 相对饿死 (<25% 全流中位, ≥10s) | 5 次 / 56s / max 14s | 0 | 0 |
| 深跌间隔 CV（中位） | 0.86 | 1.03 | 0.85 |

判据（预注册，代码常量）：深跌 50%、恢复目标 80% 跌前中位、观察窗 60s、空窗 <2 Mbps ≥2s、地板 <12 Mbps ≥10s、锯齿 CV<0.35 且众数覆盖 ≥50%。

- **非 DRS**: bbrplusv3 没有任何流在 <12 Mbps 停留 ≥10s；`timeseries.min_mbps≈11.9` 在三轮都出现，是 ss 瞬时采样口径，不是持续钉死。0tg 不搁置。
- **非 C3**: 深跌间隔 CV≈0.86（Poisson 式），众数覆盖仅 17.8%，没有固定周期锯齿。
- **C1/C2**: 无真正零窗口，但深跌后进入 11–18 Mbps 低平台并以 ~4.4 Mbps/s 缓慢爬升；最长 18s 的深跌后 60s 内仍未回到跌前 80%。这是恢复墙钟斜坡/削深下限问题，不是接收端窗钉死。

典型不可恢复片段（bbrplusv3, port 5205, t=18–36）：106→11.5 Mbps，随后 18s 内在 11.5–30 Mbps 徘徊；60s 内未回 80%（跌前 106 Mbps）。
另一例（port 5204, t=1565–1583）：112.5→15.7 Mbps，尾部 30s 中位仅 31.4 Mbps。

## 3. 与既有 atj A/B/C 数字的关系（需战役 owner 复核）

`docs/cca-abc-comparison.md` 的 total/min 来自 `summary.md`（timeseries `16×p50` 派生）与 `streams/*.jsonl`（相位错位）。用**真实逐秒流级**重算：

| 对比 | 旧口径 | 新口径（逐秒真实） |
|---|---|---|
| bbrplusv3 vs bbr total | +8% | **+23.6%**（380.8 vs 308.2） |
| bbrplusv3 vs bbr min | +76% | **+14.3%**（19.58 vs 17.13） |
| bbrplusv3 vs cubic total | +32% | **−5.4%**（380.8 vs 402.5） |
| bbrplusv3 vs cubic min | 旧口径 cubic 更高 | +3.3%（19.58 vs 18.95） |

方向性结论（对原版 bbr 更优）仍成立且更强；但“对 cubic 均值 +32%”不成立，真实逐秒口径是略低 5%。旧口径不能作为最终结论，建议在 ABC 文档追加勘误并复核 KEEP 表述（不改历史正文）。

## 4. 局限（直接证明缺口）

- 只有 1s 吞吐包络，无 `cwnd/pacing_rate/rcv_space/rcv_ssthresh`，无法在数据层直接区分“发送端 cwnd 恢复慢”与“接收端窗口增长慢”。C1/C2 是**形态推断**：非零低平台 + 缓慢爬升，且无 <2 Mbps 空窗/无长期地板。
- 1s 分辨率会漏掉亚秒级空窗；0.5% loss 下 1s 内多次丢失会被平滑。
- 若要闭环证明，需在 harness 加 `ss -tin` 逐秒采样（cwnd/rtt/rcv_space/pacing_rate），当前仪表无此列（`cca-abc-comparison.md` 已记录）。

## 5. 路由与下一步

- `68m`: C1/C2 路径，转入“削深下限 + 恢复墙钟斜坡”候选设计（C1/C2），不转 DRS。
- `0tg`: 前置门结果1 成立，可立项；三候选设计已在 `docs/bbrplusv3-optimization-candidates.md`。
- 管线修正影响 `scripts/wave1_sim/*` 的输入；已用修复后 loader 重跑 `run_all.py`（61s）：排序与裁决不变，但真值段数修正（bbrplusv3 dep30 3→2、cubic 5→2），旧报告中的 310s/301s/536s 长段是 summary 恒值块伪影。勘误见 `docs/wave1-sim-report.md §9`。
