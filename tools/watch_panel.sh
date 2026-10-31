#!/usr/bin/env bash
# 屏稳定性监控（看门狗诊断版）
#
# 用途：用户反馈"屏上老闪一下开机画面"。这个脚本长时间采样 /diag，
# 记录任何**异常瞬间**（USB 掉线 / 被占 / 推帧停滞 / USB 被重新打开），
# 用来判断闪烁到底来自应用侧还是屏端。
#
# 用法：  bash tools/watch_panel.sh [分钟数]     （默认 10 分钟）
set -u
MIN="${1:-10}"
PORT=54546
N=$((MIN * 60 / 2))
echo "[watch] 开始监控 ${MIN} 分钟（每 2 秒采样一次，异常时立即打印）"

prev_sent=""; prev_oc=""; prev_open=""
drops=0; stuck=0; reopens=0; fails=0
for i in $(seq 1 "$N"); do
  out="$(curl -s --max-time 3 "http://127.0.0.1:$PORT/diag" 2>/dev/null)"
  if [ -z "$out" ]; then
    fails=$((fails+1))
    echo "[watch] t=$((i*2))s  ⚠️ diag 无响应（应用可能卡死/重启）"
    sleep 2; continue
  fi
  read -r open blocked sent oc err <<<"$(printf '%s' "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('usbOpen'), d.get('usbClaimBlocked'), d.get('sent'), d.get('usbOpenCount'), d.get('errors'))" 2>/dev/null)"
  [ -z "${open:-}" ] && { sleep 2; continue; }

  if [ "$open" != "True" ] || [ "$blocked" = "True" ]; then
    drops=$((drops+1)); echo "[watch] t=$((i*2))s  ⚠️ USB 异常 open=$open blocked=$blocked"
  fi
  if [ -n "$prev_oc" ] && [ "$oc" != "$prev_oc" ]; then
    reopens=$((reopens+1)); echo "[watch] t=$((i*2))s  ⚠️ USB 被重新打开 openCount $prev_oc → $oc（屏被重初始化）"
  fi
  if [ -n "$prev_sent" ] && [ "$sent" = "$prev_sent" ]; then
    stuck=$((stuck+1))
  fi
  prev_sent="$sent"; prev_oc="$oc"; prev_open="$open"
  sleep 2
done
echo "[watch] 结束：采样 $N 次 / $((N*2))s"
echo "[watch]   异常汇总  USB掉线=$drops  USB重开=$reopens  diag失败=$fails  推帧停滞=$stuck"
printf '[watch]   首末 openCount: %s\n' "$prev_oc"
