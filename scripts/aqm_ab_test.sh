#!/bin/bash
# scripts/aqm_ab_test.sh — AQM hardening 三臂×两腿 A/B (bd yve, backlog 验证战役 Wave-0)
#
# 矩阵: fq(基线) | fq_codel | cake  ×  loss(0.5%) | clean(净腿), 每腿 LEG_SEC 秒
# 判据: 三指标 (total/min/加载 RTT) 任一 qdisc 显著优于 fq -> KEEP 候选 (PM 裁决)
#
# 拓扑 (双 netns 路由, 被测 qdisc 位于瓶颈队列, 无 ifb):
#   ns_srv(10.0.1.1) --(ve_s|v_s) host 路由 --(v_c|ve_c) ns_cli(10.0.2.1)
#   数据方向 srv->cli: ve_s egress [tbf 限速 + 被测 qdisc, 瓶颈队列在此] -> v_s ingress -> 路由 -> v_c egress [netem 延迟/丢包, 无 rate]
#   ACK  方向 cli->srv: ve_c egress -> v_c ingress -> 路由 -> v_s egress [netem 延迟, 无 rate]
#   RTT = 2xRTT_HALF_MS 固定 150ms (禁抖动: 75ms±75ms 均匀抖动会在 bbrplusv3 rto-1 门下诱发
#   虚假 RTO 风暴, cwnd 钉 11-13 包 + rcv_space 钉 14480, 全流塌缩 0.6Mbps, run 39039732757 实证;
#   战役原始复现配方即固定双向 150ms)
#
# 为什么 netem 不与被测 qdisc 串同一设备链: netem enqueue 即按时间戳入 tfifo,
#   恒吃掉批量队列, 下游 qdisc 永远近空载 -> 三臂假性无差异 (120.79 VPS smoke 实证后撤离)。
#   且 ifb 冷插 quirk + netem-on-ifb 兼容性在 7.2 guest 内核两次烧穿 CI (run 38840464139/38853683704),
#   纯 egress 方案两条失败路径全删。
# 数据来源: 本 harness 自采 (iperf3 -J 逐流 + ss -tin 循环 + ping 循环), 不依赖旧 soak harness JSONL。
# 环境政策 2026-10-16: 实验一律 CI QEMU guest, 禁用用户 VPS。
#
# env (vng 命令行烤入, guest 不继承宿主 env):
#   LEG_SEC 每腿秒数(默认 1200)  SHAPE_REQ 请求限速(默认 200Mbit, TCG 容量不足自动下调)
#   ARMS 参赛 qdisc 列表(默认 "fq fq_codel cake", 烟雾探针可传 "fq_codel cake")
#   BYTES 单流字节(默认 12.5M)  RTT_HALF_MS 单向均值 ms(默认 75)  LOSS_PCT loss 腿丢包率(默认 0.5)
#   LEGS 腿规格列表 (bd 7hn, 默认 "loss clean" 保留战役配方): 简名或全格式 TAG:JIT:LOSS:CC:PARAMS
#     简名: loss/clean/jloss/jclean; JIT=1 在 v_s(ACK向) 挂 delay H Jms(0-2H 均匀抖动, 复刻 run 39039732757 现场)
#     CC 非空则三 netns 运行时切 net.ipv4.tcp_congestion_control; PARAMS 形如 "rto_fc_enable=1" 写
#     /sys/module/tcp_bbrplusv3/parameters/ (7hn 用它隔离 rto-cut: 同腿 CC 下 enable 1 vs 0)
#   JITTER_MS 抖动幅度 ms(默认 75)
#   OUT 输出目录(默认 /var/log/tcpboost-soak/aqm_ab)
set -u

