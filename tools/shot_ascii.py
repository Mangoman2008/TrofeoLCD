#!/usr/bin/env python3
"""把手机截图降采样成「色块地图」，用来在没有视觉通道时核对版式。

用法: python3 tools/shot_ascii.py <图片> [列数]

输出:
  1) 调色板统计（哪些设计色真的出现在屏幕上）
  2) 横向分带：每一带的平均色 + 该带里"有内容"的列范围（判断卡片/文字是否溢出）
  3) 粗粒度 ASCII 图：字符按亮度取，方便看区块边界
"""
import sys
from collections import Counter
from PIL import Image

PATH = sys.argv[1]
COLS = int(sys.argv[2]) if len(sys.argv) > 2 else 46

# 设计调色板（Index.ets 里用到的颜色）
PALETTE = {
    (0x0D, 0x11, 0x17): 'BG      页面底',
    (0x16, 0x1B, 0x22): 'CARD    卡片',
    (0x21, 0x26, 0x2D): 'BORDER  描边/次按钮',
    (0x30, 0x36, 0x3D): 'BORDER2 输入框描边',
    (0x01, 0x04, 0x09): 'PREVIEW 预览底',
    (0x23, 0x86, 0x36): 'PRIMARY 主色/选中',
    (0x0D, 0x28, 0x18): 'TINT    绿提示条',
    (0x9E, 0x6A, 0x03): 'WARN    停止按钮',
    (0xE6, 0xED, 0xF3): 'TEXT    主文字',
    (0x8B, 0x94, 0x9E): 'MUTED   次文字',
    (0x7D, 0x85, 0x90): 'DIM     弱文字',
    (0x48, 0x4F, 0x58): 'FAINT   页脚',
    (0x3F, 0xB9, 0x50): 'OK      绿状态',
    (0xD2, 0x99, 0x22): 'AMBER   黄状态',
    (0xF8, 0x51, 0x49): 'ERR     红状态',
    (0x58, 0xA6, 0xFF): 'BLUE    蓝状态',
    (0xD0, 0xBC, 0xFF): 'PURPLE  紫状态',
}


def near(c, ref, tol=10):
    return abs(c[0] - ref[0]) <= tol and abs(c[1] - ref[1]) <= tol and abs(c[2] - ref[2]) <= tol


def main():
    im = Image.open(PATH).convert('RGB')
    W, H = im.size
    print(f'图片 {W}x{H}')

    # ---- 1. 调色板统计（按 4x4 采样，避免全图逐像素太慢）----
    cnt = Counter()
    px = im.load()
    for y in range(0, H, 3):
        for x in range(0, W, 3):
            cnt[px[x, y]] += 1
    exact = {c: n for c, n in cnt.items()}
    print('\n=== 调色板命中（精确像素）===')
    hits = {}
    for ref, name in PALETTE.items():
        n = exact.get(ref, 0)
        if n:
            hits[ref] = n
    for ref, n in sorted(hits.items(), key=lambda kv: -kv[1]):
        print(f'  #{ref[0]:02X}{ref[1]:02X}{ref[2]:02X}  {n * 9:>8} px  {PALETTE[ref]}')
    missing = [PALETTE[r] for r in PALETTE if r not in hits]
    if missing:
        print('  未出现: ' + ' | '.join(missing))

    # ---- 2. 分带分析：每 1/40 高度一带 ----
    band = max(1, H // 40)
    print(f'\n=== 横向分带（每带 {band}px）· R=有内容列范围 ===')
    for b0 in range(0, H, band):
        b1 = min(H, b0 + band)
        cols_with_content = []
        rs = gs = bs = 0
        n = 0
        for x in range(0, W, 3):
            colmax = 0
            for y in range(b0, b1, 3):
                c = px[x, y]
                lum = (c[0] * 299 + c[1] * 587 + c[2] * 114) // 1000
                if lum > 60:
                    colmax = max(colmax, lum)
                rs += c[0]; gs += c[1]; bs += c[2]; n += 1
            if colmax > 60:
                cols_with_content.append(x)
        avg = (rs // max(1, n), gs // max(1, n), bs // max(1, n))
        if cols_with_content:
            lo, hi = min(cols_with_content), max(cols_with_content)
            rng = f'{lo:>4}-{hi:>4} ({100 * lo // W:>3}%..{100 * hi // W:>3}%)'
        else:
            rng = '   （空）'
        print(f'  y={b0:>4}  avg #{avg[0]:02X}{avg[1]:02X}{avg[2]:02X}  R={rng}')

    # ---- 3. 粗 ASCII ----
    print('\n=== ASCII（亮度）===')
    rows = max(1, int(COLS * H / W / 2.1))
    cw, ch = W / COLS, H / rows
    ramp = ' .:-=+*#%@'
    for r in range(rows):
        line = []
        for c in range(COLS):
            x0, x1 = int(c * cw), max(int(c * cw) + 1, int((c + 1) * cw))
            y0, y1 = int(r * ch), max(int(r * ch) + 1, int((r + 1) * ch))
            tot = 0
            k = 0
            for y in range(y0, min(y1, H), 2):
                for x in range(x0, min(x1, W), 2):
                    p = px[x, y]
                    tot += (p[0] * 299 + p[1] * 587 + p[2] * 114) // 1000
                    k += 1
            lum = tot // max(1, k)
            line.append(ramp[min(len(ramp) - 1, lum * len(ramp) // 256)])
        print('  |' + ''.join(line) + '|')


if __name__ == '__main__':
    main()
