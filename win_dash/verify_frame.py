#!/usr/bin/env python3
"""verify_frame.py —— 对 lcdrunner/Program（--demo/--render）产出的帧做主机侧独立核对。

不依赖任何自报数据，布局常量按 Theme.ets/Dashboard.ets 重新推一遍：
  h（横屏）：直接检查 1920×462 光栅里的 4 个面板区（系统 / DSH / 用量 / VM）
  v（竖屏）：LcdRunner 的变换是 translate(W,0)+rotate(90°)，即
             logical(x,y) -> device(1920-y, x)；这里先把光栅反旋转回 462×1920 的
             逻辑坐标，再检查顶部时钟 / VM / 系统 / DSH / 用量 5 段。

  python3 win_dash/verify_frame.py <jpg> h|v
"""
import os
import sys

from PIL import Image

C = {
    "bgTop": (0x0A, 0x0C, 0x14), "bgBot": (0x10, 0x12, 0x1C),
    "panel": (0x14, 0x17, 0x22), "border": (0x26, 0x2A, 0x3A),
}
LW, LH, LM, LG = 1920, 462, 14, 10       # 帧高 462（与 Theme.ets 的 L.height 一致）
LPW = (LW - 480 - 2 * LM - 4 * LG) / 5.0  # 这里的 480 是 VM 那一列的宽度（不是帧高）
LPH = LH - 2 * LM
LVX, LVW, LVH = (LW - 480) + LG, 480 - LG - LM, LH - 2 * LM
VW, VH, VMAR = 462, 1920, 14    # 竖装逻辑宽 = 帧高 462
# VM 面板里"等比放入"后图像真正覆盖的矩形（横屏 / 竖屏）
HIMG = (1450 + (456 - 432) // 2, 14 + 52 + 49, 1450 + (456 + 432) // 2, 14 + 52 + 49 + 288)
VIMG = (14 + (452 - 428) // 2, 140 + 52 + 64, 14 + (452 + 428) // 2, 140 + 52 + 64 + 285)
VIN = VW - 2 * VMAR
FAIL = []
PX = None
PXW = PXH = 0


def check(name, ok, detail):
    if not ok:
        FAIL.append(name)
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}  {detail}")


def panel_x(i):
    return LM + i * (LPW + LG)


def bg_at(y, h):
    t = y / float(h - 1)
    return tuple(round(C["bgTop"][k] + (C["bgBot"][k] - C["bgTop"][k]) * t) for k in range(3))


def region_stats(x0, y0, x1, y1, h):
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(PXW, int(x1)), min(PXH, int(y1))
    tot = d25 = d60 = fill = 0
    for y in range(y0, y1):
        bg = bg_at(y, h)
        for x in range(x0, x1):
            r, g, b = PX[x, y]
            d = abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2])
            tot += 1
            if d > 25:
                d25 += 1
            if d > 60:
                d60 += 1
            if abs(r - C["panel"][0]) <= 6 and abs(g - C["panel"][1]) <= 6 and abs(b - C["panel"][2]) <= 6:
                fill += 1
    return tot, d25, d60, fill


def bright_in(x0, y0, x1, y1, thr=80):
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(PXW, int(x1)), min(PXH, int(y1))
    n = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = PX[x, y]
            if max(r, g, b) >= thr:
                n += 1
    return n


def unrotate(img):
    """logical(x,y) = device(1920-y, x)  ← LcdRunner 的 translate(W,0)+rotate(90°)
    光栅 1920×462 → 逻辑 462×1920"""
    w, h = img.size               # w=1920（光栅宽）, h=462（光栅高）
    out = Image.new("RGB", (h, w))   # 逻辑 462×1920
    src = img.load()
    dst = out.load()
    for ly in range(w):           # 逻辑 y: 0..1919
        for lx in range(h):       # 逻辑 x: 0..479
            dst[lx, ly] = src[w - 1 - ly, lx]
    return out


def open_frame_loaded(img, vertical):
    global PX, PXW, PXH
    if vertical:
        img = unrotate(img)
        print(f"      反旋转回逻辑坐标后 {img.size[0]}×{img.size[1]}")
    PX = img.load()
    PXW, PXH = img.size
    return img


def palette_check(img_rect, label):
    """硬不变量：调色板最亮是 #E6EBF5(230,235,245)，没有 #FFFFFF。
    所以 Dockboard 自己画的区域里不该出现 R,G,B 同时 >=250 的像素；
    只有 VM 监控画面（外部真实截图）里的白色是合法的。"""
    x0, y0, x1, y1 = img_rect
    bad = 0
    worst = (0, 0, 0)
    worst_at = None
    for y in range(PXH):
        for x in range(PXW):
            if x0 - 2 <= x <= x1 + 2 and y0 - 2 <= y <= y1 + 2:
                continue
            r, g, b = PX[x, y]
            if min(r, g, b) >= 250:
                bad += 1
                if min(r, g, b) > min(worst):
                    worst, worst_at = (r, g, b), (x, y)
    check(f"VM 画面矩形之外没有纯白（{label}）", bad == 0,
          f"min(RGB)>=250 的像素 {bad} 个" + (f"，最高 {worst}@{worst_at}" if bad else ""))
    # 顺带给出 VM 画面矩形"之内"的纯白数（那是被监控桌面自身的内容，允许）
    inside = 0
    for y in range(max(0, y0), min(PXH, y1)):
        for x in range(max(0, x0), min(PXW, x1)):
            if min(PX[x, y]) >= 250:
                inside += 1
    print(f"      （VM 画面矩形内纯白 {inside} 个 = 被监控 VM 桌面自身内容，不影响本不变量）")


