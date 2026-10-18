# AQM hardening 三臂×两腿 A/B (bd yve) — Wave-0 支线验证报告

**结论: REJECT — 在 CI QEMU 复现环境（固定 150ms RTT + loss 0.5% + 校准限速瓶颈 + 8 流 12.5MB 竞速）下, fq_codel 与 cake 相对 fq 基线均无显著优势（饿死三臂全零, min-flow 无差异, cake 全指标略差）; 饿死前提本身未在该环境复现（gate=REPRO_WEAK）。按战役规则无效即弃, 主线零影响。**

`VERDICT: REJECT`

- 日期: 2026-10-16 ~ 10-18; 派单: bd yve（backlog 全量验证战役 Wave-0）; 环境: GitHub Actions CI QEMU guest（vng TCG, 内核 7.2.11-tcpboost+, SHAPE 自动校准 166Mbit）
- 数据: run 39070138587 artifact `aqm-ab-results`（六腿原始 CSV + ping/ss/tc 采样 log + summary.txt）; 烟雾探针 run 39063660975（绿）; 前置失败轮 38840464139/38853683704/39033650855/39039732757（修复链见 §3）

## 1. 全量 A/B 结果（3 臂 × loss/clean, 每腿 1200s, 64-85 批/腿）

### loss 腿（复现条件, 决定性对比）

| 指标 | fq (基线) | fq_codel | cake |
|---|---|---|---|
| total p50 Mbps | 79.6 | **85.2** (+7%) | 68.2 (−14%) |
| total p5 Mbps | 71.4 | 78.0 | 63.5 |
| min-flow p50 Mbps | 7.49 | 7.49 | 6.55 |
| min-flow p5 Mbps | 6.55 | 6.55 | 5.82 |
| 加载 RTT p50/p95 ms | 153/168 | 152/160 | 153/161 |
| starved% / max streak | 0 / 0 | 0 / 0 | 0 / 0 |

### clean 腿

| 指标 | fq | fq_codel | cake |
|---|---|---|---|
| total p50 Mbps | 87.1 | **98.0** (+12.5%) | 75.0 (−14%) |
| min-flow p50 Mbps | 8.73 | 9.51 | 8.05 |
| RTT p95 ms | 171 | 162 | 164 |

### 判读（对照 §4 预声明门槛）

- **环境 gate**: fq_loss starv%=0, streak=0 → `REPRO_WEAK`——差分饿死（输家流钉地板）在本环境未复现, "有无饿死场景可改善"的答案是无。
- **KEEP 三条全不满足**: starv% 比 1/3（0/0 空真）、min p5 ≥2×（fq_codel 1.0×, cake 0.89×）、RTT p95 ≤+25%（三者相当, 两个挑战者反而略优）。
- **次级观察（未过显著门槛, 供 PM 参考）**: fq_codel 有温和的总吞吐优势（loss +7%, clean +12.5%）与略优 RTT p95; cake 全指标略差（其 per-flow 隔离在该负载无增益, TCG 4 vCPU 下开销更重）。
- **机理注记**: pin%（rcv_space≤65535 采样占比）三臂普遍 90-97%——窗口贴 64KB 常态普遍存在（campaign 已知 regime）但未发展为差分饿死; bbrplusv3 在固定 RTT + 0.5% loss 下 loss 腿 ≈ clean 腿（无 loss 塌缩）。

## 2. 最终实验环境

- 拓扑（纯 egress, 无 ifb）: `ns_srv(10.0.1.1) ──(ve_s|v_s) host 路由 ──(v_c|ve_c) ns_cli(10.0.2.1)`。
  - 数据方向 srv→cli: ve_s egress 挂 `tbf(校准限速 166Mbit) + 被测 qdisc`（**瓶颈队列真在被测 qdisc**）→ v_s ingress → 路由 → v_c egress 挂 `netem delay 75ms loss 0.5%`（无 rate, 只延迟染色）
  - ACK 方向: ve_c egress → 路由 → v_s egress 挂 `netem delay 75ms`（无 rate）
  - RTT = 固定 150ms（实测 p50 151-153ms）; loss 只在数据方向; offloads 全关（1500B 段, AQM 粒度三臂一致）
- 关键设计约束: **netem 不得与被测 qdisc 串同一设备链**——netem enqueue 即按时间戳入 tfifo, 恒吃掉批量队列, 下游 qdisc 永远近空载 → 三臂假性无差异（120.79 VPS smoke 实证后撤离）。
- 数据自采: iperf3 `-J` 逐流 jq 解析 + `ss -tin` 5s 循环 + `ping -i 0.2` 循环 + `tc -s` 30s 快照; 不依赖旧 soak harness JSONL。
- 防抖: 校准 3 batch 取 max（TCG 容量不足自动下调 SHAPE 并记日志）+ 每腿 64-85 批天然多采样 + 每腿 ICMP/TCP 双预检 fail-fast。

