#!/bin/bash
# =============================================================================
# lib/common.sh — StarCo NimoShake 監控/告警共用函式
#   - 設定檔載入 (金鑰/帳號/主機/發信人 全部參數化在 conf，程式不寫死)
#   - SendGrid 寄信 (純 curl API 模式)
#   - 記錄檔工具
# 本檔以 source 方式被 nimoshake-alert.sh 引用。
# =============================================================================

# ---- 設定檔載入與驗證 --------------------------------------------------------
# 用法: load_config /path/to/env.conf
load_config() {
  local cfg="$1"
  if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
    echo "[FATAL] 找不到設定檔: ${cfg:-<未指定>}" >&2
    echo "        請複製 config/*.conf.example 並填入 SENDGRID_API_KEY。" >&2
    return 1
  fi
  # 注意: conf 以 source 方式載入，與腳本同權限等級 — conf 只放 KEY=VALUE 設定，
  # 不要放指令；檔案權限建議 600
  if grep -qE '^\s*[^#[:space:]=]+=' "$cfg" 2>/dev/null; then
    # shellcheck disable=SC1090
    set -a; . "$cfg"; set +a
  fi

  : "${ENV_NAME:?設定檔缺少 ENV_NAME}"
  : "${LOG_FILE:?設定檔缺少 LOG_FILE}"
  : "${MAIL_TO:?設定檔缺少 MAIL_TO}"
  : "${MAIL_FROM:?設定檔缺少 MAIL_FROM}"

  # API Key: 直接寫在 conf (SENDGRID_API_KEY)；也相容 SENDGRID_API_KEY_FILE 指到金鑰檔
  if [ -z "${SENDGRID_API_KEY:-}" ] && [ -n "${SENDGRID_API_KEY_FILE:-}" ] && [ -f "$SENDGRID_API_KEY_FILE" ]; then
    SENDGRID_API_KEY="$(tr -d ' \r\n' < "$SENDGRID_API_KEY_FILE")"
  fi

  # SendGrid 連線參數 (可由 conf 覆寫)
  SENDGRID_API_HOST="${SENDGRID_API_HOST:-api.sendgrid.com}"
  SENDGRID_API_PORT="${SENDGRID_API_PORT:-443}"
  SENDGRID_SMTP_SERVER="${SENDGRID_SMTP_SERVER:-smtp.sendgrid.net}"
  SENDGRID_SMTP_PORT="${SENDGRID_SMTP_PORT:-587}"
  SENDGRID_SMTP_USERNAME="${SENDGRID_SMTP_USERNAME:-apikey}"

  # 預設值
  HOST_ROLE="${HOST_ROLE:-}"                       # 測試機/正式機，會顯示在信件主旨
  DISK_ALERT_PCT="${DISK_ALERT_PCT:-85}"           # 磁碟使用率超過此 % 判為異常
  MEM_ALERT_PCT="${MEM_ALERT_PCT:-90}"             # 記憶體使用率超過此 % 判為異常
  MAIL_FROM_NAME="${MAIL_FROM_NAME:-StarCo Monitor (${ENV_NAME})}"
  REALERT_INTERVAL="${REALERT_INTERVAL:-21600}"   # 仍未解除，每 6h 提醒一次 (0=永不重寄)
  GLOBAL_COOLDOWN="${GLOBAL_COOLDOWN:-60}"         # 任兩封信最小間隔秒數
  MAX_MAILS_PER_RUN="${MAX_MAILS_PER_RUN:-10}"     # 單次執行最多寄幾封 (防爆量)
  NOTIFY_RESOLVED="${NOTIFY_RESOLVED:-1}"          # 狀態解除是否通知
  ALERT_MIN_SEVERITY="${ALERT_MIN_SEVERITY:-medium}" # 低於此嚴重度不寄信 (high>medium>low>info)
  DRY_RUN="${DRY_RUN:-1}"                          # 1=不真的寄，只寫 log (安全預設)
  STATE_DIR="${STATE_DIR:-$(dirname "$cfg")/state}"

  # 監控門檻: 接受 bare 或 NS_ 前綴命名，統一成 bare 供 alert 使用
  STALL_SECONDS="${STALL_SECONDS:-${NS_STALL_SECONDS:-300}}"
  HANG_SECONDS="${HANG_SECONDS:-${NS_HANG_SECONDS:-60}}"
  SCAN_TAIL_LINES="${SCAN_TAIL_LINES:-${NS_SCAN_TAIL_LINES:-2000}}"
  SLOW_WRITE_MS="${SLOW_WRITE_MS:-${NS_SLOW_WRITE_MS:-200}}"
  SLOW_SCAN_MS="${SLOW_SCAN_MS:-${NS_SLOW_SCAN_MS:-500}}"
  EXPECT_RUNNING="${EXPECT_RUNNING:-${NS_EXPECT_RUNNING:-0}}"
  PROC_PATTERN="${PROC_PATTERN:-${NS_PROC_PATTERN:-(^|/)nimo-shake(\.(linux|darwin))?( |$)}}"
  TABLE_TOTALS="${TABLE_TOTALS:-}"   # 選填: 各 table 來源總筆數基準 "Orders:5200000,..."，報表顯示全量進度%

  # FullCheck 結束通知 (選填): 填 nimo-full-check 的執行目錄 (可逗號分隔多個)。
  # 設定後 alert 引擎會偵測「輸出資料夾出現 run-manifest.json」= 該次複核已結束，
  # 自動寄結果信 (outcome/各 table 統計/耗時)。空值 = 功能關閉，不影響既有部署。
  # 另以 FULLCHECK_PROC_PATTERN 追蹤 fullcheck 程序: 程序消失卻沒有新結果檔
  # (中途被 OOM/kill/斷線終止) 時發 🔴 異常結束告警，失敗也不漏通知。
  FULLCHECK_DIR="${FULLCHECK_DIR:-}"
  FULLCHECK_PROC_PATTERN="${FULLCHECK_PROC_PATTERN:-(^|/)nimo-full-check(\.(linux|darwin))?( |$)}"
  # 版本模式: starco=專版 (判別 run-manifest.json)；native=原生 git 版——
  # 原生不寫 manifest，改用「程序結束 + 讀 -d 輸出資料夾的 diff 檔」判別，
  # 此時 FULLCHECK_DIR 請直接填 -d 輸出資料夾本身。
  FULLCHECK_MODE="${FULLCHECK_MODE:-starco}"
  FULLCHECK_NATIVE_LOG="${FULLCHECK_NATIVE_LOG:-}"   # (建議) 原生 fullcheck 啟動時導出的 log 檔，用於區分跑完/中途掛掉
  return 0
}