def body(regions, h, tags):
    for name, x0, y0, x1, y1, need_fill in regions:
        tot, d25, d60, fill = region_stats(x0, y0, x1, y1, h)
        check(f"{name} 有内容", d60 > 500, f"d25={d25} d60={d60} 像素={tot}")
        if need_fill:
            pct = fill * 100 // max(1, tot)
            check(f"{name} 面板底色 #141722 已铺满", fill > tot * 0.5, f"覆盖 {pct}%")
    for i, (x0, y0, x1, y1) in enumerate(tags):
        n = bright_in(x0, y0, x1, y1)
        check(f"缝隙/边距 {i+1} 干净", n <= 20, f"亮像素 {n} 区域 {x0},{y0}-{x1},{y1}")


def rot180(img):
    """LcdRunner 的横屏 rotate180：translate(W,H)+rotate(180°) → 内容整体翻转 180°"""
    return img.transpose(Image.ROTATE_180)


def main():
    path, mode = sys.argv[1], sys.argv[2]
    vertical = mode == "v"
    flipped = len(sys.argv) > 3 and sys.argv[3] == "r180"
    img = Image.open(path).convert("RGB")
    print(f"\n===== {os.path.basename(path)}  光栅 {img.size[0]}×{img.size[1]}"
          f"{'（rotate180，先翻转回正）' if flipped else ''} =====")
    if flipped:
        img = rot180(img)
    open_frame_loaded(img, vertical)

    if vertical:
        check("逻辑尺寸 462×1920（反旋转后）", (PXW, PXH) == (VW, VH), f"{PXW}×{PXH}")
        p1 = PX[5, 4]
        p2 = PX[5, VH - 5]
        check("整帧渐变背景（逻辑坐标）",
              max(abs(p1[i] - C["bgTop"][i]) for i in range(3)) <= 14
              and max(abs(p2[i] - C["bgBot"][i]) for i in range(3)) <= 14,
              f"顶 {p1} 底 {p2}（令牌 {C['bgTop']}→{C['bgBot']}）")
        x, w = VMAR, VIN
        regions = [
            ("顶部时钟", x, 14, x + w, 130, True),
            ("VM 画面段", x, 140, x + w, 620, False),
            ("系统 SYSTEM 段", x, 630, x + w, 1010, True),
            ("DSH 会话段", x, 1020, x + w, 1560, True),
            ("用量 USAGE 段", x, 1570, x + w, 1906, True),
        ]
        tags = [(0, 0, VW, 14), (0, 1906, VW, 1920), (0, 14, 14, 1906), (VW - 14, 14, VW, 1906),
                (0, 130, VW, 140), (0, 620, VW, 630), (0, 1010, VW, 1020), (0, 1560, VW, 1570)]
        body(regions, VH, tags)
        palette_check(VIMG, "竖屏")
        check("VM 段占位文字（等待 VM 画面…）", bright_in(VMAR + 24, 192 + 60, VMAR + VIN - 24, 192 + 414 - 40, 70) > 200,
              f"VM 内亮像素 {bright_in(VMAR + 24, 192 + 60, VMAR + VIN - 24, 192 + 414 - 40, 70)}")
    else:
        check("光栅尺寸 1920×462", (PXW, PXH) == (LW, LH), f"{PXW}×{PXH}")
        p1 = PX[5, 4]
        p2 = PX[5, LH - 5]
        check("整帧渐变背景（顶行深、底行浅）", p1[2] < p2[2] or p2[2] - p1[2] >= 4,
              f"顶 {p1} 底 {p2}")
        regions = [
            ("系统 SYSTEM", panel_x(0), LM, panel_x(0) + LPW, LM + LPH, True),
            ("DSH 会话(1-3)", panel_x(1), LM, panel_x(1) + LPW * 3 + LG * 2, LM + LPH, True),
            ("用量 USAGE", panel_x(4), LM, panel_x(4) + LPW, LM + LPH, True),
            ("VM 画面", LVX, LM, LVX + LVW, LM + LVH, False),
        ]
        tags = [(panel_x(0) + LPW, LM, panel_x(1), LM + LPH),
                (panel_x(3) + LPW, LM, panel_x(4), LM + LPH),
                (0, 0, 1920, LM), (0, LM + LPH, 1920, LH), (0, 0, LM, LH),
                (LVX + LVW, 0, LW, LH)]
        body(regions, LH, tags)
        palette_check(HIMG, "横屏")
        check("VM 面板占位文字", bright_in(LVX + 24, LM + 52, LVX + LVW - 24, LM + LVH - 14, 70) > 200,
              f"VM 内亮像素 {bright_in(LVX + 24, LM + 52, LVX + LVW - 24, LM + LVH - 14, 70)}")

    print("\n小结：", "全部通过" if not FAIL else f"不通过 {len(FAIL)} 项 {FAIL}")
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main())
