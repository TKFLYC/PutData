#!/bin/bash
# =============================================================================
# nimoshake-alert.sh  v1.4 — NimoShake 監控告警引擎 (SendGrid)
# -----------------------------------------------------------------------------
# 設計給「每分鐘一次 cron」使用，重點在「不亂寄、不重複寄」:
#   1. 狀態機:  新增(NEW) / 未解除(FIRING) / 已解除(RESOLVED)
#   2. 事件去重: 只計算「上次檢查後新增」的 log 段落 (byte offset)，
#               舊的錯誤不會每分鐘重寄。
#   3. 批次寄信: 同一次執行的多個條件合併成「一封」新增信 / 一封解除信，
#               而不是每個條件一封。
#   4. 冷卻/上限: 任兩封信最小間隔 GLOBAL_COOLDOWN，單次最多 MAX_MAILS_PER_RUN。
#   5. 嚴重度門檻: 低於 ALERT_MIN_SEVERITY 的條件只記錄、不寄信。
#   6. DRY_RUN=1 (預設) 只寫 log 不真的寄信 —— 上線前請確認後才改 0。
#   7. FullCheck 完成通知 (v1.4): conf 設 FULLCHECK_DIR 後，nimo-full-check
#      跑完 (輸出資料夾出現 run-manifest.json) 自動寄結果信；使用者照原本
#      指令跑 fullcheck，不需改任何操作。
#
# 用法:
#   ./nimoshake-alert.sh <env.conf>
#   ./nimoshake-alert.sh --send  <env.conf>   # 覆寫成真的寄 (DRY_RUN=0)
#   ./nimoshake-alert.sh --dry   <env.conf>   # 強制 dry-run
#   ./nimoshake-alert.sh --status <env.conf>  # 只印目前狀態，不動狀態檔、不寄信
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh 支援兩種擺放: lib/ 子目錄 (repo 佈局) 或與本腳本同層 (交付包平放佈局)
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh"
else
  . "$SCRIPT_DIR/common.sh"
fi

MONITOR="$SCRIPT_DIR/nimoshake-monitor.sh"

FORCE=""       # send | dry | ""
STATUS_ONLY=0
CONF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --send)   FORCE="send" ;;
    --dry)    FORCE="dry" ;;
    --status) STATUS_ONLY=1 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知參數: $1" >&2; exit 2 ;;
    *)  CONF="$1" ;;
  esac
  shift
done

load_config "$CONF" || exit 1
[ "$FORCE" = "send" ] && DRY_RUN=0
[ "$FORCE" = "dry" ]  && DRY_RUN=1

COND_DIR="$STATE_DIR/cond"
OFFSET_FILE="$STATE_DIR/.log_offset"
LASTMAIL_FILE="$STATE_DIR/.last_mail"
mkdir -p "$COND_DIR" 2>/dev/null || true

# --status 承諾「不動狀態檔」: 改在狀態檔的暫存副本上運算，離開時清掉
if [ "$STATUS_ONLY" -eq 1 ]; then
  TMP_COND=$(mktemp -d)
  cp -a "$COND_DIR/." "$TMP_COND"/ 2>/dev/null || true
  COND_DIR="$TMP_COND"
  trap 'rm -rf "$TMP_COND"' EXIT
fi

NOW=$(date +%s)

sev_rank() { case "$1" in high) echo 4;; medium) echo 3;; low) echo 2;; info) echo 1;; *) echo 0;; esac; }
MIN_RANK=$(sev_rank "$ALERT_MIN_SEVERITY")

# ---- 事件去重: 只掃「新增」的 log 段落 --------------------------------------
LOG_SIZE=0
[ -r "$LOG_FILE" ] && { LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' '); : "${LOG_SIZE:=0}"; }
FIRST_RUN=0
[ -f "$OFFSET_FILE" ] || FIRST_RUN=1
PREV_OFFSET=0
[ -f "$OFFSET_FILE" ] && PREV_OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null | tr -d ' ')
[ -z "$PREV_OFFSET" ] && PREV_OFFSET=0
# log 被輪替 (變小) 就從頭
[ "$LOG_SIZE" -lt "$PREV_OFFSET" ] && PREV_OFFSET=0

# 冷啟動保護: 第一次執行 (沒有 offset 檔) 只記錄基準點，不把整份歷史 log 的
# 舊事件當成「新增」而狂寄信。狀態類條件 (process/stall) 仍會正常判斷當下狀態。
NEW_SEG=""
if [ "$FIRST_RUN" -eq 1 ]; then
  log_line "INFO: [$ENV_NAME] 首次執行，建立 log 基準點 (offset=$LOG_SIZE)，本次不對歷史事件發信"
elif [ "$LOG_SIZE" -gt "$PREV_OFFSET" ]; then
  NEW_SEG=$(tail -c +$((PREV_OFFSET + 1)) "$LOG_FILE" 2>/dev/null)
fi

seg_count() { [ -z "$NEW_SEG" ] && { echo 0; return; }; local n; n=$(printf '%s' "$NEW_SEG" | grep -icE "$1" 2>/dev/null); echo "${n:-0}"; }
seg_count_awk_write() { [ -z "$NEW_SEG" ] && { echo 0; return; }; printf '%s' "$NEW_SEG" | awk -v th="$SLOW_WRITE_MS" 'function ms(v){if(v~/µs$|us$/){gsub(/µs$|us$/,"",v);return v/1000}if(v~/ms$/){gsub(/ms$/,"",v);return v+0}if(v~/s$/){gsub(/s$/,"",v);return v*1000}return v+0} {if(match($0,/writeDestDbTime\[[^]]+\]/)){x=substr($0,RSTART+16,RLENGTH-17); if(ms(x)>th)n++}} END{print n+0}'; }
seg_count_awk_scan() { [ -z "$NEW_SEG" ] && { echo 0; return; }; printf '%s' "$NEW_SEG" | awk -v th="$SLOW_SCAN_MS" 'function ms(v){if(v~/µs$|us$/){gsub(/µs$|us$/,"",v);return v/1000}if(v~/ms$/){gsub(/ms$/,"",v);return v+0}if(v~/s$/){gsub(/s$/,"",v);return v*1000}return v+0} {if(match($0,/scanTime\[[^]]+\]/)){x=substr($0,RSTART+9,RLENGTH-10); if(ms(x)>th)n++}} END{print n+0}'; }

# 事件 ID -> 新段落計數 (0 表示這次沒有新的 -> 視為不活躍)
declare -A EVENT_NEWCOUNT
EVENT_NEWCOUNT[ERROR_DETECTED]=$(seg_count '\[(ERROR|CRIT|FATAL)\]')
EVENT_NEWCOUNT[PANIC]=$(seg_count 'panic:')   # 帶冒號: 避免誤中增量事件 base64 資料裡隨機出現的 panic 字樣
EVENT_NEWCOUNT[TIMEOUT]=$(seg_count 'timed out|i/o timeout|deadline exceeded|connection timeout')
EVENT_NEWCOUNT[THROTTLE]=$(seg_count 'throttl|ProvisionedThroughputExceeded')
EVENT_NEWCOUNT[CONN_ERROR]=$(seg_count 'connection refused|broken pipe|no route to host')
EVENT_NEWCOUNT[SHARD_EXPIRED]=$(seg_count 'ExpiredIterator|TrimmedData')
EVENT_NEWCOUNT[SLOW_WRITE]=$(seg_count_awk_write)
EVENT_NEWCOUNT[SLOW_SCAN]=$(seg_count_awk_scan)

# ---- 取得目前條件 (由 monitor 判斷 STATE，EVENT 由上面重算) -----------------
# log 檔不存在/不可讀時，監控等同失明，這本身就是 high 告警；
# 不能讓 monitor 失敗導致條件清單變空、被誤判成「全部解除」。
FREEZE=0
if [ ! -r "$LOG_FILE" ]; then
  CONDITIONS="STATE|high|LOG_MISSING|1|log 檔不存在或不可讀|$LOG_FILE 讀不到，監控暫時失效，請確認 NimoShake log 路徑或檔案權限。"
  FREEZE=1   # log 讀不到 → 既有告警無從判斷，凍結不解除、不誤寄 🟢
