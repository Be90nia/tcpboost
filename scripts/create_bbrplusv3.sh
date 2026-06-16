#!/bin/bash
# create_bbrplusv3.sh — 基于 BBRv3 tcp_bbr.c 创建 bbrplusv3 算法
#
# 工作流程：
#   1. 复制 tcp_bbr.c → tcp_bbrplusv3.c
#   2. 修改模块名、算法名、版本标识
#   3. 去掉可调参数的 const 限定符（为 module_param 做准备）
#   4. 应用 BBRPlus aggressive 参数值（默认 profile）
#   5. PROBE_RTT 优化
#   6. ECN/loss 参数调整
#   7. 追加 module_param 声明 + 三档 Profile 系统
#   8. 修改 Kconfig 和 Makefile 注册新算法
#
# Profile 系统（运行时切换）：
#   echo 0 > /sys/module/tcp_bbrplusv3/parameters/profile  # conservative
#   echo 1 > /sys/module/tcp_bbrplusv3/parameters/profile  # standard
#   echo 2 > /sys/module/tcp_bbrplusv3/parameters/profile  # aggressive (默认)
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
echo "[1/9] 已复制 $BBR_SRC → $BBRPLUSV3_SRC"

# ============================================
# 2. 修改模块名和算法标识
# ============================================

# 模块描述
sed -i 's/MODULE_DESCRIPTION("TCP BBR (Bottleneck Bandwidth and RTT)")/MODULE_DESCRIPTION("TCP BBRPlusV3 (BBRv3 + aggressive probing + ACD + profile system)")/' "$BBRPLUSV3_SRC"

# 添加 MODULE_VERSION（标识 BBRPlusV3，不改 BBR_VERSION 避免影响算法内部逻辑）
if ! grep -q 'MODULE_VERSION' "$BBRPLUSV3_SRC" 2>/dev/null; then
  sed -i '/MODULE_DESCRIPTION/a\MODULE_VERSION("2.0-bbrplusv3");' "$BBRPLUSV3_SRC"
fi

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

echo "[2/9] 已修改模块名和注册信息"

# ============================================
# 3. 去掉可调参数的 const 限定符（为 module_param 做准备）
# ============================================

# pacing_gain 数组
sed -i 's/^static const int bbr_pacing_gain\[\]/static int bbr_pacing_gain[]/' "$BBRPLUSV3_SRC"

# 需要可调的参数列表
TUNABLE_PARAMS="bbr_startup_cwnd_gain bbr_cwnd_gain bbr_startup_pacing_gain \
bbr_beta bbr_loss_thresh bbr_full_loss_cnt bbr_full_bw_thresh \
bbr_ecn_thresh bbr_inflight_headroom bbr_drain_gain \
bbr_probe_rtt_mode_ms bbr_probe_rtt_win_ms bbr_min_rtt_win_sec"

for param in $TUNABLE_PARAMS; do
  sed -i -E "s/static const (int|u32) ${param} /static \1 ${param} /" "$BBRPLUSV3_SRC"
done

echo "[3/9] 已去掉可调参数的 const 限定符"

# ============================================
# 4. 应用 BBRPlus aggressive 参数值（默认 profile）
# ============================================

# 4a. pacing_gain UP: 5/4 → 3/2（更激进的带宽探测）
sed -i 's/BBR_UNIT \* 5 \/ 4,\t\/\* UP: probe for more available bw \*\//BBR_UNIT * 3 \/ 2,\t\/* UP: aggressive bandwidth probing (BBRPlus-style) *\//' "$BBRPLUSV3_SRC"

# 4b. pacing_gain DOWN: 91/100 → 3/4（更积极地排空队列）
sed -i 's/BBR_UNIT \* 91 \/ 100,\t\/\* DOWN: drain queue and\/or yield bw \*\//BBR_UNIT * 3 \/ 4,\t\/* DOWN: aggressive drain (BBRPlus-style) *\//' "$BBRPLUSV3_SRC"

# 4c. startup_cwnd_gain: 2 → 5/2（BBRPlus 核心思想：STARTUP 时更激进地填充管道）
sed -i 's/bbr_startup_cwnd_gain.*BBR_UNIT \* 2;/bbr_startup_cwnd_gain = BBR_UNIT * 5 \/ 2;/' "$BBRPLUSV3_SRC"

# 4d. bbr_beta: 30% → 20%（丢包时减少更少，保持更高吞吐）
sed -i 's/bbr_beta = BBR_UNIT \* 30 \/ 100;/bbr_beta = BBR_UNIT * 20 \/ 100;/' "$BBRPLUSV3_SRC"

