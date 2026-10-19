# BBR 家族缺点盘点 × 国际优化文献调研（International Track）

**结论（首行）**：七个缺点的国际文献覆盖齐全且相互印证——BBRv3 的核心病灶（对 CUBIC 深缓冲不公平、staggered 收敛 >4min、自诱导排队 ~1 RTTmin、startup 先发优势终身固化、ProbeRTT 周期性吞吐塌陷、丢包后 inflight 上限回填慢）在 PAM'24 / IFIP Networking'25 / ICNC'26 三篇独立评估中全部复现；最优可抄方案依次为：oBBR（ATC'23）的自适应 in-flight cap + 快速带宽跌落检测（对缺点 3/2）、LBNL ICNC'26 的 startup 增强变体 e1（对缺点 5/2，长 RTT +15% Jain）、BBRv2+（CoN'22）的 delay-based probing（对缺点 2）、FaiRTT（IEEE'24）的 per-ACK BDP 模型（对缺点 7）、内核 Dumazet 2025-05 接收侧补丁系列（对缺点 6）；种子文献 arXiv 2505.07741 实际 venue 是 **IFIP Networking 2025**（非 IMC'25）；**"BBR-nF (PAMD'26 smart exit)" 四路检索查无此文献，标 UNVERIFIED**。

---

## 0. 快查表：每缺点一行最优文献方案

| # | 缺点 | 最优文献方案（一行） | 文献 |
|---|------|---------------------|------|
| 1 | ProbeRTT 停顿 | 沿用 BBRv3 已改的 5s 周期 + cwnd=BDP/2，进一步做 per-flow 相位随机化防同步；pacing 保底、只降 cwnd 上限不降速率 | draft-ietf-ccwg-bbr-05; PAM'24 Table 1; oBBR ATC'23 |
| 2 | 与 CUBIC 共存不公平 | 自适应 cwnd_gain：按"RTT 增量反推瓶颈缓冲深度"动态调 g（浅缓冲降 g、深缓冲回 g_max=2），配 per-ack 线性回填 | oBBR (USENIX ATC'23); BBRv2+ (CoN'22) |
| 3 | 丢包后回填慢 | 把 inflight_hi 削减后的恢复改为 per-ACK 线性爬升（g += α·S_ack/BDP, α≈0.01）+ 带宽跌落快速检测（k=30 连续低样本）+ 错判回退 | oBBR (USENIX ATC'23); BBR-ACD (Electronics'20) |
| 4 | min_rtt 滤波器陈旧 | 跨洋固定路径风险低于 LEO/蜂窝；维持 10s 窗口 + 5s ProbeRTT 刷新已够，重点防"陈旧高 RTT 样本污染接收侧自调"（那是缺点 6 的机制） | draft-05 §min_rtt; Sussex LEO'25; LWN 1021321 |
| 5 | 短流 startup 慢 | startup 激进度再抬（长 RTT 场景 +15% Jain、util>95%）+ plateau 双条件退出防过早退出——bbrplusv3 的 2.25/2.685+smart exit 与文献方向一致；短流额外收益有限（KIT'25 实测仅微弱胜 CUBIC） | LBNL ICNC'26 BBRv3e1; KIT Networking'25; RFC 9406 HyStart++ |
| 6 | 接收窗 DRS/rcv_space 地板 | 升级/回移 6.12+ 内核含 Dumazet 2025-05 "tcp: receive side improvements" 11 补丁（修 rx 自调 RTT 高估、rcvbuf 过冲、最小 RTT 采样；200G 单流 73.6→122.5 Gbit/s）；继续用 SO_RCVBUF 显式钉为可接受兜底 | LWN/patchwork 1021321 (2025-05) |
| 7 | RTT 方差/抖动敏感 | per-ACK 基于 RTT 实测重算 inflight/BDP 速率（FaiRTT：Jain 0.98、利用率 98.78%）；BBRv3 对抖动本身不算脆弱（KIT'25），但抖动伤排队时延与公平 | FaiRTT (IEEE HPSR'24); KIT Networking'25 |

