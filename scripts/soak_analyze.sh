#!/bin/bash
# scripts/soak_analyze.sh - 长跑结果分析器
# 用法: sudo bash soak_analyze.sh <输出目录>
# 输入: <目录>/timeseries.csv + samples.jsonl
# 输出: <目录>/summary.md + regression.md (机器可读 VERDICT)

set -u
OUT="${1:-}"
[ -n "$OUT" ] || { echo "usage: $0 <out-dir>"; exit 2; }
CSV="$OUT/timeseries.csv"
[ -f "$CSV" ] || { echo "FATAL: $CSV 缺失"; exit 1; }

# 阈值
WARN_TOTAL_DROP="${WARN_TOTAL_DROP:-5}"   # %
FAIL_TOTAL_DROP="${FAIL_TOTAL_DROP:-15}"
WARN_P50_DROP="${WARN_P50_DROP:-10}"
FAIL_MIN_DROP="${FAIL_MIN_DROP:-30}"
WARN_ORPHAN_GROW="${WARN_ORPHAN_GROW:-100}"  # 绝对增量
FAIL_PSI_CPU="${FAIL_PSI_CPU:-5}"      # %
WARN_MEM_RISE="${WARN_MEM_RISE:-5}"    # 绝对 % 增量
FAIL_LOAD_RISE="${FAIL_LOAD_RISE:-1.0}"

awk -F, -v out="$OUT" -v warn_total="$WARN_TOTAL_DROP" -v fail_total="$FAIL_TOTAL_DROP" \
    -v warn_p50="$WARN_P50_DROP" -v fail_min="$FAIL_MIN_DROP" \
    -v warn_orphan="$WARN_ORPHAN_GROW" -v fail_psi="$FAIL_PSI_CPU" \
    -v warn_mem="$WARN_MEM_RISE" -v fail_load="$FAIL_LOAD_RISE" '
function pct(a, b) {  # 变化率 % (b 基线, a 当前)
  if (b == 0) return (a == 0 ? 0 : 999)
  return (a - b) * 100 / b
}
function verdict(pct_drop, warn_thr, fail_thr) {
  if (pct_drop < 0) {
    # 下降
    if (-pct_drop >= fail_thr) return "FAIL"
    if (-pct_drop >= warn_thr) return "WARN"
    return "OK"
  }
  return "OK"  # 上升算 OK (吞吐涨是好)
}
function reg_row(metric, baseline, current, ver, note) {
  delta = current - baseline
  dpct = pct(current, baseline)
  return metric " | baseline=" baseline " current=" current " delta=" delta " dpct=" dpct " | " ver " | " note
}
BEGIN { OFS="|"; }
NR == 1 { next }  # 跳表头
{ data[NR-1] = $0; n++; if (n == 1) start_epoch = $1 }
END {
  if (n < 10) { print "FATAL: 数据点 < 10"; exit 1 }

  # 找首末 30min 区间
  end_epoch = data[n]
  first_30_end = start_epoch + 1800
  last_30_start = end_epoch - 1800

  for (i = 1; i <= n; i++) {
    split(data[i], a, ",")
    if (a[1] <= first_30_end) { fn++; for (k=2;k<=NF-1;k++) first_30[k] += a[k] }
    if (a[1] >= last_30_start) { ln++; for (k=2;k<=NF-1;k++) last_30[k] += a[k] }
  }
  for (k=2;k<=21;k++) {
    first_30[k] = (fn>0) ? first_30[k]/fn : 0
    last_30[k]  = (ln>0) ? last_30[k]/ln : 0
  }

  # 列对应: 2=total_mbps 3=min_mbps 4=p50_mbps 5=max_mbps 6=active
  # 7=tcp_estab 8=tw 9=inuse 10=orphan 11=conntrack
  # 12=psicpu 13=psimem 14=psiio 15=load1 16=load5 17=load15
  # 18=cpu_pct 19=mem_pct 20=unstick

  issues = 0
  fail_count = 0
  warn_count = 0
  print "metric | baseline (首30min) | current (末30min) | delta | dpct% | verdict | note"
  print "---|---|---|---|---|---|---"

  # total_mbps
  dpct = pct(last_30[2], first_30[2])
  v = verdict(dpct, warn_total+0, fail_total+0)
  print reg_row("total_mbps", first_30[2], last_30[2], v, "")
  if (v == "FAIL") fail_count++; else if (v == "WARN") warn_count++

  # p50_mbps
  dpct = pct(last_30[4], first_30[4])
  v = verdict(dpct, warn_p50+0, 999)
  print reg_row("p50_mbps", first_30[4], last_30[4], v, "")
  if (v == "WARN") warn_count++

  # min_mbps (饿死指标)
  dpct = pct(last_30[3], first_30[3])
  if (dpct < 0 && -dpct >= fail_min) { v = "FAIL" } else if (dpct < 0 && -dpct >= fail_min/2) { v = "WARN" } else { v = "OK" }
  print reg_row("min_mbps", first_30[3], last_30[3], v, "饿死敏感")
  if (v == "FAIL") fail_count++; else if (v == "WARN") warn_count++

  # active streams
  dpct = pct(last_30[6], first_30[6])
  if (dpct < -20) { v = "WARN" } else { v = "OK" }
  print reg_row("active_streams", first_30[6], last_30[6], v, "")
  if (v == "WARN") warn_count++

  # orphan 增长 (泄漏信号)
  delta = last_30[10] - first_30[10]
  if (delta > warn_orphan) { v = "FAIL" } else if (delta > warn_orphan/2) { v = "WARN" } else { v = "OK" }
  print reg_row("tcp_orphan", first_30[10], last_30[10], v, "泄漏/未清理 fd")
  if (v == "FAIL") fail_count++; else if (v == "WARN") warn_count++

  # psi.cpu sustained
  if (last_30[12] >= fail_psi) { v = "FAIL" } else if (last_30[12] >= fail_psi/2) { v = "WARN" } else { v = "OK" }
  print reg_row("psi.cpu_some", first_30[12], last_30[12], v, "持续 CPU 争抢")
  if (v == "FAIL") fail_count++; else if (v == "WARN") warn_count++

  # psi.mem
  if (last_30[13] >= fail_psi*2) { v = "WARN" } else { v = "OK" }
  print reg_row("psi.mem_some", first_30[13], last_30[13], v, "")
  if (v == "WARN") warn_count++

  # psi.io
  if (last_30[14] >= fail_psi*2) { v = "WARN" } else { v = "OK" }
  print reg_row("psi.io_some", first_30[14], last_30[14], v, "")
  if (v == "WARN") warn_count++

  # load1
  delta = last_30[15] - first_30[15]
  if (delta > fail_load) { v = "FAIL" } else if (delta > fail_load/2) { v = "WARN" } else { v = "OK" }
  print reg_row("load1", first_30[15], last_30[15], v, "")
  if (v == "FAIL") fail_count++; else if (v == "WARN") warn_count++

  # mem_pct
  delta = last_30[19] - first_30[19]
  if (delta > warn_mem) { v = "FAIL" } else if (delta > warn_mem/2) { v = "WARN" } else { v = "OK" }
  print reg_row("mem_pct", first_30[19], last_30[19], v, "进程内存压力")
  if (v == "FAIL") fail_count++; else if (v == "WARN") warn_count++

  # verdict
  if (fail_count > 0) verdict = "FAIL"
  else if (warn_count >= 3) verdict = "FAIL"
  else if (warn_count > 0) verdict = "WARN"
  else verdict = "PASS"

  printf "\nFAIL=%d WARN=%d\n", fail_count, warn_count
  printf "VERDICT: %s\n", verdict
}' "$CSV" > "$OUT/regression.md"

