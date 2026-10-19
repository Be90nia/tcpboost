# batch-6 候选 2 评估: Dumazet 2025-05 "tcp: receive side improvements" 11 补丁回移可行性

> 评估日期: 2026-10-19。只评估, 未改任何代码/配置/CI。
> 一手来源: LWN 汇编 https://lwn.net/Articles/1021321/ (cover letter) + lore mbox
> https://lore.kernel.org/netdev/20250513193919.1089692-1-edumazet@google.com/ (11 补丁全文 + 上游 review 线程)
> 实证方法: vanilla 7.2.11 / 6.12.113 源码树本地 git apply 双向校验 + 签名 grep + GitHub 提交史检索。
> 工作树: D:/tmp/dumazet-eval (t72/ t612/ 两棵干跑树 + p01–p25.mbox 全系列拆分), 未入仓。

## 0. 结论 (一句话)

**回移对 7.2 系列不成立——11 补丁已全部在 7.2 基线内 (vanilla 7.2.11 实测), 且上游在此之上又叠了约 8 个后续修正; 更关键: 该系列治的是 rx 自调"RTT 高估→rcvbuf/space 过冲", 不是 W4 的"copied≤space 增长前提死锁→rcv_space 钉 64KB"(7.2.11:983 死锁前提原样保留), W4 根治仍归已落地的 unstick。** 候选 2 的正确收口: 7.2 无事可做; 6.12(默认 CI 系列)确无此系列, 但回移收益与 W4 脱钩且是 15+ commit 终态链工程, **建议不做**; tcp_rmem[2] 32MB **不采纳**(profiles 全覆盖)。

## 1. Q1: 7.2 系列的基线内核版本到底是什么

CI 链 (.github/workflows/build-kernel.yml):

1. `check-version`: 从 kernel.org kdist feed 取该系列最新版 → **7.2 系列当前 = vanilla 7.2.11**(6.12 = 6.12.113 longterm);
2. `Download kernel source`: `cdn.kernel.org/.../v7.2.x/linux-7.2.11.tar.xz` —— **纯 vanilla kernel.org 源码, 无 XanMod 位**;
3. `Apply Xanmod BBRv3 patches`: 我们自己的 `patches/7.2/xanmod-bbrv3/`(3 件, BBRv3 移植);
4. `Apply CloudPassenger custom patches`: `kernel_patches/7.2/net/`(4 件, bbr1/bbrplus/brutal; 本地目录已建, 否则 fallback CP 远端 pinned 0314d34)。

即 "7.2" 是**内核主版本 7.2.x**, 目录名 "xanmod-bbrv3" 只是补丁系列标签, 与 XanMod 发行版版本号无关。基线 = vanilla 7.2.11, 无歧义。

## 2. Q2: 11 补丁哪些已在基线里

方法: 对 vanilla 7.2.11 逐补丁 `git apply --reverse --check`(精确反向命中 = 内容逐字在位), 反向未中者再逐签名 grep 终态代码。

