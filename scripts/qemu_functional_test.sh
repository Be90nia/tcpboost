#!/bin/bash
# scripts/qemu_functional_test.sh - 在 virtme-ng 启动的新内核 VM 内跑全功能冒烟
# 入口: KVER (期望的内核版本字符串, e.g. 6.12.94-tcpboost+)
# 退出: 0 = 全 HARD 过; 非 0 = 至少一项 HARD 失败
set -u

KVER="${1:-}"
if [ -z "$KVER" ]; then
  echo "FATAL: 缺 KVER 参数"
  exit 2
fi

LOG="/tmp/qemu-test.log"
: > "$LOG"
HARD=0
SOFT=0
pass() { echo "  PASS: $1" | tee -a "$LOG"; }
fail_hard() { echo "  HARD-FAIL: $1" | tee -a "$LOG"; HARD=$((HARD+1)); }
fail_soft() { echo "  SOFT-WARN: $1" | tee -a "$LOG"; SOFT=$((SOFT+1)); }

# 准备: 装 iperf3 (vng 共享 host rootfs, 装到 host = VM 内可见)
which iperf3 >/dev/null 2>&1 || { apt-get install -y iperf3 >/dev/null 2>&1 || fail_soft "apt iperf3 失败"; }

# 清理钩子: 杀 iperf3, 卸模块, 删 netem
cleanup() {
  pkill -f 'iperf3 -s' 2>/dev/null
  pkill -f 'iperf3 -c' 2>/dev/null
  tc qdisc del dev lo root 2>/dev/null
  modprobe -r tcp_bbrplusv3 2>/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
  sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=0 2>/dev/null
}
trap cleanup EXIT
cleanup

echo "=== 1. uname 检查 (期望 $KVER) ==="
ACTUAL="$(uname -r)"
if [ "$ACTUAL" = "$KVER" ]; then pass "uname -r = $KVER"
else fail_hard "uname -r=$ACTUAL != $KVER (vng 启的是别的内核)"; fi

echo "=== 2. BBRPlusV3 模块加载 ==="
if modprobe tcp_bbrplusv3 2>>"$LOG"; then
  pass "modprobe tcp_bbrplusv3"
  for p in loss_thresh beta startup_max_ms historical_cache_enable; do
    if [ -r "/sys/module/tcp_bbrplusv3/parameters/$p" ]; then
      pass "param $p = $(cat /sys/module/tcp_bbrplusv3/parameters/$p)"
    else
      fail_soft "param $p 不可读"
    fi
  done
else
  fail_hard "modprobe tcp_bbrplusv3 失败"
fi

echo "=== 3. 可用 CC 列表含 bbrplusv3 ==="
ACC=$(sysctl -n net.ipv4.tcp_available_congestion_control)
if echo "$ACC" | grep -qw bbrplusv3; then pass "tcp_available_congestion_control 含 bbrplusv3 ($ACC)"
else fail_hard "tcp_available_congestion_control=$ACC 不含 bbrplusv3"; fi

echo "=== 4. 切 CC 到 bbrplusv3 ==="
if sysctl -w net.ipv4.tcp_congestion_control=bbrplusv3 >/dev/null 2>&1; then
  CUR=$(sysctl -n net.ipv4.tcp_congestion_control)
  if [ "$CUR" = "bbrplusv3" ]; then pass "tcp_congestion_control=bbrplusv3 生效"
  else fail_hard "写后回读=$CUR"; fi
else
  fail_hard "sysctl -w tcp_congestion_control=bbrplusv3 失败"
fi

echo "=== 5. unstick sysctl 可写 ==="
if sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=0 >/dev/null 2>&1 \
   && sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=1 >/dev/null 2>&1; then
  pass "tcp_rcv_ssthresh_unstick 可写 (0/1)"
else
  fail_hard "tcp_rcv_ssthresh_unstick 不可写 (sysctl 缺失?)"
fi

echo "=== 6. collapse sysctl 可写 ==="
if sysctl -n net.ipv4.tcp_collapse_max_bytes >/dev/null 2>&1; then
  OLD=$(sysctl -n net.ipv4.tcp_collapse_max_bytes)
  if sysctl -w net.ipv4.tcp_collapse_max_bytes=$((OLD+1)) >/dev/null 2>&1; then
    sysctl -w net.ipv4.tcp_collapse_max_bytes=$OLD >/dev/null 2>&1
    pass "tcp_collapse_max_bytes 可写 (原 $OLD)"
  else
    fail_soft "tcp_collapse_max_bytes 存在但不可写"
  fi
else
  fail_soft "tcp_collapse_max_bytes 缺失 (可能本分支未编译 collapse patch)"
fi

