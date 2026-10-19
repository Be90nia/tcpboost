# atj: BBRPlusV3 vs 原版 A/B/C 横比 (Wave-0, 设计定稿版)

> 票: bd tcpboost-atj (P3, ← tcpboost-86e)。**核心问题: tcpboost 卖点 "BBRPlusV3 比原版性能提升多少" 从未被实测 — 本文档量出这个数字。**
> 环境: CI only (`atj/cca-mix-ci` @ e72240b), vng QEMU guest 7.2 系内核; VPS 零接触。
> 设计演变: 混跑 (per-stream CCA) → 用户澄清生产环境只有 bbrplusv3 → 推翻 → 纯 A/B/C 三轮 8 同流横比 (定稿, 不再改)。

## 1. 设计 (定稿)

| 轮 | CCA | run id | 状态 |
|---|---|---|---|
| A | **bbrplusv3** (tcpboost 卖点) | [38887594698](https://github.com/Be90nia/tcpboost/actions/runs/38887594698) | in_progress |
| B | **bbr** (原版基线) | 待 A 完成后串行派发 (workflow_dispatch 排队折叠: 同 ref pending dispatch 会被新 dispatch 顶掉, 实测 38887603966 被顶, 故必须串行) | - |
| C | **cubic** (经典参照) | 待 B 完成后串行派发 | - |

- profile 统一: netem 双向 loss 0.5% + RTT≈150ms (soak_delay_ms=75 双腿), 8 并发 iperf3 (每流独立端口 5202-5209, STREAM_ROTATE_SEC=300), 30m/轮, 采样 30s。
- **不升级 5h** — 这是比较实验不是稳定性门禁 (用户拍板)。
- 30m 噪声带内分不出 → 只重跑模糊的那一轮一次; 再分不出 → 如实报 "30m 粒度下持平"。

## 2. 仪表 (全部经 CI 验证)

- 采样器: SoakNoise 修复版 (fix/soak-sampler 4a638d0, CI 双 run ALL PASS: sockstat 标签匹配 / iperf3 tab-JSON 兼容 / tcpmem / psi 空值兜底)。
- analyzer: 本支线 e72240b 修 CSV 列位偏 1 + verdict 函数/变量同名冲突 (gawk 恒空 regression.md 根因), 合成数据验证全对。
- 加载 RTT: 现行仪表 (timeseries.csv / samples.jsonl / streams/*.jsonl) 无 RTT 列 — **条件不齐, 本轮不量测** (如实记录)。若后续需要, 需 harness 加 ss rtt 采样 (设计冻结不改)。

## 3. 判读方法

- 数据源: 每轮 artifact `soak-test-results/<ts>/`。
- **total / min / p50**: `streams/stream-1..8.jsonl` (每行为该轮 iperf3 各 interval bits_per_second, `0` 为轮转空档标记须剔除)。命令:
  `awk '$1+0>0 {s+=$1;n++;if(mn==""||$1<mn)mn=$1; v[n]=$1} END{asort(v); printf "avg=%.3fMbps min=%.3fMbps p50=%.3fMbps n=%d\n", s/n/1e6, mn/1e6, v[int(n/2)]/1e6, n}' stream-N.jsonl`
  跨 8 流再聚合成轮级 total/min/p50; 与 `timeseries.csv` (ss delivery_rate 视角) 交叉校验。
- **Jain 公平指数**: `J=(Σxᵢ)²/(8·Σxᵢ²)`, xᵢ=各流 avg bps。8 同流 J→1 = 无结构性偏斜。
- **噪声带**: 同轮内 8 流 avg 的极差/中位数比 + 轮内 timeseries 的 min 流波动; 两轮差 < 噪声带 → 记"分不出"。
- **VERDICT 输出格式** (首行): `bbrplusv3 vs 原版 bbr: total +X%, min +Y% (+噪声带说明)`; 全文 `VERDICT: bbrplusv3 显著优 / 持平 / 劣于`。

## 4. 结果

(待三轮跑完填充)

## 5. 结论

(待填充)


## 结果 (2026-10-17 收割, PM 计算)

| 指标 | A bbrplusv3 | B bbr(原版) | C cubic |
|---|---|---|---|
| total 均值/中位 | 535.6 / 347.7 | 496.4 / 321.0 | 404.6 / 395.8 |
| min 均值/中位 | 23.89 / 12.43 | 13.59 / 10.80 | 35.46 / 11.87 |
| p50 流均值 | 33.47 | 31.25 | 25.34 |

- **bbrplusv3 vs 原版 bbr: total +8%, min 最弱流 +76%** — 均值/中位双同向, 稳健结论
- bbrplusv3 vs cubic: 均值 +32% 但中位 -12%, 30m 粒度下持平
- runs: A=38887594698 / B=38913043898 / C=38887614387 (各 54-55 采样, loss 0.5% + 150ms)

VERDICT: bbrplusv3 优于原版 bbr (公平性增益显著, 总吞吐温和); vs cubic 30m 粒度持平

## 勘误 (2026-10-19, 68m 离线分析)

原 total/min 口径混用了 `summary.md`（timeseries `16×p50` 派生）与 `streams/*.jsonl`（summary 行导致相位错位）。用修复后的 `iperf3-server-*.log` 逐秒流级序列重算（三轮均为 ~1800s，8 流）：

| 指标 (逐秒真实) | bbrplusv3 | bbr | cubic |
|---|---:|---:|---:|
| total 均值 (Mbps) | 380.8 | 308.2 | 402.5 |
| total 中位 (Mbps) | 348.1 | 298.8 | 408.2 |
| min 流均值 (Mbps) | 19.58 | 17.13 | 18.95 |

- bbrplusv3 vs bbr：total **+23.6%**（旧 +8%），min **+14.3%**（旧 +76%）。方向成立且更强，但“+76%”不复现。
- bbrplusv3 vs cubic：total 均值 **−5.4%**（旧 +32%），中位 **−14.7%**；min 均值 +3.3%。旧“均值 +32%”是派生列口径造成的，不可作为结论。
- 对原版 bbr 的 KEEP 方向不受影响；对 cubic 的表述需按新口径复核。旧表保留作历史对照。