---

## 1. Probe_RTT 停顿（种子 1）

**机制确认（T1/T2）**
- **[BBR 原始论文]** Cardwell et al., "BBR: Congestion-Based Congestion Control", ACM Queue/CACM 2016. https://queue.acm.org/doi/10.1145/3012426.3022184 — ProbeRTT 期 cwnd 降到 4 包让全部 BBR 流自我同步（self-synchronization），这既加速公平收敛、也造成周期性全网吞吐塌陷（bubble）。
- **[IETF 规范]** "BBR Congestion Control", draft-ietf-ccwg-bbr-05, 2026-03, Experimental. https://www.ietf.org/archive/id/draft-ietf-ccwg-bbr-05.html — BBRv2/v3 已把 ProbeRTTInterval 降到 **5s**、ProbeRTTCwndGain=**0.5**（BDP/2）、时长 max(200ms, 1 RTT)；v1 为 10s / 4 包。
- **[独立实测]** Zeynali et al., "Promises and Potential of BBRv3", PAM 2024（Best Paper）, LNCS 14538, pp.249-272, DOI 10.1007/978-3-031-56252-5_12. 作者版 PDF: https://research.vu.nl/ws/portalfiles/portal/367913888/Promises_and_Potential_of_BBRv3.pdf — 版本差异表证实上述参数演进。
- **[停顿代价]** Bi et al., "oBBR", USENIX ATC 2023. https://www.usenix.org/system/files/atc23-bi.pdf — 明确把 "ProbeRTT 期吞吐骤降、把带宽让给竞争流" 列为 BBR 病灶之一；竞争流借 ProbeRTT 窗口抢占，BBR 因无视丢包在浅缓冲下反被驱逐（R=0.5 时丢包率达 13.36%）。

**优化方案与增益**
- 无单一"消灭 ProbeRTT"的公认方案；文献路线是**参数已由 v3 收紧 + 调度随机化/自适应化**：
  - **BBR-R**（"BBR-R: Improving BBR performance in multi-flow competition scenarios", Computer Networks, 2024, DOI 10.1016/j.comnet.2024.110892 [DOI 号 UNVERIFIED，以 ScienceDirect 页为准]）https://www.sciencedirect.com/science/article/abs/pii/S1389128624006480 — 指出 "ProbeRTT 机制偏离设计初衷"，提出自适应发送速率，目标多流下更小瓶颈队列且保 goodput（正文付费墙，方法细节 UNVERIFIED）。注意与 AINA 2024 同名论文（"BBR-R: Improving BBR's RTT Fairness by Dynamically Adjusting Delay Detection Intervals", https://link.springer.com/chapter/10.1007/978-3-031-57840-3_7）区分。
  - **BBR-SJ**（"BBR-SJ: Optimization of time delay jitter in GEO satellite network", ICSPCN 2024, ACM, DOI 10.1145/3712335.3712342）— GEO 时延抖动场景的 BBR 变体（付费墙，细节 UNVERIFIED）。
  - Linux 内核实现自带 per-flow 随机化（probe_rtt 进入时刻基于各自 min_rtt 时间戳），同步 bubble 在异质 RTT 下已被稀释——这是"可直接抄"的既有行为。
- **KIT'25 补充**：Bless, Lihotzki, Zitterbart, "Insights into BBRv3's Performance and Behavior by Experimental Evaluation", IFIP Networking 2025. https://publikationen.bibliothek.kit.edu/1000182022 — BBRv3 单流常态自加 **0.95 RTTmin** 排队时延（来自 ProbeBW up-gain 1.25 的自诱导队列，非 ProbeRTT），多流 >50% 时间 >1 RTTmin；即"低时延目标未达成"，ProbeRTT 只是周期性塌陷来源之一。

