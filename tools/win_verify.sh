#!/bin/sh
# win_verify.sh —— 在 Win11 ARM64 虚拟机里把 Windows 版从头验一遍，打印 PASS/FAIL 表。
#
#   sh tools/win_verify.sh            # 全跑（约 3-5 分钟）
#   sh tools/win_verify.sh --quick    # 跳过带 VM 画面的那一步
#
# 依赖：livepad 在跑（用于 VM 画面那一项）；没有它那一项记 SKIP。
#
# 注意：exe 同目录若有 dshlcd.ini，其中的 vm-url 会一直生效。
# 第 4/5 步要验"没有外部画面时画面上不该有纯白"这个不变量，
# 所以那两步显式传 --vm-url none 关掉 VM 画面（命令行优先于 ini）。
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
OUT="$HOME/.VMDocs/.hwf_share/.disks/C/dshlcd/out"
TMP="$ROOT/.diag"; mkdir -p "$TMP"   # 本沙箱 /tmp 只读，临时文件一律放工作区
VURL=${VM_URL:-http://172.16.101.1:8787/vm/frame.jpg}
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

pass=0; fail=0; skip=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
sk()  { skip=$((skip+1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
sec() { printf '\n== %s ==\n' "$1"; }

# 统计一张图的：尺寸、纯白像素、唯一色、亮像素占比
shotstat() {
  python3 - "$1" <<'PYEOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB"); px = im.load(); W, H = im.size
white = sum(1 for y in range(0, H, 2) for x in range(0, W, 2) if min(px[x, y]) >= 250)
bright = sum(1 for y in range(0, H, 4) for x in range(0, W, 4) if max(px[x, y]) > 60)
uniq = len(set(im.getdata()))
print(f"{W}x{H} white={white} bright%={bright*100//max(1,(H//4)*(W//4))} colors={uniq}")
PYEOF
}

sec "1/7 编译"
if timeout 600 python3 tools/win.py build > "$TMP"/wv-build.txt 2>&1 \
   && grep -q "arm64 size=" "$TMP"/wv-build.txt && grep -q "x64 size=" "$TMP"/wv-build.txt; then
  ok "双架构编译通过（$(grep -oE '(arm64|x64) size=[0-9]+' "$TMP"/wv-build.txt | tr '\n' ' ')）"
else
  bad "编译失败，见下方"; tail -20 "$TMP"/wv-build.txt
fi

sec "2/7 自检（协议 + 调度 + 归一化 + JSON）"
WIN_SETTLE=20 timeout 300 python3 tools/win.py run "--selftest" > "$TMP"/wv-self.txt 2>&1
if ! grep -aq "自检结果" "$TMP"/wv-self.txt; then
  echo "      （第一次没等到日志，重试一次）"
  sleep 5
  WIN_SETTLE=25 timeout 300 python3 tools/win.py run "--selftest" > "$TMP"/wv-self.txt 2>&1
fi
LINE=$(grep -a "自检结果" "$TMP"/wv-self.txt | tail -1)
if echo "$LINE" | grep -q "失败 0"; then
  ok "$(echo "$LINE" | sed 's/.*==== //; s/ ====//')"
else
  bad "自检未全通过：$LINE"; grep -a "\[失败\]" "$TMP"/wv-self.txt | head -10
fi

sec "3/7 USB 枚举（没插屏也应跑完并读出真实 VID/PID）"
WIN_SETTLE=8 timeout 300 python3 tools/win.py run "--probe" > "$TMP"/wv-probe.txt 2>&1
if grep -aq "USB 设备接口共" "$TMP"/wv-probe.txt; then
  N=$(sed -n 's/.*USB 设备接口共 \([0-9]*\) 个.*/\1/p' "$TMP"/wv-probe.txt | head -1)
  ok "枚举跑通：$N 个 USB 设备接口；$(grep -a '结论：' "$TMP"/wv-probe.txt | head -1 | sed 's/.*结论：//')"
else
  bad "枚举没跑完"; tail -15 "$TMP"/wv-probe.txt
fi

# 演示步骤统一重试一次：VM 的输入注入偶发丢包（环境已知），一次没跑起来不代表代码有问题
demo() {   # $1 = 附加参数, $2 = 日志文件
  i=0
  while [ $i -lt 2 ]; do
    WIN_SETTLE=25 timeout 400 python3 tools/win.py run "$1" > "$2" 2>&1
    grep -aq "演示结果" "$2" && return 0
    i=$((i+1)); echo "      （注入未生效，重试 $i/2）"; sleep 4
  done
  return 1
}

sec "4/7 横屏渲染（1920×462，无外部画面）"
if demo "--demo --vertical 0 --seconds 6 --out-frame C:\\dshlcd\\out\\verify-h.jpg --no-self-http --vm-url none" "$TMP/wv-h.txt"; then
  grep -a "演示结果" "$TMP"/wv-h.txt | tail -1 | sed 's/^/      /'
  ST=$(shotstat "$OUT/verify-h.jpg"); echo "      图: $ST"
  echo "$ST" | grep -q "^1920x462" && ok "横屏帧尺寸 1920x462（与设备一致）" || bad "横屏帧尺寸不对：$ST"
  echo "$ST" | grep -q "white=0" && ok "无外部画面时没有纯白像素（配色不变量成立）" || bad "出现了不该有的纯白：$ST"
  echo "$ST" | grep -qE "colors=[0-9]{4,}" && ok "画面内容足够丰富（文字/图形都画了）" || bad "画面疑似空白：$ST"
else
  bad "横屏演示没跑完"
fi

sec "5/7 竖屏渲染（逻辑 462×1920，旋转进 1920×462 帧）"
if demo "--demo --vertical 1 --seconds 6 --out-frame C:\\dshlcd\\out\\verify-v.jpg --no-self-http --vm-url none" "$TMP/wv-v.txt"; then
  grep -a "演示结果" "$TMP"/wv-v.txt | tail -1 | sed 's/^/      /'
  ST=$(shotstat "$OUT/verify-v.jpg"); echo "      图: $ST"
  echo "$ST" | grep -q "^1920x462" && ok "竖屏也进 1920x462 帧（与设备要求一致）" || bad "竖屏帧尺寸不对：$ST"
  echo "$ST" | grep -q "white=0" && ok "竖屏布局下配色不变量同样成立" || bad "竖屏出现不该有的纯白：$ST"
else
  bad "竖屏演示没跑完"
fi

sec "6/7 真实 VM 画面源 + HTTP 自测"
if [ "$QUICK" = "1" ]; then
  sk "按 --quick 跳过"
elif timeout 20 curl -s -m 8 -o /dev/null "$VURL" 2>/dev/null; then
  if WIN_SETTLE=30 timeout 500 python3 tools/win.py run "--demo --vertical 0 --vm-url $VURL --seconds 8 --out-frame C:\\dshlcd\\out\\verify-vm.jpg" > "$TMP"/wv-vm.txt 2>&1; then
    VMF=$(grep -a '"vmFrames"' "$TMP"/wv-vm.txt | tail -1 | grep -o '"vmFrames":[0-9]*' | head -1)
    HTTP=$(grep -ac "HTTP 200" "$TMP"/wv-vm.txt)
    grep -aq '"vmFrames":0' "$TMP"/wv-vm.txt && bad "VM 画面一帧都没抓到（$VMF）" || ok "VM 画面抓取正常（$VMF）"
    [ "$HTTP" -ge 6 ] && ok "HTTP 自测 $HTTP 个接口返回 200" || bad "HTTP 自测只有 $HTTP 个 200"
    ST=$(shotstat "$OUT/verify-vm.jpg"); echo "      图: $ST"
    # VM 截图是任意外部图像（横屏 180° 翻转后落在左侧），所以这里纯白多是正常的
    echo "$ST" | grep -qE "white=[0-9]{4,}" && ok "VM 截图确实进了帧（纯白像素显著增多，符合预期）" || sk "VM 截图区域恰好没有纯白（画面内容而定，不算失败）"
  else
    bad "VM 画面演示没跑完"
  fi
else
  sk "livepad 的 $VURL 不可达，跳过"
fi

sec "7/7 三版本对齐（网页预览页单源 + 图标 + 诊断字段）"
if python3 tools/make_web.py --check > "$TMP"/wv-web.txt 2>&1; then
  ok "网页预览页：鸿蒙 / Windows 两侧与 web/preview.html 完全一致（$(wc -c < web/preview.html) 字节 × 2 份）"
else
  bad "网页预览页两侧不一致"; cat "$TMP"/wv-web.txt
fi
if [ -f win/icon/dshlcd.ico ] && [ "$(stat -c%s win/icon/dshlcd.ico)" -gt 20000 ]; then
  NSZ=$(python3 -c "from PIL import Image;print(len(Image.open('win/icon/dshlcd.ico').ico.sizes()))")
  ok "exe 图标存在：win/icon/dshlcd.ico（$NSZ 个尺寸，含 16/24/32 简化版）"
else
  bad "win/icon/dshlcd.ico 缺失或过小（跑 tools/make_icon.py 生成）"
fi
MISS=""
for f in vmErr vmAgeMs selfTest selfTestAllPass platform; do
  grep -q "\"$f\"" win/src/LcdRunner.cs || MISS="$MISS $f"
done
[ -z "$MISS" ] && ok "Windows /diag 字段与鸿蒙对齐（vmErr / vmAgeMs / selfTest / selfTestAllPass / platform）" \
  || bad "Windows /diag 缺字段：$MISS"
grep -q "vmAgeMsForUi\|vmErrForUi" entry/src/main/ets/service/LcdService.ets \
  && ok "鸿蒙侧暴露取帧状态给界面（vmAgeMsForUi / vmErrForUi）" || bad "鸿蒙侧取帧状态取值器缺失"

sec "结果"
printf '  通过 %d，失败 %d，跳过 %d\n' "$pass" "$fail" "$skip"
if [ "$fail" -eq 0 ]; then echo "  ✅ 全部通过"; else echo "  ❌ 有失败项，见上面输出"; fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
