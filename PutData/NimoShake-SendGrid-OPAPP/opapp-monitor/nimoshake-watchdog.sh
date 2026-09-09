#!/bin/bash
# =============================================================================
# nimoshake-watchdog.sh — 看門狗: 監控「告警引擎本身」有沒有掛掉
#
# 問題: nimo-shake 掛了有 PROCESS_DOWN、fullcheck 掛了有異常結束告警，
#       但告警引擎 (nimoshake-alert.sh) 自己壞掉 = 無聲失明，一封信都不會有。
# 做法: 引擎每輪「完整跑完」會寫 state/.heartbeat；本腳本由 cron 每 5 分鐘
#       獨立執行，心跳超過門檻沒更新 → 直接用 curl 寄 🔴「監控引擎停擺」，
#       恢復後寄 🟢「已恢復」。
#
# 【設計紅線】本腳本刻意「完全獨立」: 不 source lib/common.sh、不呼叫引擎——
#   引擎或共用碼壞掉時，看門狗必須還活著能寄信。除 conf (純 KEY=VALUE) 外
#   零相依，只用 bash + curl。
#
# 用法:   ./nimoshake-watchdog.sh <env.conf>
# 排程:   */5 * * * * /bin/bash $BASE/nimoshake-watchdog.sh $BASE/MyShip/myship.conf >> $BASE/MyShip/state/watchdog.log 2>&1
# 參數 (conf 可覆寫):
#   WATCHDOG_STALE_SECONDS=300     心跳落後幾秒視為引擎停擺 (預設 5 分鐘 = 連漏 5 輪)
#   WATCHDOG_REALERT_SECONDS=21600 停擺未恢復多久提醒一次 (預設 6 小時)
# 誠實聲明: 看門狗與引擎裝在「同一份 crontab」——若整份 crontab 沒裝好或
#   cron 服務本身停了，兩者一起沉默，這層只能靠外部監控 (如主機監控) 補。
# =============================================================================
set -u

CONF="${1:-}"
if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "[FATAL] 用法: nimoshake-watchdog.sh <env.conf> (找不到: ${CONF:-未指定})" >&2
  exit 1
fi
# conf 僅含 KEY=VALUE (含少數函式定義時也無害，本腳本不呼叫它們)
set -a; . "$CONF"; set +a

: "${ENV_NAME:?conf 缺少 ENV_NAME}"
: "${MAIL_TO:?conf 缺少 MAIL_TO}"
: "${MAIL_FROM:?conf 缺少 MAIL_FROM}"
STATE_DIR="${STATE_DIR:-$(cd "$(dirname "$CONF")" && pwd)/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STALE="${WATCHDOG_STALE_SECONDS:-300}"
REALERT="${WATCHDOG_REALERT_SECONDS:-21600}"
DRY_RUN="${DRY_RUN:-1}"
SENDGRID_API_HOST="${SENDGRID_API_HOST:-api.sendgrid.com}"
SENDGRID_API_PORT="${SENDGRID_API_PORT:-443}"
if [ -z "${SENDGRID_API_KEY:-}" ] && [ -n "${SENDGRID_API_KEY_FILE:-}" ] && [ -f "$SENDGRID_API_KEY_FILE" ]; then
  SENDGRID_API_KEY="$(tr -d ' \r\n' < "$SENDGRID_API_KEY_FILE")"
fi

HB_FILE="$STATE_DIR/.heartbeat"
DOWN_FILE="$STATE_DIR/.watchdog_down"
NOW=$(date +%s)
HOST=$(hostname 2>/dev/null || echo "?")
SUBJ="$ENV_NAME"; [ -n "${HOST_ROLE:-}" ] && SUBJ="$ENV_NAME·$HOST_ROLE"

wd_log() { echo "[$(date '+%F %T')] $*"; }   # cron 導向 watchdog.log

wd_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }

wd_send() { # $1=主旨 $2=內文 → 0 成功
  local subject="$1" body="$2"
  if [ "$DRY_RUN" = "1" ]; then
    wd_log "DRY_RUN: 略過寄信 subject=[$subject]"
    return 0
  fi
  if [ -z "${SENDGRID_API_KEY:-}" ] || ! command -v curl >/dev/null 2>&1; then
    wd_log "ERROR: 缺 SENDGRID_API_KEY 或 curl，無法寄信"
    return 1
  fi
  local to_json="" addr
  for addr in $(printf '%s' "$MAIL_TO" | tr ',;' ' '); do
    [ -z "$addr" ] && continue
    to_json+="{\"email\":\"$(wd_esc "$addr")\"},"
  done
  to_json="${to_json%,}"
  local tmp="$STATE_DIR/.wd_payload.$$"
  printf '{"personalizations":[{"to":[%s]}],"from":{"email":"%s","name":"%s"},"subject":"%s","content":[{"type":"text/plain","value":"%s"}]}' \
    "$to_json" "$(wd_esc "$MAIL_FROM")" "$(wd_esc "StarCo Monitor (${ENV_NAME})")" \
    "$(wd_esc "$subject")" "$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS=""} {print (NR>1?"\\n":"") $0}')" > "$tmp"
  local http
  http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -X POST "https://${SENDGRID_API_HOST}:${SENDGRID_API_PORT}/v3/mail/send" \
    -H "Authorization: Bearer ${SENDGRID_API_KEY}" \
    -H 'Content-Type: application/json' \
    --data-binary @"$tmp" 2>/dev/null)
  rm -f "$tmp" 2>/dev/null || true
  if [ "$http" = "202" ]; then wd_log "SENT ok subject=[$subject]"; return 0
  else wd_log "ERROR: SendGrid HTTP ${http:-?} subject=[$subject]"; return 1; fi
}

# ---- 心跳判讀 ----------------------------------------------------------------
HB_TS=0
[ -f "$HB_FILE" ] && HB_TS=$(tr -dc '0-9' < "$HB_FILE" 2>/dev/null)
: "${HB_TS:=0}"
AGE=$((NOW - HB_TS))

FOOT=$'\n---\n環境: '"$SUBJ"$'  主機: '"$HOST"$'\n時間: '"$(date '+%F %T %Z')"$'\n(本信由 nimoshake-watchdog.sh 自動發送；看門狗與告警引擎為獨立程式)'

if [ "$HB_TS" -gt 0 ] && [ "$AGE" -le "$STALE" ]; then
  # ---- 心跳正常 ----
  if [ -f "$DOWN_FILE" ]; then
    if wd_send "【StarCo $SUBJ】🟢 監控引擎已恢復" \
"告警引擎 (nimoshake-alert.sh) 已恢復運作，心跳更新於 $(date -d "@$HB_TS" '+%F %T' 2>/dev/null || echo "$HB_TS")。
停擺期間的 NimoShake 異常會在接下來幾輪重新判定，若有未解除問題將照常告警。$FOOT"; then
      rm -f "$DOWN_FILE" 2>/dev/null || true
    fi
  fi
  exit 0
fi

# ---- 心跳停更 (或從未有心跳) --------------------------------------------------
if [ "$HB_TS" -eq 0 ]; then
  DESC="找不到心跳檔 ($HB_FILE)——告警引擎可能從未成功執行過。"
else
  DESC="心跳已 $((AGE/60)) 分鐘未更新 (最後: $(date -d "@$HB_TS" '+%F %T' 2>/dev/null || echo "$HB_TS")，門檻 $((STALE/60)) 分鐘)。"
fi
BODY="監控告警引擎 (nimoshake-alert.sh) 疑似停擺，期間所有 NimoShake/FullCheck
異常都【不會】有人通知，請儘速處理。

狀況: $DESC

👉 排查 (登入主機依序執行):
  1. sudo crontab -l               # 確認告警排程還在、BASE 路徑正確
  2. sudo tail -20 <BASE>/<環境>/state/cron.log    # 看引擎最近的錯誤輸出
  3. sudo bash <BASE>/nimoshake-alert.sh --status <conf>   # 手動跑一次看哪行報錯
  4. 檢查 conf 是否被改壞、磁碟是否已滿 (df -h)
$FOOT"

if [ ! -f "$DOWN_FILE" ]; then
  if wd_send "【StarCo $SUBJ】🔴 監控引擎停擺 (告警失效中)" "$BODY"; then
    echo "$NOW" > "$DOWN_FILE" 2>/dev/null || true
  fi
else
  LAST=$(tr -dc '0-9' < "$DOWN_FILE" 2>/dev/null); : "${LAST:=0}"
  if [ "$REALERT" -gt 0 ] && [ $((NOW - LAST)) -ge "$REALERT" ]; then
    if wd_send "【StarCo $SUBJ】🟠 監控引擎仍停擺 (提醒)" "$BODY"; then
      echo "$NOW" > "$DOWN_FILE" 2>/dev/null || true
    fi
  else
    wd_log "INFO: 引擎仍停擺，距上次通知未達提醒間隔，略過"
  fi
fi
exit 0