**对 bbrplusv3 适配性**：**需改造（小幅）**。部署环境 150ms RTT 下，ProbeRTT 一次停顿 ≈200ms+1RTT≈350ms，5s 周期即 ~7% 时间近零速——对长连接 span 流量可感知。可直接抄 v3 的 5s/BDP÷2 基线；改造点：①probe 期保 pacing_rate 不降、仅压 cwnd 上限（fq 下 pacer 平滑，恢复无尖峰）；②已有 mlfq pacing 可让 ProbeRTT 让出的窗口优先被本机低优先级流吸收。不建议引入付费墙未验证的 BBR-R/BBR-SJ 细节。

## 2. 与 CUBIC 共存不公平（种子 2）

**核心必读**
- **Sarpkaya, Srivastava, Fund, Panwar**, "BBR's Sharing Behavior with CUBIC and Reno", **IFIP Networking 2025**（⚠️ 契约写的 IMC'25 有误）, arXiv:2505.07741. https://arxiv.org/abs/2505.07741 （slides: https://fatihsarpkaya.github.io/files/BBR_IFIP_Networking_2025.pdf ）— 在 FABRIC 平台系统检验 BBRv1/v2/v3 对 Ware 稳态模型与流体模型的符合度：稳态模型只对 BBRv1 成立；流体模型对 v1/v2 大体成立但在**深缓冲、大流数、intra-flow 公平**场景失效；**BBRv3 与全部已有模型预测出现明显偏差**，需要新模型。
- **Ware, Mukerjee, Seshan, Sherry**, "Modeling BBR's Interactions with Loss-Based Congestion Control", IMC 2019, DOI 10.1145/3355369.3355604. https://dl.acm.org/doi/10.1145/3355369.3355604 （作者自述 https://blog.apnic.net/2020/01/24/modelling-bbrs-interactions-with-loss-based-congestion-control ）— 经典解析模型：BBRv1 的 in-flight 上限使其在浅缓冲对 CUBIC 过激、深缓冲被 CUBIC 的丢包退避反噬。
- **Cao et al.**, "When to use and when not to use BBR", IMC 2019, DOI 10.1145/3355369.3355579. https://netsys.cs.stonybrook.edu/sites/netsys.cs.stonybrook.edu/files/2024-06/p130-Cao.pdf — 640 组实验决策树：buffer ≪ BDP 时 BBR 全面占优，深缓冲与 CUBIC 互踩。
- **Zeynali et al., PAM'24**（同上）— **BBRv3 对 CUBIC 的不公平与 BBRv1 几乎相同**且浅缓冲更糟；staggered 启动时 16×BDP 缓冲下新流要 **>4 分钟**才拿回应得份额；5 流 deep-buffer 全共陈时 BBRv3 是所有 CCA 里最差；BBRv3 vs CUBIC 重传率回到 v1 量级。
- **Yang, Wu, Li, Liu, Pau, Xie**, "BBRv2+: Towards balancing aggressiveness and fairness with delay-based bandwidth probing", Computer Networks 206:108789, 2022, DOI 10.1016/j.comnet.2021.108789 — 用路径时延信息调节带宽探测激进度，在激进与公平间取平衡（PAM'24 与 oBBR 均引用其分析模型）。
- **LBNL**, "BBRv3 Startup Behavior: Analysis and Fairness Enhancements", ICNC 2026. https://sdm.lbl.gov/oapapers/icnc26-bbrv3.pdf — FABRIC 实测（RTT 35/56/145ms，1-25Gbps，1-4×BDP）：**startup 先发优势贯穿连接全生命周期**；BBRv3e1（startup 更激进）在与 CUBIC 竞争、长 RTT 场景 Jain +15%、util>95%。

