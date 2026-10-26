#!/bin/bash
# 监控常驻进程：内置静态页面服务，并在 09/11/13/15/17 点（Asia/Shanghai）执行扫描。
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/config/monitor.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

: "${DATA_DIR:=/www/data}"
: "${ALERT_HOURS:=9,11,13,15,17}"

log() { echo "[$(date '+%F %T')] $*"; }

mkdir -p "$DATA_DIR/logs" 2>/dev/null || true

# 静态页面 + 扫描生成的 JSON 快照，均由 lighttpd 提供
(
  while true; do
    lighttpd -D -f /etc/lighttpd/log-monitor.conf
    log "lighttpd 退出，1 秒后重启"
    sleep 1
  done
) &

IFS=',' read -r -a HOURS <<< "$ALERT_HOURS"

log "启动，先执行一次扫描"
/bin/bash /scripts/monitor.sh

while true; do
  hh=$((10#$(date +%H)))
  mm=$((10#$(date +%M)))
  ss=$((10#$(date +%S)))
  sod=$(( hh * 3600 + mm * 60 + ss ))

  wait_s=""
  for h in "${HOURS[@]}"; do
    t=$(( 10#$h * 3600 ))
    if [ "$t" -gt "$sod" ]; then wait_s=$(( t - sod )); break; fi
  done
  if [ -z "$wait_s" ]; then
    wait_s=$(( 86400 - sod + 10#${HOURS[0]} * 3600 ))
  fi

  log "下次扫描 ${wait_s} 秒后"
  while [ "$wait_s" -gt 0 ]; do
    if [ "$wait_s" -gt 60 ]; then s=60; else s=$wait_s; fi
    sleep "$s"
    wait_s=$(( wait_s - s ))
  done

  log "到达扫描时间点"
  /bin/bash /scripts/monitor.sh
done
