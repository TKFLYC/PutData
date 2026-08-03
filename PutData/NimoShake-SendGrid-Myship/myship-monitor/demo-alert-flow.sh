#!/bin/bash
# =============================================================================
# demo-alert-flow.sh — 告警系統驗收演示 (一鍵跑完整個告警生命週期)
# -----------------------------------------------------------------------------
# 使用「真實的 NimoShake log」(預設: repo 根目錄 DevTest.log，2026/05/04 實際
# 執行、全量中斷的真實案例)。演示過程不偽造任何 log 內容，只做檔案搬移:
#   1) 載入真實 log     -> 🔴 新增告警 (真實的「全量未完成即中止」+ 系統狀態判讀)
#   2) 持續未修復       -> 🟠 持續未解除提醒 (等 REALERT 到期)
#   3) 模擬 log 被移走  -> 🔴 新增: log 檔遺失 (既有告警凍結，不誤報解除)
#   4) log 恢復         -> 🟢 已解除: log 檔遺失
# 全程在暫存目錄以 log 副本進行，不動正式環境 state/、不動原始 log。
#
# 用法:
#   bash demo-alert-flow.sh <env.conf>            # dry-run 彩排 (不寄信)
#   bash demo-alert-flow.sh --send <env.conf>     # 真的寄信 (收件人取自 conf 的 MAIL_TO)
# 環境變數:
#   DEMO_REALERT    第 2 步提醒信的等待秒數 (預設 60)
#   DEMO_SOURCE_LOG 真實 log 路徑 (預設 <repo>/DevTest.log)
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT="$SCRIPT_DIR/nimoshake-alert.sh"
# 範例 log 依序找: DEMO_SOURCE_LOG 指定 > repo 上層 DevTest.log > 同層 DevTest.log
SRC_LOG="${DEMO_SOURCE_LOG:-$SCRIPT_DIR/../DevTest.log}"
[ -f "$SRC_LOG" ] || SRC_LOG="$SCRIPT_DIR/DevTest.log"

SEND=0
CONF=""
for a in "$@"; do
  case "$a" in
    --send) SEND=1 ;;
    -*) echo "未知參數: $a" >&2; exit 2 ;;
    *) CONF="$a" ;;
  esac
done
if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "用法: $0 [--send] <env.conf>" >&2; exit 2
fi
if [ ! -f "$SRC_LOG" ]; then
  echo "找不到真實 log: $SRC_LOG (可用 DEMO_SOURCE_LOG=/path/to/nimo-shake.log 指定)" >&2; exit 2
fi

DEMO_REALERT="${DEMO_REALERT:-60}"

green(){ echo -e "\033[32m$1\033[0m"; }
cyan(){ echo -e "\033[36m$1\033[0m"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DEMO_LOG="$TMP/nimo-shake.log"
DEMO_CONF="$TMP/demo.conf"

# 以正式 conf 為底覆寫 (log/state 都在暫存目錄，不碰正式環境)
cp "$CONF" "$DEMO_CONF"
{
  echo ""
  echo "# ---- demo 覆寫 ----"
  echo "LOG_FILE=\"$DEMO_LOG\""
  echo "STATE_DIR=\"$TMP/state\""
  echo "DRY_RUN=$([ $SEND -eq 1 ] && echo 0 || echo 1)"
  echo "REALERT_INTERVAL=$DEMO_REALERT"
  echo "GLOBAL_COOLDOWN=5"
} >> "$DEMO_CONF"

run_alert(){ bash "$ALERT" "$DEMO_CONF" 2>&1 | sed 's/^/    /'; }

echo "============================================================"
cyan " NimoShake 告警系統演示  (conf: $CONF)"
cyan " 真實 log: $SRC_LOG ($(wc -l < "$SRC_LOG" | tr -d ' ') 行，內容不做任何修改)"
cyan " 模式: $([ $SEND -eq 1 ] && echo '真實寄信' || echo 'dry-run 彩排(不寄信)')   提醒間隔: ${DEMO_REALERT}s"
echo "============================================================"

cyan "[步驟 1/4] 載入真實 log — 內含真實的「全量同步中斷」案例 (預期: 🔴 新增告警 + 系統狀態判讀)"
cp "$SRC_LOG" "$DEMO_LOG"
run_alert
echo ""

cyan "[步驟 2/4] 異常持續未修復 — 等 ${DEMO_REALERT}s 到期 (預期: 🟠 持續未解除提醒)"
sleep $((DEMO_REALERT + 3))
run_alert
echo ""

cyan "[步驟 3/4] 模擬 log 檔被移走 (輪替/誤刪情境) (預期: 🔴 新增: log 檔遺失；既有告警凍結不誤報解除)"
mv "$DEMO_LOG" "$DEMO_LOG.bak"
sleep 6   # 過冷卻
run_alert
echo ""

cyan "[步驟 4/4] log 檔恢復 (預期: 🟢 已解除: log 檔遺失)"
mv "$DEMO_LOG.bak" "$DEMO_LOG"
sleep 6   # 過冷卻
run_alert
echo ""

echo "============================================================"
if [ $SEND -eq 1 ]; then
  green " 演示完成 ✓ 請到收件匣確認: 🔴 新增(真實中斷案例) / 🟠 持續提醒 / 🔴 log遺失 / 🟢 已解除"
else
  green " 彩排完成 ✓ 以上為 dry-run，改用 --send 參數即真實寄信"
fi
echo "============================================================"
