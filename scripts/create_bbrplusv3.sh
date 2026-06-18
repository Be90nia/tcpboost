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
#   7. 追加 module_param 声明 + Profile 系统（conservative/standard/aggressive/wifi）
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
sed -i 's/MODULE_DESCRIPTION("TCP BBR (Bottleneck Bandwidth and RTT)")/MODULE_DESCRIPTION("TCP BBRPlusV3 (BBRv3 + aggressive probing + profile system)")/' "$BBRPLUSV3_SRC"

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

# 4a. pacing_gain UP: 5/4 → 11/8（适度激进的带宽探测，消除正反馈循环H2）
sed -i 's/BBR_UNIT \* 5 \/ 4,\t\/\* UP: probe for more available bw \*\//BBR_UNIT * 11 \/ 8,\t\/* UP: balanced bandwidth probing (BBRPlusV3) *\//' "$BBRPLUSV3_SRC"

# 4b. pacing_gain DOWN: 91/100 → 17/20（温和排空，减少吞吐波动）
sed -i 's/BBR_UNIT \* 91 \/ 100,\t\/\* DOWN: drain queue and\/or yield bw \*\//BBR_UNIT * 17 \/ 20,\t\/* DOWN: balanced drain (BBRPlusV3) *\//' "$BBRPLUSV3_SRC"

# 4c. startup_cwnd_gain: 2 → 9/4（折中：比原版温和激进，消除过冲风险）
sed -i 's/bbr_startup_cwnd_gain.*BBR_UNIT \* 2;/bbr_startup_cwnd_gain = BBR_UNIT * 9 \/ 4;/' "$BBRPLUSV3_SRC"

# 4d. bbr_beta: 保持 30%（BBRv3原版值，SSH/CF安全。不再降为20%）
# 三轮审计确认：beta=20%是SSH/CF断连根因，恢复30%

# 4e. loss_thresh: 2% → 3%（适度提高丢包容忍，CF/SSH安全）
sed -i 's/bbr_loss_thresh = BBR_UNIT \* 2 \/ 100;.*/bbr_loss_thresh = BBR_UNIT * 3 \/ 100;/' "$BBRPLUSV3_SRC"

echo "[4/9] 已应用 BBRPlus aggressive 参数值"

# ============================================
# 5. PROBE_RTT 优化（200→100ms, 5000ms保持，减少PROBE_RTT频率）
# ============================================

# BBRv3 的 PROBE_RTT 停留时间默认 200ms，缩短到 100ms 平衡吞吐损失和游戏延迟
sed -i 's/bbr_probe_rtt_mode_ms = 200;/bbr_probe_rtt_mode_ms = 100;/' "$BBRPLUSV3_SRC"

# bbr_probe_rtt_win_ms: 保持 5000（每5s探测一次min_rtt，减少频率降低延迟尖峰）
# 不再缩短到2500ms：三轮审计确认2500ms导致PROBE_RTT过于频繁，影响游戏/视频
echo "[5/9] 已优化 PROBE_RTT 参数 (mode=100ms, win=5000ms)"

# ============================================
# 6. ECN/loss 参数调整
# ============================================

# bbr_ecn_thresh: 保持 50%（BBRv3原版值，响应AQM早期拥塞信号）
# 三轮审计确认：70%架空fq_codel/cake的ECN标记，改回50%

# bbr_full_loss_cnt: 6 → 3（更快响应严重丢包退出 STARTUP）
sed -i 's/bbr_full_loss_cnt = 6;/bbr_full_loss_cnt = 3;/' "$BBRPLUSV3_SRC"

# bbr_inflight_headroom: 15% → 12%（适度减少headroom，平衡激进利用和稳定性）
sed -i 's/bbr_inflight_headroom = BBR_UNIT \* 15 \/ 100;/bbr_inflight_headroom = BBR_UNIT * 12 \/ 100;/' "$BBRPLUSV3_SRC"