# 渲染人类可读 summary.md
SUMMARY="$OUT/summary.md"
TOTAL_LINES=$(wc -l < "$CSV")
DUR=$(awk -F, 'NR==2{start=$1} END{print int(($1-start)/60)"min"}' "$CSV")
UNSTICK=$(awk -F, 'NR==2{print $21}' "$CSV")
{
  echo "# 长跑套件结果 - $(basename "$OUT")"
  echo ""
  echo "- 时长: $DUR (共 $TOTAL_LINES 个 30s 采样点)"
  echo "- unstick sysctl 状态: $UNSTICK"
  echo "- 生成: $(date -Iseconds)"
  echo ""
  echo "## 退化判定"
  echo ""
  echo '```'
  cat "$OUT/regression.md"
  echo '```'
  echo ""
  echo "## 判读指南"
  echo ""
  echo "- **VERDICT: PASS** = 5h 持久运行无显著退化, 放心上生产"
  echo "- **VERDICT: WARN** = 存在轻度退化, 需看具体 metric 决定 (min_mbps 降 = 饿死重现)"
  echo "- **VERDICT: FAIL** = 显著退化, **不能上生产**, 复现你之前\"用久降速\"问题"
  echo ""
  echo "## 重点关注指标"
  echo ""
  echo "| 指标 | 含义 | FAIL 含义 |"
  echo "|---|---|---|"
  echo "| min_mbps | 最慢流速率 | 流饿死重现 (本次补丁的对症问题) |"
  echo "| total_mbps | 8 流总吞吐 | 整体性能下降 |"
  echo "| tcp_orphan | 未挂载的 socket | fd 泄漏 (用户态/内核态) |"
  echo "| psi.cpu_some | CPU 压力 | 内核/进程在争 CPU (可能软锁/自旋) |"
  echo "| mem_pct | 内存占用 | 内存泄漏 |"
  echo "| load1 | 系统负载 | 综合退化 |"
  echo ""
  echo "## 原始数据"
  echo ""
  echo "- 时序 CSV: timeseries.csv"
  echo "- 详细 JSONL: samples.jsonl"
  echo "- 每流速率: streams/stream-1..8.jsonl"
  echo ""
} > "$SUMMARY"

# 终端 echo
echo ""
echo "================================================"
echo "  长跑套件分析结果: $OUT"
echo "================================================"
cat "$OUT/regression.md"
echo ""
echo "详情: $SUMMARY"
