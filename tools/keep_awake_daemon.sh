#!/usr/bin/env bash
# 常驻守护：定时重设"永不熄屏"，解决"power-shell 覆盖重启即丢"的问题。
#
# ## 为什么需要守护而不是一次性设置
# 本机实测：`power-shell timeout -o 2147483647` 是**运行时覆盖，重启就丢**；
# 而且系统里**没有 crontab、没有 ~/.config/autostart、没有 LaunchAgents**
# （都实测过），所以挂不了标准的开机自启。
# 于是用一个常驻循环：每 5 分钟检查一次，丢了就重设。
#
# ## 与 keep_awake_boot.sh 的分工
# - `keep_awake_boot.sh`：一次性把覆盖设上（手动或开机时调）
# - `keep_awake_daemon.sh`（本文件）：常驻守着，**重启后第一次运行时会把覆盖补回来**
#
# ## 用法
#   nohup bash tools/keep_awake_daemon.sh > ~/.cache/keep_awake.log 2>&1 &
#   bash tools/keep_awake_daemon.sh --once     # 只检查一次（给开机脚本调用）
set -u
ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1
HERE="$(cd "$(dirname "$0")" && pwd)"
BOOT="$HERE/keep_awake_boot.sh"
INTERVAL=300          # 5 分钟
LOG_PREFIX="[keep-awake-daemon]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX $*"; }

apply() {
  # 复用 keep_awake_boot.sh 的逻辑（它已处理多目标与 hdc 目标漂移）
  if [ -x "$BOOT" ]; then
    local out
    out="$(bash "$BOOT" 2>&1)"
    case "$out" in
      *已设永不超时*) log "已确认/重设成功" ;;
      *)              log "设置失败：$(echo "$out" | tail -2 | tr '\n' ' ')" ;;
    esac
  else
    log "找不到 $BOOT"
  fi
}

apply
if [ "$ONCE" = "1" ]; then
  exit 0
fi
while true; do
  sleep "$INTERVAL"
  apply
done
