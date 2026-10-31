#!/usr/bin/env bash
# console.sh —— 可视化 Agent 控制台的一键启停 + 端到端自检
#
#   bash tools/console.sh start     后台起控制台（写 PID / 日志）
#   bash tools/console.sh stop      停止
#   bash tools/console.sh restart   重启
#   bash tools/console.sh status    看状态与地址
#   bash tools/console.sh url       只打印地址
#   bash tools/console.sh check     端到端自检（12 项，不改动副屏内容）
#
# 设计要点：
#   · 只绑 127.0.0.1，不对局域网开放
#   · 副屏控制走**白名单**（只放开 theme/background/profile 等可逆键），自检里会验证未知键被丢弃
#   · 自检里的 /set 只用"当前同样的值"或"未知键"，绝不真正改变你的屏幕
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="$ROOT/bridge/.console.pid"
LOGFILE="$ROOT/bridge/.console.log"
PORT="${DSH_LCD_CONSOLE_PORT:-54550}"
NODE="$(command -v node || echo "$HOME/.harmonybrew/bin/node")"
URL="http://127.0.0.1:$PORT/"

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
alive_http() { curl -s -m 2 -o /dev/null "$URL"health 2>/dev/null; }

case "${1:-status}" in
start)
  if running; then echo "已在运行 (PID $(cat "$PIDFILE"))  $URL"; exit 0; fi
  cd "$ROOT"
  nohup "$NODE" bridge/console-server.mjs --port "$PORT" >> "$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2.5
  if running && alive_http; then
    echo "已启动 (PID $(cat "$PIDFILE"))"
    echo "地址: $URL"
    echo "日志: $LOGFILE"
  else
    echo "启动失败，日志尾部："; tail -n 12 "$LOGFILE" 2>/dev/null; rm -f "$PIDFILE"; exit 1
  fi
  ;;
stop)
  if running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do running || break; sleep 0.3; done
    running && kill -9 "$(cat "$PIDFILE")" 2>/dev/null
    echo "已停止"
  else
    echo "未运行"
  fi
  rm -f "$PIDFILE"
  ;;
restart) "$0" stop; "$0" start ;;
status)
  if running; then
    echo "运行中 (PID $(cat "$PIDFILE"))"
    alive_http && echo "HTTP 正常  $URL" || echo "HTTP 无响应（进程在但端口不通？）"
  else
    echo "未运行（bash tools/console.sh start 可启动）"
  fi
  [ -f "$LOGFILE" ] && { echo "--- 日志尾部 ---"; tail -n 3 "$LOGFILE"; }
  exit 0
  ;;
url) echo "$URL" ;;

