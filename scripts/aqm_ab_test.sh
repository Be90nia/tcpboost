#!/bin/bash
# scripts/aqm_ab_test.sh — AQM hardening 三臂×两腿 A/B (bd yve, backlog 验证战役 Wave-0)
#
# 矩阵: fq(基线) | fq_codel | cake  ×  loss(0.5%) | clean(净腿), 每腿 LEG_SEC 秒
# 判据: 三指标 (total/min/加载 RTT) 任一 qdisc 显著优于 fq -> KEEP 候选 (PM 裁决)
#
# 拓扑 (路由三节点, 被测 qdisc 位于瓶颈队列):
#   ns_srv(10.0.1.1) --(ve_s|v_s) host 路由 --(v_c|ve_c) ns_cli(10.0.2.1)
#   数据方向 srv->cli: v_s ingress -(mirred)-> ifb0 [netem 延迟/丢包] -> 路由 -> v_c egress [tbf 限速 + 被测 qdisc]
#   ACK  方向 cli->srv: v_c ingress -> 路由 -> v_s egress [netem 延迟]
#   RTT ~= 2x75ms 均值 (每方向 delay 75ms 75ms 抖动), 复现 150ms RTT + loss 0.5% 报告条件
#
# 为什么 netem 不与被测 qdisc 串一条链: netem enqueue 即按时间戳入 tfifo,
#   恒吃掉批量队列, 下游 qdisc 永远近空载 -> 三臂假性无差异 (120.79 VPS smoke 实证后撤离)。
# 数据来源: 本 harness 自采 (iperf3 -J 逐流 + ss -tin 循环 + ping 循环), 不依赖旧 soak harness JSONL。
# 环境政策 2026-10-16: 实验一律 CI QEMU guest, 禁用用户 VPS。
#
# env (vng 命令行烤入, guest 不继承宿主 env):
#   LEG_SEC 每腿秒数(默认 1200)  SHAPE_REQ 请求限速(默认 200Mbit, TCG 容量不足自动下调)
#   BYTES 单流字节(默认 12.5M)  RTT_HALF_MS 单向均值 ms(默认 75)  LOSS_PCT loss 腿丢包率(默认 0.5)
#   OUT 输出目录(默认 /var/log/tcpboost-soak/aqm_ab)
set -u

LEG_SEC="${LEG_SEC:-1200}"
BYTES="${BYTES:-12.5M}"
SHAPE_REQ="${SHAPE_REQ:-200Mbit}"
RTT_HALF_MS="${RTT_HALF_MS:-75}"
LOSS_PCT="${LOSS_PCT:-0.5}"
OUT="${OUT:-/var/log/tcpboost-soak/aqm_ab}"
LOGS="$OUT/logs"
DATA="$OUT/data"
SRV_IP=10.0.1.1
PERFLOW_TIMEOUT=300
mkdir -p "$LOGS" "$DATA"
exec > >(tee -a "$LOGS/harness.log") 2>&1

SHAPE=0   # 校准后的实际限速 Mbit

fail() { echo "FATAL: $*"; exit 3; }

qdisc_reset() {
  tc qdisc del dev v_c root 2>/dev/null
  tc qdisc del dev ifb0 root 2>/dev/null
  tc qdisc del dev v_s root 2>/dev/null
}

cleanup() {
  qdisc_reset
  pkill -x iperf3 2>/dev/null
  ip netns del ns_srv 2>/dev/null
  ip netns del ns_cli 2>/dev/null
  ip link del v_s 2>/dev/null
  ip link del v_c 2>/dev/null
  modprobe -r ifb 2>/dev/null
}
trap cleanup EXIT