else
  CONDITIONS=$(
    NS_STALL_SECONDS="$STALL_SECONDS" NS_HANG_SECONDS="${HANG_SECONDS:-60}" \
    NS_SLOW_WRITE_MS="$SLOW_WRITE_MS" NS_SLOW_SCAN_MS="$SLOW_SCAN_MS" \
    NS_SCAN_TAIL_LINES="${SCAN_TAIL_LINES:-2000}" \
    NS_EXPECT_RUNNING="${EXPECT_RUNNING:-0}" NS_PROC_PATTERN="$PROC_PATTERN" \
    NS_TABLE_TOTALS="${TABLE_TOTALS:-}" \
    bash "$MONITOR" --conditions "$LOG_FILE"
  ) || true
  # monitor 正常時至少會輸出 ALL_CLEAR；輸出為空代表 monitor 失敗 (如 -r 檢查後
  # log 剛好被刪的競態) → 視同 log 遺失並凍結，避免全部條件被誤判解除
  if [ -z "$CONDITIONS" ]; then
    CONDITIONS="STATE|high|LOG_MISSING|1|log 檔不存在或不可讀|monitor 無法讀取 $LOG_FILE，監控暫時失效，請確認 NimoShake log 路徑或檔案權限。"
    FREEZE=1
  fi
fi

# ---- 讀/寫單一條件狀態檔 (tab 分隔，安全解析) ------------------------------
state_get() { # state_get ID KEY  (印出值，找不到回傳非 0；不會有多餘空白)
  local f="$COND_DIR/$1"; [ -f "$f" ] || return 1
  awk -F '\t' -v k="$2" '$1==k{ sub(/^[^\t]*\t/,""); print; f=1; exit } END{ exit(f?0:1) }' "$f"
}
state_write() { # state_write ID type sev first_seen last_sent count title
  local f="$COND_DIR/$1"
  {
    printf 'type\t%s\n' "$2"
    printf 'severity\t%s\n' "$3"
    printf 'first_seen\t%s\n' "$4"
    printf 'last_sent\t%s\n' "$5"
    printf 'count\t%s\n' "$6"
    printf 'title\t%s\n' "$7"
  } > "$f"
}

# ---- 每種條件的處理建議 (寄進信裡，收件人不必再查文件) ----------------------
action_for() { # $1=條件 ID -> 印出處理建議
  case "$1" in
    PROCESS_DOWN)         echo "確認程序: ps -ef | grep nimo-shake；查是否 OOM/重開機被終止 (dmesg、/var/log/messages)。若全量未完成，重啟會從頭開始且目標庫會被清空重灌，重啟前請先確認。" ;;
    FULL_SYNC_INCOMPLETE) echo "全量沒跑完就中止，NimoShake 不支援斷點續傳。處理: 確認來源/目標連線正常後重新執行 nimo-shake (會清空目標庫從頭同步)。" ;;
    LOG_HANG)             echo "程序還在但 log 卡住。先看 top 該 PID 的 CPU (100%=卡迴圈、0%=卡 IO/網路)；必要時重啟 nimo-shake。" ;;
    LOG_STALLED)          echo "確認程序狀態與磁碟空間 (df -h)；若程序已死請比照「程序未運行」處理。" ;;
    LOG_MISSING)          echo "確認 conf 的 LOG_FILE 路徑是否正確、log 是否被搬移/輪替、檔案權限是否可讀。監控在此期間是失效的，請盡快恢復。" ;;
    ERROR_DETECTED)       echo "查看最近錯誤內容: grep -E '\\[(ERROR|CRIT|FATAL)\\]' <log檔> | tail -20，依錯誤訊息處理；持續大量出現請通知開發窗口。" ;;
    PANIC)                echo "程式已崩潰 (Go panic)。收集 log 中 panic 段落後重啟；若重啟後連續 panic，請將 panic 訊息回報開發窗口。" ;;
    SHARD_EXPIRED)        echo "增量資料可能已遺失，僅重啟無法補救。處理: 重跑 full sync 以保證資料一致。" ;;
    THROTTLE)             echo "DynamoDB 被限流。處理: 調低 NimoShake 設定的 qps.full，或提高來源 DynamoDB 的 RCU。" ;;
    TIMEOUT)              echo "檢查來源/目標的網路與負載: 能否連上 MongoDB Atlas (telnet/openssl)、Atlas 監控是否高負載。" ;;
    CONN_ERROR)           echo "檢查網路/防火牆/DNS，確認目標服務是否重啟過；若為瞬斷且未再出現可觀察即可。" ;;
    SLOW_WRITE)           echo "MongoDB 寫入偏慢。查目標叢集 CPU/IOPS/連線數；持續偏慢可調降寫入並行 full.document.concurrency。" ;;
    SLOW_SCAN)            echo "DynamoDB 讀取偏慢。確認 RCU 是否足夠，或調整 full.read.concurrency。" ;;
    *)                    echo "查看 log 詳情並依內容處理；可先執行 --status 查看目前所有條件。" ;;
  esac
}

# ---- HTML 信件輔助 (每個異常一張卡片，避免純文字在郵件軟體裡排版跑掉) --------
sev_color() { case "$1" in high) echo '#d93025';; medium) echo '#e37400';; *) echo '#5f6368';; esac; }
html_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
html_card() { # $1=顏色 $2=標題列 $3=狀況(可空) $4=處理建議(可空)
  local c="$1" t s a
  t=$(html_escape "$2"); s=$(html_escape "$3"); a=$(html_escape "$4")
  printf '<div style="border-left:4px solid %s;background:#f8f9fa;padding:10px 14px;margin:0 0 10px;border-radius:0 6px 6px 0">' "$c"
  printf '<div style="font-weight:bold;color:%s">%s</div>' "$c" "$t"
  [ -n "$s" ] && printf '<div style="color:#3c4043;margin-top:4px">狀況: %s</div>' "$s"
  [ -n "$a" ] && printf '<div style="color:#202124;margin-top:6px;padding:8px 10px;background:#fff;border:1px solid #e0e0e0;border-radius:4px">👉 <b>處理:</b> %s</div>' "$a"
  printf '</div>'
}

# ---- 蒐集本次執行要寄的東西 (批次) -----------------------------------------
# 信件項目: 純文字版 (■ 區塊) + HTML 版 (卡片)，兩版並存由郵件軟體挑 HTML 顯示
NEW_LIST=""      ; NEW_HTML=""      # 新增
FIRING_LIST=""   ; FIRING_HTML=""   # 未解除且到期提醒
RESOLVED_LIST="" ; RESOLVED_HTML="" # 已解除
declare -A ACTIVE_IDS

process_condition() { # TYPE SEV ID COUNT TITLE DETAIL
  local type="$1" sev="$2" id="$3" cnt="$4" title="$5" detail="$6"
  [ "$id" = "ALL_CLEAR" ] && return
  # 事件: 用「新段落計數」判斷是否活躍
  if [ "$type" = "EVENT" ]; then
    # 自檢: monitor 新增 EVENT 條件但這裡漏加 EVENT_NEWCOUNT 時，明確警告而非永久靜默
    if [ -z "${EVENT_NEWCOUNT[$id]+x}" ]; then
      log_line "WARN: EVENT 條件 $id 缺少 EVENT_NEWCOUNT 對映 (nimoshake-alert.sh)，該事件將不會觸發告警，請補上"
      return
    fi
    local nc="${EVENT_NEWCOUNT[$id]:-0}"
    [ "$nc" -eq 0 ] && return   # 這次沒有新的 -> 不活躍，交給解除流程
    cnt="$nc"
  fi
  ACTIVE_IDS[$id]=1

  # 嚴重度門檻: 低於門檻只記錄狀態、不列入寄信
  local rank; rank=$(sev_rank "$sev")
  local below=0; [ "$rank" -lt "$MIN_RANK" ] && below=1

  local prev_first prev_last
  if prev_first=$(state_get "$id" first_seen 2>/dev/null); then
    # 已存在 -> 未解除
    prev_last=$(state_get "$id" last_sent 2>/dev/null); : "${prev_last:=0}"
    state_write "$id" "$type" "$sev" "$prev_first" "$prev_last" "$cnt" "$title"
    # last_sent=0 表示「新增信」從未寄成功 → 不論 REALERT_INTERVAL 為何都立即重試
    if [ "$below" -eq 0 ] && { [ "${prev_last:-0}" -eq 0 ] || { [ "${REALERT_INTERVAL:-0}" -gt 0 ] && [ $((NOW - prev_last)) -ge "$REALERT_INTERVAL" ]; }; }; then
      local dur; dur=$((NOW - prev_first))
      FIRING_LIST+="■ [$sev] $title (已持續 $((dur/3600))h$(((dur%3600)/60))m)"$'\n'"   狀況: $detail"$'\n'"   👉 處理: $(action_for "$id")"$'\n\n'
      FIRING_HTML+=$(html_card "$(sev_color "$sev")" "[$sev] $title（已持續 $((dur/3600))h$(((dur%3600)/60))m）" "$detail" "$(action_for "$id")")
      FIRING_DUE_IDS+=" $id"
    fi
  else
    # 新增: last_sent 先記 0，等「新增信」真的寄成功才蓋成 NOW。
    # 這樣寄失敗 (如 SendGrid 掛掉) 時，下一輪會以「到期提醒」立即重試，
    # 而不是沉默到 REALERT_INTERVAL 才再通知。
    if [ "$below" -eq 0 ]; then
      state_write "$id" "$type" "$sev" "$NOW" "0" "$cnt" "$title"
      NEW_LIST+="■ [$sev] $title"$'\n'"   狀況: $detail"$'\n'"   👉 處理: $(action_for "$id")"$'\n\n'
      NEW_HTML+=$(html_card "$(sev_color "$sev")" "[$sev] $title" "$detail" "$(action_for "$id")")
      NEW_IDS+=" $id"
    else
      state_write "$id" "$type" "$sev" "$NOW" "$NOW" "$cnt" "$title"
      log_line "INFO: 新增條件 $id ($sev) 低於寄信門檻($ALERT_MIN_SEVERITY)，僅記錄"
    fi
  fi
}

