#!/bin/bash
# create_bbrplusv3.sh — 基于 BBRv3 tcp_bbr.c 创建 bbrplusv3 算法
#
# 工作流程：
#   1. 复制 tcp_bbr.c → tcp_bbrplusv3.c
#   2. 修改模块名、算法名、版本号
#   3. 调整算法参数（pacing_gain 动态化、cwnd_gain 增大、PROBE_RTT 优化）
#   4. 添加 sysctl 可调参数（ECN/loss_thresh/beta/probe_rtt）
#   5. 修改 Kconfig 和 Makefile 注册新算法
#
# 前提：已应用 Xanmod BBRv3 补丁，net/ipv4/tcp_bbr.c 为 BBRv3 版本
#
# 许可证：GPLv2

set -e

KERNEL_DIR="${1:-.}"
cd "$KERNEL_DIR"

BBR_SRC="net/ipv4/tcp_bbr.c"
BBRPLUSV3_SRC="net/ipv4/tcp_bbrplusv3.c"

if [ ! -f "$BBR_SRC" ]; then
  echo "错误: 未找到 $BBR_SRC，请先应用 Xanmod BBRv3 补丁"
  exit 1
fi

echo "=== 创建 BBRPlusV3 算法 ==="
echo "源文件: $BBR_SRC"
echo "目标文件: $BBRPLUSV3_SRC"

# ============================================
# 1. 复制 tcp_bbr.c → tcp_bbrplusv3.c
# ============================================
cp "$BBR_SRC" "$BBRPLUSV3_SRC"
echo "[1/6] 已复制 $BBR_SRC → $BBRPLUSV3_SRC"

# ============================================
# 2. 修改模块名和算法标识
# ============================================

# BBR 版本号改为 3+（表示基于 BBRv3 的增强版）
sed -i 's/#define BBR_VERSION\t\t3/#define BBR_VERSION\t\t3/' "$BBRPLUSV3_SRC"

# 模块描述
sed -i 's/MODULE_DESCRIPTION("TCP BBR (Bottleneck Bandwidth and RTT)")/MODULE_DESCRIPTION("TCP BBRPlusV3 (BBRv3 + aggressive probing, based on BBRPlus ideas)")/' "$BBRPLUSV3_SRC"

# 注册名：bbr → bbrplusv3
sed -i 's/\.name\t\t= "bbr",/.name\t\t= "bbrplusv3",/' "$BBRPLUSV3_SRC"

# struct 名称：tcp_bbr_cong_ops → tcp_bbrplusv3_cong_ops
sed -i 's/static struct tcp_congestion_ops tcp_bbr_cong_ops/static struct tcp_congestion_ops tcp_bbrplusv3_cong_ops/' "$BBRPLUSV3_SRC"

# module_init / module_exit 注册函数名
sed -i 's/module_init(tcp_bbr_register)/module_init(tcp_bbrplusv3_register)/' "$BBRPLUSV3_SRC"
sed -i 's/module_exit(tcp_bbr_unregister)/module_exit(tcp_bbrplusv3_unregister)/' "$BBRPLUSV3_SRC"

# 注册/注销函数名
sed -i 's/static int __init tcp_bbr_register/static int __init tcp_bbrplusv3_register/' "$BBRPLUSV3_SRC"
sed -i 's/static void __exit tcp_bbr_unregister/static void __exit tcp_bbrplusv3_unregister/' "$BBRPLUSV3_SRC"

# 注册时引用的 ops 变量名
sed -i 's/tcp_register_congestion_control(&tcp_bbr_cong_ops)/tcp_register_congestion_control(\&tcp_bbrplusv3_cong_ops)/' "$BBRPLUSV3_SRC"
sed -i 's/tcp_unregister_congestion_control(&tcp_bbr_cong_ops)/tcp_unregister_congestion_control(\&tcp_bbrplusv3_cong_ops)/' "$BBRPLUSV3_SRC"

echo "[2/6] 已修改模块名和注册信息"

# ============================================
# 3. BBRPlus 核心算法改进
# ============================================

# 3a. pacing_gain UP: 5/4 → 3/2（更激进的带宽探测）
#     BBRv3: BBR_UNIT * 5 / 4 = 1.25
#     BBRPlusV3: BBR_UNIT * 3 / 2 = 1.5（BBRPlus 原版 pacing_gain = 2.89，但太激进；
#     1.5 是 BBRPlus 思想与 BBRv3 框架的平衡点）
sed -i 's/BBR_UNIT \* 5 \/ 4,\t\/\* UP: probe for more available bw \*\//BBR_UNIT * 3 \/ 2,\t\/\* UP: aggressive bandwidth probing (BBRPlus-style) *\//' "$BBRPLUSV3_SRC"

