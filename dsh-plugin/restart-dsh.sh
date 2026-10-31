#!/usr/bin/env bash
# restart-dsh.sh —— 真正重启 DSH（含"确认真退出了"与"确认新实例起来了"）
#
# ## 为什么需要这个脚本
# 实测踩过：用户以为"重启了 DSH"，但 `bin/dsh-ohos.js` 进程的启动时间**没变**
# —— 刷新浏览器 / 关标签页**都不算重启**，DSH 是常驻进程。
# 结果就是插件改了、profile 也更新了，但运行中的 DSH 仍加载旧代码，
# 表现为"改了没生效"，而且很难看出来。
#
# 这个脚本把三件事做扎实：
#   ① 停掉所有 DSH 实例 → **逐一确认进程真的没了**（不然新实例会 EADDRINUSE）
#   ② 等端口释放 → 启动新实例（detached，不随终端退出而死）
#   ③ 确认新实例真的起来了（读它的 startup 日志 + 探端口）
#
# ## 用法
#   ./restart-dsh.sh              # 默认 profile=web，端口 3080
#   ./restart-dsh.sh --port 3083  # 指定端口（LAN 那套用 3083）
#   ./restart-dsh.sh --profile web --port 3083
#   ./restart-dsh.sh --dry-run    # 只看会做什么，不动手
#
# ⚠️ 重启会终止跑在这个 DSH 里的对话（如果当前会话就在它里面）。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE="web"
PORT="3080"
LAN_PATCH=""
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --lan)     LAN_PATCH="$HOME/.cache/dsh-lan/patch-${PORT}.yml"; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

DSH_BIN="$(command -v dsh-harmonyos || command -v dsh-ohos || true)"
[ -n "$DSH_BIN" ] || { echo "❌ 找不到 dsh-harmonyos / dsh-ohos"; exit 1; }

say() { printf '  %s\n' "$*"; }
ok()  { printf '  ✅ %s\n' "$*"; }
warn(){ printf '  ⚠️  %s\n' "$*"; }
err() { printf '  ❌ %s\n' "$*"; }

# 列出所有 DSH 主进程 PID（排除本脚本与外层 shell）
dsh_pids() {
  python3 - <<'PY'
import os
for pid in sorted(os.listdir('/proc'), key=lambda x: int(x) if x.isdigit() else 0):
    if not pid.isdigit():
        continue
    try:
        raw = open(f'/proc/{pid}/cmdline', 'rb').read().decode('utf-8', 'replace')
    except Exception:
        continue
    if 'bash' in raw or 'restart-dsh' in raw:
        continue
    # 放宽匹配：实测有两套实例（3080 那套 + 3083 那套），
    # 只匹配一种写法会漏掉另一套 → 残留实例占着端口 → 新实例 EADDRINUSE 起不来。
    if ('dsh-ohos' in raw or 'dsh-harmonyos' in raw
            or 'bin/dsh-ohos.js' in raw or 'bin.js' in raw
            or '@deepseek-ai/dsh/lib' in raw):
        print(pid)
PY
}

port_busy() {
  python3 - "$1" <<'PY'
import socket, sys
p = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(1)
try:
    s.connect(('127.0.0.1', p))
    print('busy')
except Exception:
    print('free')
finally:
    s.close()
PY
}

echo "════ DSH 重启（profile=$PROFILE port=$PORT）════"

PIDS="$(dsh_pids | tr '\n' ' ')"
if [ -n "${PIDS// /}" ]; then
  say "当前 DSH 进程: $PIDS"
else
  warn "没发现运行中的 DSH 进程"
fi

if [ "$DRY" -eq 1 ]; then
  say "[dry-run] 会执行：kill $PIDS ；等端口 $PORT 释放；再启动新实例"
  exit 0
fi

# ── ① 停 ──
if [ -n "${PIDS// /}" ]; then
  say "停止中…"
  # shellcheck disable=SC2086
  kill $PIDS 2>/dev/null
  # 等它真的退出（最多 15 秒），不行再来硬的
  for _ in $(seq 1 15); do
    sleep 1
    LEFT="$(dsh_pids | tr -d '\n')"
    [ -z "$LEFT" ] && break
  done
  LEFT="$(dsh_pids | tr -d '\n')"
  if [ -n "$LEFT" ]; then
    warn "还有进程没退: $LEFT → SIGKILL"
    # shellcheck disable=SC2086
    kill -9 $LEFT 2>/dev/null
    sleep 2
  fi
fi
LEFT="$(dsh_pids | tr -d '\n')"
if [ -n "$LEFT" ]; then
  err "仍有 DSH 进程存活: $LEFT（请手动处理后再来）"
  exit 1
fi
ok "所有 DSH 进程已退出"

# ── ② 等端口释放 ──
for i in $(seq 1 20); do
  if [ "$(port_busy "$PORT")" = "free" ]; then
    ok "端口 $PORT 已释放"
    break
  fi
  sleep 1
  [ "$i" -eq 20 ] && warn "端口 $PORT 仍被占用（可能有别的东西在用）"
done

# ── ③ 启动新实例（detached）──
LOGDIR="$HOME/.cache/dsh-lan"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/log-${PORT}.txt"
: > "$LOG"
ARGS=(-- --profile "$PROFILE" --port "$PORT" --no-open)
if [ -n "$LAN_PATCH" ] && [ -f "$LAN_PATCH" ]; then
  ARGS=(-- --profile "$PROFILE" --patch "$LAN_PATCH" --no-open)
  say "使用 LAN patch: $LAN_PATCH"
fi
say "启动: $DSH_BIN ${ARGS[*]}"
# setsid + nohup：脱离本终端，终端关掉也不会死
setsid nohup "$DSH_BIN" "${ARGS[@]}" >> "$LOG" 2>&1 < /dev/null &
NEWPID=$!
echo "$NEWPID" > "$LOGDIR/pid-${PORT}"
sleep 1
ok "已启动（launcher PID $NEWPID），日志: $LOG"

# ── ④ 确认真起来了 ──
say "等待就绪…"
UP=0
for i in $(seq 1 45); do
  sleep 1
  if grep -qE 'dsh web: http' "$LOG" 2>/dev/null; then
    UP=1
    break
  fi
  if grep -qE 'EADDRINUSE|startup failed' "$LOG" 2>/dev/null; then
    err "启动失败：" ; grep -E 'EADDRINUSE|startup failed|Error:' "$LOG" | head -5 | sed 's/^/      /'
    exit 1
  fi
done

if [ "$UP" -eq 1 ]; then
  ok "已就绪"
  echo
  grep -E 'dsh web: http' "$LOG" | tail -1 | sed 's/^/  /'
  echo
  say "插件是否加载：等 5 秒后看心跳文件是否每秒更新"
  say "  watch -n1 'stat -c %y ~/.dsh/storages/lcd-bridge/last.json'"
else
  warn "45 秒内没看到 'dsh web: http' —— 可能还在起，或有错"
  tail -12 "$LOG" | sed 's/^/      /'
fi