NEW_IDS=""
FIRING_DUE_IDS=""
RESOLVED_IDS=""
while IFS='|' read -r type sev id cnt title detail; do
  [ -z "$id" ] && continue
  process_condition "$type" "$sev" "$id" "${cnt:-1}" "$title" "$detail"
done <<< "$CONDITIONS"

# ---- 找出已解除 (狀態檔存在但這次不活躍) -----------------------------------
if [ -d "$COND_DIR" ]; then
  for f in "$COND_DIR"/*; do
    [ -e "$f" ] || continue
    id=$(basename "$f")
    [ -n "${ACTIVE_IDS[$id]:-}" ] && continue
    [ "$FREEZE" -eq 1 ] && continue   # log 失蹤期間凍結既有條件，等 log 恢復再判斷
    stype=$(state_get "$id" type 2>/dev/null); : "${stype:=STATE}"
    ssev=$(state_get "$id" severity 2>/dev/null); : "${ssev:=medium}"
    stitle=$(state_get "$id" title 2>/dev/null); : "${stitle:=$id}"
    sfirst=$(state_get "$id" first_seen 2>/dev/null); : "${sfirst:=$NOW}"
    slast=$(state_get "$id" last_sent 2>/dev/null); : "${slast:=0}"
    # EVENT 的通知從未寄成功 (last_sent=0，被冷卻擋下或 SendGrid 失敗) →
    # 不能靜默清除，保留狀態並補送；寄成功後由 mark_sent 蓋 last_sent，下一輪才清
    if [ "$stype" = "EVENT" ] && [ "$slast" -eq 0 ] && [ "$(sev_rank "$ssev")" -ge "$MIN_RANK" ]; then
      scnt=$(state_get "$id" count 2>/dev/null); : "${scnt:=1}"
      NEW_LIST+="■ [$ssev] $stitle (先前通知未送出，本封為補送；累計 $scnt 筆)"$'\n'"   👉 處理: $(action_for "$id")"$'\n\n'
      NEW_HTML+=$(html_card "$(sev_color "$ssev")" "[$ssev] $stitle（先前通知未送出，本封為補送；累計 $scnt 筆）" "" "$(action_for "$id")")
      NEW_IDS+=" $id"
      continue
    fi
    if [ "$stype" = "STATE" ] && [ "${NOTIFY_RESOLVED:-1}" = "1" ] && [ "$(sev_rank "$ssev")" -ge "$MIN_RANK" ]; then
      dur=$((NOW - sfirst))
      RESOLVED_LIST+="■ [$ssev] $stitle (曾持續 $((dur/60)) 分鐘，已自動恢復，無需處理)"$'\n'
      RESOLVED_HTML+=$(html_card "#188038" "[$ssev] $stitle（曾持續 $((dur/60)) 分鐘，已自動恢復，無需處理）" "" "")
      # 狀態檔先保留，等 🟢 信真的寄成功才刪；寄失敗或被冷卻擋下時下一輪重試
      RESOLVED_IDS+=" $id"
    else
      log_line "INFO: 條件 $id 已不活躍，靜默清除 (type=$stype)"
      rm -f "$f" 2>/dev/null || true
    fi
  done
fi

# ---- FullCheck 完成偵測 (conf 設 FULLCHECK_DIR 才啟用) -----------------------
# 需求: nimo-full-check 全量複核一跑數小時，結束後要用 SendGrid 通知結果。
# 判別: 專版 fullcheck「結束時」才會在輸出資料夾 (-d) 寫 run-manifest.json
#       (含 outcome/started_at/finished_at)，所以 manifest 出現 = 該次已結束。
#       使用者照原本指令跑 fullcheck 即可，不需改任何操作。
# 去重: 指紋 = finished_at|outcome 記在 state/.fullcheck_seen。刻意不用路徑當
#       指紋: fullcheck 重跑時會把舊輸出資料夾改名加時間戳，用路徑會誤判成
#       新結果而重寄。寄成功才記錄 (寄失敗/被冷卻擋下 → 下一輪重試，不漏寄)。
# 冷啟動: 首次啟用只把現有結果記為基準、不補寄歷史 (同 log offset 精神)。
FC_SEEN_FILE="$STATE_DIR/.fullcheck_seen"
FC_IDS=(); FC_SUBJECTS=(); FC_BODIES=(); FC_HTMLS=()

# 單行 JSON 取欄位 (機器上未必有 jq，用 sed 解析 fullcheck 的 summary 行)
fc_field_num() { printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -1; }
fc_field_str() { printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }
# manifest (多行 JSON) 取字串欄位: 頂層 outcome 在 tables 陣列之後，取最後一個
fc_manifest_str() { grep -o '"'"$2"'"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null | tail -1 | sed 's/.*"\([^"]*\)"$/\1/'; }

fc_build_mail() { # $1=run-manifest.json 路徑 $2=去重指紋 → 結果信推入 FC_* 陣列
  local mf="$1" fid="$2" dir outcome ms me dur="-" host subj
  dir=$(cd "$(dirname "$mf")" 2>/dev/null && pwd) || dir=$(dirname "$mf")
  outcome=$(fc_manifest_str "$mf" outcome); : "${outcome:=UNKNOWN}"
  ms=$(fc_manifest_str "$mf" started_at); me=$(fc_manifest_str "$mf" finished_at)
  local s1="" s2=""
  [ -n "$ms" ] && s1=$(date -d "$ms" +%s 2>/dev/null)
  [ -n "$me" ] && s2=$(date -d "$me" +%s 2>/dev/null)
  if [ -n "$s1" ] && [ -n "$s2" ]; then
    local d=$((s2 - s1))
    if   [ "$d" -ge 3600 ]; then dur="$((d/3600))h$(((d%3600)/60))m"
    elif [ "$d" -ge 60 ];   then dur="$((d/60))m$((d%60))s"
    else dur="${d}s"; fi
  fi

  # 各 table 統計: 輸出資料夾內每個 table 檔各有一行 {"type":"summary",...}
  local summaries; summaries=$(grep -rhs '"type":"summary"' "$dir" 2>/dev/null || true)
  local n_table=0 t_ck=0 t_ps=0 t_fl=0 t_ex=0 t_er=0 t_tg=0
  local rows_txt="" rows_html="" line tb oc ck ps fl ex er tg hl td
  td='padding:6px 10px;border:1px solid #e0e0e0'
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    tb=$(fc_field_str "$line" table);   oc=$(fc_field_str "$line" outcome)
    ck=$(fc_field_num "$line" checked); ps=$(fc_field_num "$line" passed)
    fl=$(fc_field_num "$line" failed);  ex=$(fc_field_num "$line" exceptions)
    er=$(fc_field_num "$line" execution_errors); tg=$(fc_field_num "$line" target_only)
    : "${ck:=0}" "${ps:=0}" "${fl:=0}" "${ex:=0}" "${er:=0}" "${tg:=0}"
    n_table=$((n_table+1))
    t_ck=$((t_ck+ck)); t_ps=$((t_ps+ps)); t_fl=$((t_fl+fl))
    t_ex=$((t_ex+ex)); t_er=$((t_er+er)); t_tg=$((t_tg+tg))
    rows_txt+=$(printf '  %-20s %11s %11s %7s %5s %5s %5s  %s' \
      "$tb" "$ck" "$ps" "$fl" "$ex" "$er" "$tg" "${oc:-?}")$'\n'
    hl=""
    if [ "$fl" -gt 0 ] || [ "$er" -gt 0 ]; then hl=' style="background:#fdf6f6"'; fi
    rows_html+='<tr'"$hl"'><td style="'"$td"';font-weight:bold">'"$(html_escape "$tb")"'</td><td style="'"$td"';text-align:right">'"$ck"'</td><td style="'"$td"';text-align:right">'"$ps"'</td><td style="'"$td"';text-align:right">'"$fl"'</td><td style="'"$td"';text-align:right">'"$ex"'</td><td style="'"$td"';text-align:right">'"$er"'</td><td style="'"$td"';text-align:right">'"$tg"'</td><td style="'"$td"';white-space:nowrap">'"$(html_escape "${oc:-?}")"'</td></tr>'
  done <<< "$summaries"

  # 異常明細: 直接把差異紀錄列進信裡 (最多 10 筆)，收件人不用登主機就知道是什麼錯
  # 來源 = 輸出資料夾的差異 JSONL (一表一檔，檔名即表名)。差異紀錄本身不帶表名，
  # 故不用 -h: 保留 grep 的「檔名:」前綴，把表名一起印進信裡，多表時才分得出來
  local exc_top="" exc_detail="" exc_raw
  if [ "$t_ex" -gt 0 ] || [ "$t_fl" -gt 0 ]; then
    exc_raw=$(cd "$dir" 2>/dev/null && grep -sHE '"severity":"(EXCEPTION|DIFF)"' -- * 2>/dev/null)
    local eline etb ejson epk esk epath ecls esev ereq esv eav edesc
    while IFS= read -r eline; do
      [ -z "$eline" ] && continue
      etb="${eline%%:*}"; ejson="${eline#*:}"
      epk=$(fc_field_str "$ejson" pk);   esk=$(fc_field_str "$ejson" sk)
      epath=$(fc_field_str "$ejson" path); ecls=$(fc_field_str "$ejson" classification)
      esev=$(fc_field_str "$ejson" severity); ereq=$(fc_field_str "$ejson" required_type)
      esv=$(fc_field_str "$ejson" source_value); eav=$(fc_field_str "$ejson" actual_value)
      esv=${esv:0:60}; eav=${eav:0:60}
      # 白話說明: 讓收件人不用懂分類代碼也知道這筆是什麼問題
      if [ "$ecls" = "SOURCE_UNCASTABLE" ]; then
        edesc="型別不相容 — 欄位要求 ${ereq:-?}，來源值 \"${esv}\" 無法轉型"
      elif [ "$esev" = "DIFF" ] || [ -z "$ecls" ]; then
        edesc="值不一致 — 來源=\"${esv}\" 目標=\"${eav}\""
      else
        edesc="${ecls} — 要求 ${ereq:-?}，來源=\"${esv}\" 目標=\"${eav}\""
      fi
      exc_detail+="  $etb  key=[${epk:-?}${esk:+/$esk}]  ${epath:-?}"$'\n'"      → $edesc"$'\n'
    done <<< "$(printf '%s' "$exc_raw" | head -10)"
    # 欄位分布: 異常超過 10 筆時，補一個「錯集中在哪張表哪個欄位」的統計
    if [ $((t_ex + t_fl)) -gt 10 ]; then
      exc_top=$(printf '%s' "$exc_raw" \
        | sed -n 's/^\([^:]*\):.*"path":"\([^"]*\)".*/\1  \2/p' | sort | uniq -c | sort -rn | head -5 \
        | awk '{c=$1; $1=""; printf "  %6s 筆 %s\n", c, $0}')
    fi
  fi

  local icon color head
  case "$outcome" in
    PASS)                 icon="🟢"; color="#188038"; head="FullCheck 完成 — PASS" ;;
    PASS_WITH_EXCEPTIONS) icon="🟠"; color="#f9ab00"; head="FullCheck 完成 — PASS_WITH_EXCEPTIONS (${t_ex} 筆 exception)" ;;
    *)                    icon="🔴"; color="#d93025"; head="FullCheck 完成 — $outcome (failed=$t_fl)" ;;
  esac
  host=$(hostname 2>/dev/null || echo "?")
  subj="$ENV_NAME"; [ -n "${HOST_ROLE:-}" ] && subj="$ENV_NAME·$HOST_ROLE"

  local body
  body="nimo-full-check 全量複核已結束，結果如下:

