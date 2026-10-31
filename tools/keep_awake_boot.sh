#!/usr/bin/env bash
# 开机自动重设"永不锁屏" —— 放在启动项里，解决 power-shell 覆盖重启即失效的问题。
#
# 背景（实测）：本机没有 settings 命令，只能用
#     hdc -t <目标> shell "power-shell timeout -o 2147483647"
# 但这是**运行时覆盖，重启就丢**。本会话里它已经丢了 3 次（每次设备重启后屏就锁了，
# 应用连启动都被系统拒绝：Error 10106102 "screen is locked"）。
#
# 用法（任选一种）：
#   1) 手动/定时：  bash tools/keep_awake_boot.sh
#   2) 开机自启：   把下面这行加进你的启动项（crontab -e 或桌面自启）
#                   @reboot sleep 20 && bash /storage/Users/currentUser/WorkBuddy/TrofeoLCD/tools/keep_awake_boot.sh
set -u
TARGETS=("127.0.0.1:40601" "192.168.11.130:40601")
HDC="$(command -v hdc || echo hdc)"

# 先确保 hdc 有目标（网络/IP 会漂，所以多试几个已知地址）
if [ -z "$("$HDC" list targets 2>/dev/null | head -1)" ]; then
  "$HDC" start >/dev/null 2>&1
  sleep 2
fi

OK=0
for t in $(hdc list targets 2>/dev/null); do
  "$HDC" -t "$t" shell "power-shell wakeup" >/dev/null 2>&1
  out="$("$HDC" -t "$t" shell "power-shell timeout -o 2147483647" 2>&1)"
  case "$out" in
    *Override*) echo "[keep-awake] $t 已设永不超时"; OK=1 ;;
    *)          echo "[keep-awake] $t 失败: $out" ;;
  esac
done

if [ "$OK" = "0" ]; then
  echo "[keep-awake] 没有可用 hdc 目标。已知目标：" 
  printf '  %s\n' "${TARGETS[@]}"
  echo "  先确认设备在线（hdc list targets），必要时 hdc tconn <地址>"
  exit 1
fi
