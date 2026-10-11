# xhttp 流间饿死 × tcpboost 接入评估

> 收口结论: tcpboost 不是该问题的主要修复点; 但有一个低成本 sysctl 实验可做 PoC, 验证有效再决定是否进 profile.
> 评估时间: 2026-10-08
> 输入: `D:/Project/tcpboost/xhttp-starvation-report.md` (gam0 收口)
> 评估者: PM 初判 (Ponytail 模式: 最小完整变更)

---

## 1. 一句话结论

**饿死根因是 Linux 内核 TCP 接收端 DRS 预测器在 loss+高 RTT+多流竞速下的亚稳态 (客户端侧), 与发送端 BBR 无关.** tcpboost 是内核 CC (BBRPlusV3) + sysctl 工具, 不在用户态应用层, 报告 §5 列出的 4 个候选方向中**只有选项 3 (sysctl 调参) 在 tcpboost 管辖范围**, 且报告自身标注此方向为"可改变 DRS 竞速地形"的**推测**, 未经验证. 因此本任务收口为评估, 不写代码, 待 netem 实验结果决定是否行动.

---

## 2. 报告候选方向与 tcpboost 实际管辖范围对照

| 报告候选 | 性质 | tcpboost 管辖? | 说明 |
|---|---|---|---|
| 1. sockopt 干预 | 用户态 setsockopt | ❌ | tcpboost 无用户态组件 |
| 2. mux 共享连接 | 应用层协议 (xray/sing-box) | ❌ | 归属 xray-core-rust bd `gam0` (P3) |
| **3. sysctl 调参** | 内核参数 | **✅** | tcpboost 4 个 profile 都在管 sysctl |
| 4. 应用层重连 | 用户态逻辑 | ❌ | tcpboost 无用户态组件 |

**关键边界**: 此问题发生在**客户端接入侧** (家宽→VPS) 每流 TCP 连接的**收端窗**, 不在 xray 隧道字节路径, 也不在 VPS 出口侧. tcpboost 当前定位是**优化 VPS 出口侧** (BBRPlusV3 + sysctl), **对客户端接入侧 sysctl 默认由客户端 OS 决定**. 所以即使在 VPS 上调 sysctl, 也只影响 VPS 自己作为 receiver 的连接, 不能影响客户端家宽 OS 的 DRS 行为.

⚠️ **这是另一个不对口原因**: 即使 sysctl 调参方向有效, 也是给"tcpboost 部署在客户端"的用户才有用; 标准部署 (tcpboost 装在 VPS) 不对路.

---

## 3. tcpboost 本地 bd 相关 issue (已查)

- `gam0` (报告引用) ❌ **不在本仓库 beads**, 是 xray-core-rust 那边的票
- `tcpboost-65m` / `tcpboost-068` ✅ 已存在, 标题 "RTT 不公平性复合放大" 描述的是**发送侧 BBR 饿死低 RTT 流**, 与本次**接收侧 DRS 钉地板**是不同形态
- `tcpboost-7sz` SSH 审计, 间接相关

> 本地 beads 已有"饿死"方向的发送侧 issue, 但与本次问题不重叠. 不需要在本地新建 issue (gam0 在 xray 那边跟踪).

---

## 4. 现存代码中可借鉴的钩子

读了 `tcp.sh:1299-1623` 的 4 个 profile, 关键发现:

| Profile | `tcp_moderate_rcvbuf` | `tcp_adv_win_scale` | `tcp_rmem` max | 备注 |
|---|---|---|---|---|
| conservative (≤100M) | 1 (autotune ON) | 未设 (默认 2) | 4MB | DRS 跑预测 |
| balanced (1G) | 1 | 未设 | 16MB | 同上 |
| aggressive (BDP) | 1 | **1** | 16-128MB | adv_win_scale 已压低 |
| tls-optimized | 1 | 1 | 16-128MB | 同上 |

- `tcp_moderate_rcvbuf=1` (autotune) 是所有 profile 默认 → **这正是 DRS 预测器跑的开关**. 关掉它 (设 0) + 配高固定 `tcp_rmem` = 绕开 DRS 亚稳态.
- `tcp_adv_win_scale=1` 已用于激进/TLS profile (默认 2), 进一步压低 advertised window, 缓解方向一致
- `tcp_collapse_max_bytes` (Cloudflare 贡献) 是另一接收侧优化钩子, 已在用

`patches/6.12/xanmod-bbrv3/0011` + 6.18/7.0/7.1 BBRv3 补丁已**默认启用 `fast_ack_mode`**, 不需要再动 (也已确定它影响 DRS 但具体方向未知, 反正默认开了).

---

## 5. 唯一 PoC 实验 (低成本, 可做)

**目标**: 验证"关 DRS 自整定 + 固定高 buffer"是否消除饿死流. **改动一行 sysctl, 0 内核改动, 5 分钟.**

### 实验 A: 在 VPS 端模拟"接收侧"角色

