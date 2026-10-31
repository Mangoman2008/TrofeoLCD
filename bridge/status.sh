#!/usr/bin/env bash
# 查看数据桥状态
set -u
D="$(cd "$(dirname "$0")" && pwd)"
PID="$D/.bridge.pid"; LOG="$D/.bridge.log"
if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
  echo "运行中 (PID $(cat "$PID"))"
else
  echo "未运行"
fi
[ -f "$LOG" ] && { echo "--- 日志尾部 ---"; tail -n 3 "$LOG" | tr -d '\r'; }
