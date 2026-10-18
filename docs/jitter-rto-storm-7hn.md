# netem 抖动 × rto-cut: 虚假 RTO 风暴 (bd tcpboost-7hn) — 诊断与修复报告

分支: `feature/7hn-jitter-rto` (自 feature/aqm-ab-ci 4bf56c5 切出)
探针 run: 见 §4/§5 (全部 30m 级, LEG_SEC=300, 串行)

## 1. 结论 (VERDICT)

`VERDICT: NOT_REPRO — 病理不可复现 (3 次 dispatch / 6 条抖动腿全健康); 票面归因证伪: 原始现场 CC=bbr (非 bbrplusv3) 且 rto_fc_enable=0, rto-cut 从未行使; 轮 1 bpv3 on/off 差分无效应。修复无病可治; 门 2 守卫以防御性定位随分支留档 (本地未推)。裁决归 PM。`

- **① 复现**: FAIL。轮 1 (fq 臂) + 轮 2 (fq_codel/cake 臂) 共 6 条 ACK 抖动腿,
  最差 fq_codel_jloss 65.7 Mbps (温和 -20%), 无任何塌缩签名 (starv/streak/pin
  全零, 发端 cwnd 健康)。轮 4 现场 (8 流 0.5-0.67 Mbps × 20 批) 不可重现。
- **② rto-cut 归因**: 证伪。三重证据: (a) 原始现场 CC=`bbr` 且 rto_fc=0
  (§2); (b) bpv3 抖动腿 enable 1 vs 0 无差分 +2% (§4); (c) rto-cut 属
  tcp_bbrplusv3.c, bbr 流不经过该代码路径。触发器候选 (TCP×抖动 / rto-cut /
  fq_codel×抖动) 全部排除, 剩余解释 = 轮 4 guest 环境瞬态 (TCG 宿主噪声,
  旁证: 塌腿 rtt 25.7ms 畸形样本 + 该 run I/O 死锁 4h)。
- **③④ 修复验证**: 无病可治 — 修复验收 (抖动腿 ≥ 固定腿 50%) 在零修复状态下
  即满足 (94-100%)。门 2 (`rto_fc_max_jitter_us`) 重定位为 batch-4 特性在抖动
  链路的防御性守卫 (§5.1), 本地 commit eeee566 未 push。
- 附带实证: bbrplusv3 对 ACK 抖动鲁棒 (抖动腿全场最高 +26~73%), 抖动真实代价
  fq_codel -20% / fq -6% (无修复必要量级)。

## 2. 现场重析 (run 39039732757 artifact, 2026-10-18)

下载该 run 的 `aqm-ab-results` artifact 重析 (fq_codel_loss 腿 = 抖动+loss, v_s ACK 向
`delay 75ms 75ms`, 数据向 `delay 75ms loss 0.5%`, tbf 166Mbit, 8 流 12.5MB):

| 证据 | 数值 | 出处 |
|---|---|---|
| 8 流吞吐 | 全部 0.50-0.67 Mbps, 聚合 p50 4.6 Mbps (健康对照 111-118) | data/fq_codel_loss.csv |
| RTT | p50 149ms, p95 249ms, max 295ms (抖动已生效) | logs/ping_*.txt |
| **拥塞控制** | **`bbr` (XanMod BBRv3) × 2179 采样, 非 bbrplusv3** | logs/ss_*.txt |
| cli 侧 cwnd | 1090 采样全部 ≤15 (ACK 流, 红鲱鱼 — 非发端信号) | 同上 |
| cli 侧 rcv_space | 钉 14480 × 545 采样 (收端 DRS 随塌缩反向收缩, 效应非成因) | 同上 |

**关键事实修正**: 该 run 的 aqm-ab job 从未设置拥塞控制, guest 默认 CC =
CONFIG_DEFAULT_TCP_CONG=`bbr` (configs/x86_64_apply.sh:86)。rto-cut 钩子只存在于
tcp_bbrplusv3.c (create_bbrplusv3.sh §7c3), 且 `rto_fc_enable` 静态默认 0 ——
**原始现场的虚假 RTO 风暴发生在 XanMod BBRv3 上, rto-1 门在该现场根本未加载**。
票面 "bbrplusv3 rto-1 门诱发" 的归因不成立于原始现场; rto-cut 是否在该 CC 下
放大同一病理, 由 §4 A/B 实证 (bpv3 on/off 隔离腿)。

