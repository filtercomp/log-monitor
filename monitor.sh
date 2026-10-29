#!/bin/bash
# 错误日志监控：按 RECENT_WINDOW_MINUTES 窗口巡检，按工作负载（Deployment/StatefulSet 等）聚合后
# 推送企业微信摘要，同时把每个副本的最新日志快照写入页面数据目录。
#
# 告警降噪：
#   1. 首次发现错误立即告警；
#   2. 同一工作负载每 RENOTIFY_HOURS 小时最多发送一条告警（无论首次还是持续）；
#   3. 连续 RECOVERY_MINUTES 分钟无新增错误后发送一次恢复通知，并清除页面记录；
#   4. 恢复不清除上次告警时间，冷却期内再次报错只更新页面、不发消息。
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/config/monitor.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

: "${CLUSTER_NAME:=cn-prod}"
: "${ERROR_LOG_DIR:=/tmp/logs/error}"
: "${MAX_MESSAGES:=20}"
: "${INCLUDE_NAMESPACES:=}"
: "${EXCLUDE_NAMESPACES:=kube-system,kube-public,kube-node-lease}"
: "${EXCLUDE_CONTAINERS:=^(istio-proxy|linkerd-proxy|.*-init)$}"
: "${DRY_RUN:=false}"
: "${WECOM_WEBHOOK_URL:=}"
: "${WEB_BASE_URL:=}"
: "${DATA_DIR:=/www/data}"
: "${SNAPSHOT_LINES:=2000}"
: "${RECENT_WINDOW_MINUTES:=6}"
: "${RECOVERY_MINUTES:=20}"
: "${RENOTIFY_HOURS:=2}"
: "${ACTIVE_HOURS:=9-17}"

# ACTIVE_HOURS=9-17 表示 09:00-17:59（含两端的小时）；时段外只更新页面与状态，不推送
SEND_ALLOWED=false
_h=$((10#$(date +%H)))
_hs=${ACTIVE_HOURS%%-*}
_he=${ACTIVE_HOURS##*-}
if [ "$_h" -ge "$((10#$_hs))" ] && [ "$_h" -le "$((10#$_he))" ]; then SEND_ALLOWED=true; fi

NOW=$(date +%s)
SINCE=$(( NOW - RECENT_WINDOW_MINUTES * 60 ))
SCAN_TIME=$(date '+%F %T')
TODAY=$(date '+%F')

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

# 在容器内执行的探测脚本（由远端 sh 执行，参数：日志目录 起始时间戳 行数 当天日期）
# 输出两部分：1) 当天全部日志的错误归类（CAT 行，tab 分隔）；2) 窗口内最新文件的快照
read -r -d '' PROBE <<'EOS' || true
d="$1"; since="$2"; n="$3"; today="$4"
[ -d "$d" ] || exit 3
cd "$d" || exit 3
echo "@@DAILY-BEGIN"
# 只读当天写入的文件：文件名含当天日期，或无日期但今天被追加写入
day_start=$(date -d "$today 00:00:00" +%s 2>/dev/null) || day_start=0
flist=""
for f in *.log; do
  [ -f "$f" ] || continue
  case "$f" in
    *"$today"*) flist="$flist $f" ;;
    *)
      mt=$(stat -c %Y "$f" 2>/dev/null) || continue
      [ "$mt" -ge "$day_start" ] && flist="$flist $f" ;;
  esac
done
if [ -n "$flist" ]; then
  awk -v today="$today" '
    function inchain(x,  i) {
      for (i = 1; i <= chn; i++) if (ch[i] == x) return 1
      return 0
    }
    function flushblk(  chain, full, i, k) {
      if (!inblk) return
      if (chn > 0) {
        chain = ch[1]
        for (i = 2; i <= chn; i++) chain = chain " <- " ch[i]
        k = ch[chn]
      } else {
        k = ""
        if (match(msg, /[a-zA-Z_$][a-zA-Z0-9_$]*(\.[a-zA-Z_$][a-zA-Z0-9_$]*)*(Exception|Error|Throwable)/))
          k = substr(msg, RSTART, RLENGTH)
        chain = (k == "") ? "(no-stack)" : k
        if (k == "") k = "(no-stack)"
      }
      cnt[chain]++
      if (!(chain in first)) { first[chain] = tsstr; rootcls[chain] = k }
      last[chain] = tsstr
      if (!(chain in samp)) {
        full = msg
        if (rootmsg != "") full = msg " | " rootmsg
        samp[chain] = substr(full, 1, 400)
      }
      inblk = 0; chn = 0
    }
    {
      if ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
        flushblk()
        if (substr($0, 1, 10) != today) { inblk = 0; next }
        if ($0 ~ /ERROR/) {
          inblk = 1
          tsstr = substr($0, 1, 19)
          msg = $0
          gsub(/\t/, " ", msg)
          msg = substr(msg, 1, 240)
          root = ""; top = ""; rootmsg = ""; chn = 0
        }
        next
      }
      if (!inblk) next
      if ($0 ~ /^Caused by:/) {
        c = $0
        sub(/^Caused by:[ \t]*/, "", c)
        gsub(/\t/, " ", c)
        rootmsg = substr(c, 1, 200)
        sub(/:.*/, "", c)
        sub(/[ \t]+$/, "", c)
        if (c != "") {
          root = c
          if (!inchain(c)) ch[++chn] = c
        }
      } else if (top == "" && $0 ~ /^[a-zA-Z_$][a-zA-Z0-9_$.]*(Exception|Error|Throwable)([: ]|$)/) {
        t = $0
        sub(/:.*$/, "", t)
        sub(/[ \t].*$/, "", t)
        top = t
        if (!inchain(t)) ch[++chn] = t
      }
    }
    END {
      flushblk()
      for (k in cnt) printf "CAT\t%s\t%s\t%d\t%s\t%s\t%s\n", k, rootcls[k], cnt[k], first[k], last[k], samp[k]
    }
  ' $flist
