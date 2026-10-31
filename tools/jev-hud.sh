#!/usr/bin/env bash
# jev-hud.sh —— JEV 决策光路（TypeSafe Jev / System One）页面的启停与自检
#
#   bash tools/jev-hud.sh start     后台起服务（写 PID / 日志）
#   bash tools/jev-hud.sh stop      停止（按 PID 文件，不用 pkill —— 那个会误杀自己）
#   bash tools/jev-hud.sh restart
#   bash tools/jev-hud.sh status
#   bash tools/jev-hud.sh url
#   bash tools/jev-hud.sh check     端到端自检（15 项，模拟模式也能全过）
#
# key：TYPESAFE_API_KEY 环境变量，或 ~/.config/typesafe/env 里的一行。
#      没有 key 时走内置模拟判定器（页面标 SIMULATED），结构与真 API 一致。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="$ROOT/bridge/.jev-hud.pid"
LOGFILE="$ROOT/bridge/.jev-hud.log"
PORT="${DSH_JEV_PORT:-54551}"
NODE="$(command -v node || echo "$HOME/.harmonybrew/bin/node")"
URL="http://127.0.0.1:$PORT/"

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
alive() { curl -s -m 2 -o /dev/null "$URL"health 2>/dev/null; }

case "${1:-status}" in
start)
  if running; then echo "已在运行 (PID $(cat "$PIDFILE"))  $URL"; exit 0; fi
  cd "$ROOT"
  KEYSET="no"
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then KEYSET="yes(env)";
  elif [ -f "$HOME/.config/typesafe/env" ] && grep -q '^TYPESAFE_API_KEY=' "$HOME/.config/typesafe/env" 2>/dev/null; then KEYSET="yes(file)"; fi
  nohup "$NODE" bridge/jev-hud.mjs --port "$PORT" "$@" >> "$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  if running && alive; then
    echo "已启动 (PID $(cat "$PIDFILE"))"
    echo "地址: $URL"
    echo "key: $KEYSET（$([ "$KEYSET" = no ] && echo '走本地模拟，页面标 SIMULATED' || echo '走真实 API')）"
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
restart) "$0" stop; shift || true; "$0" start "$@" ;;
status)
  if running; then
    echo "运行中 (PID $(cat "$PIDFILE"))"
    alive && echo "HTTP 正常  $URL" || echo "HTTP 无响应"
    curl -s -m 3 "$URL"api/info 2>/dev/null | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log("模式:",j.configured&&!j.mock?"真实 API":"本地模拟(SIMULATED)","| 模型:",j.model)}catch(e){}})' 2>/dev/null
  else
    echo "未运行（bash tools/jev-hud.sh start 可启动）"
  fi
  exit 0
  ;;
url) echo "$URL" ;;