机理解读 (与 0.6Mbps 逐流吻合, 仅描述轮 4 塌缩态的节奏; 该节奏在本轮 6 条
抖动腿中未再现 → 触发条件疑含环境瞬态成分, 见 §5.3): ACK 向 0-150ms 均匀抖动 → RTT p95 249ms 超过
RTO 下限 (200ms) 与 srtt+4·mdev 估计 → ACK 迟到触发虚假 RTO → cwnd 重置 ~10 包
→ 恢复窗口内再触发 → 钉死节奏 10 包/~0.4s ≈ 0.3-0.6 Mbps/流。这是 CC 无关的
"RTT 方差 > RTO 估计" 类病理, 拥塞控制只能决定恢复速度。

## 3. harness 改动 (3a36643 + ed9929d)

- `LEGS` 腿规格 `TAG:JIT:LOSS:CC:PARAMS` (简名 loss/clean/jloss/jclean 兼容旧矩阵):
  JIT=1 在 v_s(ACK 向) 挂 `delay H Jms` (复刻原始现场); CC 逐 netns 运行时切;
  PARAMS 写 `/sys/module/tcp_bbrplusv3/parameters/` (fail-fast, 防 verify 式假通过)
- `ss_srv_<leg>.txt` 服务端采样: 真发端 cwnd 签名 (cli 侧是 ACK 流恒 ~10, 原始
  报告的 "cwnd 钉 11-13" 即此红鲱鱼)
- analyze: TAGS 改 CSV 发现; 加 `srv_cw50 / cw<20% / cwn` 三列
- workflow: `aqm_legs` / `aqm_jitter_ms` dispatch 参数

## 4. Phase ①+② 探针: 复现 + rto-cut 根因隔离

run: https://github.com/Be90nia/tcpboost/actions/runs/39102562168 (2026-10-18 06:01Z, 成功;
旧 run 39091572503/39098995805 被砍无数据)。LEGS (ARMS=fq, 每腿 300s):
`loss`(bbr 固定对照) `jloss`(bbr 抖动, 复现腿) `bpv3_loss`(bpv3 固定基线)
`bpv3_jloss_on`(rto_fc=1) `bpv3_jloss_off`(rto_fc=0)。SHAPE=187Mbit。

| leg (CC) | batches | tot_p50 | tot_p5 | min_p50 | srv_cw50 | cw<20% | starv% | pin% |
|---|---|---|---|---|---|---|---|---|
| fq_loss (bbr) | 23 | 111.8 | 102.4 | 10.47 | 15 | 51.7 | 0 | 0 |
| **fq_jloss (bbr, 抖动)** | 20 | **104.7** | 90.5 | 8.74 | 14 | 53.7 | 0 | 0 |
| fq_bpv3_loss (bpv3, rto=1) | 30 | 139.1 | 131.9 | 14.97 | 15 | 54.6 | 0 | 0 |
| **fq_bpv3_jloss_on (抖动 rto=1)** | 32 | **153.3** | 138.2 | 17.42 | 14 | 59.1 | 0 | 0 |
| **fq_bpv3_jloss_off (抖动 rto=0)** | 31 | **150.3** | 143.1 | 17.43 | 15 | 57.6 | 0 | 0 |

判读:

- **① 复现 (fq 臂): 未复现**。抖动腿 104.7 vs 固定腿 111.8 Mbps (-6.3%), min-flow
  8.74 vs 10.47, starv/pin 全零, 发端 cwnd 健康 — fq 臂下 ACK 向抖动不触发塌缩
  (对照原始现场 0.6 Mbps/流, 差 ~170 倍)。泛 "TCP × 抖动" 因果被排除; 剩余差分
  变量 = 被测 qdisc (原始现场 fq_codel, 本轮 fq) → 转入 Phase ①b (fq_codel/cake 臂)。
