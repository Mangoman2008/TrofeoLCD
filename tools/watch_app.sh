#!/bin/sh
# 旁观鸿蒙端应用：每 15 秒打一次 /status，记录时间戳；一旦卡死就把现场记下来。
# 用法：sh tools/watch_app.sh [分钟数]
MIN=${1:-40}
OUT="$HOME/WorkBuddy/TrofeoLCD/.diag/status-watch.txt"
: > "$OUT"
i=0; fails=0
while [ $i -lt $((MIN*4)) ]; do
  i=$((i+1))
  TS=$(date '+%H:%M:%S')
  BODY=$(timeout 5 curl -s -m 4 "http://127.0.0.1:54546/status" 2>/dev/null)
  if [ -z "$BODY" ]; then
    fails=$((fails+1))
    echo "$TS  ❌ 超时（连续第 $fails 次）" >> "$OUT"
    if [ "$fails" -ge 6 ]; then
      echo "$TS  === 判定卡死，停止观察（进程仍活着）===" >> "$OUT"
      break
    fi
  else
    if [ "$fails" -gt 0 ]; then echo "$TS  （恢复）" >> "$OUT"; fi
    fails=0
    echo "$TS  $BODY" >> "$OUT"
  fi
  sleep 15
done
echo "$(date '+%H:%M:%S')  观察结束" >> "$OUT"
