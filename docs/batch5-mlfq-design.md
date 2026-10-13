# batch-5 设计定稿: MLFQ-1 (分档 pacing gain, 对症 8 并发公平/饿死)

> 2026-10-13 · 依据: wdb design-of-record (最优分层) + 深扒 §2.3 骨架
> 前置变化: PI 默认关 (wdb 冲突 2 消失), ABC 不存在 (冲突 1 消失), 新采样器使 min 流真可测

## 目标症状
8 流争抢 (xhttp 场景) 下, 弱流频繁 loss 却仍以激进增益 (1.375) 冲击瓶颈,
加剧队列震荡; 健康流与弱流互相拖累. MLFQ: 连续 loss 的流降档到保守增益
(少添乱), 稳定 1s 的流回档 (不永久惩罚).

## 分层 (wdb 定稿)

| Level | 基线 UP gain | 降档条件 | 回档条件 |
|---|---|---|---|
| L0 | 1.375 (vanilla) | — | — |
| L1 | ×1.0 (cap at 1.0) | 连续 5 个 loss round | 1s 无 loss 降回 L0 |
| L2 | ×0.7 | 再累计 5 个 loss round | 1s 无 loss 升回 L1 |

- 计数单位: **round** (bbr->round_start + bbr->loss_in_round, BBRv3 现成信号),
  非 per-ACK — 防高 RTT 下重复计数
- Rule 5 (1s boost): 升一级 (L2→L1, L1→L0), 非直接跳 L0 — 减少增益振荡

## 与 beta 的互斥 (wdb 条 3)
- L0/L1: beta 照常
- L2: inflight_hi 削减乘 mlfq 乘数 (0.7), **不叠加 beta 削减** —
  effective cut ≤ max(单机制)
- 不变量: 任意时刻 effective cut ≤ max(单机制削减)

## 与 PI 的共存 (wdb 条 2, PI 现默认关)
- MLFQ 在 pi_adjust 重放基线 gain 处接入: 基线 = vanilla gain × mlfq 乘数
- PI 开时: delta 照旧附加, 跳层时 pi_int_err 清零 (状态一致性)

## struct 预算
u8 mlfq_level + u8 mlfq_loss_cnt + u32 mlfq_last_loss (jiffies) ≈ 8B 含对齐
→ struct ~184B, ICSK 256 余量充足

## 参数
mlfq_en (默认 1) / mlfq_l2_gain_pct (70) / mlfq_loss_rounds (5) / mlfq_boost_ms (1000)

## CI 可测性声明 (新纪律)
- 新采样器 (真 8 并发) 下 total/min 均真 → 30m 探针可判:
  预期 total↑ (弱流少过冲) 或 min↑ (弱流少抢), 二者其一可辨
- 判绿线: min 相对新默认 (k=0/p=0 基线) 不降 且 total 不降 >5%
- 30m 探针 → 修/调 → 5h 出厂章

## 验收 (wdb 原文)
1. 单流 0 loss: 永远 L0, 行为不变
2. 8 并发 netem 5%: 无饿流恶化, total/min 不降
3. 任意拥塞事件只触发一条削减路径 (rto_fc 已默认关, 无重叠)
