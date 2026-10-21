#!/bin/bash
# vps_sim_health.sh — 24h 实验自检 (每小时落盘, 供随时/每 6h 巡检)
# 输出: 结构化摘要行 + WARN 列表 (追加到 health.log)
set -u
OUT=/var/log/tcpboost-sim
LOG="$OUT/health.log"
if [ -d "$OUT/current" ]; then RUN="$OUT/current"; else RUN=$(ls -d "$OUT"/2026* 2>/dev/null | sort | tail -1); fi
NOW=$(date +%s)
WARN=()

[ -n "$RUN" ] || { echo "FATAL: 无 run 目录" | tee -a "$LOG"; exit 1; }
SEGCSV="$RUN/segments.csv"
NSEG=$(( $(wc -l < "$SEGCSV" 2>/dev/null || echo 1) - 1 ))
CUR=$(ls -d "$RUN"/seg-* 2>/dev/null | sort | tail -1)
CSV="$CUR/timeseries.csv"
C2=$(cat /sys/module/tcp_bbrplusv3/parameters/c2_early_probe 2>/dev/null || echo "NA")
UNIT=$(pgrep -f "vps_sim_ab.sh" >/dev/null 2>&1 && echo "running" || echo "dead")
SIMPID=$(pgrep -f "vps_sim_ab.sh" | head -1)
if [ -n "$SIMPID" ]; then
  CPU_S=$(awk '{print int(($14+$15)/100)}' "/proc/$SIMPID/stat" 2>/dev/null)
  MEM_CUR=$(ps -o rss= -p "$SIMPID" 2>/dev/null | tr -d ' ')
else
  CPU_S=0; MEM_CUR=0
fi
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
MEMUSED=$(free -m | awk '/^Mem:/{print $3"/"$2"MB"}')
XR=$(systemctl is-active xr.service 2>/dev/null)
CF=$(pgrep -c cloudflared 2>/dev/null | head -1); CF=${CF:-0}
IPERF=$(pgrep -c iperf3 2>/dev/null | head -1); IPERF=${IPERF:-0}
QDISC=$(tc qdisc show dev tb-h 2>/dev/null | grep -c netem)
NS=$(ip netns list 2>/dev/null | grep -c tbsim)
DISK=$(df -h /var/log | tail -1 | awk '{print $4}')
# 采样器活性: CSV 末行时间距今
LASTTS=$(tail -1 "$CSV" 2>/dev/null | cut -d, -f1)
STALE=-1
[ -n "${LASTTS:-}" ] && STALE=$((NOW - LASTTS))
# 当前段每流最近速率 (server log 尾部 5 个 interval 均值)
declare -A RATE
for f in "$CUR"/iperf3-server-*.log; do
  [ -f "$f" ] || continue
  p=$(basename "$f" | sed 's/.*-//; s/\.log//')
  v=$(grep -E "sec .*Mbits/sec" "$f" 2>/dev/null | tail -5 \
      | awk '{for(i=1;i<=NF;i++) if($i=="Mbits/sec"){printf "%.2f ", $(i-1)}}' | tr ' ' '\n' | awk 'NF{s+=$1;n++} END{if(n)printf "%.2f", s/n; else print "0"}')
  RATE[$p]=$v
done
ZERO_STREAMS=""
for p in $(echo "${!RATE[@]}" | tr ' ' '\n' | sort); do
  awk -v v="${RATE[$p]:-0}" 'BEGIN{exit !(v < 0.5)}' && ZERO_STREAMS="$ZERO_STREAMS $p"
done

# ---- 告警判定 ----
[ "$UNIT" = "running" ] || WARN+=("实验主进程不在 ($UNIT)")
[ "$IPERF" -ge 12 ] || WARN+=("iperf3 进程只剩 $IPERF 个 (期望≥12: 8 server+8 client)")
[ "$QDISC" = "1" ] || WARN+=("netem qdisc 丢失 (tb-h)")
[ "$NS" = "1" ] || WARN+=("netns tbsim 丢失")
[ "$XR" = "active" ] || WARN+=("业务 xr.service 非 active!")
[ "$CF" -ge 1 ] || WARN+=("cloudflared 进程消失!")
[ "$STALE" -gt 300 ] 2>/dev/null && WARN+=("采样器停摆: CSV 末行已过 ${STALE}s")
[ -n "$ZERO_STREAMS" ] && WARN+=("零速流:$ZERO_STREAMS")
RUNNAME=$(basename "$RUN")
RUNSTART=$(date -d "${RUNNAME:0:8} ${RUNNAME:9:2}:${RUNNAME:11:2}:${RUNNAME:13:2}" +%s 2>/dev/null || echo 0)
[ "$NSEG" -eq 0 ] && [ "$RUNSTART" -gt 0 ] && [ $((NOW - RUNSTART)) -gt 10800 ] && WARN+=("运行>3h 仍无完整段 (进行中: $CUR)")

TS=$(date -Iseconds)
SUM="ts=$TS run=$(basename "$RUN") seg_done=$NSEG cur_seg=$(basename "$CUR") c2=$C2 sim=$UNIT iperf=$IPERF qdisc=$QDISC netns=$NS xr=$XR cf=$CF load=$LOAD mem=$MEMUSED sim_rss_kb=$MEM_CUR cpu_sim_s=$CPU_S disk_free=$DISK sample_stale_s=$STALE"
RATESTR=""
for p in $(echo "${!RATE[@]}" | tr ' ' '\n' | sort); do RATESTR="$RATESTR $p=${RATE[$p]}"; done
LINE="$SUM | rates:$RATESTR"
echo "$LINE" >> "$LOG"
if [ ${#WARN[@]} -gt 0 ]; then
  echo "$TS WARN: ${WARN[*]}" >> "$LOG"
  echo "WARN: ${WARN[*]}"
else
  echo "$TS OK" >> "$LOG"
  echo "OK"
fi
echo "$LINE"