| # | 补丁 (v1 标题) | 7.2.11 状态 | 证据 |
|---|---|---|---|
| 01 | tcp_rcvbuf_grow() tracepoint | ✅ 在位(已演化) | `TRACE_EVENT(tcp_rcvbuf_grow` @ include/trace/events/tcp.h:207; tcp_input.c:986 调用 |
| 02 | fix sk_rcvbuf overshoot | ✅ 在位(已演化) | `tcp_rcvbuf_grow()` 已成为 `void tcp_rcvbuf_grow(struct sock*, u32 newval)` @ tcp_input.c:911 |
| 03 | adjust rcvbuf in presence of reorders | ✅ 在位(已演化) | `rcvwin += TCP_SKB_CB(tp->ooo_last_skb)->end_seq - tp->rcv_nxt` @ tcp_input.c:944 |
| 04 | receive queue awareness in rcv_space_adjust | ✅ 精确反向命中 | reverse-check OK |
| 05 | remove zero TCP TS samples | ✅ 精确反向命中 | reverse-check OK |
| 06 | fix initial rcvq_space.space (passive TS) | ✅ 精确反向命中 | reverse-check OK |
| 07 | always seek minimal rtt in tcp_rcv_rtt_update | ✅ 在位 | `new_sample = old_sample - (old_sample >> 3) + sample` @ tcp_input.c:852 |
| 08 | skip big rtt sample if receive queue not empty | ✅ 精确反向命中 | reverse-check OK |
| 09 | tcp_limit_output_bytes 默认 1MB→4MB | ✅ 精确反向命中 | reverse-check OK |
| 10 | always use tcp_limit_output_bytes limitation | ✅ 精确反向命中 | reverse-check OK |
| 11 | tcp_rmem[2] 6MB→32MB | ✅ 在位 | `max_rshare = min(32UL*1024*1024, limit)` @ tcp.c:5364 + ip-sysctl.rst:875 "between 131072 and 32MB" |

**合并版本**: v6.16 原文实测 0 命中(raw tag 检索), 11 补丁应用日期 2025-05-15(net-next), 首补丁 `2da35e4b4df9`("tcp: add tcp_rcvbuf_grow() tracepoint")对 v6.17 的 GitHub compare = `status: behind`(祖先包含)——**合并于 v6.17**, 实锤; 本仓库支持的 6.18/7.0/7.1/7.2 均在其后 → 全部包含。**唯一不含的是 6.12 longterm**(6.12.113 前向 apply 7/11 REJ, §3)。

**上游后续链(重要)**: 该系列合入后并不稳定, 上游又叠了约 8 个修正 (GitHub 提交史):
- `65c5287892e9`(02/11 overshoot 修复本体)→ Neal Cardwell 报出 **RWIN-limited 回归**(tcp_rmem[2]=512MB 仍受限), 引出 "tcp: fix too slow tcp_rcvbuf_grow() action"(2025-10)+ "add newval parameter" 拆分;
- `e118cdc34dd1` mptcp rcvbuf auto-tuning improvement + mptcp 三件连带修复 (2025-10/2026-02);
- "tcp: add net.ipv4.tcp_rcvbuf_low_rtt" 新 sysctl (2025-11);
- "tcp: update window_clamp when SO_RCVBUF is set" (2026-04, 与我们 862340ff SO_RCVBUF 锁定路径直接相关);
- "tcp: do not let tcp_rmem be set below 4096" 除零崩溃修复 (2026-09)。

含义: **任何"回移"都不能按 LWN v1 的 11 封邮件做——v1 中间态含已知回归**, 必须按终态 git 链 cherry-pick, 且拖上 mptcp 依赖。

## 3. Q3: test-apply 结果与我方补丁的冲突面

### 3.1 对 7.2(vanilla 7.2.11): 缺失补丁 = 0, test-apply 无对象

反向验证即结论: 不存在需要 apply 的缺失补丁。

我方 7 补丁链在 vanilla 7.2.11 上的顺带实测(与 Dumazet 无关的维护信号):

| 补丁 | 严格 `git apply --check` | `patch -p1 -F3` | 漂移 |
|---|---|---|---|
| xanmod 0001 (bbrv3) | REJECT (tcp.h:235) | ✅ offset -3, fuzz 2 | 老化 |
| xanmod 0002 (collapse) | REJECT (netns/ipv4.h:242) | ✅ offset +9 / sysctl +42 | 老化 |
| xanmod 0003 (unstick) | REJECT (netns/ipv4.h:217) | ✅ offset +2 | 轻微 |
| CP 0000 (bbr1) | REJECT (tcp.h:677) | ✅ offset +99, fuzz 2 | 老化较重 |
| CP 0001/0002 (新文件) | ✅ 直接应用 | — | 无 |
| CP 0003 (Makefile) | REJECT(级联: 0000 未上, bbr1.o 行缺失) | ✅ | 级联 |

