#!/bin/bash
# scripts/soak_test_5h.sh - 5 小时持久长跑套件
# 在你的 VPS 上跑 (需要 root, 装好 tcpboost 内核并启用 unstick=1)
# 测的是: 持续负载下吞吐是否退化 + 内核态资源是否泄漏/压力上升
# 用法:
#   sudo ./soak_test_5h.sh                    # 默认 5h, lo, 8 流, netem 双腿 5%/75ms
#   sudo DURATION=2h IFACE=eth0 LOSS=0.5% ./soak_test_5h.sh
#
# 输出: /var/log/tcpboost-soak/<ts>/{timeseries.csv, samples.jsonl, streams/*.jsonl, summary.md, regression.md}

set -u

# ============ 参数 ============
DURATION="${DURATION:-5h}"
IFACE="${IFACE:-lo}"
NSTREAMS="${NSTREAMS:-8}"
LOSS="${LOSS:-5%}"
DELAY_MS="${DELAY_MS:-75}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-30}"   # 秒
SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-300}"  # 秒
STREAM_ROTATE_SEC="${STREAM_ROTATE_SEC:-300}"  # 每条流 5min 重连一次
LOG_ROOT="${LOG_ROOT:-/var/log/tcpboost-soak}"
CC="${CC:-bbrplusv3}"
IPERF_PORT="${IPERF_PORT:-5201}"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$LOG_ROOT/$ts"
mkdir -p "$OUT/streams"
echo "[$(date -Iseconds)] 长跑套件启动: duration=$DURATION iface=$IFACE streams=$NSTREAMS loss=$LOSS delay=${DELAY_MS}ms cc=$CC"
echo "[$(date -Iseconds)] 输出: $OUT"

# ============ 前置检查 ============
[ "$(id -u)" = "0" ] || { echo "FATAL: 需要 root"; exit 2; }
which iperf3 >/dev/null 2>&1 || { echo "FATAL: iperf3 未装 (apt install iperf3)"; exit 2; }
which bc >/dev/null 2>&1 || apt-get install -y bc >/dev/null 2>&1
sysctl -w net.ipv4.tcp_congestion_control="$CC" >/dev/null 2>&1 || echo "WARN: CC=$CC 切换失败, 沿用当前"

# ============ 启 netem ============
cleanup_netem() {
  tc qdisc del dev "$IFACE" root 2>/dev/null
}
trap 'cleanup_netem; pkill -P $$ 2>/dev/null; pkill -f "iperf3.*-p $IPERF_PORT" 2>/dev/null' EXIT

# lo/eth 上网段 netem (双向同 delay 同 loss) - 模拟报告 §6 条件并加压
if [ "$IFACE" = "lo" ]; then
  tc qdisc add dev lo root handle 1: prio bands 4 2>/dev/null
  tc qdisc add dev lo parent 1:4 handle 40: netem delay "${DELAY_MS}ms" "${DELAY_MS}ms" loss "$LOSS" 2>/dev/null
  # 把目标 IP 重定向到 band 4 (本机 127.0.0.1)
  tc filter add dev lo protocol ip parent 1:0 prio 3 u32 match ip dst 127.0.0.1 flowid 1:4 2>/dev/null
else
  tc qdisc add dev "$IFACE" root netem delay "${DELAY_MS}ms" "${DELAY_MS}ms" loss "$LOSS" 2>/dev/null
fi
echo "[$(date -Iseconds)] netem 已加: $IFACE 双腿 ${DELAY_MS}ms/$LOSS"

# ============ 启 iperf3 server (持续) ============
iperf3 -s -p "$IPERF_PORT" > "$OUT/iperf3-server.log" 2>&1 &
SERVER_PID=$!
sleep 1
[ -d "/proc/$SERVER_PID" ] || { echo "FATAL: iperf3 server 启动失败"; cat "$OUT/iperf3-server.log"; exit 1; }
echo "[$(date -Iseconds)] iperf3 server pid=$SERVER_PID port=$IPERF_PORT"

# ============ 流 watcher 循环 (每流 5min 一轮) ============
STREAM_PIDS=()
stop_streams() {
  for pid in "${STREAM_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null
    pkill -P "$pid" 2>/dev/null
  done
}
trap 'cleanup_netem; stop_streams; pkill -f "iperf3.*-p $IPERF_PORT" 2>/dev/null' EXIT

stream_watcher() {
  local idx=$1
  local log="$OUT/streams/stream-$idx.jsonl"
  while true; do
    iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t "$STREAM_ROTATE_SEC" -J 2>/dev/null \
      | grep -o '"bits_per_second":[0-9]*' | tail -1 | cut -d: -f2 \
      >> "$log" || true
    # 流轮转空档标记
    echo "0" >> "$log"
  done
}

for i in $(seq 1 "$NSTREAMS"); do
  stream_watcher "$i" &
  STREAM_PIDS+=($!)
done
echo "[$(date -Iseconds)] 启动 $NSTREAMS 个流 watcher, pids=${STREAM_PIDS[*]}"

