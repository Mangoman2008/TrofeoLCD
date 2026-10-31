#!/bin/sh
# dash_sync.sh —— 把 win_dash 审计外壳与 win/src 同步，并在虚拟机里重新渲染 + 主机侧核对。
#
# 为什么需要它：win_dash/src 是**给审计外壳用的 C# 源码副本**（不是交付物）。
# 它曾经停在 10-12：渲染出来的 4 张对照图是旧代码画的，而 verify.py 又按 480 断言，
# 等于"审计在验旧版本"。这个脚本每次重新同步 + 渲染，杜绝审计副本过期。
#
# 踩过的两个坑（所以脚本长这样）：
#   · 外壳只编"渲染链"那几个文件 —— Gui.cs / LcdRunner.cs 引用了外壳 Program 里没有的
#     Program.Version / Program.SaveIniValue，编进去必然 CS0117；
#   · VM 共享盘上旧文件删不掉/删不干净，**每次换新目录与新文件名**，否则会拿到上一轮的
#     exe、日志或对照图（"审计通过"其实是旧代码的结论）。
#
# 用法： sh tools/dash_sync.sh
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
SRC="$ROOT/win/src"
DASH="$ROOT/win_dash"
VDASH="$HOME/.VMDocs/.hwf_share/.disks/C/dshlcd_dash"
OUT="$DASH/out"
STAMP=$(date +%H%M%S)
VSRC="$VDASH/src-$STAMP"
mkdir -p "$OUT"

# 外壳的编译集：状态 + 令牌 + 画布 + JSON/日志（+ 外壳自己的 Program）
SET="Dashboard.cs Theme.cs State.cs Json.cs Log.cs SysMon.cs"

echo "== 1/4 同步源码（win/src → $STAMP 批次的审计副本）=="
rm -rf "$DASH/src"
mkdir -p "$DASH/src" "$VSRC"
for b in $SET; do
  cp "$SRC/$b" "$DASH/src/$b"
  cp "$SRC/$b" "$VSRC/$b"
done
cp "$DASH/harness/Program.harness.cs.txt" "$DASH/src/Program.cs"
cp "$DASH/harness/Program.harness.cs.txt" "$VSRC/Program.cs"
echo "   $(ls "$VSRC"/*.cs | wc -l) 个 .cs（$SET + 外壳 Program.cs）"

echo "== 2/4 生成 VM 侧构建脚本并注入 =="
python3 - "$VDASH" "$STAMP" <<'PYEOF'
import os, sys
v, stamp = sys.argv[1], sys.argv[2]
exe = 'dshlcd_dash_%s.exe' % stamp
log = 'dash-%s.log' % stamp
build = (
    '@echo off\r\n'
    'setlocal\r\n'
    'set HERE=%~dp0\r\n'
    'set OUT=%HERE%out\r\n'
    'set CSC=C:\\dshlcd\\roslyn\\csc.exe\r\n'
    'if not exist "%OUT%" mkdir "%OUT%"\r\n'
    'set LOG=%OUT%\\' + log + '\r\n'
    'echo === dash build %DATE% %TIME% === > "%LOG%"\r\n'
    'if not exist "%CSC%" ( echo [FAIL] roslyn not found >> "%LOG%" & exit /b 1 )\r\n'
    '"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 ^\r\n'
    '  /out:"%OUT%\\' + exe + '" ^\r\n'
    '  /reference:System.dll /reference:System.Drawing.dll ^\r\n'
    '  "%HERE%src-' + stamp + '\\*.cs" >> "%LOG%" 2>&1\r\n'
    'if errorlevel 1 ( echo [FAIL] compile failed >> "%LOG%" & exit /b 1 )\r\n'
    'echo [OK] compiled >> "%LOG%"\r\n'
    'for %%A in ("%OUT%\\' + exe + '") do echo size=%%~zA bytes >> "%LOG%"\r\n'
    'echo === dash render %DATE% %TIME% === >> "%LOG%"\r\n'
    '"%OUT%\\' + exe + '" --all >> "%LOG%" 2>&1\r\n'
    'echo [OK] rendered >> "%LOG%"\r\n')
open(os.path.join(v, 'dash.cmd'), 'w', encoding='ascii', newline='').write(build)
print('   dash.cmd → 产物 %s / 日志 %s / 源码 src-%s' % (exe, log, stamp))
PYEOF
timeout 300 python3 tools/win.py vm "cmd /c C:\\dshlcd_dash\\dash.cmd" >/dev/null 2>&1 || true

echo "== 3/4 等渲染（日志 dash-$STAMP.log）=="
i=0
while [ $i -lt 40 ]; do
  if grep -q "\[OK\] rendered\|\[FAIL\]" "$VDASH/out/dash-$STAMP.log" 2>/dev/null; then break; fi
  i=$((i+1)); sleep 3
done
grep -E "\[OK\]|\[FAIL\]|size=|error CS" "$VDASH/out/dash-$STAMP.log" 2>/dev/null | head -8
if ! grep -q "\[OK\] rendered" "$VDASH/out/dash-$STAMP.log" 2>/dev/null; then
  echo "  ❌ 渲染没完成，后面的核对无意义（对照图还是旧的）"
  exit 1
fi
for f in dash_h.jpg dash_v.jpg dash_h_novm.jpg dash_v_novm.jpg dash_h_empty.jpg dash_v_empty.jpg; do
  cp "$VDASH/out/$f" "$OUT/$f" && printf '   %s  %s B\n' "$f" "$(stat -c%s "$OUT/$f")"
done

echo "== 4/4 主机侧核对 =="
python3 win_dash/verify.py 2>&1 | tail -22
python3 win_dash/verify_frame.py "$OUT/dash_h.jpg" h 2>&1 | tail -6
# 竖装：verify_frame 要的是"真实光栅"（竖装内容已被 LcdRunner 旋转进 1920×462），
# 而外壳的 dash_v.jpg 是逻辑坐标直接画的 462×1920 —— 喂给它必然越界。
# 所以这里用 LcdRunner 真产出的那张（先跑 tools/win_verify.sh 生成 verify-v.jpg）。
REALV="$HOME/.VMDocs/.hwf_share/.disks/C/dshlcd/out/verify-v.jpg"
if [ -f "$REALV" ]; then
  python3 win_dash/verify_frame.py "$REALV" v 2>&1 | tail -6
else
  echo "  （跳过竖装 verify_frame：先跑 tools/win_verify.sh 生成真实光栅 verify-v.jpg）"
fi
