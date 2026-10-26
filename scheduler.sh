#!/bin/bash
# 监控常驻进程：内置静态页面服务，并按固定间隔巡检（默认 60 秒，仅 ACTIVE_HOURS 时段内执行）。
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/config/monitor.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

: "${DATA_DIR:=/www/data}"
: "${SCAN_INTERVAL_SECONDS:=60}"
: "${ACTIVE_HOURS:=9-17}"

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

# ACTIVE_HOURS=9-17 表示 09:00-17:59（含两端的小时）
in_hours() {
  local h s e
  h=$((10#$(date +%H)))
  s=${ACTIVE_HOURS%%-*}
  e=${ACTIVE_HOURS##*-}
  [ "$h" -ge "$((10#$s))" ] && [ "$h" -le "$((10#$e))" ]
}

log "启动，先执行一次扫描（巡检间隔 ${SCAN_INTERVAL_SECONDS} 秒，时段 ${ACTIVE_HOURS}）"
/bin/bash /scripts/monitor.sh

while true; do
  now=$(date +%s)
  next=$(( (now / SCAN_INTERVAL_SECONDS + 1) * SCAN_INTERVAL_SECONDS ))
  sleep_s=$(( next - now ))
  [ "$sleep_s" -lt 1 ] && sleep_s=1
  sleep "$sleep_s"

  if in_hours; then
    /bin/bash /scripts/monitor.sh
  fi
done
