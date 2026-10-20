#!/bin/bash
# vps_sim_collect.sh — 把 24h 段的产物按 c2 值合并成两臂, 供分析器直接消费
# 产出: $ROOT/c2_0/{iperf3-server-<port>.log,timeseries.csv}  c2_1/{...}
# 用法: ./vps_sim_collect.sh [RUN_DIR]   (默认取 /var/log/tcpboost-sim 下最新)
set -u
ROOT=${1:-$(ls -d /var/log/tcpboost-sim/*/ 2>/dev/null | grep -v run24h | sort | tail -1)}
[ -d "$ROOT" ] || { echo "FATAL: 无 run 目录"; exit 1; }
SEGCSV="$ROOT/segments.csv"
[ -f "$SEGCSV" ] || { echo "FATAL: 缺 $SEGCSV"; exit 1; }

echo "ROOT=$ROOT"
for arm in 0 1; do
  mkdir -p "$ROOT/c2_$arm"
  : > "$ROOT/c2_$arm/timeseries.csv"
done
head -1 <(head -1 "$ROOT/seg-00/timeseries.csv") > /dev/null 2>&1

# 每段: 按 c2 值把 8 个流 log 追加进对应臂; timeseries 也追加 (保留 c2 列)
tail -n +2 "$SEGCSV" | while IFS=, read -r seg c2 s0 s1 el; do
  [ -z "${c2:-}" ] && continue
  src="$ROOT/seg-$(printf '%02d' "$seg")"
  [ -d "$src" ] || { echo "WARN: 缺段目录 $src"; continue; }
  for f in "$src"/iperf3-server-*.log; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    echo "--- segment $seg (c2=$c2) ---" >> "$ROOT/c2_$c2/$base"
    cat "$f" >> "$ROOT/c2_$c2/$base"
  done
  if [ -f "$ROOT/c2_$c2/timeseries.csv" ]; then
    [ -s "$ROOT/c2_$c2/timeseries.csv" ] || head -1 "$src/timeseries.csv" > "$ROOT/c2_$c2/timeseries.csv"
    tail -n +2 "$src/timeseries.csv" >> "$ROOT/c2_$c2/timeseries.csv"
  fi
  echo "seg$seg -> c2_$c2"
done

echo "--- 汇总 ---"
for arm in 0 1; do
  n=$(ls "$ROOT/c2_$arm"/iperf3-server-*.log 2>/dev/null | wc -l)
  rows=$(wc -l < "$ROOT/c2_$arm/timeseries.csv" 2>/dev/null || echo 0)
  echo "c2_$arm: 流日志=$n timeseries 行=$rows"
done
echo "TAR: tar czf $ROOT.tgz -C $(dirname "$ROOT") $(basename "$ROOT")"
tar czf "$ROOT.tgz" -C "$(dirname "$ROOT")" "$(basename "$ROOT")"
ls -l "$ROOT.tgz"