**对 bbrplusv3 适配性**：**需改造，分场景**。我们的痛点恰是文献最痛的象限：跨洋 150ms（深缓冲大 BDP）+ 0.5% loss。①深缓冲：Zeynali 证明 v3 参数改动反而更差 → bbrplusv3 的 smart exit（双条件 RND-limited 退出）正对 "v3 继续探测直至饱和" 语义，方向正确；②与 CUBIC 共存：oBBR 的自适应 g（见 §3）是唯一有公网 A/B 数字的可抄方案；③fq 已部署满足 PAM'24 "FQ-CoDel/AQM 改善深缓冲" 旁证；④注意 LBNL 结论与直觉相反：**更长 RTT 下 startup 更激进反而改善公平**——bbrplusv3 startup 2.25/2.685 高于 v3 官方 2.77 pacing/2.0 cwnd 中的 pacing 但 cwnd_gain 2.25>2.0 同向，与 e1 方向一致，可作为 e1 的已部署版本看待。

## 3. 丢包后回填节奏慢（种子 3）

**核心文献（唯一有完整机制+公网数字）**
- **Bi, Xiao, Yu, Zhang, Tong, Liu, Li**, "oBBR: Optimize Retransmissions of BBR Flows on the Internet", USENIX ATC 2023. https://www.usenix.org/system/files/atc23-bi.pdf （代码 https://github.com/bpq233/oBBR ）
  - 方法一句话：①丢包时按 RTT_latest/RTprop 估计瓶颈缓冲深度，把 cwnd_gain g 自适应压到 `min(1+μ·(RTT_latest-RTprop)/RTprop, g_max)`；此后 **per-ACK 线性回填 `g += α·S_ack/BDP`（α=0.01）**直到 g_max；②带宽跌落检测：连续 k=30 个样本 <0.75×BtlBw 或 RTT >(g_max+0.5)×RTprop → 立即用 k 样本均值刷新 BtlBw；③带宽更新后比较前后投递分（U=delivered−10×unacked），变差即回退。
  - 实测增益及条件：恒定链路 2% 随机丢包下 goodput **14.65×于 BBRv2**（BBRv2/CUBIC 在 1-2% 丢包下 goodput 掉 76-96%，BBR 无感但重传 17.4%）；公网长链路 1GB 传输：goodput **1.54×于 BBRv2**，重传 ~6.5% vs 6.71%；带宽 20→5/2Mbps 骤降时收敛从 7-15s（10 RTT 窗口过期）降到即时。
  - 实现载体是 nginx-quic 用户态 QUIC，但全部逻辑只用 delivered/RTT/丢包计数，内核可移植。
- **[配套]** Mahmud, Kim, Lubna, Cho, "BBR-ACD: BBR with Advanced Congestion Detection", Electronics 9(1):136, 2020, DOI 10.3390/electronics9010136 — 对重传做选择性响应（区分拥塞/非拥塞丢包）改善公平与重传。
- **[规范基线]** draft-ietf-ccwg-bbr-05：excess loss → inflight_hi=当前 cwnd，此后靠 ProbeBW 上探逐步抬高 inflight_hi——这就是"回填慢"的规范根源：恢复速度绑定在 2-3s 随机间隔的 up-phase 上。
- **[独立旁证]** PAM'24：BBRv2/v3 因 loss response 在浅缓冲重传最低但深缓冲吞吐回吐给 CUBIC；KIT'25：BBRv3 收敛慢自 v2 延续。

**对 bbrplusv3 适配性**：**可直接抄（首选移植对象）**。oBBR 的三件套与 bbrplusv3 已有的 rto-cut/smart exit 正交互补：smart exit 管 startup/probe 退出，oBBR 管 loss 后 inflight_hi 回填速度。落点：把 inflight_hi 恢复从"等 ProbeBW up-phase"改为 per-ACK 线性爬升 + 检测/回退门控；α=0.01、k=30 可作初值再按 150ms/0.5% 调。1-CPU 上开销 = 每 ACK 几次乘加，可忽略。

## 4. min_rtt 滤波器陈旧（种子 4）