fi
echo "@@DAILY-END"
cnt=0; newest=""; newest_mt=0; newest_sz=0
for f in *.log; do
  [ -f "$f" ] || continue
  mt=$(stat -c %Y "$f" 2>/dev/null) || continue
  [ "$mt" -ge "$since" ] || continue
  cnt=$(( cnt + 1 ))
  if [ "$mt" -gt "$newest_mt" ]; then
    newest="$f"; newest_mt=$mt; newest_sz=$(wc -c < "$f" | tr -d ' ')
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
STATE_FILE="$DATA_DIR/state.json"
mkdir -p "$DATA_DIR/logs" 2>/dev/null || true

# ---- 状态文件：记录每个工作负载的告警状态，Pod 重建后随内存卷一起丢失 ----
state_init() {
  if [ ! -s "$STATE_FILE" ]; then
    printf '{"updated_at":"","workloads":{}}\n' > "$STATE_FILE" 2>/dev/null || true
  fi
}

# 输出（tab 分隔）：alerted last_alert_ts last_mtime last_mtime_str id namespace workload file hits
state_get() {
  jq -r --arg k "$1" '
    (.workloads[$k] // empty)
    | [ (.alerted // false), (.last_alert_ts // 0), (.last_mtime // 0), (.last_mtime_str // ""),
        (.id // ""), (.namespace // ""), (.workload // ""), (.file // ""), (.hits // 0) ]
    | @tsv' "$STATE_FILE" 2>/dev/null
}

state_set() {  # wkey ns wl alerted last_alert_ts last_mtime last_mtime_str id file hits
  local wkey="$1" ns="$2" wl="$3" alerted="$4" lts="$5" lmt="$6" lmstr="$7" id="$8" file="$9" hits="${10}"
  local tmp="$STATE_FILE.tmp.$$"
  if jq --arg k "$wkey" --arg now "$SCAN_TIME" --argjson now_ts "$NOW" \
      --arg ns "$ns" --arg wl "$wl" --argjson alerted "$alerted" --argjson lts "$lts" \
      --argjson lmt "$lmt" --arg lmstr "$lmstr" --arg id "$id" --arg file "$file" --argjson hits "$hits" '
      .updated_at = $now
      | .workloads = (.workloads // {})
      | .workloads[$k] = {
          namespace:$ns, workload:$wl, alerted:$alerted,
          last_alert_ts:$lts, last_seen_ts:$now_ts, last_seen_str:$now,
          last_mtime:$lmt, last_mtime_str:$lmstr,
          id:$id, file:$file, hits:$hits }
    ' "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
    log "写入状态失败：$wkey"
  fi
}

state_remove() {  # wkey
  local tmp="$STATE_FILE.tmp.$$"
  if jq --arg k "$1" --arg now "$SCAN_TIME" '
      .updated_at = $now
      | .workloads = ((.workloads // {}) | del(.[$k]))
    ' "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}

# 删除页面记录及其日志快照
drop_record() {  # id
  local id="$1" tmp="$META_FILE.tmp.$$" s
  [ -z "$id" ] && return 0
  [ -s "$META_FILE" ] || return 0
  while IFS= read -r s; do
    [ -n "$s" ] && rm -f "$DATA_DIR/logs/$s.json" 2>/dev/null
  done < <(jq -r --arg i "$id" '(.alerts // [])[] | select(.id == $i) | (.sources // [])[]? | .snapshot // empty' "$META_FILE" 2>/dev/null)
  if jq --arg i "$id" --arg now "$SCAN_TIME" '
      .alerts = ((.alerts // []) | map(select(.id != $i)))
      | .updated_at = $now
    ' "$META_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$META_FILE"
  else
    rm -f "$tmp"
  fi
}

state_init

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

log "扫描命名空间：${NS_LIST[*]:-<无>}，窗口 ${RECENT_WINDOW_MINUTES} 分钟，快照 ${SNAPSHOT_LINES} 行，告警发送=$SEND_ALLOWED"

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

# 当天错误归类聚合：键 = 工作负载|异常链
declare -A DCNT=() DFIRST=() DLAST=() DSAMP=() DROOT=()
declare -A DWL_SEEN=()
declare -a DWL_ORDER=()
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

      raw=$(timeout 40 kubectl exec -n "$ns" "$pod" -c "$c" -- sh -c "$PROBE" sh "$ERROR_LOG_DIR" "$SINCE" "$SNAPSHOT_LINES" "$TODAY" 2>/dev/null)
      rc=$?

      # 解析返回块：先收当天归类（rc=4 时也有），再收窗口快照
      fname=""; fsize=""; fmtime=""; fmstr=""; fcount="0"; body=""; in_body=0; in_daily=0
      while IFS= read -r line; do
        case "$line" in
          @@COUNT=*) fcount="${line#@@COUNT=}" ;;
          @@FILE=*) fname="${line#@@FILE=}" ;;
          @@MTIME=*) fmtime="${line#@@MTIME=}" ;;
          @@MTIME_STR=*) fmstr="${line#@@MTIME_STR=}" ;;
          @@SIZE=*) fsize="${line#@@SIZE=}" ;;
          @@DAILY-BEGIN) in_daily=1 ;;
          @@DAILY-END) in_daily=2 ;;
          @@LOGS-BEGIN) in_body=1 ;;
          @@LOGS-END) in_body=2 ;;
          CAT$'\t'*)
            if [ "$in_daily" = "1" ]; then
              IFS=$'\t' read -r _tag catv croot cnum cfirst clast csamp <<< "$line"
              if [ -n "$catv" ]; then
                if [ -z "${DWL_SEEN[$wkey]:-}" ]; then DWL_SEEN["$wkey"]=1; DWL_ORDER+=("$wkey"); fi
                dkey="$wkey|$catv"
                if [ -z "${DCNT[$dkey]:-}" ]; then
                  DCNT["$dkey"]=$cnum; DFIRST["$dkey"]=$cfirst; DLAST["$dkey"]=$clast; DSAMP["$dkey"]=$csamp; DROOT["$dkey"]=$croot
                else
                  DCNT["$dkey"]=$(( DCNT[$dkey] + cnum ))
                  [[ "$cfirst" < "${DFIRST[$dkey]}" ]] && DFIRST["$dkey"]=$cfirst
                  [[ "$clast" > "${DLAST[$dkey]}" ]] && DLAST["$dkey"]=$clast
                fi
              fi
            fi ;;
          *)
            if [ "$in_body" = "1" ]; then body="${body}${line}"$'\n'; fi ;;
        esac
      done <<< "$raw"

      if [ $rc -eq 4 ]; then continue; fi          # 窗口内无变更（归类已统计）
      if [ $rc -ne 0 ]; then
        log "跳过 $ns/$pod/$c（exec rc=$rc，可能无该目录或无权限）"
        continue
      fi

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