# 4e. loss_thresh: 2% → 5%（丢包容忍度提高，高丢包链路不会过早降速）
sed -i 's/bbr_loss_thresh = BBR_UNIT \* 2 \/ 100;.*/bbr_loss_thresh = BBR_UNIT * 5 \/ 100;/' "$BBRPLUSV3_SRC"

echo "[4/9] 已应用 BBRPlus aggressive 参数值"

# ============================================
# 5. PROBE_RTT 优化（200→50ms, 5000→2500ms）
# ============================================

# BBRv3 的 PROBE_RTT 停留时间默认 200ms，缩短到 50ms 减少吞吐量损失
sed -i 's/bbr_probe_rtt_mode_ms = 200;/bbr_probe_rtt_mode_ms = 50;/' "$BBRPLUSV3_SRC"

# bbr_probe_rtt_win_ms: 5000 → 2500（更频繁地探测 min_rtt）
# 每次只停 50ms（vs BBRv3 的 200ms），总吞吐量损失更小
sed -i 's/bbr_probe_rtt_win_ms = 5000;/bbr_probe_rtt_win_ms = 2500;/' "$BBRPLUSV3_SRC"

echo "[5/9] 已优化 PROBE_RTT 参数"

# ============================================
# 6. ECN/loss 参数调整
# ============================================

# bbr_ecn_thresh: 50% → 70%（ECN 标记容忍度提高）
sed -i 's/bbr_ecn_thresh = BBR_UNIT \* 1 \/ 2;.*/bbr_ecn_thresh = BBR_UNIT * 7 \/ 10;/' "$BBRPLUSV3_SRC"

# bbr_full_loss_cnt: 6 → 3（更快响应严重丢包退出 STARTUP）
sed -i 's/bbr_full_loss_cnt = 6;/bbr_full_loss_cnt = 3;/' "$BBRPLUSV3_SRC"

# bbr_inflight_headroom: 15% → 10%（保留更少的 headroom，更激进利用带宽）
sed -i 's/bbr_inflight_headroom = BBR_UNIT \* 15 \/ 100;/bbr_inflight_headroom = BBR_UNIT * 10 \/ 100;/' "$BBRPLUSV3_SRC"

echo "[6/9] 已调整 ECN/loss 参数"

# ============================================
# 7. 追加 module_param 声明 + 三档 Profile 系统
# ============================================

cat >> "$BBRPLUSV3_SRC" << 'BBRPLUSV3_PARAMS_EOF'

/* ============================================
 * BBRPlusV3: Module Parameters + Profile System
 *
 * 运行时可通过 /sys/module/tcp_bbrplusv3/parameters/ 调整
 *
 * Profile 切换（批量更新所有参数）:
 *   echo 0 > .../profile  (conservative: 接近 BBRv3 原版)
 *   echo 1 > .../profile  (standard: 温和增强)
 *   echo 2 > .../profile  (aggressive: 激进探测，默认)
 *
 * 单独参数也可覆盖 profile 值（BBR_UNIT = 256）:
 *   echo 76 > .../beta          (76/256 = 30%)
 *   echo 13 > .../loss_thresh   (13/256 = 5%)
 * ============================================ */

/* Profile 枚举 */
#define BBRPLUSV3_PROFILE_CONSERVATIVE	0
#define BBRPLUSV3_PROFILE_STANDARD	1
#define BBRPLUSV3_PROFILE_AGGRESSIVE	2
#define BBRPLUSV3_PROFILE_WIFI		3
#define BBRPLUSV3_PROFILE_TLS_OPTIMIZED	4

/* Profile 参数预设表 */
struct bbrplusv3_profile_params {
	int  pacing_gain_up;
	int  pacing_gain_down;
	int  startup_cwnd_gain;
	int  startup_pacing_gain;
	int  drain_gain;
	u32  beta;
	u32  loss_thresh;
	u32  full_bw_thresh;
	u32  probe_rtt_mode_ms;
	u32  probe_rtt_win_ms;
	u32  ecn_thresh;
	u32  full_loss_cnt;
	u32  inflight_headroom;
};

