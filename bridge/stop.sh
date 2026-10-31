#!/usr/bin/env bash
# 停止后台数据桥
set -u
D="$(cd "$(dirname "$0")" && pwd)"
PID="$D/.bridge.pid"
if [ ! -f "$PID" ]; then echo "没有 PID 文件，未在运行"; exit 0; fi
P="$(cat "$PID")"
if kill -0 "$P" 2>/dev/null; then
  kill "$P" && echo "已停止 (PID $P)"
else
  echo "进程 $P 已不存在"
fi
rm -f "$PID"
