#!/bin/bash
# vps_sim_watchdog.sh — 实验守护: 主进程不在就续跑重启
# 起因: 宝塔面板 (BT) 例行维护会停 network.target, 连坐杀掉 systemd transient unit
# 对策: 实验脱离 systemd (setsid nohup) + 本 watchdog 每 10 分钟检查并续跑
set -u
OUT=/var/log/tcpboost-sim/current
LOG=/var/log/tcpboost-sim/watchdog.log
SEG_SEC=7200
MAX_SEGS=6          # 6 段 × 2h = 12h (每臂 3 段)
DURATION=24h

log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

if pgrep -f "vps_sim_ab.sh" >/dev/null 2>&1; then
  exit 0
fi
log "主进程不在 → 清理残留并续跑重启"

# 残留清理 (脚本自身 cmdline 不含下列串, 不会自杀)
pkill -9 -f "iperf3 -c 10.77.0.2" 2>/dev/null
for i in $(seq 5201 5208); do pkill -9 -f "iperf3 -s -p $i" 2>/dev/null; done
ip netns del tbsim 2>/dev/null
tc qdisc del dev tb-h root 2>/dev/null
ip link del tb-h 2>/dev/null
sleep 2

mkdir -p "$OUT"
setsid nohup env DURATION="$DURATION" SEG_SEC="$SEG_SEC" MAX_SEGS="$MAX_SEGS" \
  C2_VALS="0 1" RATE=100mbit LOSS=0.5% DELAY_MS=75 OUT="$OUT" \
  /root/vps_sim_ab.sh >> /var/log/tcpboost-sim/run24h.log 2>&1 &
sleep 5
if pgrep -f "vps_sim_ab.sh" >/dev/null 2>&1; then
  log "重启成功 (pid $(pgrep -f vps_sim_ab.sh | head -1))"
else
  log "重启失败!"
fi
