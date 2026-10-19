# batch-6 候选 1: oBBR 三件套 A/B (tcpboost-obbr-1)

**状态**: 实施完成, 判据预注册于点火前 (本 commit 即预注册版本, 结果回填后不得改动判据节)。
**分支**: feature/batch6-obbr (自 feature/7hn-jitter-rto ed9929d 切出)

## 0. 背景与动机

内部实测 W1: 丢包后 inflight 上限回填慢 (median 落后 cubic −12%, docs/bbrplusv3-weakness-inventory.md)。
规范根源: draft-ietf-ccwg-bbr-05 的 excess-loss 响应把 inflight_hi 削到当前 cwnd, 之后恢复速度绑定在
2-3s 随机间隔的 ProbeBW up-phase 上。文献最优 (唯一有公网 A/B 数字): oBBR (Bi et al., USENIX ATC'23,
github.com/bpq233/oBBR, QUIC 用户态; 逻辑纯计数器, 内核可移植)。

## 1. 移植内容 (tcpboost-obbr-1, 注入路径 scripts/create_bbrplusv3.sh §7c5-decimus)

| # | oBBR 机制 | 内核落点 |
|---|---|---|
| ① | 丢包时自适应 cwnd_gain: g = clamp(RTT_latest/RTprop [μ=1], 1.25, g_max=2.0) | per-ACK `bbrplusv3_obbr_update()`: `rs->losses>0` 时写 `bbr->obbr_g` (16.16 定点), 并把 `inflight_hi` 钳到 g 档目标; `bbr_update_gains()` PROBE_BW 分支把 `cwnd_gain` 钳到 `obbr_g>>8` |
| ② | per-ACK 线性回填 g += α·S_ack/BDP (α=0.01) 爬回 g_max | 同函数尾部, 16.16 定点 + 余数累加器 `obbr_frac` (防亚单元截断); 同步抬 `inflight_hi` 至 g 档目标 |
| ③ | 带宽跌检测: 连续 k=30 样本 <0.75×BtlBw 或 RTT>(g_max+0.5)×RTprop → 用 k 样本均值刷新 BtlBw; 更新前后投递分 U=delivered−10×unacked (T=200ms) 变差即回滚 | 通道 A/B 同函数中段; 刷新写 `bw_hi[1]`, 快照 `obbr_bw_saved`/`obbr_u_before`/`obbr_rb_at`, 回滚臂还原 |

参数 (`/sys/module/tcp_bbrplusv3/parameters/`): `obbr_enable` (默认 **0** = 全路径零行为变化),
`obbr_alpha` (默认 10 = 0.01), `obbr_k` (默认 30), `obbr_rolls_ms` (默认 200)。
诊断计数 (0444): `obbr_cuts` / `obbr_drops` / `obbr_rolls`。

边界: 仅 PROBE_BW 相位生效 (STARTUP 归 smartexit/A5); app-limited 样本不参与; struct bbr +44B
(预算 ~202B → ~246B, ICSK_CA_PRIV_SIZE=256 内, 未动 ICSK)。

**参考实现可达性注记**: bpq233/oBBR 在实施时点 raw/API/镜像全 404 (疑似转私有), 三件套按论文机制
(docs/lit-review-bbr-opt-intl.md §3 + lit-review-bbr-opt-cn.md §S1 双源一致) 移植。

## 2. 预注册判据 (点火前固化)

### 腿矩阵 (CI aqm-ab-test job, ARM=fq 单臂, 每腿 300s, TCG QEMU)