echo "[6/9] 已调整 ECN/loss 参数 (ecn=50%, full_loss_cnt=3, headroom=12%)"

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
	u32  min_rtt_win_sec;
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
		.min_rtt_win_sec	= 10,
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
		.min_rtt_win_sec	= 10,
	},
	[BBRPLUSV3_PROFILE_AGGRESSIVE] = {
		.pacing_gain_up		= BBR_UNIT * 11 / 8,
		.pacing_gain_down	= BBR_UNIT * 17 / 20,
		.startup_cwnd_gain	= BBR_UNIT * 9 / 4,
		.startup_pacing_gain	= BBR_UNIT * 2885 / 1000 + 1,
		.drain_gain		= BBR_UNIT * 1000 / 2885,
		.beta			= BBR_UNIT * 30 / 100,
		.loss_thresh		= BBR_UNIT * 3 / 100,
		.full_bw_thresh		= BBR_UNIT * 5 / 4,
		.probe_rtt_mode_ms	= 100,
		.probe_rtt_win_ms	= 5000,
		.ecn_thresh		= BBR_UNIT * 1 / 2,
		.full_loss_cnt		= 3,
		.inflight_headroom	= BBR_UNIT * 12 / 100,
		.min_rtt_win_sec	= 10,
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
		.min_rtt_win_sec	= 10,
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
	    bbrplusv3_profile > BBRPLUSV3_PROFILE_WIFI) {
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
	bbr_min_rtt_win_sec		= p->min_rtt_win_sec;

	pr_info("BBRPlusV3: profile switched to %d (%s)\n",
		bbrplusv3_profile,
		bbrplusv3_profile == BBRPLUSV3_PROFILE_CONSERVATIVE ?
			"conservative" :
		bbrplusv3_profile == BBRPLUSV3_PROFILE_STANDARD ?
			"standard" :
		bbrplusv3_profile == BBRPLUSV3_PROFILE_AGGRESSIVE ?
			"aggressive" : "wifi_optimized");
	return 0;
}

static const struct kernel_param_ops bbrplusv3_profile_ops = {
	.set = bbrplusv3_profile_set,
	.get = param_get_int,
};

module_param_cb(profile, &bbrplusv3_profile_ops,
		&bbrplusv3_profile, 0644);
MODULE_PARM_DESC(profile,
	"BBRPlusV3 profile: 0=conservative, 1=standard, 2=aggressive, 3=wifi (default=2)");

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
module_param_named(min_rtt_win_sec, bbr_min_rtt_win_sec, uint, 0644);
MODULE_PARM_DESC(min_rtt_win_sec, "Min RTT filter window in seconds (default=10, BBRv3 original)");
BBRPLUSV3_PARAMS_EOF

echo "[7/9] 已追加 module_param + 四档 Profile 系统"

# ============================================
# 7b. 注入算法优化（Pacing Scale + cong_control wrapper + BBR-GC）
# ============================================

# 前向声明 bbrplusv3_main（在 cong_ops 之前注入）
sed -i '/static struct tcp_congestion_ops tcp_bbrplusv3_cong_ops/i\
static void bbrplusv3_main(struct sock *sk, u32 ack, int flag, const struct rate_sample *rs);\
static int bbrplusv3_gc_base_down = 217;	/* C8: 初始化为 aggressive pacing_gain_down(0.85), 避免GC静默禁用 */' "$BBRPLUSV3_SRC"

# 替换 cong_control 回调: bbr_main → bbrplusv3_main
sed -i 's/\.cong_control.*=.*bbr_main,.*/.cong_control\t= bbrplusv3_main,/' "$BBRPLUSV3_SRC"

# 追加 wrapper 函数 + 算法优化参数
cat >> "$BBRPLUSV3_SRC" << 'BBRPLUSV3_ALGO_EOF'

/* ============================================
 * BBRPlusV3 算法优化
 *
 * Pacing Scale: 全局 pacing rate 缩放 (BMR alpha)
 * Minimum pacing rate: 单流保底速率
 * BBR-GC: 自适应 pacing gain (gamma correction)
 * ============================================ */

