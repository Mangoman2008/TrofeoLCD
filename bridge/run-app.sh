#!/usr/bin/env bash
# run-app.sh —— 一条命令把「数据桥 + 屏幕 App」都拉起来
#
# ## 为什么现在这么简单
# 数据桥已经从**外部 node 脚本**改成 **DSH 插件**（见 docs/进程内数据桥与运行时自检.md）：
# 插件随 DSH 进程自动启动，在进程内解压会话文件并 UDP 推给屏幕 App。
# 所以"拉起数据桥"这件事**不需要单独执行** —— DSH 开着，桥就在推。
#
# 这个脚本负责剩下的确定性工作：
#   1. 确保插件已安装并注册（不足就自动装）
#   2. 把屏幕 App 拉到前台（设备就是本机，走 hdc 127.0.0.1）
#   3. 用 App 的 /diag 验证**遥测真的在推**，而不是"以为在推"
#
# 用法：
#   ./run-app.sh                  # 装插件（如需）+ 起 App + 验证
#   ./run-app.sh --install        # 顺带把最新构建的 HAP 重装到设备
#   ./run-app.sh --no-app         # 只保证桥就绪，不碰 App
#   ./run-app.sh --verify         # 只做验证（什么都不启动）
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BUNDLE="${TROFEO_BUNDLE:-com.dsh.trofeolcd}"
ABILITY="${TROFEO_ABILITY:-EntryAbility}"
HAP="$REPO/.build-output/entry-default-signed.hap"
HDC="${HDC:-$(command -v hdc || echo "$HOME/.harmonybrew/bin/hdc")}"
DIAG_URL="http://127.0.0.1:54546/diag"
PLUGIN_SETUP="$REPO/dsh-plugin/setup.sh"
DO_INSTALL=0
DO_APP=1

for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=1 ;;
    --no-app)  DO_APP=0 ;;
    --verify)  DO_APP=0 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

say() { printf '  %s\n' "$*"; }
ok()  { printf '  ✅ %s\n' "$*"; }
warn(){ printf '  ⚠️  %s\n' "$*"; }
err() { printf '  ❌ %s\n' "$*"; }

# ── 找一个能用的 hdc 目标（本机无线调试端口会变，所以扫一遍）──
pick_target() {
  local t
  t=$("$HDC" list targets 2>/dev/null | grep -v '^\[Empty\]' | head -1 | tr -d '\r')
  if [ -z "$t" ]; then
    # 本机无线调试：试几个常见端口
    for p in 40601 39569 37651 38851; do
      if "$HDC" tconn "127.0.0.1:$p" >/dev/null 2>&1; then
        t=$("$HDC" list targets 2>/dev/null | grep -v '^\[Empty\]' | head -1 | tr -d '\r')
        [ -n "$t" ] && break
      fi
    done
  fi
  printf '%s' "$t"
}

# ── 读 App 的 /diag，判断遥测到底有没有在推 ──
check_diag() {
  local d
  d=$(curl -s --max-time 5 "$DIAG_URL" 2>/dev/null || true)
  if [ -z "$d" ]; then
    return 2   # App 没在跑
  fi
  if command -v python3 >/dev/null 2>&1; then
    # ★ 用**命令行参数**传 JSON，不要用管道：
    #   `python3 - <<'PY'` 这种 heredoc 会把 stdin 占成"脚本内容"，
    #   于是 `printf '%s' "$d" | python3 -` 的管道数据**进不去**
    #   （实测：手动跑能解析、脚本里恒报 "/diag 不是合法 JSON"）。
    python3 - "$d" <<'PY'
import sys, json
raw = sys.argv[1] if len(sys.argv) > 1 else ''
try:
    d = json.loads(raw)
except Exception:
    print('  ⚠️ /diag 不是合法 JSON'); raise SystemExit(3)
def mk(ok): return '✅' if ok else '❌'
age = d.get('bridgeAgeSec')
age_ok = isinstance(age, (int, float)) and 0 <= age <= 15
pk = d.get('telemetryPackets')
print(f"  {mk(age_ok)} 数据桥遥测: {age}s 前收到 / 累计 {pk} 包")
print(f"  {mk(d.get('usbOpen'))} USB 屏幕: {d.get('device') or '未连接'}")
print(f"  {mk((d.get('sent') or 0) > 0)} 推帧: sent={d.get('sent')} errors={d.get('errors')}")
print(f"  {mk(d.get('selfTestAllPass'))} 协议自检: {d.get('selfTest')}")
if not age_ok:
    print('')
    # 区分两种情况，避免"其实只是没重启"被误读成故障
    import os, glob
    prof = os.environ.get('DSH_PROFILE', 'web')
    pkg = os.path.expanduser('~/.dsh/profiles/%s/package.json' % prof)
    registered = False
    try:
        import json as _j
        _d = _j.load(open(pkg, encoding='utf-8'))
        registered = bool(_d.get('dependencies', {}).get('dsh-lcd-bridge')) and \
            'dsh-lcd-bridge' in (_d.get('dsh', {}).get('profile', {}).get('bundles', []) or [])
    except Exception:
        pass
    if registered:
        print('  → 插件已装好，但**当前运行的 DSH 进程还没加载它**（插件在 DSH 启动时加载）。')
        print('     解决：重启 DSH 即可。重启后本项应变为 ✅。')
    else:
        print('  → 插件未正确安装。跑一次： dsh-plugin/setup.sh')
        print('     它会写 profile 的 dependencies + dsh.profile.bundles 两处（缺一不可）。')
raise SystemExit(0 if age_ok else 4)
PY
    return $?
  else
    say "(没有 python3，原始 /diag)"
    printf '%s\n' "$d" | head -c 400
    return 0
  fi
}