結果   : $outcome
開始   : ${ms:-?} (UTC)
結束   : ${me:-?} (UTC)
耗時   : $dur
輸出   : $dir

各 Table 統計 (共 $n_table 個):
$(printf '  %-20s %11s %11s %7s %5s %5s %5s  %s' table checked passed failed exc err tgt outcome)
$rows_txt  合計: checked=$t_ck passed=$t_ps failed=$t_fl exceptions=$t_ex exec_err=$t_er target_only=$t_tg

欄位說明:
  checked=檢核筆數  passed=通過筆數
  failed=不符筆數 (來源與目標不一致，須補搬後重新驗證)
  exc=來源型別例外 (來源資料原生型別問題，非搬遷錯誤；逐筆確認後列例外清單結案)
  err=執行錯誤 (讀取/連線等程式面錯誤)  tgt=目標端多出筆數 (來源不存在)
"
  [ -n "$exc_detail" ] && body+="
異常明細 (最多列 10 筆，本次共 $((t_ex + t_fl)) 筆；完整清單見輸出資料夾各 table 檔):
$exc_detail"
  [ -n "$exc_top" ] && body+="
異常欄位分布 Top 5 (依筆數):
$exc_top
"
  if [ -n "$exc_detail" ]; then
    body+="
【快速指令】(登入主機後可直接複製執行；輸出每行開頭即表名)
  看全部異常明細:  cd $dir && grep -HE '\"severity\":\"(EXCEPTION|DIFF)\"' -- *
  只看某個欄位  :  cd $dir && grep -HE '\"severity\":\"(EXCEPTION|DIFF)\"' -- * | grep <欄位名>
  看各表統計    :  cd $dir && grep -H '\"type\":\"summary\"' -- *
"
  fi
  body+="