# ---- 当天错误归类：生成 errors-daily.json / errors-daily.csv（每轮全量重算覆盖） ----
DAILY_JSON="$DATA_DIR/errors-daily.json"
DAILY_CSV="$DATA_DIR/errors-daily.csv"
groups_jsonl="$SCAN_TMP/daily-groups.jsonl"
: > "$groups_jsonl"
for wkey2 in "${DWL_ORDER[@]}"; do
  tmpcats="$SCAN_TMP/daily-cats.jsonl"
  : > "$tmpcats"
  prefix="$wkey2|"
  for dkey in "${!DCNT[@]}"; do
    [ "${dkey#"$prefix"}" != "$dkey" ] || continue
    catv="${dkey#"$prefix"}"
    jq -n --arg chain "$catv" --arg exception "${DROOT[$dkey]:-$catv}" --argjson count "${DCNT[$dkey]}" \
        --arg first "${DFIRST[$dkey]}" --arg last "${DLAST[$dkey]}" --arg message "${DSAMP[$dkey]}" \
        '{chain:$chain, exception:$exception, count:$count, first:$first, last:$last, message:$message}' >> "$tmpcats"
  done
  wns2="${wkey2%%|*}"; wl2="${wkey2#*|}"
  jq -n --arg namespace "$wns2" --arg workload "$wl2" --slurpfile cats "$tmpcats" \
      '{namespace:$namespace, workload:$workload, categories:($cats | sort_by(-.count))}' >> "$groups_jsonl"
