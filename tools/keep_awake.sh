#!/usr/bin/env bash
# keep_awake.sh —— 让设备屏幕不自动锁屏/熄屏（用户 2026-10-14 要求）
#
# 背景：设备上没有 settings 命令，但 power-shell 支持运行时覆盖熄屏超时。
#   power-shell timeout -o <ms>   覆盖熄屏时间（毫秒）
#   power-shell timeout -r        恢复系统默认
#   power-shell wakeup            立即点亮
#
# 注意：这是**运行时覆盖，设备重启后失效** —— 每次开机（或换班）跑一次本脚本即可。
#
# 用法：
#   bash tools/keep_awake.sh          # 设为永不超时（2147483647ms ≈ 24.8 天）
#   bash tools/keep_awake.sh 1800000  # 设为 30 分钟
#   bash tools/keep_awake.sh restore  # 恢复系统默认
#   bash tools/keep_awake.sh status   # 只看当前 diag 状态，不改设置

set -u

TARGET="${1:-2147483647}"
HDC_TARGET="${HDC_TARGET:-127.0.0.1:40601}"
DIAG_URL="${DIAG_URL:-http://127.0.0.1:54546/diag}"

hdc_do() {
  hdc -t "$HDC_TARGET" shell "$1" 2>&1
}

case "$TARGET" in
  status)
    echo "== 设备/应用状态 =="
    curl -s --max-time 6 "$DIAG_URL" || echo "(diag 不可用：应用可能没在跑)"
    echo
    exit 0
    ;;
  restore)
    echo "恢复系统默认熄屏时间…"
    hdc_do "power-shell timeout -r"
    ;;
  *)
    if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
      echo "参数错误：$TARGET（应为毫秒数、restore 或 status）" >&2
      exit 2
    fi
    echo "设置熄屏时间为 ${TARGET} ms（2147483647 ≈ 永不）…"
    hdc_do "power-shell timeout -o $TARGET"
    ;;
esac

# 顺手点亮一次，避免设置完还黑着
hdc_do "power-shell wakeup" >/dev/null 2>&1 || true

echo
echo "== 当前状态 =="
curl -s --max-time 6 "$DIAG_URL" \
  | tr ',' '\n' | grep -E '"(running|theme|usbOpen|errors|sent|fps|bgTask)"' \
  || echo "(diag 不可用)"
echo
echo "提示：应用已注册长时任务（bgTask），手机屏幕黑掉也照样推帧；"
echo "      本设置只影响「手机自己会不会锁屏」。重启设备后需重跑本脚本。"