---
環境: $subj  主機: $host
時間: $(date '+%F %T %Z')
(本信由 nimoshake-alert.sh 偵測到 FullCheck 結束自動發送)"

  local html
  html='<div style="font-family:-apple-system,'"'Microsoft JhengHei','PingFang TC'"',Arial,sans-serif;font-size:14px;color:#202124;max-width:900px">'
  html+='<div style="border-left:4px solid '"$color"';padding:10px 14px;background:#f8f9fa;margin-bottom:14px;border-radius:0 6px 6px 0"><b style="color:'"$color"'">'"$(html_escape "$icon $head")"'</b><br><span style="color:#5f6368">耗時: '"$(html_escape "$dur")"'</span></div>'
  html+='<table cellspacing="0" cellpadding="0" style="border-collapse:collapse;font-size:13px;margin-bottom:14px">'
  html+='<tr><td style="padding:4px 12px 4px 0;color:#5f6368;white-space:nowrap">開始</td><td>'"$(html_escape "${ms:-?}")"' (UTC)</td></tr>'
  html+='<tr><td style="padding:4px 12px 4px 0;color:#5f6368">結束</td><td>'"$(html_escape "${me:-?}")"' (UTC)</td></tr>'
  html+='<tr><td style="padding:4px 12px 4px 0;color:#5f6368">輸出</td><td><code style="word-break:break-all">'"$(html_escape "$dir")"'</code></td></tr></table>'
  if [ "$n_table" -gt 0 ]; then
    html+='<div style="font-weight:bold;margin-bottom:6px">各 Table 統計（共 '"$n_table"' 個）</div>'
    html+='<table cellspacing="0" cellpadding="0" style="border-collapse:collapse;width:100%;font-size:13px"><tr style="background:#f1f3f4">'
    local h
    for h in table checked passed failed exceptions exec_err target_only outcome; do
      html+='<th style="'"$td"';text-align:left;white-space:nowrap">'"$h"'</th>'
    done
    html+='</tr>'"$rows_html"'<tr style="background:#f8f9fa;font-weight:bold"><td style="'"$td"'">合計</td><td style="'"$td"';text-align:right">'"$t_ck"'</td><td style="'"$td"';text-align:right">'"$t_ps"'</td><td style="'"$td"';text-align:right">'"$t_fl"'</td><td style="'"$td"';text-align:right">'"$t_ex"'</td><td style="'"$td"';text-align:right">'"$t_er"'</td><td style="'"$td"';text-align:right">'"$t_tg"'</td><td style="'"$td"'">'"$(html_escape "$outcome")"'</td></tr></table>'
    html+='<div style="color:#5f6368;font-size:12px;margin-top:6px;line-height:1.7"><b>欄位說明</b>：checked＝檢核筆數／passed＝通過筆數／<b style="color:#d93025">failed＝不符筆數</b>（來源與目標不一致，須補搬後重新驗證）／<b style="color:#e37400">exceptions＝來源型別例外</b>（來源資料原生型別問題，非搬遷錯誤；逐筆確認後列例外清單結案）／exec_err＝執行錯誤（程式面錯誤）／target_only＝目標端多出筆數</div>'
  fi
  if [ -n "$exc_detail" ]; then
    html+='<div style="font-weight:bold;margin:14px 0 6px">異常明細（最多列 10 筆，本次共 '"$((t_ex + t_fl))"' 筆）</div><pre style="background:#f8f9fa;border:1px solid #e0e0e0;padding:10px;font-size:12px;overflow-x:auto;margin:0;line-height:1.8">'"$(html_escape "$exc_detail")"'</pre><div style="color:#5f6368;font-size:12px;margin-top:4px">格式：[主鍵] 欄位路徑: 要求型別，來源值（分類）。完整清單見輸出資料夾各 table 檔的單行 JSON。</div>'
  fi
  if [ -n "$exc_top" ]; then
    html+='<div style="font-weight:bold;margin:14px 0 6px">異常欄位分布 Top 5（依筆數）</div><pre style="background:#f8f9fa;border:1px solid #e0e0e0;padding:10px;font-size:12px;overflow-x:auto;margin:0">'"$(html_escape "$exc_top")"'</pre>'
  fi
  if [ -n "$exc_detail" ]; then
    local cmd_all cmd_one cmd_sum
    cmd_all="cd $dir && grep -HE '\"severity\":\"(EXCEPTION|DIFF)\"' -- *"
    cmd_one="cd $dir && grep -HE '\"severity\":\"(EXCEPTION|DIFF)\"' -- * | grep <欄位名>"
    cmd_sum="cd $dir && grep -H '\"type\":\"summary\"' -- *"
    html+='<div style="font-weight:bold;margin:14px 0 6px">快速指令（登入主機後可直接複製執行）</div><table cellspacing="0" cellpadding="0" style="border-collapse:collapse;font-size:12px"><tr><td style="padding:3px 12px 3px 0;color:#5f6368;white-space:nowrap">看全部異常明細</td><td><code style="word-break:break-all">'"$(html_escape "$cmd_all")"'</code></td></tr><tr><td style="padding:3px 12px 3px 0;color:#5f6368">只看某個欄位</td><td><code style="word-break:break-all">'"$(html_escape "$cmd_one")"'</code></td></tr><tr><td style="padding:3px 12px 3px 0;color:#5f6368">看各表統計</td><td><code style="word-break:break-all">'"$(html_escape "$cmd_sum")"'</code></td></tr></table>'
  fi
  html+='<div style="color:#80868b;font-size:12px;border-top:1px solid #e0e0e0;margin-top:18px;padding-top:10px;line-height:1.7">環境: <b>'"$(html_escape "$subj")"'</b>　主機: '"$(html_escape "$host")"'　時間: '"$(date '+%F %T %Z')"'<br>（本信由 nimoshake-alert.sh 偵測到 FullCheck 結束自動發送）</div></div>'

  FC_IDS+=("$fid")
  FC_SUBJECTS+=("【StarCo $subj】$icon $head")
  FC_BODIES+=("$body")
  FC_HTMLS+=("$html")
}

# FullCheck 異常結束告警: 正常跑完「一定」會寫 run-manifest.json，
# 所以「程序消失 + 沒有新結果檔」= 中途被終止 (OOM/kill/斷線/Ctrl+C)，失敗也要通知。
# 判斷順序刻意「先查程序、再掃 manifest」: 程序剛結束時本輪 manifest 掃描
# 會撿到結果 → 走完成通知，不會被誤判成異常結束。
FC_RUN_FILE="$STATE_DIR/.fullcheck_running"
FC_FAIL_SUBJECT=""; FC_FAIL_BODY=""; FC_FAIL_HTML=""

fc_build_fail_mail() { # $1=首次偵測執行中的時間戳 → 填入 FC_FAIL_*
  local fs="$1" host subj dur
  host=$(hostname 2>/dev/null || echo "?")
  subj="$ENV_NAME"; [ -n "${HOST_ROLE:-}" ] && subj="$ENV_NAME·$HOST_ROLE"
  local d=$((NOW - fs))
  if [ "$d" -ge 3600 ]; then dur="$((d/3600))h$(((d%3600)/60))m"; else dur="$((d/60))m"; fi
  FC_FAIL_SUBJECT="【StarCo $subj】🔴 FullCheck 異常結束 (未產出結果)"
  FC_FAIL_BODY="偵測到 nimo-full-check 程序已消失，但輸出資料夾沒有出現新的
run-manifest.json (正常跑完一定會寫入結果檔) → 本次複核未完成。

首次偵測執行中: $(date -d "@$fs" '+%F %T %Z' 2>/dev/null || echo "$fs")
已執行約      : $dur
監看目錄      : $FULLCHECK_DIR

可能原因: 手動中止 (Ctrl+C / kill)、記憶體不足被 OOM killer 終止、
來源/目標連線中斷、磁碟空間不足。
👉 處理:
  1. 查執行終端機 / nohup 輸出的最後訊息
  2. dmesg | grep -iE 'kill|oom'  看是否被 OOM 終止
  3. df -h  確認磁碟空間
  4. 排除原因後直接重下原本的 fullcheck 指令即可 (每次執行都是完整重跑)

---
環境: $subj  主機: $host
時間: $(date '+%F %T %Z')
(本信由 nimoshake-alert.sh 偵測到 FullCheck 異常結束自動發送)"
  FC_FAIL_HTML='<div style="font-family:-apple-system,'"'Microsoft JhengHei','PingFang TC'"',Arial,sans-serif;font-size:14px;color:#202124;max-width:860px">'
  FC_FAIL_HTML+=$(html_card "#d93025" "[high] FullCheck 異常結束（未產出結果，已執行約 $dur）" \
    "nimo-full-check 程序已消失，但輸出資料夾沒有新的 run-manifest.json（正常跑完一定會寫）→ 本次複核未完成。可能原因: 手動中止 / OOM / 連線中斷 / 磁碟滿。" \
    "1) 查執行終端機或 nohup 輸出的最後訊息  2) dmesg | grep -iE 'kill|oom' 看是否 OOM  3) df -h 確認磁碟空間  4) 排除後直接重下原本的 fullcheck 指令 (每次執行都是完整重跑)")
  FC_FAIL_HTML+='<div style="color:#80868b;font-size:12px;border-top:1px solid #e0e0e0;margin-top:18px;padding-top:10px;line-height:1.7">監看目錄: <code style="word-break:break-all">'"$(html_escape "$FULLCHECK_DIR")"'</code><br>環境: <b>'"$(html_escape "$subj")"'</b>　主機: '"$(html_escape "$host")"'　時間: '"$(date '+%F %T %Z')"'<br>（本信由 nimoshake-alert.sh 偵測到 FullCheck 異常結束自動發送）</div></div>'
}

# ---- 原生版 (711) 支援: FULLCHECK_MODE=native ---------------------------------
# 原生 git 版不寫 run-manifest.json，判別改為: 程序結束 + 讀 -d 輸出資料夾的
# diff 檔 (原生有差異才留檔、一行一筆 src[..] != dst[..]，空檔會被自己刪掉)。
# 跑完/掛掉的區分: 開跑時記下 log 檔中 "full-check completes" 出現次數，
# 程序消失後次數有 +1 = 正常跑完；沒設 FULLCHECK_NATIVE_LOG 則一律視為跑完。
FC_NATIVE_SUBJECT=""; FC_NATIVE_BODY=""; FC_NATIVE_HTML=""

fc_native_completes() { # 印出 log 檔中結束標記出現次數 (檔案不存在=0)
  local c=""
  [ -n "$FULLCHECK_NATIVE_LOG" ] && [ -f "$FULLCHECK_NATIVE_LOG" ] && \
    c=$(grep -c 'full-check completes' "$FULLCHECK_NATIVE_LOG" 2>/dev/null)
  printf '%s' "${c:-0}"
}

