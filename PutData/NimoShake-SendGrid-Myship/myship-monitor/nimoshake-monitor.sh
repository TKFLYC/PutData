#!/bin/bash
# =============================================================================
# nimoshake-monitor.sh  v2.4  — NimoShake (DynamoDB -> MongoDB) 監控解析器
# -----------------------------------------------------------------------------
# 專案 : StarCo Migration (C2CPlatform)  環境: OPAPP / 賣貨便(MyShip)
# 依賴 : 純 bash + awk + grep + (可選) curl / pgrep / ps  — 無外部套件
#
# 涵蓋原始說明文件的九大區塊:
#   1 程式狀態  2 同步階段  3 Table 進度  4 效能指標  5 瓶頸分析
#   6 錯誤偵測  7 HTTP 端點  8 系統資源  9 操作建議  (+ 設定參數)
#
# 這支程式「只讀取、只分析」，不寄信、不改資料。HTTP 檢查僅打本機 localhost。
# 寄信與去重邏輯在 nimoshake-alert.sh。
#
# 用法 (目標可為 log 檔、conf 檔、或留空):
#   ./nimoshake-monitor.sh                        # 不帶參數: 自動找腳本旁唯一的 *.conf，用其 LOG_FILE
#                                                 #   在互動終端機直接執行時自動進入持續刷新 (同 --watch)，
#                                                 #   Ctrl-C 結束；輸出導向檔案/管線時仍為單次報表
#   ./nimoshake-monitor.sh <env.conf>             # 指定 conf: 讀其 LOG_FILE 與門檻參數
#   ./nimoshake-monitor.sh <logfile>              # 直接指定 log 檔 (臨時分析任何 log)
#   ./nimoshake-monitor.sh --human [目標]         # 強制單次報表 (不進入持續刷新)
#   ./nimoshake-monitor.sh --json [目標]          # JSON 輸出 (串接 dashboard)
#   ./nimoshake-monitor.sh --conditions [目標]    # 給告警引擎用的條件清單
#   ./nimoshake-monitor.sh --summary [目標]       # 逐面向判讀 (告警信的判讀表來源)
#   ./nimoshake-monitor.sh --watch [秒] [目標]    # 持續刷新 (預設 10 秒，Ctrl-C 結束)
#   ./nimoshake-monitor.sh --totals <全量log> [log2...] # 統計各 table 實際筆數，產生 TABLE_TOTALS
#                                                 # (全量若跨輪替檔，把 .log.2 .log.1 一起帶上)
#
# 全量進度百分比: conf 設 TABLE_TOTALS="Orders:5200000,Users:130000" (來源總筆數基準)
#   後，報表 [3] 顯示 進度% 與 預計剩餘時間。基準值可用 --totals 從上次完成的全量 log 產生。
#
# --conditions 每行格式 (供 nimoshake-alert.sh 解析):
#   TYPE|SEVERITY|ID|COUNT|TITLE|DETAIL
#     TYPE=STATE(持續狀態,有已解除通知) | EVENT(瞬時事件,只通知新增)
#     SEVERITY=high|medium|low|info    ID=穩定條件代碼
# --summary 每行格式: status|面向|說明 (status=ok/bad/info/na)
# 環境變數門檻: NS_STALL_SECONDS(300) NS_HANG_SECONDS(60)
#   NS_SLOW_WRITE_MS(200) NS_SLOW_SCAN_MS(500) NS_SCAN_TAIL_LINES(2000)
#   NS_EXPECT_RUNNING(0) NS_PROC_PATTERN NS_DISK_ALERT_PCT(85) NS_MEM_ALERT_PCT(90)
#   NS_HTTP_FULL_PORT(9341) NS_HTTP_INCR_PORT(9340) NS_HTTP_PPROF_PORT(9330)
# =============================================================================
set -uo pipefail

STALL_SECONDS="${NS_STALL_SECONDS:-300}"
HANG_SECONDS="${NS_HANG_SECONDS:-60}"    # 程序在但 log 停寫幾秒視為疑似假死
SLOW_WRITE_MS="${NS_SLOW_WRITE_MS:-200}"
SLOW_SCAN_MS="${NS_SLOW_SCAN_MS:-500}"
SCAN_TAIL_LINES="${NS_SCAN_TAIL_LINES:-2000}"
EXPECT_RUNNING="${NS_EXPECT_RUNNING:-0}"
PROC_PATTERN="${NS_PROC_PATTERN:-(^|/)nimo-shake(\.(linux|darwin))?( |$)}"   # 錨定 regex: 匹配 nimo-shake / nimo-shake.linux 執行檔，不誤中 nimo-shake.log 路徑或監控腳本自身
HTTP_FULL_PORT="${NS_HTTP_FULL_PORT:-9341}"
HTTP_INCR_PORT="${NS_HTTP_INCR_PORT:-9340}"
HTTP_PPROF_PORT="${NS_HTTP_PPROF_PORT:-9330}"
TABLE_TOTALS="${NS_TABLE_TOTALS:-${TABLE_TOTALS:-}}"   # 選填: "Orders:5200000,Users:130000" → [3] 顯示進度%/預計剩餘

MODE="human"; MODE_EXPLICIT=0; WATCH_INTERVAL=10; LOGFILE=""; CONF_PATH=""; TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)       MODE="json";       MODE_EXPLICIT=1 ;;
    --conditions) MODE="conditions"; MODE_EXPLICIT=1 ;;
    --summary)    MODE="summary";    MODE_EXPLICIT=1 ;;
    --totals)     MODE="totals";     MODE_EXPLICIT=1 ;;
    --human)      MODE="human";      MODE_EXPLICIT=1 ;;
    --watch)
      MODE="watch"; MODE_EXPLICIT=1
      if [ "${2:-}" ] && printf '%s' "${2:-}" | grep -qE '^[0-9]+$'; then WATCH_INTERVAL="$2"; shift; fi ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知參數: $1" >&2; exit 2 ;;
    *)  LOGFILE="$1"; TARGETS+=("$1") ;;
  esac
  shift
done
# 互動終端機直接執行且未指定模式 → 自動進入持續刷新 (啟動後一直更新，不用重複下指令)
# 輸出導向檔案/管線 (如排程的 report.txt) 時 stdout 不是 TTY，維持單次報表不受影響
if [ "$MODE_EXPLICIT" -eq 0 ] && [ -t 1 ]; then MODE="watch"; fi

