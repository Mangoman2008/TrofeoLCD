#!/usr/bin/env bash
# setup.sh —— 一条命令把「进程内数据桥」装好
#
# 背景：原来屏幕的遥测靠一个**外部 node 脚本**（bridge/start.sh + dsh-bridge.mjs +
# zstd.exe）。现在改成 **DSH 插件**（dsh-plugin/dsh-lcd-bridge），随 DSH 进程启动，
# 在进程内解压会话文件（DSH 的 node 原生带 zstd），直接 UDP 推给屏幕 App。
# 所以：
#   · 不需要再跑 ./start.sh
#   · 不需要 zstd.exe / node 脚本
#   · DSH 一起来，数据桥就在推
#
# 这个脚本负责"安装"这一步（把插件放进 profile 并注册）。装完重启 DSH 生效。
#
# 用法：
#   ./setup.sh            安装/更新插件 + 重启 DSH
#   ./setup.sh --install  只安装（不重启 DSH，等你自己重启）
#   ./setup.sh --uninstall 卸载插件（恢复 profile 配置）
#   ./setup.sh --verify   只检查当前状态
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PLUGIN_SRC="$HERE/dsh-lcd-bridge"
PROFILE="${DSH_PROFILE:-web}"
PROFILE_DIR="$HOME/.dsh/profiles/$PROFILE"
NM="$PROFILE_DIR/node_modules"
PATCH="$PROFILE_DIR/cordis.patch.yml"
NAME="dsh-lcd-bridge"
MARK="# ---- $NAME (installed by dsh-plugin/setup.sh) ----"

say() { printf '  %s\n' "$*"; }
ok()  { printf '  ✅ %s\n' "$*"; }
warn(){ printf '  ⚠️  %s\n' "$*"; }
err() { printf '  ❌ %s\n' "$*"; }

need() {
  if [ ! -d "$PROFILE_DIR" ]; then
    err "找不到 profile 目录: $PROFILE_DIR"
    err "（用 DSH_PROFILE=<名字> 指定，或先在 DevEco/DSH 里建一个 profile）"
    exit 1
  fi
  if [ ! -f "$PLUGIN_SRC/index.mjs" ]; then
    err "找不到插件源码: $PLUGIN_SRC/index.mjs"
    exit 1
  fi
}

# 把注册项写进 profile 的 cordis.patch.yml（幂等）
register() {
  if grep -q "id: $NAME" "$PATCH" 2>/dev/null; then
    ok "profile 里已注册（跳过注册步骤）"
    return 0
  fi
  # 先备份，便于回滚
  if [ ! -f "$PATCH.bak-$NAME" ]; then
    cp "$PATCH" "$PATCH.bak-$NAME"
    say "已备份 profile 配置 → $(basename "$PATCH").bak-$NAME"
  fi
  # 顶层数组项，`- insert:` 顶格；子项 4/6 空格（错缩进会被 YAML 解析器拒绝）
  {
    printf '%s\n' "$MARK"
    printf '%s\n' '- insert:'
    printf '    - id: %s\n' "$NAME"
    printf '      name: %s\n' "$NAME"
  } >> "$PATCH"
  ok "已注册到 $(basename "$PATCH")"
}