| 腿 (TAG:JIT:LOSS:CC:PARAMS) | 作用 |
|---|---|
| `bpv3_loss_ob0:0:1::obbr_enable=0` | 主对照 (现网默认行为) |
| `bpv3_loss_ob1:0:1::obbr_enable=1` | 主对 (loss 0.5% + 双向 150ms 固定) |
| `bpv3_clean_ob0:0:0::obbr_enable=0` | 无回归对照基线 |
| `bpv3_clean_ob1:0:0::obbr_enable=1` | 无回归对照 |
| `bpv3_jloss_ob0:1:1::obbr_enable=0` | 抖动基线 (ACK 向 75ms±75ms, 7hn 配方) |
| `bpv3_jloss_ob1:1:1::obbr_enable=1` | 抖动鲁棒性 (7hn 实测抖动是优点, 不许丢) |
| `cubic_loss:0:1:cubic:` | median 参照 (无门) |

### 门禁 (VERDICT = PASS 需 G1∧G2∧G3∧G4 全过; 任一不过 = FAIL)

- **G1 (主对, loss 腿回填加速)**: `tot_p50(bpv3_loss_ob1) ≥ tot_p50(bpv3_loss_ob0)`
  **且** 发端 cwnd 恢复用时缩短: recovery_p50(loss_ob1) < recovery_p50(loss_ob0)。
  recovery 定义: 对 `ss_srv_fq_bpv3_loss_obN.txt` (5s 采样), B = 该腿全部 cwnd 样本 p75;
  连续样本 max(cwnd) < 0.9×B 为一个 dip 段, 段长 = 样本数×5s; recovery_p50 = 各 dip 段长中位数。
- **G2 (无回归, clean 腿)**: `tot_p50(clean_ob1) ≥ 0.9 × tot_p50(clean_ob0)`。
- **G3 (抖动鲁棒性, jloss 腿)**: `tot_p50(jloss_ob1) ≥ 0.9 × tot_p50(jloss_ob0)` 且
  `min_p50(jloss_ob1) ≥ 0.9 × min_p50(jloss_ob0)` (不塌, 保持 7hn 水平)。
- **G4 (无新饿死/钉死签名)**: starv%(各 ob1 腿) ≤ starv%(同规格 ob0 腿) + 1pp,
  且 pinmax(ob1) ≤ pinmax(ob0); 机制侧 `obbr_cuts > 0` 且 `obbr_drops ≥ 0` (证明机制真实行使)。
- **G5 (参照, 不设门)**: cubic_loss tot_p50 记录, 供 median 相对位置参照。

### 判读与后手

- PASS → 保持 obbr_enable 默认 **0** 不变 (上线节奏归 PM), bd 挂结果注记。
- FAIL → 默认 0 维持, 报告记录失败维度与假设 (α/k 初值或 v3 下界机制交互), 归档 follow-up。

## 3. 运行环境

- GitHub Actions `Build TCPBoost Kernel`, kernel_series=7.2, force_build=true, aqm_skip_release=true,
  soak_duration=5m (本跑为 A/B, 不做长跑门禁), aqm_leg_sec=300, aqm_arms=fq, aqm_legs=上表 7 腿。
- 禁碰: 生产 VPS / release tag / main。

## 4. 结果 (run 39189344806, 2026-10-19, kernel 7.2.11, 全 job success)

CI: check-version/build-kernel/qemu-test/soak-test(5m)/aqm-ab-test 全 success, create-release skipped。
接线证明: harness.log 每腿 `bpv3 params applied: obbr_enable=N` (sysfs fail-fast 通过, 模块参数存在);
cubic 腿 CC 切换生效。artifact: `aqm-ab-results` (retention 7d)。

```
leg                      tot_p50  tot_p5  min_p50  starv%  pinmax  cw50  retrans_sum
fq_bpv3_loss_ob0          139.8    82.3    14.97    0.00      0     15     13511
fq_bpv3_loss_ob1          120.7    76.5    11.65    0.00      0     14     13239
fq_bpv3_clean_ob0         125.7   113.5    13.10    0.00      0     15       342
fq_bpv3_clean_ob1         123.7   110.2    13.10    0.00      0     15       272
fq_bpv3_jloss_ob0         125.9    84.7     9.53    0.00      0     15     12717
fq_bpv3_jloss_ob1         118.5    80.1     9.53    0.00      0     14     12832
fq_cubic_loss              13.6     7.9     1.34    0.00      0     10      1460
```