**证据与方案**
- **[规范]** draft-ietf-ccwg-bbr-05：min_rtt = 最近 **MinRTTFilterLen=10s** 窗口最小值，ProbeRTT ≤5s 强制刷新——v2/v3 已把陈旧上限从 v1 的 10s 不刷新压到 5s。
- **[陈旧实测]** Mazilu, Valentine, Parisis, "Evaluating Learning Congestion control Schemes for LEO Constellations", arXiv:2510.25498, 2025-10. https://arxiv.org/abs/2510.25498 — LeoEM 仿真：**BBRv3 在 RTT 突变（星间切换）时反应迟缓**，公平性随 RTT 不对称显著退化；AQM 可恢复。这是"min_rtt/路径模型中毒"最直接的独立实证。
- **[抖动耦合]** KIT'25（同上）：BBRv3 对时延抖动不高度敏感，但抖动恶化排队时延与公平（不到饿死程度）。
- **[无线域]** "TCP BBR-n: Increased throughput for wireless-AC networks", PMC10712868, 2023 — 802.11ac 聚合 ACK 导致 max_bw/min_rtt 模型失真，BBR-n 改模型提吞吐；另见 arXiv:2509.06245（AQM WiFi 下 BBRv3）、arXiv:2512.18259（WiFi6 AQM）。
- **[公网形态]** Cao IMC'19（同上）：真实路径上 BBR 的 min_rtt/btlbw 估计质量直接决定其相对 CUBIC 的胜负。

**对 bbrplusv3 适配性**：**基本不适用（低优先级）**。固定 VPS→客户端跨洋路径无 LEO 式切换；min_rtt 中毒窗口是"ISP 入口路径切换/无线末端抖动"，靠 10s 窗+5s probe 已覆盖。注意区分：我们内部实测的 rcv_space 钉死是**接收侧自调**问题（种子 6），不是发送侧 min_rtt 滤波器——文献两侧机制不同，勿混修。

## 5. 短流 startup 慢（种子 5）

**证据与方案**
- **LBNL ICNC'26**（同上，https://sdm.lbl.gov/oapapers/icnc26-bbrv3.pdf ）— 三个 startup 改造变体：e1=更激进、e2=降低 loss 响应、e3=组合；e1 在 **145ms RTT**（与我们的 150ms 几乎相同）+ ≤2×BDP 缓冲下最优：Jain +15%、util>95%；局限：4×BDP 深缓冲优势消失，高随机丢包路径可能放大突发（作者自列未验证）。
- **Bless, Lihotzki, Zitterbart, IFIP Networking 2025**（同上）— 真实 trace 短流并发实验：**BBRv3 仅"略微但一致地"好于 CUBIC**——即短流不是 BBRv3 的显著短板，也别指望大改 startup 对短流有质变。
- **Zeynali PAM'24** — 真实 MAWI 流长分布下 BBRv2 短流 FCT slowdown 反而优于 BBRv3（BBRv3 长流优先）。
- **[旁支算法]** Xu, Claypool et al., **HyStart++**, RFC 9406, 2023. https://www.rfc-editor.org/rfc/rfc9406.txt ；"Validation and Evaluation of HyStart++ for Linux", NetDev 0x1A, 2023. http://web.cs.wpi.edu/~claypool/pubs/Congestion.html — CUBIC 侧短流慢启动改善的成熟方案（round-trip 粒度减速退出），思路可迁移：用 RTT 增量梯度提前温和退出而非等 plateau。
- **Liu et al., "BBR-PP: Accelerating Slow Start for Congestion Control in LEO Satellite Networks", ACM, 2026-07, DOI 10.1145/3821162.3821172** — LEO 网络端到端慢启动加速（正文 403 付费墙，机制细节 UNVERIFIED，只有标题/venue/年份可核实）。
- **[规范侧]** draft-huitema-ccwg-bbr-realtime-00（IETF）— 实时流 BBR startup 增益调整（pacing 2.77/cwnd 2 基线描述），是参数调优的规范参照。

