#!/usr/bin/env bash
# stop.sh — nimo-shake-starco 1.0.14-sc.20260917-OPAPP
# 用法: ./stop.sh [pidfile]    (預設 nimo-shake.pid;另有 conf 的 id 決定的 <id>.pid)
catalog=$(dirname "$0")
cd "${catalog}" || exit 1

pidfile="${1:-nimo-shake.pid}"
[ -f "$pidfile" ] || { echo "[INFO] 找不到 $pidfile,視為未在執行。"; exit 0; }
pid="$(cat "$pidfile")"
[ -n "$pid" ] || { echo "[INFO] $pidfile 為空,已清除。"; rm -f "$pidfile"; exit 0; }

if ! kill -0 "$pid" 2>/dev/null; then
    echo "[INFO] pid=$pid 已不存在(全量模式跑完會自行退出),清除 pid 檔。"
    rm -f "$pidfile"
    exit 0
fi

# 防呆:pid 可能已被系統重用,殺之前驗證指令列
if ! tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null | grep -q "nimo-shake"; then
    echo "[FAIL] pid=$pid 不是 nimo-shake(PID 可能已被系統重用),拒絕 kill。"
    exit 1
fi

kill -TERM "$pid" 2>/dev/null
for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "$pid" 2>/dev/null; then
    echo "[WARN] TERM 無效,改用 KILL。"
    kill -9 "$pid"
fi
rm -f nimo-shake.pid ./*.pid 2>/dev/null
echo "[OK] stopped pid=$pid"