1. 准备两台 VPS: 199.115.231.188 (标准测试机) + 备用
2. 在 199.115.231.188 上应用 baseline (现 aggressive profile)
3. `tc qdisc` 注入双腿 loss 0.5% (75ms+75ms) (报告 §6 配方)
4. 8 并发 range 下载 12.5MB 段
5. ss -tin 0.5s 采样, 记录 90s 内: 饿死流数 / 平均吞吐 / rcv_space 分布

### 实验 B: 在 199.115.231.188 上改一组 sysctl (唯一差异)

```bash
# 关键: 关 DRS autotune, 固定高 receive buffer
net.ipv4.tcp_moderate_rcvbuf = 0
net.ipv4.tcp_rmem = 4096 16777216 16777216  # min/default/max 都 16MB, 强制固定
# 其它参数与 baseline aggressive 相同
```

### 判定标准

- **正向**: 实验 B 饿死流数从 2-4 降到 0; 整体吞吐不下降
- **负向**: 实验 B 内存压力大 / 饿死未消除 / 吞吐下降 → 放弃此方向
- **中性**: 部分缓解 → 考虑作为可选项加入新 profile 或子命令, 默认 OFF

### 实施位置 (若有效)

不直接改 4 个现有 profile. 加一个**独立子命令** (保持现有用户不受影响):

```
./tcp.sh starvation-mitigation enable   # 关 DRS autotune, 固定高 rcvbuf
./tcp.sh starvation-mitigation disable  # 恢复
./tcp.sh starvation-mitigation status
```

理由: 饿死场景很特定 (loss + 高 RTT + 多流), 主流用户不需要; 默认 OFF 让知情用户手动开.

---

## 6. 范围外 (明确不做)

- 不动 BBRPlusV3 内核模块 (报告确认与 BBR 无关)
- 不引入新 sysctl (现有 `tcp_moderate_rcvbuf` + `tcp_rmem` 够用)
- 不动 mux 方向 (bd `gam0` 在 xray 那边)
- 不写新的 kernel patch

---

## 7. 风险与回退

| 风险 | 缓解 |
|---|---|
| 实验 A 内存吃紧 | buffer 16MB × 流数 = 8 流 = 128MB, 1G VPS 内存足够 |
| 改动影响所有 BBRPlusV3 用户的接收行为 | 默认 OFF, 子命令显式开启 |
| 实验发现 PoC 无效 | 不写代码, 此评估文档为最终交付, 不留技术债 |

---

## 8. 验证清单 (若启动 PoC)

- [ ] baseline (aggressive): 8 并发双腿 loss 0.5%, 90s, 复现 2-4 饿死流
- [ ] 实验 B: 同一 netem, 同一并发, 饿死流数 = 0 (或显著降低)
- [ ] 实验 B: 8 流平均吞吐 ≥ baseline (不退化)
- [ ] 实验 B: `free -m` 内存压力 < baseline + 100MB (不爆内存)
- [ ] 撤掉 PoC sysctl 后, baseline 饿死流复现 (确认因果)

---

## 9. 评估结论

> **本任务评估完成, 不写代码, 待 PoC 启动决策.** (2026-10-08 追补: 内核补丁方向评估见 §10 — tcpboost 作为内核补丁项目, 内核侧恰为其对口干预层, 修正 §1 "不是主要修复点"的过度收窄结论)

最小 PoC 成本: 1 个 netem 实验 (~30 min), 1 行 sysctl, 1 个子命令骨架 (~20 行 bash).
若 PM 决定启动 PoC, 走 `pm-dispatch` 派 `fullstack-engineer` 写 `apply_starvation_mitigation` + `disable` + `status` 三个函数, 嵌入 `tcp.sh` 的函数集合. 若 PoC 证明无效, 此评估文档为最终收口.

---

## 10. 内核补丁方向（追补评估, 2026-10-08 用户追问"能否从内核调整"）

### 10.1 DRS 钉地板的内核机制（v6.12 源码实锤, net/ipv4/tcp_input.c）

**起点**（`tcp_init_buffer_space()` L589）:
```c
tp->rcvq_space.space = min3(tp->rcv_ssthresh, tp->rcv_wnd,
                            (u32)TCP_INIT_CWND * tp->advmss);
```
DRS 基线从 `10 × advmss ≈ 14.5KB` 起步, 通告窗顶到 `tcp_rmem[1]` 默认值(≈64KB, 即报告实测的 65495 钉板).

**增长条件**（`tcp_rcv_space_adjust()` L750）:
```c
copied = tp->copied_seq - tp->rcvq_space.seq;
if (copied <= tp->rcvq_space.space)
    goto new_measure;          /* ← 钉地板的根源 */
```
增长只在"上一 RTT 实际交付字节 **>** 当前 space"时发生; rcvbuf 自动调大也在同一分支里 (L762-786). 丢包/RTO 打断交付 → `copied` 恒 ≤ space → **space 不涨 + rcvbuf 不涨 + 通告窗钉 64KB** 的闭环亚稳态. 这是确定性死锁条件, 与"竞速输家"表述吻合: 谁在窗口爬坡期踩中 RTO 打断, 谁永久锁死.

### 10.2 最终方案: tcpboost-unstick-1（修正初版 K1/K2/K3 设计）