# ============ 采样器 ============
CSV="$OUT/timeseries.csv"
echo "epoch,wall,total_mbps,min_mbps,p50_mbps,max_mbps,active_streams,tcp_estab,tcp_timewait,tcp_inuse,sockstat_orphan,conntrack_used,psicpu_some,psimem_some,psiio_some,load1,load5,load15,cpu_pct,mem_used_pct,unstick" > "$CSV"
SAMPLES="$OUT/samples.jsonl"
echo '{"epoch":0}' > "$SAMPLES"
echo '{"epoch":0}' > "$OUT/memory.jsonl"

# 把秒数转 epoch + 总时长终止点
DURATION_SEC=$(echo "$DURATION" | awk '{
  if ($1 ~ /[0-9]+h$/) print substr($1,1,length($1)-1)*3600;
  else if ($1 ~ /[0-9]+m$/) print substr($1,1,length($1)-1)*60;
  else if ($1 ~ /[0-9]+s$/) print substr($1,1,length($1)-1);
  else if ($1 ~ /^[0-9]+$/) print $1;
  else { print "5*3600" }
}')
DEADLINE=$(($(date +%s) + DURATION_SEC))
echo "[$(date -Iseconds)] 计划运行 ${DURATION_SEC}s ($(date -d @$DEADLINE -u +%FT%TZ) 结束)"

# 当前每流 bps (从 ss -tin 实时抓)
sample_streams() {
  ss -tin state established 2>/dev/null | awk '
    /delivery_rate/ {
      for (i=1;i<=NF;i++) {
        if ($i == "delivery_rate") { r=$(i+1); sub(/bps,?/,"",r); if (r ~ /Mbps$/) { sub(/Mbps/,"",r); r*=1e6 } else if (r ~ /Kbps$/) { sub(/Kbps/,"",r); r*=1e3 } else if (r ~ /Gbps$/) { sub(/Gbps/,"",r); r*=1e9 } rates[++n]=r }
      }
    }
    END { printf "%d %d %d %d %d\n", n, (n>0?min(rates):0), (n>0?max(rates):0), sum(rates), (n>0?int(sum(rates)/n):0) }
    function min(a,  i,m) { m=a[1]; for (i=2;i<=length(a);i++) if (a[i]<m) m=a[i]; return m }
    function max(a,  i,m) { m=a[1]; for (i=2;i<=length(a);i++) if (a[i]>m) m=a[i]; return m }
    function sum(a,  i,s) { for (i=1;i<=length(a);i++) s+=a[i]; return s }
  ' 2>/dev/null
}

# 取 PSI 值 (百分比, 1位小数)
psi() {
  local f="/proc/pressure/$1"
  [ -r "$f" ] || { echo "n/a"; return; }
  awk '/^some/ {printf "%.1f", $2}' "$f"
}

# mpstat 1 秒 1 次; 没有 sysstat 用 top
cpu_pct() {
  if which mpstat >/dev/null 2>&1; then
    mpstat 1 1 2>/dev/null | awk '/^Average/ && NF>=12 {print 100-$NF}'
  else
    top -bn2 -d1 2>/dev/null | awk '/^%Cpu/ {gsub(",","",$0); print $0; exit}' | awk '{print 100-$8}'
  fi
}

# 内存细采: slab/内核栈/碎片化/compact/iperf3 RSS — 5min 粒度落 memory.jsonl
# 碎片化观测点: buddyinfo order-0/4/9 空闲页 (order-9 ≈ 2MB 巨页, 持续下降=碎片化)
# 泄漏观测点: SUnreclaim(不可回收slab)/KernelStack/Vmalloc 持续单调涨=泄漏
mem_snapshot() {
  local pid="$1"
  local mi slab unreclaim kstack vmalloc tcpmem
  mi=$(cat /proc/meminfo)
  slab=$(awk '/^Slab:/ {print $2}' <<<"$mi")
  unreclaim=$(awk '/^SUnreclaim:/ {print $2}' <<<"$mi")
  kstack=$(awk '/^KernelStack:/ {print $2}' <<<"$mi")
  vmalloc=$(awk '/^VmallocUsed:/ {print $2}' <<<"$mi")
  tcpmem=$(awk '/^TCP:/{print $2}' /proc/sockstat 2>/dev/null)
  # buddyinfo: node0 各 order free 页数; 取 order0/4/9 (第4/9/15列, buddyinfo 从第4列起是 order0)
  read -r b0 b4 b9 <<< "$(awk 'NR==2{print $4, $8, $13}' /proc/buddyinfo 2>/dev/null)"
  # compact/alloc 压力事件
  read -r cstall cfail csucc allocstall <<< "$(awk '/compact_stall/{s=$2}/compact_fail/{f=$2}/compact_success/{c=$2}/allocstall/{a+=$2}END{print s+0,f+0,c+0,a+0}' /proc/vmstat)"
  # iperf3 进程 RSS (kB)
  local rss=0
  [ -n "$pid" ] && [ -r "/proc/$pid/status" ] && rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status")
  echo "{\"epoch\":$(date +%s),\"slab_kb\":$slab,\"sunreclaim_kb\":$unreclaim,\"kstack_kb\":$kstack,\"vmalloc_kb\":$vmalloc,\"tcp_mem_pages\":${tcpmem:-0},\"buddy_o0\":${b0:-0},\"buddy_o4\":${b4:-0},\"buddy_o9\":${b9:-0},\"compact_stall\":$cstall,\"compact_fail\":$cfail,\"compact_success\":$csucc,\"allocstall\":$allocstall,\"iperf3_rss_kb\":$rss}"
}