static const struct bbrplusv3_profile_params
bbrplusv3_profile_table[] = {
	[BBRPLUSV3_PROFILE_CONSERVATIVE] = {
		.pacing_gain_up		= BBR_UNIT * 5 / 4,
		.pacing_gain_down	= BBR_UNIT * 91 / 100,
		.startup_cwnd_gain	= BBR_UNIT * 2,
		.startup_pacing_gain	= BBR_UNIT * 277 / 100 + 1,
		.drain_gain		= BBR_UNIT * 1000 / 2885,
		.beta			= BBR_UNIT * 30 / 100,
		.loss_thresh		= BBR_UNIT * 2 / 100,
		.full_bw_thresh		= BBR_UNIT * 5 / 4,
		.probe_rtt_mode_ms	= 200,
		.probe_rtt_win_ms	= 5000,
		.ecn_thresh		= BBR_UNIT * 1 / 2,
		.full_loss_cnt		= 6,
		.inflight_headroom	= BBR_UNIT * 15 / 100,
	},
	[BBRPLUSV3_PROFILE_STANDARD] = {
		.pacing_gain_up		= BBR_UNIT * 11 / 8,
		.pacing_gain_down	= BBR_UNIT * 17 / 20,
		.startup_cwnd_gain	= BBR_UNIT * 9 / 4,
		.startup_pacing_gain	= BBR_UNIT * 2885 / 1000 + 1,
		.drain_gain		= BBR_UNIT * 1100 / 2885,
		.beta			= BBR_UNIT * 25 / 100,
		.loss_thresh		= BBR_UNIT * 35 / 1000,
		.full_bw_thresh		= BBR_UNIT * 6 / 5,
		.probe_rtt_mode_ms	= 100,
		.probe_rtt_win_ms	= 3000,
		.ecn_thresh		= BBR_UNIT * 3 / 5,
		.full_loss_cnt		= 4,
		.inflight_headroom	= BBR_UNIT * 12 / 100,
	},
	[BBRPLUSV3_PROFILE_AGGRESSIVE] = {
		.pacing_gain_up		= BBR_UNIT * 3 / 2,
		.pacing_gain_down	= BBR_UNIT * 3 / 4,
		.startup_cwnd_gain	= BBR_UNIT * 5 / 2,
		.startup_pacing_gain	= BBR_UNIT * 2885 / 1000 + 1,
		.drain_gain		= BBR_UNIT * 1200 / 2885,
		.beta			= BBR_UNIT * 20 / 100,
		.loss_thresh		= BBR_UNIT * 5 / 100,
		.full_bw_thresh		= BBR_UNIT * 11 / 10,
		.probe_rtt_mode_ms	= 50,
		.probe_rtt_win_ms	= 2500,
		.ecn_thresh		= BBR_UNIT * 7 / 10,
		.full_loss_cnt		= 3,
		.inflight_headroom	= BBR_UNIT * 10 / 100,
	},
	[BBRPLUSV3_PROFILE_WIFI] = {
		.pacing_gain_up		= BBR_UNIT * 3 / 2,
		.pacing_gain_down	= BBR_UNIT * 9 / 10,
		.startup_cwnd_gain	= BBR_UNIT * 9 / 4,
		.startup_pacing_gain	= BBR_UNIT * 2885 / 1000 + 1,
		.drain_gain		= BBR_UNIT * 1200 / 2885,
		.beta			= BBR_UNIT * 25 / 100,
		.loss_thresh		= BBR_UNIT * 5 / 100,
		.full_bw_thresh		= BBR_UNIT * 11 / 10,
		.probe_rtt_mode_ms	= 100,
		.probe_rtt_win_ms	= 3000,
		.ecn_thresh		= BBR_UNIT * 7 / 10,
		.full_loss_cnt		= 4,
		.inflight_headroom	= BBR_UNIT * 10 / 100,
	},
	[BBRPLUSV3_PROFILE_TLS_OPTIMIZED] = {
		/* TLS 握手优化: STARTUP 温和(2.77/2.0 避免队列堆积)
		 * + PROBE_BW standard(1.375/0.85 保持带宽探测)
		 * + 丢包容忍(5%) + PROBE_RTT 优化(100ms/5s 减少延迟峰)
		 * + BBRPlus beta(30%) 经典恢复
		 * 适用: 跨太平洋 TLS 1.3 握手稳定性 + xray/sing-box 代理 */
		.pacing_gain_up		= BBR_UNIT * 11 / 8,
		.pacing_gain_down	= BBR_UNIT * 17 / 20,
		.startup_cwnd_gain	= BBR_UNIT * 2,
		.startup_pacing_gain	= BBR_UNIT * 277 / 100 + 1,
		.drain_gain		= BBR_UNIT * 1100 / 2885,
		.beta			= BBR_UNIT * 30 / 100,
		.loss_thresh		= BBR_UNIT * 5 / 100,
		.full_bw_thresh		= BBR_UNIT * 6 / 5,
		.probe_rtt_mode_ms	= 100,
		.probe_rtt_win_ms	= 5000,
		.ecn_thresh		= BBR_UNIT * 3 / 5,
		.full_loss_cnt		= 4,
		.inflight_headroom	= BBR_UNIT * 12 / 100,
	},
};

