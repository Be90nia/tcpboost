#!/bin/bash
# vps_sim_ab.sh — 车队机内部 netns 模拟 (不产生公网流量, 不碰宿主 lo/eth0)
#
# 复刻 CI (scripts/soak_test_5h.sh) 的损伤与采样结构, 但把损伤放进 netns+veth:
#   - 损伤: 双向 delay 75ms (=RTT 150ms) + loss 0.5% + rate 限速 (共享瓶颈)
#   - 8 流独立端口, 每 ROTATE_SEC 秒轮转一次 client 连接 (与 CI 同构)
#   - A/B: 每 SEG_SEC 秒切一次 c2_early_probe (C2_VALS 轮转), 段间重起流隔离状态
#
# 用法 (root):
#   DURATION=12m SEG_SEC=180 C2_VALS="0" ./scripts/vps_sim_ab.sh
#   DURATION=24h SEG_SEC=7200 C2_VALS="0 1" ./scripts/vps_sim_ab.sh
#
# 输出: $OUT/seg-NN/{iperf3-server-<port>.log, timeseries.csv} + $OUT/segments.csv
# 分析: python scripts/analysis/recovery_timeline.py --dirs c2_0=...,c2_1=... (合并段后)
set -u

DURATION=${DURATION:-24h}
SEG_SEC=${SEG_SEC:-7200}
LOSS=${LOSS:-0.5%}
DELAY_MS=${DELAY_MS:-75}      # 单向; 双向 = 150ms RTT (与 CI 一致)
RATE=${RATE:-100mbit}         # netem 瓶颈: none = 不限速 (CPU 限流时用)
PER_STREAM_BW=${PER_STREAM_BW:-} # 每流 iperf3 限速 (如 60M); 空 = 不限速
NSTREAMS=${NSTREAMS:-8}
ROTATE_SEC=${ROTATE_SEC:-300}
C2_VALS=${C2_VALS:-"0 1"}
BASE_PORT=${BASE_PORT:-5201}
CLIENT_CPUS=${CLIENT_CPUS:-0} # client 绑核, server 不绑 (nice 让路给业务)
CC=${CC:-bbrplusv3}
NS=tbsim
OUT=${OUT:-/var/log/tcpboost-sim/$(date +%Y%m%dT%H%M%S)}
C2PATH=/sys/module/tcp_bbrplusv3/parameters/c2_early_probe
SEG_DIRS=()

log() { echo "[$(date -Iseconds)] $*"; }

DURATION_SEC=$(echo "$DURATION" | awk '{
  if ($1 ~ /[0-9]+h$/) print substr($1,1,length($1)-1)*3600;
  else if ($1 ~ /[0-9]+m$/) print substr($1,1,length($1)-1)*60;
  else if ($1 ~ /[0-9]+s$/) print substr($1,1,length($1)-1);
  else print 5*3600 }')
DEADLINE=$(($(date +%s) + DURATION_SEC))

# ---------- 前置检查 ----------
[ "$(id -u)" = "0" ] || { echo "FATAL: 需要 root"; exit 2; }
for b in iperf3 tc ip taskset nice ionice ss; do
  command -v "$b" >/dev/null 2>&1 || { echo "FATAL: 缺 $b"; exit 2; }
done
mkdir -p "$OUT"
log "OUT=$OUT duration=${DURATION_SEC}s seg=${SEG_SEC}s loss=$LOSS delay=${DELAY_MS}ms rate=$RATE cc=$CC"
log "C2_VALS=[$C2_VALS] knob=$([ -w "$C2PATH" ] && echo present || echo absent)"