# ---- --totals: 統計各 table 實際筆數 (可接多個 log，全量跨輪替檔時一起給) ----
if [ "$MODE" = "totals" ]; then
  [ ${#TARGETS[@]} -eq 0 ] && { echo "用法: $0 --totals <全量log> [更多log...]  (全量若跨輪替檔，把 .log.2 .log.1 一起帶上)" >&2; exit 2; }
  for _t in "${TARGETS[@]}"; do [ -f "$_t" ] || { echo "找不到檔案: $_t" >&2; exit 2; }; done
  _pairs=$(grep -hoE 'table\[[A-Za-z0-9_.-]+\].*scanCount\[[0-9]+\]' "${TARGETS[@]}" 2>/dev/null | \
    awk -F'[][]' '{ sum[$2]+=$(NF-1) } END{ for(t in sum) printf "%s:%d\n", t, sum[t] }' | sort)
  if [ -z "$_pairs" ]; then
    echo "這些 log 中沒有 scanCount 記錄 — 需要「跑過全量」的 log (含輪替舊檔 .log.1/.log.2)" >&2; exit 1
  fi
  echo "各 table 全量實際掃描筆數 (來源: ${TARGETS[*]}):"
  printf '%s\n' "$_pairs" | awk -F: '{ printf "  %-24s %s 筆\n", $1, $2 }'
  echo
  echo "將下行貼進 conf，報表 [3] 即顯示 進度% 與 預計剩餘時間:"
  echo "TABLE_TOTALS=\"$(printf '%s' "$_pairs" | tr '\n' ',' | sed 's/,$//')\""
  exit 0
fi
# ---- 目標解析: 留空→自動找 conf；.conf→讀 LOG_FILE 與門檻；其他→視為 log 檔 ----
if [ -z "$LOGFILE" ]; then
  _sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _confs=$(ls "$_sd"/*.conf "$_sd"/*/*.conf 2>/dev/null)
  _n=$(printf '%s\n' "$_confs" | grep -c '\.conf$')
  if [ "$_n" -eq 1 ]; then
    LOGFILE="$_confs"
  elif [ "$_n" -eq 0 ]; then
    echo "用法: $0 [--json|--summary|--conditions|--watch [秒]] [log檔|conf檔]" >&2
    echo "(未帶參數時會自動使用腳本旁唯一的 *.conf，目前找不到任何 conf)" >&2; exit 2
  else
    echo "找到多個 conf，請指定其中一個:" >&2; printf '%s\n' "$_confs" >&2; exit 2
  fi
fi
if printf '%s' "$LOGFILE" | grep -q '\.conf$'; then
  CONF_PATH="$LOGFILE"
  [ -f "$CONF_PATH" ] || { echo "找不到 conf 檔: $CONF_PATH" >&2; exit 2; }
  # shellcheck disable=SC1090  # 載入 conf: LOG_FILE 與門檻參數與本腳本變數同名，直接生效
  . "$CONF_PATH"
  LOGFILE="${LOG_FILE:-}"
  [ -z "$LOGFILE" ] && { echo "conf 缺少 LOG_FILE: $CONF_PATH" >&2; exit 2; }
  # NS_* 環境變數優先權最高 (告警引擎呼叫時傳入)，覆蓋回來
  [ -n "${NS_STALL_SECONDS:-}" ]   && STALL_SECONDS="$NS_STALL_SECONDS"
  [ -n "${NS_HANG_SECONDS:-}" ]    && HANG_SECONDS="$NS_HANG_SECONDS"
  [ -n "${NS_SLOW_WRITE_MS:-}" ]   && SLOW_WRITE_MS="$NS_SLOW_WRITE_MS"
  [ -n "${NS_SLOW_SCAN_MS:-}" ]    && SLOW_SCAN_MS="$NS_SLOW_SCAN_MS"
  [ -n "${NS_SCAN_TAIL_LINES:-}" ] && SCAN_TAIL_LINES="$NS_SCAN_TAIL_LINES"
  [ -n "${NS_EXPECT_RUNNING:-}" ]  && EXPECT_RUNNING="$NS_EXPECT_RUNNING"
  [ -n "${NS_PROC_PATTERN:-}" ]    && PROC_PATTERN="$NS_PROC_PATTERN"
  [ -n "${NS_TABLE_TOTALS:-}" ]    && TABLE_TOTALS="$NS_TABLE_TOTALS"
fi
if [ ! -f "$LOGFILE" ]; then echo "找不到 log 檔: $LOGFILE" >&2; exit 2; fi

# ------------------------------------------------------------------ 工具
now_epoch() { date +%s; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
human_secs() {
  local s="$1"
  if   [ "$s" -lt 60 ];   then echo "${s}秒"
  elif [ "$s" -lt 3600 ]; then echo "$((s/60))分$((s%60))秒"
  else echo "$((s/3600))時$(((s%3600)/60))分"; fi
}

# ------------------------------------------------------------------ 基本
LOG_BYTES=$(wc -c < "$LOGFILE" 2>/dev/null | tr -d ' ')
LOG_LINES=$(wc -l < "$LOGFILE" 2>/dev/null | tr -d ' ')
LOG_MTIME=$(file_mtime "$LOGFILE")
NOW=$(now_epoch)
LOG_AGE=$(( NOW - LOG_MTIME )); [ "$LOG_AGE" -lt 0 ] && LOG_AGE=0

# ---- [1] process 狀態 + 資源 ----
PROC_PID=""
command -v pgrep >/dev/null 2>&1 && PROC_PID=$(pgrep -f "$PROC_PATTERN" 2>/dev/null | head -n1)
PROC_RUNNING=0; [ -n "$PROC_PID" ] && PROC_RUNNING=1
PROC_CPU="-"; PROC_MEM_MB="-"; PROC_THREADS="-"; PROC_UPTIME="-"
if [ "$PROC_RUNNING" -eq 1 ] && command -v ps >/dev/null 2>&1; then
  PROC_CPU=$(ps -p "$PROC_PID" -o %cpu= 2>/dev/null | tr -d ' '); : "${PROC_CPU:=-}"
  _rss=$(ps -p "$PROC_PID" -o rss= 2>/dev/null | tr -d ' '); [ -n "$_rss" ] && PROC_MEM_MB=$((_rss/1024))
  PROC_THREADS=$(ps -p "$PROC_PID" -o nlwp= 2>/dev/null | tr -d ' '); : "${PROC_THREADS:=-}"
  PROC_UPTIME=$(ps -p "$PROC_PID" -o etime= 2>/dev/null | tr -d ' '); : "${PROC_UPTIME:=-}"
fi

# ---- 時間範圍 ----
LOG_START=$(grep -m1 -oE '^\[[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]+ UTC\]' "$LOGFILE" 2>/dev/null | tr -d '[]')
LOG_END=$(grep -oE '^\[[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]+ UTC\]' "$LOGFILE" 2>/dev/null | tail -n1 | tr -d '[]')

# ---- [2] 同步模式 / 階段 ----
SYNC_MODE=$(grep -m1 -oE '"SyncMode":"[a-z]+"' "$LOGFILE" 2>/dev/null | head -n1 | cut -d'"' -f4); : "${SYNC_MODE:=unknown}"
HAS_PREPARE=$(grep -c 'prepare checkpoint' "$LOGFILE" 2>/dev/null); HAS_PREPARE=${HAS_PREPARE:-0}
HAS_START_SYNC=$(grep -cE 'start (syncing|full sync)' "$LOGFILE" 2>/dev/null); HAS_START_SYNC=${HAS_START_SYNC:-0}
HAS_FULL_DONE=$(grep -ciE 'full sync (done|finish|complete)' "$LOGFILE" 2>/dev/null); HAS_FULL_DONE=${HAS_FULL_DONE:-0}
HAS_INCR=$(grep -ciE 'start incr' "$LOGFILE" 2>/dev/null); HAS_INCR=${HAS_INCR:-0}
STAGE="unknown"; STAGE_SYM="?"
if   [ "$HAS_INCR" -gt 0 ];       then STAGE="增量同步中"; STAGE_SYM="◌"
elif [ "$HAS_FULL_DONE" -gt 0 ];  then STAGE="全量完成";   STAGE_SYM="✓"
elif [ "$HAS_START_SYNC" -gt 0 ]; then STAGE="全量同步中"; STAGE_SYM="◌"
elif [ "$HAS_PREPARE" -gt 0 ];    then STAGE="準備中";     STAGE_SYM="◌"
fi
[ "$PROC_RUNNING" -eq 0 ] && [ "$LOG_AGE" -ge "$STALL_SECONDS" ] && { STAGE="已停止"; STAGE_SYM="✗"; }
LOG_ACTIVITY="active"
if   [ "$LOG_AGE" -ge "$STALL_SECONDS" ]; then LOG_ACTIVITY="stopped"
elif [ "$LOG_AGE" -ge 30 ];               then LOG_ACTIVITY="idle"; fi
HANG=0; [ "$PROC_RUNNING" -eq 1 ] && [ "$LOG_AGE" -ge "$HANG_SECONDS" ] && HANG=1

# ---- table 清單 + 每批大小 ----
TABLES=$(grep -oE 'table\[[A-Za-z0-9_.-]+\]' "$LOGFILE" 2>/dev/null | sed -E 's/table\[(.*)\]/\1/' | sort -u)
# 每批大小: 以 log configuration 的 FullDocumentWriteBatch 為準 (首筆 batch 可能是 0 空批)
BATCH_SIZE=$(grep -m1 -oE '"FullDocumentWriteBatch":[0-9]+' "$LOGFILE" 2>/dev/null | grep -oE '[0-9]+$')
if [ -z "$BATCH_SIZE" ] || [ "$BATCH_SIZE" = "0" ]; then
  BATCH_SIZE=$(grep -m1 -oE 'write db batch\[[1-9][0-9]*\]' "$LOGFILE" 2>/dev/null | grep -oE '[0-9]+')
fi
: "${BATCH_SIZE:=25}"

# ---- [6] 異常事件計數 (全檔) ----
cnt() { local n; n=$(grep -icE "$1" "$LOGFILE" 2>/dev/null); echo "${n:-0}"; }
C_ERROR=$(cnt '\[(ERROR|CRIT|FATAL)\]')
C_PANIC=$(cnt 'panic:')   # 帶冒號: Go 崩潰必印 "panic: ..."；不帶會誤中增量事件 base64 資料裡隨機出現的字樣
C_TIMEOUT=$(cnt 'timed out|i/o timeout|deadline exceeded|connection timeout')
C_THROTTLE=$(cnt 'throttl|ProvisionedThroughputExceeded')
C_CONN=$(cnt 'connection refused|broken pipe|no route to host')   # i/o timeout 歸 TIMEOUT，不重複計數
C_SHARD=$(cnt 'ExpiredIterator|TrimmedData')

# ---- [4] 效能取樣 (尾端 N 行) ----
SAMPLE=$(tail -n "$SCAN_TAIL_LINES" "$LOGFILE" 2>/dev/null)
# 抽出某欄位的毫秒數值 (一行一個)
extract_ms() {
  printf '%s' "$SAMPLE" | awk -v f="$1" '
    function ms(v){ if(v~/µs$|us$/){gsub(/µs$|us$/,"",v);return v/1000}
                    if(v~/ms$/){gsub(/ms$/,"",v);return v+0}
                    if(v~/s$/){gsub(/s$/,"",v);return v*1000} return v+0 }
    { if(match($0, f "\\[[^]]+\\]")){ x=substr($0,RSTART+length(f)+1,RLENGTH-length(f)-2); print ms(x) } }'
}
# 統計: 輸入為每行一個數值 -> "n avg min max p95"
stats() {
  sort -n | awk '{a[NR]=$1; s+=$1} END{
    n=NR; if(n==0){print "0 0 0 0 0"; exit}
    idx=int(0.95*n+0.999); if(idx<1)idx=1; if(idx>n)idx=n;
    printf "%d %.2f %.2f %.2f %.2f\n", n, s/n, a[1], a[n], a[idx] }'
}
read -r WC WAVG WMIN WMAX WP95 <<<"$(extract_ms writeDestDbTime | stats)"
read -r SC SAVG SMIN SMAX SP95 <<<"$(extract_ms scanTime | stats)"
read -r PC PAVG PMIN PMAX PP95 <<<"$(extract_ms parserTime | stats)"
SLOW_W=$(extract_ms writeDestDbTime | awk -v t="$SLOW_WRITE_MS" '$1>t{n++} END{print n+0}')
SLOW_S=$(extract_ms scanTime | awk -v t="$SLOW_SCAN_MS" '$1>t{n++} END{print n+0}')

# ---- [2b] 增量同步活動 (尾端取樣) -------------------------------------------
# 增量期 log 是 dispatcher 事件行 (update/insert table[...] ... ok)，沒有全量的
# batch/scanTime 欄位；改由取樣行計算 事件數 / 速率 / 同步延遲 (來源變更時間 vs 處理時間)
INCR_EVENTS=$(printf '%s' "$SAMPLE" | grep -cE 'dispatcher\[[0-9]+\]' 2>/dev/null); INCR_EVENTS=${INCR_EVENTS:-0}
INCR_SPAN=0; INCR_RATE="-"; INCR_LAG="-"; INCR_LAG_SEC=""; INCR_TABLES_DESC=""
if [ "$INCR_EVENTS" -gt 0 ]; then
  # 取樣時間跨度 (行首時戳 HH:MM:SS，跨日 +86400 校正)
  _ift=$(printf '%s' "$SAMPLE" | grep -m1 -oE '^\[[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}$')
  _ilt=$(printf '%s' "$SAMPLE" | grep -oE '^\[[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -n1 | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}$')
  if [ -n "$_ift" ] && [ -n "$_ilt" ]; then
    _ifs=$(( 10#${_ift:0:2}*3600 + 10#${_ift:3:2}*60 + 10#${_ift:6:2} ))
    _ils=$(( 10#${_ilt:0:2}*3600 + 10#${_ilt:3:2}*60 + 10#${_ilt:6:2} ))
    INCR_SPAN=$(( _ils - _ifs )); [ "$INCR_SPAN" -lt 0 ] && INCR_SPAN=$(( INCR_SPAN + 86400 ))
  fi
  [ "$INCR_SPAN" -gt 0 ] && INCR_RATE=$(awk -v n="$INCR_EVENTS" -v s="$INCR_SPAN" 'BEGIN{printf "%.1f", n/s}')
  # 同步延遲: 取最後一筆帶 UpdateDate 的事件行，事件的來源變更時間 vs 行首處理時戳
  _lagline=$(printf '%s' "$SAMPLE" | grep 'UpdateDate:' | tail -n1)
  if [ -n "$_lagline" ]; then
    _src=$(printf '%s' "$_lagline" | grep -oE 'UpdateDate:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -n1 | sed 's/^UpdateDate://')
    _prc=$(printf '%s' "$_lagline" | grep -oE '^\[[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | tr -d '[')
    if [ -n "$_src" ] && [ -n "$_prc" ]; then
      _srce=$(date -u -d "${_src}Z" +%s 2>/dev/null)
      _prce=$(date -u -d "$(printf '%s' "$_prc" | tr '/' '-')" +%s 2>/dev/null)
      if [ -n "$_srce" ] && [ -n "$_prce" ]; then
        INCR_LAG_SEC=$(( _prce - _srce )); [ "$INCR_LAG_SEC" -lt 0 ] && INCR_LAG_SEC=0
        INCR_LAG="$(human_secs "$INCR_LAG_SEC")"
      fi
    fi
  fi
  # 活躍 table (取樣中事件數前 3 名)
  INCR_TABLES_DESC=$(printf '%s' "$SAMPLE" | grep -oE '(insert|update|delete|remove|modify) table\[[A-Za-z0-9_.-]+\]' \
    | sed -E 's/.*table\[([^]]+)\]/\1/' | sort | uniq -c | sort -rn | head -n3 \
    | awk '{printf "%s%s(%s)", (NR>1?"、":""), $2, $1}')
fi
# 階段推斷: 里程碑訊息 (start incr 等) 已隨 log 輪替消失、但取樣中有增量事件 → 增量同步中
if [ "$STAGE" = "unknown" ] && [ "$INCR_EVENTS" -gt 0 ]; then
  STAGE="增量同步中"; STAGE_SYM="◌"
fi

# ---- [5] 瓶頸 ----
BN=$(awk -v s="$SAVG" -v p="$PAVG" -v w="$WAVG" 'BEGIN{
  if(s>=p&&s>=w&&s>0)print"fetcher"; else if(w>=s&&w>=p&&w>0)print"writer";
  else if(p>0)print"parser"; else print"none"}')
case "$BN" in
  fetcher) BOTTLENECK="讀取端 Fetcher (DynamoDB Scan) — 建議調 full.read.concurrency / qps.full" ;;
  writer)  BOTTLENECK="寫入端 Writer (MongoDB) — 建議調 full.document.concurrency / 檢查目標負載" ;;
  parser)  BOTTLENECK="轉換端 Parser (CPU) — 建議調 full.document.parser" ;;
  *)       BOTTLENECK="樣本不足" ;;
esac

# =============================================================================
# 條件產生 (供告警引擎)
# =============================================================================
CONDITIONS=""
emit_cond() {
  local t="$1" sev="$2" id="$3" c="$4" title="$5" detail="$6"
  title=${title//|/／}; detail=${detail//|/／}; title=${title//$'\n'/ }; detail=${detail//$'\n'/ }
  CONDITIONS+="${t}|${sev}|${id}|${c}|${title}|${detail}"$'\n'
}
if [ "$PROC_RUNNING" -eq 0 ]; then
  if [ "$EXPECT_RUNNING" = "1" ]; then
    emit_cond STATE high PROCESS_DOWN 1 "NimoShake 程序未運行" "pgrep 找不到 [$PROC_PATTERN]；設定要求應持續運行。"
  elif [ "$HAS_FULL_DONE" -eq 0 ] && [ "$HAS_START_SYNC" -gt 0 ]; then
    emit_cond STATE high FULL_SYNC_INCOMPLETE 1 "全量同步未完成即中止" "log 有 start syncing 但無 full sync done，且程序已不在。全量不支援斷點續傳，重啟會從頭。"
  fi
fi
if [ "$HANG" -eq 1 ]; then
  emit_cond STATE high LOG_HANG 1 "疑似假死 (卡住)" "程序存在(PID $PROC_PID)但 log 已 $(human_secs "$LOG_AGE") 無寫入。"
elif [ "$PROC_RUNNING" -eq 1 ] && [ "$LOG_ACTIVITY" = "stopped" ]; then
  emit_cond STATE high LOG_STALLED 1 "log 停滯" "log 已 $(human_secs "$LOG_AGE") 無寫入 (門檻 ${STALL_SECONDS}s)。"
fi
[ "$C_ERROR" -gt 0 ]    && emit_cond EVENT high   ERROR_DETECTED "$C_ERROR"  "偵測到 ERROR/CRIT/FATAL"      "全檔累計 $C_ERROR 筆。"
[ "$C_PANIC" -gt 0 ]    && emit_cond EVENT high   PANIC          "$C_PANIC"  "偵測到 panic (Go crash)"      "全檔累計 $C_PANIC 筆。"
[ "$C_SHARD" -gt 0 ]    && emit_cond EVENT high   SHARD_EXPIRED  "$C_SHARD"  "Shard Iterator 過期"          "增量資料可能遺失，建議重跑 full sync。累計 $C_SHARD 筆。"
[ "$C_THROTTLE" -gt 0 ] && emit_cond EVENT medium THROTTLE       "$C_THROTTLE" "DynamoDB 限流"              "建議降 qps.full 或加來源 RCU。累計 $C_THROTTLE 筆。"
[ "$C_CONN" -gt 0 ]     && emit_cond EVENT medium CONN_ERROR     "$C_CONN"   "連線錯誤"                     "connection refused / broken pipe 等。累計 $C_CONN 筆。"
[ "$C_TIMEOUT" -gt 0 ]  && emit_cond EVENT medium TIMEOUT        "$C_TIMEOUT" "連線逾時"                    "來源或目標逾時。累計 $C_TIMEOUT 筆。"
[ "$SLOW_W" -gt 0 ]     && emit_cond EVENT low    SLOW_WRITE     "$SLOW_W"   "慢寫入 (>${SLOW_WRITE_MS}ms)" "近 ${SCAN_TAIL_LINES} 行中 $SLOW_W 筆。"
[ "$SLOW_S" -gt 0 ]     && emit_cond EVENT low    SLOW_SCAN      "$SLOW_S"   "慢讀取 (>${SLOW_SCAN_MS}ms)"  "近 ${SCAN_TAIL_LINES} 行中 $SLOW_S 筆。"
[ -z "$CONDITIONS" ] && emit_cond STATE info ALL_CLEAR 1 "目前運行正常" "階段: $STAGE；無異常條件。"

# =============================================================================
# 各 table 進度 (重量級，只在 human/json 計算)
# 回傳多行: table<TAB>status<TAB>批次<TAB>預估筆數<TAB>耗時秒<TAB>速率<TAB>進度%<TAB>預計剩餘
# 進度%/預計剩餘 需要 conf 設 TABLE_TOTALS="Orders:5200000,..." (基準可由 --totals 產生)，未設顯示 "-"
# =============================================================================
total_for() { # table 名 -> 印出 TABLE_TOTALS 中的總筆數，查無回傳 1
  [ -z "$TABLE_TOTALS" ] && return 1
  printf '%s' "$TABLE_TOTALS" | tr ',' '\n' | awk -F: -v t="$1" '$1==t && $2+0>0 { print $2; f=1 } END{ exit(f?0:1) }'
}
compute_table_stats() {
  [ -z "$TABLES" ] && return
  while IFS= read -r tb; do
    [ -z "$tb" ] && continue
    local batches est first last dur rate status act
    act=" $tb}] write db batch"  # 前導空白必要: 避免 Orders 誤中 PendingOrders 等後綴重疊的 table
    batches=$(grep -cF "$act" "$LOGFILE" 2>/dev/null); batches=${batches:-0}
    est=$(( batches * BATCH_SIZE ))
    if grep -qE "finish sync table\[$tb\]|sync table\[$tb\] .*(done|finish)" "$LOGFILE" 2>/dev/null; then
      status="完成"
    else
      status="中斷/進行中"
    fi
    # 該 table 首末時間: 取活動行的「行首時戳」HH:MM:SS (避開 stream metadata 的時戳)
    first=$(grep -F "$act" "$LOGFILE" 2>/dev/null | head -n1 | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -n1)
    last=$(grep -F "$act" "$LOGFILE" 2>/dev/null | tail -n1 | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -n1)
    dur=0
    if [ -n "$first" ] && [ -n "$last" ]; then
      local fs ls
      fs=$(( 10#${first:0:2}*3600 + 10#${first:3:2}*60 + 10#${first:6:2} ))
      ls=$(( 10#${last:0:2}*3600 + 10#${last:3:2}*60 + 10#${last:6:2} ))
      dur=$(( ls - fs )); [ "$dur" -lt 0 ] && dur=$(( dur + 86400 ))
    fi
    if [ "$dur" -gt 0 ]; then rate=$(( est / dur )); else rate=0; fi
    # 進度% / 預計剩餘 (需要 TABLE_TOTALS 基準)
    local total pct="-" eta="-"
    if total=$(total_for "$tb"); then
      if [ "$status" = "完成" ]; then
        pct="100%"
      else
        pct=$(awk -v e="$est" -v t="$total" 'BEGIN{ p=e*100/t; if(p>100)p=100; printf "%.1f%%", p }')
        if [ "$est" -ge "$total" ]; then eta="即將完成"
        elif [ "$rate" -gt 0 ]; then eta="$(human_secs $(( (total - est) / rate )))"
        fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tb" "$status" "$batches" "$est" "$dur" "$rate" "$pct" "$eta"
  done <<< "$TABLES"
}

# =============================================================================
# [7] HTTP 端點檢查 (只打本機)
# =============================================================================
http_check() { # port -> "up"/"down"/"n/a"
  local port="$1"
  [ -z "$port" ] && { echo "n/a"; return; }
  command -v curl >/dev/null 2>&1 || { echo "n/a"; return; }
  if curl -s -o /dev/null --max-time 2 "http://localhost:${port}/" 2>/dev/null; then echo "up"; else echo "down"; fi
}
http_fetch() { # port -> 印出 "路徑 內容摘要" (NimoShake 內建監控 API 的進度與統計；截 220 字)；無內容回傳 1
  local port="$1" p body
  [ -z "$port" ] && return 1
  command -v curl >/dev/null 2>&1 || return 1
  for p in /progress /metric /worker /repl /; do
    # -f: HTTP 4xx/5xx (如 404 page not found) 視為失敗，才會輪到下一個候選路徑
    body=$(curl -sf --max-time 2 "http://localhost:${port}${p}" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g')
    if [ -n "${body// /}" ]; then
      printf '%s %s' "$p" "$(printf '%s' "$body" | cut -c1-220)"
      return 0
    fi
  done
  return 1
}

# =============================================================================
# [8] 系統資源
# =============================================================================
SYS_CORES=$( { command -v nproc >/dev/null 2>&1 && nproc; } 2>/dev/null || echo "-")
SYS_LOAD=$( [ -r /proc/loadavg ] && cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "-")
SYS_MEM="-"
if [ -r /proc/meminfo ]; then
  # 舊 kernel 無 MemAvailable 時以 MemFree+Buffers+Cached 估算，避免誤算成 100%
  SYS_MEM=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/MemFree/{f=$2}/^Buffers/{b=$2}/^Cached/{c=$2} END{ if(a=="")a=f+b+c; if(t>0) printf "總 %dMB / 可用 %dMB / 使用率 %.0f%%", t/1024, a/1024, (t-a)*100/t }' /proc/meminfo 2>/dev/null)
fi
SYS_DISK=$(df -h "$(dirname "$LOGFILE")" 2>/dev/null | awk 'NR==2{printf "%s 已用 (%s/%s)", $5,$3,$2}'); : "${SYS_DISK:=-}"

# =============================================================================
# [4/config] 設定參數擷取 (從 configuration 行)
# =============================================================================
CFG_LINE=$(grep -m1 'configuration:' "$LOGFILE" 2>/dev/null)
cfg_get() { printf '%s' "$CFG_LINE" | grep -oE "\"$1\":[^,}]+" | head -n1 | sed -E "s/\"$1\"://; s/^\"//; s/\"$//"; }

# =============================================================================
# 輸出
# =============================================================================
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

print_conditions() { printf '%s' "$CONDITIONS"; }

print_json() {
  local first=1
  printf '{'
  printf '"logfile":"%s","log_bytes":%s,"log_lines":%s,"log_age_sec":%s,' "$(json_escape "$LOGFILE")" "$LOG_BYTES" "$LOG_LINES" "$LOG_AGE"
  printf '"log_start":"%s","log_end":"%s",' "$(json_escape "${LOG_START:-}")" "$(json_escape "${LOG_END:-}")"
  printf '"process":{"running":%s,"pid":"%s","cpu":"%s","mem_mb":"%s","threads":"%s","uptime":"%s"},' \
    "$PROC_RUNNING" "${PROC_PID:-}" "$PROC_CPU" "$PROC_MEM_MB" "$PROC_THREADS" "$PROC_UPTIME"
  printf '"sync_mode":"%s","stage":"%s","log_activity":"%s","hang":%s,' "$SYNC_MODE" "$(json_escape "$STAGE")" "$LOG_ACTIVITY" "$HANG"
  printf '"incr":{"events":%s,"span_sec":%s,"rate":"%s","lag":"%s","lag_sec":"%s"},' "$INCR_EVENTS" "$INCR_SPAN" "$INCR_RATE" "$(json_escape "$INCR_LAG")" "${INCR_LAG_SEC:-}"
  printf '"perf":{"write":{"n":%s,"avg":%s,"min":%s,"max":%s,"p95":%s},"scan":{"n":%s,"avg":%s,"min":%s,"max":%s,"p95":%s},"parser":{"n":%s,"avg":%s,"min":%s,"max":%s,"p95":%s},"slow_write":%s,"slow_scan":%s},' \
    "$WC" "$WAVG" "$WMIN" "$WMAX" "$WP95" "$SC" "$SAVG" "$SMIN" "$SMAX" "$SP95" "$PC" "$PAVG" "$PMIN" "$PMAX" "$PP95" "$SLOW_W" "$SLOW_S"
  printf '"bottleneck":"%s",' "$(json_escape "$BOTTLENECK")"
  printf '"errors":{"error":%s,"panic":%s,"timeout":%s,"throttle":%s,"conn":%s,"shard_expired":%s},' \
    "$C_ERROR" "$C_PANIC" "$C_TIMEOUT" "$C_THROTTLE" "$C_CONN" "$C_SHARD"
  printf '"http":{"full_%s":"%s","incr_%s":"%s","pprof_%s":"%s"},' \
    "$HTTP_FULL_PORT" "$(http_check "$HTTP_FULL_PORT")" "$HTTP_INCR_PORT" "$(http_check "$HTTP_INCR_PORT")" "$HTTP_PPROF_PORT" "$(http_check "$HTTP_PPROF_PORT")"
  printf '"system":{"cores":"%s","load":"%s","mem":"%s","disk":"%s"},' \
    "$SYS_CORES" "$(json_escape "$SYS_LOAD")" "$(json_escape "$SYS_MEM")" "$(json_escape "$SYS_DISK")"
  printf '"tables":['
  while IFS=$'\t' read -r tb st ba es du ra pc et; do
    [ -z "$tb" ] && continue
    [ $first -eq 0 ] && printf ','; first=0
    printf '{"table":"%s","status":"%s","batches":%s,"est_rows":%s,"dur_sec":%s,"rate":%s,"pct":"%s","eta":"%s"}' \
      "$(json_escape "$tb")" "$(json_escape "$st")" "${ba:-0}" "${es:-0}" "${du:-0}" "${ra:-0}" "$(json_escape "${pc:--}")" "$(json_escape "${et:--}")"
  done <<< "$(compute_table_stats)"
  printf '],'
  first=1
  printf '"conditions":['
  while IFS='|' read -r t sev id c title detail; do
    [ -z "$id" ] && continue
    [ $first -eq 0 ] && printf ','; first=0
    printf '{"type":"%s","severity":"%s","id":"%s","count":%s,"title":"%s","detail":"%s"}' \
      "$t" "$sev" "$id" "${c:-0}" "$(json_escape "$title")" "$(json_escape "$detail")"
  done <<< "$CONDITIONS"
  printf ']}'
  printf '\n'
}

print_suggestions() {
  local any=0
  if [ "$PROC_RUNNING" -eq 0 ] && [ "$HAS_FULL_DONE" -eq 0 ] && [ "$HAS_START_SYNC" -gt 0 ]; then
    echo "   • Process 停止但全量未完成 → 需重啟，全量會從頭開始 (無斷點續傳)"; any=1; fi
  [ "$C_THROTTLE" -gt 0 ] && { echo "   • 出現 DynamoDB throttling → 降低 qps.full 或增加來源 RCU"; any=1; }
  [ "$C_SHARD" -gt 0 ]    && { echo "   • Shard Iterator 過期 → 增量資料可能遺失，建議重跑 full sync"; any=1; }
  [ "$SLOW_W" -gt 0 ]     && { echo "   • MongoDB 寫入延遲偏高 → 檢查目標 MongoDB 的 CPU/IO/網路"; any=1; }
  [ "$HANG" -eq 1 ]       && { echo "   • 疑似假死 → 檢查程序是否卡住，必要時重啟"; any=1; }
  [ "$any" -eq 0 ] && echo "   • 目前運行正常，無需操作"
}

print_human() {
  local B="\033[1m" R="\033[0m" G="\033[32m" Y="\033[33m" RED="\033[31m" DIM="\033[2m"
  echo -e "${B}══════════ NimoShake 監控報表 ══════════${R}"
  echo -e "Log 檔案 : $LOGFILE"
  echo -e "大小/行數: ${LOG_BYTES} bytes / ${LOG_LINES} 行"
  echo -e "時間範圍 : ${LOG_START:-?}  ~  ${LOG_END:-?}"
  echo -e "最後寫入 : $(human_secs "$LOG_AGE") 前  (${LOG_ACTIVITY})"
  echo
  echo -e "${B}[1] 程式狀態${R}"
  if [ "$PROC_RUNNING" -eq 1 ]; then
    echo -e "   ${G}● 運行中${R}  PID=$PROC_PID  CPU=${PROC_CPU}%  RSS=${PROC_MEM_MB}MB  執行緒=${PROC_THREADS}  運行=${PROC_UPTIME}"
  else echo -e "   ${RED}● 未運行${R}"; fi
  echo -e "${B}[2] 同步階段${R}"
  echo -e "   模式: $SYNC_MODE   階段: $STAGE_SYM $STAGE"
  if [ "$INCR_EVENTS" -gt 0 ]; then
    echo -e "   增量: 近 ${SCAN_TAIL_LINES} 行取樣 ${INCR_EVENTS} 筆事件 (~${INCR_RATE} 筆/s)  同步延遲: ${INCR_LAG}"
    [ -n "$INCR_TABLES_DESC" ] && echo -e "   活躍 table: $INCR_TABLES_DESC"
  fi
  [ "$HANG" -eq 1 ] && echo -e "   ${RED}⚠ 疑似假死: 程序在但 log 停止寫入${R}"
  echo -e "${B}[3] Table 進度${R}"
  if [ -n "$TABLES" ]; then
    printf "   %-16s %-12s %10s %14s %10s %10s %8s %12s\n" "Table" "狀態" "批次" "預估筆數" "耗時(s)" "速率/s" "進度%" "預計剩餘"
    while IFS=$'\t' read -r tb st ba es du ra pc et; do
      [ -z "$tb" ] && continue
      printf "   %-16s %-12s %10s %14s %10s %10s %8s %12s\n" "$tb" "$st" "$ba" "$es" "$du" "$ra" "${pc:--}" "${et:--}"
    done <<< "$(compute_table_stats)"
    echo -e "   ${DIM}(每批大小 batch=${BATCH_SIZE}，預估筆數 = 批次 × batch)${R}"
    [ -z "$TABLE_TOTALS" ] && echo -e "   ${DIM}(進度%/預計剩餘 需在 conf 設 TABLE_TOTALS 基準，可用 --totals 從上次全量 log 產生)${R}"
    [ "$INCR_EVENTS" -gt 0 ] && echo -e "   ${DIM}(增量期逐筆事件同步，全量批次數字僅為本檔歷史；增量現況見 [2])${R}"
  else echo -e "   ${DIM}(log 中未偵測到 table)${R}"; fi
  echo -e "${B}[4] 效能 (近 ${SCAN_TAIL_LINES} 行取樣)${R}"
  printf "   %-12s %6s %8s %8s %8s %8s\n" "段落" "樣本" "平均ms" "最小ms" "最大ms" "P95ms"
  printf "   %-12s %6s %8s %8s %8s %8s\n" "MongoDB寫入" "$WC" "$WAVG" "$WMIN" "$WMAX" "$WP95"
  printf "   %-12s %6s %8s %8s %8s %8s\n" "DynamoDB讀取" "$SC" "$SAVG" "$SMIN" "$SMAX" "$SP95"
  printf "   %-12s %6s %8s %8s %8s %8s\n" "資料轉換"     "$PC" "$PAVG" "$PMIN" "$PMAX" "$PP95"
  [ "$WC" -eq 0 ] && [ "$SC" -eq 0 ] && [ "$INCR_EVENTS" -gt 0 ] && \
    echo -e "   ${DIM}(增量同步期無全量效能欄位可取樣，全為 0 屬正常；增量速率見 [2])${R}"
  echo -e "${B}[5] 瓶頸${R}"
  echo -e "   $BOTTLENECK"
  echo -e "${B}[6] 異常偵測 (全檔累計)${R}"
  printf "   ERROR:%s Panic:%s Timeout:%s Throttle:%s Conn:%s ShardExpired:%s\n" "$C_ERROR" "$C_PANIC" "$C_TIMEOUT" "$C_THROTTLE" "$C_CONN" "$C_SHARD"
  printf "   慢寫入(>%sms):%s  慢讀取(>%sms):%s\n" "$SLOW_WRITE_MS" "$SLOW_W" "$SLOW_SCAN_MS" "$SLOW_S"
  echo -e "${B}[7] HTTP 端點 (localhost, NimoShake 內建監控 API)${R}"
  # check 結果只算一次；port 為 up 才抓內容 (down 的 port 每個 curl 都會等滿逾時，白燒最多 10 秒)
  local _fs _is _ps _fb _ib
  _fs=$(http_check "$HTTP_FULL_PORT"); _is=$(http_check "$HTTP_INCR_PORT"); _ps=$(http_check "$HTTP_PPROF_PORT")
  printf "   Full(%s):%s  Incr(%s):%s  PProf(%s):%s\n" \
    "$HTTP_FULL_PORT" "$_fs" "$HTTP_INCR_PORT" "$_is" "$HTTP_PPROF_PORT" "$_ps"
  [ "$_fs" = "up" ] && _fb=$(http_fetch "$HTTP_FULL_PORT") && echo -e "   ${DIM}Full${_fb}${R}"
  [ "$_is" = "up" ] && _ib=$(http_fetch "$HTTP_INCR_PORT") && echo -e "   ${DIM}Incr${_ib}${R}"
  echo -e "${B}[8] 系統資源${R}"
  echo -e "   CPU核心:$SYS_CORES  負載:$SYS_LOAD  記憶體:$SYS_MEM"
  echo -e "   磁碟(log所在):$SYS_DISK"
  echo -e "${B}[9] 操作建議${R}"
  print_suggestions
  echo -e "${B}[設定參數] (log configuration)${R}"
  printf "   SyncMode=%s  FullConcurrency=%s  ReadConcurrency=%s  WriteBatch=%s  QpsFull=%s\n" \
    "$(cfg_get SyncMode)" "$(cfg_get FullConcurrency)" "$(cfg_get FullReadConcurrency)" "$(cfg_get FullDocumentWriteBatch)" "$(cfg_get QpsFull)"
  echo -e "${B}[告警條件] (alert 引擎會處理)${R}"
  while IFS='|' read -r t sev id c title detail; do
    [ -z "$id" ] && continue
    local mark="  "; case "$sev" in high) mark="${RED}✗${R}";; medium) mark="${Y}▲${R}";; low) mark="${DIM}·${R}";; info) mark="${G}✓${R}";; esac
    echo -e "   $mark [$sev/$id] $title ${DIM}$detail${R}"
  done <<< "$CONDITIONS"
  echo -e "${B}════════════════════════════════════════${R}"
}

# =============================================================================
# --summary: 每個監控面向的「判讀結果」(供告警信使用)
# 每行格式: status|面向|說明   status = ok(正常) / bad(異常) / info(參考資訊) / na(無資料)
# 判讀邏輯全部來自真實 log 的計算值，不做任何假設
# =============================================================================
print_summary() {
  # 1) 程式狀態
  if [ "$HANG" -eq 1 ]; then
    echo "bad|程式狀態|疑似假死: 程序在 (PID $PROC_PID) 但 log 已 $(human_secs "$LOG_AGE") 無寫入"
  elif [ "$PROC_RUNNING" -eq 1 ]; then
    echo "ok|程式狀態|運行中 (PID $PROC_PID, CPU ${PROC_CPU}%, 記憶體 ${PROC_MEM_MB}MB)"
  else
    echo "bad|程式狀態|未運行 (log 最後寫入於 $(human_secs "$LOG_AGE") 前)"
  fi

  # 2) 同步階段
  if [ "$STAGE" = "已停止" ] || { [ "$PROC_RUNNING" -eq 0 ] && [ "$HAS_FULL_DONE" -eq 0 ] && [ "$HAS_START_SYNC" -gt 0 ]; }; then
    echo "bad|同步階段|$STAGE (全量未完成即中止，重啟會從頭開始)"
  else
    echo "ok|同步階段|$STAGE (模式: $SYNC_MODE)"
  fi

  # 2.5) 增量同步 (取樣中有增量事件才顯示)；延遲超過 STALL_SECONDS 視為異常
  if [ "$INCR_EVENTS" -gt 0 ]; then
    if [ -n "$INCR_LAG_SEC" ] && [ "$INCR_LAG_SEC" -ge "$STALL_SECONDS" ]; then
      echo "bad|增量同步|同步延遲 ${INCR_LAG} 超過門檻 $(human_secs "$STALL_SECONDS")；近取樣 ${INCR_EVENTS} 筆 (~${INCR_RATE} 筆/s)"
    else
      echo "ok|增量同步|近取樣 ${INCR_EVENTS} 筆事件 (~${INCR_RATE} 筆/s)，同步延遲 ${INCR_LAG}${INCR_TABLES_DESC:+；活躍: ${INCR_TABLES_DESC}}"
    fi
  fi

  # 3) Table 進度: 逐張判讀 (含名稱/筆數)，未完成且程序已不在 = 中斷(異常)
  if [ -n "$TABLES" ]; then
    local t_done=0 t_done_desc="" t_bad="" t_run=""
    while IFS=$'\t' read -r tb st ba es du ra pc et; do
      [ -z "$tb" ] && continue
      local _p=""; [ -n "$pc" ] && [ "$pc" != "-" ] && _p=" ${pc}"
      local _e=""; [ -n "$et" ] && [ "$et" != "-" ] && _e="，預計剩餘 ${et}"
      if [ "$st" = "完成" ]; then t_done=$((t_done+1)); t_done_desc+="${tb}(~${es} 筆)、"
      elif [ "$PROC_RUNNING" -eq 0 ]; then t_bad+="${tb} 中斷於約 ${es} 筆${_p} (${ba} 批)；"
      else t_run+="${tb} 進行中約 ${es} 筆${_p} (速率 ${ra} 筆/s${_e})；"
      fi
    done <<< "$(compute_table_stats)"
    t_done_desc="${t_done_desc%、}"
    if [ -n "$t_bad" ]; then
      echo "bad|Table 進度|${t_bad}已完成 ${t_done} 張${t_done_desc:+: ${t_done_desc}}"
    elif [ -n "$t_run" ]; then
      echo "ok|Table 進度|${t_run}已完成 ${t_done} 張${t_done_desc:+: ${t_done_desc}}"
    else
      echo "ok|Table 進度|全部 ${t_done} 張完成${t_done_desc:+: ${t_done_desc}}"
    fi
  else
    echo "na|Table 進度|log 中未偵測到 table"
  fi

  # 4) 來源讀取延遲 (DynamoDB Scan)
  if [ "$SC" -gt 0 ]; then
    if awk -v a="$SAVG" -v t="$SLOW_SCAN_MS" 'BEGIN{exit !(a>t)}'; then
      echo "bad|來源讀取 (DynamoDB)|平均 ${SAVG}ms 超過門檻 ${SLOW_SCAN_MS}ms (P95 ${SP95}ms，取樣 ${SC} 筆)"
    else
      echo "ok|來源讀取 (DynamoDB)|平均 ${SAVG}ms / P95 ${SP95}ms (門檻 ${SLOW_SCAN_MS}ms，取樣 ${SC} 筆)"
    fi
  else
    echo "na|來源讀取 (DynamoDB)|近 ${SCAN_TAIL_LINES} 行無取樣"
  fi

  # 5) 目標寫入延遲 (MongoDB)
  if [ "$WC" -gt 0 ]; then
    if awk -v a="$WAVG" -v t="$SLOW_WRITE_MS" 'BEGIN{exit !(a>t)}'; then
      echo "bad|目標寫入 (MongoDB)|平均 ${WAVG}ms 超過門檻 ${SLOW_WRITE_MS}ms (P95 ${WP95}ms，取樣 ${WC} 筆)"
    else
      echo "ok|目標寫入 (MongoDB)|平均 ${WAVG}ms / P95 ${WP95}ms (門檻 ${SLOW_WRITE_MS}ms，取樣 ${WC} 筆)"
    fi
  else
    echo "na|目標寫入 (MongoDB)|近 ${SCAN_TAIL_LINES} 行無取樣"
  fi

  # 5.5) 資料轉換延遲 (Parser，參考資訊)
  if [ "$PC" -gt 0 ]; then
    echo "info|資料轉換 (Parser)|平均 ${PAVG}ms / P95 ${PP95}ms (取樣 ${PC} 筆)"
  else
    echo "na|資料轉換 (Parser)|近 ${SCAN_TAIL_LINES} 行無取樣"
  fi

  # 6) 瓶頸判定 (三段比較，指出最慢環節在來源/目標/轉換)
  case "$BN" in
    fetcher) echo "info|瓶頸判定|最慢環節=來源讀取 DynamoDB (avg ${SAVG}ms)；可調 qps.full / full.read.concurrency" ;;
    writer)  echo "info|瓶頸判定|最慢環節=目標寫入 MongoDB (avg ${WAVG}ms)；可調 full.document.concurrency 或查目標負載" ;;
    parser)  echo "info|瓶頸判定|最慢環節=資料轉換 (avg ${PAVG}ms)；可調 full.document.parser" ;;
    *)       echo "na|瓶頸判定|取樣不足，無法判定" ;;
  esac

  # 7) 系統資源: 磁碟/記憶體超過門檻 (可用 NS_DISK_ALERT_PCT / NS_MEM_ALERT_PCT 調整)
  #    或 1 分鐘負載 > 核心數 視為異常
  local disk_th="${NS_DISK_ALERT_PCT:-85}" mem_th="${NS_MEM_ALERT_PCT:-90}"
  local disk_pct="" mem_pct="" load1="" sys_bad="" sys_desc=""
  disk_pct=$(df -P "$(dirname "$LOGFILE")" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  [ -r /proc/meminfo ] && mem_pct=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/MemFree/{f=$2}/^Buffers/{b=$2}/^Cached/{c=$2} END{if(a=="")a=f+b+c; if(t>0) printf "%d", (t-a)*100/t}' /proc/meminfo 2>/dev/null)
  [ -r /proc/loadavg ] && load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
  sys_desc="磁碟 ${disk_pct:-?}%、記憶體 ${mem_pct:-?}%、負載 ${load1:-?}/${SYS_CORES} 核"
  [ -n "$disk_pct" ] && [ "$disk_pct" -gt "$disk_th" ] 2>/dev/null && sys_bad+="磁碟 ${disk_pct}% 超過門檻 ${disk_th}%；"
  [ -n "$mem_pct" ] && [ "$mem_pct" -gt "$mem_th" ] 2>/dev/null && sys_bad+="記憶體 ${mem_pct}% 超過門檻 ${mem_th}%；"
  if [ -n "$load1" ] && [ "$SYS_CORES" != "-" ] && awk -v l="$load1" -v c="$SYS_CORES" 'BEGIN{exit !(l>c)}'; then
    sys_bad+="負載 ${load1} 超過核心數 ${SYS_CORES}；"
  fi
  if [ -n "$sys_bad" ]; then echo "bad|系統資源|${sys_bad%；}"
  else echo "ok|系統資源|$sys_desc"
  fi
}

case "$MODE" in
  json)       print_json ;;
  conditions) print_conditions ;;
  summary)    print_summary ;;
  human)      print_human ;;
  watch)      # 每輪重新執行本腳本重算，才是真的刷新 (變數在頂部只算一次，直接重印會是舊值)
              # 目標帶 conf 原路徑 (若有)，讓 TABLE_TOTALS/門檻/port 等 conf 設定每輪重新套用
              # trap: Ctrl-C / kill 時收乾淨地離開，不留半張報表；sleep 放背景 + wait 讓訊號即時生效
              trap 'printf "\n(監控結束)\n"; exit 0' INT TERM
              while true; do
                _out=$(bash "$0" --human "${CONF_PATH:-$LOGFILE}" 2>&1)   # 先在背後算完，再一次清屏重印，畫面不閃爍
                clear 2>/dev/null || printf '\033[2J\033[H'
                printf '%s\n' "$_out"
                echo "(每 ${WATCH_INTERVAL}s 刷新，Ctrl-C 結束；要單次報表請加 --human)"
                sleep "$WATCH_INTERVAL" & wait $! || true
              done ;;
esac
