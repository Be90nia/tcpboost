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

## 4. 结果 (点火后回填)

TBD

## 5. 裁决 (TBD)

TBD