# ---------- 清理 ----------
cleanup() {
  log "收尾: 停流/删 netns/qdisc"
  pkill -f "iperf3 -c 10.77.0.2" 2>/dev/null
  for i in $(seq 0 $((NSTREAMS - 1))); do pkill -f "iperf3 -s -p $((BASE_PORT + i))" 2>/dev/null; done
  sleep 2
  pkill -9 -f "iperf3 -c 10.77.0.2" 2>/dev/null
  for i in $(seq 0 $((NSTREAMS - 1))); do pkill -9 -f "iperf3 -s -p $((BASE_PORT + i))" 2>/dev/null; done
  ip netns del "$NS" 2>/dev/null
  tc qdisc del dev tb-h root 2>/dev/null
  ip link del tb-h 2>/dev/null
}
trap cleanup EXIT INT TERM

# ---------- netns + veth 隔离 ----------
ip netns del "$NS" 2>/dev/null
ip link del tb-h 2>/dev/null
ip netns add "$NS" || { echo "FATAL: netns 创建失败"; exit 1; }
ip link add tb-h type veth peer name tb-n || { echo "FATAL: veth 创建失败"; exit 1; }
ip link set tb-n netns "$NS"
ip addr add 10.77.0.1/24 dev tb-h
ip link set tb-h up
ip netns exec "$NS" ip addr add 10.77.0.2/24 dev tb-n
ip netns exec "$NS" ip link set tb-n up
ip netns exec "$NS" ip link set lo up
# 双向同损伤: host 侧 (去程) + netns 侧 (回程)
NETEM_ARGS="delay ${DELAY_MS}ms ${DELAY_MS}ms loss $LOSS"
[ "$RATE" != "none" ] && NETEM_ARGS="$NETEM_ARGS rate $RATE"
tc qdisc add dev tb-h root netem $NETEM_ARGS 2>/dev/null
ip netns exec "$NS" tc qdisc add dev tb-n root netem $NETEM_ARGS 2>/dev/null
log "netem 已加: tb-h/tb-n 双向 ${DELAY_MS}ms/$LOSS rate=$RATE (RTT=$((DELAY_MS * 2))ms)"

# ---------- 全局 CC (业务也在用, 记录原值) ----------
OLD_CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
sysctl -w net.ipv4.tcp_congestion_control="$CC" >/dev/null 2>&1 || log "WARN: CC 切换失败, 沿用 $OLD_CC"
log "CC: $OLD_CC -> $(cat /proc/sys/net/ipv4/tcp_congestion_control)"

# ---------- 采样 (client 侧 dport 过滤, 不双计) ----------
sample_streams() {
  local filt="" p
  for p in $(seq "$BASE_PORT" $((BASE_PORT + NSTREAMS - 1))); do filt+="dport = :$p or "; done
  filt="( ${filt%or } )"
  ss -tin state established "$filt" 2>/dev/null | awk '
    /delivery_rate/ {
      for (i=1;i<=NF;i++) {
        if ($i == "delivery_rate") { r=$(i+1); sub(/bps,?/,"",r); if (r ~ /Mbps$/) { sub(/Mbps/,"",r); r*=1e6 } else if (r ~ /Kbps$/) { sub(/Kbps/,"",r); r*=1e3 } else if (r ~ /Gbps$/) { sub(/Gbps/,"",r); r*=1e9 } rates[++n]=r }
      }
    }
    END {
      if (n>0) { m=rates[1]; x=rates[1]; s=0;
        for (i=1;i<=n;i++) { if (rates[i]<m) m=rates[i]; if (rates[i]>x) x=rates[i]; s+=rates[i] }
        printf "%d %.3f %.3f %.3f\n", n, m/1e6, x/1e6, s/1e6 }
      else printf "0 0.000 0.000 0.000"
    }
  ' 2>/dev/null
}

cpu_ticks() { awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat; }