echo "=== 7. iperf3 loopback + ss -ti ==="
sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=0 >/dev/null 2>&1
sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
tc qdisc replace dev lo root fq 2>/dev/null
iperf3 -s -D -p 5201 >/dev/null 2>&1
sleep 0.5
OUT=$(iperf3 -c 127.0.0.1 -p 5201 -t 3 -J 2>/dev/null) || { fail_hard "iperf3 -c 失败"; }
SENT=$(echo "$OUT" | grep -o '"bits_per_second":[0-9]*' | tail -1 | cut -d: -f2)
# 流可能在 iperf3 -c 退出后消失, 单独起一个长 server 再 ss
iperf3 -s -D -p 5202 >/dev/null 2>&1
sleep 0.3
( iperf3 -c 127.0.0.1 -p 5202 -t 3 >/dev/null 2>&1 ) &
sleep 0.8
SS_OUT=$(ss -tin 'sport = :5202' 2>/dev/null)
if echo "$SS_OUT" | grep -q bbrplusv3; then
  pass "ss -ti 抓到 bbrplusv3 ($(echo "$SS_OUT" | grep bbrplusv3 | head -1 | tr -s ' '))"
else
  fail_soft "ss -ti 未抓到 bbrplusv3 字样 (可能端口已关): $(echo "$SS_OUT" | head -1)"
fi
pkill -f 'iperf3.*-p 520[12]' 2>/dev/null

echo "=== 8. unstick A/B (早窗期 rcv_ssthresh 对比) ==="
measure_rsa() {
  # 起 server, 客户端 0.4s 取 ss -tin rcv_ssthresh
  iperf3 -s -D -p "$1" >/dev/null 2>&1
  sleep 0.3
  ( iperf3 -c 127.0.0.1 -p "$1" -t 1 >/dev/null 2>&1 ) &
  sleep 0.4
  ss -tin "sport = :$1" 2>/dev/null | awk '/rcv_ssthresh:/ {print $2; exit}' | tr -d ','
  pkill -f "iperf3.*-p $1" 2>/dev/null
}
sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=0 >/dev/null 2>&1
RSA0=$(measure_rsa 5203)
sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=1 >/dev/null 2>&1
RSA1=$(measure_rsa 5204)
if [ -n "$RSA0" ] && [ -n "$RSA1" ]; then
  if [ "$RSA1" -ge "$RSA0" ]; then
    pass "unstick A/B: off=$RSA0  on=$RSA1 (on >= off, 早窗期未退步)"
  else
    fail_hard "unstick A/B: off=$RSA0  on=$RSA1 (on 反而更低, patch 可能未生效)"
  fi
else
  fail_soft "A/B 采样失败 (rsa0='$RSA0' rsa1='$RSA1', ss 可能延迟未抓到)"
fi
sysctl -w net.ipv4.tcp_rcv_ssthresh_unstick=0 >/dev/null 2>&1

echo "=== 9. 卸载再加载 ==="
if modprobe -r tcp_bbrplusv3 2>>"$LOG"; then pass "modprobe -r"
else fail_hard "modprobe -r 失败"; fi
modprobe tcp_bbrplusv3 2>/dev/null

echo "=== SOFT: 8 并发短跑 (无 netem) ==="
for p in 5210 5211 5212 5213 5214 5215 5216 5217; do iperf3 -s -D -p $p >/dev/null 2>&1; done
sleep 0.5
PIDS=""
for p in 5210 5211 5212 5213 5214 5215 5216 5217; do
  iperf3 -c 127.0.0.1 -p $p -t 2 -P 1 >/dev/null 2>&1 &
  PIDS="$PIDS $!"
done
wait $PIDS 2>/dev/null
pkill -f 'iperf3.*-p 521[0-7]' 2>/dev/null
pass "8 并发短跑完成"

echo "=== SOFT: netem 双腿 loss 0.5% 8 流 3s ==="
tc qdisc add dev lo root handle 1: prio bands 4 2>/dev/null
tc qdisc add dev lo parent 1:4 handle 40: netem delay 75ms 75ms loss 0.5% 2>/dev/null
for p in 5220 5221 5222 5223 5224 5225 5226 5227; do iperf3 -s -D -p $p >/dev/null 2>&1; done
sleep 0.5
BPS_TOTAL=0
for p in 5220 5221 5222 5223 5224 5225 5226 5227; do
  R=$(iperf3 -c 127.0.0.1 -p $p -t 3 -J 2>/dev/null | grep -o '"bits_per_second":[0-9]*' | tail -1 | cut -d: -f2)
  BPS_TOTAL=$((BPS_TOTAL + ${R:-0}))
done
TC_TOTAL_MBPS=$((BPS_TOTAL / 3 / 1000000))
if [ "$TC_TOTAL_MBPS" -gt 0 ]; then pass "8 流 netem 总吞吐 ${TC_TOTAL_MBPS} Mbps"
else fail_soft "8 流 netem 吞吐为 0 (取样失败)"; fi
pkill -f 'iperf3.*-p 522[0-7]' 2>/dev/null
tc qdisc del dev lo root 2>/dev/null

echo "=== 总结 ==="
echo "HARD-FAIL: $HARD"
echo "SOFT-WARN: $SOFT"
if [ "$HARD" -gt 0 ]; then
  echo "VERDICT: FAIL"
  exit 1
else
  echo "VERDICT: PASS"
  exit 0
fi
