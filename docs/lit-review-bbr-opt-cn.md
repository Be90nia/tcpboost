# 国内 BBR/BBRplus 优化方案调研 (国内路, 2026-10-18)

**结论 (先行): 国内对 BBR 缺点的优化研究集中在两条线——pacing gain 模型化 (解 RTT 公平性, 中科院合肥/哈工大系 + 沈阳航空航天大学, NS3 为主) 和丢包/带宽突变的鲁棒性 (白山云+山东大学 oBBR 是唯一顶会+开源+真实 Internet 实测的一手工作)。对 bbrplusv3 的部署形态 (1-CPU VPS 代理, 跨洋 150ms RTT, loss 0.5%, fq) 最值得抄的是 oBBR 的"丢包触发自适应 in-flight cap + k 连续样本带宽跌检测 + 可逆回滚" (正对内部 W1 丢包后回填慢) 和哈工大 2019 的"RTT 均值+标准差判抖动、γ=0.3 阈值下用平滑均值替代 min_rtt 算 BDP" (正对种子 4/7, 约 30 行内核改动); 接收窗 DRS/rcv_space 地板 (W4)、参数交互审计 (W3)、pacing 单核开销基准 (W5) 在国内文献中均为空白, 无现成方案可抄。**

时间窗 2022-2026 优先, BBRplus 谱系与 2019 奠基工作作为血统收录。所有增益数字均摘自一手来源原文; 标注 UNVERIFIED 的是未能核实全文/作者的内容。

---

## 一、七个缺点 × 国内最优方案 (一行速查)