- **② rto-cut 隔离: 排除**。bpv3 抖动腿 on/off 差分 +2.0% (153.3 vs 150.3, 噪声内),
  min-flow/cwnd/RTT 全指标同级 — rto_fc_enable 1→0 不改变抖动腿行为。rto-cut 既非
  塌缩必要条件 (off 满速) 也无恶化效应 (on 不降)。注: 本轮未采 rto_seen/rto_fc_fires
  计数器 (harness 缺 sysfs 采样), 门行使次数未实证; 但 off 臂满速已足以否定
  "rto-cut 为塌缩触发器"。
- 附带发现: bpv3 抖动腿 (153) 反超其固定腿 (139, +10%) — bbrplusv3 对抖动鲁棒,
  无病理。bpv3 各腿全面优于 bbr (+24~46%)。

## 5. Phase ③+④: 守卫修复 + 修复后 A/B

### 5.1 修复对象重定位 (基于 §2/§4 实证)

契约预设 "rto-cut 为触发器 → 参数化守卫挂起 RTO-cut"。实证推翻前提:

- 原始现场 CC=`bbr` 且 rto_fc_enable=0 (§2) — rto-cut 路径未被行使;
- 轮 1 bpv3 on/off 无差分 (§4) — rto-cut 即使开也不调制病理;
- 病理触发器收敛于 **qdisc 交互维度** (Phase ①b, §4.2), 非 CC 模块内部。

故 "挂起 RTO-cut" 类守卫对本病理无治疗作用 (病理不经过该代码路径)。
本轮交付的门 2 (`rto_fc_max_jitter_us`, 本地 commit eeee566, 未 push) 重新定位为
**rto-cut 自身的防御性守卫**: batch-4 特性 (VPS rto_fc=1 场景) 在抖动链路下,
RTO 误触发会被误读为真拥塞并封顶 inflight_hi — 门 2 (mdev_us > 20ms 挂起)
阻断该误动作。这不是 7hn 病理的修复, 是 adjacent hardening, 随分支留档待 PM 裁决。

### 5.2 判读树 (Phase ①b 数据落地前固化, 防事后调整)

- fq_codel_jloss 塌 (≥4/8 流 <1Mbps, 持续多批) → ① 复现 ✓ 于 fq_codel 臂;
  触发器 = fq_codel × ACK 抖动 (±loss 协同, 由 jclean 判定); VERDICT: REJECT 预设归因
- fq_codel_jloss 不塌 → ① REPRO_FAIL (轮 4 现场不可复现, 疑 TCG 环境瞬态);
  VERDICT: NOT_REPRO, 修复无意义
- cake_jloss 塌 → codel 家族共病; 不塌 → fq_codel 特有
- fq_codel_bpv3j 塌 → CC 无关 (TCP 栈层); 不塌 → bbr CC 敏感

### 5.3 Phase ①b 结果 (run 39118792759, 2026-10-18 10:19Z, 全 job success)

ARMS=`fq_codel cake`, LEGS=`jloss loss jclean bpv3j:1:1:bbrplusv3:rto_fc_enable=0`,
每腿 300s, SHAPE 校准健康。8 腿全量:

| leg (CC) | batches | tot_p50 | tot_p5 | min_p50 | min_p5 | starv% | streak | pin% | srv_cw50 |
|---|---|---|---|---|---|---|---|---|---|
| fq_codel_jloss (bbr, 抖动) | 13 | 65.7 | 63.0 | 5.52 | 3.28 | 0 | 0 | 0 | 14 |
| fq_codel_loss (bbr, 固定) | 18 | 81.8 | 75.1 | 7.49 | 6.17 | 0 | 0 | 0 | 14 |
| fq_codel_jclean (bbr, 抖动净) | 19 | 90.0 | 76.5 | 8.06 | 6.99 | 0 | 0 | 0 | 14 |
| fq_codel_bpv3j (bpv3, 抖动) | 25 | **140.8** | 130.9 | 13.10 | 7.49 | 0 | 0 | 0 | 18 |
| cake_jloss (bbr, 抖动) | 17 | 121.5 | 106.9 | 7.49 | 3.38 | 5.88 | 1 | 0 | 14 |
| cake_loss (bbr, 固定) | 24 | 108.6 | 100.9 | 10.48 | 8.74 | 0 | 0 | 0 | 14 |
| cake_jclean (bbr, 抖动净) | 19 | 108.6 | 90.8 | 8.06 | 6.99 | 0 | 0 | 0 | 14 |
| cake_bpv3j (bpv3, 抖动) | 19 | 125.1 | 115.0 | 8.74 | 5.52 | 0 | 0 | 0 | 14 |

