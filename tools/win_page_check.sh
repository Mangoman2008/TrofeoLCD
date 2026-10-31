#!/bin/sh
# win_page_check.sh —— 端到端验证「三个版本」的网页预览页与图标真的对齐了。
#
# 做法：在 Win11 虚拟机里启动 dshlcd（不碰 USB），用客户机自己的 curl 把
#   /        网页预览页
#   /status  状态 JSON
# 抓回来，然后在主机上：
#   1) 与唯一来源 web/preview.html 逐字节比对（两份手抄走样过，所以要钉死）
#   2) 核对 /status 字段集与鸿蒙版一致
#   3) 读 exe 的图标与版本信息（csc /win32icon + AssemblyInfo 是否真的生效）
#
# 用法： sh tools/win_page_check.sh [exe路径]
# 依赖： tools/win.py 的 VM 通道（livepad 输入注入）
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
VM="$HOME/.VMDocs/.hwf_share/.disks/C/dshlcd"
OUT="$VM/out"
EXE=${1:-C:\\dshlcd\\out\\dshlcd_arm64_v4.exe}
BASE=$(basename "$EXE" .exe)
TMP="$ROOT/.diag"; mkdir -p "$TMP"

echo "== 1/3 让虚拟机里的 exe 把页面吐出来（$BASE）=="
# 先删掉上一次的结果文件：否则下面等 "DONE" 会立刻命中旧文件，
# 读到的就是上一版 exe 的版本号与页面（会给出"假通过"，比不检查更糟）
rm -f "$OUT/pagecheck.txt" "$OUT/served-page.html" "$OUT/served-status.json"
python3 - "$VM" "$EXE" "$BASE" <<'PYEOF'
import io, os, sys
vm, exe, base = sys.argv[1], sys.argv[2], sys.argv[3]
body = r'''@echo off
set OUT=C:\dshlcd\out
echo === page check %DATE% %TIME% === > "%OUT%\pagecheck.txt"
powershell -NoProfile -Command "(Get-Item '%EXE%').VersionInfo | Format-List FileVersion,ProductVersion,ProductName" >> "%OUT%\pagecheck.txt" 2>&1
powershell -NoProfile -Command "Add-Type -AssemblyName System.Drawing; $i=[System.Drawing.Icon]::ExtractAssociatedIcon('%EXE%'); if($i){'ICON_OK ' + $i.Width + 'x' + $i.Height}else{'ICON_MISSING'}" >> "%OUT%\pagecheck.txt" 2>&1
taskkill /IM %BASE%.exe /F >nul 2>&1
start "" "%EXE%" --no-usb --vm-url none
ping -n 7 127.0.0.1 >nul
curl -s -m 6 http://127.0.0.1:54546/status -o "%OUT%\served-status.json"
curl -s -m 6 http://127.0.0.1:54546/ -o "%OUT%\served-page.html"
for %%A in ("%OUT%\served-page.html") do echo page %%~zA bytes >> "%OUT%\pagecheck.txt"
taskkill /IM %BASE%.exe /F >nul 2>&1
echo DONE >> "%OUT%\pagecheck.txt"
'''
body = body.replace('%EXE%', exe).replace('%BASE%', base)
open(os.path.join(vm, 'page-check.cmd'), 'w', encoding='ascii', newline='\r\n').write(body)
print('  已写入 page-check.cmd')
PYEOF
timeout 300 python3 tools/win.py vm "cmd /c C:\\dshlcd\\page-check.cmd" >/dev/null 2>&1

echo "== 2/3 等客户机回读 =="
i=0
while [ $i -lt 25 ]; do
  # 必须"比本次开始时间新"才算：光看 DONE 可能命中上一次的残留
  if [ -f "$OUT/pagecheck.txt" ] && grep -q DONE "$OUT/pagecheck.txt" 2>/dev/null; then break; fi
  i=$((i+1)); sleep 3
done
cat "$OUT/pagecheck.txt" 2>/dev/null | sed 's/^/  /'

echo "== 3/3 主机侧比对 =="
python3 - "$OUT" <<'PYEOF'
import io, json, os, sys
out = sys.argv[1]
tpl = io.open('web/preview.html', encoding='utf-8').read().rstrip('\n')
try:
    served = io.open(os.path.join(out, 'served-page.html'), encoding='utf-8').read().rstrip('\n')
except OSError:
    print('  ❌ 没抓到 served-page.html（exe 没起来？）'); sys.exit(1)
same = tpl == served
print(('  ✅ ' if same else '  ❌ ') + f'网页预览页逐字节一致（模板 {len(tpl.encode())} B / 服务返回 {len(served.encode())} B）')
if not same:
    for i, (a, b) in enumerate(zip(tpl, served)):
        if a != b:
            print(f'     首个差异 @{i}: 模板 {a!r} 服务 {b!r}'); break
    sys.exit(1)
# /status 字段集（鸿蒙侧的字段由 LcdService.statusJson 决定，这里列成基准）
ets = io.open('entry/src/main/ets/service/LcdService.ets', encoding='utf-8').read()
seg = ets[ets.find('private statusJson'):ets.find('diagJson(): string')]
import re
want = set(re.findall(r'"([A-Za-z][A-Za-z0-9_]*)"\s*:', seg))
got = set(json.load(io.open(os.path.join(out, 'served-status.json'), encoding='utf-8')))
print(('  ✅ ' if want == got else '  ❌ ') + f'/status 字段与鸿蒙一致（{len(want)} 项）'
      + ('' if want == got else f'  差集: 缺 {sorted(want-got)} 多 {sorted(got-want)}'))
sys.exit(0 if want == got else 1)
PYEOF