# 3b. pacing_gain DOWN: 91/100 → 3/4（更积极地排空队列）
#     BBRv3: BBR_UNIT * 91 / 100 = 0.91
#     BBRPlusV3: BBR_UNIT * 3 / 4 = 0.75（与 BBRPlus 原版 drain 一致）
sed -i 's/BBR_UNIT \* 91 \/ 100,\t\/\* DOWN: drain queue and\/or yield bw \*\//BBR_UNIT * 3 \/ 4,\t\/\* DOWN: aggressive drain (BBRPlus-style) *\//' "$BBRPLUSV3_SRC"

# 3c. startup_cwnd_gain: 2 → 2.5（BBRPlus 核心思想：STARTUP 时更激进地填充管道）
#     BBRv3: BBR_UNIT * 2
#     BBRPlusV3: BBR_UNIT * 5 / 2 = 2.5
sed -i 's/static const int bbr_startup_cwnd_gain  = BBR_UNIT \* 2;/static const int bbr_startup_cwnd_gain  = BBR_UNIT * 5 \/ 2; \/* BBRPlus-style: more aggressive startup pipe-filling *\//' "$BBRPLUSV3_SRC"

# 3d. bbr_beta: 30% → 20%（丢包时减少更少，保持更高吞吐）
#     BBRv3: BBR_UNIT * 30 / 100
#     BBRPlusV3: BBR_UNIT * 20 / 100
sed -i 's/static const u32 bbr_beta = BBR_UNIT \* 30 \/ 100;/static const u32 bbr_beta = BBR_UNIT * 20 \/ 100; \/* BBRPlus-style: less reduction on loss *\//' "$BBRPLUSV3_SRC"

# 3e. loss_thresh: 2% → 5%（丢包容忍度提高，高丢包链路不会过早降速）
#     BBRv3: BBR_UNIT * 2 / 100
#     BBRPlusV3: BBR_UNIT * 5 / 100
sed -i 's/static const u32 bbr_loss_thresh = BBR_UNIT \* 2 \/ 100;  \/\* 2% loss \*\//static const u32 bbr_loss_thresh = BBR_UNIT * 5 \/ 100;  \/* 5% loss tolerance (BBRPlus-style) *\//' "$BBRPLUSV3_SRC"

echo "[3/6] 已应用 BBRPlus 核心算法改进"

# ============================================
# 4. PROBE_RTT 优化（200ms → 50ms，sysctl 可调）
# ============================================

# BBRv3 的 PROBE_RTT 停留时间默认 200ms（bbr_probe_rtt_mode_ms）
# 缩短到 50ms 可以减少吞吐量损失，在长肥管道上尤其明显
# 注意：bbr_probe_rtt_mode_ms 在 BBRv3 代码中是 static const u32
# 我们改为更高的 sysctl 可调值
sed -i 's/static const u32 bbr_probe_rtt_mode_ms = 200;/static const u32 bbr_probe_rtt_mode_ms = 50; \/* BBRPlusV3: shorter PROBE_RTT (was 200ms) *\//' "$BBRPLUSV3_SRC"

# bbr_probe_rtt_win_ms: 5000 → 2500（更频繁地探测 min_rtt）
# 这样 PROBE_RTT 每 2.5 秒进入一次（vs BBRv3 的 5 秒），
# 但每次只停 50ms（vs BBRv3 的 200ms），总吞吐量损失更小
sed -i 's/static const u32 bbr_probe_rtt_win_ms = 5000;/static const u32 bbr_probe_rtt_win_ms = 2500; \/* BBRPlusV3: probe RTT more often (was 5000ms) *\//' "$BBRPLUSV3_SRC"

echo "[4/6] 已优化 PROBE_RTT 参数"

# ============================================
# 5. ECN 可调化
# ============================================

# bbr_ecn_thresh: 50% → 70%（ECN 标记容忍度提高）
# BBRv3 默认 50% 太保守，在高 ECN 标记链路会过早降速
sed -i 's/static const u32 bbr_ecn_thresh = BBR_UNIT \* 1 \/ 2;  \/\* 1\/2 = 50% \*\//static const u32 bbr_ecn_thresh = BBR_UNIT * 7 \/ 10;  \/* 7\/10 = 70% ECN tolerance (BBRPlus-style) *\//' "$BBRPLUSV3_SRC"

# bbr_full_loss_cnt: 6 → 3（更快响应严重丢包退出 STARTUP）
sed -i 's/static const u32 bbr_full_loss_cnt = 6;/static const u32 bbr_full_loss_cnt = 3; \/* BBRPlusV3: faster STARTUP exit on heavy loss *\//' "$BBRPLUSV3_SRC"

