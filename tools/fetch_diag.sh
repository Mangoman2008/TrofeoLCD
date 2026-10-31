#!/usr/bin/env bash
# 从运行中的应用取完整诊断信息（本沙箱读不到 hilog 时的取证通道）
#   tools/fetch_diag.sh            取 /diag
#   tools/fetch_diag.sh probe      先 /probe（主动扫 USB）再取 /diag
set -u
PORT="${PORT:-54546}"
BASE="http://127.0.0.1:$PORT"

if [ "${1:-}" = "probe" ]; then
  echo "=== /probe（主动扫描 USB 并尝试打开）==="
  curl -s -m 20 "$BASE/probe" | python3 -m json.tool --no-ensure-ascii 2>/dev/null || echo "  ❌ probe 失败（应用未运行？）"
  echo
fi

echo "=== /diag ==="
curl -s -m 8 "$BASE/diag" -o /tmp/.diag 2>/dev/null
if [ ! -s /tmp/.diag ]; then
  echo "  ❌ 取不到（应用未运行 / 端口未监听）"
  exit 1
fi
python3 - <<'PY'
import json
d = json.load(open('/tmp/.diag'))
print(f"  自检        : {d.get('selfTest')}  {'✅ 全部通过' if d.get('selfTestAllPass') else '❌ 有失败项'}")
for f in d.get('selfTestFails', []):
    print(f"      - {f}")
print(f"  USB 打开    : {d.get('usbOpen')}")
print(f"  设备        : {d.get('deviceLabel')}")
print(f"  设备信息    : {d.get('deviceInfo') or '（未握手）'}")
print(f"  端点选择    : {d.get('endpoint')}")
print(f"  旋转        : {d.get('rotateDeg')}° (开关 rotate180={d.get('rotate180')})")
print(f"  输出帧      : {d.get('jpegW')}x{d.get('jpegH')}  {d.get('jpegBytes')} 字节")
print(f"  已发送/错误 : {d.get('sent')} / {d.get('errors')}   帧率 {d.get('fps')}")
print(f"  屏 ACK      : {d.get('ack')}")
print(f"  数据桥      : {d.get('bridgeAgeSec')} 秒前")
print(f"  最近错误    : {d.get('lastError') or '（无）'}")
dump = d.get('deviceDump') or []
if dump:
    print(f"  USB 描述符  : {len(dump)} 行")
    for line in dump[:12]:
        print(f"      {line}")
PY