# ★ 正规安装：走 dsh 自己的 plugin 命令（底层是 pnpm add）。
#
# 为什么不能只复制文件 + 手写 cordis.patch.yml（实测踩过）：
#   那样 DSH 启动时会**预检阻断**：
#     [阻断] dsh-lcd-bridge@? — bundles 里引用了但没装
#   因为 DSH 的 profile 有**两处**声明：package.json 的 dependencies（谁装进来了）
#   和 dsh.profile.bundles（谁要被加载）。只塞 node_modules 两处都不满足。
#   `dsh plugin add` 会把 file: 依赖写进 dependencies、装进 node_modules，
#   并自动把包名加进 bundles。
install_plugin() {
  # ★ 本机 `dsh plugin add` **不可靠**（审计 2026-10-16 实测）：
  #   pnpm 用硬链接把文件"import"进 node_modules，在本机文件系统上会报
  #   `Operation not permitted (os error 1)`，而且每次卡在不同文件上
  #   （先 bridge-standalone.mjs，后 cordis.patch.yml）。
  #   更坑的是它**先删旧副本再拷**，一旦失败就把插件目录留空 →
  #   DSH 一重启就因缺文件加载失败（实测踩过）。
  #
  # 所以改成：**直接复制**是主路径（node 解析插件只看 node_modules 里的文件），
  # 声明（dependencies + bundles）用 Python 精确维护，
  # 最后校验「文件 + 两处声明」三样都对才算成功。
  local D="$HOME/.dsh/profiles/web/node_modules/$NAME"
  local PKG="$HOME/.dsh/profiles/web/package.json"
  local FILES="index.mjs session.mjs printer.mjs balance.mjs package.json cordis.patch.yml"

  mkdir -p "$D"
  local missing_src=0
  for f in $FILES; do
    if [ ! -f "$PLUGIN_SRC/$f" ]; then
      err "源文件缺失: $PLUGIN_SRC/$f"
      missing_src=1
    fi
  done
  [ "$missing_src" -eq 0 ] || return 1

  say "复制插件文件 → $D"
  # shellcheck disable=SC2086
  cp -f $(for f in $FILES; do printf '%s ' "$PLUGIN_SRC/$f"; done) "$D/" || {
    err "复制失败"; return 1; }

  say "维护 profile 的 dependencies + bundles 声明"
  PYTHONWARNINGS=ignore "$(command -v python3 || echo python3)" - "$PKG" "$NAME" "$PLUGIN_SRC" <<'PY' || return 1
import json, sys, os, tempfile
pkg, name, src = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(pkg, encoding='utf-8'))
d.setdefault('dependencies', {})[name] = 'file:' + src
prof = d.setdefault('dsh', {}).setdefault('profile', {})
bl = prof.setdefault('bundles', [])
if name not in bl:
    bl.append(name)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(pkg), suffix='.json')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write('\n')
os.replace(tmp, pkg)
print('    dependencies / bundles 已写入')
PY

  # 三样都校验：文件在 + dependencies + bundles
  local bad=0
  for f in $FILES; do
    [ -f "$D/$f" ] || { err "缺文件 $f"; bad=1; }
  done
  "$(command -v python3 || echo python3)" - "$PKG" "$NAME" <<'PY' || bad=1
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
n = sys.argv[2]
ok1 = d.get('dependencies', {}).get(n) is not None
ok2 = n in d.get('dsh', {}).get('profile', {}).get('bundles', [])
print(f'    dependencies={"✅" if ok1 else "❌"}  bundles={"✅" if ok2 else "❌"}')
sys.exit(0 if (ok1 and ok2) else 1)
PY
  if [ "$bad" -ne 0 ]; then
    err "安装校验未通过"
    return 1
  fi
  ok "安装完成（文件 + dependencies + bundles 三项均已校验）"
  return 0
}

# 校验 profile 的 patch 文件仍是合法 YAML（缩进写错会直接让 DSH 起不来）
validate_yaml() {
  local D="$HOME/npm/lib/node_modules/dsh-harmonyos/node_modules/@deepseek-ai/dsh/lib/bin.js"
  local NODE_BIN="$HOME/.harmonybrew/opt/node/bin/node"
  [ -x "$NODE_BIN" ] || NODE_BIN="$(command -v node || true)"
  [ -n "$NODE_BIN" ] || { warn "找不到 node，跳过 YAML 校验"; return 0; }
  [ -f "$D" ] || { warn "找不到 dsh 的 bin.js，跳过 YAML 校验"; return 0; }
  "$NODE_BIN" -e "
    const fs=require('node:fs'), {createRequire}=require('node:module');
    const req=createRequire('$D');
    let YAML=null; for (const m of ['yaml','js-yaml']) { try { YAML=req(m); break } catch {} }
    if(!YAML){ process.exit(0) }
    try { const d=(YAML.parse||YAML.load)(fs.readFileSync('$PATCH','utf8'));
      if(!Array.isArray(d)) { console.log('  ❌ patch 顶层不是数组'); process.exit(1) }
      console.log('  ✅ patch YAML 合法（'+d.length+' 项）');
    } catch(e) { console.log('  ❌ patch YAML 错误: '+e.message); process.exit(1) }
  " || exit 1
}

restart_dsh() {
  # 正在跑的 DSH 占着 3080；插件改动要重启才生效。
  # 这里只**提示**，不擅自杀掉用户正在用的 GUI 进程。
  local n
  n=$( (pgrep -f 'dsh/lib/bin.js' 2>/dev/null || true) | wc -l )
  if [ "$n" -gt 0 ]; then
    warn "检测到 $n 个 DSH 进程在跑 —— **插件要重启 DSH 才生效**"
    say  "请你手动重启 DSH（关掉再打开），之后数据桥即随 DSH 自动启动"
  else
    ok "没有 DSH 在跑，下次启动 DSH 时插件会自动加载"
  fi
}

