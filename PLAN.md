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
