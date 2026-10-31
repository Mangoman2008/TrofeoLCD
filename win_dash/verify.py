#!/usr/bin/env python3
"""verify.py —— 在主机侧独立核对 VM 渲染出来的 JPEG。

不依赖 C# 侧的自报数据：布局常量在这里按 entry/src/main/ets/common/Theme.ets
和 render/Dashboard.ets 里的数字**重新推一遍**，再检查：
  1. 尺寸必须正好 1920×462 / 462×1920
  2. 每个面板区域内「非背景」像素数（d>25 含面板底色，d>60 文字/强调色）
  3. 面板之间的缝隙与整帧外边距里不该有亮像素（证明内容没溢出面板）
  4. 逐特征探针：CPU 圆环绿弧、内存条绿段、上下文条橙段、状态徽章品牌蓝、
     VM 画面青色边框、时钟白字 …… 位置和颜色都要对上

  python3 win_dash/verify.py
"""
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")

# ---- 令牌（Theme.ets）----
C = {
    "bgTop": (0x0A, 0x0C, 0x14), "bgBot": (0x10, 0x12, 0x1C),
    "panel": (0x14, 0x17, 0x22), "panelHi": (0x1A, 0x1E, 0x2C),
    "border": (0x26, 0x2A, 0x3A),
    "textW": (0xE6, 0xEB, 0xF5), "textS": (0x8C, 0x94, 0xA8),
    "textL": (0x64, 0x6C, 0x82), "textD": (0x46, 0x4C, 0x5F),
    "blue": (0x42, 0x85, 0xF4), "green": (0x34, 0xD3, 0x99),
    "orange": (0xFB, 0xBF, 0x24), "red": (0xEF, 0x44, 0x44),
    "purple": (0xA7, 0x8B, 0xFA), "cyan": (0x22, 0xD3, 0xEE),
    "deepseek": (0x4D, 0x6B, 0xFE), "barBg": (0x1E, 0x22, 0x30),
}

# ---- 横屏布局（L）：帧高 462（与 Theme.ets 的 L.height 一致；480 是电商页宣传值）----
VMW = 480                                          # VM 监视画面那一列的宽度（仍是 480）
LW, LH, LM, LG = 1920, 462, 14, 10
LPW = (LW - VMW - 2 * LM - 4 * LG) / 5.0           # 274.4
LPH = LH - 2 * LM                                  # 434
LVX, LVW, LVH = (LW - VMW) + LG, VMW - LG - LM, LH - 2 * LM

# ---- 竖屏布局（V）：逻辑宽 = 帧高 462（绘制时整体旋转 90°）----
VW, VH, VM_ = 462, 1920, 14
VIN = VW - 2 * VM_                                 # 434


def panel_x(i):
    return LM + i * (LPW + LG)


FAIL = []


def check(name, ok, detail):
    tag = "PASS" if ok else "FAIL"
    if not ok:
        FAIL.append(name)
    print(f"  [{tag}] {name}  {detail}")


def bg_at(y, h):
    t = y / float(h - 1)
    return tuple(round(C["bgTop"][k] + (C["bgBot"][k] - C["bgTop"][k]) * t) for k in range(3))


def stats(px, x0, y0, x1, y1, h):
    """返回 (总像素, d>25, d>60, 最亮像素颜色)"""
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(px_w, int(x1)), min(px_h, int(y1))
    tot = d25 = d60 = 0
    bright = (0, 0, 0)
    for y in range(y0, y1):
        bg = bg_at(y, h)
        for x in range(x0, x1):
            r, g, b = px[x, y]
            d = abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2])
            tot += 1
            if d > 25:
                d25 += 1
            if d > 60:
                d60 += 1
            if r + g + b > sum(bright):
                bright = (r, g, b)
    return tot, d25, d60, bright


def bright_count(px, x0, y0, x1, y1, thr=80):
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(px_w, int(x1)), min(px_h, int(y1))
    n = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px[x, y]
            if max(r, g, b) >= thr:
                n += 1
    return n


def panel_fill(px, x0, y0, x1, y1, tol=6):
    """面板底色 #141722 的覆盖比例（比"与背景差多少"更可靠：某些行背景下
    面板底色与背景的绝对差正好是 25，卡在阈值上）"""
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(px_w, int(x1)), min(px_h, int(y1))
    hit = tot = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px[x, y]
            tot += 1
            if abs(r - C["panel"][0]) <= tol and abs(g - C["panel"][1]) <= tol and abs(b - C["panel"][2]) <= tol:
                hit += 1
    return hit, tot


