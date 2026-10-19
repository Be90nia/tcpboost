# 68m 后的优化空间评估 — 2026-10-19

**结论 (首行): 有空间，但只剩一条高置信主线 — 丢包后的“恢复完整性/恢复速度”(C1/C2)。** 68m 三分法落在 C1/C2；DRS、规律锯齿、oBBR、Dumazet、startup、FaiRTT 均无新证据支撑。C3 (ProbeBW 振幅) 只值得一次纯参数旁路。**最高优先级不是新算法，而是先补仪表（RTT/cwnd/rcv_space）**，否则 C1/C2 无法归因，也无法给队列副作用设门。

复现: `python scripts/analysis/recovery_timeline.py --out reports/68m`；判定细节见 `docs/68m-recovery-timeline.md`，机器可读数据在 `reports/68m/recovery-timeline.json`。

## 1. 修正后的证据基线

权威源: `iperf3-server-*.log` 每秒流级序列（修复 summary 行拼接 bug 后，见 `scripts/wave1_sim/common.py:62`）。三轮 atj A/B/C，loss 0.5% + 150ms，8 流 × ~1800s。

| 指标 | bbrplusv3 | bbr | cubic |
|---|---:|---:|---:|
| total 均值 / 中位 (Mbps) | 380.8 / 348.1 | 308.2 / 298.8 | 402.5 / 408.2 |
| min 流均值 / 中位 (Mbps) | 19.58 / 16.8 | 17.13 / 15.7 | 18.95 / 16.8 |
| 深跌次数 | 411 | 272 | 428 |
| 60s 内未恢复 80% | **39 (9.5%)** | 14 (5.1%) | 15 (3.5%) |
| 恢复中位 / p90 (s) | 5.0 / 21.2 | 4.0 / 23.5 | 4.2 / 21.8 |
| <2 Mbps 持续 ≥2s | 0 | 0 | 0 |
| <12 Mbps 持续 ≥10s | 0 | 0 | 6 |
| 规律锯齿 CV / 众数覆盖 | 0.86 / 17.8% | 1.03 / — | 0.85 / — |

读法:
- **对原版 bbr**: total +23.6%、min +14.3%，但慢恢复比例更高（9.5% vs 5.1%）。收益与恢复债并存。
- **对 cubic**: 总吞吐均值 −5.4%、中位 −14.7%，min 略高（+3.3%）。BBR 用吞吐换公平/低队列，不能简单判“落后”。
- **不可恢复段是主损失**: 深跌后常见 100+ Mbps → 11–18 Mbps 低平台，再以 ~4.4 Mbps/s 爬升；最长 18s 的深跌 60s 内未回 80%。这不是零窗口（发端空窗），而是非零低平台 + 慢斜坡。

> 旧 `cca-abc-comparison.md` 的 total/min 口径已勘误（`16×p50` 派生列 + streams 相位错位）；`W2 最弱流不敌 cubic` 的旧前提不成立。新口径应以本节为准。

## 2. 已关闭方向（不再立项）

| 方向 | 关闭理由 |
|---|---|
| DRS/rcv_space 地板 | bbrplusv3 无任何流 <12 Mbps 持续 ≥10s；无 <2 Mbps 空窗。生产 xhttp DRS 是另一条线，不由 atj 轨迹支撑。 |
| 规律增益锯齿 (C3 作为主因) | 深跌间隔 CV≈0.86，众数覆盖 17.8%，Poisson 式而非固定周期。 |
| oBBR 三件套 | batch-6 预注册 G1 双向反转 FAIL，已 DROP；本数据不改变该结论。 |
| Dumazet 11 补丁 | 已在 7.2.11 基线，且治 rx 过冲不治本数据形态。 |
| startup / e1 | 参数已对齐（2.25/2.885 + smart exit）；数据无 startup 证据。 |
| FaiRTT / RTT 公平 | 单路径、同 RTT 8 流，收益边际；先解决恢复。 |
| 抖动/min_rtt 旧化 | 7hn 已证抖动鲁棒；本数据无路径突变。 |

## 3. 候选排序