# ---------- 段循环 ----------
SEG=0
VALS=($C2_VALS)
NVALS=${#VALS[@]}
echo "seg,c2,start_epoch,end_epoch,elapsed_s" > "$OUT/segments.csv"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  NOW=$(date +%s)
  LEFT=$((DEADLINE - NOW))
  [ "$LEFT" -le 0 ] && break
  THIS_SEC=$SEG_SEC
  [ "$THIS_SEC" -gt "$LEFT" ] && THIS_SEC=$LEFT
  C2=${VALS[$((SEG % NVALS))]}
  SEG_DIR="$OUT/seg-$(printf '%02d' "$SEG")"
  mkdir -p "$SEG_DIR"
  SEG_DIRS+=("$SEG_DIR")
  if [ -w "$C2PATH" ]; then
    echo "$C2" > "$C2PATH" 2>/dev/null && log "seg$SEG c2_early_probe=$C2" || log "seg$SEG c2 写失败"
  else
    log "seg$SEG c2 旋钮不存在 (内核 $(uname -r)), 该段无 c2 对照"
  fi
  CSV="$SEG_DIR/timeseries.csv"
  echo "epoch,wall,total_mbps,min_mbps,max_mbps,active_streams,cpu_pct,load1,c2" > "$CSV"

  # 8 个 iperf3 server (netns 内), 每端口一条流
  for i in $(seq 0 $((NSTREAMS - 1))); do
    p=$((BASE_PORT + i))
    ip netns exec "$NS" nice -n 19 ionice -c 3 iperf3 -s -p "$p" > "$SEG_DIR/iperf3-server-$p.log" 2>&1 &
  done
  sleep 2
  # 8 个 watcher: 每流每 ROTATE_SEC 秒重连一次 (与 CI 同构)
  for i in $(seq 0 $((NSTREAMS - 1))); do
    p=$((BASE_PORT + i))
    (
      while [ ! -f "$SEG_DIR/stop" ] && [ "$(date +%s)" -lt "$((NOW + THIS_SEC))" ]; do
        taskset -c "$CLIENT_CPUS" nice -n 19 ionice -c 3 \
          iperf3 -c 10.77.0.2 -p "$p" -t "$ROTATE_SEC" ${PER_STREAM_BW:+-b "$PER_STREAM_BW"} >/dev/null 2>&1
        sleep 1
      done
    ) &
  done
  log "seg$SEG 开始: c2=$C2 时长 ${THIS_SEC}s"

  # 秒级采样直到段末
  SEG_END=$((NOW + THIS_SEC))
  read -r PREV_T PREV_I <<< "$(cpu_ticks)"
  while [ "$(date +%s)" -lt "$SEG_END" ]; do
    read -r n mn mx tot <<< "$(sample_streams)"
    read -r T I <<< "$(cpu_ticks)"
    DT=$((T - PREV_T)); DI=$((I - PREV_I)); PREV_T=$T; PREV_I=$I
    CPU=0; [ "$DT" -gt 0 ] && CPU=$(awk -v dt="$DT" -v di="$DI" 'BEGIN{printf "%.1f", 100*(dt-di)/dt}')
    echo "$(date +%s),$(date -Iseconds),${tot:-0},${mn:-0},${mx:-0},${n:-0},$CPU,$(cut -d' ' -f1 /proc/loadavg),$C2" >> "$CSV"
    sleep 1
  done

  touch "$SEG_DIR/stop"
  pkill -f "iperf3 -c 10.77.0.2" 2>/dev/null
  for i in $(seq 0 $((NSTREAMS - 1))); do pkill -f "iperf3 -s -p $((BASE_PORT + i))" 2>/dev/null; done
  sleep 3
  # 兜底: 段边界竞态重启的 client / 未响应 TERM 的 server (禁 wait: server 是无限进程, 会死锁)
  pkill -9 -f "iperf3 -c 10.77.0.2" 2>/dev/null
  for i in $(seq 0 $((NSTREAMS - 1))); do pkill -9 -f "iperf3 -s -p $((BASE_PORT + i))" 2>/dev/null; done
  echo "$SEG,$C2,$NOW,$(date +%s),$(( $(date +%s) - NOW ))" >> "$OUT/segments.csv"
  log "seg$SEG 结束: c2=$C2"
  SEG=$((SEG + 1))
done

log "全部完成: $OUT (段数=$SEG)"
log "段目录: ${SEG_DIRS[*]}"