def probe(px, x, y, color, tol, rad=4):
    """在 (x,y) 周围 rad 半径里找最接近 color 的像素，返回 (最小通道差, 命中坐标)"""
    best, at = 999, None
    for yy in range(int(y) - rad, int(y) + rad + 1):
        for xx in range(int(x) - rad, int(x) + rad + 1):
            if 0 <= xx < px_w and 0 <= yy < px_h:
                r, g, b = px[xx, yy]
                d = max(abs(r - color[0]), abs(g - color[1]), abs(b - color[2]))
                if d < best:
                    best, at = d, (xx, yy, (r, g, b))
    return best, at


def load(path):
    img = Image.open(path).convert("RGB")
    return img, img.load()


def run_common(path, want_w, want_h):
    global px, px_w, px_h
    img, px = load(path)
    px_w, px_h = img.size
    print(f"\n===== {os.path.basename(path)}  {px_w}×{px_h}  {os.path.getsize(path)} B =====")
    check("尺寸", (px_w, px_h) == (want_w, want_h),
          f"实际 {px_w}×{px_h}，要求 {want_w}×{want_h}")
    p1, at1 = probe(px, 5, 4, C["bgTop"], 14)
    p2, at2 = probe(px, 5, px_h - 5, C["bgBot"], 14)
    check("整帧渐变背景", p1 <= 14 and p2 <= 14,
          f"顶行 {at1[2]} 底行 {at2[2]}（令牌 {C['bgTop']} → {C['bgBot']}）")
    return img, px


def horizontal():
    path = os.path.join(OUT, "dash_h.jpg")
    run_common(path, 1920, LH)

    regions = [
        ("系统 SYSTEM", panel_x(0), LM, panel_x(0) + LPW, LM + LPH),
        ("DSH 会话(1-3)", panel_x(1), LM, panel_x(1) + LPW * 3 + LG * 2, LM + LPH),
        ("用量 USAGE", panel_x(4), LM, panel_x(4) + LPW, LM + LPH),
        ("VM 画面", LVX, LM, LVX + LVW, LM + LVH),
    ]
    print("  -- 各面板内容像素（d25=非背景，d60=文字/强调色）--")
    for name, x0, y0, x1, y1 in regions:
        tot, d25, d60, bright = stats(px, x0, y0, x1, y1, LH)
        check(f"{name} 有内容", d60 > 500, f"像素 {tot}，d25={d25}，d60={d60}，最亮 {bright}")
        if name != "VM 画面":
            hit, tt = panel_fill(px, x0, y0, x1, y1)
            check(f"{name} 面板底色 #141722 已铺满", hit > tt * 0.6,
                  f"覆盖 {hit*100//max(1,tt)}%（{hit}/{tt}）")

    # 缝隙 / 外边距不该有亮像素（内容没溢出面板）
    gaps = [(panel_x(0) + LPW, LM, panel_x(1), LM + LPH),
            (panel_x(3) + LPW, LM, panel_x(4), LM + LPH),
            (panel_x(4) + LPW, 0, LVX, LH),
            (0, 0, 1920, LM), (0, LM + LPH, 1920, LH), (0, 0, LM, LH),
            (LVX + LVW, 0, 1920, LH)]
    for i, (x0, y0, x1, y1) in enumerate(gaps):
        n = bright_count(px, x0, y0, x1, y1)
        check(f"缝隙/边距 {i+1} 干净", n <= 20, f"亮像素 {n}（区域 {(int(x0),int(y0))}-{(int(x1),int(y1))}）")

    # 特征探针
    cx, cy, r = panel_x(0) + LPW / 2, LM + 150, 62
    d, at = probe(px, cx + r, cy, C["green"], 45)
    check("系统面板 CPU 圆环绿弧（37.4%）", d <= 45, f"(x={int(cx+r)},y={cy}) → {at[2]}，差 {d}")
    d, at = probe(px, cx - r, cy, C["barBg"], 14)
    check("系统面板 圆环底槽 barBg", d <= 14, f"(x={int(cx-r)},y={cy}) → {at[2]}，差 {d}")

    mempct = 9120 / 16384.0
    mx = panel_x(0) + 22
    mw = LPW - 44
    d, at = probe(px, mx + mw * mempct * 0.5, LM + 262 + 6, C["green"], 45, 3)
    check("系统面板 内存条绿段", d <= 45, f"填充至 x={int(mx+mw*mempct)}，探针 {at[2]}，差 {d}")
    d, at = probe(px, mx + mw * 0.95, LM + 262 + 6, C["barBg"], 14, 3)
    check("系统面板 内存条底槽", d <= 14, f"探针 {at[2]}，差 {d}")

    # 用量面板：上下文 64% → byPercent 橙
    ux = panel_x(4)
    cpct = 81920 / 128000.0
    d, at = probe(px, ux + 22 + (LPW - 44) * cpct * 0.5, LM + 156 + 6, C["orange"], 45, 3)
    check("用量面板 上下文条橙段（64%）", d <= 45, f"探针 {at[2]}，差 {d}")

    # 状态徽章（busy → deepseek 品牌蓝）
    ax = panel_x(1)
    aw = LPW * 3 + LG * 2
    n = 0
    for x in range(int(ax + aw - 240), int(ax + aw - 18)):
        for y in range(LM + 52, LM + 86):
            r, g, b = px[x, y]
            if abs(r - C["deepseek"][0]) < 60 and abs(g - C["deepseek"][1]) < 60 and abs(b - C["deepseek"][2]) < 60:
                n += 1
    check("DSH 面板 状态徽章（deepseek 蓝）", n > 500, f"徽章区域品牌蓝像素 {n}")

    # DSH 面板标题蓝 + 项目名白字
    n = bright_count(px, ax + 22, LM + 50, ax + 380, LM + 95, 200)
    check("DSH 面板 项目名（白字）", n > 200, f"项目名区亮像素 {n}")

    # VM 画面：合成帧的青色边框
    n = 0
    for y in range(LM, LM + LVH):
        for x in range(LVX, LVX + LVW):
            r, g, b = px[x, y]
            if b > 150 and g > 150 and r < 140:
                n += 1
    check("VM 画面 已贴上合成帧（青色边框）", n > 200, f"青色像素 {n}")

    # 时钟白字
    n = bright_count(px, ux + LPW / 2 - 110, LM + 272 - 26, ux + LPW / 2 + 110, LM + 272 + 26, 200)
    check("用量面板 时钟白字", n > 300, f"时钟区亮像素 {n}")