dump_diag() {
  echo "--- diag dump ---"
  ip -br link 2>&1
  ip route 2>&1
  ip netns exec ns_cli ip route 2>&1
  ip netns exec ns_cli ss -tin 2>&1 | head -20
  tc -s qdisc show dev v_c 2>&1
  tc -s qdisc show dev ifb0 2>&1
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
  local ARM=$1 LEG=$2 TAG="${1}_${2}"
  local PID_PING PID_SS PID_TC
  local data_netem="delay ${RTT_HALF_MS}ms ${RTT_HALF_MS}ms limit 10000"
  [ "$LEG" = loss ] && data_netem="delay ${RTT_HALF_MS}ms ${RTT_HALF_MS}ms loss ${LOSS_PCT}% limit 10000"
  echo "--- leg $TAG start $(date +%s) ---"
  qdisc_reset
  if ! { tc qdisc add dev ifb0 root netem $data_netem \
         && tc qdisc add dev v_s root netem "delay ${RTT_HALF_MS}ms ${RTT_HALF_MS}ms limit 10000"; }; then
    fail "netem 建立失败 $TAG"
  fi
  # 瓶颈: tbf 优先 (派单指定), 拒绝子 graft 时回落 htb (两种都让队列落在被测 qdisc)
  local graft=tbf
  if tc qdisc add dev v_c root handle 1: tbf rate "${SHAPE}Mbit" burst 256kb latency 1000ms 2>/dev/null \
     && tc qdisc add dev v_c parent 1:1 handle 10: "$ARM" 2>/dev/null; then
    :
  else
    qdisc_reset
    tc qdisc add dev ifb0 root netem $data_netem || fail "netem 重建失败 $TAG"
    tc qdisc add dev v_s root netem "delay ${RTT_HALF_MS}ms ${RTT_HALF_MS}ms limit 10000" || fail "v_s netem 重建失败 $TAG"
    tc qdisc add dev v_c root handle 1: htb default 1 || fail "htb root $TAG"
    tc class add dev v_c parent 1: classid 1:1 htb rate "${SHAPE}Mbit" burst 1mb || fail "htb class $TAG"
    tc qdisc add dev v_c parent 1:1 handle 10: "$ARM" || fail "被测 qdisc $ARM $TAG"
    graft=htb
  fi
  # 连通性 fail-fast: ICMP + 2s TCP 预检 (120.79 VPS SYN 黑洞教训: 诊断后即停, 不烧腿)
  ip netns exec ns_cli ping -c 3 -i 0.3 -W 2 "$SRV_IP" > "$LOGS/ping_base_$TAG.txt" 2>&1 \
    || { dump_diag; fail "ICMP base ping 失败 $TAG"; }
  timeout 15 ip netns exec ns_cli iperf3 -c "$SRV_IP" -p 5201 -R -t 2 -J > "$LOGS/probe_$TAG.json" 2>&1 \
    || { dump_diag; fail "TCP 探针失败 $TAG"; }

  ip netns exec ns_cli ping -i 0.2 -D "$SRV_IP" > "$LOGS/ping_$TAG.txt" 2>&1 &
  PID_PING=$!
  ( while :; do echo "=== $(date +%s)"; ip netns exec ns_cli ss -tin dst "$SRV_IP"; sleep 5; done ) > "$LOGS/ss_$TAG.txt" 2>&1 &
  PID_SS=$!
  ( while :; do echo "=== $(date +%s)"; tc -s qdisc show dev v_c; sleep 30; done ) > "$LOGS/tc_$TAG.txt" 2>&1 &
  PID_TC=$!

  local CSV="$DATA/$TAG.csv" deadline b=0 nrows
  deadline=$(( $(date +%s) + LEG_SEC ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    b=$((b + 1))
    run_batch "$b" "$CSV"
  done
  kill "$PID_PING" "$PID_SS" "$PID_TC" 2>/dev/null
  wait 2>/dev/null || true
  tc -s qdisc show dev v_c > "$LOGS/tc_final_$TAG.txt" 2>&1
  nrows=$(wc -l < "$CSV")
  [ "$nrows" -gt 8 ] || { dump_diag; fail "leg $TAG 产出不足 1 批"; }
  qdisc_reset
  sleep 5
  echo "--- leg $TAG done batches=$((nrows - 1)) graft=$graft ---"
}

python3_analyze() {
  python3 - "$DATA" "$LOGS" "$OUT" <<'PYEOF'
import os, re, sys
from collections import defaultdict

DATA, LOGS, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
TAGS = ['fq_loss', 'fq_clean', 'fq_codel_loss', 'fq_codel_clean', 'cake_loss', 'cake_clean']

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

lines = []
lines.append(f'{"leg":18s} {"batches":>7s} {"tot_p50":>8s} {"tot_p5":>8s} {"min_p50":>8s} {"min_p5":>8s} '
             f'{"min_lo":>8s} {"starv%":>7s} {"streak":>6s} {"rtt_p50":>8s} {"rtt_p95":>8s} {"rtt_max":>8s} {"pin%":>6s} {"pinmax":>6s}')
stats = {}
for tag in TAGS:
    rows = load_csv(tag)
    if not rows:
        lines.append(f'{tag:18s} NO DATA')
        continue
    totals, mins, stars, maxstreak = batch_stats(rows)
    rtt = ping_stats(tag)
    blocks, hit, maxpin = ss_stats(tag)
    stats[tag] = (stars / len(totals) * 100, maxstreak)
    lines.append(f'{tag:18s} {len(totals):7d} {pct(totals,.5):8.1f} {pct(totals,.05):8.1f} '
                 f'{pct(mins,.5):8.2f} {pct(mins,.05):8.2f} {min(mins):8.2f} {100.0*stars/len(totals):7.2f} {maxstreak:6d} '
                 f'{pct(rtt,.5):8.1f} {pct(rtt,.95):8.1f} {max(rtt):8.1f} {100.0*hit/blocks if blocks else 0:6.1f} {maxpin:6d}')
lines.append('')
lines.append('units: tot/min Mbps, rtt ms; starved batch = min flow < 25% batch median; streak = max consecutive')
lines.append('pin% = share of 5s samples with >=1 socket rcv_space<=65535 (钉死签名), pinmax = max pinned sockets in one sample')
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
for m in sch_netem ifb sch_tbf sch_fq sch_fq_codel sch_cake; do
  modprobe "$m" 2>/dev/null || fail "内核模块 $m 不可用 (未编入本内核)"
done
echo "modules: sch_netem/ifb/sch_tbf/sch_fq/fq_codel/cake 全部 OK"
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

modprobe ifb numifbs=1 2>/dev/null
ip link show ifb0 >/dev/null 2>&1 || fail "ifb0 设备未创建"
ip link set ifb0 up
tc qdisc add dev v_s handle ffff: ingress || fail "v_s ingress"
tc filter add dev v_s parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 \
  || fail "mirred redirect"

for d in v_s v_c ifb0; do ethtool -K "$d" tso off gso off gro off 2>/dev/null; done
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

echo "=== 3. 六腿矩阵 (loss 腿先跑, 早出饿死信号) ==="
for ARM in fq fq_codel cake; do
  for LEG in loss clean; do
    run_leg "$ARM" "$LEG"
  done
done

echo "=== 4. 聚合 ==="
python3_analyze
echo "HARNESS_DONE out=$OUT"