> ⚠️ 初版设计的 K1（抬高 `rcvq_space.space` 起始地板）**方向反了**: DRS 增长前置条件是 `copied > space`（见 §10.1 L750），抬高 space 只会让健康流的增长分支更难触发、连健康流也被钉死。已废弃。K2/K3 合并为下述最终方案。

**真正的钳位链**（源码实锤）: 通告窗在 `__tcp_select_window()` 被两处硬钳于 `tp->rcv_ssthresh`（tcp_output.c），而 `rcv_ssthresh` 只靠 `tcp_grow_window()` 的 per-skb 慢启动启发式小幅增长（tcp_input.c，注释自述"slow start phase 用"）——丢包/RTO 打断后无人再抬它 → 窗、`copied`、DRS 三者闭环锁死。

**补丁**（每分支 3 文件 4 hunk，~35 行）:
1. `include/net/netns/ipv4.h`: 新增 `u8 sysctl_tcp_rcv_ssthresh_unstick;`（默认 0 = 原行为）
2. `net/ipv4/tcp_input.c` `tcp_init_buffer_space()`: unstick 时 `rcv_ssthresh = max(现值, min(window_clamp, tcp_full_space(sk)))` —— 起步即缓冲级窗，无低起点竞速
3. `net/ipv4/tcp_input.c` `tcp_rcv_space_adjust()`: 运行期保持 `rcv_ssthresh ≥ min(window_clamp, tcp_space(sk))` —— 只增不减、free-space 驱动（应用读得慢→队列满→不抬窗）、内存压力路径（`tcp_clamp_window`）照旧回缩、`sk_rcvbuf` 仍是内存硬顶
4. `net/ipv4/sysctl_net_ipv4.c`: 表项（仿 `tcp_moderate_rcvbuf` 的 u8/proc_dou8vec_minmax）

安全性: SO_RCVBUF 锁定 4MB 的代理套接字窗直接开到位；自整定套接字窗跟随 rcvbuf 增长而非卡死启发式。后续扩展（未做）: K3 跨连接 rcv_space 峰值缓存（复用 lotspeed-1 基建）。

**落地（本 PR 仅 6.12 触发编译，7.2 端到端待 11 节 retarget）**: `patches/{6.12→0020, 6.18/7.0/7.1→0003}`，`tcp.sh` aggressive/tls 档 `net.ipv4.tcp_rcv_ssthresh_unstick = 1`。7.2 三件补丁（0001/0002/0003）已落盘但 kernel_patches/7.2 配套未就绪，本 PR 不触发。

补丁生效在**收端**内核. 报告生产场景收端 = 家宽客户端:

| 收端形态 | K1-K3 是否生效 |
|---|---|
| Windows/Mac 家宽客户端（常见场景） | ❌ 装不了 Linux 内核 |
| **Linux 软路由 / 网关客户端**（本用户群常见） | ✅ 生效 |
| VPS 自身作为收端（上传方向 / 报告的 netem 实验拓扑） | ✅ 生效 |
| VPS 仅作发端（下载方向） | ❌ 发端 CC 补丁（BBRPlusV3）管不了收端通告窗, 无 sender 侧补丁可替代 |

结论: 内核补丁方向**技术上完全可行且对口 tcpboost**, 但只覆盖"收端装 tcpboost 内核"的场景. 对 Windows/Mac 家宽客户端, 唯一出路仍是 bd `gam0` 的用户态 mux 方向.

## 11. 7.2 端到端状态 (WIP, 2026-10-08)

7.2 编译触发**本次未做**，原因：`kernel_patches/{6.18,7.0,7.1}` 存在但 `kernel_patches/7.2/` 缺；CI 退到 CloudPassenger 远程拉——而 bbrplus/bbr1/brutal 三件套对 7.2 的 Makefile/Kconfig 行号漂移没 retarget 过，套用后会留 .rej，CI 的"零 reject 才放过"会直接 exit 1。已复制 7.1 三件套作 `kernel_patches/7.2/` 起点但未完工。**本次 PR 只触发 6.12**——主战场。7.2 完整跑通需 retarget 三件套（5–10 行 Makefile/Kconfig 偏移调整），留作下一个 PR。

## 12. 验证流水线 (本次新增)

- **CI 编译门禁** (`.github/workflows/build-kernel.yml` 加 `qemu-test` job): build-kernel 出包 → dpkg -i → virtme-ng QEMU TCG 启动 → `scripts/qemu_functional_test.sh` 跑 BBRPlusV3 模块加载/参数/CC 切换/iperf3 loopback/unstick A/B/8 并发/netem 8 流/卸载。**门禁作用**: 内核能跑起来 + unstick patch 行为正确，不阻塞 release。
- **5h 长跑套件** (`scripts/soak_test_5h.sh` + `soak_analyze.sh`): 跑在你 VPS 真内核上，8 流 iperf3 + 双腿 5%/75ms netem，30s 采样吞吐/sockstat/conntrack/PSI/CPU/mem，5h 末自动出 `regression.md` + `summary.md`，**VERDICT: PASS/WARN/FAIL**——这是"用久降速"的判决器。