check)
  echo "═══ 可视化 Agent 控制台 · 端到端自检 ═══"
  PASS=0; FAIL=0
  ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
  bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
  note() { printf '  ➖ %s\n' "$1"; }

  # ── A. 离线自检：不依赖已起的服务，直接跑一份完整快照 ──
  TMPJ="$(mktemp -t console-once.XXXXXX.json)"
  if ! (cd "$ROOT" && timeout 120 "$NODE" bridge/console-server.mjs --once > "$TMPJ" 2>/dev/null); then
    bad "console-server.mjs --once 退出异常"
  else
    ok "--once 能跑完并输出 JSON"
  fi

  eval "$("$NODE" -e '
    const fs = require("fs")
    let j = null
    try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) } catch (e) { j = null }
    const q = (s) => "\x27" + String(s).replace(/[\x27\\]/g, "") + "\x27"
    const p = []
    if (!j) { console.log("SESS=" + q("")) } else {
      console.log("SESS=" + q(j.session && j.session.file ? "1" : ""))
      console.log("STATE=" + q(j.agent && j.agent.state || ""))
      console.log("TL=" + (j.timeline ? j.timeline.length : 0))
      console.log("TLBAD=" + (j.timeline || []).filter((r) => !r.kind || !r.ts).length)
      console.log("TOOLS=" + (j.timeline || []).filter((r) => r.kind === "tool" && r.label && r.brief !== undefined).length)
      console.log("RUNNING=" + (j.timeline || []).filter((r) => r.kind === "tool" && r.running === true).length)
      console.log("RESULT=" + (j.timeline || []).filter((r) => r.kind === "tool" && r.result && typeof r.result.ms === "number").length)
      console.log("HEAVY=" + (j.stats && j.stats.lines > 0 ? "1" : ""))
      console.log("CTXWIN=" + ((j.tokens && j.tokens.contextWindow) || 0))
      console.log("SESSIONS=" + ((j.sessions || []).length))
      console.log("CURMARK=" + ((j.sessions || []).filter((s) => s.current).length))
      console.log("APP=" + (j.app && j.app.online ? "1" : ""))
      console.log("HEALTH=" + JSON.stringify(j.health || {}))
    }
  ' "$TMPJ")"

  [ -n "${SESS:-}" ] && ok "能定位当前会话文件（按**最后事件时间**选）" || bad "找不到会话文件（DSH_HOME=$(echo ~/.dsh)？）"
  case "${STATE:-}" in
    busy|waiting|idle) ok "状态机取值合法：$STATE" ;;
    *) bad "状态机取值异常：'${STATE:-空}'" ;;
  esac
  [ "${TL:-0}" -gt 0 ] && ok "时间线有条目：$TL 条" || bad "时间线为空"
  [ "${TLBAD:-1}" -eq 0 ] && ok "时间线每条都带 kind/ts" || bad "有 $TLBAD 条缺字段"
  [ "${TOOLS:-0}" -gt 0 ] && ok "工具行有中文标签与摘要：$TOOLS 条" || bad "工具行缺少标签/摘要"
  [ "${HEAVY:-}" = "1" ] && ok "全量统计完成（行数/解码耗时/工具分布）" || bad "全量统计缺失"
  [ "${CTXWIN:-0}" -gt 0 ] && ok "上下文窗口已知：$CTXWIN" || bad "上下文窗口为 0"
  [ "${SESSIONS:-0}" -gt 0 ] && ok "会话列表可用：$SESSIONS 个" || bad "会话列表为空"
  [ "${CURMARK:-0}" -eq 1 ] && ok "会话列表正确标记当前项" || bad "当前项标记数量=$CURMARK"

  if [ "${APP:-}" = "1" ]; then
    ok "副屏 App 在线（/status 可达）"
  else
    note "副屏 App 不在线（允许：只需起 App 才有画面/控制）"
  fi
  echo "  健康：${HEALTH:-{}}"

  # ── B. 在线自检：需要服务在跑 ──
  if ! running; then
    "$0" start >/dev/null 2>&1 || true
  fi
  if running && alive_http; then
    ok "HTTP 服务在跑：$URL"
    # ★ 别用 head 截断再比对：页面里的 CSS 很长，标题标记在 4KB 之后（第一版就栽在这）
    CODE_BODY=$(curl -s -m 5 "$URL")
    case "$CODE_BODY" in
      *"AGENT CONSOLE"*) ok "首页返回控制台页面（含标题标记，$(printf %s "$CODE_BODY" | wc -c) 字节）" ;;
      *) bad "首页内容不对（不是控制台页面？）" ;;
    esac
    SSE="$(timeout 3 curl -s -N "$URL"api/stream | head -c 2000)"
    case "$SSE" in
      *"event: state"*) ok "SSE 推流正常（收到 event: state）" ;;
      *) bad "SSE 没收到首帧" ;;
    esac
    FRAME="$(curl -s -m 6 -o /dev/null -w '%{http_code}:%{content_type}' "$URL"api/frame.jpg)"
    case "$FRAME" in
      200:image/jpeg) ok "副屏画面代理正常（$FRAME）" ;;
      502*) note "副屏画面取不到（App 未运行）：$FRAME" ;;
      *) bad "副屏画面代理异常：$FRAME" ;;
    esac
    SETOUT="$(curl -s -m 6 -X POST -H 'Content-Type: application/json' -d '{"q":"evil=1&reboot=1"}' "$URL"api/app/set)"
    case "$SETOUT" in
      *'"ok":false'*'"dropped"'*) ok "白名单生效：未知键被丢弃（"$SETOUT"）" ;;
      *) bad "白名单没拦住：$SETOUT" ;;
    esac
    INBOXOUT="$(curl -s -m 6 -X POST -H 'Content-Type: application/json' -d '{"text":"[自检] 收件箱连通性测试","note":"console.sh check"}' "$URL"api/inbox)"
    case "$INBOXOUT" in
      *'"ok":true'*) ok "收件箱可写（指令落盘通路；自检会追加一条带 note=console.sh check 的记录）" ;;
      *) bad "收件箱写入失败：$INBOXOUT" ;;
    esac
  else
    bad "HTTP 服务起不来（$LOGFILE 尾部见下）"
    tail -n 5 "$LOGFILE" 2>/dev/null | sed 's/^/     /'
  fi

  rm -f "$TMPJ"
  echo "───────────────────────────────"
  echo "  通过 $PASS 项，失败 $FAIL 项"
  [ "$FAIL" -eq 0 ] && { echo "  ✅ 全部通过"; exit 0; } || { echo "  ❌ 有失败项"; exit 1; }
  ;;
*)
  sed -n '2,12p' "$0"; exit 2 ;;
esac