fc_run_write() { # 建立/重置執行追蹤檔 (native 模式多記結束標記基準數)
  {
    printf 'first_seen\t%s\n' "$NOW"
    [ "$FULLCHECK_MODE" = "native" ] && printf 'completes_base\t%s\n' "$(fc_native_completes)"
  } > "$FC_RUN_FILE" 2>/dev/null
}

fc_build_native_mail() { # 原生模式結果信 (讀 -d 輸出資料夾的 diff 檔)
  local out="${FULLCHECK_DIR%%,*}" host subj
  host=$(hostname 2>/dev/null || echo "?")
  subj="$ENV_NAME"; [ -n "${HOST_ROLE:-}" ] && subj="$ENV_NAME·$HOST_ROLE"
  # 各表差異筆數 (一表一檔，行數=筆數)；原生無差異不留檔
  local total=0 n_table=0 counts="" samples="" f n
  for f in "$out"/*; do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" 2>/dev/null | tr -d ' '); : "${n:=0}"
    [ "$n" -eq 0 ] && continue
    n_table=$((n_table+1)); total=$((total+n))
    counts+="  $(basename "$f")  ${n} 筆"$'\n'
    [ -z "$samples" ] && samples=$(head -5 "$f" 2>/dev/null | cut -c1-200 | sed 's/^/  /')
  done
  local icon color head
  if [ "$total" -eq 0 ]; then
    icon="🟢"; color="#188038"; head="FullCheck 完成 — 未發現差異"
  else
    icon="🔴"; color="#d93025"; head="FullCheck 完成 — 發現 $total 筆差異 ($n_table 張表)"
  fi
  FC_NATIVE_SUBJECT="【StarCo $subj】$icon $head"
  FC_NATIVE_BODY="nimo-full-check (原生版) 已結束。

結果   : $head
輸出   : $out
"
  if [ "$total" -gt 0 ]; then
    FC_NATIVE_BODY+="
各表差異筆數:
$counts
差異內容節錄 (前 5 行，格式 src[來源] != dst[目標]):
$samples

【快速指令】看完整差異: cd $out && cat *
"
  fi
  FC_NATIVE_BODY+="
(原生版不輸出 checked/passed 統計，僅能回報差異筆數與內容)"
  [ -z "$FULLCHECK_NATIVE_LOG" ] && FC_NATIVE_BODY+="
(未設定 FULLCHECK_NATIVE_LOG，無法區分正常結束或中途被終止；若懷疑執行中斷，重跑一次即可)"
  FC_NATIVE_BODY+="
---
環境: $subj  主機: $host
時間: $(date '+%F %T %Z')
(本信由 nimoshake-alert.sh 偵測到 FullCheck 結束自動發送)"
  FC_NATIVE_HTML='<div style="font-family:-apple-system,'"'Microsoft JhengHei','PingFang TC'"',Arial,sans-serif;font-size:14px;color:#202124;max-width:860px"><div style="border-left:4px solid '"$color"';padding:10px 14px;background:#f8f9fa;margin-bottom:14px;border-radius:0 6px 6px 0"><b style="color:'"$color"'">'"$(html_escape "$icon $head")"'</b><br><span style="color:#5f6368">輸出: <code>'"$(html_escape "$out")"'</code></span></div>'
  if [ "$total" -gt 0 ]; then
    FC_NATIVE_HTML+='<div style="font-weight:bold;margin-bottom:6px">各表差異筆數</div><pre style="background:#f8f9fa;border:1px solid #e0e0e0;padding:10px;font-size:12px;margin:0 0 12px">'"$(html_escape "$counts")"'</pre><div style="font-weight:bold;margin-bottom:6px">差異內容節錄（前 5 行）</div><pre style="background:#f8f9fa;border:1px solid #e0e0e0;padding:10px;font-size:12px;overflow-x:auto;margin:0">'"$(html_escape "$samples")"'</pre>'
  fi
  FC_NATIVE_HTML+='<div style="color:#80868b;font-size:12px;border-top:1px solid #e0e0e0;margin-top:16px;padding-top:10px;line-height:1.7">原生版不輸出 checked/passed 統計，僅回報差異筆數與內容。<br>環境: <b>'"$(html_escape "$subj")"'</b>　主機: '"$(html_escape "$host")"'　時間: '"$(date '+%F %T %Z')"'<br>（本信由 nimoshake-alert.sh 偵測到 FullCheck 結束自動發送）</div></div>'
}

if [ -n "${FULLCHECK_DIR:-}" ]; then
  # 1) 程序是否在跑 (要先於 manifest 掃描，見上方註解)
  FC_PROC_ALIVE=0
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$FULLCHECK_PROC_PATTERN" >/dev/null 2>&1 && FC_PROC_ALIVE=1
  fi
  FC_BASELINE=0
  if [ "$FULLCHECK_MODE" = "starco" ]; then
  [ -f "$FC_SEEN_FILE" ] || FC_BASELINE=1
  for fc_root in $(printf '%s' "$FULLCHECK_DIR" | tr ',;' ' '); do
    [ -z "$fc_root" ] && continue
    if [ ! -d "$fc_root" ]; then
      log_line "WARN: [$ENV_NAME] FULLCHECK_DIR 不存在: $fc_root (請確認 conf 路徑)"
      continue
    fi
    # 掃 FULLCHECK_DIR 本身與其下一層 (-d 輸出資料夾通常在執行目錄下一層)
    for fc_mf in "$fc_root"/run-manifest.json "$fc_root"/*/run-manifest.json; do
      [ -f "$fc_mf" ] || continue
      fc_fin=$(fc_manifest_str "$fc_mf" finished_at)
      if [ -n "$fc_fin" ]; then
        fc_fid="$fc_fin|$(fc_manifest_str "$fc_mf" outcome)"
      else
        fc_fid=$(md5sum "$fc_mf" 2>/dev/null | awk '{print $1}'); : "${fc_fid:=$fc_mf}"
      fi
      grep -qxF "$fc_fid" "$FC_SEEN_FILE" 2>/dev/null && continue
      if [ "$FC_BASELINE" -eq 1 ]; then
        [ "$STATUS_ONLY" -eq 0 ] && printf '%s\n' "$fc_fid" >> "$FC_SEEN_FILE" 2>/dev/null
        continue
      fi
      fc_build_mail "$fc_mf" "$fc_fid"
    done
  done
  if [ "$FC_BASELINE" -eq 1 ] && [ "$STATUS_ONLY" -eq 0 ]; then
    touch "$FC_SEEN_FILE" 2>/dev/null || true
    log_line "INFO: [$ENV_NAME] FullCheck 通知首次啟用，既有結果記為基準，不補寄歷史"
  fi
  fi  # FULLCHECK_MODE=starco (native 模式不掃 manifest，靠下方程序狀態機)

  # 2) 執行中/異常結束狀態機 (狀態檔 .fullcheck_running: first_seen / gone_since)
  if [ "$FC_PROC_ALIVE" -eq 1 ]; then
    if [ ! -f "$FC_RUN_FILE" ]; then
      if [ "$STATUS_ONLY" -eq 0 ]; then
        fc_run_write
        log_line "INFO: [$ENV_NAME] 偵測到 nimo-full-check 執行中，開始追蹤 (mode=$FULLCHECK_MODE)"
      fi
    elif grep -q '^gone_since' "$FC_RUN_FILE" 2>/dev/null && [ "$STATUS_ONLY" -eq 0 ]; then
      # 程序又出現 (新的一輪複核開跑) → 重置追蹤
      fc_run_write
    fi
  elif [ -f "$FC_RUN_FILE" ]; then
    if [ "$FULLCHECK_MODE" = "starco" ] && [ "${#FC_IDS[@]}" -gt 0 ]; then
      # 程序結束且本輪撿到新結果 → 正常結束，交給完成通知
      [ "$STATUS_ONLY" -eq 0 ] && rm -f "$FC_RUN_FILE" 2>/dev/null
    else
      fc_gone=$(awk -F '\t' '$1=="gone_since"{print $2}' "$FC_RUN_FILE" 2>/dev/null)
      if [ -z "$fc_gone" ]; then
        # 寬限一輪 (約 1 分鐘): 避免「程序剛結束、結果檔還在寫」的競態誤報
        [ "$STATUS_ONLY" -eq 0 ] && printf 'gone_since\t%s\n' "$NOW" >> "$FC_RUN_FILE" 2>/dev/null
      elif [ "$FULLCHECK_MODE" = "native" ]; then
        # 原生: log 結束標記次數比開跑時多 = 正常跑完；否則 = 中途被終止。
        # 沒設 FULLCHECK_NATIVE_LOG 時無從區分，一律視為跑完 (信中已註明)
        fc_base=$(awk -F '\t' '$1=="completes_base"{print $2}' "$FC_RUN_FILE" 2>/dev/null); : "${fc_base:=0}"
        if [ -z "$FULLCHECK_NATIVE_LOG" ] || [ "$(fc_native_completes)" -gt "$fc_base" ]; then
          fc_build_native_mail
        else
          fc_first=$(awk -F '\t' '$1=="first_seen"{print $2}' "$FC_RUN_FILE" 2>/dev/null)
          fc_build_fail_mail "${fc_first:-$NOW}"
        fi
      else
        fc_first=$(awk -F '\t' '$1=="first_seen"{print $2}' "$FC_RUN_FILE" 2>/dev/null)
        fc_build_fail_mail "${fc_first:-$NOW}"
      fi
    fi
  fi
fi

# ---- 更新 offset ------------------------------------------------------------
# FREEZE (log 遺失) 期間不動 offset: 同一檔案搬回來可從原 offset 續讀，
# 不會把整份歷史 log 重掃成「新增事件」；真正輪替的新檔仍由變小檢查歸零
if [ "$STATUS_ONLY" -eq 0 ] && [ "$FREEZE" -eq 0 ]; then
  echo "$LOG_SIZE" > "$OFFSET_FILE" 2>/dev/null || true
fi

# =============================================================================
# --status: 只印，不寄，不動狀態
# =============================================================================
if [ "$STATUS_ONLY" -eq 1 ]; then
  echo "===== [$ENV_NAME] 目前狀態 ($(date '+%F %T')) ====="
  echo "LOG: $LOG_FILE  size=$LOG_SIZE  (上次 offset=$PREV_OFFSET)"
  echo "DRY_RUN=$DRY_RUN  ALERT_MIN_SEVERITY=$ALERT_MIN_SEVERITY  REALERT=${REALERT_INTERVAL}s"
  echo "--- 目前條件 ---"; printf '%s' "$CONDITIONS"
  echo "--- 新增 ---"; printf '%s' "${NEW_LIST:-  (無)
}"
  echo "--- 到期提醒 ---"; printf '%s' "${FIRING_LIST:-  (無)
}"
  echo "--- 已解除 ---"; printf '%s' "${RESOLVED_LIST:-  (無)
}"
  if [ -n "${FULLCHECK_DIR:-}" ]; then
    echo "--- FullCheck ---"
    if [ "${FC_PROC_ALIVE:-0}" -eq 1 ]; then
      echo "  執行中 (程序存在，結束後 1 分鐘內通知結果)"
    elif [ -n "$FC_FAIL_SUBJECT" ]; then
      echo "  疑似異常結束 (程序消失且無新結果檔)，待寄: $FC_FAIL_SUBJECT"
    fi
    if [ "${#FC_SUBJECTS[@]}" -gt 0 ]; then
      printf '  待通知: %s\n' "${FC_SUBJECTS[@]}"
    elif [ "${FC_PROC_ALIVE:-0}" -eq 0 ] && [ -z "$FC_FAIL_SUBJECT" ]; then
      echo "  (無待通知結果)"
    fi
  fi
  exit 0