| # | 缺点种子 | 国内最优方案 (一句话) | 一手来源 |
|---|---|---|---|
| 1 | Probe_RTT 停顿/吞吐抖动 | oBBR: 丢包时按 `RTT_latest/RTprop` 比值缩 in-flight cap 并可逆恢复, ProbeRTT 让带宽的代价用 adaptive-g 补偿; 配合 dog250 的周期随机化消全局同步 | [oBBR, USENIX ATC'23](https://www.usenix.org/conference/atc23/presentation/bi) |
| 2 | 与 cubic 共存公平性 | BBR-Compatible: 主动发现队列堆积 + 及时更新 RTprop + 检测丢包重传时调整发送行为, 浅缓冲区 Jain 指数均值 +1.5~1.58× | [BBR-C, 计算机应用与软件 2026](https://www.shcas.net/cn/article/pdf/preview/10.3969/j.issn.1000-386x.2026.02.020.pdf) |
| 3 | 丢包后恢复节奏 | oBBR: k=30 连续带宽样本 <0.75×BtlBw 或连续 RTT >(g_max+0.5)×RTprop 判带宽跌, 即时下修带宽估计, 更新后用投递分 (delivered−10×unacked) 回退防误判 | [oBBR](https://www.usenix.org/system/files/atc23-bi.pdf) |
| 4 | min_rtt 估计陈旧 (无线/抖动) | 哈工大 2019: EWMA 维护 RTT 均值与标准差, `T_dev > 0.3×T_smo` 判剧烈抖动, 用 T_smo 替代 T_min 计算拥塞窗口 | [董瀚泽/郭志川, 哈工大学报 2019](https://hit.alljournals.cn/html/hitxb_cn/2019/11/20191102.html) |
| 5 | 短流 startup | 深大 BBR-Copilot: 智能构造并发送额外数据主动制造准确带宽样本, 解 startup 难退出→自伤丢包 + 稳态发送低于可用带宽; (厂商方向参照: 腾讯 TCPA 小文件场景宣称 +40%) | [BBR-Copilot, arXiv 2026](https://arxiv.org/abs/2606.03468) |
| 6 | 接收窗 DRS/rcv_space 地板 | **国内空白** — 查无专门一手文献; 邻近证据仅 BBRplus 社区 `EXPORT_SYMBOL(tcp_snd_wnd_test)` 补丁 (绕过标准发送窗检查) 与阿里云老内核 BBR 高 CPU 公告; 详细对照见第四节 | 见 [UNVERIFIED/空白](#五国内空白与-unverified) |
| 7 | RTT 方差敏感 | 同 #4 (哈工大 γ=0.3 判抖动), 加 BBRv2+ (清华/中科院网络中心) 的抖动韧性与随机丢包机制 (高机动场景 +25% 吞吐) | [BBRv2+, arXiv 2021](https://arxiv.org/abs/2107.03057) |

---

## 二、分缺点详录 (每条: 题目/来源/年份/URL、针对缺点、方法、实测增益及条件、适配性)

### S1+S3. oBBR: Optimize Retransmissions of BBR Flows on the Internet
- **来源**: 毕鹏强 (Pengqiang Bi)、肖萌白 (Mengbai Xiao)、于东晓、张光慧 — 山东大学; 佟健、刘静超、李毅军 — 白山云 (BaishanCloud, CDN 厂商)。USENIX ATC 2023。
- **URL**: https://www.usenix.org/conference/atc23/presentation/bi ; PDF: https://www.usenix.org/system/files/atc23-bi.pdf ; 开源 (QUIC/nginx-quic 实现): https://github.com/bpq233/oBBR
- **针对缺点**: 1 (ProbeRTT 让带宽/自伤丢包)、3 (丢包后恢复/带宽跌钝感)、2 (浅缓冲区对 cubic 侵略性, 定量模型 `Q_R(p; g, R)` 证明 g=2 固定值在 R<1 BDP 浅缓冲必丢包、g=1 深缓冲必输)。
- **方法**: ① 丢包事件→用 `RTT_latest/RTprop` 判浅缓冲, 按比例缩 cwnd_gain g (下限 1.25 配合 1.25×pacing_gain), 每个 ACK 按 `g+α·S_ack/BDP` 缓慢恢复到 g_max=2; ② 带宽跌检测双通道: k=30 连续带宽样本 <0.75×BtlBw, 或连续 RTT 样本 >(g_max+0.5)×RTprop, 命中即用最近 k 个样本均值更新 BtlBw; ③ 可逆保险: 更新前后各 2T 窗口计算投递分 `U = delivered − 10×unacked` (T=200ms), 分数下降即回滚带宽估计。
- **实测增益及条件**: 实验室 2% 随机丢包下 goodput 为 BBRv2 的 14.65× (BBRv2 goodput −94%; 条件 40Mbps/100ms, R=0.25); 稳定网络丢包率较 BBR 最多降 30×; 带宽 40→10Mbps 波动场景重传 −52%; 真实 Internet 长链路: goodput 1.54× 于 BBRv2 且重传 ~6.5% vs 6.71%; 流媒体 QoE (画质/切换/卡顿) 全面优于 BBRv2/BBR-S, 重传 ~4%。实现为 QUIC 用户态, 开销 O(1)/ACK。
- **适配性**: **需改造 (价值最高的国内一手方案)**。逻辑与 QUIC 无耦合, 三块 (adaptive g / k 连续样本检测 / 投递分回滚) 可直接移植进内核 tcp_bbr 模块; 正对我们 W1 (丢包后 re-probe 保守) 与 BBRv3 loss 阈值 2% 对 0.5% loss 不反应的窗口; 注意与现有 smartexit/inflight_hi 的参数交互 (W3 风险), 建议作为独立可开关特性走 30m 探针验证。

### S2. BBR-Compatible (BBR-C): 浅缓冲区网络中 BBR 与 CUBIC 的传输公平性研究
- **来源**: 杨华、周谦杰、吴杰宏 — 沈阳航空航天大学计算机学院。《计算机应用与软件》2026 年 2 月, 43(2)。收稿 2022-12。
- **URL**: DOI 10.3969/j.issn.1000-386x.2026.02.020 ; PDF: https://www.shcas.net/cn/article/pdf/preview/10.3969/j.issn.1000-386x.2026.02.020.pdf
- **针对缺点**: 2 (BBR 与 CUBIC 浅缓冲共存时 BBR 抢占带宽)。
- **方法**: 主动发现队列堆积、及时更新 RTprop、检测到丢包重传时调整发送行为以降低侵略性。
- **实测增益及条件**: NS3 仿真, 与 CUBIC 浅缓冲区共存时 Jain 公平指数均值提升 1.5~1.58×, 且 BBR-C 自身传输质量不降。
- **适配性**: **需改造**。NS3 → 内核; "及时更新 RTprop"分支与我们场景相关 (cubic 竞争致 RTprop 估计污染), 但浅缓冲假设与跨洋 fq 链路匹配度中等; 若 W1/W2 (对 cubic median 落后) 需要进一步归因, 其队列堆积检测思路可参考。

### S2/S7. BBR-A (哈工大学报 2022): BBR 拥塞控制算法的 RTT 公平性优化
- **来源**: 潘婉苏、李晓风、谭海波、许金林、李皙茹 — 中科院合肥物质科学研究院 + 中国科学技术大学。哈尔滨工业大学学报 2022, 54(11): 38-46。国家重点研发计划资助。
- **URL**: DOI 10.11918/202109034 ; https://hit.alljournals.cn/html/hitxb_cn/2022/11/20221105.html
- **针对缺点**: 2 (RTT 公平性/流间公平)、重传率; 间接 7。
- **方法**: 用 RTT 与起搏增益的关系构造反比例函数起搏增益调节模型, 替换固定 1.25/0.75, 上下增益交错平衡不同 RTT 流的发送速率; 并加入丢包反馈建立对称增益模型。
- **实测增益及条件**: NS3; 不同缓冲/RTT 差异下 Jain 公平指数较 BBR 至少提高 1.5 倍 (RTT 比 10:1 时维持 ~0.95 vs BBR 0.59); 100 流、0.1BDP 缓冲时重传率 4.24% vs BBR 14.9%; 信道利用率不降。
- **适配性**: **需改造、优先级中低**。目标是同瓶颈不同 RTT 流的公平; 我们 8 并发同路径竞速场景 RTT 相近, 收益边际; 且改 pacing gain 会与 smartexit/mlfq pacing 强交互 (W3)。其价值主要在方法论 (起搏增益可用负反馈函数模型化)。

### S2/S7 扩展. Sensors 2023: Optimization of BBR Congestion Control Algorithm Based on Pacing Gain Model (BBR-A/B/C)
- **来源**: 杨爽、唐玉泉、潘婉苏、王华东、荣丹丹、张志荣 — 安徽省先进激光技术实验室/合肥 (与上条同组, 英文扩展版)。Sensors 2023, 23(9):4431。
- **URL**: DOI 10.3390/s23094431 ; https://pmc.ncbi.nlm.nih.gov/articles/PMC10181671/
- **针对缺点**: 2、7; 附带梳理 BBR-Yinker (Wi-Fi/5G 自适应 pacing_gain, 未核实原文, UNVERIFIED lead) 与 BBR-CWS (丢包反馈缩窗) 等支线。
- **方法**: 三组 P_up/P_down 负反馈函数 (反比例+cos / 对称反比例 / gamma 校正), 按当前 RTT 占连接最大 RTT 的比例 ω 自适应调节 ProbeBW 增益。
- **实测增益及条件**: NS3 + 合肥/北京/香港/新加坡真实 WAN; 50ms 流对 10ms 流的吞吐压制从 BBR 的 4.7× 显著收敛; gamma 校正版 (BBR-C) 稳定性最好。
- **适配性**: **需改造、参考价值**。同 BBR-A 的适用性判断; gamma 校正函数形态 (P_up∈[1,1.5], P_down∈[0.5,1], 各为 ω 的幂函数) 可作为我们 pacing 增益参数化的候选曲线。

### S3/S4/S7. BBRv2+: Towards Balancing Aggressiveness and Fairness with Delay-based Bandwidth Probing
- **来源**: 杨芙蓉、吴清华、李振宇、刘燕美、Giovanni Pau、谢高岗 — 清华大学/中科院计算机网络信息中心系。arXiv 2021-07 (2021 年, 略早于 2022 窗口, 作为 v2 代国内代表作收录)。
- **URL**: https://arxiv.org/abs/2107.03057
- **针对缺点**: 3 (随机丢包韧性)、4/7 (网络抖动)、2 (对 cubic 公平不牺牲)。
- **方法**: 在 BBRv2 路径模型中引入时延信息, 谨慎引导带宽探测的激进程度 (不牺牲对 loss-based 的公平), 并集成随机丢包与抖动恢复机制。
- **实测增益及条件**: 高机动 (high-mobility) 场景较 BBRv2 吞吐 +25%, 排队时延相当; 修复 BBRv2 对带宽动态响应慢、随机丢包韧性差两大代价。
- **适配性**: **需改造**。基于 BBRv2 alpha; "用时延信号引导 ProbeBW 激进度"的思想可嫁接到 v3 的 probe_bw_up 决策; 高机动场景结论对应无线末端客户端, 对我们 VPS 侧为次要场景。

### S4/S7. 哈工大 2019: BBR 拥塞控制算法在无线网络中的性能改进 ⭐ (种子 4 的国内最优)
- **来源**: 董瀚泽、郭志川 — 中科院声学所国家网络新媒体工程技术研究中心。哈尔滨工业大学学报 2019, 51(11): 63-67。
- **URL**: DOI 10.11918/j.issn.0367-6234.201901020 ; https://hit.alljournals.cn/html/hitxb_cn/2019/11/20191102.html
- **针对缺点**: 4 (min_rtt 陈旧/抖动下 BDP 算小)、7 (RTT 方差敏感)、带宽下降钝感 (与 3 交叉)。
- **方法**: EWMA 维护 T_smo (α=0.125) 与 T_dev (β=0.25); `T_dev > 0.3×T_smo` (γ=0.3, 源自有线网 RTT 标准差/均值 ≤0.3 的实测统计) 判剧烈抖动, 此时用 T_smo 替代 T_min 进 BDP/拥塞窗口计算; 网络不稳时把 ProbeBW 平稳段 (gain=1) 从 8 拍缩到 5 拍加速带宽跌感知。
- **实测增益及条件**: 真实网络 + QUIC 实现; 3Mbps 链路、时延 N(60ms, σ=40ms) 下原版 BBR 速率跌到 0.5Mbps, 改进版稳定 ~2.55Mbps 且基本不受抖动加重影响; 带宽跌收敛时间减半。
- **适配性**: **需改造 (小改动高确定性, 建议进候选池)**。约 30 行内核态改动 (两个 EWMA + 一个阈值分支 + 周期数组切换); 我们跨洋主干 RTT 方差小, 但客户端无线末端造成的 ACK 路径抖动会进 RTT 样本, 与内部实测"抖动鲁棒优点"互补; 风险: 新增 α/β/γ 三个参数, 需并入 W3 的交互扫描; γ 取 0.3 时在网络好时会偏激进, 作者已注明。

### S5. BBR-Copilot: When BBR Meets Live Streaming
- **来源**: Xu Yan, 李彤 (Tong Li), Bo Wu, Cheng Luo, 朱九翔, 崔来中 — 深圳大学系 (摘要点名 Amazon/Tencent/ByteDance/Huawei 已在直播场景用 BBR, 含 TikTok Live)。arXiv 2026-06。
- **URL**: https://arxiv.org/abs/2606.03468
- **针对缺点**: 5 (startup 难退出→自伤丢包) + 稳态发送率低于可用带宽 (与 1 交叉)。
- **方法**: BBR 旁挂辅助拥塞控制组件, 通过"智能构造并发送额外数据"主动制造准确的带宽测量样本, 喂给 BBR 的模型。
- **实测增益及条件**: QUIC 原型 + testbed; 直播场景有效提升 BBR 性能 (论文未给出跨场景统一倍数, 属场景化增益)。
- **适配性**: **不直接适用**。需要应用层/传输层旁路构造探测流, 1-CPU VPS 代理场景基础设施成本高; 且我们的 smart exit 已覆盖"startup 难退出"主症状。留存价值: "输家流被动等样本不如主动造样本"的思想对饿死流重建带宽估计有启发。

### S5 (方向参照). 腾讯 TCPA (厂商实践, 2019)
- **来源**: 腾讯 TEG 操作系统组, 基于 RHEL 7.4 定制内核, 2019-03 开放。
- **URL**: 发布背景: https://www.eaglemoe.com/archives/103 ; 社区评测: https://blog.zeruns.com/archives/13.html (对比报告为腾讯宣称/社区转述, 未独立复核)
- **针对缺点**: 5 (短流/小文件 startup)。
- **方法**: 单边内核加速, 激进的 small-flow 处理; 绑定 80/443/8080 端口白名单。
- **实测增益及条件**: 厂商宣称小文件较 BBR +40% 以上、大文件 +5~10%; 仅 CentOS7/RHEL7.4 内核, 2019 后停止更新。
- **适配性**: **不适用 (方向参考)**。无 BBR 血统 (混合/锐速系), 停更, 平台过老; 但"小文件场景单独调 startup + 端口白名单"的部署分层思路对我们 mlfq pacing 的场景化配置有参照意义。

### S1/S3 (血统). dog250 BBR 修正分析 (BBRplus 起点, 2018)
- **来源**: dog250 (国内 BBR 社区核心分析者), CSDN 2018-06。
- **URL**: https://blog.csdn.net/dog250/article/details/80629551 (失速+收敛慢两问题与 Google patch set 解读); 失速 trick 前作: https://blog.csdn.net/dog250/article/details/80203520
- **针对缺点**: 1 (失速/全局同步)、3 (收敛慢/丢包后节奏)。
- **方法**: ① ACK 聚合失速 → Google extra_acked (windowed max) 补偿 cwnd; ② 收敛慢 → drain-to-target (drain 持续到 inflight≤BDP) + ProbeBW 周期长度随机化 (2~8 拍) 打散固定"心电图"潮汐、消除全局同步改善公平; ③ dog250 自己的等价实现 (平稳拍 2~10 随机) 与 Google patch 互证。
- **实测增益及条件**: 无系统数字 (工程博客); 后被 cx9208 编译为 BBRplus 4.14.129 广泛部署 (血统即证据)。
- **适配性**: **已继承**。drain-to-target 与周期随机化均在我们 fork 的基础上游; 无新增动作。

---

## 三、BBRplus 谱系与后继改版盘点

| 改版 | 时间 | 内容 | URL | 评估 |
|---|---|---|---|---|
| dog250 修正版 (BBRplus 原型) | 2018-06 | 失速补偿 + 收敛慢修复, 完整 tcp_bbrplus.c 随文发布 | https://blog.csdn.net/dog250/article/details/80629551 | 理念已被我们吸收 |
| cx9208/bbrplus | 2018-2019 | dog250 代码编入 4.14.129 内核; 需扩 `icsk_ca_priv` 至 112B 并 `EXPORT_SYMBOL(tcp_snd_wnd_test)`; 作者自注"实验性修改, 无人对稳定性负责" | https://github.com/cx9208/bbrplus ; 介绍帖 https://www.hostloc.com/thread-507165-1-1.html | 我们的直接血统 |
| UJX6N/bbrplus-5.10 / 6.6 | 2024-02 | 4.14 BBRplus 平移到 5.10/6.6 LTS; **合并 2018-2023 官方 tcp_bbr 补丁**; 保留原版 bbr 模块可切换; 明确"fq 是唯一推荐 qdisc, 勿用 fq_codel/fq_pie/cake" | https://github.com/UJX6N/bbrplus-6.6 ; https://github.com/UJX6N/bbrplus-5.10 | 与我们 fq 基线一致; 官方补丁合并清单值得 diff 对照 |
| 社区脚本生态 (chiakge/Linux-NetSpeed、Chikage0o0、byJoey/Actions-bbr-v3、EasyBBR3、twbk 管理脚本) | 2019-2025 | 一键装机/内核编译/调优预设 | https://github.com/byJoey/Actions-bbr-v3 等 | 装机量大但结论均为 speedtest 截图级, 不作证据 |
| "尤达" BBR2/BBRv3 改 | 不详 | 契约提示的社区改版 | **检索未命中可核实一手来源, UNVERIFIED** | 不收录为证据 |

---

## 四、厂商实践盘点

- **白山云 + 山东大学 oBBR (2023)**: 国内唯一"顶会 + 开源 + 真实 Internet + CDN 生产语义 (QoE)"的系统化 BBR 优化, 详见 S1+S3 详录。这是我们最应该盯的一手参照。
- **腾讯 TCPA (2019)**: 见 S5 详录; 2019 后无官方演进。检索未见名为 "TBBR" 的腾讯 BBR 改进论文 (多轮检索未命中, 若存在则 UNVERIFIED)。
- **B 站 (2025-06)**: 知乎文章《从拥塞控制算法热交换到内核错误修复》证实 B 站在产环境自研改进版 BBR 内核模块, 并用算法热交换方法做真实环境测试。原文反爬 (HTTP 403, jina 代理亦失败), 细节 UNVERIFIED。题录: https://zhuanlan.zhihu.com/p/1920535564987380863
- **阿里云 (2024)**: 官方公告 Alibaba Cloud Linux 2 老内核 BBR 存在 CPU 占用过高与网络性能下降问题并给处理方案 — 间接印证 W5 (BBR 在低配/老内核上有实打实的 CPU 代价), 但无算法级公开。https://help.aliyun.com/zh/alinux/support/how-does-the-tcp-congestion-control-algorithm-bbr-affect-network
- **字节/华为**: 无公开算法级 BBR 改进; BBR-Copilot 摘要将其与 Amazon/Tencent 并列为直播场景 BBR 采用者。

---

## 五、国内空白与 UNVERIFIED

**国内空白 (查无一手文献, 附已试查询)**:
1. **接收窗 DRS/rcv_space 地板 (种子 6 / 内部 W4)** — 试过: "dog250 BBR 接收窗口 rcv_space"、"BBR 接收窗口 rcv_space 自动调节 DRS 限制 吞吐 CSDN"、"tcp rcv_space 接收窗口 自动调优 吞吐 中文"、"dog250 TCP 接收窗口 自动调整 DRS"。中文检索结果全部漂移到 Windows autotuning 或英文规范。国内最接近的动作只有 cx9208 补丁里的 `EXPORT_SYMBOL(tcp_snd_wnd_test)` (给模块绕过标准发送窗检查的 plumbing, 并非 DRS 分析)。该缺点的有效文献在国际路 (BBR-n+ 的 RWND 智能退出, PLOS One 2026) 与我们自己的 sockopt 修复, 归口国际路报告。
2. **参数交互扫描/特性默认值策略 (内部 W3)** — 无国内文献命中。
3. **pacing 单核开销基准方法 (内部 W5)** — 无国内系统工作; 阿里云公告为唯一 ops 侧旁证。

**UNVERIFIED (题录存在但未能核实全文/作者)**:
- B 站改进 BBR 细节 (知乎 403)。
- "尤达" BBR2/BBRv3 改 (未命中一手来源)。
- BBR-PP: Accelerating Slow Start for Congestion Control in LEO Satellite Networks (ACM, 2026-07, DOI 10.1145/3821162.3821172;疑似国内 LEO 团队, ACM 403 无法核实作者与增益; LEO 场景与我们也远, 仅存目)。
- BBR-Yinker (Sensors 2023 引文 [23], Wi-Fi/5G 自适应 pacing_gain, 原文未获取)。
- 腾讯 TCPA "+40% 小文件" 数字 (厂商宣称/社区转述, 无独立复核)。

**一手来源质量说明**: 哈工大学报两篇、Sensors 2023、《计算机应用与软件》2026 为期刊全文直读 (T1/T2); oBBR 为顶会全文直读 (T1); BBRv2+/BBR-Copilot 为 arXiv 直读 (T2); dog250/CSDN、GitHub 谱系、TCPA 评测为工程博客/仓库 (T3, 结论已尽量回溯到代码与论文)。期刊类增益数字全部出自 NS3 或小规模真实网, 条件与数字一并给出, 未做外推。

---

## 六、对 bbrplusv3 的落地建议 (按内部缺点清单对齐)

| 内部缺点 | 建议动作 | 来源 |
|---|---|---|
| W1 丢包后 re-probe 保守 | 移植 oBBR 双通道带宽跌检测 (k=30 样本 / RTT 连续超限) + 投递分回滚; 与 inflight_hi 恢复策略合流, 单特性开关走 30m 探针 | oBBR (ATC'23) |
| 种子 4/7 抖动 | 哈工大 γ=0.3 RTT 均值替代 (~30 行), 参数并入 W3 扫描 | 哈工大学报 2019 |
| W2 min 流不敌 cubic 爆发 | BBR-C 队列堆积检测思路作归因参考, 不直接搬 | 计算机应用与软件 2026 |
| W4 DRS 地板 | 国内无文献; 继续沿 sockopt + 国际路 (BBR-n+) 线索 | 本报告第五节 |
| W3/W5 | 无国内方案; 阿里云公告提示 BBR CPU 代价值得一次 1-CPU 实测定基线 | 阿里云 ALinux2 公告 |