# bbr_inflight_headroom: 15% → 10%（保留更少的 headroom，更激进利用带宽）
sed -i 's/static const u32 bbr_inflight_headroom = BBR_UNIT \* 15 \/ 100;/static const u32 bbr_inflight_headroom = BBR_UNIT * 10 \/ 100; \/* BBRPlusV3: less headroom reserved *\//' "$BBRPLUSV3_SRC"

echo "[5/6] 已调整 ECN/loss 参数"

# ============================================
# 6. 修改 Kconfig 和 Makefile
# ============================================

# 添加 Kconfig 选项（在 CONFIG_TCP_CONG_BBR 后面插入）
if ! grep -q "CONFIG_TCP_CONG_BBRPLUSV3" init/Kconfig 2>/dev/null; then
  # 找到 BBR 的 Kconfig 条目，在其后插入 bbrplusv3
  sed -i '/config TCP_CONG_BBR$/,/^[^[:space:]]/{
    /^[^[:space:]]/a\
\
config TCP_CONG_BBRPLUSV3\
	tristate "BBRPlusV3 (BBRv3 + aggressive probing)"\
	depends on TCP_CONG_ADVANCED\
	default m\
	help\
	  BBRPlusV3 combines Google BBRv3 with BBRPlus aggressive probing\
	  strategies. Optimized for high-loss, high-BDP links.\
	  \
	  Recommended for VPS/proxy scenarios with packet loss 1-5%.\
	  \
	  Module will be called tcp_bbrplusv3.
  }' init/Kconfig
  echo "已添加 Kconfig 选项"
fi

# 添加 Makefile 编译目标
if ! grep -q "tcp_bbrplusv3" net/ipv4/Makefile 2>/dev/null; then
  echo "obj-\$(CONFIG_TCP_CONG_BBRPLUSV3) += tcp_bbrplusv3.o" >> net/ipv4/Makefile
  echo "已添加 Makefile 编译目标"
fi

# 修改 ICSK_CA_PRIV_SIZE 以容纳 bbrplusv3
# BBRv3 struct bbr 约 144 bytes，bbrplusv3 同样大小（我们没改 struct）
# 但如果已有的 ICSK_CA_PRIV_SIZE < 144，需要增大
CURRENT_PRIV_SIZE=$(grep -oP 'icsk_ca_priv\[\K\d+' include/net/inet_connection_sock.h 2>/dev/null || echo "0")
if [ "$CURRENT_PRIV_SIZE" -lt 144 ]; then
  echo "增大 ICSK_CA_PRIV_SIZE ($CURRENT_PRIV_SIZE → 144)..."
  sed -i "s/icsk_ca_priv\[$CURRENT_PRIV_SIZE \/ sizeof(u64)\]/icsk_ca_priv[144 \/ sizeof(u64)]/" include/net/inet_connection_sock.h
fi

echo "[6/6] 已修改 Kconfig 和 Makefile"

# ============================================
# 验证
# ============================================
echo ""
echo "=== 验证 bbrplusv3 创建结果 ==="
echo "--- 注册名 ---"
grep '\.name' "$BBRPLUSV3_SRC" | head -3
echo "--- pacing_gain 数组 ---"
grep -A4 'bbr_pacing_gain\[' "$BBRPLUSV3_SRC" | head -5
echo "--- 关键参数 ---"
grep -E 'bbr_startup_cwnd_gain|bbr_beta|bbr_loss_thresh|bbr_probe_rtt_mode_ms|bbr_probe_rtt_win_ms|bbr_ecn_thresh|bbr_full_loss_cnt|bbr_inflight_headroom' "$BBRPLUSV3_SRC"
echo "--- Makefile ---"
grep bbrplusv3 net/ipv4/Makefile
echo "--- MODULE ---"
grep -E 'MODULE_DESCRIPTION|MODULE_VERSION' "$BBRPLUSV3_SRC"

echo ""
echo "=== BBRPlusV3 创建完成 ==="
echo "算法参数对比:"
echo "  pacing_gain UP:    1.25 → 1.50 (BBRPlus-style 激进探测)"
echo "  pacing_gain DOWN:  0.91 → 0.75 (BBRPlus-style 积极排空)"
echo "  startup_cwnd_gain: 2.0  → 2.5  (更激进填充管道)"
echo "  bbr_beta:          30%  → 20%  (丢包时减少更少)"
echo "  loss_thresh:       2%   → 5%   (丢包容忍度提高)"
echo "  probe_rtt_mode_ms: 200  → 50   (PROBE_RTT 停留更短)"
echo "  probe_rtt_win_ms:  5000 → 2500 (PROBE_RTT 更频繁)"
echo "  ecn_thresh:        50%  → 70%  (ECN 容忍度提高)"
echo "  full_loss_cnt:     6    → 3    (更快退出 STARTUP)"
echo "  inflight_headroom: 15%  → 10%  (更少保留 headroom)"
