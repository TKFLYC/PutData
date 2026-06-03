#!/usr/bin/env bash
# nimomon.sh —— NimoShake 遷移監看器(團隊共識版,零外部相依)
# 只用 bash(/dev/tcp)+ coreutils + /proc + iproute2;不需 python/curl/wget/jq。
# 模式:
#   bash nimomon.sh            # 即時看板(ANSI loop,預設)
#   bash nimomon.sh --once     # 單次快照(cron/SSH 點查)
#   bash nimomon.sh --collector# 背景持續寫 TSV(長期/告警用,搭配 nohup)
# 搬到客戶端時，通常只需要依 nimo-shake.conf 對照下面幾項:
#   HOST       = 跑 NimoShake 的主機 IP；若本機執行就維持 127.0.0.1
#   LOGFILE    = nimo-shake.conf 的 log.file；若 log.file 空白，代表 NimoShake 印到 stdout，需改填實際 systemd/stdout log 路徑
#   FULL_PORT  = nimo-shake.conf 的 full_sync.http_port，預設 9341
#   INCR_PORT  = nimo-shake.conf 的 incr_sync.http_port，預設 9340
#   MONGO_PORT = target.address 裡 MongoDB 的 port；只用來估 Mongo 連線數，預設 27017
# 其他是監控腳本自己的設定:
#   INTERVAL=刷新秒數  TSV=歷史紀錄檔  LAG_WARN=延遲警戒秒數
set -u
HOST="${HOST:-127.0.0.1}"
FULL_PORT="${FULL_PORT:-9341}"
INCR_PORT="${INCR_PORT:-9340}"
INTERVAL="${INTERVAL:-5}"
LOGFILE="${LOGFILE:-/var/log/nimoshake/nimo-shake.log}"
TSV="${TSV:-$HOME/nimomon.tsv}"
LAG_WARN="${LAG_WARN:-60}"
MONGO_PORT="${MONGO_PORT:-27017}"

# ---- HTTP via bash /dev/tcp,timeout 包住避免卡死 ----
http_get() { # $1=port $2=path
  timeout 2 bash -c '
    exec 3<>/dev/tcp/'"$HOST"'/'"$1"' || exit 1
    printf "GET %s HTTP/1.0\r\nHost: x\r\nConnection: close\r\n\r\n" "'"$2"'" >&3
    awk "f{print} /^\r?\$/{f=1}" <&3
  ' 2>/dev/null
}
jnum()  { grep -oE "\"$2\": *[0-9]+" <<<"$1" | grep -oE '[0-9]+' | head -1; }   # 數字欄位
jstr1() { grep -oE "\"$2\": *\"[^\"]*\"" <<<"$1" | head -1 | sed 's/.*: *"//; s/"$//'; }
parse_epoch() { # $1=NimoShake timestamp; stdout=epoch seconds if parseable
  local ts="$1"
  ts=$(sed 's/.*: *"//; s/"$//; s/[[:space:]]*$//' <<<"$ts")
  [ -z "$ts" ] && return 1
  date -u -d "$ts" +%s 2>/dev/null && return 0
  date -u -d "${ts% UTC}" +%s 2>/dev/null && return 0
  date -u -d "$ts UTC" +%s 2>/dev/null && return 0
  return 1
}

# ---- 主機指標(Linux only;非 Linux 自動降級為 n/a) ----
host_metrics() { # 設 G_CPU G_MEM G_RXB G_TXB G_CONN
  G_CPU="n/a"; G_MEM="n/a"; G_RXB="n/a"; G_TXB="n/a"; G_CONN="n/a"
  case "$(uname -s 2>/dev/null)" in Linux*) ;; *) return 0 ;; esac
  [ -r /proc/stat ] || return 0
  local nic; nic=$(ip route show default 2>/dev/null | awk '{print $5; exit}'); nic="${nic:-eth0}"
  read -r _ a b c d e f g _ < <(grep '^cpu ' /proc/stat)
  local t1=$((a+b+c+d+e+f+g)) i1=$d
  local rx1 tx1; read -r rx1 tx1 < <(awk -v n="$nic:" '$1==n{print $2, $10}' /proc/net/dev 2>/dev/null)
  sleep 0.3
  read -r _ a b c d e f g _ < <(grep '^cpu ' /proc/stat)
  local t2=$((a+b+c+d+e+f+g)) i2=$d
  local rx2 tx2; read -r rx2 tx2 < <(awk -v n="$nic:" '$1==n{print $2, $10}' /proc/net/dev 2>/dev/null)
  local dt=$((t2-t1)); [ "$dt" -gt 0 ] && G_CPU=$(awk "BEGIN{printf \"%.0f%%\", 100*($dt-($i2-$i1))/$dt}")
  G_MEM=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t)printf "%.0f%%",100*(t-a)/t}' /proc/meminfo)
  if [ -n "${rx1:-}" ] && [ -n "${rx2:-}" ]; then
    G_RXB=$(awk "BEGIN{printf \"%.1f\", ($rx2-$rx1)/0.3/1048576}")  # MB/s
    G_TXB=$(awk "BEGIN{printf \"%.1f\", ($tx2-$tx1)/0.3/1048576}")
  fi
  G_CONN=$(ss -tn 2>/dev/null | grep -c ":$MONGO_PORT" )
}