漂移全部为行偏移/fuzz 级(CI 的 `git apply --3way → --recount → patch -F3` 兜底链可救), **无一指向 Dumazet 内容造成的语义冲突**。但按 unstick 教训(fuzz 应用=静默错位风险), 7.2 链该做一次 re-offset 刷新 + qemu unstick A/B 复核——列为独立 followup, 不属候选 2。

### 3.2 对 6.12(vanilla 6.12.113): 4 干净 + 7 REJ(若决策回移)

| 补丁 | `git apply --check` | 备注 |
|---|---|---|
| 01 tracepoint | ✅ 干净 | |
| 02 overshoot | ❌ REJ tcp_input.c:771 | 依赖整块重构(增长逻辑搬出 rcv_space_adjust); v1 形态已被上游证伪(too-slow 回归) |
| 03 reorders | ❌ REJ tcp_input.c:760 | 依赖 02 的 tcp_rcvbuf_grow() |
| 04 queue awareness | ❌ REJ tcp.h:340 + tcp_input.c | 依赖 02/03; struct 字段 u32→int |
| 05 zero TS samples | ❌ REJ tcp_input.c:712 | 4 hunk, 上下文 6.13+ 演化(EXPORT_IPV6_MOD 等) |
| 06 initial space (passive TS) | ❌ REJ tcp_input.c:6872 | advmss-=12 时序移动, 手工 rebase 易 |
| 07 minimal rtt seek | ❌ REJ tcp_input.c:664 | EXPORT_IPV6_MOD 上下文, 函数体 6.12 同构, rebase 易 |
| 08 skip big rtt | ✅ 干净 | |
| 09 TSQ 4MB | ✅ 干净 | |
| 10 always TSQ limit | ✅ 干净 | |
| 11 rmem 32MB | ❌ REJ ip-sysctl.rst:735 | 代码 hunk 干净, 仅文档行漂移 |

依赖链: 02→03→04 强耦合; 加上 §2 的终态链要求(mptcp、newval 拆分、low_rtt、除零修复), 6.12 回移 ≈ **15+ commit 的 cherry-pick 工程, 3–5 人日 + 两轮 30m 探针**, 收益见 §4 判为与 W4 脱钩。

### 3.3 与我方核心补丁(kernel_patches/ bbrplus 系列)的冲突面

- **文件交集**: Dumazet 系列只动 `ip-sysctl.rst / include/linux/tcp.h / include/trace/events/tcp.h / tcp.c / tcp_input.c / tcp_ipv4.c / tcp_output.c`; bbrplus/brutal/bbr1 三件套主体是**新增文件**(tcp_bbrplus.c / tcp_brutal.c / tcp_bbr1.c) + Makefile/Kconfig 钩子 + tcp.h/tcp_output.c 个别声明行——与 Dumazet hunk 区域**不相交**, 仅行偏移级影响。
- **逻辑交集**: 与 xanmod 0003-unstick 的关系是**互补而非冲突**: Dumazet 修"过冲/RTT 高估", unstick 修"rcv_ssthresh 钉死 + 通告窗不开"。7.2 的 unstick 0003 本来就是在含 Dumazet 终态的函数形状上写的(hunk2 首上下文行 = `int time, inq, copied;`, 正是 04 补丁的产物), 已共存在 CI 基线里。
- **6.12 若回移**: unstick 0020 的 hunk1(tcp_init_buffer_space 尾)与 Dumazet 全部 hunk 无文本重叠; hunk2(rcv_space_adjust 头, trace 之后)在 02 重构后依然存在(trace 调用在函数顶部保留), 需按新函数形状重建 offset, 语义合并平凡。

## 4. Q4: 逐补丁独立价值排序(对 VPS 代理 / W4 场景)