fi

# =============================================================================
# 寄信 (批次，含冷卻與上限)
# =============================================================================
MAILS_SENT=0
LAST_MAIL=0
[ -f "$LASTMAIL_FILE" ] && LAST_MAIL=$(cat "$LASTMAIL_FILE" 2>/dev/null | tr -d ' ')
[ -z "$LAST_MAIL" ] && LAST_MAIL=0

can_send() {
  [ "$MAILS_SENT" -ge "$MAX_MAILS_PER_RUN" ] && { log_line "INFO: 達單次寄信上限 $MAX_MAILS_PER_RUN，略過"; return 1; }
  if [ "$DRY_RUN" != "1" ] && [ $((NOW - LAST_MAIL)) -lt "$GLOBAL_COOLDOWN" ]; then
    log_line "INFO: 冷卻中 (距上封 $((NOW - LAST_MAIL))s < ${GLOBAL_COOLDOWN}s)，本封延到下次"
    return 1
  fi
  return 0
}
after_send() {
  MAILS_SENT=$((MAILS_SENT + 1))
  LAST_MAIL=$(date +%s)
  echo "$LAST_MAIL" > "$LASTMAIL_FILE" 2>/dev/null || true
}
mark_sent() { # 寄成功後把條件的 last_sent 蓋成 NOW，避免下一輪重寄
  local id pf pt ps pc ptl
  for id in "$@"; do
    [ -f "$COND_DIR/$id" ] || continue
    pf=$(state_get "$id" first_seen); pt=$(state_get "$id" type); ps=$(state_get "$id" severity); pc=$(state_get "$id" count); ptl=$(state_get "$id" title)
    state_write "$id" "${pt:-STATE}" "${ps:-medium}" "${pf:-$NOW}" "$NOW" "${pc:-1}" "${ptl:-$id}"
  done
}

# ---- 系統狀態判讀: 附進告警信，逐面向標示 正常/異常 --------------------------
# 資料來源 = monitor --summary (全部由真實 log 計算，不做假設)
# 面向: 程式狀態 / 同步階段 / Table 進度 / 來源讀取 / 目標寫入 / 瓶頸 / 系統資源
# 只在真的有信要寄時才產生 (全檔掃描較耗時，平時每分鐘的檢查不做)
SNAPSHOT=""; SNAPSHOT_HTML=""
if [ -n "$NEW_LIST$FIRING_LIST" ] && [ -r "$LOG_FILE" ]; then
  SUMMARY=$(NS_STALL_SECONDS="$STALL_SECONDS" NS_HANG_SECONDS="${HANG_SECONDS:-60}" \
            NS_SLOW_WRITE_MS="$SLOW_WRITE_MS" NS_SLOW_SCAN_MS="$SLOW_SCAN_MS" \
            NS_SCAN_TAIL_LINES="${SCAN_TAIL_LINES:-2000}" \
            NS_EXPECT_RUNNING="${EXPECT_RUNNING:-0}" NS_PROC_PATTERN="$PROC_PATTERN" \
            NS_DISK_ALERT_PCT="${DISK_ALERT_PCT:-85}" NS_MEM_ALERT_PCT="${MEM_ALERT_PCT:-90}" \
            NS_TABLE_TOTALS="${TABLE_TOTALS:-}" \
            bash "$MONITOR" --summary "$LOG_FILE" 2>/dev/null)
  if [ -n "$SUMMARY" ]; then
    SNAPSHOT=$'\n【系統狀態判讀】\n'
    SNAPSHOT_HTML='<div style="margin-top:16px"><div style="font-weight:bold;margin-bottom:6px">系統狀態判讀</div><table cellspacing="0" cellpadding="0" style="border-collapse:collapse;width:100%;font-size:13px">'
    while IFS='|' read -r st dim desc; do
      [ -z "$dim" ] && continue
      case "$st" in
        ok)   SNAPSHOT+="  ✓ 正常  $dim: $desc"$'\n'
              SNAPSHOT_HTML+='<tr><td style="padding:6px 10px;border:1px solid #e0e0e0;white-space:nowrap;color:#188038;font-weight:bold">✓ 正常</td><td style="padding:6px 10px;border:1px solid #e0e0e0;white-space:nowrap;font-weight:bold">'"$(html_escape "$dim")"'</td><td style="padding:6px 10px;border:1px solid #e0e0e0;color:#3c4043">'"$(html_escape "$desc")"'</td></tr>' ;;
        bad)  SNAPSHOT+="  ✗ 異常  $dim: $desc"$'\n'
              SNAPSHOT_HTML+='<tr style="background:#fdf6f6"><td style="padding:6px 10px;border:1px solid #e0e0e0;white-space:nowrap;color:#d93025;font-weight:bold">✗ 異常</td><td style="padding:6px 10px;border:1px solid #e0e0e0;white-space:nowrap;font-weight:bold">'"$(html_escape "$dim")"'</td><td style="padding:6px 10px;border:1px solid #e0e0e0;color:#3c4043">'"$(html_escape "$desc")"'</td></tr>' ;;
        *)    SNAPSHOT+="  ・參考  $dim: $desc"$'\n'
              SNAPSHOT_HTML+='<tr><td style="padding:6px 10px;border:1px solid #e0e0e0;white-space:nowrap;color:#5f6368">・參考</td><td style="padding:6px 10px;border:1px solid #e0e0e0;white-space:nowrap;font-weight:bold">'"$(html_escape "$dim")"'</td><td style="padding:6px 10px;border:1px solid #e0e0e0;color:#3c4043">'"$(html_escape "$desc")"'</td></tr>' ;;
      esac
    done <<< "$SUMMARY"
    SNAPSHOT_HTML+='</table></div>'
  fi