**对 bbrplusv3 适配性**：**已基本对齐，小幅校准即可**。bbrplusv3 的增强 startup（cwnd 2.25/pacing 2.685）≈ LBNL e1 的方向且参数相当；smart exit 双条件退出正对应 ICNC'26 指出的 v3 "过早/过晚退出" 问题。可补：①startup 内嵌 HyStart++ 式 RTT-inflation 早期减速，保护 150ms 高 RTT 下一次 up-swing 打出的 2×BDP 队列；②20260-2026 文献一致警告：startup 激进↑ 对"几个 RTT 内完成的短流"无益（它们死于第一次 RTO 而非 startup 形状）——我们已有的 rto-cut 对短流更关键，优先级高于 startup 再调。

## 6. 接收窗 DRS / rcv_space 地板（种子 6）

**核心文献（一手内核源）**
- **Eric Dumazet, "[PATCH net-next 00/11] tcp: receive side improvements", 2025-05-13**, LWN 汇编 https://lwn.net/Articles/1021321 （patch 系列原文 https://lwn.net/ml/all/20250513193919.1089692-1-edumazet@google.com/ ）— Google 自述：tcp_rmem[2]=15MB 用了 8 年，**TCP rx 自调倾向高估 RTT → rcvq_space.space/sk_rcvbuf 过冲**；修复：①tcp_rcv_rtt_update 恒取最小 RTT；②接收队列非空时跳过大 RTT 采样；③tcp_rcv_space_adjust 感知接收队列积压；④sk_rcvbuf 过冲修正；⑤乱序下的 rcvbuf 调整；⑥tcp_rmem[2] 提至 32MB。200G 网卡单流 73.6→**122.5** Gbit/s。
- **[规范]** kernel docs ip-sysctl：tcp_moderate_rcvbuf=1 时接收缓冲自动调至路径所需、上限 tcp_rmem[2]。https://www.kernel.org/doc/html/v5.10/networking/ip-sysctl.html
- **[经典]** Weigle & Feng, "A Comparison of TCP Automatic Tuning Techniques for Distributed Computing", HPDC 2002. https://www.lanl.gov/radiant/pubs/hptcp/hpdc02-drs.pdf ；Semke et al., "Automatic TCP Buffer Tuning", SIGMETRICS 1998, DOI 10.1145/277630.277648 — DRS 类机制的历史定位（记忆/带宽换型）。

**对 bbrplusv3 适配性**：**环境侧修复，非模块代码**。我们内部钉死的 rcv_space=65495 地板（亚稳态输家流）与 Dumazet 修复的"RTT 高估→自调卡死"同族；SO_RCVBUF 显式钉（862340ff）是正确兜底。根治路径 = 代理 VPS 内核回移该 11 补丁系列（7.2 系列内核如有 backport 直接吃）；另注意 1-CPU 上 fq+大 rmem 的内存/CPU 代价，32MB 上限对单流代理偏大，保持自有 sockopt 策略更稳。学术侧无 2022-2026 专门分析 Linux DRS 的论文（检索过 hpdc02/sigmetrics98 之外的近作未命中），此结论标注为**检索缺口**。

## 7. RTT 方差/抖动敏感（种子 7）