def vertical():
    path = os.path.join(OUT, "dash_v.jpg")
    run_common(path, VW, 1920)
    x, w = VM_, VIN
    segs = [("顶部时钟", 14, 116), ("VM 画面", 140, 480), ("系统 SYSTEM", 630, 380),
            ("DSH 会话", 1020, 540), ("用量 USAGE", 1570, 336)]
    print("  -- 各分段内容像素 --")
    for name, y0, hh in segs:
        tot, d25, d60, bright = stats(px, x, y0, x + w, y0 + hh, 1920)
        check(f"{name} 有内容", d60 > 500, f"像素 {tot}，d25={d25}，d60={d60}，最亮 {bright}")
        if name != "VM 画面":
            hit, tt = panel_fill(px, x, y0, x + w, y0 + hh)
            check(f"{name} 面板底色 #141722 已铺满", hit > tt * 0.6,
                  f"覆盖 {hit*100//max(1,tt)}%（{hit}/{tt}）")

    gaps = [(0, 0, VW, 14), (0, 1906, VW, 1920), (0, 14, 14, 1906), (VW - 14, 14, VW, 1906),
            (0, 130, VW, 140), (0, 620, VW, 630), (0, 1010, VW, 1020), (0, 1560, VW, 1570)]
    for i, (x0, y0, x1, y1) in enumerate(gaps):
        n = bright_count(px, x0, y0, x1, y1)
        check(f"缝隙/边距 {i+1} 干净", n <= 20, f"亮像素 {n}（区域 {x0},{y0}-{x1},{y1}）")

    # 顶部时钟白字 + 日期
    n = bright_count(px, 100, 34, 380, 60, 200)
    check("顶部 大时钟白字", n > 300, f"时钟区亮像素 {n}")

    # CPU 圆环（竖屏系统段 y=630）
    cx, cy, r = x + w / 2, 630 + 150, 62
    d, at = probe(px, cx + r, cy, C["green"], 45)
    check("系统段 CPU 圆环绿弧", d <= 45, f"({int(cx+r)},{cy}) → {at[2]}，差 {d}")

    # 用量段：上下文条橙段
    cpct = 81920 / 128000.0
    d, at = probe(px, x + 22 + (w - 44) * cpct * 0.5, 1570 + 146 + 6, C["orange"], 45, 3)
    check("用量段 上下文条橙段", d <= 45, f"探针 {at[2]}，差 {d}")

    # VM 段：合成帧的青边
    n = 0
    for y in range(140, 620):
        for xx in range(x, x + w):
            rr, gg, bb = px[xx, y]
            if bb > 150 and gg > 150 and rr < 140:
                n += 1
    check("VM 段 已贴上合成帧（青色边框）", n > 200, f"青色像素 {n}")

    # DSH 段：状态徽章品牌蓝
    n = 0
    for y in range(1020 + 52, 1020 + 86):
        for xx in range(x + w - 260, x + w - 18):
            rr, gg, bb = px[xx, y]
            if abs(rr - C["deepseek"][0]) < 60 and abs(gg - C["deepseek"][1]) < 60 and abs(bb - C["deepseek"][2]) < 60:
                n += 1
    check("DSH 段 状态徽章（deepseek 蓝）", n > 400, f"品牌蓝像素 {n}")


