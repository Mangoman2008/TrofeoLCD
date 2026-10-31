#!/usr/bin/env bash
# 从运行中的应用取当前帧（应用需已启动；监听 127.0.0.1:54546）
#
# 用途：本沙箱读不到系统 hilog，这个脚本让"应用到底渲染出了什么"可以被外部验证——
# 不需要接屏幕，也不需要复制日志。
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$D/.build-output/frame.jpg"
PORT="${1:-54546}"
mkdir -p "$D/.build-output"

echo "=== /status ==="
curl -s -m 6 "http://127.0.0.1:$PORT/status" 2>&1 | head -c 600; echo
echo "=== /frame.jpg ==="
code=$(curl -s -m 8 -o "$OUT" -w '%{http_code}' "http://127.0.0.1:$PORT/frame.jpg" 2>/dev/null)
if [ "$code" != "200" ]; then
  echo "❌ 取帧失败 (HTTP $code)"
  echo "   应用未运行 / 未启用远程预览 / 端口被占用"
  exit 1
fi
python3 - "$OUT" <<'PY'
import sys, struct, os
p = sys.argv[1]
data = open(p, 'rb').read()
print(f"  保存: {p}  ({len(data)} bytes)")
if len(data) > 4 and data[0] == 0xFF and data[1] == 0xD8:
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1; continue
        m = data[i+1]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            h = (data[i+5] << 8) | data[i+6]
            w = (data[i+7] << 8) | data[i+8]
            print(f"  ✅ 有效 JPEG: {w}x{h}"
                  + ("  ← 与设备要求一致" if (w, h) == (1920, 462) else "  ⚠️ 与 1920x462 不一致"))
            print(f"  体积限制 650KB: {'✅ 通过' if len(data) <= 650000 else '❌ 超限'}")
            break
        i += 2 + ((data[i+2] << 8) | data[i+3])
    else:
        print("  ⚠️ 未找到 SOF 标记")
else:
    print("  ❌ 不是 JPEG")
PY
