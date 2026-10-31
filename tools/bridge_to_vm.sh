#!/usr/bin/env bash
# 在鸿蒙本机跑数据桥，把遥测 UDP 推给 Windows VM。
#
# 为什么这样最省事：数据源（~/.dsh/sessions）本来就在本机且是活的，
# 直接读 + UDP 推过去 —— **零拷贝、实时**，不需要共享盘、不需要
# --sessions-root、不需要定时同步。
#
# Windows 侧不需要加任何参数（dshlcd.ini 里 udp-any = 1 默认就是开的）。
#
#   bash tools/bridge_to_vm.sh            后台启动
#   bash tools/bridge_to_vm.sh --fg       前台（调试看输出）
#   bash tools/bridge_to_vm.sh --restart  先杀掉再起
#
# 可选环境变量：
#   VM_HOST=172.16.101.2          目标机器（默认按 VM 的 host-only 网桥地址）
#   PORT=54545                    目标 UDP 端口
#   DSH_LCD_PRINTER=<url>         打印机数据接口；不设则自动探测 8790
#   DSH_LCD_PRINTER_AUTO=0        关掉打印机自动探测
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VM_HOST="${VM_HOST:-172.16.101.2}"
PORT="${PORT:-54545}"
LOG="$HERE/bridge/.bridge-to-vm.log"
PID="$HERE/bridge/.bridge-to-vm.pid"

restart=0
fg=0
for a in "$@"; do
  [ "$a" = "--fg" ] && fg=1
  [ "$a" = "--restart" ] && restart=1
done

if [ "$restart" = "1" ] && [ -f "$PID" ]; then
  old="$(cat "$PID" 2>/dev/null || echo)"
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    kill "$old" 2>/dev/null
    echo "已停止旧桥 (PID $old)"
    sleep 1
  fi
  rm -f "$PID"
fi

if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
  echo "已在运行 (PID $(cat "$PID"))，日志: $LOG"
  echo "要重启请用：bash tools/bridge_to_vm.sh --restart"
  exit 0
fi

# ---- 打印机：与 bridge/start.sh 的自动探测保持一致 ----
# ★ 2026-10-15 补：原来这里漏了这段，导致 payload 里根本没有 `printer` 键，
#   Dotii 的 Bambu 页永远是"离线"（用户反馈"打印机那部分没连上"）。
#   探测不到服务也不影响其它功能（桥照常发其它遥测）。
PRINTER_ARG=""
if [ -n "${DSH_LCD_PRINTER:-}" ]; then
  PRINTER_ARG="--printer ${DSH_LCD_PRINTER}"
  echo "打印机：用环境变量 DSH_LCD_PRINTER=$DSH_LCD_PRINTER"
elif [ "${DSH_LCD_PRINTER_AUTO:-1}" = "1" ]; then
  if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/8790" 2>/dev/null; then
    PRINTER_ARG="--printer http://127.0.0.1:8790/api/state"
    echo "打印机：探测到本机 8790 有服务，已接上"
  else
    echo "打印机：本机 8790 没有服务（Bambu 页会显示离线）"
    echo "        有服务后重启桥即可：bash tools/bridge_to_vm.sh --restart"
  fi
fi

cd "$HERE/bridge"
ARGS="--host $VM_HOST --port $PORT --summary 120 --deepseek-balance 600 $PRINTER_ARG"

if [ "$fg" = "1" ]; then
  echo "前台运行：桥 → $VM_HOST:$PORT"
  exec node dsh-bridge.mjs $ARGS
fi

# 日志按大小轮转一次（对齐 start.sh —— 长跑会把 .bridge.log 撑到十几 MB）
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi

nohup node dsh-bridge.mjs $ARGS >> "$LOG" 2>&1 &
echo $! > "$PID"
sleep 2
if kill -0 "$(cat "$PID")" 2>/dev/null; then
  echo "已启动 (PID $(cat "$PID")) → $VM_HOST:$PORT"
  echo "日志: $LOG"
  tail -c 400 "$LOG" 2>/dev/null | tr '\r' '\n' | grep -v '^$' | tail -3
else
  echo "启动失败，日志尾部："
  tail -c 800 "$LOG" 2>/dev/null | tr '\r' '\n' | tail -10
  rm -f "$PID"
  exit 1
fi