# ---- 採樣一次:設一堆 G_* 全域 ----
sample() {
  local prog metric now; now=$(date -u +%s)
  prog=$(http_get "$FULL_PORT" /progress); metric=$(http_get "$INCR_PORT" /metric)
  G_FULL_UP=1; [ -z "$prog" ] && G_FULL_UP=0
  G_INCR_UP=1; [ -z "$metric" ] && G_INCR_UP=0

  # 進度:以表數為準
  G_TBL_DONE=$(jnum "$prog" finished_collection_number); G_TBL_DONE=${G_TBL_DONE:-0}
  G_TBL_TOT=$(jnum "$prog" total_collection_number);     G_TBL_TOT=${G_TBL_TOT:-0}
  local fin=0 tot=0 pair
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    fin=$((fin + $(sed 's/(\([0-9]*\)\/.*/\1/' <<<"$pair")))
    tot=$((tot + $(sed 's/.*\/\([0-9]*\))/\1/' <<<"$pair")))
  done <<< "$(grep -oE '\([0-9]+/[0-9]+\)' <<<"$prog")"
  G_REC_DONE=$fin; G_REC_TOT=$tot

  # 增量筆數
  G_RGET=$(jnum "$metric" records_get);     G_RGET=${G_RGET:-0}
  G_RWRITE=$(jnum "$metric" records_write); G_RWRITE=${G_RWRITE:-0}

  # TPS:讀上一筆 TSV 算差值(含 reset 防護)
  G_TPS="?"
  if [ -r "$TSV" ]; then
    local last; last=$(tail -1 "$TSV" 2>/dev/null)
    local pts pw; pts=$(cut -f1 <<<"$last"); pw=$(cut -f6 <<<"$last")
    if [[ "$pts" =~ ^[0-9]+$ && "$pw" =~ ^[0-9]+$ ]]; then
      local d=$((now-pts)); local dw=$((G_RWRITE-pw)); [ "$dw" -lt 0 ] && dw=$G_RWRITE
      [ "$d" -gt 0 ] && G_TPS=$(( dw / d ))
    fi
  fi
  G_TPS_LOG=$(tail -n 200 "$LOGFILE" 2>/dev/null | grep 'stage=incr' | tail -1 | grep -oE 'tps=[0-9]+' | grep -oE '[0-9]+')
  G_TPS_LOG=${G_TPS_LOG:-n/a}

  # 延遲:最落後 shard = 最舊 sync_approximate_time;staleness = 最舊 update_time
  local oldest_sync="" oldest_upd="" v e
  while IFS= read -r v; do
    e=$(parse_epoch "$v") || continue
    [ -z "$oldest_sync" ] || [ "$e" -lt "$oldest_sync" ] && oldest_sync=$e
  done <<< "$(grep -oE '"sync_approximate_time": *"[^"]*"' <<<"$metric")"
  while IFS= read -r v; do
    e=$(parse_epoch "$v") || continue
    [ -z "$oldest_upd" ] || [ "$e" -lt "$oldest_upd" ] && oldest_upd=$e
  done <<< "$(grep -oE '"update_time": *"[^"]*"' <<<"$metric")"
  G_LAG="n/a"; [ -n "$oldest_sync" ] && G_LAG=$(( now - oldest_sync ))
  G_STALE="n/a"; [ -n "$oldest_upd" ] && G_STALE=$(( now - oldest_upd ))

  # 狀態機(延遲/閒置/停滯)
  local has_ckpt=0; [ -n "$oldest_sync" ] && has_ckpt=1
  local tps_zero=0; { [ "$G_TPS" = "0" ] || [ "$G_TPS" = "?" ]; } && tps_zero=1
  if [ "$G_INCR_UP" = 0 ]; then G_STATE="增量端點無回應"
  elif [ "$has_ckpt" = 0 ] && [ "$G_RWRITE" -gt 0 ] && [ "$tps_zero" = 0 ]; then G_STATE="⚠ 寫入中但尚無 checkpoint"
  elif [ "$has_ckpt" = 0 ]; then G_STATE="n/a(無 shard checkpoint:全量中/未開始)"
  elif [ "$tps_zero" = 0 ] && [ "$G_LAG" -ge "$LAG_WARN" ]; then G_STATE="🔴 落後 ${G_LAG}s"
  elif [ "$tps_zero" = 0 ]; then G_STATE="同步中 ~${G_LAG}s"
  elif [ "$G_STALE" != "n/a" ] && [ "$G_STALE" -ge "$LAG_WARN" ]; then G_STATE="🔴 疑似停滯(checkpoint ${G_STALE}s 未更新)"
  else G_STATE="Idle(上次寫入 ${G_LAG}s 前)"; fi

  # 錯誤/健康
  G_ERR=$(jstr1 "$metric" error)
  G_LOGERR=$(tail -n 300 "$LOGFILE" 2>/dev/null | grep -icE 'error|fatal|panic')
  G_FULLDONE=no; tail -n 500 "$LOGFILE" 2>/dev/null | grep -q 'finish syncing all tables and indexes' && G_FULLDONE=yes
  local stage="全量"; [ "$G_RGET" -gt 0 ] && stage="增量"; G_STAGE=$stage

  host_metrics
  G_NOW=$now
}

append_tsv() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$G_NOW" "$G_STAGE" "$G_TBL_DONE" "$G_TBL_TOT" "$G_RGET" "$G_RWRITE" \
    "$G_TPS" "$G_LAG" "$G_STALE" "$G_ERR" "$G_CPU" "$G_MEM" "$G_RXB" "$G_TXB" "$G_CONN" >> "$TSV"
  # 控制檔案大小
  local n; n=$(wc -l <"$TSV" 2>/dev/null || echo 0)
  [ "$n" -gt 200000 ] && { tail -n 100000 "$TSV" > "$TSV.tmp" && mv "$TSV.tmp" "$TSV"; }
}

render() {
  local recpct="-"; [ "${G_REC_TOT:-0}" -gt 0 ] && recpct=$(awk "BEGIN{printf \"%.1f%%\",100*$G_REC_DONE/$G_REC_TOT}")
  local h="OK"; { [ "$G_FULL_UP" = 0 ] || [ "$G_INCR_UP" = 0 ]; } && h="DOWN(full:$G_FULL_UP incr:$G_INCR_UP)"
  printf '\033[H\033[2J'
  echo "NimoShake 遷移監看  $(date '+%F %T')  host=$HOST  full=:${FULL_PORT} incr=:${INCR_PORT}  interval=${INTERVAL}s"
  echo "（pipeline 自報數據;GCP-Mongo 落地數請於 cutover 另外核對）"
  echo "------------------------------------------------------------"
  echo "階段        : $G_STAGE   全量完成log: $G_FULLDONE"
  echo "全量進度    : 表 $G_TBL_DONE/$G_TBL_TOT   筆 $recpct ($G_REC_DONE/~$G_REC_TOT est.)"
  echo "增量筆數    : get=$G_RGET  write=$G_RWRITE"
  echo "速率 TPS    : $G_TPS  (log交叉:$G_TPS_LOG)"
  echo "延遲/狀態   : $G_STATE   [worst-shard lag=${G_LAG}s, ckpt-stale=${G_STALE}s]"
  echo "錯誤/健康   : 端點=$h  metric.error='${G_ERR}'  log錯誤數(近300行)=$G_LOGERR"
  echo "主機        : CPU=$G_CPU  MEM=$G_MEM  NET rx=${G_RXB}MB/s tx=${G_TXB}MB/s  Mongo連線=$G_CONN"
  echo "------------------------------------------------------------"
}

line_once() {
  local recpct="-"; [ "${G_REC_TOT:-0}" -gt 0 ] && recpct=$(awk "BEGIN{printf \"%.1f%%\",100*$G_REC_DONE/$G_REC_TOT}")
  printf '[%s] 階段=%s 表=%s/%s 筆=%s TPS=%s(log:%s) %s | CPU=%s MEM=%s Mongo連線=%s\n' \
    "$(date '+%T')" "$G_STAGE" "$G_TBL_DONE" "$G_TBL_TOT" "$recpct" "$G_TPS" "$G_TPS_LOG" "$G_STATE" "$G_CPU" "$G_MEM" "$G_CONN"
}

MODE="${1:-}"
case "$MODE" in
  --once)      sample; append_tsv; line_once ;;
  --collector) while true; do sample; append_tsv; sleep "$INTERVAL"; done ;;
  *)           while true; do sample; append_tsv; render; sleep "$INTERVAL"; done ;;
esac