| 序 | 候选 | 机制 | 证据 | 改动量 | 风险 | 先做 |
|---|---|---|---|---|---|---|
| P0 | **仪表补齐** | 每秒采 `ss -tin`: cwnd/rtt/rcv_space/pacing_rate + CPU% | 当前只有吞吐包络，C1/C2 只能形态推断 | harness ~30 行 | 无产品风险 | 与下一轮 A/B 同跑 |
| P1 | **C1 削深下限** | 丢包削减设“跌前 BDP/速率”地板，禁止一次砍到 11–18 Mbps | 9.5% 深跌 60s 不恢复；谷底集中 11–18 Mbps | 内核 ~30–40 行 + 1 参数 | 队列反弹、与 lower-bound 双响应 | C1a beta=25% **FAIL**（total −4.8%）；测 C1b `c1_floor_pct=50` |
| P1 | **C2 恢复墙钟斜坡** | 丢包后强制在 1 个 RTT 内进入 UP 探测，不等随机 2–3s 周期 | 恢复中位 5s、p90 21s；39 次 >60s | 内核 ~25 行 + 2 参数 | 过冲/双响应（oBBR 前车之鉴） | C1 无效或叠加 |
| P2 | **C3 ProbeBW 振幅收窄** | `pacing_gain_up 1.375→1.25`、`down 0.85→0.91` | 无规律锯齿 → 预期低；仅作参数旁路 | 0 行（sysfs） | 总吞吐下降、探测变慢 | C1/C2 均无效时 |
| P2 | W5 CPU 基线 | 同轮采 CPU% | 1-CPU VPS 是主部署形态 | 0 行（采样） | 无 | 搭车 |

### P1-C1 削深下限

**假设**: 一次丢包把 `inflight_lo/inflight_hi` 压到远低于跌前 BDP，导致深谷；后续只能靠 ProbeBW 慢爬。若给削减设地板（如跌前 BDP 的 50%），谷底抬高、恢复时间缩短。

**源码确认 (2026-10-19, `patches/7.2/xanmod-bbrv3/0001`)**:
```c
u32 loss_cut = BBR_UNIT - bbr_param(sk, beta);
*inflight = max_t(u32, bbr->inflight_latest,
                  (u64)bbr->inflight_lo * loss_cut >> BBR_SCALE);
```
beta=30% → 保留 70%；beta=25% → 保留 75%，即**更浅的削减**。因此 `beta=25%` 是正确的 C1 快筛参数，不是反向。

**已实现 C1b（默认 off）**: `scripts/create_bbrplusv3.sh` §7c-bis2（`:540`），在 `bbr_loss_lower_bounds()` 的 `*inflight` 之后加地板，复用 `bbr_max_bw()` + `bbr_bdp()`，module_param `c1_floor_pct`（0=off，50=不低于 50% BDP），并加构建期 grep 守卫防 sed no-op。无需新增 `c1_prior_bw` 快照。

**C1a 结果 (2026-10-19, soak-only 30m, v7.2.11, `min_pacing_rate=0`)**:

| 指标（逐秒 server log） | baseline beta=76 | beta=64 | delta | 预注册判据 |
|---|---:|---:|---:|---|
| total 均值 (Mbps) | 396.3 | 377.1 | **−4.8%** | FAIL（需 ≥+5%） |
| min 流均值 (Mbps) | 19.70 | 19.53 | −0.9% | PASS（≥−3%） |
| 深跌次数 | 415 | 380 | −8.4% | 改善 |
| 60s 未恢复 | 25 | 32 | **+28%** | FAIL（需 ≤−50%） |
| 恢复中位 (s) | 5.0 | 4.0 | −20% | 改善 |