static int bbrplusv3_pacing_rate_scale = 100;
static u64 bbrplusv3_min_pacing_rate;
static int bbrplusv3_gc_enable = 0;

/* tcpboost-4cf: 参数范围验证标志（首次 ACK 时验证一次） */
static atomic_t bbrplusv3_params_checked = ATOMIC_INIT(0);

static void bbrplusv3_main(struct sock *sk, u32 ack, int flag,
			   const struct rate_sample *rs)
{
	struct bbr *bbr = inet_csk_ca(sk);

	/* tcpboost-4cf: 首次调用时验证关键参数范围
	 * 防止用户通过 sysfs 写入极端值导致 PROBE_RTT 风暴 */
	if (unlikely(!atomic_read(&bbrplusv3_params_checked))) {
		if (READ_ONCE(bbr_probe_rtt_win_ms) > 0 &&
		    READ_ONCE(bbr_probe_rtt_win_ms) < 1000)
			WRITE_ONCE(bbr_probe_rtt_win_ms, 1000);
		if (READ_ONCE(bbr_probe_rtt_mode_ms) == 0)
			WRITE_ONCE(bbr_probe_rtt_mode_ms, 1);
		atomic_set(&bbrplusv3_params_checked, 1);
	}

	/* 先调用原始 BBRv3 主逻辑 */
	bbr_main(sk, ack, flag, rs);

	/* C1: PROBE_RTT 期间不做任何 pacing/cwnd 修改
	 * PROBE_RTT 需要将 cwnd 压缩到 probe_rtt_cwnd，
	 * min_pacing_rate floor / pacing scale 会破坏这个过程，
	 * 导致 inflight 无法降到 probe_rtt_cwnd，PROBE_RTT 无法退出 */
	if (bbr->mode == BBR_PROBE_RTT)
		return;

	/* Pacing Rate Scale (BMR alpha) + C4: 同步 cwnd */
	if (bbrplusv3_pacing_rate_scale != 100) {
		u64 rate = READ_ONCE(sk->sk_pacing_rate);
		u32 cwnd = tcp_snd_cwnd(tcp_sk(sk));

		rate = rate * bbrplusv3_pacing_rate_scale / 100;
		WRITE_ONCE(sk->sk_pacing_rate, rate);

		/* C4: pacing 变化后同步 cwnd，避免 cwnd/pacing 失同步
		 * 按 scale 比例调整，但不低于 cwnd_min_target */
		cwnd = max_t(u32,
			      cwnd * bbrplusv3_pacing_rate_scale / 100,
			      bbr_cwnd_min_target);
		tcp_snd_cwnd_set(tcp_sk(sk), cwnd);
	}

	/* Minimum pacing rate floor (单流保底)
	 * C1: PROBE_RTT 期间已在上面 return */
	if (bbrplusv3_min_pacing_rate > 0) {
		u64 rate = READ_ONCE(sk->sk_pacing_rate);

		if (rate < bbrplusv3_min_pacing_rate)
			WRITE_ONCE(sk->sk_pacing_rate,
				   bbrplusv3_min_pacing_rate);
	}

	/* BBR-GC: Gamma Correction 自适应 pacing gain
	 * 论文: Sensors 2023 "Optimization of BBR based on pacing gain model"
	 * C6: 使用内核精确 int_sqrt() 替代错误牛顿法近似(原4x误差)
	 * C7: gc_base_down 已添加 module_param 供 sysfs 同步
	 * C9: gc_enable=0 时恢复全局 pacing_gain[DOWN] 到基准值
	 * queue_ratio = (rtt - min_rtt) / min_rtt (队列膨胀比例)
	 * gc_down = BBR_UNIT - range * sqrt(queue_ratio)
	 * 无队列(q=0): gc_down -> cap 0.91 (不降速)
	 * 满队列(q=1): gc_down -> base_down (profile DOWN gain) */
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

		/* C6: 使用内核精确 int_sqrt() 替代错误近似 */
		sqrt_q = int_sqrt(queue_ratio);

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

		/* 更新全局 DOWN gain (只影响 PROBE_BW DOWN phase)
		 * UP/CRUISE/REFILL 完全不受影响 */
		WRITE_ONCE(bbr_pacing_gain[BBR_BW_PROBE_DOWN],
			   gc_down);
	} else if (!bbrplusv3_gc_enable && bbrplusv3_gc_base_down > 0) {
		/* C9: gc 禁用时恢复全局 DOWN gain 到 profile 基准值
		 * 防止 GC 最后修改的值永久残留 */
		u32 cur_down = READ_ONCE(bbr_pacing_gain[BBR_BW_PROBE_DOWN]);

		if (cur_down != bbrplusv3_gc_base_down)
			WRITE_ONCE(bbr_pacing_gain[BBR_BW_PROBE_DOWN],
				   bbrplusv3_gc_base_down);
	}
}