static int bbrplusv3_profile = BBRPLUSV3_PROFILE_AGGRESSIVE;

/* Profile 切换回调：批量更新所有参数 */
static int bbrplusv3_profile_set(const char *val,
				  const struct kernel_param *kp)
{
	int old = bbrplusv3_profile;
	int ret = param_set_int(val, kp);
	const struct bbrplusv3_profile_params *p;

	if (ret)
		return ret;

	if (bbrplusv3_profile < 0 ||
	    bbrplusv3_profile > BBRPLUSV3_PROFILE_TLS_OPTIMIZED) {
		bbrplusv3_profile = old;
		return -EINVAL;
	}

	p = &bbrplusv3_profile_table[bbrplusv3_profile];

	bbr_pacing_gain[BBR_BW_PROBE_UP]	= p->pacing_gain_up;
	bbr_pacing_gain[BBR_BW_PROBE_DOWN]	= p->pacing_gain_down;
	bbrplusv3_gc_base_down		= p->pacing_gain_down;
	bbr_startup_cwnd_gain		= p->startup_cwnd_gain;
	bbr_startup_pacing_gain		= p->startup_pacing_gain;
	bbr_drain_gain			= p->drain_gain;
	bbr_beta			= p->beta;
	bbr_loss_thresh			= p->loss_thresh;
	bbr_full_bw_thresh		= p->full_bw_thresh;
	bbr_probe_rtt_mode_ms		= p->probe_rtt_mode_ms;
	bbr_probe_rtt_win_ms		= p->probe_rtt_win_ms;
	bbr_ecn_thresh			= p->ecn_thresh;
	bbr_full_loss_cnt		= p->full_loss_cnt;
	bbr_inflight_headroom		= p->inflight_headroom;

	pr_info("BBRPlusV3: profile switched to %d (%s)\n",
		bbrplusv3_profile,
		bbrplusv3_profile == BBRPLUSV3_PROFILE_CONSERVATIVE ?
			"conservative" :
		bbrplusv3_profile == BBRPLUSV3_PROFILE_STANDARD ?
			"standard" :
		bbrplusv3_profile == BBRPLUSV3_PROFILE_AGGRESSIVE ?
			"aggressive" :
		bbrplusv3_profile == BBRPLUSV3_PROFILE_WIFI ?
			"wifi_optimized" : "tls_optimized");
	return 0;
}

static const struct kernel_param_ops bbrplusv3_profile_ops = {
	.set = bbrplusv3_profile_set,
	.get = param_get_int,
};

module_param_cb(profile, &bbrplusv3_profile_ops,
		&bbrplusv3_profile, 0644);
MODULE_PARM_DESC(profile,
	"BBRPlusV3 profile: 0=conservative, 1=standard, 2=aggressive, 3=wifi, 4=tls_optimized (default=2)");

/* 单独可调参数（覆盖 profile 值，BBR_UNIT = 256） */
module_param_named(pacing_gain_up,
	bbr_pacing_gain[BBR_BW_PROBE_UP], int, 0644);
module_param_named(pacing_gain_down,
	bbr_pacing_gain[BBR_BW_PROBE_DOWN], int, 0644);
module_param_named(startup_cwnd_gain, bbr_startup_cwnd_gain, int, 0644);
module_param_named(startup_pacing_gain, bbr_startup_pacing_gain, int, 0644);
module_param_named(drain_gain, bbr_drain_gain, int, 0644);
module_param_named(beta, bbr_beta, uint, 0644);
module_param_named(loss_thresh, bbr_loss_thresh, uint, 0644);
module_param_named(full_bw_thresh, bbr_full_bw_thresh, uint, 0644);
module_param_named(probe_rtt_mode_ms, bbr_probe_rtt_mode_ms, uint, 0644);
module_param_named(probe_rtt_win_ms, bbr_probe_rtt_win_ms, uint, 0644);
module_param_named(ecn_thresh, bbr_ecn_thresh, uint, 0644);
module_param_named(full_loss_cnt, bbr_full_loss_cnt, uint, 0644);
module_param_named(inflight_headroom, bbr_inflight_headroom, uint, 0644);
BBRPLUSV3_PARAMS_EOF

echo "[7/9] 已追加 module_param + 四档 Profile 系统"

# ============================================
# 7b. 注入算法优化（BBR-ACD + Pacing Scale + cong_control wrapper）
# ============================================