- run: baseline `39232815997` / C1a `39232827655`，日志已确认 `beta=76/64`、`min_pacing_rate=0`。
- **VERDICT: FAIL**。beta 削浅减少了深跌次数、加快中位恢复，但总吞吐下降且长尾未恢复更多——乘法削减深度不是主杠杆。
- 注意: `summary.md` 的 total/min 是 timeseries 派生口径（min_mbps 在 30s 瞬时采样），本节一律用逐秒 server log。
- **决定**: 按预注册顺序先测 **C1b 绝对 BDP 地板**（`c1_floor_pct=50`，需新内核）；C1b 仍 FAIL 则转 C2。C1b 代码已默认 off，main workflow 已接 `c1_floor_pct` 输入。
- C1b 构建: run `39237198600`（7.2, force_build, soak 30m, c1_floor_pct=50）。首个 run `39237061632` 因 sed 锚点跨行陷阱取消：`*inflight = max_t(...)` 跨两行，`a\` 会插进语句中间；已改为锚第二行并加位置守卫（`create_bbrplusv3.sh:549`）。
- **对照方法学**: C1b 臂没有同构建 paired baseline（需再烧一次全量构建）。对照用 v7.2.11 C1a-baseline（396.3/19.70/415/25）——两者 BBRv3 代码路径一致、唯一差异是地板参数；若 C1b 结果落在噪声带内，判 "分不出" 而不是硬判方向。

**C1b 结果 (2026-10-19, 全新构建 + 30m soak, `c1_floor_pct=50` 已确认写入)**:

| 指标（逐秒 server log） | baseline v7.2.11 | C1b floor=50%BDP | delta | 预注册判据 |
|---|---:|---:|---:|---|
| total 均值 (Mbps) | 396.3 | 327.2 | **−17.4%** | FAIL（需 ≥+5%） |
| total 中位 (Mbps) | 359.7 | 282.1 | −21.6% | — |
| min 流均值 (Mbps) | 19.70 | 18.07 | **−8.3%** | FAIL（需 ≥−3%） |
| 深跌次数 | 415 | 310 | −25.3% | 机制生效 |
| 60s 未恢复 | 25 | 26 | +4.0% | FAIL（需 ≤−50%） |
| 恢复中位 (s) | 5.0 | 4.0 | −20% | 改善 |
| 相对饿死段 | 6 段/88s/max 23s | **2 段/22s/max 11s** | 大幅改善 | — |

- **VERDICT: FAIL**。地板确实防住了深跌（−25%）、饿死段 6→2、恢复更快，但 total **−17.4%**、min 也 −8.3%——保留 inflight 的代价是持续队列，吞吐代价远超收益。
- **因果反转 (重要)**: 两次 C1 探针一致表明**深跌与高 total 正相关**——砍得深、探得猛的流赢走带宽；68m 的"未恢复=吞吐损失"框架把相关性当成了因果。"恢复慢"不是 total 瓶颈。
- **C2 前提同步削弱**: C1b 已证明"更快恢复中位"不带来 total（−17% 下恢复反而 4s）。C2（强制早探测）的预期收益机制不成立。
- **裁决 (预注册熔断)**: C1/C2/C3 线 **PARKED**——C3 振幅收窄与 C1b 同向（少探测→更低 total），预期同样为负。`c1_floor_pct` 保留为默认 off 的**公平性 opt-in 旋钮**（饿死段 6→2 是真实收益），不当吞吐优化用。
- 探针产物: `reports/68m/probe-beta/{baseline,c1}/`（逐秒 server log + 原始 artifact）。

**预期**（目标，不是实测）: 未恢复率 9.5%→<5%，恢复 p90 21s→<12s，total 均值 +5% 量级；min 不降。若 total 不升而 min 升，也算部分成功。

### P1-C2 恢复墙钟斜坡

**假设**: 丢包后 BBR 等待下一个 ProbeBW UP 相位（随机 2–3s + 相位对齐），造成 5s 中位、21s p90。若丢包后 1 个 RTT 内强制一次 UP，恢复墙钟显著缩短。

**落点**: `struct bbr` 增 `unsigned long c2_loss_stamp`；在丢包处理（`bbr_handle_inflight_too_high`/`bbr_exit_loss_recovery` 附近，create 脚本注释锚点 `scripts/create_bbrplusv3.sh:1130-1132`）记录时间；在 `bbr_probe_bw()` 的 CRUISE/DOWN 分支，满足 `time_after(now, stamp + c2_delay_ms)` 且 `inflight < bdp` 时调用 `bbr_start_bw_probe_up(sk)`（create 脚本已在 `:899` 使用该函数）。**只在 inflight_hi 本回合被削减过时触发一次**，触发后清 stamp，防 oBBR 式双响应。

**参数**: `c2_enable=0`、`c2_delay_ms=200`（约 1–2 RTT，150ms 场景）。默认 off，单特性 A/B。

**预期**: 恢复 p90 21s→<10s；未恢复率减半；total +3–5%。风险是过冲导致丢包/队列上升，必须由 P0 仪表设门。

### P2-C3 ProbeBW 振幅收窄

纯运行时参数，不重编译:
```bash
PD=/sys/module/tcp_bbrplusv3/parameters
echo 320 > $PD/pacing_gain_up     # 1.25 × 256
echo 233 > $PD/pacing_gain_down   # 0.91 × 256
```
现网 aggressive 是 1.375/0.85（`scripts/create_bbrplusv3.sh:101-105`，module_param 在 `:328-331`）。数据没有规律锯齿，预期收益低；只在 C1/C2 均无信号时做，且必须看 total/min 双指标。

## 4. 30m 探针预注册（下一轮唯一动作）

**环境**: 复用 `atj/cca-mix-ci` 的 `.atj-scratch/soak_mix.sh`；netem 双向 loss 0.5% + 150ms；8 流 × 30m；CC=bbrplusv3 单臂，串行 dispatch（同 ref pending 会被顶掉）。

**新增仪表（与 A/B 同跑，零额外 CI）**: 采样器加每秒 `ss -tin` 解析 `cwnd/rtt/rcv_space/pacing_rate`，加 `mpstat`/`pidstat` 的 CPU%。产物进 `soak-test-results/<ts>/tcp_stats.jsonl`。这是 C1/C2 归因和队列门的前提。

**臂**:
1. baseline（当前 aggressive，kalman/pi 保持现网值）
2. C1a1: `beta=25%`（64/256）单参数
3. C1a2（仅当 C1a1 无信号）: `loss_thresh=5%`（13/256）单参数
4. C1b（仅当 C1a1/C1a2 均无信号）: 结构地板 `c1_floor_pct=50`
5. C2（仅当 C1 无信号或叠加）: `c2_enable=1, c2_delay_ms=200`
6. C3（仅当 C1/C2 均无信号）: `pacing_gain_up=320, pacing_gain_down=233`

**判据（预注册）**:
- **PASS**: total 均值 ≥ baseline +5% **且** min 流均值 ≥ baseline −3% **且** 未恢复率 ≤ baseline/2 **且** 无新增 <12 Mbps ≥10s 段。
- **队列门（有仪表后生效）**: 平均 RTT/排队时延 ≤ baseline +10%；超过则即使 total 提升也判 FAIL。
- **KILL**: total −5%、min −10%、CPU +10%、或出现新的 11–18 Mbps 长平台。
- 30m 一轮；模糊（差值 <轮内噪声带）只重跑一次；不把 5h soak 当诊断工具。

## 5. 代码/数据落点

| 内容 | 位置 |
|---|---|
| 68m 分析器 | `scripts/analysis/recovery_timeline.py`（`--selftest` 内置 4 类合成序列） |
| loader 修复 | `scripts/wave1_sim/common.py:62`（跳过 iperf3 summary 行） |
| 参数表 | `scripts/create_bbrplusv3.sh:86-89`（tunables）、`:101-105`（UP/DOWN gain） |
| A4 lower-bound 锚点 | `scripts/create_bbrplusv3.sh:528` |
| C1 开关 / 注入 | `scripts/create_bbrplusv3.sh:97`（static）、`:540`（bbr_loss_lower_bounds 地板 + 守卫） |
| RTO inflight_hi cap 范例 | `scripts/create_bbrplusv3.sh:1148` |
| C2 UP 触发范例 | `scripts/create_bbrplusv3.sh:899`（`bbr_start_bw_probe_up`） |
| beta 削减位置 | `scripts/create_bbrplusv3.sh:1224`（mlfq L2 跳过 beta 双重削减） |
| 运行时参数 | `/sys/module/tcp_bbrplusv3/parameters/{beta,loss_thresh,pacing_gain_up,pacing_gain_down}` |

C1/C2 的具体行号需在 7.2.11 `net/ipv4/tcp_bbr.c` 落地时按实际源码确认；本文只锁定函数名、锚点与注入方式，避免凭记忆写行号。

## 6. 风险与边界

- **归因未闭环**: 1s 吞吐 + 无 `cwnd/rcv_space` 时，C1/C2 是形态推断。P0 仪表未上线前，结构补丁属于“有依据的赌博”，必须默认 off + 预注册判据。
- **对 cubic 的 total 差距不能靠加激进度硬追**: harness 无 RTT 列，盲目提 gain 可能用排队换吞吐；队列门必须先于结论。
- **单轮 30m + 8 流**: 只能筛掉大效应；C1/C2 若效应 <5%，需 5h 门禁或更多轮，不能据一轮宣称成功。
- **oBBR 教训**: 任何“丢包后更激进回填”都要检查与 v3 lower-bound 的双重响应；C1/C2 都必须只动一个旋钮，并记录 `inflight_hi/lo` 轨迹。
- **数据修正影响历史结论**: Wave-1 排序不变但真值段数变化；ABC 的 +76% min 不复现。后续引用一律用修正后口径。

## 8. 公平性标定战役 (2026-10-19 启动)

**目标**: 给 `c1_floor_pct` 定 knee 值——吞吐预算内最小化饿死。

**三臂** (同一 release 内核 `v7.2.11-tcpboost`=新构建含 C1b 代码, beta=76, 30m, 0.5%/150ms, 8 流, 并行):
- base0 (floor=0): run `39255255666` — 同内核对照 (旧基线 396.3 来自无 C1 代码的 v7.2.11, 需重测控漂移)
- floor30: run `39255260886`
- floor50: run `39255265761`

**预注册 knee 规则 (看数前钉死)**:
1. 预算以 base0 臂为基准: `total_mean ≥ base0 × 0.95` 且 `min_stream_mean ≥ base0 × 0.97`。
2. 预算内选 `starved_total_s` 最小者; 无达标臂 → knee 不存在, floor 维持 0, 公平性另寻机制。
3. floor30/50 双达标且公平性随 floor 单调改善 → 补 floor70 一臂再定。
4. 选中值跑 5h soak 出厂门禁 (probe workflow 已接 `c1_floor_pct`, timeout 360), 过门禁才准上队。

判据口径: 逐秒 server log (分析器 `--dirs`), 饿死指标 = probe.json `starved` 段 (episodes/total_s/max_s)。

**30m 标定结果 (13:00, 三臂全绿)**:

| 臂 | total | min 流 | 深跌 | 60s未恢复 | 饿死段 |
|---|---:|---:|---:|---:|---|
| base0 (floor=0) | 341.9 | 17.31 | 382 | 24 | 2 段/22s/max12 |
| floor30 | 348.1 (+1.8%) | 18.57 (+7.3%) | 374 | 25 | 2 段/25s/max14 |
| floor50 | 346.4 (+1.3%) | 17.12 (−1.1%) | 321 | 31 | 5 段/76s/max21 |
| (参考: 昨 C1b floor50) | 327.2 | 18.07 | 310 | 26 | 2 段/22s/max11 |
| (参考: 旧 v7.2.11 基线) | 396.3 | 19.70 | 415 | 25 | 6 段/88s/max23 |

- **分辨率判定**: 同配置 floor50 两跑饿死 22s vs 76s (3.5×), base0 total 漂移 396→342 (−14%), min 臂间 ±4%——**30m 单窗对饿死/min 指标无分辨率**, 预注册规则的 floor30 "胜出" 落在噪声带, 不认。
- **按协议升级**: 30m 稳定性已证 (4 跑无故障), 效应量未分辨 → 直接 5h 成对门禁, 同轮同内核, 样本 ×10。

**5h 成对门禁 (预注册, 看数前钉死)**: base0-5h run `39260138793` / floor30-5h run `39260147451` (beta=76, 5h, 0.5%/150ms, 8 流):
1. 公平性主判据: `starved_total_s(floor30) ≤ 0.5 × base0` **且** `min_stream_mean(floor30) ≥ base0`。
2. 吞吐守卫: `total_mean(floor30) ≥ 0.95 × base0`。
3. 双过 → PASS, floor=30 进 D 阶段上队; 主判据不过 → knee 在 5h 尺度也不存在, 旋钮 PARKED 维持 0, 公平性另寻机制。
4. 门禁只跑一次, 不循环; FAIL 即终审。

## 7. 建议顺序

1. **P0 仪表 + baseline 30m**（同轮），拿到 cwnd/rcv_space 后重算 68m 指标。
2. **C1a `beta=25%` 30m → FAIL**（total −4.8%，未恢复 +28%）。
3. **C1b `c1_floor_pct=50` 30m → FAIL**（total −17.4%，min −8.3%；但饿死段 6→2）。
4. **C1/C2/C3 线 PARKED**（因果反转：深跌与高 total 正相关，"恢复慢"不是 total 瓶颈）；`c1_floor_pct` 留作公平性 opt-in。
5. 后续 total 优化需新机制/新证据立项，不在本轮范围内。