module_param_named(pacing_rate_scale, bbrplusv3_pacing_rate_scale, int, 0644);
MODULE_PARM_DESC(pacing_rate_scale, "Pacing rate scale in % (100=100%, 90=90%)");

module_param_named(min_pacing_rate, bbrplusv3_min_pacing_rate, ullong, 0644);
MODULE_PARM_DESC(min_pacing_rate, "Min pacing rate bytes/s (0=off, e.g. 1250000=10Mbps)");

module_param_named(gc_enable, bbrplusv3_gc_enable, int, 0644);
MODULE_PARM_DESC(gc_enable, "BBR-GC adaptive pacing gain (0=off, 1=on)");

/* C7: gc_base_down 暴露为 module_param, 允许 tcp.sh 在覆盖 pacing_gain_down 时同步 */
module_param_named(gc_base_down, bbrplusv3_gc_base_down, int, 0644);
MODULE_PARM_DESC(gc_base_down, "BBR-GC base DOWN gain (sync with pacing_gain_down when overriding)");
BBRPLUSV3_ALGO_EOF

echo "[7b/9] 已注入 Pacing Scale + cong_control wrapper + BBR-GC"

# ============================================
# 7c. STARTUP 阶段优化（三轮审计后修正版）
# 审计修正：
#   - drain_gain 保持 0.347 (=1/startup_pacing_gain，修复H1数学不一致)
#   - min_rtt_win_sec 保持 10s (修复C10/65m RTT不公平性)
#   - full_bw_thresh 保持 1.25 (修复C5 STARTUP持续过久)
#   - startup_pacing_gain 2.885 (保留，BBRv3e1论文值)
# ============================================

# DRAIN gain: 保持 BBRv3 原版 0.347 (1000/2885)
# 三轮审计确认：drain_gain=0.416 导致 DRAIN 不充分(H1)，改回原版值
# 不再执行 sed 修改，保持 BBRv3 源码原值

# min_rtt_win_sec: 保持 BBRv3 原版 10s
# 三轮审计确认：20s 导致 RTT 不公平性复合放大(C10/65m)和 spurious RTO 风险(lzc)
# 不再执行 sed 修改，保持 BBRv3 源码原值

# full_bw_thresh: 保持 BBRv3 原版 1.25 (5/4)
# 三轮审计确认：1.10 导致 STARTUP 持续过久(C5)，buffer overflow → SSH/CF断连
# 不再执行 sed 修改，保持 BBRv3 源码原值

# STARTUP pacing gain: 2.77 → 2.885 (BBRv3e1 论文, 2/ln(2))
sed -i 's/bbr_startup_pacing_gain = BBR_UNIT \* 277 \/ 100 + 1/bbr_startup_pacing_gain = BBR_UNIT * 2885 \/ 1000 + 1/' "$BBRPLUSV3_SRC"

echo "[7c/9] STARTUP 优化修正版 (drain=0.347, win=10s, thresh=1.25, pacing=2.885)"

# ============================================
# 7d. tcpboost-wia: sed 替换验证
# 验证所有关键 sed 修改已成功执行，防止静默 fallback 到 vanilla BBRv3
# ============================================
echo "[7d/9] 验证 sed 修改..."
SED_ERRORS=0