done
if jq -n --arg date "$TODAY" --arg now "$SCAN_TIME" --arg cluster "$CLUSTER_NAME" --slurpfile groups "$groups_jsonl" \
    '{date:$date, updated_at:$now, cluster:$cluster,
      groups:($groups | sort_by(-([.categories[].count] | add // 0)))}' > "$DAILY_JSON.tmp" 2>/dev/null; then
  mv "$DAILY_JSON.tmp" "$DAILY_JSON"
  {
    printf '\xEF\xBB\xBF命名空间,工作负载,异常链,根因异常,次数,首次出现,末次出现,代表消息\n'
    jq -r '.groups[] | . as $g | .categories[] |
      [$g.namespace, $g.workload, .chain, .exception, (.count|tostring), .first, .last, .message] | @csv' \
      "$DAILY_JSON" 2>/dev/null
  } > "$DAILY_CSV.tmp" && mv "$DAILY_CSV.tmp" "$DAILY_CSV" || rm -f "$DAILY_CSV.tmp"
else
  rm -f "$DAILY_JSON.tmp"
  log "写入当天错误归类失败"
fi

# ---- 按工作负载逐条写入页面数据并按状态机发送告警 ----
found_total=${#AGG_ORDER[@]}
sent=0
skipped_by_limit=0

for wkey in "${AGG_ORDER[@]}"; do
  wns="${wkey%%|*}"; wl="${wkey#*|}"
  rpod="${AGG_REP_POD[$wkey]}"; rctr="${AGG_REP_CTR[$wkey]}"
  rfname="${AGG_FILE[$wkey]}"; rsize="${AGG_SIZE[$wkey]}"
  rmt="${AGG_MTIME[$wkey]}"; rmstr="${AGG_MTIME_STR[$wkey]:-}"
  rfc="${AGG_FCOUNT[$wkey]}"
  hits="${AGG_HITS[$wkey]}"; pods="${AGG_PODS[$wkey]}"; ctrs="${AGG_CTRS[$wkey]}"
  [ -z "$rmstr" ] && rmstr="$rmt"

  # 记录 id 按工作负载固定，页面链接在多次巡检之间保持稳定
  rid="w-$(printf '%s' "$wkey" | cksum | cut -d' ' -f1)"
  if [ -n "$WEB_BASE_URL" ]; then
    link="${WEB_BASE_URL}/#/alert/${rid}"
  else
    link=""
  fi

  pods_json=$(printf '%s' "$pods" | jq -R 'split(",") | map(select(length > 0))')
  ctrs_json=$(printf '%s' "$ctrs" | jq -R 'split(",") | map(select(length > 0))')

  # 为该工作负载下的每个 Pod/容器 各生成一份快照与副本元数据（文件名固定，每次覆盖）
  src_jsonl="$SCAN_TMP/sources-$rid.jsonl"
  : > "$src_jsonl"
  src_count=0
  total_err=0
  total_exc=0
  for ((si=0; si<${#SRC_ORDER[@]}; si++)); do
    [ "${SRC_WKEY[$si]:-}" = "$wkey" ] || continue
    src_count=$(( src_count + 1 ))
    spod="${SRC_POD[$si]}"; sctr="${SRC_CTR[$si]}"
    sfile="${SRC_FILE[$si]}"; smt="${SRC_MTIME[$si]}"
    smstr="${SRC_MTIME_STR[$si]:-}"; ssize="${SRC_SIZE[$si]}"
    sfc="${SRC_FCOUNT[$si]}"; sbody="${SRC_BODY_FILE[$si]}"
    [ -z "$smstr" ] && smstr="$smt"

    sid="s-$(printf '%s' "$wkey|$spod|$sctr" | cksum | cut -d' ' -f1)"

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
    --arg id "$rid" --arg cluster "$CLUSTER_NAME" --arg ns "$wns" --arg workload "$wl" \
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

  # 同一工作负载只保留最新一条页面记录
  if [ -s "$META_FILE" ]; then
    tmp="$META_FILE.tmp.$$"
    if jq --arg date "$TODAY" --arg now "$SCAN_TIME" --arg cluster "$CLUSTER_NAME" \
        --argjson rec "$rec" '
        (if .date == $date then . else {date:$date, alerts:[]} end)
        | .date = $date | .updated_at = $now | .cluster = $cluster
        | .alerts = ([$rec] + ((.alerts // []) | map(select(.id != $rec.id))))
      ' "$META_FILE" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$META_FILE"
    else
      rm -f "$tmp"
      log "更新页面数据失败：$rid"
    fi
  fi

  # ---- 状态机判定 ----
  prev="$(state_get "$wkey")"
  p_alerted=false; p_lts=0; p_lmt=0; p_lmstr=""
  if [ -n "$prev" ]; then
    IFS=$'\t' read -r p_alerted p_lts p_lmt p_lmstr _p_id _p_ns _p_wl _p_file _p_hits <<< "$prev"
    [ -z "$p_alerted" ] && p_alerted=false
    [ -z "$p_lts" ] && p_lts=0
    [ -z "$p_lmt" ] && p_lmt=0
  fi

  changed=1
  if [ "$p_lmt" -ge "$rmt" ] 2>/dev/null; then changed=0; fi

  # 同一工作负载在冷却期内（距上次告警不足 RENOTIFY_HOURS 小时）不再发消息
  cooldown_ok=0
  if [ $(( NOW - p_lts )) -ge $(( RENOTIFY_HOURS * 3600 )) ]; then cooldown_ok=1; fi

  kind=""
  if [ "$p_alerted" != "true" ]; then
    [ "$cooldown_ok" = "1" ] && kind="new"
  elif [ "$changed" = "1" ] && [ "$cooldown_ok" = "1" ]; then
    kind="repeat"
  fi

  lmt="$rmt"; lmstr="$rmstr"
  if [ "$p_lmt" -gt "$lmt" ] 2>/dev/null; then lmt="$p_lmt"; lmstr="${p_lmstr:-$p_lmt}"; fi

  if [ -n "$kind" ]; then
    if [ "$SEND_ALLOWED" != "true" ]; then
      log "非告警时段，仅写入页面：${wns}/${wl} ${rfname}"
    elif [ "$sent" -ge "$MAX_MESSAGES" ]; then
      skipped_by_limit=$(( skipped_by_limit + 1 ))
    else
      if [ "$kind" = "repeat" ]; then
        title="**🔥 <font color=\"warning\">错误日志持续告警</font>**"
      else
        title="**🔥 <font color=\"warning\">错误日志告警</font>**"
      fi
      msg="${title}
> 集群：${CLUSTER_NAME}
> 命名空间：${wns}
> 工作负载：${wl}
> 受影响：${hits} 个 Pod/容器；容器：${ctrs}
> 摘要：ERROR ${total_err} 行 / Exception ${total_exc} 处
> 扫描时间：${SCAN_TIME}"
      if [ -n "$link" ]; then
        msg="${msg}
> [查看日志详情](${link})"
      fi
      if send_wecom "$msg"; then
        sent=$(( sent + 1 ))
        p_alerted=true
        log "已告警（${kind}）：${wns}/${wl}（${hits} 个 Pod/容器）${rfname}"
      else
        log "发送失败：${wns}/${wl} ${rfname}"
      fi
      p_lts=$NOW
    fi
  fi

  state_set "$wkey" "$wns" "$wl" "$p_alerted" "$p_lts" "$lmt" "$lmstr" "$rid" "$rfname" "$hits"
done

# ---- 恢复检测：本次没有新增错误的工作负载 ----
mapfile -t STATE_KEYS < <(jq -r '(.workloads // {}) | keys[]' "$STATE_FILE" 2>/dev/null)
for k in "${STATE_KEYS[@]}"; do
  [ -z "$k" ] && continue
  [ -n "${AGG_SEEN[$k]:-}" ] && continue

  prev="$(state_get "$k")"
  [ -z "$prev" ] && continue
  IFS=$'\t' read -r p_alerted p_lts p_lmt p_lmstr p_id p_ns p_wl p_file p_hits <<< "$prev"
  [ -z "$p_alerted" ] && p_alerted=false
  [ -z "$p_lmt" ] && p_lmt=0
  [ -z "$p_lmstr" ] && p_lmstr="$p_lmt"

  # 从未告警过或已恢复：冷却期结束后清理状态，冷却期内保留上次告警时间
  if [ "$p_alerted" != "true" ]; then
    if [ $(( NOW - p_lts )) -ge $(( RENOTIFY_HOURS * 3600 )) ]; then
      drop_record "$p_id"
      state_remove "$k"
    fi
    continue
  fi

  if [ $(( NOW - p_lmt )) -lt $(( RECOVERY_MINUTES * 60 )) ]; then
    continue
  fi

  if [ "$SEND_ALLOWED" != "true" ]; then
    log "非告警时段，恢复通知顺延：${p_ns}/${p_wl}（最后错误 ${p_lmstr}）"
    continue
  fi

  msg="**💚 <font color=\"info\">错误日志恢复</font>**
> 集群：${CLUSTER_NAME}
> 命名空间：${p_ns}
> 工作负载：${p_wl}
> 最后错误写入：${p_lmstr}
> 状态：已连续 ${RECOVERY_MINUTES} 分钟无新增错误"
  if [ -n "$WEB_BASE_URL" ]; then
    msg="${msg}
> [查看日志监控页面](${WEB_BASE_URL})"
  fi

  if send_wecom "$msg"; then
    log "已发送恢复：${p_ns}/${p_wl}（最后错误 ${p_lmstr}）"
    drop_record "$p_id"
    # 保留 last_alert_ts，冷却期内再次报错不重复告警
    state_set "$k" "$p_ns" "$p_wl" false "$p_lts" "$p_lmt" "$p_lmstr" "$p_id" "$p_file" "$p_hits"
  else
    log "恢复通知发送失败，下个巡检周期重试：${p_ns}/${p_wl}"
  fi
done

# 超出单次发送上限时补一条汇总
if [ "$skipped_by_limit" -gt 0 ] && [ "$DRY_RUN" != "true" ] && [ "$SEND_ALLOWED" = "true" ]; then
  summary="**🔥 <font color=\"warning\">错误日志告警（汇总）</font>**
> 集群：${CLUSTER_NAME}
> 本次共发现 ${found_total} 个工作负载有新增错误日志，已发送 ${sent} 条，因单次上限 ${MAX_MESSAGES} 条未发送 ${skipped_by_limit} 条
> 扫描时间：${SCAN_TIME}"
  [ -n "$WEB_BASE_URL" ] && summary="${summary}
> [查看日志详情](${WEB_BASE_URL})"
  send_wecom "$summary" || true
fi

# 清理不再被页面记录引用的快照，避免长期运行后占用过多内存
if [ -s "$META_FILE" ]; then
  mapfile -t KEEP_SNAPS < <(jq -r '(.alerts // [])[] | (.sources // [])[]? | .snapshot // empty' "$META_FILE" 2>/dev/null)
  for f in "$DATA_DIR"/logs/*.json; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .json)"
    keep=0
    for s in "${KEEP_SNAPS[@]}"; do [ "$s" = "$base" ] && keep=1 && break; done
    [ "$keep" = "0" ] && rm -f "$f"
  done
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
