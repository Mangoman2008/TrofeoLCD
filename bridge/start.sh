#!/usr/bin/env bash
# 后台启动数据桥（写 PID 与日志，避免占着终端）
#   ./start.sh                      正常启动
#   ./start.sh --weather 北京       顺带开天气
#   ./start.sh --lyrics-cmd '命令'  顺带开歌词
set -u
D="$(cd "$(dirname "$0")" && pwd)"
PID="$D/.bridge.pid"
LOG="$D/.bridge.log"
NODE="$(command -v node || echo "$HOME/.harmonybrew/bin/node")"

if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
  echo "已在运行 (PID $(cat "$PID"))，日志: $LOG"
  exit 0
fi

cd "$D"
# 拓竹打印机：有环境变量就用（默认指向本机的 bambu-monitor）
PRINTER_ARG=""
if [ -n "${DSH_LCD_PRINTER:-}" ]; then
  PRINTER_ARG="--printer ${DSH_LCD_PRINTER}"
elif [ "${DSH_LCD_PRINTER_AUTO:-1}" = "1" ]; then
  # 本机 8790 有 bambu-monitor 就自动接上（服务没起也不影响）
  if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/8790" 2>/dev/null; then
    PRINTER_ARG="--printer http://127.0.0.1:8790/api/state"
  fi
fi
BG_ARG=""
[ -f "$D/docs/bg-grid.jpg" ] && BG_ARG="--bg $D/docs/bg-grid.jpg"
SUMMARY_ARG="--summary 120"
BALANCE_ARG="--deepseek-balance 600"

# ★ 日志轮转（2026-10-15）：原来这里是无脑 `>> "$LOG"`，实测长跑 14 小时后
#   `.bridge.log` 涨到 13MB 且从不清理。启动时按大小轮转一次：
#   超过 MAX_BYTES 就把当前日志改名保留一份 .1，其余丢弃（只留最近一段）。
MAX_BYTES=$(( 2 * 1024 * 1024 ))      # 2MB
if [ -f "$LOG" ]; then
  CUR=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$CUR" -gt "$MAX_BYTES" ]; then
    tail -c 262144 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    echo "[start.sh] 日志已轮转（原 $((CUR/1024))KB → 保留末尾 256KB）"
  fi
fi

nohup "$NODE" dsh-bridge.mjs $BALANCE_ARG $SUMMARY_ARG $BG_ARG $PRINTER_ARG "$@" >> "$LOG" 2>&1 &
echo $! > "$PID"
sleep 1.5
if kill -0 "$(cat "$PID")" 2>/dev/null; then
  echo "已启动 (PID $(cat "$PID"))"
  echo "日志: $LOG"
  tail -n 3 "$LOG" 2>/dev/null | tr -d '\r'
else
  echo "启动失败，日志尾部："; tail -n 10 "$LOG" 2>/dev/null
  rm -f "$PID"; exit 1
fi