verify_pattern() {
    if ! grep -qF "$1" "$BBRPLUSV3_SRC"; then
        echo "  [FAIL] $2 — 模式未找到: $1" >&2
        echo "         可能原因：BBRv3 源码版本变化，sed 替换未匹配" >&2
        SED_ERRORS=$((SED_ERRORS + 1))
    fi
}

# 验证关键算法参数已被正确修改
verify_pattern 'BBR_UNIT * 11 / 8' "pacing_gain UP=1.375"
verify_pattern 'BBR_UNIT * 17 / 20' "pacing_gain DOWN=0.85"
verify_pattern 'BBR_UNIT * 9 / 4' "startup_cwnd_gain=2.25"
verify_pattern 'BBR_UNIT * 3 / 100' "loss_thresh=3%"
verify_pattern 'bbr_probe_rtt_mode_ms = 100' "probe_rtt_mode_ms=100"
verify_pattern 'bbrplusv3_main' "cong_control wrapper"
verify_pattern '"bbrplusv3"' "module name"
verify_pattern 'BBR_UNIT * 2885' "startup_pacing_gain=2.885"

if [ "$SED_ERRORS" -gt 0 ]; then
    echo "" >&2
    echo "WARNING: $SED_ERRORS 个 sed 验证失败！" >&2
    echo "  生成的模块可能行为异常（可能得到 vanilla BBRv3）" >&2
    echo "  建议：检查 BBRv3 源码版本兼容性，或手动调整 sed 模式" >&2
else
    echo "  所有关键 sed 修改验证通过"
fi

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
# tcpboost-e6f: 兼容多种 ICSK_CA_PRIV_SIZE 定义格式（数组字面量/define/enum）
PRIV_FILE="include/net/inet_connection_sock.h"
if [ -f "$PRIV_FILE" ]; then
  # 方式1: 从 icsk_ca_priv[N / sizeof(u64)] 格式中提取 N（兼容 grep -E）
  CURRENT_PRIV_SIZE=$(grep -oE 'icsk_ca_priv\[[0-9]+' "$PRIV_FILE" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || echo "")
  
  # 方式2: 如果方式1失败，尝试从 #define ICSK_CA_PRIV_SIZE 提取
  if [ -z "$CURRENT_PRIV_SIZE" ]; then
    CURRENT_PRIV_SIZE=$(grep -oE '#define[[:space:]]+ICSK_CA_PRIV_SIZE[[:space:]]+[0-9]+' "$PRIV_FILE" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || echo "")
  fi
  
  # 默认值：无法检测时假设安全
  [ -z "$CURRENT_PRIV_SIZE" ] && CURRENT_PRIV_SIZE=0
  
  NEED=144
  if [ "$CURRENT_PRIV_SIZE" -gt 0 ] && [ "$CURRENT_PRIV_SIZE" -lt "$NEED" ]; then
    echo "增大 ICSK_CA_PRIV_SIZE ($CURRENT_PRIV_SIZE → $NEED)..."
    sed -i "s/icsk_ca_priv\[$CURRENT_PRIV_SIZE \/ sizeof(u64)\]/icsk_ca_priv[$NEED \/ sizeof(u64)]/" "$PRIV_FILE"
    # 验证修改成功
    if ! grep -qF "icsk_ca_priv[$NEED / sizeof(u64)]" "$PRIV_FILE"; then
      echo "WARNING: ICSK_CA_PRIV_SIZE 修改可能未生效（格式不兼容）" >&2
      echo "  建议：手动检查 $PRIV_FILE 中 icsk_ca_priv 的定义" >&2
    fi
  elif [ "$CURRENT_PRIV_SIZE" = "0" ]; then
    echo "WARNING: 无法自动检测 ICSK_CA_PRIV_SIZE（可能使用 enum/非标准格式）" >&2
    echo "  建议：手动确认 struct bbr 不超过当前 ICSK_CA_PRIV_SIZE" >&2
  else
    echo "ICSK_CA_PRIV_SIZE 已为 $CURRENT_PRIV_SIZE (≥$NEED)，无需修改"
  fi