LEG_SEC="${LEG_SEC:-1200}"
ARMS="${ARMS:-fq fq_codel cake}"
BYTES="${BYTES:-12.5M}"
SHAPE_REQ="${SHAPE_REQ:-200Mbit}"
RTT_HALF_MS="${RTT_HALF_MS:-75}"
LOSS_PCT="${LOSS_PCT:-0.5}"
LEGS="${LEGS:-loss clean}"
JITTER_MS="${JITTER_MS:-75}"
OUT="${OUT:-/var/log/tcpboost-soak/aqm_ab}"
LOGS="$OUT/logs"
DATA="$OUT/data"
SRV_IP=10.0.1.1
CLI_IP=10.0.2.1
PERFLOW_TIMEOUT=300
mkdir -p "$LOGS" "$DATA"
exec > >(tee -a "$LOGS/harness.log") 2>&1

SHAPE=0   # 校准后的实际限速 Mbit

fail() { echo "FATAL: $*"; exit 3; }

# 腿简名 -> 全格式 TAG:JIT:LOSS:CC:PARAMS
leg_expand() {
  case "$1" in
    loss)   echo "loss:0:1::" ;;
    clean)  echo "clean:0:0::" ;;
    jloss)  echo "jloss:1:1::" ;;
    jclean) echo "jclean:1:0::" ;;
    *)      echo "$1" ;;
  esac
}

# PARAMS 写 /sys/module/tcp_bbrplusv3/parameters/ (内建, sysfs 常驻; fail-fast 防 verify 式假通过)
bpv3_params() {
  local kv p dir=/sys/module/tcp_bbrplusv3/parameters
  [ -n "$1" ] || return 0
  [ -d "$dir" ] || fail "tcp_bbrplusv3 sysfs 缺失 ($dir), 无法写 '$1'"
  for kv in $1; do
    p="${kv%%=*}"
    [ -e "$dir/$p" ] || fail "模块参数不存在: $dir/$p"
    [ -w "$dir/$p" ] || fail "模块参数不可写: $dir/$p"
    echo "${kv#*=}" > "$dir/$p" || fail "写 $dir/$p=${kv#*=} 失败"
  done
  echo "bpv3 params applied: $1"
}

# 三 netns 各自切 CC (netns 建立时从 init_net 拷贝副本, 建立后需逐个改)
set_cc() {
  local cc="$1" ns
  [ -n "$cc" ] || return 0
  sysctl -qw net.ipv4.tcp_congestion_control="$cc" || fail "sysctl CC=$cc (init_net)"
  for ns in ns_srv ns_cli; do
    ip netns exec "$ns" sysctl -qw net.ipv4.tcp_congestion_control="$cc" || fail "sysctl CC=$cc ($ns)"
  done
  echo "CC set: $cc (active: $(sysctl -n net.ipv4.tcp_congestion_control))"
}

qdisc_reset() {
  tc qdisc del dev v_c root 2>/dev/null
  tc qdisc del dev v_s root 2>/dev/null
  ip netns exec ns_srv tc qdisc del dev ve_s root 2>/dev/null
}

cleanup() {
  qdisc_reset
  pkill -x iperf3 2>/dev/null
  ip netns del ns_srv 2>/dev/null
  ip netns del ns_cli 2>/dev/null
  ip link del v_s 2>/dev/null
  ip link del v_c 2>/dev/null
}
trap cleanup EXIT

dump_diag() {
  echo "--- diag dump ---"
  ip -br link 2>&1
  ip route 2>&1
  ip netns exec ns_cli ip route 2>&1
  ip netns exec ns_cli ss -tin 2>&1 | head -20
  tc -s qdisc show dev v_c 2>&1
  tc -s qdisc show dev v_s 2>&1
  ip netns exec ns_srv tc -s qdisc show dev ve_s 2>&1
  echo "--- diag end ---"
}