# 前向声明 bbrplusv3_main（在 cong_ops 之前注入）
sed -i '/static struct tcp_congestion_ops tcp_bbrplusv3_cong_ops/i\
static void bbrplusv3_main(struct sock *sk, u32 ack, int flag, const struct rate_sample *rs);' "$BBRPLUSV3_SRC"

# 替换 cong_control 回调: bbr_main → bbrplusv3_main
sed -i 's/\.cong_control.*=.*bbr_main,.*/.cong_control\t= bbrplusv3_main,/' "$BBRPLUSV3_SRC"

# 追加 wrapper 函数 + 算法优化参数
cat >> "$BBRPLUSV3_SRC" << 'BBRPLUSV3_ALGO_EOF'

/* ============================================
 * BBRPlusV3 算法优化
 *
 * BBR-ACD: 丢包+RTT恶化=真拥塞(降速), 丢包+RTT稳定=随机丢包(补偿)
 * Pacing Scale: 全局 pacing rate 缩放 (BMR alpha)
 * ============================================ */

static int bbrplusv3_acd_enable;
static int bbrplusv3_acd_rtt_factor = 200;
static int bbrplusv3_acd_congestion_scale = 70;
static int bbrplusv3_acd_cwnd_reduce = 1;
static int bbrplusv3_pacing_rate_scale = 100;
static u64 bbrplusv3_min_pacing_rate;
static int bbrplusv3_gc_enable = 0;
static int bbrplusv3_gc_base_down;	/* profile 原始 DOWN gain, GC 基准值 */

static void bbrplusv3_main(struct sock *sk, u32 ack, int flag,
			   const struct rate_sample *rs)
{
	struct bbr *bbr = inet_csk_ca(sk);

	bbr_main(sk, ack, flag, rs);

	/* BBR-ACD: 真拥塞 vs 随机丢包双向检测
	 * 论文: Electronics 2020, 9(1), 136 (BBR-ACD)
	 * 真拥塞 (rtt > factor×min_rtt): pacing × congestion_scale/100 (减速)
	 * 随机丢包 (rtt ≤ factor×min_rtt): pacing × 105/100 (补偿，保持吞吐)
	 * 跨太平洋链路 1-5% 丢包多为随机丢包(光放大器 ASE 噪声)，不应降速 */
	if (bbrplusv3_acd_enable && rs->losses > 0 && rs->rtt_us > 0 &&
	    bbr->min_rtt_us > 0) {
		u32 threshold = bbr->min_rtt_us *
				bbrplusv3_acd_rtt_factor / 100;

		if (rs->rtt_us > threshold) {
			/* 真拥塞: RTT 膨胀说明队列堆积，pacing 减速 */
			u64 rate = READ_ONCE(sk->sk_pacing_rate);

			rate = rate * bbrplusv3_acd_congestion_scale / 100;
			WRITE_ONCE(sk->sk_pacing_rate, rate);

			/* beta 加权 cwnd 缩减 (优化 D)
			 * 仅在 Recovery 首入时执行一次, 避免持续减半
			 * cwnd_new = max(cwnd × beta, 4) */
			if (bbrplusv3_acd_cwnd_reduce &&
			    bbr->prev_ca_state != TCP_CA_Recovery &&
			    inet_csk(sk)->icsk_ca_state == TCP_CA_Recovery) {
				struct tcp_sock *tp = tcp_sk(sk);
				u32 cwnd = tcp_snd_cwnd(tp);
				u32 new_cwnd = max_t(u32,
					(u64)cwnd * bbr_beta / BBR_UNIT, 4);

				tcp_snd_cwnd_set(tp, new_cwnd);
			}
		} else {
			/* 随机丢包: RTT 正常说明非拥塞，pacing 轻微补偿 */
			u64 rate = READ_ONCE(sk->sk_pacing_rate);

			rate = rate * 105 / 100;
			WRITE_ONCE(sk->sk_pacing_rate, rate);
		}
	}

	/* Pacing Rate Scale (BMR alpha) */
	if (bbrplusv3_pacing_rate_scale != 100) {
		u64 rate = READ_ONCE(sk->sk_pacing_rate);

		rate = rate * bbrplusv3_pacing_rate_scale / 100;
		WRITE_ONCE(sk->sk_pacing_rate, rate);
	}

	/* Minimum pacing rate floor (单流保底) */
	if (bbrplusv3_min_pacing_rate > 0) {
		u64 rate = READ_ONCE(sk->sk_pacing_rate);

		if (rate < bbrplusv3_min_pacing_rate)
			WRITE_ONCE(sk->sk_pacing_rate,
				   bbrplusv3_min_pacing_rate);
	}

	/* BBR-GC: Gamma Correction 自适应 pacing gain (优化 E)
	 * 论文: Sensors 2023 "Optimization of BBR based on pacing gain model"
	 * 改进: 用 sqrt 近似 gamma=2, 基于 queue_ratio 平滑过渡
	 * queue_ratio = (rtt - min_rtt) / min_rtt (队列膨胀比例)
	 * gc_down = BBR_UNIT - range × sqrt(queue_ratio)
	 * 无队列(q=0): gc_down → cap 0.91 (不降速)
	 * 满队列(q=1): gc_down → base_down (profile DOWN gain)
	 * sqrt 用整数牛顿法 1 次迭代近似 */
	if (bbrplusv3_gc_enable && rs->rtt_us > 0 &&
	    bbr->min_rtt_us > 0 && bbrplusv3_gc_base_down > 0) {
		u32 queue_ratio = 0;
		u32 base_down = bbrplusv3_gc_base_down;
		u32 range = BBR_UNIT - base_down;
		u32 sqrt_q;
		u32 gc_down;

		if (rs->rtt_us > bbr->min_rtt_us) {
			queue_ratio = (u32)((u64)(rs->rtt_us - bbr->min_rtt_us) *
					    BBR_UNIT / bbr->min_rtt_us);
			if (queue_ratio > BBR_UNIT)
				queue_ratio = BBR_UNIT;
		}

		/* sqrt 近似 (牛顿法 1 次迭代) */
		if (queue_ratio == 0) {
			sqrt_q = 0;
		} else {
			u32 x = queue_ratio / 2 + 1;

			x = (x + queue_ratio / x) / 2;
			sqrt_q = x;
		}

		gc_down = BBR_UNIT - range * sqrt_q / BBR_UNIT;

		/* Cap at 0.91 (保留温和排空, 避免 0-drain 上传退化) */
		{
			u32 gc_cap = BBR_UNIT * 91 / 100;

			if (gc_down > gc_cap)
				gc_down = gc_cap;
		}
		/* 不低于 base_down (保持最小排空能力) */
		if (gc_down < base_down)
			gc_down = base_down;

		/* 直接更新全局 DOWN gain
		 * 只影响 PROBE_BW DOWN phase
		 * UP/CRUISE/REFILL 完全不受影响 */
		WRITE_ONCE(bbr_pacing_gain[BBR_BW_PROBE_DOWN],
			   gc_down);
	}
}

