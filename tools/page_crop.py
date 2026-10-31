#!/usr/bin/env python3
"""从实机截图里裁出 dashboard 页面区域（自动标定缩放与原点）。

为什么需要：浏览器缩放一变（用户在 50%/100% 之间切），"页面坐标 → 屏幕坐标"的映射就变，
为什么需要：浏览器缩放一变（用户会在 50%/100% 之间切），"页面坐标 → 屏幕坐标"的映射就变，
按固定系数裁剪必然裁偏（试过按总线虚线自动找，结果找到的是浏览器工具栏）。
最终方案是**确定性的标定物**：页面加 `?cal=1` 会在两角画两个品红方块（页面坐标已知：
中心 (12,12) 与 (1908,1068)），图里一找就能反推缩放与原点，裁任意区域都不会错。

配套的抓屏链路（本机 = 目标设备）：
  hdc -t 127.0.0.1:40601 shell "aa start -b com.haitai.htbrowser -a EntryAbility -U 'http://127.0.0.1:54550/dashboard?cal=1'"
  hdc -t 127.0.0.1:40601 shell "snapshot_display -f /data/local/tmp/x.jpeg"
  hdc -t 127.0.0.1:40601 file recv /data/local/tmp/x.jpeg <本地>

用法：python3 tools/page_crop.py <截图> <out.png> [px0 py0 px1 py1]   # 不给框就裁整页（统一成 1920×1080）
"""
import sys
from PIL import Image

SRC, OUT = sys.argv[1], sys.argv[2]
BOX = [float(v) for v in sys.argv[3:7]] if len(sys.argv) >= 7 else [0, 0, 1920, 1080]

im_rgb = Image.open(SRC).convert('RGB')
im = im_rgb.convert('L')
W, H = im.size

# ── 标定：?cal=1 会在页面两角画品红方块；在图里找它们就能反推缩放与原点 ──
px_rgb = im_rgb.load()
mag = [(x, y) for y in range(0, H, 2) for x in range(0, W, 2)
       if px_rgb[x, y][0] > 190 and px_rgb[x, y][1] < 90 and px_rgb[x, y][2] > 190]
if len(mag) < 20:
    raise SystemExit('没找到标定物：请用带 ?cal=1 的地址打开页面再抓屏')
xs = sorted(x for x, _ in mag)
ys = sorted(y for _, y in mag)
# 两个方块：取最左与最右的簇中心（各 24px 见方，取簇内均值）
def cluster(vals, gap=40):
    out, cur = [], [vals[0]]
    for v in vals[1:]:
        if v - cur[-1] <= gap:
            cur.append(v)
        else:
            out.append(cur); cur = [v]
    out.append(cur)
    return [sum(c) / len(c) for c in out]
cx = cluster(xs)
x_left, x_right = cx[0], cx[-1]
y_of_left = sorted(y for x, y in mag if abs(x - x_left) < 40)
y_of_right = sorted(y for x, y in mag if abs(x - x_right) < 40)
y_top, y_bot = sum(y_of_left) / len(y_of_left), sum(y_of_right) / len(y_of_right)
# 方块中心 = 页面 (12,12) 与 (1908,1068)
scale = (x_right - x_left) / (1908 - 12)
ox = x_left - 12 * scale
oy = (y_top if y_top < y_bot else y_bot) - 12 * scale
print('标定：品红方块中心 x=%.0f/%.0f, y=%.0f/%.0f → 缩放 %.4f，页面原点 (%.0f, %.0f)'
      % (x_left, x_right, y_top, y_bot, scale, ox, oy))
box = (int(ox + BOX[0] * scale), int(oy + BOX[1] * scale),
       int(ox + BOX[2] * scale), int(oy + BOX[3] * scale))
c = im.crop(box).convert('RGB')
if len(sys.argv) < 7:
    c = c.resize((1920, 1080), Image.LANCZOS)   # 整页统一成 1920×1080，便于对比
c.save(OUT)
print('裁剪 %s → %s（%dx%d）' % (box, OUT, c.width, c.height))
