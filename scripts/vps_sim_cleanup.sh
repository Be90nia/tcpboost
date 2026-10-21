#!/bin/bash
# vps_sim_cleanup.sh — 测试收尾: 清理痕迹 + 还原宝塔重启计划任务 (+ 内核软还原)
# 用法: /root/vps_sim_cleanup.sh [--no-kernel]
#   默认: 清 netns/veth/qdisc、脚本、deb、cron 条目、日志目录; 恢复 crontab 备份;
#         把 grub 默认内核改回 7.2.10-tcpboost+ 并 reboot (车队一致性);
#         保留 7.2.11 内核包未卸载 (可 1 分钟切回)。
set -u
LOG=/var/log/tcpboost-sim-cleanup.log
log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }

# ---------- 1. 停实验 ----------
log "停止实验进程"
pkill -9 -f "iperf3 -c 10.77.0.2" 2>/dev/null
for i in $(seq 5201 5208); do pkill -9 -f "iperf3 -s -p $i" 2>/dev/null; done
pkill -9 -f "vps_sim_ab.sh" 2>/dev/null
sleep 1

# ---------- 2. 删网络痕迹 ----------
log "删除 netns / veth / qdisc"
ip netns del tbsim 2>/dev/null
tc qdisc del dev tb-h root 2>/dev/null
ip link del tb-h 2>/dev/null
ip netns list | grep -c tbsim && log "WARN: netns 仍存在" || log "netns 已清"
ip link show tb-h >/dev/null 2>&1 && log "WARN: tb-h 仍存在" || log "tb-h 已清"

# ---------- 3. 删 cron 条目 ----------
log "删除 /etc/cron.d/tbsim-health"
rm -f /etc/cron.d/tbsim-health

# ---------- 4. 还原宝塔重启计划任务 ----------
if [ -f /root/crontab.bak-20261021 ]; then
  log "还原 crontab (恢复每日 03:30 reboot 任务)"
  crontab /root/crontab.bak-20261021
  crontab -l | grep -E "^30 3 \* \* \*" && log "03:30 reboot 任务已恢复" || log "WARN: 恢复后未找到 03:30 任务"
else
  log "WARN: 找不到备份 /root/crontab.bak-20261021, crontab 未动"
fi

# ---------- 5. 删测试脚本与包 ----------
log "删除测试脚本与内核 deb"
rm -f /root/vps_sim_ab.sh /root/vps_sim_health.sh /root/vps_sim_watchdog.sh /root/vps_sim_collect.sh
rm -f /root/kernel-7.2.11.deb /root/sim_smoke.log /root/deb_dl.log

# ---------- 6. 日志目录 (先确保已拉回本地) ----------
if [ -f /root/ARTIFACTS_PULLED ]; then
  log "删除 /var/log/tcpboost-sim (数据已拉回)"
  rm -rf /var/log/tcpboost-sim
else
  log "保留 /var/log/tcpboost-sim (未见 /root/ARTIFACTS_PULLED 标记, 怕丢数据)"
fi

# ---------- 7. 内核软还原 ----------
if [ "${1:-}" = "--no-kernel" ]; then
  log "跳过内核还原 (--no-kernel)"
else
  log "grub 默认内核改回 7.2.10-tcpboost+ (7.2.11 包保留, 可切回)"
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.2.10-tcpboost+"/' /etc/default/grub
  grep -E "GRUB_DEFAULT" /etc/default/grub
  update-grub >/dev/null 2>&1 && log "update-grub 完成"
  log "5 秒后 reboot (机器日常 03:30 也会自动重启, 业务已适应)"
  (sleep 5; reboot) &
fi
log "收尾完成"