UNSTICK=$(sysctl -n net.ipv4.tcp_rcv_ssthresh_unstick 2>/dev/null || echo 0)

last_snap=0
echo "[$(date -Iseconds)] 采样循环开始 (interval=${SAMPLE_INTERVAL}s)"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  now=$(date +%s)
  wall=$(date -Iseconds)

  # 流数据: 活跃数/总bps/最小/最大/平均 (Mbps)
  read -r active minbps maxbps sumbps p50bps <<<"$(sample_streams)"
  total_mbps=$(echo "scale=2; ${sumbps:-0} / 1000000" | bc 2>/dev/null || echo 0)
  min_mbps=$(echo "scale=2; ${minbps:-0} / 1000000" | bc 2>/dev/null || echo 0)
  max_mbps=$(echo "scale=2; ${maxbps:-0} / 1000000" | bc 2>/dev/null || echo 0)
  p50_mbps=$(echo "scale=2; ${p50bps:-0} / 1000000" | bc 2>/dev/null || echo 0)

  # sockstat
  ss_estab=$(awk '/^TCP:/ {print $2}' /proc/net/sockstat 2>/dev/null)
  ss_tw=$(awk '/^TCP:/ {print $7}' /proc/net/sockstat 2>/dev/null)
  ss_inuse=$(awk '/^TCP:/ {print $4}' /proc/net/sockstat 2>/dev/null)
  ss_orphan=$(awk '/^TCP:/ {print $9}' /proc/net/sockstat 2>/dev/null)

  # conntrack
  [[ -r /proc/net/nf_conntrack ]] && ct_used=$(wc -l < /proc/net/nf_conntrack) || ct_used=0

  # PSI
  psicpu=$(psi cpu)
  psimem=$(psi memory)
  psiio=$(psi io)

  # load
  read -r load1 load5 load15 _ < /proc/loadavg

  # CPU + mem
  cpu=$(cpu_pct)
  mem=$(free | awk '/^Mem:/ {printf "%.1f", $3/$2*100}')

  # 5min 一次完整快照
  if [ $((now - last_snap)) -ge "$SNAPSHOT_INTERVAL" ] || [ "$last_snap" = "0" ]; then
    last_snap=$now
    # 内存/碎片化细采 (memory.jsonl, 5min 粒度)
    iperf3_pid=$(pgrep -f 'iperf3 -s' | head -1)
    mem_snapshot "$iperf3_pid" >> "$OUT/memory.jsonl"
    # 落 JSONL (详细)
    snap_json=$(cat <<EOF
{"epoch":$now,"wall":"$wall","active":$active,"total_mbps":$total_mbps,"min_mbps":$min_mbps,"max_mbps":$max_mbps,"p50_mbps":$p50_mbps,"tcp_estab":${ss_estab:-0},"tcp_tw":${ss_tw:-0},"tcp_inuse":${ss_inuse:-0},"orphan":${ss_orphan:-0},"conntrack":$ct_used,"psicpu":$psicpu,"psimem":$psimem,"psiio":$psiio,"load1":$load1,"cpu_pct":$cpu,"mem_pct":$mem,"unstick":$UNSTICK,"tcp_rcv_ssthresh_unstick":$UNSTICK}
EOF
)
    echo "$snap_json" >> "$SAMPLES"
    echo "[$wall] SNAPSHOT: total=${total_mbps}Mbps p50=${p50_mbps}Mbps min=${min_mbps}Mbps active=$active estab=${ss_estab} cpu=${cpu}% mem=${mem}% psi.cpu=$psicpu"
  fi

  # 始终落 CSV (30s 粒度)
  echo "$now,$wall,$total_mbps,$min_mbps,$p50_mbps,$max_mbps,$active,${ss_estab:-0},${ss_tw:-0},${ss_inuse:-0},${ss_orphan:-0},$ct_used,$psicpu,$psimem,$psiio,$load1,$load5,$load15,$cpu,$mem,$UNSTICK" >> "$CSV"

  sleep "$SAMPLE_INTERVAL"
done

echo "[$(date -Iseconds)] 采样循环结束"
cleanup_netem
stop_streams
sleep 2
pkill -f "iperf3.*-p $IPERF_PORT" 2>/dev/null
sleep 1

# ============ 收尾: 调分析器 ============
ANALYZE="$(dirname "$0")/soak_analyze.sh"
if [ -x "$ANALYZE" ]; then
  echo "[$(date -Iseconds)] 跑分析: $ANALYZE $OUT"
  bash "$ANALYZE" "$OUT"
else
  echo "[$(date -Iseconds)] 分析器未找到 ($ANALYZE), 跳过"
fi

echo "[$(date -Iseconds)] 长跑套件收尾完成"
echo "结果: $OUT"
ls -la "$OUT"