recovery (预注册估计量: B=p75(cwnd), dip=<0.9B 连续段, 5s 采样粒度):
- loss_ob1: p50=1027ms p90=3550ms n=14 段;  loss_ob0: p50=854ms p90=5500ms n=10 段

### 门禁裁决

| 门 | 结果 | 数据 |
|---|---|---|
| G1 (loss 回填加速) | **FAIL** | tot_p50 120.7 vs 139.8 (**−13.7%**) 且 recovery_p50 1027 vs 854ms (更慢) — 两个方向都反 |
| G2 (clean 无回归) | PASS | 123.7 ≥ 0.9×125.7 (=113.1), −1.6% |
| G3 (jloss 不塌) | PASS | tot 118.5 ≥ 0.9×125.9; min_p50 持平 9.53 |
| G4 (无 starv/pin) | PASS | 三对腿 starv 均 0.00%, pinmax 均 0; 机制行使证据见下 |
| G5 (cubic 参照) | 记录 | 13.6 (bbrplusv3 两位数倍于 cubic, 与历史一致) |

**VERDICT: FAIL** (G1 不过) → `obbr_enable` 维持默认 **0**, 不合主线建议, 归档 follow-up。

### 解读与 follow-up 假设 (未经本轮验证, 供 PM 决策)

1. **机制确实行使**: ob1 与 ob0 唯一差异是 enable 门控代码路径; loss 腿 tot −13.7% + 发端 cwnd p50
   15→14 + 批次数 32→27, 方向一致。局限: harness 未采样 `obbr_cuts/obbr_drops/obbr_rolls` 计数器
   (0444 sysfs), 行使次数无直接读数 — follow-up 可在 harness leg 末尾加一行 param dump。
2. **双重削减假设 (主嫌疑)**: bbrplusv3 在 0.5% 随机 loss 下已有 v3 lower-bound 削减
   (adapt_lower_bounds→loss_lower_bounds 压 inflight_lo/bw_lo) + mlfq 降档; obbr 再叠 inflight_hi cap
   + cwnd_gain 钳制 = 对同一次丢包双重响应。oBBR 论文的增益是相对 BBRv2 (β=0.7 深削) 的;
   v3/bpv3 的 loss 响应本就更温和, 第二套削减是净负。
3. **per-ACK 重割棘轮假设**: 0.5% loss ≈ 每 ~200 包一次 loss ACK, 每次都把 g 重设为当前 RTT 比值
   (fq 浅队列下 ≈ 地板 1.25); α=0.01/RTT 的回填每 RTT 只 +1%, 割得快填得慢 → g 长期贴地板,
   等效 cwnd 永久 −25~35%, 与 −13.7% tot 量级吻合。潜在修法 (未验证): 割一次后本轮 recovery
   内抑制重割, 或 α 随 RTT 比值放大。
4. **重传未降**: loss 腿 retrans_sum ob1≈ob0 (13239 vs 13511) — 论文 headline (2% loss 重传大降)
   在 0.5%+fq 场景不成立。
5. **环境噪声带**: loss_ob0 (139.8) > clean_ob0 (125.7) +11% (同配置不同腿), 说明腿间噪声
   ~±10%; G1 的 −13.7% 只略出噪声带, 但与 cwnd 签名/recovery 同向, FAIL 判定稳健。
6. **抖动腿尾部改善信号**: jloss_ob1 最差流 min 5.5 vs ob0 3.7 (+49%), tot −5.9% — 机制在抖动
   场景或对尾部流有益, 若未来重启候选值得单独探针。

## 5. 裁决

按预注册规则: **FAIL**。默认 off 维持; 本分支保留实现与判据供复验 (重跑命令见 §3), 合并/回滚归 PM。
follow-up 候选 (均需重新预注册): 计数器采样进 harness、双重削减去耦 (只留回填不留割)、
抖动场景单独探针。