module_param_named(acd_enable, bbrplusv3_acd_enable, int, 0644);
MODULE_PARM_DESC(acd_enable, "BBR-ACD delay-gradient congestion detection (0=off, 1=on)");

module_param_named(acd_rtt_factor, bbrplusv3_acd_rtt_factor, int, 0644);
MODULE_PARM_DESC(acd_rtt_factor, "ACD RTT threshold in % (200=2x min_rtt, 真拥塞判据)");

module_param_named(acd_congestion_scale, bbrplusv3_acd_congestion_scale, int, 0644);
MODULE_PARM_DESC(acd_congestion_scale, "ACD pacing scale on true congestion in % (70=减速到70%)");

module_param_named(acd_cwnd_reduce, bbrplusv3_acd_cwnd_reduce, int, 0644);
MODULE_PARM_DESC(acd_cwnd_reduce, "ACD beta-weighted cwnd reduction on true congestion (0=off, 1=on)");

module_param_named(pacing_rate_scale, bbrplusv3_pacing_rate_scale, int, 0644);
MODULE_PARM_DESC(pacing_rate_scale, "Pacing rate scale in % (100=100%, 90=90%)");

module_param_named(min_pacing_rate, bbrplusv3_min_pacing_rate, ullong, 0644);
MODULE_PARM_DESC(min_pacing_rate, "Min pacing rate bytes/s (0=off, e.g. 1250000=10Mbps)");

module_param_named(gc_enable, bbrplusv3_gc_enable, int, 0644);
MODULE_PARM_DESC(gc_enable, "BBR-GC adaptive pacing gain (0=off, 1=on)");
BBRPLUSV3_ALGO_EOF

echo "[7b/9] 已注入 BBR-ACD + Pacing Scale + cong_control wrapper + BBR-GC"

# ============================================
# 7c. STARTUP 阶段优化（单流性能改进）
# 基于 tsunami-v3 基准验证 (616 vs 494 Mbps) + nanqinlang STARTUP 抗早退:
#   - drain_gain 0.347→0.416: 温和 DRAIN（tsunami-v3 验证）
#   - min_rtt_win 10→20s: 长 RTT 链路更稳定（tsunami-v3）
#   - full_bw_thresh 1.25→2.0: STARTUP 抗早退（nanqinlang）
#   - startup_pacing_gain 2.77→2.885: 更快爬升（BBRv3e1）
# ============================================

