#!/bin/bash
# ab_bench.sh — BBRPlusV3 batch 特性 A/B 基准 (keep/reject 门禁)
#
# 方法论 (2026-10-08 用户定): 基准内核 + 修复一个测试一个; 优秀则留, 不行打回。
#
# 实验矩阵 (单内核 sysfs 开关切配置):
#   E0  基准内核 (baseline/pre-batch1 分支产物, 无 batch-1 代码)
#   E1  variant 内核, smart_exit_enable=0 codel_enable=0   (param-off sanity)
#   E2  variant 内核, smart_exit_enable=1 codel_enable=0   (Smart Exit 归因)
#   E3  variant 内核, smart_exit_enable=0 codel_enable=1   (CoDel 归因)
#   E4  variant 内核, 两者 on                              (组合效应)
#
# 判定门禁 (每特性独立):
#   G1 单流回归:  0-loss 单流吞吐 >= 基准 x 0.98
#   G2 饿流改善:  netem 8 流饿流数 < 基准饿流数
#   G3 总量不退:  netem 8 流总吞吐 >= 基准 x 0.95
#   通过 -> keep (参数默认 on); 不过 -> 该特性 enable=0 打回 (留码待重做)
#
# 用法: 在目标机 (QEMU 镜像或 VPS) 上, 与对应内核一起:
#   E0: ab_bench.sh E0
#   E1: ab_bench.sh E1   (E2/E3/E4 同理)
# 输出: /tmp/ab_bench_<variant>.json 风格文本 + STDOUT 表格
# 依赖: iperf3, tc/netem, ss; root
#
# ponytail: 相对阈值内建 (饿流 = < max(200Kbps, 0.15x中位数)); VPS 90s 严格
#   复现 (xhttp-starvation-report.md 配方) 属 atj/人工层, 本脚本做 keep/reject 快门。

set -u

VARIANT="${1:?usage: ab_bench.sh E0|E1|E2|E3|E4}"
DUR_SINGLE="${DUR_SINGLE:-10}"
DUR_NETEM="${DUR_NETEM:-30}"
P="/sys/module/tcp_bbrplusv3/parameters"
OUT="/tmp/ab_bench_${VARIANT}.txt"
: > "$OUT"

SE=0; CE=0
case "$VARIANT" in
  E0) SE=""; CE="" ;;               # 基准内核无参数
  E1) SE=0; CE=0 ;;
  E2) SE=1; CE=0 ;;
  E3) SE=0; CE=1 ;;
  E4) SE=1; CE=1 ;;
  *) echo "unknown variant $VARIANT" >&2; exit 2 ;;
esac

log() { echo "$*" | tee -a "$OUT"; }

set_params() {
  if [ "$SE" = "" ]; then return 0; fi
  echo "$SE" > "$P/smart_exit_enable" 2>/dev/null
  echo "$CE" > "$P/codel_enable" 2>/dev/null
  log "params: smart_exit_enable=$(cat "$P/smart_exit_enable" 2>/dev/null) codel_enable=$(cat "$P/codel_enable" 2>/dev/null)"
}

# 单流 0-loss: 取 3 次中位 bps
bench_single() {
  iperf3 -s -D -p 5301 >/dev/null 2>&1
  sleep 0.3
  B=""
  for _ in 1 2 3; do
    R=$(iperf3 -c 127.0.0.1 -p 5301 -t "$DUR_SINGLE" -J 2>/dev/null \
        | grep -o '"bits_per_second":[0-9]*' | tail -1 | cut -d: -f2)
    [ -n "${R:-}" ] && B="$B $R"
  done
  pkill -f 'iperf3.*-p 5301' 2>/dev/null
  MED=$(printf '%s\n' $B | sort -n | sed -n '2p')
  echo "${MED:-0}"
}

# netem 双腿 loss 0.5% x 150ms, 8 并发; 输出 "total_bps starved_count"
bench_netem8() {
  tc qdisc add dev lo root handle 1: prio bands 4 2>/dev/null
  tc qdisc add dev lo parent 1:4 handle 40: netem delay 75ms 75ms loss 0.5% 2>/dev/null
  P_LIST=""
  for p in 5310 5311 5312 5313 5314 5315 5316 5317; do
    iperf3 -s -D -p $p >/dev/null 2>&1
    P_LIST="$P_LIST $p"
  done
  sleep 0.5
  RATES=""
  for p in $P_LIST; do
    ( iperf3 -c 127.0.0.1 -p $p -t "$DUR_NETEM" -J 2>/dev/null \
      | grep -o '"bits_per_second":[0-9]*' | tail -1 | cut -d: -f2 \
      > "/tmp/ab_${VARIANT}_$p.bps" ) &
  done
  wait 2>/dev/null
  T=0; N=0
  for p in $P_LIST; do
    R=$(cat "/tmp/ab_${VARIANT}_$p.bps" 2>/dev/null || echo 0)
    rm -f "/tmp/ab_${VARIANT}_$p.bps"
    RATES="$RATES ${R:-0}"
    T=$((T + ${R:-0}))
    N=$((N + 1))
  done
  SORTED=$(printf '%s\n' $RATES | sort -n)
  MEDIAN=$(printf '%s\n' $SORTED | sed -n '5p')
  THRESH=$(( 200000 ))
  [ "$MEDIAN" -gt 0 ] && [ $(( MEDIAN * 15 / 100 )) -gt "$THRESH" ] \
    && THRESH=$(( MEDIAN * 15 / 100 ))
  STARVED=0
  for r in $RATES; do [ "$r" -lt "$THRESH" ] && STARVED=$((STARVED + 1)); done
  pkill -f 'iperf3.*-p 531[0-7]' 2>/dev/null
  tc qdisc del dev lo root 2>/dev/null
  echo "$T $STARVED"
}

log "=== ab_bench $VARIANT (single=${DUR_SINGLE}s x3, netem8=${DUR_NETEM}s) ==="
set_params

S=$(bench_single)
read -r NTOT NSRV <<EOF
$(bench_netem8)
EOF
log "SINGLE_MED_BPS=$S"
log "NETEM8_TOTAL_BPS=$NTOT"
log "NETEM8_STARVED=$NSRV"
log "=== done $VARIANT ==="
echo "OK: results in $OUT"
