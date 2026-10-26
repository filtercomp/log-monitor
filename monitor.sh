#!/bin/bash
# 错误日志监控：扫描指定命名空间下所有 Pod 的错误日志目录，
# 按工作负载（Deployment/StatefulSet 等）聚合后推送企业微信摘要，
# 同时把每个工作负载的最新日志快照写入页面数据目录（仅保留当天）。
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/config/monitor.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

: "${CLUSTER_NAME:=cn-prod}"
: "${ERROR_LOG_DIR:=/tmp/logs/error}"
: "${CHECK_INTERVAL_HOURS:=2}"
: "${MAX_MESSAGES:=20}"
: "${INCLUDE_NAMESPACES:=}"
: "${EXCLUDE_NAMESPACES:=kube-system,kube-public,kube-node-lease}"
: "${EXCLUDE_CONTAINERS:=^(istio-proxy|linkerd-proxy|.*-init)$}"
: "${DRY_RUN:=false}"
: "${WECOM_WEBHOOK_URL:=}"
: "${WEB_BASE_URL:=}"
: "${DATA_DIR:=/www/data}"
: "${SNAPSHOT_LINES:=2000}"
: "${ALERT_HOURS:=9,11,13,15,17}"

# 启动时的首次扫描只负责填充页面数据；仅在告警时间点的前 15 分钟内推送企微
SEND_ALLOWED=false
IFS=',' read -r -a ALERT_HOUR_LIST <<< "$ALERT_HOURS"
CUR_HOUR=$((10#$(date +%H)))
CUR_MIN=$((10#$(date +%M)))
for _h in "${ALERT_HOUR_LIST[@]}"; do
  if [ "$CUR_HOUR" -eq "$((10#$_h))" ] && [ "$CUR_MIN" -lt 15 ]; then SEND_ALLOWED=true; fi
done

NOW=$(date +%s)
START=$(( NOW - CHECK_INTERVAL_HOURS * 3600 - 600 ))   # 窗口额外加 10 分钟容差
SCAN_TIME=$(date '+%F %T')
TODAY=$(date '+%F')
SCAN_ID=$(date '+%Y%m%d%H%M%S')

log() { echo "[$(date '+%F %T')] $*"; }

human_size() {
  awk -v s="$1" 'BEGIN { if (s < 1024) printf "%d B", s; else if (s < 1048576) printf "%.1f KB", s/1024; else printf "%.1f MB", s/1048576 }'
}

send_wecom() {
  local content="$1"
  if [ "$DRY_RUN" = "true" ]; then
    log "DRY_RUN=on，不发送。消息内容："
    printf '%s\n' "$content"
    return 0
  fi
  if [ -z "$WECOM_WEBHOOK_URL" ]; then
    log "未配置 WECOM_WEBHOOK_URL，跳过发送"
    return 1
  fi
  local payload resp
  payload=$(jq -n --arg c "$content" '{msgtype:"markdown",markdown:{content:$c}}')
  resp=$(curl -sS --max-time 10 -H 'Content-Type: application/json' -d "$payload" "$WECOM_WEBHOOK_URL" 2>&1) || true
  log "webhook 响应：$resp"
  case "$resp" in
    *'"errcode":0'*) return 0 ;;
    *) return 1 ;;
  esac
}

# 在容器内执行的探测脚本（由远端 sh 执行，参数：日志目录 起始时间戳 行数）
read -r -d '' PROBE <<'EOS' || true
d="$1"; since="$2"; n="$3"
[ -d "$d" ] || exit 3
cd "$d" || exit 3
cnt=0; newest=""; newest_mt=0; newest_sz=0
for f in *.log; do
  [ -f "$f" ] || continue
  mt=$(stat -c %Y "$f" 2>/dev/null) || continue
  [ "$mt" -ge "$since" ] || continue
  cnt=$(( cnt + 1 ))
  if [ "$mt" -gt "$newest_mt" ]; then
    newest="$f"; newest_mt="$mt"; newest_sz=$(wc -c < "$f" | tr -d ' ')
  fi
done
[ "$cnt" -gt 0 ] || exit 4
echo "@@COUNT=$cnt"
echo "@@FILE=$newest"
echo "@@MTIME=$newest_mt"
echo "@@SIZE=$newest_sz"
echo "@@MTIME_STR=$(date '+%F %T' -r "$newest" 2>/dev/null)"
echo "@@LOGS-BEGIN"
tail -n "$n" "$newest"
echo "@@LOGS-END"
EOS

META_FILE="$DATA_DIR/alerts.json"
mkdir -p "$DATA_DIR/logs" 2>/dev/null || true

# 跨天时清空前一日的快照，页面只展示当天记录
prev_date=""
if [ -s "$META_FILE" ]; then
  prev_date=$(jq -r '.date // ""' "$META_FILE" 2>/dev/null || true)
fi
if [ "$prev_date" != "$TODAY" ]; then
  rm -f "$DATA_DIR"/logs/*.json 2>/dev/null || true
  jq -n --arg date "$TODAY" --arg now "$SCAN_TIME" --arg cluster "$CLUSTER_NAME" \
    '{date:$date, updated_at:$now, cluster:$cluster, alerts:[]}' > "$META_FILE" 2>/dev/null || true
fi

# ---- 计算需要扫描的命名空间 ----
mapfile -t ALL_NS < <(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
declare -a NS_LIST=()
IFS=',' read -r -a INC <<< "$INCLUDE_NAMESPACES"
IFS=',' read -r -a EXC <<< "$EXCLUDE_NAMESPACES"
for ns in "${ALL_NS[@]}"; do
  [ -z "$ns" ] && continue
  skip=0
  if [ -n "$INCLUDE_NAMESPACES" ]; then
    skip=1
    for i in "${INC[@]}"; do [ "$(echo "$i" | xargs)" = "$ns" ] && skip=0; done
  else
    for e in "${EXC[@]}"; do [ "$(echo "$e" | xargs)" = "$ns" ] && skip=1; done
  fi
  [ "$skip" = "0" ] && NS_LIST+=("$ns")
done

log "扫描命名空间：${NS_LIST[*]:-<无>}，窗口 ${CHECK_INTERVAL_HOURS} 小时，快照 ${SNAPSHOT_LINES} 行"

sent=0
attempts=0
skipped_by_limit=0

# 同一工作负载（Deployment/StatefulSet 等）的多个 Pod 聚合为一条告警
declare -A POD_WL=() RS_WL=()
declare -A AGG_SEEN=() AGG_PODS=() AGG_CTRS=() AGG_HITS=() AGG_FCOUNT=()
declare -A AGG_MTIME=() AGG_MTIME_STR=() AGG_FILE=() AGG_SIZE=()
declare -A AGG_REP_POD=() AGG_REP_CTR=()
declare -a AGG_ORDER=()

# 每个 Pod/容器 各保留一份日志快照；同一工作负载的不同副本内容可能不同
declare -A SRC_IDX=() SRC_WKEY=() SRC_POD=() SRC_CTR=() SRC_FILE=()
declare -A SRC_MTIME=() SRC_MTIME_STR=() SRC_SIZE=() SRC_FCOUNT=() SRC_BODY_FILE=()
declare -a SRC_ORDER=()
SCAN_TMP=$(mktemp -d /tmp/log-monitor-scan.XXXXXX)
trap 'rm -rf "$SCAN_TMP"' EXIT

for ns in "${NS_LIST[@]}"; do
  mapfile -t PODS < <(kubectl get pods -n "$ns" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  for pod in "${PODS[@]}"; do
    [ -z "$pod" ] && continue

    # 解析 Pod 归属的工作负载；Deployment 的 Pod 属于 ReplicaSet，需要再查一层
    if [ -z "${POD_WL["$ns/$pod"]:-}" ]; then
      owner=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
      okind=${owner%%/*}; oname=${owner#*/}
      if [ "$okind" = "ReplicaSet" ] && [ -n "$oname" ]; then
        dep="${RS_WL["$ns/$oname"]:-}"
        if [ -z "$dep" ]; then
          dep=$(kubectl get rs -n "$ns" "$oname" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
          RS_WL["$ns/$oname"]="$dep"
        fi
        [ -n "$dep" ] && okind="Deployment" && oname="$dep"
      fi
      [ -z "$oname" ] && okind="Pod" && oname="$pod"
      POD_WL["$ns/$pod"]="$okind/$oname"
    fi
    wkey="$ns|${POD_WL["$ns/$pod"]}"

    mapfile -t CONTAINERS < <(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n')
    for c in "${CONTAINERS[@]}"; do
      [ -z "$c" ] && continue
      if printf '%s' "$c" | grep -qE "$EXCLUDE_CONTAINERS"; then continue; fi

      raw=$(timeout 40 kubectl exec -n "$ns" "$pod" -c "$c" -- sh -c "$PROBE" sh "$ERROR_LOG_DIR" "$START" "$SNAPSHOT_LINES" 2>/dev/null)
      rc=$?
      if [ $rc -eq 4 ]; then continue; fi          # 窗口内无变更
      if [ $rc -ne 0 ]; then
        log "跳过 $ns/$pod/$c（exec rc=$rc，可能无该目录或无权限）"
        continue
      fi

      # 解析返回块（每个 Pod/容器 一个块）
      fname=""; fsize=""; fmtime=""; fmstr=""; fcount="0"; body=""; in_body=0
      while IFS= read -r line; do
        case "$line" in
          @@COUNT=*) fcount="${line#@@COUNT=}" ;;
          @@FILE=*) fname="${line#@@FILE=}" ;;
          @@MTIME=*) fmtime="${line#@@MTIME=}" ;;
          @@MTIME_STR=*) fmstr="${line#@@MTIME_STR=}" ;;
          @@SIZE=*) fsize="${line#@@SIZE=}" ;;
          @@LOGS-BEGIN) in_body=1 ;;
          @@LOGS-END) in_body=2 ;;
          *) [ "$in_body" = "1" ] && body="${body}${line}"$'\n' ;;
        esac
      done <<< "$raw"

      [ -z "$fname" ] && continue

      # 按工作负载聚合：记录所有副本，日志正文按 Pod/容器 各自落一份临时文件
      if [ -z "${AGG_SEEN[$wkey]:-}" ]; then
        AGG_SEEN["$wkey"]=1
        AGG_ORDER+=("$wkey")
      fi
      AGG_HITS["$wkey"]=$(( ${AGG_HITS[$wkey]:-0} + 1 ))
      pods="${AGG_PODS[$wkey]:-}"
      case ",$pods," in *",$pod,"*) ;; *) pods="${pods:+$pods,}$pod" ;; esac
      AGG_PODS["$wkey"]="$pods"
      ctrs="${AGG_CTRS[$wkey]:-}"
      case ",$ctrs," in *",$c,"*) ;; *) ctrs="${ctrs:+$ctrs,}$c" ;; esac
      AGG_CTRS["$wkey"]="$ctrs"
      if [ "${AGG_MTIME[$wkey]:-0}" -lt "$fmtime" ]; then
        AGG_MTIME["$wkey"]="$fmtime"
        AGG_MTIME_STR["$wkey"]="$fmstr"
        AGG_FILE["$wkey"]="$fname"
        AGG_SIZE["$wkey"]="$fsize"
        AGG_FCOUNT["$wkey"]="$fcount"
        AGG_REP_POD["$wkey"]="$pod"
        AGG_REP_CTR["$wkey"]="$c"
      fi

      # 同一 Pod/容器 只登记一次，正文写入临时文件供后续生成快照
      skey="$wkey|$pod|$c"
      if [ -z "${SRC_IDX[$skey]:-}" ]; then
        sidx=${#SRC_ORDER[@]}
        SRC_IDX["$skey"]="$sidx"
        SRC_ORDER+=("$skey")
      else
        sidx="${SRC_IDX[$skey]}"
      fi
      SRC_WKEY["$sidx"]="$wkey"
      SRC_POD["$sidx"]="$pod"
      SRC_CTR["$sidx"]="$c"
      SRC_FILE["$sidx"]="$fname"
      SRC_MTIME["$sidx"]="$fmtime"
      SRC_MTIME_STR["$sidx"]="$fmstr"
      SRC_SIZE["$sidx"]="$fsize"
      SRC_FCOUNT["$sidx"]="$fcount"
      SRC_BODY_FILE["$sidx"]="$SCAN_TMP/src-$sidx.log"
      printf '%s' "$body" > "${SRC_BODY_FILE[$sidx]}"
    done
  done
done

# ---- 按工作负载逐条写入页面数据并发送告警 ----
found_total=${#AGG_ORDER[@]}
idx=0
for wkey in "${AGG_ORDER[@]}"; do
  idx=$(( idx + 1 ))
  id="${SCAN_ID}-$(printf '%02d' "$idx")"

  wns="${wkey%%|*}"; wl="${wkey#*|}"
  rpod="${AGG_REP_POD[$wkey]}"; rctr="${AGG_REP_CTR[$wkey]}"
  rfname="${AGG_FILE[$wkey]}"; rsize="${AGG_SIZE[$wkey]}"
  rmt="${AGG_MTIME[$wkey]}"; rmstr="${AGG_MTIME_STR[$wkey]:-}"
  rfc="${AGG_FCOUNT[$wkey]}"
  hits="${AGG_HITS[$wkey]}"; pods="${AGG_PODS[$wkey]}"; ctrs="${AGG_CTRS[$wkey]}"
  [ -z "$rmstr" ] && rmstr="$rmt"

  if [ -n "$WEB_BASE_URL" ]; then
    link="${WEB_BASE_URL}/#/alert/${id}"
  else
    link=""
  fi

  pods_json=$(printf '%s' "$pods" | jq -R 'split(",") | map(select(length > 0))')
  ctrs_json=$(printf '%s' "$ctrs" | jq -R 'split(",") | map(select(length > 0))')

  # 为该工作负载下的每个 Pod/容器 各生成一份快照与副本元数据
  src_jsonl="$SCAN_TMP/sources-$id.jsonl"
  : > "$src_jsonl"
  src_count=0
  total_err=0
  total_exc=0
  for ((si=0; si<${#SRC_ORDER[@]}; si++)); do
    [ "${SRC_WKEY[$si]:-}" = "$wkey" ] || continue
    src_count=$(( src_count + 1 ))
    sid="$id-$(printf '%02d' "$src_count")"
    spod="${SRC_POD[$si]}"; sctr="${SRC_CTR[$si]}"
    sfile="${SRC_FILE[$si]}"; smt="${SRC_MTIME[$si]}"
    smstr="${SRC_MTIME_STR[$si]:-}"; ssize="${SRC_SIZE[$si]}"
    sfc="${SRC_FCOUNT[$si]}"; sbody="${SRC_BODY_FILE[$si]}"
    [ -z "$smstr" ] && smstr="$smt"

    serr=$(grep -c 'ERROR' "$sbody" 2>/dev/null || true)
    sexc=$(grep -ci 'exception' "$sbody" 2>/dev/null || true)
    [ -z "$serr" ] && serr=0
    [ -z "$sexc" ] && sexc=0
    total_err=$(( total_err + serr ))
    total_exc=$(( total_exc + sexc ))

    if jq -n --arg id "$sid" --arg ns "$wns" --arg workload "$wl" \
        --arg pod "$spod" --arg container "$sctr" --rawfile raw "$sbody" \
        '{id:$id, namespace:$ns, workload:$workload, pod:$pod, container:$container,
          lines: ($raw | split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end)}' \
        > "$DATA_DIR/logs/$sid.json" 2>/dev/null; then
      :
    else
      log "写入日志快照失败：$sid"
    fi

    jq -n --arg snapshot "$sid" --arg pod "$spod" --arg container "$sctr" --arg file "$sfile" \
      --argjson size "$ssize" --arg size_human "$(human_size "$ssize")" \
      --argjson mtime "$smt" --arg mtime_str "$smstr" --argjson file_count "$sfc" \
      --argjson error_count "$serr" --argjson exception_count "$sexc" \
      '{snapshot:$snapshot, pod:$pod, container:$container, file:$file,
        size:$size, size_human:$size_human, mtime:$mtime, mtime_str:$mtime_str,
        file_count:$file_count, error_count:$error_count, exception_count:$exception_count}' \
      >> "$src_jsonl" 2>/dev/null || log "写入副本元数据失败：$sid"
  done

  rec=$(jq -n \
    --arg id "$id" --arg cluster "$CLUSTER_NAME" --arg ns "$wns" --arg workload "$wl" \
    --arg file "$rfname" --argjson pods "$pods_json" --argjson containers "$ctrs_json" \
    --argjson hits "$hits" --argjson size "$rsize" --arg size_human "$(human_size "$rsize")" \
    --argjson mtime "$rmt" --arg mtime_str "$rmstr" --argjson file_count "$rfc" \
    --argjson error_count "$total_err" --argjson exception_count "$total_exc" \
    --arg rep_pod "$rpod" --arg rep_container "$rctr" \
    --arg scan_time "$SCAN_TIME" --arg link "$link" \
    --slurpfile sources "$src_jsonl" \
    '{id:$id, cluster:$cluster, namespace:$ns, workload:$workload, file:$file,
      pods:$pods, containers:$containers, hits:$hits, size:$size, size_human:$size_human,
      mtime:$mtime, mtime_str:$mtime_str, file_count:$file_count,
      error_count:$error_count, exception_count:$exception_count,
      rep_pod:$rep_pod, rep_container:$rep_container, sources:$sources,
      scan_time:$scan_time, link:$link}')

  if [ -s "$META_FILE" ]; then
    tmp="$META_FILE.tmp.$$"
    if jq --arg date "$TODAY" --arg now "$SCAN_TIME" --arg cluster "$CLUSTER_NAME" \
        --argjson rec "$rec" '
        (if .date == $date then . else {date:$date, alerts:[]} end)
        | .date = $date | .updated_at = $now | .cluster = $cluster
        | .alerts = ([$rec] + (.alerts // []))
      ' "$META_FILE" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$META_FILE"
    else
      rm -f "$tmp"
      log "更新页面数据失败：$id"
    fi
  fi

  attempts=$(( attempts + 1 ))
  if [ "$attempts" -gt "$MAX_MESSAGES" ]; then
    skipped_by_limit=$(( skipped_by_limit + 1 ))
    continue
  fi

  # 展示用 Pod 名字过长时截断
  pod_show="$pods"
  if [ "$(printf '%s' "$pod_show" | wc -c)" -gt 200 ]; then pod_show="$(printf '%s' "$pod_show" | cut -c1-200)…"; fi

  msg="**错误日志告警**
> 集群：${CLUSTER_NAME}
> 命名空间：${wns}
> 工作负载：${wl}
> 受影响：${hits} 个 Pod/容器；容器：${ctrs}
> 代表 Pod：${rpod}（容器 ${rctr}）
> Pod 列表：${pod_show}
> 代表日志：${rfname}（$(human_size "$rsize")，最后写入 ${rmstr}）
> 摘要：ERROR ${total_err} 行 / Exception ${total_exc} 处（${src_count} 份副本日志）
> 扫描时间：${SCAN_TIME}（检测窗口 ${CHECK_INTERVAL_HOURS} 小时）"
  if [ -n "$link" ]; then
    msg="${msg}
> [查看日志详情](${link})"
  fi

  if [ "$SEND_ALLOWED" != "true" ]; then
    log "非告警时间点，仅写入页面：${wns}/${wl} ${rfname}"
  elif send_wecom "$msg"; then
    sent=$(( sent + 1 ))
    log "已告警：${wns}/${wl}（${hits} 个 Pod/容器）${rfname}"
  else
    log "发送失败：${wns}/${wl} ${rfname}"
  fi
done

# 超出单次发送上限时补一条汇总
if [ "$skipped_by_limit" -gt 0 ] && [ "$DRY_RUN" != "true" ] && [ "$SEND_ALLOWED" = "true" ]; then
  summary="**错误日志告警（汇总）**
> 集群：${CLUSTER_NAME}
> 本次共发现 ${found_total} 个工作负载有新增错误日志，已发送 ${sent} 条，因单次上限 ${MAX_MESSAGES} 条未发送 ${skipped_by_limit} 条
> 扫描时间：${SCAN_TIME}"
  [ -n "$WEB_BASE_URL" ] && summary="${summary}
> [查看日志详情](${WEB_BASE_URL})"
  send_wecom "$summary" || true
fi

# 无告警时也刷新页面的最后扫描时间
if [ -s "$META_FILE" ]; then
  tmp="$META_FILE.tmp.$$"
  if jq --arg now "$SCAN_TIME" '.updated_at = $now' "$META_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$META_FILE"
  else
    rm -f "$tmp"
  fi
fi

log "完成：命中 ${found_total} 个工作负载，发送 ${sent} 条"