# ---- 記錄檔 ------------------------------------------------------------------
log_line() {
  local logdir="${STATE_DIR:-/tmp}"
  mkdir -p "$logdir" 2>/dev/null || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$logdir/alert.log" >&2
}

# ---- SendGrid 寄信 (API 模式) -----------------------------------------------
# 用法: sendgrid_send "主旨" "純文字內容" ["HTML內容"]
#   第 3 參數若提供，信件同時帶 text/plain 與 text/html (郵件軟體優先顯示 HTML)
# 回傳: 0 成功 / 非 0 失敗。DRY_RUN=1 時只印不寄。
sendgrid_send() {
  local subject="$1" body="$2" html="${3:-}"

  if [ "${DRY_RUN:-1}" = "1" ]; then
    log_line "DRY_RUN: 略過寄信 -> to=$MAIL_TO subject=[$subject]"
    return 0
  fi
  if [ -z "${SENDGRID_API_KEY:-}" ]; then
    log_line "ERROR: 未設定 SENDGRID_API_KEY，無法寄信 (subject=$subject)"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_line "ERROR: 環境無 curl，無法寄信"
    return 1
  fi

  local esc_sub esc_body esc_from esc_name esc_html content_json payload http
  esc_sub=$(json_escape "$subject")
  esc_body=$(json_escape "$body")
  esc_from=$(json_escape "$MAIL_FROM")
  esc_name=$(json_escape "$MAIL_FROM_NAME")
  content_json="{\"type\":\"text/plain\",\"value\":\"${esc_body}\"}"
  if [ -n "$html" ]; then
    esc_html=$(json_escape "$html")
    content_json="${content_json},{\"type\":\"text/html\",\"value\":\"${esc_html}\"}"
  fi

  # MAIL_TO 支援多收件人: 逗號/分號/空白分隔
  local to_json="" addr
  for addr in $(printf '%s' "$MAIL_TO" | tr ',;' ' '); do
    [ -z "$addr" ] && continue
    to_json+="{\"email\":\"$(json_escape "$addr")\"},"
  done
  to_json="${to_json%,}"
  if [ -z "$to_json" ]; then
    log_line "ERROR: MAIL_TO 為空，無法寄信 (subject=$subject)"
    return 1
  fi

  payload=$(cat <<JSON
{"personalizations":[{"to":[${to_json}]}],
"from":{"email":"${esc_from}","name":"${esc_name}"},
"subject":"${esc_sub}",
"content":[${content_json}]}
JSON
)
  # payload 走暫存檔而非命令列參數: 避免多位元組字元 (中文/emoji) 在部分
  # 平台的 argv 編碼轉換中損毀，導致 SendGrid 回 415 Invalid UTF8
  local tmp_payload="${STATE_DIR:-/tmp}/.sg_payload.$$"
  printf '%s' "$payload" > "$tmp_payload"
  http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -X POST "https://${SENDGRID_API_HOST}:${SENDGRID_API_PORT}/v3/mail/send" \
    -H "Authorization: Bearer ${SENDGRID_API_KEY}" \
    -H 'Content-Type: application/json' \
    --data-binary @"$tmp_payload" 2>/dev/null)
  rm -f "$tmp_payload" 2>/dev/null || true

  if [ "$http" = "202" ]; then
    log_line "SENT ok (HTTP 202) to=$MAIL_TO subject=[$subject]"
    return 0
  else
    log_line "ERROR: SendGrid 回應 HTTP ${http:-?} to=$MAIL_TO subject=[$subject]"
    return 1
  fi
}

# JSON 字串轉義 (供 payload 用)；含 \r — 防 CRLF 設定值造成 payload 非法 JSON
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g' | awk 'BEGIN{ORS=""} {print (NR>1?"\\n":"") $0}'
}