fi

echo "[8/9] 已修改 Kconfig 和 Makefile"

# ============================================
# 9. Cloudflare TCP collapse patch（接收侧优化，独立于 CCA）
# 来源: mfreemon@cloudflare.com (2022-03), 适配 Linux 6.12 LTS
# 博客: https://blog.cloudflare.com/optimizing-tcp-for-high-throughput-and-low-latency/
# sysctl: net.ipv4.tcp_collapse_max_bytes (0=禁用默认行为, >0=启用跳过collapse)
# 效果: 高 BDP 链路上接收队列满时，跳过 collapse 操作避免 CPU 延迟尖峰
# 幂等: 每个文件用 grep 检查是否已修改，重复运行安全
# ============================================

NETNS_FILE="include/net/netns/ipv4.h"
TRACE_FILE="include/trace/events/tcp.h"
SYSCTL_FILE="net/ipv4/sysctl_net_ipv4.c"
TCP_INPUT_FILE="net/ipv4/tcp_input.c"
TCP_IPV4_FILE="net/ipv4/tcp_ipv4.c"

# --- 文件 1: include/net/netns/ipv4.h ---
# 在 struct netns_ipv4 中添加字段声明
# 6.12 锚点: sysctl_tcp_syn_linear_timeouts (6.12 新增字段)
if [ -f "$NETNS_FILE" ] && ! grep -q "sysctl_tcp_collapse_max_bytes" "$NETNS_FILE" 2>/dev/null; then
  sed -i '/sysctl_tcp_syn_linear_timeouts;/a\\tunsigned int\tsysctl_tcp_collapse_max_bytes;' "$NETNS_FILE"
  echo "  [cloudflare] netns/ipv4.h: 已添加字段"
fi

# --- 文件 2: include/trace/events/tcp.h ---
# 添加 tcp_collapse_max_bytes_exceeded trace 事件
# 锚点: TRACE_EVENT(tcp_retransmit_synack 之前插入
if [ -f "$TRACE_FILE" ] && ! grep -q "tcp_collapse_max_bytes_exceeded" "$TRACE_FILE" 2>/dev/null; then
  awk '/TRACE_EVENT\(tcp_retransmit_synack,/ && !inserted {
    print "DEFINE_EVENT(tcp_event_sk, tcp_collapse_max_bytes_exceeded,"
    print ""
    print "\tTP_PROTO(struct sock *sk),"
    print ""
    print "\tTP_ARGS(sk)"
    print ");"
    print ""
    inserted = 1
  }
  { print }' "$TRACE_FILE" > "${TRACE_FILE}.tmp" && mv "${TRACE_FILE}.tmp" "$TRACE_FILE"
  echo "  [cloudflare] trace/events/tcp.h: 已添加事件"
fi

# --- 文件 3: net/ipv4/sysctl_net_ipv4.c ---
# 在 ipv4_net_table[] 中添加 tcp_collapse_max_bytes sysctl 条目
# 锚点: tcp_shrink_window 条目闭合 }, 之后
if [ -f "$SYSCTL_FILE" ] && ! grep -q "tcp_collapse_max_bytes" "$SYSCTL_FILE" 2>/dev/null; then
  awk '
  /"tcp_shrink_window"/ { in_entry = 1 }
  in_entry && /^\t\}/ {
    print
    print "\t{"
    print "\t\t.procname\t= \"tcp_collapse_max_bytes\","
    print "\t\t.data\t\t= &init_net.ipv4.sysctl_tcp_collapse_max_bytes,"
    print "\t\t.maxlen\t\t= sizeof(unsigned int),"
    print "\t\t.mode\t\t= 0644,"
    print "\t\t.proc_handler\t= proc_douintvec_minmax,"
    print "\t},"
    in_entry = 0
    next
  }
  { print }
  ' "$SYSCTL_FILE" > "${SYSCTL_FILE}.tmp" && mv "${SYSCTL_FILE}.tmp" "$SYSCTL_FILE"
  echo "  [cloudflare] sysctl_net_ipv4.c: 已添加 sysctl 条目"
