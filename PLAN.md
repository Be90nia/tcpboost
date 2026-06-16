# TCPBoost 开发计划

## 项目概述

TCPBoost 是一个 Linux VPS TCP 网络加速一键脚本，集成内核安装与系统级网络优化。

**参考项目**：
- [ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed) — 原版 tcp.sh
- [CloudPassenger/Cloud-Kernel-BBRv3](https://github.com/CloudPassenger/Cloud-Kernel-BBRv3) — 内核编译方案

**核心差异**（vs 原版 tcp.sh）：
| 对比项 | tcp.sh | TCPBoost |
|--------|--------|----------|
| 内核来源 | 预编译二进制下载 | GitHub Actions 云端编译 |
| 支持系统 | CentOS 7 / Debian | Debian 11+ / Ubuntu 20.04+ / Rocky 9 / Alma 9 |
| 内核版本 | 4.14 (BBRplus) / 5.x (BBR) | 6.12 LTS（支持到 2028）|
| 包格式 | .deb | .deb + .rpm |
| 算法 | BBR / BBRplus / 锐速 | BBRv3 / BBRPlus / TCP Brutal / BBRv1 |
| 网络优化 | 3 套固定方案 | 3 级方案 + BDP 动态计算 |
| 供应链 | 不透明 | GitHub Actions 全流程透明 |

---

## 开发阶段

### Phase 1: 构建流水线（当前）

**目标**：GitHub Actions 自动编译含 BBR 系列算法的 Linux 内核

**任务清单**：
- [x] 创建项目仓库结构
- [x] 编写 GitHub Actions 编译工作流
- [x] 编写内核编译配置脚本 (x86_64_apply.sh)
- [ ] 验证首次 Actions 构建成功
- [ ] 调试 RPM 打包流程
- [ ] 设置 ccache 缓存加速增量编译
- [ ] 配置自动发布到 GitHub Releases

**交付物**：
- `.github/workflows/build-kernel.yml` — 编译工作流
- `configs/x86_64_apply.sh` — 编译选项

**验收标准**：
- Actions 构建成功产出 `.deb` 和 `.rpm`
- 安装后 `sysctl net.ipv4.tcp_available_congestion_control` 显示 `bbr bbrplus bbr1`

---

### Phase 2: 安装脚本

**目标**：一键安装脚本，支持 Debian/Ubuntu (.deb) 和 Rocky/Alma (.rpm)

**任务清单**：
- [ ] 系统检测模块（OS 版本、架构、虚拟化环境）
- [ ] .deb 内核安装（dpkg）
- [ ] .rpm 内核安装（dnf/yum）
- [ ] 旧内核清理（保留一个回退版本）
- [ ] GRUB 默认内核设置
- [ ] 安装验证（重启后检查算法可用性）
- [ ] 卸载功能（恢复原内核）

**交付物**：
- `tcp.sh` 主脚本
- `install-kernel.sh` 内核安装器

**验收标准**：
- Debian 12 安装后重启，新内核生效
- Rocky 9 安装后重启，新内核生效
- 卸载后恢复原内核可正常启动

---

### Phase 3: 网络优化

**目标**：3 级 sysctl 优化方案 + BDP 动态计算

**任务清单**：
- [ ] Profile 1: 保守方案（低配 VPS，≤100Mbps）
- [ ] Profile 2: 均衡方案（通用 VPS，1Gbps）
- [ ] Profile 3: 激进方案（高性能，含 BDP 计算）
- [ ] BDP 动态计算（根据延迟/带宽/内存自动调整缓冲区）
- [ ] limits.conf / systemd 调优
- [ ] 原始配置备份与恢复
- [ ] 优化前后性能对比提示

**优化内容详细设计**：

#### Profile 1: 保守（≤100Mbps VPS）
```
net.core.rmem_max = 4194304          # 4MB
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr  # 或 bbrplus
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
```

#### Profile 2: 均衡（1Gbps VPS）
```
# 在 Profile 1 基础上增大 buffer
net.core.rmem_max = 16777216         # 16MB
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535
```

#### Profile 3: 激进（高性能 + BDP）
```
# BDP = bandwidth × RTT
# 自动计算 buffer 上限
net.core.rmem_max = 67108864         # 64MB
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
# + limits.conf: nofile 65535
# + systemd: DefaultLimitNOFILE=65535
```

#### BDP 动态计算逻辑
```bash
# 检测实际带宽（Mbps）和延迟（ms）
# BDP_bytes = (bandwidth_Mbps × 1000000 / 8) × (RTT_ms / 1000)
# 示例: 1Gbps × 200ms = 25MB
# buffer 上限 = max(BDP × 2, 16MB)，不超过物理内存的 1/16
```

**验收标准**：
- 每个 Profile 可独立应用和恢复
- BDP 计算结果在合理范围内
- 优化后 `sysctl -a` 显示正确值

---

### Phase 4: 算法管理

**目标**：支持运行时切换拥塞控制算法

**任务清单**：
- [ ] 查看当前算法和可用算法
- [ ] 切换算法（bbr/bbrplus/brutal/bbr1/cubic）
- [ ] 算法性能建议提示
- [ ] 算法持久化（写入 sysctl.conf）

**算法推荐场景**：
| 算法 | 推荐场景 | 要求 |
|------|---------|------|
| BBRv3 | 通用场景，推荐默认使用 | fq |
| BBRPlus | 高丢包链路（>1%丢包） | fq |
| TCP Brutal | Hysteria2/sing-box 专用 | mux 协议 |
| BBRv1 | 兼容性需求 | fq |
| Cubic | 生产环境，公平性好 | 默认 |

**验收标准**：
- `tcp.sh switch bbrplus` 切换成功
- 重启后算法配置保持

---

### Phase 5: 测试与发布

**任务清单**：
- [ ] Debian 12 安装测试
- [ ] Ubuntu 22.04/24.04 安装测试
- [ ] Rocky 9 安装测试
- [ ] Alma 9 安装测试
- [ ] 卸载恢复测试
- [ ] 优化方案 A/B 性能对比
- [ ] 编写 README 使用文档
- [ ] 首个 Release 发布

---

## 技术决策记录

### TD-001: 内核版本选择 6.12 LTS
- **原因**: CloudPassenger 补丁基于 6.12，LTS 支持到 2028.12
- **替代**: 6.6 LTS（更长支持但补丁兼容性差）
- **决策日期**: 2026-06-11

### TD-002: CentOS 最低版本 Stream 9
- **原因**: CentOS 7 已 EOL（2024.6），glibc 2.17 太旧
- **替代**: 支持 CentOS 7（需额外 glibc 兼容工作）
- **决策日期**: 2026-06-11

### TD-003: RPM 打包策略
- **首选**: `make binrpm-pkg` 原生 RPM 打包
- **备选**: `alien` 转换 .deb → .rpm
- **原因**: 原生打包更可靠，alien 作为 fallback
- **决策日期**: 2026-06-11

### TD-004: 补丁来源
- **来源**: CloudPassenger/Cloud-Kernel-BBRv3 `kernel_patches/` 目录
- **许可**: GPLv2（Linux 内核衍生）
- **风险**: 如果 CloudPassenger 停更，需自行维护补丁 forward-port
- **决策日期**: 2026-06-11

---

## 项目结构

```
tcpboost/
├── .github/
│   └── workflows/
│       └── build-kernel.yml     # GitHub Actions 内核编译
├── configs/
│   └── x86_64_apply.sh          # x86_64 编译选项
├── tcp.sh                       # 主脚本（安装+优化+管理）
├── PLAN.md                      # 本文件
├── README.md                    # 使用说明
├── .gitignore
└── LICENSE                      # GPLv2
```

---

## 里程碑

| 里程碑 | 目标日期 | 状态 |
|--------|---------|------|
| M1: 首次 Actions 构建成功 | - | 待验证 |
| M2: 安装脚本可用 | - | 开发中 |
| M3: 3 级优化方案完成 | - | 待开始 |
| M4: 算法管理功能 | - | 待开始 |
| M5: 首个 Release | - | 待开始 |

---

## BBRPlusV3 算法优化路线图

### Phase 1: 核心稳定性（已完成 2026-06-16）

**目标**：提升跨太平洋链路 TLS 握手稳定性 + 吞吐 + 减少波动

**已完成内容**：

| 优化项 | 状态 | 说明 |
|--------|------|------|
| BBRv3 核心机制验证 | ✅ 确认 | Xanmod 补丁已包含 PROBE_BW 4 相位 + PROBE_RTT 0.5×BDP + loss 计数器 + prior_cwnd + probe_wait 随机化 |
| BBR-ACD 双向 pacing | ✅ 完成 | 真拥塞(rtt>2×min_rtt) pacing×0.7 + 随机丢包 pacing×1.05，跨太平洋随机丢包不降速 |
| tls_optimized profile | ✅ 完成 | 第5档 profile：STARTUP 温和(2.77/2.0) + PROBE_BW standard(1.375/0.85) + 丢包容忍(5%) + PROBE_RTT 优化(100ms/5s) |
| TLS sysctl 配套 | ✅ 完成 | synack_retries=2, syn_retries=3, fastopen=3, slow_start_after_idle=0, mtu_probing=1 |
| IW10 初始拥塞窗口 | ✅ 完成 | initcwnd=10 (RFC 6928)，TLS 证书链(约 2 MSS)全覆盖 |
| tcp.sh 集成 | ✅ 完成 | 新增 `apply_profile_tls_optimized` + 菜单选项 5 + `tls-optimize` 子命令 |

**预期性能提升**：
- TLS 握手延迟 -45%（~640ms → ~350ms）
- 吞吐 +20-40%（BBR-ACD 减少随机丢包误退避）
- PROBE_RTT 吞吐波动 -80%

**研究依据**（2023-2026 学术论文 + 开源实现）：
- BBR-ACD: Electronics 2020, 9(1), 136 — 随机丢包 vs 拥塞丢包区分
- BBRv3e1: ICNC 2026 — STARTUP pacing_gain 2.77 比 2.89 公平性 +15%
- IMC 2019 — BBR 在浅缓冲重传率高 10×，20% 丢包悬崖点
- Cloudflare/Dropbox 生产 sysctl 调优经验
- RFC 6928 (IW10) + RFC 7413 (TFO) + RFC 8446 (TLS 1.3)

### Phase 2: 精细化调优（已完成 2026-06-16）

| 优化项 | 状态 | 说明 |
|--------|------|------|
| beta 加权 cwnd 缩减 | ✅ 完成 | BBR-ACD 真拥塞时 Recovery 首入执行 `cwnd × beta`（新增 `acd_cwnd_reduce` 参数，默认开启）。BBRv3 已有 `bbr_handle_inflight_too_high` 的 inflight_hi 软边界，本优化在其基础上增加显式 cwnd 缩减 |
| BBR-GC gamma correction | ✅ 完成 | 从 omega^4 公式改进为 sqrt 近似（γ=2 gamma correction），基于 queue_ratio 平滑过渡 DOWN gain。新增 `gc_base_down` 全局变量保存 profile 原始值避免递归修改 |

### Phase 3: 探索性（远期，需评估）

| 优化项 | 说明 | 风险 |
|--------|------|------|
| KCC 卡尔曼 min_rtt 滤波 | 替代滑动窗口 min_rtt，对队列噪声更鲁棒（liulilittle/kcc） | 许可证 NOASSERTION 需确认 |
| skb_marked_lost 回调 | 精细化丢包追踪（BBRv3 已有 `.skb_marked_lost`） | 需 BBRv3 补丁支持 |
| L4S / TCP Prague ECN | 精确 ECN 反馈（仅企业网段可用） | 跨洋公网路由器不支持 |

**Beads 任务追踪**：
- Epic: `tcpboost-2yh` (BBRPlusV3 算法优化)
- Phase 1 任务: `tcpboost-12i` (A), `tcpboost-b7w` (B), `tcpboost-739` (C)
- Phase 2 任务: `tcpboost-7gz` (D), `tcpboost-20h` (E)
