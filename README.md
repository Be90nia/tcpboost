# TCPBoost — Linux VPS TCP 网络加速一键脚本

基于 Linux 6.12 LTS 内核，集成 BBRv3 / BBRPlus / TCP Brutal / BBRv1 拥塞控制算法 + 系统级网络优化。

## 特性

- **GitHub Actions 云端编译** — 内核编译过程完全透明，可审计
- **多算法集成** — BBRv3、BBRPlus、TCP Brutal、BBRv1 一键切换
- **双格式支持** — Debian/Ubuntu (.deb) + Rocky/Alma (.rpm)
- **3 级网络优化** — 保守 / 均衡 / 激进，含 BDP 动态计算
- **国内外自适应** — 自动检测网络环境，国内使用加速镜像下载
- **安全可靠** — 配置自动备份，一键恢复

## 支持系统

| 系统 | 最低版本 | 包格式 |
|------|---------|--------|
| Debian | 11 (Bullseye) | .deb |
| Ubuntu | 20.04 (Focal) | .deb |
| Rocky Linux | 9 | .rpm |
| AlmaLinux | 9 | .rpm |
| CentOS Stream | 9 | .rpm |

**架构**: 仅 x86_64

## 快速开始

```bash
# 国际网络（GitHub 直连）
bash <(curl -fsSL https://raw.githubusercontent.com/Be90nia/tcpboost/main/tcp.sh)

# 国内网络（加速镜像）
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Be90nia/tcpboost/main/tcp.sh)
```

> 脚本启动后会自动检测网络环境，国内用户下载内核包时将自动使用加速镜像，无需额外配置。

## 使用说明

### 交互式菜单

运行脚本后显示菜单：

```
  1) 安装 TCPBoost 内核 (6.12 LTS)
  2) 网络优化 — 保守方案 (≤100Mbps)
  3) 网络优化 — 均衡方案 (1Gbps)
  4) 网络优化 — 激进方案 (高性能)
  5) 切换拥塞控制算法
  6) 恢复默认配置
  7) 卸载 TCPBoost 内核
  0) 退出
```

### 命令行模式

```bash
# 安装内核
./tcp.sh install

# 应用均衡优化
./tcp.sh optimize

# 切换到 BBRPlus
./tcp.sh switch bbrplus

# 查看当前状态
./tcp.sh status

# 卸载
./tcp.sh uninstall

# 恢复默认配置
./tcp.sh restore
```

### 拥塞控制算法

| 算法 | 推荐场景 | 说明 |
|------|---------|------|
| **BBRv3** | 通用场景（推荐默认） | Google 最新版，延迟低、公平性好 |
| **BBRPlus** | 高丢包链路（>1%） | 丢包场景性能提升 3-4 倍 |
| **TCP Brutal** | Hysteria2/sing-box 专用 | 需 mux 协议配合 |
| **BBRv1** | 兼容性需求 | 主线内核 4.9+ 内置 |
| **Cubic** | 生产环境 | 公平性好，适合多用户 |

### 网络优化方案

| 方案 | 带宽 | Buffer | BDP 计算 | limits.conf |
|------|------|--------|----------|-------------|
| 保守 | ≤100Mbps | 4MB | 否 | 否 |
| 均衡 | 1Gbps | 16MB | 否 | 否 |
| 激进 | 10Gbps | 动态 | 是 | 是 |

## 项目结构

```
tcpboost/
├── .github/workflows/
│   └── build-kernel.yml     # GitHub Actions 内核编译
├── configs/
│   └── x86_64_apply.sh      # x86_64 内核编译选项
├── tcp.sh                    # 主脚本
├── PLAN.md                   # 开发计划
├── README.md                 # 本文件
└── LICENSE                   # GPLv2
```

## 致谢

- [CloudPassenger/Cloud-Kernel-BBRv3](https://github.com/CloudPassenger/Cloud-Kernel-BBRv3) — 内核补丁和编译配置
- [ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed) — 原版 tcp.sh 网络优化参考
- [cx9208/bbrplus](https://github.com/cx9208/bbrplus) — BBRPlus 算法原始实现
- [UJX6N/bbrplus-6.x_stable](https://github.com/UJX6N/bbrplus-6.x_stable) — BBRPlus 6.x 内核移植

## 许可证

GPLv2 — 与 Linux 内核许可证一致
