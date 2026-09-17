#!/usr/bin/env bash
# start.sh — nimo-shake-starco 1.0.14-sc.20260917-OPAPP
# 用法: ./start.sh [conf]    (預設 nimo-shake.conf)
# 舊版的第二參數(-type 模式)已廢棄:同步型態由 conf 的 sync_mode 決定
catalog=$(dirname "$0")
cd "${catalog}" || exit 1

name="nimo-shake.linux"
conf="${1:-nimo-shake.conf}"

if [ $# -gt 2 ]; then
    echo "USAGE: $0 [conf]"
    exit 1
fi
if [ $# -eq 2 ]; then
    echo "[WARN] 第二個參數 '$2' 已忽略:本版沒有 -type 旗標,同步型態由 conf 的 sync_mode 決定。"
fi

if [ "Darwin" = "$(uname -s)" ]; then
    echo "WARNING !!! 本包未附 macOS 執行檔,僅支援 Linux。"
    exit 1
fi

[ -x "./$name" ] || { echo "[FAIL] 找不到或不可執行:./$name"; exit 1; }
[ -f "$conf" ]   || { echo "[FAIL] 找不到設定檔:$conf"; exit 1; }

cfg() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$conf" | head -1 | tr -d "[:space:]"; }

# preflight:mchange_cast 必須配得到 type_rules(路徑相對於本資料夾)
if [ "$(cfg 'convert.type')" = "mchange_cast" ]; then
    rules="$(cfg 'convert.type_rules_path')"
    if [ -z "$rules" ] || [ ! -f "$rules" ]; then
        echo "[FAIL] convert.type=mchange_cast,但 type_rules 檔不存在:'${rules:-<未設定>}'"
        exit 1
    fi
fi

id="$(cfg 'id')"; pidfile="${id:-nimo-shake}.pid"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "[FAIL] 已在執行中(pid=$(cat "$pidfile"));請先 ./stop.sh"
    exit 1
fi
rm -f "$pidfile" nimo-shake.pid

if [ "$(cfg 'target.db.exist')" = "drop" ]; then
    echo "[WARN] target.db.exist=drop:目標 collection 會先被清空再重搬!"
fi

setsid nohup "./$name" -conf="$conf" >> "$name.output" 2>&1 < /dev/null &

# 等 binary 自己寫出 <id>.pid(最多 10 秒);寫不出來 = 啟動失敗
ok=""
for _ in $(seq 1 20); do
    [ -s "$pidfile" ] && { ok=1; break; }
    sleep 0.5
done
if [ -z "$ok" ]; then
    echo "[FAIL] 啟動失敗。$name.output 末 20 行:"
    tail -n 20 "$name.output"
    exit 1
fi
cp "$pidfile" nimo-shake.pid

# 啟動後複檢:有些錯誤(憑證/連線設定)會在寫出 pid 檔之後才崩
sleep 2
if ! kill -0 "$(cat nimo-shake.pid)" 2>/dev/null; then
    logf="$(cfg 'log.file')"
    if [ -n "$logf" ] && grep -q "sync complete" "$logf" 2>/dev/null; then
        echo "[OK] 啟動後隨即完成(資料量小,全量已跑完)。log: $logf"
        rm -f "$pidfile" nimo-shake.pid
        exit 0
    fi
    echo "[FAIL] 程序啟動後隨即退出(常見原因:憑證/連線設定錯誤)。輸出末 20 行:"
    tail -n 20 "$name.output" 2>/dev/null
    [ -n "$logf" ] && [ -f "$logf" ] && { echo "--- $logf 末 10 行 ---"; tail -n 10 "$logf"; }
    rm -f "$pidfile" nimo-shake.pid
    exit 1
fi
echo "[OK] started pid=$(cat nimo-shake.pid) conf=$conf"
echo "     stdout: $name.output    log: $(cfg 'log.file')    停止: ./stop.sh"