先给机制判据: W4 钉死根因 = `tcp_rcv_space_adjust()` 的增长前提 `if (copied <= tp->rcvq_space.space) goto new_measure;` 在 loss 打断交付后永不满足 + rcv_ssthresh 启发式不再抬窗。**7.2.11 实测: 该前提原样保留**(tcp_input.c:983-984), `tcp_init_buffer_space()` 的 min3 低起点(:773)也原样保留。即 **Dumazet 系列没有触碰 W4 的死锁前提**, 它修的是反方向(过高估计导致 rcvbuf/space 过大、CPU cache/DDIO 失效)。

| 排序 | 补丁 | 对 W4 | 对 1-CPU VPS 代理 | 裁决(7.2) |
|---|---|---|---|---|
| 1 | 08 skip big rtt (queue non-empty) | 间接正向: rx RTT 样本去排队延迟污染, 高 loss 下防 RTT 高估 | 有益 | 已在基线 |
| 2 | 07 minimal rtt seek | 间接: rx RTT 恒取 min, 影响 `time < rtt>>3` DRS 门控频率(:975) | 有益 | 已在基线 |
| 3 | 04 queue awareness (inq) | **中性偏负**: `copied -= inq` 在应用读慢时更保守, 收端自调更难增长——W4 竞速场景需盯 | 中性 | 已在基线 |
| 4 | 03 reorders rcvbuf | 轻微正向(乱序期不算欠账) | 有益 | 已在基线 |
| 5 | 02 overshoot fix | 无(治过冲) | 上游两次返工, 终态有益 | 已在基线(终态) |
| 6 | 06 passive TS advmss | 12 字节级 | 微 | 已在基线 |
| 7 | 05 zero TS samples | 亚 ms DC 场景; 150ms 路径无感 | ~0 | 已在基线 |
| 8 | 09/10 TSQ 发端两项 | 无 | 200G 量级收益; 1Gbps VPS 边际; 10 号在无 pacing 场景有边界价值 | 已在基线 |
| 9 | 11 rmem 32MB | 无 | 见 §6 | 已在基线; profiles 覆盖 |
| 10 | 01 tracepoint | 0(观测工具) | 诊断用 | 已在基线(且已演化加强) |

**对候选 2 立项理由的修正**: "根治 W4"的预期不成立——系列治过冲, W4 是钉死; 两者只在"rx 自调不准"这一层是同族。862340ff(SO_RCVBUF 兜底)+ unstick(已落地)仍是对口武器。

## 5. Q5: 回移工作量估计与验证方案

- **7.2 系列**: 回移工作量 = **0**(全部在基线且已含后续修正)。候选 2 在 7.2 上的正确动作 = 无代码动作 + 可选观测(见下)。
- **6.12 系列**: 干净 backport 不存在(4/11 干净, 其余依赖终态链 + mptcp 连带), 估 **3–5 人日**改写 + 验证。按 §4 收益裁决**建议放弃**; 若未来 6.12 上出现真实的 rcvbuf 过冲证据(tracepoint 显示 rcvbuf ≫ 2×BDP), 再按终态链立项。
- **验证方案(30m 探针, 沿用 CI soak_duration=30m 运行时参数)**:
  - 腿: loss 0.5% + 单向 75ms(双向 150ms)+ 8 并发 curl range(报告原配方), off/on A/B;
  - 采样: `ss -tin` 每 0.5s(现有 soak 基建), 采收端每流:
    - **钉死签名(W4 主判据)**: 任一流 `rcvq_space.space ≤ 65KB` 持续 >60s 的流数(期望 0; unstick on 腿已应 0);
    - **过冲签名(Dumazet 系列的主判据)**: `sk_rcvbuf` 峰值 ≤ 2×BDP(1Gbps×150ms≈18.75MB→≤37.5MB), 且 `perf -e tcp:tcp_rcvbuf_grow` 可用(7.2 基线自带该 tracepoint);
    - **回归门**: 8 流 median 吞吐 ≥ 基线 90%; 30m 探针稳 2 轮才视为 code 成熟(战役纪律)。
  - qemu 层: unstick A/B 用例已覆盖 on 腿窗口增长; 若做 6.12 回移需补 tcp_rcvbuf_grow 路径的 smoke(除零回归就是 2026-09 才修的, 前车之鉴)。