# DRAIN gain: 0.347 → 0.416 (tsunami-v3 验证值)
sed -i 's/bbr_drain_gain = BBR_UNIT \* 1000 \/ 2885/bbr_drain_gain = BBR_UNIT * 1200 \/ 2885/' "$BBRPLUSV3_SRC"

# min_rtt 窗口: 10s → 20s (tsunami-v3, 长 RTT 链路 min_rtt 估值更稳定)
sed -i 's/bbr_min_rtt_win_sec = 10/bbr_min_rtt_win_sec = 20/' "$BBRPLUSV3_SRC"

# full_bw_thresh: 1.25 → 1.10 (降低增长判定阈值, STARTUP 充分探测带宽后再退出)
# BBR STARTUP 退出条件: 连续 full_bw_cnt(3) 个 round 带宽增长不到 full_bw_thresh
# 原版 1.25 要求每 round 增长 25% 才算"显著增长"(重置计数器)
# 改为 1.10 只要 10% 增长即可, 避免 STARTUP 过早退出导致 full_bw 估计偏低
# 注: 之前的 2.0 方向反了 — 翻倍才算"显著"导致第 3 个 round 就退出 STARTUP
sed -i 's/bbr_full_bw_thresh = BBR_UNIT \* 5 \/ 4/bbr_full_bw_thresh = BBR_UNIT * 11 \/ 10/' "$BBRPLUSV3_SRC"

# STARTUP pacing gain: 2.77 → 2.885 (BBRv3e1 论文, 2/ln(2))
sed -i 's/bbr_startup_pacing_gain = BBR_UNIT \* 277 \/ 100 + 1/bbr_startup_pacing_gain = BBR_UNIT * 2885 \/ 1000 + 1/' "$BBRPLUSV3_SRC"

echo "[7c/9] 已优化 STARTUP/DRAIN (tsunami-v3+nanqinlang: drain=0.416, win=20s, thresh=1.10, pacing=2.885)"

# ============================================
# 8. 修改 Kconfig 和 Makefile
# ============================================

# 添加 Kconfig 选项（在 net/ipv4/Kconfig 中 TCP_CONG_BBR 后面插入）
KCONFIG_FILE="net/ipv4/Kconfig"
if [ ! -f "$KCONFIG_FILE" ]; then
  echo "警告: 未找到 $KCONFIG_FILE，跳过 Kconfig 修改"
else
if ! grep -q "CONFIG_TCP_CONG_BBRPLUSV3" "$KCONFIG_FILE" 2>/dev/null; then
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
	  Supports runtime profile switching (conservative/standard/aggressive)\
	  via /sys/module/tcp_bbrplusv3/parameters/profile.\
	  \
	  Recommended for VPS/proxy scenarios with packet loss 1-5%.\
	  \
	  Module will be called tcp_bbrplusv3.
  }' "$KCONFIG_FILE"
  echo "已添加 Kconfig 选项到 $KCONFIG_FILE"
fi
fi

# 添加 Makefile 编译目标
if ! grep -q "tcp_bbrplusv3" net/ipv4/Makefile 2>/dev/null; then
  echo "obj-\$(CONFIG_TCP_CONG_BBRPLUSV3) += tcp_bbrplusv3.o" >> net/ipv4/Makefile
  echo "已添加 Makefile 编译目标"
fi

# 修改 ICSK_CA_PRIV_SIZE 以容纳 bbrplusv3
# BBRv3 struct bbr 约 144 bytes，bbrplusv3 同样大小（我们没改 struct）
# 使用动态检测，兼容任意当前值
PRIV_FILE="include/net/inet_connection_sock.h"
if [ -f "$PRIV_FILE" ]; then
  CURRENT_PRIV_SIZE=$(grep -oP 'icsk_ca_priv\[\K\d+' "$PRIV_FILE" 2>/dev/null || echo "0")
  NEED=144
  if [ "$CURRENT_PRIV_SIZE" -lt "$NEED" ]; then
    echo "增大 ICSK_CA_PRIV_SIZE ($CURRENT_PRIV_SIZE → $NEED)..."
    sed -i "s/icsk_ca_priv\[$CURRENT_PRIV_SIZE \/ sizeof(u64)\]/icsk_ca_priv[$NEED \/ sizeof(u64)]/" "$PRIV_FILE"
  else
    echo "ICSK_CA_PRIV_SIZE 已为 $CURRENT_PRIV_SIZE (≥$NEED)，无需修改"
  fi
fi

echo "[8/9] 已修改 Kconfig 和 Makefile"