def novm(name, w, h, vm_box):
    path = os.path.join(OUT, name)
    run_common(path, w, h)
    x0, y0, x1, y1 = vm_box
    n = bright_count(px, x0, y0, x1, y1, 70)
    check("VM 面板 占位文字（等待 VM 画面…）", n > 500, f"VM 面板内亮像素 {n}")




def _ink(px, x0, y0, x1, y1, thr=80):
    return bright_count(px, x0, y0, x1, y1, thr)


def _orange_count(px, x0, y0, x1, y1):
    n = 0
    for y in range(int(y0), int(y1)):
        for x in range(int(x0), int(x1)):
            r, g, b = px[x, y]
            if r > 180 and 140 < g < 230 and b < 120:
                n += 1
    return n


def extra():
    """样例图里的橙色「预估花费」行 + 空状态图（首次启动）的占位分支。"""
    global px, px_w, px_h
    ux = panel_x(4)
    img, px = load(os.path.join(OUT, "dash_h.jpg"))
    px_w, px_h = img.size
    n = _orange_count(px, ux + 22, LM + 194 - 12, ux + LPW - 22, LM + 194 + 12)
    check("样例图 用量面板 预估花费橙色行", n > 15, f"橙色像素 {n}（空状态图为 0，见下）")

    img, px = load(os.path.join(OUT, "dash_h_empty.jpg"))
    px_w, px_h = img.size
    print(f"\n===== dash_h_empty.jpg（空状态/首次启动）  {px_w}×{px_h} =====")
    check("尺寸", (px_w, px_h) == (1920, LH), f"{px_w}×{px_h}")
    ax = panel_x(1)
    n1 = _ink(px, ax + 22, LM + 60, ax + 380, LM + 86)
    check("空状态 DSH 左列「（未连接数据桥）」", n1 > 100, f"项目名行亮像素 {n1}")
    n2 = _ink(px, ax + 22, LM + 140, ax + 380, LM + 166)
    check("空状态 DSH「等待数据…」", n2 > 100, f"活动行亮像素 {n2}")
    n3 = _ink(px, ax + 421, LM + 152, ax + 830, LM + 180)
    check("空状态 DSH「暂无待办（…）」", n3 > 100, f"待办占位行亮像素 {n3}")
    # 贴底的行按版式推导（别再写 480 时代的绝对值：帧高 462 时它们整体上移 18px）
    n4 = _ink(px, ax + 22, LM + LPH - 34, ax + 421, LM + LPH + 2)
    check("空状态 DSH「数据桥：无数据」", n4 > 50, f"底部状态行亮像素 {n4}")
    n5 = _orange_count(px, ux + 22, LM + 182, ux + LPW - 22, LM + 210)
    check("空状态 用量面板 无「预估花费」行", n5 < 20, f"橙色像素 {n5}")
    n6 = _ink(px, ux + LPW / 2 - 110, LM + 246, ux + LPW / 2 + 110, LM + 300, 200)
    check("空状态 时钟仍在", n6 > 300, f"时钟区亮像素 {n6}")
    n7 = _ink(px, panel_x(0) + 100, LM + LPH - 58, panel_x(0) + LPW - 22, LM + LPH - 30)
    check("空状态 系统面板「up 0d 0h 0m」", n7 > 60, f"运行时长行亮像素 {n7}")


if __name__ == "__main__":
    extra()
    horizontal()
    vertical()
    novm("dash_h_novm.jpg", 1920, LH, (LVX + 24, LM + 52, LVX + LVW - 24, LM + LVH - 14))
    novm("dash_v_novm.jpg", VW, 1920, (VM_ + 24, 140 + 52, VM_ + VIN - 24, 620 - 14))
    print("\n================ 汇总 ================")
    if FAIL:
        print(f"不通过 {len(FAIL)} 项：")
        for f in FAIL:
            print("  -", f)
        sys.exit(1)
    print("全部通过")
