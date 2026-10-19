# bbrplusv3 batch-6 候选优化清单 (PM 综合, 2026-10-18)

> 输入: docs/bbrplusv3-weakness-inventory.md (内部实测 W1-W5) + docs/lit-review-bbr-opt-intl.md + docs/lit-review-bbr-opt-cn.md
> 原则: 沿袭战役纪律 — 单特性批次、默认 off、30m 探针门禁、预注册判据。

## 缺点 × 方案适配矩阵

| 内部缺点 | 国际最优 | 国内最优 | PM 裁决 |
|---|---|---|---|
| **W1 丢包后回填慢** (median 落后 cubic −12%) | **oBBR** (ATC'23): per-ACK 线性回填 + k=30 带宽跌检测 + 投递分回滚; 2% loss goodput 14.65×, 公网 1.54×, 开源 | oBBR (同一工作, 山东大学+白山云) | ✅ **候选 1** |
| **W4 DRS/rcv_space 地板** (xhttp 饿死根因族) | Dumazet 2025-05 内核 11 补丁 (rx 自调 RTT 高估修复, 200G 单流 +66%) | 国内空白 | ✅ **候选 2** (内核侧) |
| 种子1 ProbeRTT 停顿 (150ms 下 ~7% 时间近零速) | v3 已有 5s/BDP÷2+随机相位; 剩余改造 = probe 期保 pacing 只压 cwnd | oBBR adaptive-g 补偿 | ✅ **候选 3** (小改) |
| 种子2 cubic 共存公平 | oBBR 自适应 g / LBNL e1 (+15% Jain @145ms) | BBR-C (沈航, NS3) | ⏸ oBBR 覆盖, 不单独立项 |
| 种子4/7 min_rtt 陈旧/RTT 方差 | 固定跨洋路径低风险; FaiRTT 我们是受偏袒方 | 哈工大 2019 (γ=0.3, ~30 行) | ❌ 存目不立项 — 7hn 已实测抖动鲁棒 (+26~73%), 且 +3 参数 = W3 税 |
| 种子5 短流 startup | LBNL e1 方向 = bbrplusv3 已对齐 (2.25/2.685+smart exit) | BBR-Copilot (旁路构造样本, 不适用) | ❌ 已对齐, 无活 |
| **W3 参数交互面** | 文献空白 | 空白 | 流程缓解 (现纪律), 无代码活 |
| **W5 单核 pacing 开销未量化** | 文献空白 (阿里云公告仅提示) | 空白 | 搭车下次 CI 采 CPU% 定基线, 零成本 |

## batch-6 候选排序 (供拍板)

### 候选 1: oBBR 三件套移植 ⭐ 推荐
- **内容**: ① 丢包时按 RTT_latest/RTprop 判缓冲深度自适应压 cwnd_gain g (下限 1.25); ② inflight_hi/带宽恢复改 per-ACK 线性爬升 (α=0.01); ③ k=30 连续样本带宽跌检测 (含 RTT >(g_max+0.5)×RTprop 通道) + 投递分 (delivered−10×unacked) 错判回滚
- **理由**: 唯一有公网 A/B 数字的方案 (ATC'23 顶会+开源 github.com/bpq233/oBBR); 正交于 smartexit/rto-cut; 直击 W1; 逻辑纯计数器 (无模型, 过 Wave-1 的计数器优先门)
- **风险**: 与 smartexit/inflight_hi 交互 (W3) → 默认 off, 单特性批次, 30m A/B 预注册: loss 腿回填斜率 + median vs cubic 复测 + 固定腿无回归 ≥90%
- **工作量**: 内核 ~100-150 行 + 参数 3 个 (α/k/开关)

### 候选 2: Dumazet 接收侧 11 补丁回移评估
- **内容**: 检查 7.2 系列基线是否含 net-next 2025-05 "tcp: receive side improvements" (6.12 基线大概率不含, 需回移); 修 rx 自调 RTT 高估 → rcv_space/rcvbuf 过冲/卡死
- **理由**: W4 是 xhttp/gam0 饿死的根因族, 这是**根治方向** (862340ff sockopt 只是兜底); 200G 单流 +66% 是 Google 生产背书
- **风险**: 中 — 内核网络栈补丁, 逐补丁审 + 30m 全量回归; 注意 1-CPU 大 rmem 内存代价, tcp_rmem[2] 提额补丁可不背
- **工作量**: 评估 0.5 天 + 回移/验证 1-2 天 (若补丁干净)

### 候选 3: ProbeRTT 保 pacing 小改
- **内容**: probe 期只压 cwnd 上限不降 pacing_rate (fq pacer 平滑), 消 150ms 场景 ~7% 近零速窗
- **理由**: 小改动; 长连接 span 流量可感知
- **风险**: 低; 但 PAM'24 提示 probe 让窗是公平收敛机制之一, 压掉可能伤与 cubic 共存 → 需 A/B 看共存 Jain
- **工作量**: ~20 行

### 搭车项: W5 CPU 基线 (零成本)
下次任意 CI soak 加 CPU% 采样, 一轮定基线。

## 不立项存档

- 哈工大 2019 γ=0.3 (抖动): 我们已实测鲁棒, 3 参数税不值
- BBR-A/BBR-C (pacing 模型化公平): RTT 相近的同路径竞速场景收益边际, 且强交互 smartexit/mlfq
- BBR-Copilot/TCPA: 旁路基础设施成本高, smart exit 已覆盖主症状

## 数据勘误存档

- "BBR-nF (PAMD'26)" 不存在 (四路检索), 我方种子有误 — 功能已被 oBBR/BBR-ACD 覆盖
- arXiv 2505.07741 venue = IFIP Networking 2025 (非 IMC'25)