echo "════ TrofeoLCD · 启动数据桥 + 屏幕 App ════"

# ── 1. 数据桥（DSH 插件）──
say ""
say "── 1/3 数据桥（DSH 插件）──"
if [ -x "$PLUGIN_SETUP" ]; then
  bash "$PLUGIN_SETUP" --install 2>&1 | sed 's/^/  /' | grep -vE '^\s*$' || true
else
  warn "找不到 $PLUGIN_SETUP，跳过插件安装"
fi

# DSH 是否在跑？（插件要 DSH 在跑才有数据）
if pgrep -f 'dsh/lib/bin.js' >/dev/null 2>&1; then
  ok "DSH 正在运行（插件应已随之加载）"
else
  warn "DSH 没在运行 —— **数据桥不会推数据**，请先启动 DSH"
fi

# ── 2. App ──
say ""
say "── 2/3 屏幕 App ──"
TARGET="$(pick_target)"
if [ -z "$TARGET" ]; then
  err "没有 hdc 设备（本机要开：设置 → 系统 → 开发者选项 → 无线调试）"
  warn "跳过 App 相关步骤；桥的部分见上面"
  exit 1
fi
ok "设备: $TARGET"

if [ "$DO_INSTALL" -eq 1 ]; then
  if [ -f "$HAP" ]; then
    say "重装 HAP: $(basename "$HAP") ($(stat -c%s "$HAP") bytes)"
    timeout 240 "$HDC" -t "$TARGET" install -r "$HAP" 2>&1 | tail -3 | sed 's/^/  /'
  else
    err "找不到 $HAP（先跑 tools/cli_build.sh）"
  fi
fi

if [ "$DO_APP" -eq 1 ]; then
  # 不重装时如果没装过，提示一下
  if ! timeout 40 "$HDC" -t "$TARGET" shell "bm dump -a" 2>/dev/null | grep -q "$BUNDLE"; then
    err "设备上没装 $BUNDLE —— 加 --install 重装，或先 tools/cli_build.sh"
    exit 1
  fi
  timeout 60 "$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY" 2>&1 | tail -2 | sed 's/^/  /'
  ok "已请求启动 $BUNDLE"
  say "等 App 起来（3s）…"
  sleep 3
else
  say "（--no-app/--verify：不动 App）"
fi

# ── 3. 验证 ──
say ""
say "── 3/3 验证 ──"
sleep 2
check_diag
rc=$?
if [ "$rc" -eq 2 ]; then
  warn "读不到 $DIAG_URL —— App 没在运行（或端口被占）"
  warn "先确认 App 已启动；若刚重启过 DSH，稍等几秒再试"
elif [ "$rc" -eq 0 ]; then
  ok "遥测在推，链路正常"
else
  warn "见上面的诊断结论"
fi

say ""
say "提示：屏幕上的「运行时体检」一行会显示同样的结论（设备卡里）。"
exit 0