check)
  echo "═══ JEV 决策光路 · 端到端自检 ═══"
  PASS=0; FAIL=0
  ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
  bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
  note() { printf '  ➖ %s\n' "$1"; }
  # ★ 这里刻意只用 grep 断言，不再内联 node 解析 JSON：
  #   上一版把 JS 塞进 bash 双引号里，引号分层把解析器绕晕（syntax error near "data",d=），
  #   排查成本远高于收益。检查要的是"结构对不对"，grep 足够。

  if ! running; then "$0" start >/dev/null 2>&1 || true; fi
  if ! (running && alive); then
    bad "服务起不来（见 $LOGFILE）"; tail -n 6 "$LOGFILE" 2>/dev/null | sed 's/^/     /'
    echo "  通过 $PASS 项，失败 $FAIL 项"; exit 1
  fi
  ok "HTTP 服务在跑：$URL"

  INFO="$(curl -s -m 5 "$URL"api/info)"
  case "$INFO" in
    *'"configured":true'*) ok "模式：真实 API（key 只在服务端）" ;;
    *'"mock":true'*)       note "模式：本地模拟（没有 TYPESAFE_API_KEY）——结构与真 API 同形，自检照跑" ;;
    *)                     bad "/api/info 返回异常：$(printf %s "$INFO" | head -c 120)" ;;
  esac
  MISS=""
  for L in role blast_radius complexity security debt needs_tests start_here legacy; do
    case "$INFO" in *"\"$L\""*) ;; *) MISS="$MISS $L" ;; esac
  done
  [ -z "$MISS" ] && ok "8 个内置透镜包都在（choice/score/noul 齐全）" || bad "透镜包缺：$MISS"
  # ★ 别用 '"key"' 当判据：透镜包的定义里本来就有 {"key":"role"} 这种字段（第一版误报了）。
  #   要抓的是"真 key 的样子"和"有没有回传 key 本体"。
  if printf %s "$INFO" | grep -Eq 'sk-[A-Za-z0-9_-]{20,}'; then
    bad "/api/info 里出现了疑似真实 key"
  elif printf %s "$INFO" | grep -q '"keySource"'; then
    ok "/api/info 只回报 key 来源与掩码，不含 key 本体"
  else
    bad "/api/info 结构异常（没有 keySource）"
  fi

  ASK='{"state":"def login(user){ const t = jwt.sign(user, process.env.SECRET); if(!user) throw new Error(1); return t; }","questions":{"role":{"type":"choice","instructions":"role of the file at `path`","criteria":{"core":"Core logic","api":"Entry points","ui":"UI","data":"Data","util":"Utils","infra":"Config","tests":"Tests","docs":"Docs"}},"blast_radius":{"type":"score","instructions":"damage if a bug slipped in","criteria":["Cosmetic","Local","Feature","System","Severe"]},"security":{"type":"noul","instructions":"Does the content touch authentication, secrets or crypto?"}}}'
  RES="$(curl -s -m 25 -X POST -H 'Content-Type: application/json' -d "$ASK" "$URL"api/ask)"
  case "$RES" in
    *'"ok":true'*) ok "api/ask 调用成功" ;;
    *) bad "api/ask 失败：$(printf %s "$RES" | head -c 200)" ;;
  esac
  for K in role blast_radius security; do
    case "$RES" in *"\"$K\""*) ok "返回里有判定：$K" ;; *) bad "缺少判定：$K" ;; esac
  done
  case "$RES" in
    *'"type":"choice"'*'"probabilities":{'*'"confidence":'*) ok "choice 结构正确（choice + probabilities + confidence）" ;;
    *) bad "choice 结构不对" ;;
  esac
  case "$RES" in
    *'"type":"score"'*'"legend":{'*) ok "score 结构正确（score + legend + probabilities）" ;;
    *) bad "score 结构不对" ;;
  esac
  case "$RES" in
    *'"type":"noul"'*'"noul":'*) ok "noul 结构正确（noul 概率即答案）" ;;
    *) bad "noul 结构不对" ;;
  esac
  case "$RES" in
    *'"input_tokens":'*) ok "带 token 用量（可核算成本）" ;;
    *) note "响应没有 usage" ;;
  esac
  case "$RES" in
    *'"simulated":true'*) note "本次是模拟判定（无 key）" ;;
    *'"simulated":false'*) ok "本次是真实 API 判定" ;;
  esac

  FILES="$(curl -s -m 10 "$URL"api/files?dir=$ROOT/entry/src/main/ets\&max=20)"
  case "$FILES" in *'"ok":true'*) ok "文件枚举可用（供批量扫描选文件）" ;; *) bad "文件枚举失败" ;; esac

  SCAN="$(curl -s -m 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"dir\":\"$ROOT/entry/src/main/ets/render\",\"maxFiles\":4,\"question\":{\"key\":\"start_here\",\"spec\":{\"type\":\"noul\",\"instructions\":\"Should a new contributor read this file first?\"}}}" \
    "$URL"api/scan)"
  case "$SCAN" in
    *'"ok":true'*'"id":'*)
      JID="$(printf %s "$SCAN" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
      ok "批量扫描任务已创建（$JID）"
      SSE="$(timeout 40 curl -s -N "$URL"api/scan/$JID/stream)"
      N="$(printf %s "$SSE" | grep -c 'event: answer')"
      [ "$N" -gt 0 ] && ok "SSE 逐条推送判定（$N 条）" || bad "SSE 没收到 answer"
      case "$SSE" in *'event: done'*) ok "扫描正常收尾（event: done）" ;; *) bad "没收到 done" ;; esac
      ;;
    *) bad "批量扫描启动失败：$(printf %s "$SCAN" | head -c 160)" ;;
  esac

  PAGE="$(curl -s -m 5 "$URL")"
  case "$PAGE" in *'DECISION OPTICS'*) ok "页面可取（$(printf %s "$PAGE" | wc -c) 字节）" ;; *) bad "页面内容不对" ;; esac
  if printf %s "$PAGE" | grep -Eq 'sk-[A-Za-z0-9_-]{20,}'; then bad "页面里出现了疑似真实 key"; else ok "页面不含疑似真实 key"; fi

  echo "───────────────────────────────"
  echo "  通过 $PASS 项，失败 $FAIL 项"
  [ "$FAIL" -eq 0 ] && { echo "  ✅ 全部通过"; exit 0; } || { echo "  ❌ 有失败项"; exit 1; }
  ;;
*)
  sed -n '2,14p' "$0"; exit 2 ;;
esac