# 一个 batch: 8 并发 iperf3 下载各 BYTES, 追加 CSV(或 "-" 跳过), stdout 出聚合 Mbps
run_batch() {
  local bl="$1" csv="$2" t0 pids="" i port out part
  part=$(mktemp)
  t0=$(date +%s.%N)
  for i in 0 1 2 3 4 5 6 7; do
    port=$((5201 + i))
    (
      out=$(timeout -k 5 "$PERFLOW_TIMEOUT" ip netns exec ns_cli iperf3 -c "$SRV_IP" -p "$port" -R -n "$BYTES" -J 2>/dev/null)
      if [ -n "$out" ]; then
        printf '%s' "$out" | jq -r --arg b "$bl" --argjson f "$i" --argjson t0 "$t0" --argjson t1 "$(date +%s.%N)" \
          '[$b, $f, (.end.sum_received.seconds // ($t1 - $t0)), ((.end.sum_received.bits_per_second // 0) / 1000000), (.end.sum_sent.retransmits // -1)] | @csv'
      else
        awk -v b="$bl" -v f="$i" -v t="$PERFLOW_TIMEOUT" 'BEGIN{printf "%s,%d,%d,%.3f,-2\n", b, f, t, 800/t}'
      fi
    ) >> "$part" &
    pids="$pids $!"
  done
  wait $pids
  if [ "$csv" != "-" ]; then
    [ -f "$csv" ] || echo "batch,flow,secs,mbps,retrans" > "$csv"
    cat "$part" >> "$csv"
  fi
  awk -F, 'NR>1 && $4+0>0 {s+=$4} END{printf "%.1f", s+0}' "$part"
  rm -f "$part"
}

