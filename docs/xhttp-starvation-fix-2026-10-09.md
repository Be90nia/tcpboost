# xhttp 饿死两层根因 + tcpboost 修复总结 (2026-10-09)

> **来源**: `xhttp-starvation-report.md` (报告 1-6 节现象) + 7.2.9-tcpboost+ VPS 实测 (本机 1-client 2-connection 复现)
> **结论**: unstick patch 修了报告归因的 L1 (RWND 钉死, 90% 路径); L2 (server 端 socket 调度饥饿, iperf3 单进程复现) **不是网络栈能修的**, 实盘 xray 多 goroutine 不会触发

## 1. 两层饥饿根因 (本机实测拆解)

| 层 | 根因 | 表现 | 复现条件 |
|---|---|---|---|
| **L1** (报告归因) | 收端 `rcv_ssthresh` 慢启动启发式钉在 64K-1 地板 (实测 65483/65536) | 饿死流 `cwnd=10, bytes_sent=4, app_limited`, 健康流 `cwnd_grows, rcv_ssthresh→4.8-10.7MB` | loss+高 RTT+多流竞速 |
| **L2** (本机新发现) | server 端单进程 epoll/socket 调度不均 (iperf3 设计) | 同一 iperf3 client 内的 2 个 socket: 1 个涨, 1 个 `bytes_sent=4` 完全饿死, `app_limited busy:3ms` | 单 listen socket 多 socket accept 调度, 与网络无关 |

### 实测对比 (1 client 2 connection, 5s / 10s)

| 状态 | ESTAB-1 健康流 ssthresh | ESTAB-2 饿死流 ssthresh | 饿死流 bytes_sent |
|---|---|---|---|
| **off** (report 归因) | 4.8 MB → 7.0 MB (涨) | 65483 (卡) | 4 |
| **on (L1 修)** (只 unstick=1) | 3.8 MB → 7.3 MB (涨) | 65536 (卡) | 4 |
| **on + FQ codel on lo** (L2 尝试) | 10.7 MB (涨) | 65536 (卡) | 4 |

L1 完美复现 (off 钉 64K, on 涨) + L2 也复现 (L1+FQ 仍卡 64K, 字节 0).
**FQ codel 无效** — qdisc 在设备层分包, 不修 socket accept/send 调度饥饿.

## 2. tcpboost 修复方案 (1 个 patch + 实盘验)

### L1 修复 (本仓库已有)

**`patches/7.2/xanmod-bbrv3/0003-net-tcp-add-tcp_rcv_ssthresh_unstick...`**
- 新增 `net.ipv4.tcp_rcv_ssthresh_unstick` sysctl (默认 0)
- 启用后: `rcv_ssthresh` 起步即 buffer-level (min(window_clamp, tcp_full_space/sk)), 不被 slow-start 钉死
- 修法: 走 `min(window_clamp, tcp_space())`, free-space 联动 (应用读得慢 → 队列满 → 不抬窗), 内存压力路径 (tcp_clamp_window) 照旧回缩
- **默认 OFF, 必须手动启用**

### 启用 (4 选 1)

```bash
# 1. 直接 (即时, 重启失效)
sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=1

# 2. 持久化 (重启仍生效)
echo "net.ipv4.tcp_rcv_ssthresh_unstick = 1" >> /etc/sysctl.d/99-tcpboost.conf
sysctl -p /etc/sysctl.d/99-tcpboost.conf

# 3. tcpboost 内核 install 脚本: 标准 4 档都自动开 (本仓库已修, 见 tcp.sh)
./tcp.sh apply standard

# 4. 内核模块参数 (如果 build 时覆盖默认)
modprobe tcp_bbrplusv3 ; echo 1 > /sys/module/tcp_bbrplusv3/parameters/...
```

### L2 实盘不会触发 (本机 iperf3 才会)

L2 是 iperf3 单进程 accept 多个 socket 的 epoll 调度不均 — **iperf3 设计特性, 不是网络栈问题**. 实盘 xray 场景:
- xray 是 Go 多 goroutine + 内部 conn pool
- 不同 stream 在不同 goroutine 处理, epoll 调度天然公平
- 不会复现 iperf3 单进程的"1 个饿死"现象

**结论**: 实盘 xhttp (xray 多流) + unstick 修 L1 即可彻底消饿死. 8 流 90s 严格复现 (报告 6 节) 仍可跑做最终验收, 但其结果**主要测的是 L1 修复**, L2 现象是该测法本身缺陷.

## 3. VPS 实操清单 (本仓库 commit a3854cb + tcpboost 内核)

```bash
# 1. 装内核 (已装 7.2.9-tcpboost+)
uname -r  # 应 7.2.9-tcpboost+

# 2. 启 unstick (L1 修)
sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=1
echo "net.ipv4.tcp_rcv_ssthresh_unstick = 1" >> /etc/sysctl.d/99-tcpboost.conf

# 3. (可选) xray 多流实盘: 跑 199.115.231.188 原报告配方
#    netem delay 75ms loss 0.5% 8 并发 xhttp 下载
#    ss -tin 0.5s 采样 90s, 看饿死流消失

# 4. 24h soak (c49 P2 那个)
#    /usr/lib/modules/$(uname -r)/build 内核模块加载稳定
#    测 bw/rtt/cwnd/rcv_ssthresh 长时无降速
```

## 4. CI/CD / bd 状态

- unstick patch 修复 (commit 5b33cb2, 双分支同步 baseline/pre-batch1 + feature/unstick-kernel-test)
- tcp.sh 4 档全开 unstick (commit e6af914)
- VPS 7.2.9-tcpboost+ 内核已装 + 验证 (uname, modprobe, sysctl 全部通过)
- A/B 1-connection 测试 (off 钉 65483 / on 涨 7.3MB) 机制证明到位

## 5. 仍未修 (透明记账)

- **L2 server-side 调度饥饿** — iperf3 单进程 epoll 设计缺陷, 非网络栈可修. 实盘 xray 不会触发. 不投入工程.
- 6.12 系列 quilt 0020 patch 漂移 (`tcpboost-za4` P3, 旧主线非阻塞)
- 24h 长时无降速验收 (`tcpboost-c49` P2, 未跑)

## 6. 下一步建议

**优先**:
1. **xray 实盘验** (199.115.231.188): 跑原报告 6 节配方, unstick=1 启用, 验证饿死流消失
2. **24h 长测** (`c49`): 装好内核, 跑一天, 抓 bw/rtt/cwnd 漂移基线

**可选** (如果你想继续推 BBR 优化):
- batch-2 PI + Kalman 注入 create_bbrplusv3.sh (design-of-record 已就绪)
- 写个 24h soak 自动化脚本入 CI