**证据与方案**
- **Abrol, Murali Mohan, Truong-Huu**, "FaiRTT: An Empirical Approach for Enhanced RTT Fairness and Bottleneck Throughput in BBR", arXiv:2403.19973, 2024; IEEE（Xplore 10615947）. https://arxiv.org/abs/2403.19973 — 方法：每 ACK 按实测 RTT 重算 inflight 对 BDP/bottleneck bw/发包时刻的依赖，动态定 BDP 速率；NS-3 实测：elephant/mice 吞吐比 1.08、Jain 0.98、利用率 98.78%，显著优于 BBRv2。
- **[排队模型]** Tao, Jiang, Ma, Wang, Wang, Li, "Unraveling the RTT-fairness problem for BBR: A queueing model", GLOBECOM 2018, DOI 10.1145/3355369…（IEEE 10.1109/GLOCOM.2018.8647256 [DOI UNVERIFIED]）— BBR 长 RTT 偏置的解析解释。
- **[实测确认]** Zeynali PAM'24：10ms vs 160ms 流，BBR 全系偏袒长 RTT 流，RTT 差越大越不公平，v3 没改；KIT'25：抖动伤排队时延与公平但不至饿死。
- **[变体群]** Pan et al., Electronics 10(5):615, 2021（自适应 cwnd RTT 公平）; Njogu et al., "BBR-EFRA", Computer Communications 200:95-103, 2023; "Improved BBR for RTT fairness by Gamma Correction", Sensors 2021, PMC8234792; Abrol FaiRTT 为其中实测数字最全者。
- **[反例/边界]** De Silva, Pokhrel, Kua, "Unveiling TCP BBR Dominance in Starlink Internet", arXiv:2607.07133, 2026-07 — 六城五洲 Starlink 实测：BBRv3 在高时延强变化卫星网对 8 个 CCA（含 Copa/PCC/LeoCC）取得公平-丢包-时延最佳折中；ANRW'25 "TCP Congestion Control Performance over Starlink"（DOI 10.1145/3744200.3744760）14 种 CC 变体同场。

**对 bbrplusv3 适配性**：**需改造但低优先**。我们场景是"长 RTT 流"，文献一致表明 BBR 类在混合 RTT 竞争中偏袒我们——优化 RTT 公平是为共存让利，仅在多流共享出口瓶颈时才有意义；单 VPS 代理多为每连接独立流。若上多流 mux（连接池方向），FaiRTT 的 per-ACK BDP 重算是可抄的最小改动。抖动侧维持现状即可（KIT'25 + Starlink'26 双实证 BBRv3 抗性尚可）。

---

## 8. BBR-nF：UNVERIFIED（种子 3 附带检索义务）