verify() {
  say "── 安装状态 ──"
  [ -d "$NM/$NAME" ] && ok "插件已安装: $NM/$NAME" || err "插件未安装"
  # ★ 注册状态要看**两处**（见文件头说明）：dependencies + dsh.profile.bundles。
  #   早先这里查的是 cordis.patch.yml 里的手工注册行 —— 那种做法会被 DSH 预检阻断，
  #   正规安装根本不写 patch，所以老判据会误报"未注册"。
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PROFILE_DIR/package.json" "$NAME" <<'PYX'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception as e:
    print('  ❌ 读不到 profile package.json: %s' % e); raise SystemExit(1)
name = sys.argv[2]
dep = d.get('dependencies', {}).get(name)
bun = name in (d.get('dsh', {}).get('profile', {}).get('bundles', []) or [])
print('  %s dependencies 已声明: %s' % ('✅' if dep else '❌', dep or '无'))
print('  %s bundles 已包含: %s' % ('✅' if bun else '❌', '是' if bun else '否'))
raise SystemExit(0 if (dep and bun) else 1)
PYX
  else
    grep -q "\"$NAME\"" "$PROFILE_DIR/package.json" && ok "profile 里有声明" || err "profile 里没有声明"
  fi

  say ""
  say "── 遥测是否有在推 ──"
  # 屏幕 App 的 UDP 口；用 ss 看不到 UDP 收包计数，改看 App 的 HTTP 诊断
  local diag
  diag=$(curl -s --max-time 4 http://127.0.0.1:54546/diag 2>/dev/null || true)
  if [ -z "$diag" ]; then
    warn "读不到屏幕 App 的 /diag（App 没在跑？端口 54546）"
  else
    python3 - "$diag" <<'PY' 2>/dev/null || echo "  （需要 python3 才能解析 /diag）"
import sys, json
try: d=json.loads(sys.argv[1])
except Exception: print('  ⚠️ /diag 不是合法 JSON'); raise SystemExit
age=d.get('bridgeAgeSec'); pk=d.get('telemetryPackets')
# ★ -1 表示"从未收到过"，必须算失败（之前写成 `age is not None` 会把 -1 当通过）
def mark(ok): return '✅' if ok else '❌'
age_ok = isinstance(age,(int,float)) and 0 <= age <= 15
print(f"  {mark(age_ok)} 数据桥: {age}s 前收到 / 累计 {pk} 包")
print(f"  {mark(d.get('usbOpen'))} USB: {d.get('device') or '未连接'}")
print(f"  {mark((d.get('sent') or 0) > 0)} 推帧: sent={d.get('sent')} errors={d.get('errors')}")
print(f"  {mark(d.get('selfTestAllPass'))} 协议自检: {d.get('selfTest')}")
PY
  fi
}

uninstall_plugin() {
  rm -rf "$NM/$NAME"
  ok "插件目录已删除"
  if [ -f "$PATCH.bak-$NAME" ]; then
    cp "$PATCH.bak-$NAME" "$PATCH"
    ok "profile 配置已从备份恢复"
  else
    # 没有备份就精确删掉我们加的那几行
    if grep -q "id: $NAME" "$PATCH" 2>/dev/null; then
      python3 - "$PATCH" "$NAME" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
lines = open(p, encoding='utf-8').read().split('\n')
out, skip = [], 0
for l in lines:
    if skip > 0:
        skip -= 1
        continue
    if l.strip() == '- insert:' and name in '\n'.join(lines[lines.index(l):lines.index(l)+3]):
        skip = 3
        continue
    if name in l:
        continue
    out.append(l)
open(p, 'w', encoding='utf-8').write('\n'.join(out))
print('  ✅ 已从 patch 里移除注册项')
PY
    fi
  fi
  warn "重启 DSH 后生效"
}

# ───────────────────────── main ─────────────────────────
echo "════ TrofeoLCD 进程内数据桥 · 安装 ════"
case "${1:-}" in
  --uninstall) need; uninstall_plugin; verify; exit 0 ;;
  --verify)    need; verify; exit 0 ;;
  --install)
    need; install_plugin || exit 1; verify
    warn "还没重启 DSH —— 重启后插件才会加载"
    exit 0 ;;
  "")
    need; install_plugin || exit 1; verify; restart_dsh
    exit 0 ;;
  *) err "未知参数: $1（用 --install/--uninstall/--verify）"; exit 2 ;;
esac