判读 (对照 §5.2 预固化判读树, **B 分支**):

- **① 复现: 失败 (REPRO_FAIL)**。fq_codel_jloss 65.7 Mbps (相对其固定腿 -20%,
  温和代价) — 无 ≥4/8 流 <1Mbps 塌缩, starv/streak/pin 全零, 发端 cwnd 形态健康
  (cw<20% 52.8% 与各健康腿同级, p50 14 = batch 启动期主导)。累计 3 次 dispatch
  (39091572503 砍 / 39098995805 砍 / 39102562168 成功) + 本轮, 共 6 条抖动腿
  全部健康; 轮 4 现场 (8 流 0.5-0.67 Mbps × 20 批持续) 不可复现。
- **触发器假设穷尽**: 泛 TCP×抖动 (§4 fq 臂)、rto-cut (§4 on/off)、fq_codel×抖动
  (本轮) 逐一排除。剩余解释 = 轮 4 guest 环境瞬态 (TCG 宿主噪声): 旁证 = 塌腿
  ss 出现 rtt 25.7ms 畸形样本 (netem 150ms 路径下不可能的正常下限) + 该 run
  harness.log 仅 13 行即遭 I/O 死锁 (tee 4h 挂死撞墙钟) — 该 guest 当时处于
  异常态。
- **cake_jloss 单批 starv 5.88% (streak 1)**: 17 批中 1 批瞬态, 无持续塌缩,
  不构成签名。
- 抖动的真实代价 (供 PM 参考): fq_codel -20%, fq -6%, cake +12% (jloss 反超
  loss, 噪声级); bpv3 CC 抖动腿在两臂均最高 (fq_codel 臂 140.8, cake 臂 125.1,
  较 bbr 同配方 +26~73%) — bbrplusv3 对 ACK 抖动鲁棒性再次实证。

## 6. 机理侧记 (轮 4 artifact 深挖, 供后续追查参考)

- **qdisc 清白**: 塌缩期 fq_codel 统计 `dropped 0 / ecn_mark 0 / backlog 0b` 恒零
  (tc_fq_codel_loss.txt, 15 个 30s 快照) — codel dropping/排队均未发生, 瓶颈
  队列空转, 吞吐塌缩非 qdisc 压制。
- **直接吞吐瓶颈 = 接收窗**: cli 侧 rcv_space 双态钉 14480 (1083 socket 采样中
  545 次) ÷ RTT 150ms ≈ 0.72 Mbps/流 ≈ 观测塌缩值 (0.5-0.67) — DRS (接收端
  自动调窗) 收敛到塌缩速率后自锁 (低速→不扩窗→持续低速), 是死循环环节、效应
  非成因。
- **发端伪重传洪水**: rcv_ooopack 持续累积 (单连接 93 → 4965, ~2-4 包/s) =
  原包迟到与重传副本并存 — 触发源在发端 RTO/重传节奏 (发端侧采样缺失, 见下)。
- **证据缺口**: 轮 4 无发端 (ss_srv) 采样; ss 里 "cwnd 钉 11-13" 出现在 cli —
  ACK 流 (bytes_sent:37) 的空闲 cwnd, 红鲱鱼。塌腿发端 cwnd/bbr 形态永久缺失,
  不可补采。
- **已排除**: maxpacket 巨大 (塌腿 12112) 与塌缩无关 — 健康腿 (轮 6 fq_codel)
  maxpacket 36336 同级; rto-cut (§4); codel dropping (零 drop)。

## 7. 交付清单

- harness 扩展 (3a36643 + ed9929d, 已推): LEGS/CC/PARAMS 腿维度 + 发端 cwnd 采样
  + workflow `aqm_legs`/`aqm_jitter_ms` dispatch 参数 — 本轮 A/B 即其产物
- 门 2 守卫 (本地 eeee566, **未 push**): `rto_fc_max_jitter_us` (mdev_us > 20ms
  挂起 RTO-cut, 0=关) — 防御性 hardening, 非 7hn 病理修复 (§5.1)
- 本报告 + bd tcpboost-7hn comment (不 close, 裁决归 PM)