run_leg() {
  local ARM=$1
  local TAG JIT LOSSFLAG CC PARAMS
  IFS=: read -r TAG JIT LOSSFLAG CC PARAMS <<< "$(leg_expand "$2")"
  local TAGFULL="${ARM}_${TAG}"
  local PID_PING PID_SS PID_TC PID_SSSRV
  local data_netem="delay ${RTT_HALF_MS}ms limit 10000"
  local ack_netem="delay ${RTT_HALF_MS}ms limit 10000"
  [ "$LOSSFLAG" = 1 ] && data_netem="delay ${RTT_HALF_MS}ms loss ${LOSS_PCT}% limit 10000"
  # 7hn: 抖动挂 v_s(ACK 向), 复刻 run 39039732757 现场 (delay H J = 0-2H 均匀)
  [ "$JIT" = 1 ] && ack_netem="delay ${RTT_HALF_MS}ms ${JITTER_MS}ms limit 10000"
  echo "--- leg $TAGFULL start $(date +%s) (jit='$jit' cc='$CC' params='$PARAMS') ---"
  bpv3_params "$PARAMS"
  set_cc "$CC"
  qdisc_reset
  if ! { tc qdisc add dev v_c root netem $data_netem \
         && tc qdisc add dev v_s root netem $ack_netem; }; then
    fail "netem 建立失败 $TAGFULL"
  fi
  # 瓶颈在 ve_s (ns_srv 数据出口): tbf 优先, 拒绝子 graft 时回落 htb (两种都让队列落在被测 qdisc)
  local graft=tbf
  if ip netns exec ns_srv tc qdisc add dev ve_s root handle 1: tbf rate "${SHAPE}Mbit" burst 256kb latency 1000ms 2>/dev/null \
     && ip netns exec ns_srv tc qdisc add dev ve_s parent 1:1 handle 10: "$ARM" 2>/dev/null; then
    :
  else
    qdisc_reset
    tc qdisc add dev v_c root netem $data_netem || fail "netem 重建失败 $TAGFULL"
    tc qdisc add dev v_s root netem $ack_netem || fail "v_s netem 重建失败 $TAGFULL"
    ip netns exec ns_srv tc qdisc add dev ve_s root handle 1: htb default 1 || fail "htb root $TAGFULL"
    ip netns exec ns_srv tc class add dev ve_s parent 1: classid 1:1 htb rate "${SHAPE}Mbit" burst 1mb || fail "htb class $TAGFULL"
    ip netns exec ns_srv tc qdisc add dev ve_s parent 1:1 handle 10: "$ARM" || fail "被测 qdisc $ARM $TAGFULL"
    graft=htb
  fi
  # 连通性 fail-fast: ICMP + 2s TCP 预检 (120.79 VPS SYN 黑洞教训: 诊断后即停, 不烧腿)
  ip netns exec ns_cli ping -c 3 -i 0.3 -W 2 "$SRV_IP" > "$LOGS/ping_base_$TAGFULL.txt" 2>&1 \
    || { dump_diag; fail "ICMP base ping 失败 $TAGFULL"; }
  timeout 15 ip netns exec ns_cli iperf3 -c "$SRV_IP" -p 5201 -R -t 2 -J > "$LOGS/probe_$TAGFULL.json" 2>&1 \
    || { dump_diag; fail "TCP 探针失败 $TAGFULL"; }

  ip netns exec ns_cli ping -i 0.2 -D "$SRV_IP" > "$LOGS/ping_$TAGFULL.txt" 2>&1 &
  PID_PING=$!
  ( while :; do echo "=== $(date +%s)"; ip netns exec ns_cli ss -tin dst "$SRV_IP"; sleep 5; done ) > "$LOGS/ss_$TAGFULL.txt" 2>&1 &
  PID_SS=$!
  # 7hn: 服务端(发送方)采样 — 真发端 cwnd 签名 (cli 侧 cwnd 是 ACK 流, 恒 ~10, 是红鲱鱼)
  ( while :; do echo "=== $(date +%s)"; ip netns exec ns_srv ss -tin dst "$CLI_IP"; sleep 5; done ) > "$LOGS/ss_srv_$TAGFULL.txt" 2>&1 &
  PID_SSSRV=$!
  ( while :; do echo "=== $(date +%s)"; ip netns exec ns_srv tc -s qdisc show dev ve_s; sleep 30; done ) > "$LOGS/tc_$TAGFULL.txt" 2>&1 &
  PID_TC=$!

  local CSV="$DATA/$TAGFULL.csv" deadline b=0 nrows
  deadline=$(( $(date +%s) + LEG_SEC ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    b=$((b + 1))
    run_batch "$b" "$CSV"
  done
  kill "$PID_PING" "$PID_SS" "$PID_SSSRV" "$PID_TC" 2>/dev/null
  # 禁裸 wait: 会等 exec> >(tee) 的 tee 子进程 (等 stdout EOF) -> 死锁 (run 39039732757 实证)
  sleep 1
  ip netns exec ns_srv tc -s qdisc show dev ve_s > "$LOGS/tc_final_$TAGFULL.txt" 2>&1
  nrows=$(wc -l < "$CSV")
  [ "$nrows" -gt 8 ] || { dump_diag; fail "leg $TAGFULL 产出不足 1 批"; }
  qdisc_reset
  sleep 5
  echo "--- leg $TAGFULL done batches=$((nrows - 1)) graft=$graft ---"
}

python3_analyze() {
  python3 - "$DATA" "$LOGS" "$OUT" "$ARMS" <<'PYEOF'
import os, re, sys
from collections import defaultdict

DATA, LOGS, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
ARMS = sys.argv[4].split() if len(sys.argv) > 4 else ['fq', 'fq_codel', 'cake']
# 7hn: 腿规格不再与 ARMS×两腿硬绑, 直接发现已产出的 CSV
TAGS = sorted(f[:-4] for f in os.listdir(DATA) if f.endswith('.csv'))

def load_csv(tag):
    rows = []
    p = os.path.join(DATA, tag + '.csv')
    if not os.path.exists(p):
        return rows
    for ln in open(p, errors='ignore'):
        parts = ln.strip().split(',')
        if len(parts) != 5 or parts[0] == 'batch':
            continue
        try:
            rows.append((parts[0], int(parts[1]), float(parts[2]), float(parts[3]), int(parts[4])))
        except ValueError:
            pass
    return rows

def pct(v, q):
    if not v:
        return float('nan')
    s = sorted(v)
    return s[min(len(s) - 1, int(len(s) * q))]

def batch_stats(rows):
    bt = defaultdict(list)
    for b, f, secs, mbps, rt in rows:
        bt[b].append(mbps)
    totals, mins, stars, streak, maxstreak = [], [], 0, 0, 0
    for b in sorted(bt, key=lambda x: (len(str(x)), str(x))):
        v = sorted(bt[b])
        med = v[len(v) // 2] if len(v) % 2 else (v[len(v)//2 - 1] + v[len(v)//2]) / 2
        totals.append(sum(v))
        mins.append(v[0])
        if v[0] < 0.25 * med:
            stars += 1
            streak += 1
            maxstreak = max(maxstreak, streak)
        else:
            streak = 0
    return totals, mins, stars, maxstreak

def ping_stats(tag):
    p = os.path.join(LOGS, 'ping_' + tag + '.txt')
    if not os.path.exists(p):
        return []
    return [float(m.group(1)) for ln in open(p, errors='ignore')
            for m in [re.search(r'time=([\d.]+)\s*ms', ln)] if m]

def ss_stats(tag):
    p = os.path.join(LOGS, 'ss_' + tag + '.txt')
    if not os.path.exists(p):
        return (0, 0, 0)
    blocks = hit = maxpin = 0
    cur = 0
    for ln in open(p, errors='ignore'):
        if ln.startswith('=== '):
            blocks += 1
            if cur:
                hit += 1
                maxpin = max(maxpin, cur)
            cur = 0
            continue
    m = re.search(r'rcv_space:(\d+)', ln)
    if m and int(m.group(1)) <= 65535:
        cur += 1
    if cur:
        hit += 1
        maxpin = max(maxpin, cur)
    return (blocks, hit, maxpin)

def ss_srv_stats(tag):
    # 发端(服务端) cwnd 签名: p50 与 <20 包采样占比 (7hn 塌缩 = cwnd 钉 ~10-13)
    p = os.path.join(LOGS, 'ss_srv_' + tag + '.txt')
    if not os.path.exists(p):
        return None
    cw = [int(m.group(1)) for ln in open(p, errors='ignore')
          for m in [re.search(r'cwnd:(\d+)', ln)] if m]
    if not cw:
        return None
    s = sorted(cw)
    low = sum(1 for v in cw if v < 20)
    return (s[len(s) // 2], 100.0 * low / len(cw), len(cw))

lines = []
lines.append(f'{"leg":18s} {"batches":>7s} {"tot_p50":>8s} {"tot_p5":>8s} {"min_p50":>8s} {"min_p5":>8s} '
             f'{"min_lo":>8s} {"starv%":>7s} {"streak":>6s} {"rtt_p50":>8s} {"rtt_p95":>8s} {"rtt_max":>8s} {"pin%":>6s} {"pinmax":>6s} '
             f'{"srv_cw50":>8s} {"cw<20%":>7s} {"cwn":>5s}')
stats = {}
for tag in TAGS:
    rows = load_csv(tag)
    if not rows:
        lines.append(f'{tag:18s} NO DATA')
        continue
    totals, mins, stars, maxstreak = batch_stats(rows)
    rtt = ping_stats(tag)
    blocks, hit, maxpin = ss_stats(tag)
    srv = ss_srv_stats(tag)
    srv_str = f'{srv[0]:8d} {srv[1]:7.1f} {srv[2]:5d}' if srv else f'{"-":>8s} {"-":>7s} {"-":>5s}'
    stats[tag] = (stars / len(totals) * 100, maxstreak)
    lines.append(f'{tag:18s} {len(totals):7d} {pct(totals,.5):8.1f} {pct(totals,.05):8.1f} '
                 f'{pct(mins,.5):8.2f} {pct(mins,.05):8.2f} {min(mins):8.2f} {100.0*stars/len(totals):7.2f} {maxstreak:6d} '
                 f'{pct(rtt,.5):8.1f} {pct(rtt,.95):8.1f} {max(rtt):8.1f} {100.0*hit/blocks if blocks else 0:6.1f} {maxpin:6d} '
                 f'{srv_str}')
lines.append('')
lines.append('units: tot/min Mbps, rtt ms; starved batch = min flow < 25% batch median; streak = max consecutive')
lines.append('pin% = share of 5s samples with >=1 socket rcv_space<=65535 (钉死签名), pinmax = max pinned sockets in one sample')
lines.append('srv_cw50/cw<20%/cwn = sender-side cwnd p50 / share of samples with cwnd<20 / sample count (7hn: cwnd 钉 ~10-13 = 虚假 RTO 风暴签名)')
if 'fq_loss' in stats:
    spct, stk = stats['fq_loss']
    gate = 'REPRO_OK' if (spct >= 2.0 or stk >= 3) else 'REPRO_WEAK (fq loss 腿几乎无饿死, 环境未复现报告条件, A/B 差异仅供相对参考)'
    lines.append(f'gate(fq_loss): starved%={spct:.2f} streak={stk} -> {gate}')
report = '\n'.join(lines)
print(report)
with open(os.path.join(OUT, 'summary.txt'), 'w') as fh:
    fh.write(report + '\n')
PYEOF
}

echo "=== 0. 预检 (fail-fast) ==="
for m in sch_netem sch_tbf sch_fq sch_fq_codel sch_cake; do
  modprobe "$m" 2>/dev/null || fail "内核模块 $m 不可用 (未编入本内核)"
done
echo "modules: sch_netem/sch_tbf/sch_fq/fq_codel/cake 全部 OK"
for b in tc ip ss ping jq python3 ethtool iperf3; do
  command -v "$b" >/dev/null 2>&1 || fail "二进制 $b 缺失"
done
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 \
  || fail "sysctl (ip_forward/rp_filter)"
echo "uname -r = $(uname -r)"

echo "=== 1. 拓扑 ==="
pkill -x iperf3 2>/dev/null
ip netns add ns_srv || fail "netns ns_srv"
ip netns add ns_cli || fail "netns ns_cli"
ip link add v_s type veth peer name ve_s || fail "veth v_s"
ip link add v_c type veth peer name ve_c || fail "veth v_c"
ip link set ve_s netns ns_srv
ip link set ve_c netns ns_cli
ip addr add 10.0.1.254/24 dev v_s
ip addr add 10.0.2.254/24 dev v_c
ip link set v_s up
ip link set v_c up
ip netns exec ns_srv ip addr add 10.0.1.1/24 dev ve_s
ip netns exec ns_cli ip addr add 10.0.2.1/24 dev ve_c
ip netns exec ns_srv ip link set ve_s up
ip netns exec ns_cli ip link set ve_c up
ip netns exec ns_srv ip link set lo up
ip netns exec ns_cli ip link set lo up
ip netns exec ns_srv ip route add default via 10.0.1.254
ip netns exec ns_cli ip route add default via 10.0.2.254

for d in v_s v_c; do ethtool -K "$d" tso off gso off gro off 2>/dev/null; done
ip netns exec ns_srv ethtool -K ve_s tso off gso off gro off 2>/dev/null
ip netns exec ns_cli ethtool -K ve_c tso off gso off gro off 2>/dev/null
echo "offloads off (1500B 段, AQM 粒度三臂一致)"

for i in 0 1 2 3 4 5 6 7; do
  ip netns exec ns_srv iperf3 -s -p $((5201 + i)) -D >/dev/null 2>&1
done
sleep 1

echo "=== 2. 容量校准 (3 batch 取 max, 单点极值防 flaky) ==="
CAP=0
for c in 1 2 3; do
  qdisc_reset
  agg=$(run_batch "calib$c" "-")
  echo "calib batch $c: agg=${agg}Mbps"
  awk -v a="$CAP" -v b="$agg" 'BEGIN{exit !(b > a)}' && CAP="$agg"
done
SHAPE=$(awk -v cap="$CAP" -v req="$SHAPE_REQ" 'BEGIN{
  sub(/Mbit.*/, "", req); r = req + 0; s = int(cap * 0.6);
  if (s > r) s = r; if (s < 1) s = 1; print s}')
echo "SHAPE=${SHAPE}Mbit (req=$SHAPE_REQ, raw_cap=${CAP}Mbps, 0.6x 余量)"
awk -v s="$SHAPE" 'BEGIN{exit !(s < 30)}' && echo "WARN: TCG 容量过低 (<30Mbit), 绝对值仅做相对比较"

echo "=== 3. 腿矩阵 (legs=$LEGS; arms=$ARMS) ==="
for ARM in $ARMS; do
  for LEG in $LEGS; do
    run_leg "$ARM" "$LEG"
  done
done

echo "=== 4. 聚合 ==="
python3_analyze
echo "HARNESS_DONE out=$OUT"