契约提示的 **"BBR-nF (PAMD'26 smart exit)"** 经四路检索**未能证实存在**：
1. web_search 多种措辞（"BBR-nF"、BBR network feedback satellite 2025、PAMD 2026 program BBR）无学术命中（唯一 "BBR-NF" 命中为日产皮卡前杠商品页）；
2. GitHub `hantengyue/PAMD` 为推荐系统代码库，与拥塞控制无关；
3. PAM 2026 正式论文集（Springer LNCS 16477, https://link.springer.com/book/10.1007/978-3-032-18268-5 ）全目录 18 篇逐条核对，无 BBR-nF 或同名 smart exit 论文（"Applications and Congestion" 组仅视频会议 CC 微观观测与 L4S 住宅宽带实测两篇）；
4. Semantic Scholar API 检索通道不可用（URL 格式限制）。
**判断**：该种子疑似内部名称或记忆混淆（可用候选混淆源：BBR-n [wireless, 2023]、BBR-ACD [2020]、oBBR [ATC'23]）。功能诉求（丢包后恢复/smart exit）已被 oBBR + BBR-ACD + draft-05 覆盖，不影响报告完整性。

## 9. 交叉观察（写给方案设计者）

1. **三篇 2024-2026 独立评估收敛于同一病灶清单**（PAM'24、IFIP Networking'25×2、ICNC'26）：v3 的不公平/慢收敛/自诱导排队是结构性（探测增益+模型窗口），参数微调难根除；bbrplusv3 的差异化路线（smart exit + 更激进 startup + rto-cut）在文献上恰好避开了"参数内卷"区间。
2. **唯一跨场景通吃的公网验证方案是 oBBR**（其余多为 ns-3/FABRIC/emulation）；其三件套全部落在 bbrplusv3 缺口上，是第一移植优先级。
3. **接收侧（DRS）与发送侧（BBR）文献几乎零交叉**——我们内部把 xhttp 饿死定位到客户端接入侧每流 TCP 是对的：学术社区同样把两端当独立问题研究。
4. 环境警戒：**2BRobust**（arXiv:2601.05665, 2026-01）实测 VM CPU 竞争下 BBR pacing 精度崩坏——1-CPU VPS 是该风险象限，pacing 溢出/高精度定时器路径的 CPU 成本要纳入 bbrplusv3 每项改造的预算。

## 10. 来源清单（tier 标注）

| Tier | 文献 | URL |
|---|---|---|
| T1 | draft-ietf-ccwg-bbr-05 (IETF, 2026-03, Experimental) | https://www.ietf.org/archive/id/draft-ietf-ccwg-bbr-05.html |
| T1 | HyStart++, RFC 9406 (2023) | https://www.rfc-editor.org/rfc/rfc9406.txt |
| T1 | BBR 原始论文, ACM Queue 2016 | https://queue.acm.org/doi/10.1145/3012426.3022184 |
| T1 | Dumazet rx improvements, LWN 2025-05 | https://lwn.net/Articles/1021321/ |
| T1 | kernel ip-sysctl docs | https://www.kernel.org/doc/html/v5.10/networking/ip-sysctl.html |
| T2 | Zeynali et al., Promises and Potential of BBRv3, PAM 2024 | https://research.vu.nl/ws/portalfiles/portal/367913888/Promises_and_Potential_of_BBRv3.pdf |
| T2 | Bless et al., Insights into BBRv3, IFIP Networking 2025 | https://publikationen.bibliothek.kit.edu/1000182022 |
| T2 | Sarpkaya et al., BBR's Sharing Behavior, IFIP Networking 2025 / arXiv | https://arxiv.org/abs/2505.07741 |
| T2 | Bi et al., oBBR, USENIX ATC 2023 | https://www.usenix.org/system/files/atc23-bi.pdf |
| T2 | Ware et al., Modeling BBR Interactions, IMC 2019 | https://dl.acm.org/doi/10.1145/3355369.3355604 |
| T2 | Cao et al., When to use BBR, IMC 2019 | https://netsys.cs.stonybrook.edu/sites/netsys.cs.stonybrook.edu/files/2024-06/p130-Cao.pdf |
| T2 | LBNL, BBRv3 Startup Behavior, ICNC 2026 | https://sdm.lbl.gov/oapapers/icnc26-bbrv3.pdf |
| T2 | Yang et al., BBRv2+, Computer Networks 2022 | 10.1016/j.comnet.2021.108789 |
| T2 | Mazilu et al., LEO CC evaluation, arXiv 2025 | https://arxiv.org/abs/2510.25498 |
| T2 | Abrol et al., FaiRTT, arXiv/IEEE 2024 | https://arxiv.org/abs/2403.19973 |
| T2 | Mahmud et al., BBR-ACD, Electronics 2020 | 10.3390/electronics9010136 |
| T2 | De Silva et al., BBRv3 on Starlink, arXiv 2026 | https://arxiv.org/abs/2607.07133 |
| T3 | BBR-R (multi-flow), Computer Networks 2024 | https://www.sciencedirect.com/science/article/abs/pii/S1389128624006480 |
| T3 | BBR-R (RTT fairness), AINA 2024 | https://link.springer.com/chapter/10.1007/978-3-031-57840-3_7 |
| T3 | BBR-PP, ACM 2026 | https://dl.acm.org/doi/10.1145/3821162.3821172 |
| T3 | 2BRobust, arXiv 2026 | https://arxiv.org/html/2601.05665v2 |
| T3 | BBR Fairness NS-3, arXiv 2024 | https://arxiv.org/abs/2410.22560 |
| T3 | BBRv3 AQM WiFi, arXiv 2025 | https://arxiv.org/abs/2509.06245 |
| T3 | HyStart++ for Linux, NetDev 0x1A 2023 | http://web.cs.wpi.edu/~claypool/pubs/Congestion.html |

*标注 UNVERIFIED 的项：BBR-nF（§8）、BBR-R/B脚注 DOI、Tao GLOBECOM DOI、BBR-PP 正文细节、BBR-SJ 细节——均为付费墙或检索无果，其余数字均出自上表一手文本。*