## 6. Q6: tcp_rmem[2] 32MB 提额补丁单独裁决

**不采纳。** 理由:

1. **profiles 全覆盖**: tcp.sh 四档全部显式设定 `net.ipv4.tcp_rmem`(conservative 4MB / balanced 16MB / aggressive+tls `${buf_max}` 按 BDP 动态, tcp.sh:1352/1394/1463/1595)与 `net.core.rmem_max`, 内核默认值(6MB@6.12 / 32MB@7.2)在 tcpboost 部署里**永不生效**——补丁 11 是给"没人调参的默认内核"用的。
2. **1-CPU 单流代理**: 32MB 上限只在 autotune 无锁时被摸到; 多流突发下各流可冲 32MB, `tcp_mem` 压力路径与 collapse 抖动是真实代价(1GB 内存 VPS 更敏感), 收益仅覆盖 BDP>15MB 的单流场景——而 aggressive 档的 `${buf_max}` 机制(跨洋 1Gbps×161ms≈20MB 已注释在案)按需给得比一刀切 32MB 更准。
3. **7.2 基线已含 32MB**(tcp.c:5364), 即便要"吃上游"也是零操作。

## 7. 验收对照与证据索引

| 契约问题 | 答案位置 | 实证 |
|---|---|---|
| Q1 基线版本 | §1 | build-kernel.yml + kernel.org feed (7.2.11 / 6.12.113) |
| Q2 在基线状态 | §2 表 | t72 反向 apply 7/11 精确命中 + 4 补丁签名 grep (tcp_input.c:852/911/944/986, tcp.c:5364, ip-sysctl.rst:875) |
| Q3 test-apply + 冲突面 | §3 | 7.2: 缺失=0, 我方链 F3 全可救; 6.12: 4 OK + 7 REJ; 文件交集分析 |
| Q4 价值排序 | §4 | 死锁前提在 7.2.11:983 原样保留(实测函数体) |
| Q5 工作量 + 验证 | §5 | 6.12 依赖链 + 终态链 commit 史 |
| Q6 32MB 裁决 | §6 | tcp.sh 四档 rmem 实测 |

复现命令(评估树已留存于 D:/tmp/dumazet-eval):

```
# 反向命中(7.2): cd t72 && git apply --reverse --check ../pNN.mbox  (NN=02..12, p01=cover)
# 签名验证:    grep -n 'tcp_rcvbuf_grow' t72/net/ipv4/tcp_input.c
# 6.12 前向:    cd t612 && git apply --check ../pNN.mbox
# 我方链:      t72 上按序 git apply patches/7.2 + kernel_patches/7.2 (REJECT 者以 patch -p1 -F3 dry-run 复核)
```

## 8. 遗留与建议

1. **followup(独立于候选 2)**: 7.2 链对 7.2.11 的行偏移老化(含 CP 0000 offset +99 / fuzz 2 与 CP 0003 级联)建议做一次 re-offset 刷新 + qemu A/B 复核, 消除对 `-F3` 兜底的长期依赖。
2. 候选 2 建议改判: "7.2 无事可做; 6.12 放弃(与 W4 脱钩, 终态链成本高)"; W4 继续沿 unstick + 862340ff + (可选)gambar mux 方向。
3. 若保留观测兴趣: 7.2 已自带 `tcp:tcp_rcvbuf_grow` tracepoint(带 rtt_us/inq/space/rcvbuf 字段, 上游后续还加了 rcv_ssthresh/window_clamp/rcv_wnd 三字段), 下次 soak 顺手采样即可量化过冲/钉死两个签名, 零内核改动。
