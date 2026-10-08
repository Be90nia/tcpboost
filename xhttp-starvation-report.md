# xhttp 流间饿死形态技术报告(供 tcpboost 项目评估)
> 产出背景:Xray-core-rust 战役 7p1m(P1,已关闭)收口后的残留形态,bd 票 `gam0`(P3)跟踪。
> 所有数据来自 2026-09-29~30 VPS 受控实验(netem 精确注入 + ss -tin 0.5s 逐流采样),非猜测。
> 生产环境:1-CPU VPS(199.115.231.188,或有 CPU 限速干扰需注意),客户端家宽->VPS 公网 RTT ≈150ms。
---
## 1. 现象
多流并发经 xray xhttp 隧道下载时,**部分流被钉死在 30-100KB/s,部分流正常(0.3-2.3MB/s)**,二态分化、随机选中的受害流、间歇触发:
| 环境 | 结果 |
|---|---|
| 公网 8 并发 | 2-4 流饿死(33-104KB/s),其余正常 |
| netem 双腿 loss 0.5%(150ms RTT) | **2/8 流饿死复现**(41.5/43.3KB/s,90s 窗) |
| netem 单腿 loss(同参数) | 10 轮零饿死 |
| 无 loss 基线 | 零饿死 |
关键:饿死流**不是慢慢追上来**,是整个连接生命周期持续 40KB/s 量级;受害流每次随机。
## 2. 根因(已实锤,应用层无可修点)
**Linux 内核 TCP 收端窗预测器(rcv_space / DRS)连接早期竞速亚稳态**:
1. TCP 连接建立后,内核 DRS 用 `rcv_space` 预测收端窗增长曲线,试图让窗口"刚好"匹配 BDP
2. 有 loss 时,预测器增长竞速存在**输家**:输家流的 `rcv_space` 恒被钉在 64KB 地板(实测 `rcv_space=65495` 从不增长)
3. 64KB 窗 × 150ms RTT ≈ 理论 0.85MB/s,但叠加 RTO 超时主导后实际交付 **≈40KB/s 持续亚稳态**
4. 赢家流同进程同配置可长到 `rcv_space=458-835KB`(差异完全在内核态,用户态不可见)
### ss -tin 判决表(实测)
| 流型 | rcv_space | 交付速率 |
|---|---|---|
| 饿死流 | 65495(恒钉地板) | 41-43KB/s |
| 健康流 | 458-835KB | 0.3-2.3MB/s |
### 排除项(都验过,不是这些)
- [FAIL] SO_RCVBUF 上限:7p1m 修复(862340ff)已把 rcvbuf 从 64KB 提到 4MB 解锁 DRS,饿死流的天花板不是 rcvbuf(是 rcv_space 地板)
- [FAIL] 应用层读不及时:Recv-Q 空、s […]… 接重抽竞速签,期望值上"输家重抽")--粗暴但可能有效,用户态可做
[WARN] 边界:此问题发生在**客户端接入侧的每流 TCP 连接**(家宽->VPS 那一段),不在 xray 隧道内部;tcpboost 若只优化 VPS 侧出口连接则不对口。触发条件=loss+高 RTT+多流竞速,干净网络不会出现。
## 6. 复现配方(tcpboost 验证可直接用)
```
# VPS 侧(39058 测试实例,lo 上 netem)
tc qdisc add dev lo root handle 1: prio bands 4
tc qdisc add dev lo parent 1:4 handle 40: netem delay 75ms 75ms loss 0.5% # 双向各 150ms
tc filter add dev lo protocol ip parent 1:0 prio 3 u32 match ip dst 127.0.0.1 flowid 1:4
# 8 并发 range 下载(每流 12.5MB 段)
curl -s -o /dev/null -w "%{speed_download}\n" --socks5-hostname 127.0.0.1:18080 \
-r $((i*13107200))-$(((i+1)*13107200-1)) http://<靶>/100mb.test & # i=0..7
# 判读:饿死流 <100KB/s 且 90s 不恢复;ss -tin 逐 0.5s 采样 rcv_space 钉 65495 判决
```
数据原件:VPS `/root/bench7p1m/out/m2_*`(ss -tin 双腿采样,iproute2 格式);终报 `D:/tmp-rel-test/XHTTPPERF.md`。
