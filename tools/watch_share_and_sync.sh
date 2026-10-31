#!/usr/bin/env bash
# 等 VM 共享盘上的 dshlcd 目录回来，然后自动跑一次带校验的同步。
# （共享盘会间歇性只暴露部分内容：C 盘可见但 dshlcd 消失）
set -u
V=/storage/Users/currentUser/.VMDocs/.hwf_share/.disks/C/dshlcd
C=/storage/Users/currentUser/.VMDocs/.hwf_share/.disks/C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAX=${MAX:-120}          # 最多等 120 轮
for ((i=1; i<=MAX; i++)); do
  if [ -d "$V/src" ] && [ -w "$V" ]; then
    echo "[$(date '+%H:%M:%S')] 共享盘就绪（等了 $((i*5)) 秒），开始同步"
    exec bash "$ROOT/tools/sync_to_vm.sh"
  fi
  if [ $((i % 6)) -eq 0 ]; then
    echo "[$(date '+%H:%M:%S')] 等待中 ($((i*5))s) — C 盘内容: $(ls "$C" 2>/dev/null | tr '\n' ' ')"
  fi
  sleep 5
done
echo "[$(date '+%H:%M:%S')] 超时：dshlcd 目录始终没出现，需要你确认 VM 侧共享"
exit 1