## 3. 修复链（五轮 CI 的教训, 全部实证）

| 轮次 | run | 失败/发现 | 修复 |
|---|---|---|---|
| 1 | 38840464139 | ifb0 设备冷插失败 | 加卸载重载重试环; 后续连 ifb 整体拆除 |
| 2 | 38853683704 | `FATAL: netem 建立失败`（当时误诊 netem-on-ifb 兼容性） | 真因见轮 4 |
| 3 | 39033650855 | 同轮 2 复现 | 去 ifb 纯 egress 重构后仍复现 → 排除 ifb |
| 4 | 39039732757 | `What is "delay 75ms 75ms limit 10000"?` — **v_s netem 选项串误加引号成单 argv**, tc usage 拒收（轮 2/3 同根因, 引号实锤）; 修后腿跑通但暴露下一层: 抖动 + rto-1 门诱发虚假 RTO 风暴（cwnd 钉 11-13 包 542 采样, rcv_space 钉 14480, 8 流塌缩 0.6Mbps, DRS 反向收敛死循环）+ 腿末裸 `wait` 等 `exec>(tee)` 的 tee 死锁 4h 撞 job 超时 | 引号去除 + 抖动回归战役原始固定 150ms 配方 + 裸 wait 改 sleep 1 |
| 5 | 39063660975 | **烟雾绿**（fq_codel+cake 四腿全落盘, 111-118Mbps, starv 全零） | — |
| 6 | 39070138587 | **全量六腿完成** → 本报告 | — |

分支轨迹: `feature/aqm-ab-ci` b5c58ba → 320e485（去 ifb）→ 820891a（引号）→ 4bf56c5（抖动+死锁）, ShellCheck 全绿; create-release 加 `aqm_skip_release` 门（实验 dispatch 不覆盖生产 release tag, 已实证生效）。

## 4. 预声明判读门槛（数据落地前固化于 docs §3, 未事后调整）

- 环境 gate: fq_loss starved% ≥ 2 或 streak ≥ 3 → REPRO_OK; 否则 REPRO_WEAK。
- KEEP: loss 腿 starv% ≤ 1/3 of fq AND min p5 ≥ 2× AND RTT p95 恶化 ≤ +25%。
- starved 定义: min 流 < 25% 批次中位; 钉死签名: rcv_space ≤ 65535。

## 5. 遗留与建议

- 分支 `feature/aqm-ab-ci`（4bf56c5）不并主线: harness `scripts/aqm_ab_test.sh`（ARMS/LEG_SEC/SHAPE_REQ/RTT_HALF_MS/LOSS_PCT 全参数化）+ `aqm-ab-test` CI job + apply.sh `CONFIG_NET_SCH_NETEM =m` 均为支线资产; create-release 跳过门已内建。
- 若 PM 认为 fq_codel 的 +7~12% 总吞吐值得追: 建议另立票在更接近生产的 VPS 环境复核（本环境 gate REPRO_WEAK, 总吞吐差异未过预声明显著门槛）。
- bd tcpboost-yve 已 comment 结论（未 close, keep/reject 裁决归 PM）。
- VPS 阶段存档: `C:/Users/Begonia/AppData/Local/Temp/aqm_vps_dump.tgz`。

## 6. 复跑命令

```bash
gh workflow run build-kernel.yml -R Be90nia/tcpboost --ref feature/aqm-ab-ci \
  -f kernel_series=7.2 -f force_build=true \
  -f aqm_leg_sec=1200 -f aqm_arms="fq fq_codel cake" \
  -f soak_duration=5m -f aqm_skip_release=true
```

## 附录: VPS 阶段与历程存档（2026-10-16, 已撤出）

- 120.79.166.224: 拓扑搭建 ✓ → fq smoke 60s → TCP 全 SYN-SENT 故障（ICMP 通, 疑 rp_filter 吞 ifb0 回注 SYN-ACK, 未及定位即撤离; 该故障在纯 egress 拓扑中已不存在）→ Main 令撤出。
- RTT 层实测: ping n=659, p50=149.0ms——netem/路由层设计曾验证可行。
- qdisc 链曾验证: netem(limit 10000)/tbf(burst 256kb lat 1s)/fq(parent 1:1) 挂载正常。
- 撤离复核: 无 iperf3/ping/leg 进程, netns/veth/ifb 全删, eth0 默认 fq 未动, /root/aqm 已删, 数据先打包后拆除; iperf3 apt 包惰性未 purge。
- 历程: PM 停工令（14:00 北京）期间 offline; resume 后按 GO 指令完成烟雾→全量→本报告。
