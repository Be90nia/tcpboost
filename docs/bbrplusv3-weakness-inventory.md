# bbrplusv3 内部实测缺点清单 (PM 综合, 2026-10-18)

> 依据: backlog 验证战役全部 CI 数据 (atj/yve/7hn) + batch-1~5 历史。供文献调研对照, 判定每条缺点是否有对应优化方案。

## 实测确认的缺点

### W1. 总吞吐中位数落后 cubic (30m 粒度)
- 数据: atj 三轮 — median 347.7 vs cubic 395.8 (−12%), 均值反号 (+32%, 靠爆发轮)
- 假说: 丢包后 re-probe 偏保守, 回填慢 (68m 观察票挂账, 未验证)
- 疑点: cubic median 高有 harness 特异性 (fq 瓶颈+短轮次), 生产相关性未知
- 严重度: 中 (对抗 cubic 场景才有感; 对原版 bbr 仍 +8%)

### W2. 最弱流绝对值不敌 cubic 爆发轮
- 数据: atj min 均值 23.89 vs cubic 35.46 (中位数 12.43 vs 11.87 持平)
- 解读: cubic 靠个别爆发轮拉均值, 非稳态优势; 但"输给 cubic 爆发"的场景确实存在
- 严重度: 低 (中位数持平)

### W3. 参数交互面大, 审计困难
- 数据: batch-2 kalman/pi min 流回归靠 bisect 才定位主从犯; yve 轮 4 假警报 (CC 未切+ACK 流红鲱鱼) 烧了 5 轮 CI 才证伪
- 机制: 每个特性 (smartexit/kalman/pi/rto-cut/mlfq) 都是一个交互维度, 默认值组合无系统扫描
- 严重度: 高 (工程风险, 非性能缺陷 — 每次"默认开"都要付这税)

### W4. 收端 DRS 交互 (rcv_space 地板)
- 数据: xhttp 饿死报告 (gam0) — 收端窗预测器竞速输家钉 64KB; sockopt 4MB 抬顶后仍有亚稳态
- 定位: 通用 Linux DRS 问题, 非 bbrplusv3 特有; 但 BBR 依赖窗口模型, 受害更深
- 严重度: 中 (触发条件 loss+高RTT+多流; 生产已见)

### W5. 单核 CPU 开销未量化
- 数据: 无实测 (TCG 虚拟化数据不可用); pacing 高精度定时器 + fq 在 1-CPU 上的代价未知
- 严重度: 未知 (生产 1-CPU VPS 是主部署形态, 值得一次实测)

## 实测确认的优点 (防过度优化)

- 抖动鲁棒: ACK 抖动腿全场最高, 同配方对 bbr +26~73% (7hn 两轮 8 腿)
- 抗饿死: 对原版 bbr 最弱流 +76% (atj, loss 0.5%/150ms)
- loss 不塌: loss 腿 ≈ clean 腿 (yve, fq 基线下)

## 待文献对照的问题

| 缺点 | 需要的方案形态 |
|---|---|
| W1 | 丢包后加速 re-probe / inflight_hi 恢复策略 (不牺牲抗饿死) |
| W3 | 参数交互扫描方法 / 特性默认值策略 |
| W4 | 收端窗干预 (sockopt 层) 或 BBR 侧 DRS 感知 |
| W5 | pacing 开销基准方法 |