# ============================================
# 验证
# ============================================
echo ""
echo "=== 验证 bbrplusv3 创建结果 ==="
echo "--- 注册名 ---"
grep '\.name' "$BBRPLUSV3_SRC" | head -3
echo ""
echo "--- MODULE 版本 ---"
grep -E 'MODULE_DESCRIPTION|MODULE_VERSION' "$BBRPLUSV3_SRC"
echo ""
echo "--- pacing_gain 数组（aggressive 默认值）---"
grep -A4 'bbr_pacing_gain\[' "$BBRPLUSV3_SRC" | head -5
echo ""
echo "--- 关键参数（aggressive 默认值）---"
grep -E 'bbr_startup_cwnd_gain =|bbr_drain_gain =|bbr_beta =|bbr_loss_thresh =|bbr_full_bw_thresh =|bbr_probe_rtt_mode_ms =|bbr_probe_rtt_win_ms =|bbr_ecn_thresh =|bbr_full_loss_cnt =|bbr_inflight_headroom =' "$BBRPLUSV3_SRC" | grep -v 'profile_table\|struct\|\.' | head -12
echo ""
echo "--- Profile 系统 ---"
PARAM_COUNT=$(grep -c 'module_param' "$BBRPLUSV3_SRC")
echo "  $PARAM_COUNT 个 module_param 声明"
grep 'MODULE_PARM_DESC(profile' "$BBRPLUSV3_SRC"
echo ""
echo "--- Makefile ---"
grep bbrplusv3 net/ipv4/Makefile

echo ""
echo "=== BBRPlusV3 创建完成 ==="
echo ""
echo "Profile 使用方式:"
echo "  echo 0 > /sys/module/tcp_bbrplusv3/parameters/profile  # conservative"
echo "  echo 1 > /sys/module/tcp_bbrplusv3/parameters/profile  # standard"
echo "  echo 2 > /sys/module/tcp_bbrplusv3/parameters/profile  # aggressive (默认)"
echo "  echo 3 > /sys/module/tcp_bbrplusv3/parameters/profile  # wifi"
echo "  echo 4 > /sys/module/tcp_bbrplusv3/parameters/profile  # tls_optimized"
echo ""
echo "单独参数调整（BBR_UNIT = 256）:"
echo "  cat  /sys/module/tcp_bbrplusv3/parameters/beta"
echo "  echo 76 > /sys/module/tcp_bbrplusv3/parameters/beta   # 30%"
echo ""
echo "Profile 参数对比:"
echo "                     conservative  standard  aggressive  wifi      tls_opt"
echo "  pacing_gain UP:    1.25 (320)   1.375(352) 1.50 (384) 1.50(384) 1.375(352)"
echo "  pacing_gain DOWN:  0.91 (232)   0.85 (217) 0.75 (192) 0.90(230) 0.85 (217)"
echo "  startup_cwnd_gain: 2.0  (512)   2.25 (576) 2.50 (640) 2.25(576) 2.0  (512)"
echo "  startup_pacing:    2.77 (709)   2.885(739) 2.885(739) 2.885(739) 2.77(709)"
echo "  drain_gain:        0.35 (89)    0.38 (97)  0.42 (107) 0.42(107) 0.38 (97)"
echo "  beta:              30% (76)     25% (64)   20% (51)   25% (64)  30% (76)"
echo "  loss_thresh:       2%  (5)      3.5%(8)    5%  (12)   5%  (12)  5%  (12)"
echo "  full_bw_thresh:    1.25(320)    1.20(307)  1.10(281)  1.10(281) 1.20(307)"
echo "  probe_rtt_mode_ms: 200          100        50         100       100"
echo "  probe_rtt_win_ms:  5000         3000       2500       3000      5000"
echo "  ecn_thresh:        50% (128)    60% (153)  70% (179)  70%(179)  60% (153)"
echo "  full_loss_cnt:     6            4          3          4         4"
echo "  inflight_headroom: 15% (38)     12% (30)   10% (25)   10%(25)   12% (30)"
echo ""
echo "tls_optimized profile 特点:"
echo "  - STARTUP 温和(2.77/2.0): 避免握手期队列堆积, TLS 握手成功率↑"
echo "  - PROBE_BW standard(1.375/0.85): 保持跨太平洋带宽探测能力"
echo "  - 丢包容忍(5%) + PROBE_RTT 优化(100ms/5s): 减少延迟峰"
echo "  - BBR-ACD 双向 pacing: 真拥塞减速 + 随机丢包补偿"
echo "  适用: 跨太平洋 TLS 1.3 + xray/sing-box 代理场景"