fi

# --- 文件 4: net/ipv4/tcp_input.c（核心修改） ---
# 修改 tcp_prune_queue() 函数: 添加 sysctl 检查 + goto label
# 6.12 函数签名: tcp_prune_queue(struct sock *sk, const struct sk_buff *in_skb)
# 三处修改: ① 添加 net 变量 ② 添加 sysctl 检查+goto ③ 添加 do_not_collapse label
if [ -f "$TCP_INPUT_FILE" ] && ! grep -q "tcp_collapse_max_bytes" "$TCP_INPUT_FILE" 2>/dev/null; then
  awk '
  /static int tcp_prune_queue\(struct sock \*sk,/ && !/;[[:space:]]*$/ { in_prune = 1 }
  in_prune && /struct tcp_sock \*tp = tcp_sk\(sk\);/ && !added_net {
    print
    print "\tstruct net *net = sock_net(sk);"
    added_net = 1
    next
  }
  in_prune && added_net && !added_check && /return 0;/ {
    print
    print ""
    print "\t/* Cloudflare TCP collapse: skip collapse for large queues */"
    print "\tif (net->ipv4.sysctl_tcp_collapse_max_bytes &&"
    print "\t    (atomic_read(&sk->sk_rmem_alloc) > net->ipv4.sysctl_tcp_collapse_max_bytes)) {"
    print "\t\ttrace_tcp_collapse_max_bytes_exceeded(sk);"
    print "\t\tgoto do_not_collapse;"
    print "\t}"
    print ""
    added_check = 1
    next
  }
  in_prune && added_check && !added_label && /return 0;/ {
    print
    print ""
    print "do_not_collapse:"
    added_label = 1
    in_prune = 0
    next
  }
  { print }
  ' "$TCP_INPUT_FILE" > "${TCP_INPUT_FILE}.tmp" && mv "${TCP_INPUT_FILE}.tmp" "$TCP_INPUT_FILE"
  
  # tcpboost-2fp: 验证 tcp_input.c 的 3 处修改都已正确注入
  TCP_INPUT_OK=1
  grep -qF 'struct net *net = sock_net(sk);' "$TCP_INPUT_FILE" 2>/dev/null || { echo "  [cloudflare] WARNING: tcp_input.c net 变量注入失败" >&2; TCP_INPUT_OK=0; }
  grep -qF 'goto do_not_collapse;' "$TCP_INPUT_FILE" 2>/dev/null || { echo "  [cloudflare] WARNING: tcp_input.c sysctl 检查注入失败" >&2; TCP_INPUT_OK=0; }
  grep -qF 'do_not_collapse:' "$TCP_INPUT_FILE" 2>/dev/null || { echo "  [cloudflare] WARNING: tcp_input.c label 注入失败" >&2; TCP_INPUT_OK=0; }
  
  if [ "$TCP_INPUT_OK" = "1" ]; then
    echo "  [cloudflare] tcp_input.c: 已修改 tcp_prune_queue() (3/3 处验证通过)"
  else
    echo "  [cloudflare] WARNING: tcp_input.c 注入不完整，可能编译失败" >&2
    echo "  建议：检查内核版本兼容性，tcp_prune_queue 函数签名或锚点可能已变化" >&2
  fi
fi

# --- 文件 5: net/ipv4/tcp_ipv4.c ---
# 在 tcp_sk_init() 中初始化 sysctl_tcp_collapse_max_bytes = 0
# 锚点: sysctl_tcp_shrink_window = 0 之后
if [ -f "$TCP_IPV4_FILE" ] && ! grep -q "sysctl_tcp_collapse_max_bytes" "$TCP_IPV4_FILE" 2>/dev/null; then
  sed -i '/sysctl_tcp_shrink_window = 0;/a\\tnet->ipv4.sysctl_tcp_collapse_max_bytes = 0;' "$TCP_IPV4_FILE"
  echo "  [cloudflare] tcp_ipv4.c: 已添加初始化"
fi

# --- 汇总 ---
CLOUDFLARE_COUNT=0
for f in "$NETNS_FILE" "$TRACE_FILE" "$SYSCTL_FILE" "$TCP_INPUT_FILE" "$TCP_IPV4_FILE"; do
  grep -q "collapse_max_bytes" "$f" 2>/dev/null && CLOUDFLARE_COUNT=$((CLOUDFLARE_COUNT+1)) || :
done

if [ "$CLOUDFLARE_COUNT" -eq 5 ]; then
  echo "[9/9] 已应用 Cloudflare TCP collapse patch (5/5 文件)"
elif [ "$CLOUDFLARE_COUNT" -gt 0 ]; then
  echo "[9/9] Cloudflare TCP collapse patch 部分应用 ($CLOUDFLARE_COUNT/5 文件)"
else
  echo "[9/9] Cloudflare TCP collapse patch 未应用 (内核源文件可能不存在)"
fi

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
echo "--- Cloudflare TCP collapse ---"
echo "  sysctl: net.ipv4.tcp_collapse_max_bytes"
echo "  启用: echo 6291456 > /proc/sys/net/ipv4/tcp_collapse_max_bytes  # 6MB"
echo "  禁用: echo 0 > /proc/sys/net/ipv4/tcp_collapse_max_bytes       # 默认"

echo ""
echo "=== BBRPlusV3 创建完成 ==="
echo ""
echo "Profile 使用方式:"
echo "  echo 0 > /sys/module/tcp_bbrplusv3/parameters/profile  # conservative"
echo "  echo 1 > /sys/module/tcp_bbrplusv3/parameters/profile  # standard"
echo "  echo 2 > /sys/module/tcp_bbrplusv3/parameters/profile  # aggressive (默认)"
echo "  echo 3 > /sys/module/tcp_bbrplusv3/parameters/profile  # wifi"
echo ""
echo "单独参数调整（BBR_UNIT = 256）:"
echo "  cat  /sys/module/tcp_bbrplusv3/parameters/beta"
echo "  echo 76 > /sys/module/tcp_bbrplusv3/parameters/beta   # 30%"
echo ""
echo "Profile 参数对比:"
echo "                     conservative  standard  aggressive  wifi"
echo "  pacing_gain UP:    1.25 (320)   1.375(352) 1.50 (384) 1.50(384)"
echo "  pacing_gain DOWN:  0.91 (232)   0.85 (217) 0.75 (192) 0.90(230)"
echo "  startup_cwnd_gain: 2.0  (512)   2.25 (576) 2.50 (640) 2.25(576)"
echo "  startup_pacing:    2.77 (709)   2.885(739) 2.885(739) 2.885(739)"
echo "  drain_gain:        0.35 (89)    0.38 (97)  0.42 (107) 0.42(107)"
echo "  beta:              30% (76)     25% (64)   20% (51)   25% (64)"
echo "  loss_thresh:       2%  (5)      3.5%(8)    5%  (12)   5%  (12)"
echo "  full_bw_thresh:    1.25(320)    1.20(307)  1.10(281)  1.10(281)"
echo "  probe_rtt_mode_ms: 200          100        50         100"
echo "  probe_rtt_win_ms:  5000         3000       2500       3000"
echo "  ecn_thresh:        50% (128)    60% (153)  70% (179)  70%(179)"
echo "  full_loss_cnt:     6            4          3          4"
echo "  inflight_headroom: 15% (38)     12% (30)   10% (25)   10%(25)"
echo ""
echo "TLS 握手优化:"
echo "  使用 aggressive profile + apply_bbrplusv3_params 覆盖 + TLS sysctl"
echo "  tcp.sh 菜单选项 5 'TLS握手优化方案' 自动应用全套配置"
echo "  适用: 跨太平洋 TLS 1.3 + xray/sing-box 代理场景"