fi

HOST=$(hostname 2>/dev/null || echo "?")
# 提醒間隔的人類可讀描述: >=1h 顯示小時、不足 1h 顯示分鐘、0 = 不重複提醒
if [ "${REALERT_INTERVAL:-0}" -eq 0 ]; then
  REALERT_DESC="不重複提醒"
elif [ "$REALERT_INTERVAL" -ge 3600 ]; then
  REALERT_DESC="每 $((REALERT_INTERVAL/3600)) 小時提醒一次直到解除"
else
  REALERT_DESC="每 $((REALERT_INTERVAL/60)) 分鐘提醒一次直到解除"
fi
# 主旨環境標籤: 附上 測試機/正式機 (conf 的 HOST_ROLE)
SUBJ="$ENV_NAME"; [ -n "${HOST_ROLE:-}" ] && SUBJ="$ENV_NAME·$HOST_ROLE"
# 快速指令用實際完整路徑，收件人可直接複製執行
CONF_ABS="$(cd "$(dirname "$CONF")" 2>/dev/null && pwd)/$(basename "$CONF")"
CMD_STATUS="bash $SCRIPT_DIR/nimoshake-alert.sh --status $CONF_ABS"
CMD_REPORT="bash $SCRIPT_DIR/nimoshake-monitor.sh $LOG_FILE"
FOOT=$'\n---\n環境: '"$SUBJ"$'  主機: '"$HOST"$'\nLog: '"$LOG_FILE"$'\n時間: '"$(date '+%F %T %Z')"$'\n\n【快速指令】(登入主機後可直接複製執行)\n  查目前所有告警狀態:  '"$CMD_STATUS"$'\n  看完整監控報表:      '"$CMD_REPORT"$'\n\n【信件說明】🔴新增=剛發生 / 🟠持續='"$REALERT_DESC"$' / 🟢已解除=已恢復無需處理\n同一問題只通知一次不重複轟炸；事件型異常 (ERROR/逾時等) 只在新增時通知。\n(本信由 nimoshake-alert.sh 自動發送)'
FOOT_HTML='<div style="color:#80868b;font-size:12px;border-top:1px solid #e0e0e0;margin-top:18px;padding-top:10px;line-height:1.7">環境: <b>'"$(html_escape "$SUBJ")"'</b>　主機: '"$(html_escape "$HOST")"'　時間: '"$(date '+%F %T %Z')"'<br>Log: <code style="word-break:break-all">'"$(html_escape "$LOG_FILE")"'</code><br><br><b>快速指令</b>（登入主機後可直接複製執行）<br>查目前所有告警狀態: <code style="word-break:break-all">'"$(html_escape "$CMD_STATUS")"'</code><br>看完整監控報表: <code style="word-break:break-all">'"$(html_escape "$CMD_REPORT")"'</code><br><br>🔴新增=剛發生／🟠持續='"$REALERT_DESC"'／🟢已解除=已恢復無需處理<br>同一問題只通知一次不重複轟炸；事件型異常（ERROR/逾時等）只在新增時通知。（本信由 nimoshake-alert.sh 自動發送）</div>'

html_mail() { # $1=開頭說明句 $2=卡片HTML $3=是否附快照(1/0)
  local snap=""; [ "${3:-0}" = "1" ] && snap="$SNAPSHOT_HTML"
  printf '<div style="font-family:-apple-system,%s,Arial,sans-serif;font-size:14px;color:#202124;max-width:860px"><div style="margin:0 0 12px;color:#3c4043">%s</div>%s%s%s</div>' \
    "'Microsoft JhengHei','PingFang TC'" "$(html_escape "$1")" "$2" "$snap" "$FOOT_HTML"
}

# 1) 新增告警
if [ -n "$NEW_LIST" ] && can_send; then
  n=$(printf '%s' "$NEW_LIST" | grep -c '^■')
  if sendgrid_send "【StarCo $SUBJ】🔴 新增 $n 項告警" "偵測到新的異常狀況:"$'\n\n'"$NEW_LIST$SNAPSHOT$FOOT" \
       "$(html_mail "偵測到新的異常狀況，每項附處理方式：" "$NEW_HTML" 1)"; then
    after_send
    mark_sent $NEW_IDS
  fi
fi

# 2) 已解除
if [ -n "$RESOLVED_LIST" ] && can_send; then
  n=$(printf '%s' "$RESOLVED_LIST" | grep -c '^■')
  if sendgrid_send "【StarCo $SUBJ】🟢 已解除 $n 項" "以下狀況已恢復正常:"$'\n\n'"$RESOLVED_LIST$FOOT" \
       "$(html_mail "以下狀況已恢復正常：" "$RESOLVED_HTML" 0)"; then
    after_send
    # 🟢 寄成功才清除狀態檔 (寄失敗/被冷卻擋下時保留，下一輪重新判定並重試)
    for id in $RESOLVED_IDS; do rm -f "$COND_DIR/$id" 2>/dev/null || true; done
  fi
fi

# 3) 持續未解除 (到期提醒)
if [ -n "$FIRING_LIST" ] && can_send; then
  n=$(printf '%s' "$FIRING_LIST" | grep -c '^■')
  if sendgrid_send "【StarCo $SUBJ】🟠 持續未解除 $n 項 (提醒)" "以下狀況仍未解除:"$'\n\n'"$FIRING_LIST$SNAPSHOT$FOOT" \
       "$(html_mail "以下狀況仍未解除，請儘速處理：" "$FIRING_HTML" 1)"; then
    after_send
    mark_sent $FIRING_DUE_IDS
  fi
fi

# 4) FullCheck 完成通知 (conf 設 FULLCHECK_DIR 才會有)
#    結果信是使用者主動要的完成通知，不受 ALERT_MIN_SEVERITY 過濾；
#    仍走冷卻/單次上限。寄成功才記指紋，失敗/被冷卻擋下 → 下一輪重試。
fc_i=0
while [ "$fc_i" -lt "${#FC_IDS[@]}" ]; do
  if can_send; then
    if sendgrid_send "${FC_SUBJECTS[$fc_i]}" "${FC_BODIES[$fc_i]}" "${FC_HTMLS[$fc_i]}"; then
      after_send
      printf '%s\n' "${FC_IDS[$fc_i]}" >> "$FC_SEEN_FILE" 2>/dev/null || true
    fi
  fi
  fc_i=$((fc_i + 1))
done
# FullCheck 異常結束 (程序消失且無新結果檔): 寄成功才清追蹤檔，失敗下一輪重試
if [ -n "$FC_FAIL_SUBJECT" ] && can_send; then
  if sendgrid_send "$FC_FAIL_SUBJECT" "$FC_FAIL_BODY" "$FC_FAIL_HTML"; then
    after_send
    rm -f "$FC_RUN_FILE" 2>/dev/null || true
  fi
fi
# FullCheck 原生模式結果信 (一次執行一封，去重靠追蹤檔生命週期)
if [ -n "$FC_NATIVE_SUBJECT" ] && can_send; then
  if sendgrid_send "$FC_NATIVE_SUBJECT" "$FC_NATIVE_BODY" "$FC_NATIVE_HTML"; then
    after_send
    rm -f "$FC_RUN_FILE" 2>/dev/null || true
  fi
fi

if [ "$MAILS_SENT" -eq 0 ]; then
  log_line "OK: [$ENV_NAME] 本次無需寄信 (dry_run=$DRY_RUN)"
else
  log_line "DONE: [$ENV_NAME] 本次寄出/處理 $MAILS_SENT 封 (dry_run=$DRY_RUN)"
fi
# 心跳: 只在「本輪完整跑完」才寫。引擎壞掉/排程失效 → 心跳停更 →
# 獨立的 nimoshake-watchdog.sh (cron 每 5 分鐘) 會發「監控引擎停擺」告警
date +%s > "$STATE_DIR/.heartbeat" 2>/dev/null || true
exit 0
