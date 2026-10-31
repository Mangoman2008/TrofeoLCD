#!/usr/bin/env python3
"""生成 TrofeoLCD 的桌面图标（鸿蒙分层图标：background + foreground + 合成图）。

功能定位 → 符号：一块 1920×462 的超宽副屏（4.16:1，这是这台设备的身份），
屏里是仪表盘（状态点 + 一组高低不等的柱子，最高的一根用绿色），底下带支架。
配色直接取自应用自身：底 #0A0D12→#141A23 渐变、描边 #30363D、柱 #8B949E、
强调色 #238636/#3FB950。远看是"一块超宽屏"，近看是"屏在跑数据"。

产出（全部 1024×1024）：
  AppScope/resources/base/media/background.png   分层图标背景层（圆角方形 + 渐变 + 绿色辉光）
  AppScope/resources/base/media/foreground.png   分层图标前景层（透明底，内容在安全区内）
  AppScope/resources/base/media/app_icon.png     合成图（应用级）
  entry/src/main/resources/base/media/startIcon.png  桌面图标 / 启动页图标（能力级）
  docs/icon-preview.png                          预览对照图（浅底/深底/各种遮罩/实际尺寸）

用法: python3 tools/make_icon.py
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageChops, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 2                     # 超采样倍数（先画 2048 再缩到 1024，边缘才干净）
N = 1024                  # 最终边长
BIG = N * S

# ---------- 调色板（与应用界面一致） ----------
# 关键：底色必须明显亮于屏体，否则缩到 48px 就是一团黑（实测对比只有 29/255）。
# 现在是"蓝灰底板 + 近黑屏体 + 亮柱/绿柱"，小尺寸下依然分得开。
BG_TOP = (0x2E, 0x40, 0x54)   # lum≈62
BG_BOT = (0x1C, 0x28, 0x36)   # lum≈38（必须明显亮于屏体）
GLOW_COOL = (0x33, 0x52, 0x78)     # 左上冷光
GLOW_GREEN = (0x1C, 0x50, 0x34)    # 右下绿光
SCREEN_TOP = (0x07, 0x0A, 0x0E)
SCREEN_BOT = (0x02, 0x04, 0x06)
BORDER = (0x5A, 0x66, 0x74)
HILIGHT = (0x9A, 0xA6, 0xB4)
BAR = (0xC9, 0xD1, 0xD9)           # 普通柱：近白，小尺寸下够亮
BAR_DIM = (0x8B, 0x94, 0x9E)
BAR_HI = (0x3F, 0xB9, 0x50)        # 最高一根 = 绿色
ACCENT = (0x2E, 0xA0, 0x43)
STAND = (0x36, 0x40, 0x4C)
STAND_HI = (0x54, 0x61, 0x70)

R_CORNER = int(0.22 * BIG)         # 圆角半径：与系统模板一致（22%）
SAFE_W, SAFE_H = int(0.586 * BIG), int(0.44 * BIG)   # 前景安全区（模板实测 58% x 44%）


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def vgrad(size, top, bot):
    """竖直渐变（逐行填充，够快）"""
    w, h = size
    im = Image.new('RGB', (1, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        d.point((0, y), fill=lerp(top, bot, y / max(1, h - 1)))
    return im.resize((w, h), Image.BILINEAR)


def radial(size, color, strength, cx=0.5, cy=0.5, radius=1.0):
    """柔和径向光斑：小图当遮罩放大，避免逐像素算距离"""
    small = 128
    m = Image.new('L', (small, small))
    d = ImageDraw.Draw(m)
    for y in range(small):
        for x in range(small):
            dx = (x / (small - 1) - cx) * 2
            dy = (y / (small - 1) - cy) * 2
            r = (dx * dx + dy * dy) ** 0.5 / radius
            v = max(0.0, 1.0 - r)
            m.putpixel((x, y), int(255 * (v ** 2) * strength))
    m = m.resize(size, Image.BICUBIC)
    layer = Image.new('RGBA', size, color + (0,))
    layer.putalpha(m)
    return layer


def rounded_mask(size, radius):
    m = Image.new('L', size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


# ---------------------------------------------------------------- 背景层
def make_background():
    base = vgrad((BIG, BIG), BG_TOP, BG_BOT).convert('RGBA')
    base = Image.alpha_composite(base, radial((BIG, BIG), GLOW_COOL, 0.70, cx=0.30, cy=0.22, radius=1.10))
    base = Image.alpha_composite(base, radial((BIG, BIG), GLOW_GREEN, 0.60, cx=0.76, cy=0.86, radius=1.00))
    # 顶部一条极淡的高光，让圆角有"玻璃"感
    hi = Image.new('L', (BIG, int(BIG * 0.5)), 0)
    hd = ImageDraw.Draw(hi)
    for y in range(hi.size[1]):
        hd.line([(0, y), (BIG, y)], fill=int(26 * (1 - y / hi.size[1]) ** 2))
    base = Image.alpha_composite(base, Image.merge('RGBA', (
        Image.new('L', hi.size, 0xFF), Image.new('L', hi.size, 0xFF),
        Image.new('L', hi.size, 0xFF), hi)).transform(
        (BIG, BIG), Image.AFFINE, (1, 0, 0, 0, 1, 0), resample=Image.BILINEAR))
    base.putalpha(rounded_mask((BIG, BIG), R_CORNER))
    return base.resize((N, N), Image.LANCZOS)


# ---------------------------------------------------------------- 前景层
def make_foreground():
    fg = Image.new('RGBA', (BIG, BIG), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)

    # 屏体：宽度取安全区宽度的 ~0.97，比例按 3:1 画（真机 4.16:1 太细，缩小后没存在感，
    # 3:1 仍明确是"超宽屏"，同时有足够面积画里面的数据）
    sw = int(SAFE_W * 0.99)
    sh = int(sw / 2.70)
    cx = BIG // 2
    top = int(BIG * 0.315)
    left = cx - sw // 2
    right = cx + sw // 2
    bot = top + sh
    r = int(sh * 0.11)

    # 屏体外的绿色辉光（先画，被屏体盖住中间部分 → 形成边缘溢光）
    fg = Image.alpha_composite(fg, radial((BIG, BIG), ACCENT, 0.50,
                                         cx=0.5, cy=(top + sh / 2) / BIG,
                                         radius=(sw / BIG) * 0.95))
    d = ImageDraw.Draw(fg)

    # 屏体：竖向渐变 + 描边
    body = vgrad((sw, sh), SCREEN_TOP, SCREEN_BOT).convert('RGBA')
    body.putalpha(rounded_mask((sw, sh), r))
    fg.alpha_composite(body, (left, top))
    d.rounded_rectangle([left, top, right, bot], radius=r, outline=BORDER + (255,),
                        width=max(2, int(3 * S)))
    # 内顶高光（一条短一点的亮线，模拟屏幕玻璃反光）
    d.rounded_rectangle([left + int(18 * S), top + int(9 * S), right - int(18 * S), top + int(14 * S)],
                        radius=int(3 * S), fill=HILIGHT + (70,))

    pad = int(sw * 0.035)
    inner_top = top + pad
    inner_bot = bot - pad

    # 左侧状态点（绿，带外圈微光）
    dot_r = int(sh * 0.075)
    dcx = left + pad + dot_r
    dcy = (top + bot) // 2
    d.ellipse([dcx - dot_r, dcy - dot_r, dcx + dot_r, dcy + dot_r], fill=BAR_HI + (255,))
    d.ellipse([dcx - int(dot_r * 1.9), dcy - int(dot_r * 1.9),
               dcx + int(dot_r * 1.9), dcy + int(dot_r * 1.9)], outline=BAR_HI + (60,),
              width=max(1, int(2 * S)))

    # 柱子（仪表盘）：高低不等，最高一根绿色
    bars = [0.40, 0.66, 0.50, 1.00, 0.80]
    bx = dcx + int(dot_r * 3.4)
    bx_end = right - pad
    n = len(bars)
    gap = int((bx_end - bx) * 0.13 / max(1, n - 1))
    bw = int(((bx_end - bx) - gap * (n - 1)) / n)
    bw = max(int(4 * S), bw)
    radius_b = max(2, bw // 2)
    for i, hf in enumerate(bars):
        h = int((inner_bot - inner_top) * hf)
        x0 = bx + i * (bw + gap)
        col = BAR_HI if hf >= 1.0 else (BAR if hf > 0.6 else BAR_DIM)
        d.rounded_rectangle([x0, inner_bot - h, x0 + bw, inner_bot], radius=radius_b, fill=col + (255,))

    # 支架：短颈 + 底座（让它读起来是"一块显示器"，而不是一条色带）
    neck_w = int(sw * 0.10)
    neck_h = int(sh * 0.20)
    d.rounded_rectangle([cx - neck_w // 2, bot - int(2 * S), cx + neck_w // 2, bot + neck_h],
                        radius=int(4 * S), fill=STAND + (255,))
    base_w = int(sw * 0.42)
    base_h = int(sh * 0.11)
    d.rounded_rectangle([cx - base_w // 2, bot + neck_h - int(2 * S),
                         cx + base_w // 2, bot + neck_h + base_h],
                        radius=base_h // 2, fill=STAND_HI + (255,))
    # 底座下的绿色反光
    fg = Image.alpha_composite(fg, radial((BIG, BIG), ACCENT, 0.18, cx=0.5,
                                         cy=(bot + neck_h + base_h + int(sh * 0.30)) / BIG,
                                         radius=0.24))
    d = ImageDraw.Draw(fg)
    d.rounded_rectangle([cx - base_w // 2, bot + neck_h - int(2 * S),
                         cx + base_w // 2, bot + neck_h + base_h],
                        radius=base_h // 2, fill=STAND_HI + (255,))
    d.rounded_rectangle([cx - neck_w // 2, bot - int(2 * S), cx + neck_w // 2, bot + neck_h],
                        radius=int(4 * S), fill=STAND + (255,))

    # 地面倒影：把整块屏垂直翻转、渐隐、模糊后压在底座下方。
    # 只是"哑光桌面反射"的暗示（峰值 alpha 仅 ~46），多了就发浑。
    mark_bot = bot + neck_h + base_h
    refl = fg.crop((max(0, left - int(20 * S)), top, min(BIG, right + int(20 * S)), mark_bot))
    refl = refl.transpose(Image.FLIP_TOP_BOTTOM)
    rh = refl.size[1]
    fade = Image.new('L', refl.size, 0)
    fd = ImageDraw.Draw(fade)
    for y in range(rh):
        fd.line([(0, y), (refl.size[0], y)], fill=int(46 * (1 - y / rh) ** 3))
    refl.putalpha(ImageChops.multiply(refl.split()[3], fade))
    refl = refl.filter(ImageFilter.GaussianBlur(radius=5 * S))
    fg.alpha_composite(refl, (max(0, left - int(20 * S)), mark_bot - int(6 * S)))
    return fg.resize((N, N), Image.LANCZOS)


# ---------------------------------------------------------------- 合成 + 预览
def composite(bg, fg):
    out = Image.alpha_composite(bg, fg)
    # 合成图也裁成圆角方形，桌面/启动页显示时和系统遮罩一致
    out.putalpha(rounded_mask((N, N), int(0.22 * N)))
    return out


def mask_circle(im, size):
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).ellipse([0, 0, size - 1, size - 1], fill=255)
    out = im.resize((size, size), Image.LANCZOS).convert('RGBA')
    out.putalpha(m)
    return out


def mask_squircle(im, size, r=0.34):
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * r), fill=255)
    out = im.resize((size, size), Image.LANCZOS).convert('RGBA')
    out.putalpha(m)
    return out


def mask_rounded(im, size, r=0.22):
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * r), fill=255)
    out = im.resize((size, size), Image.LANCZOS).convert('RGBA')
    out.putalpha(m)
    return out


def font(sz):
    try:
        return ImageFont.load_default(size=sz)
    except TypeError:
        return ImageFont.load_default()


def make_preview(icon):
    W, H = 1180, 940
    DARK = (0x0D, 0x11, 0x17, 255)
    LIGHT = (0xF2, 0xF4, 0xF7, 255)
    sheet = Image.new('RGBA', (W, H), DARK)
    d = ImageDraw.Draw(sheet)
    f14, f12 = font(20), font(17)

    def paste_masked(img, box, bgcolor):
        x, y, s = box
        tile = Image.new('RGBA', (s, s), bgcolor)
        tile.alpha_composite(img)
        sheet.alpha_composite(tile, (x, y))

    # 行1：深底 / 浅底 大图
    d.text((28, 20), 'TrofeoLCD icon - 桌面图标（鸿蒙分层图标合成结果）', font=f14, fill=(0xE6, 0xED, 0xF3, 255))
    paste_masked(icon.resize((300, 300), Image.LANCZOS), (60, 58, 300), DARK)
    paste_masked(icon.resize((300, 300), Image.LANCZOS), (420, 58, 300), LIGHT)
    d.text((60, 366), '深色底（实际桌面）', font=f12, fill=(0x8B, 0x94, 0x9E, 255))
    d.text((420, 366), '浅色底（检查边缘）', font=f12, fill=(0x48, 0x4F, 0x58, 255))

    # 行2：三种遮罩
    d.text((800, 20), '系统遮罩适配', font=f14, fill=(0xE6, 0xED, 0xF3, 255))
    for i, (mk, nm) in enumerate([(mask_circle, '圆形'), (mask_squircle, '超椭圆'), (mask_rounded, '圆角方')]):
        s = 120
        tile = Image.new('RGBA', (s, s), DARK)
        tile.alpha_composite(mk(icon, s))
        sheet.alpha_composite(tile, (800, 58 + i * 138))
        d.text((936, 100 + i * 138), nm, font=f12, fill=(0x8B, 0x94, 0x9E, 255))

    # 行3：真实尺寸（浅底一排 + 深底一排）
    y0 = 440
    d.text((28, y0 - 30), '实际显示尺寸（上排浅底 / 下排深底）', font=f14, fill=(0xE6, 0xED, 0xF3, 255))
    sizes = [192, 144, 96, 72, 64, 48, 32]
    x = 40
    for s in sizes:
        paste_masked(icon.resize((s, s), Image.LANCZOS), (x, y0, s), LIGHT)
        paste_masked(icon.resize((s, s), Image.LANCZOS), (x, y0 + 210, s), DARK)
        d.text((x, y0 + 200 - 22), f'{s}px', font=f12, fill=(0x8B, 0x94, 0x9E, 255))
        x += s + 26

    # 行4：声明（分层图与安全区自检）
    ok, msg = check_safe(icon)
    d.text((28, H - 96), '分层图标自检', font=f14, fill=(0xE6, 0xED, 0xF3, 255))
    d.text((28, H - 64), msg, font=f12, fill=((0x3F, 0xB9, 0x50, 255) if ok else (0xF8, 0x51, 0x49, 255)))
    d.text((28, H - 34), '生成脚本 tools/make_icon.py（可重复运行，结果确定）', font=f12,
           fill=(0x48, 0x4F, 0x58, 255))
    return sheet.convert('RGB')


def check_safe(fg_or_icon):
    """前景内容必须落在系统安全区内，否则圆形遮罩会切掉边角。

    分两个量：实心内容（alpha≥24，真正的图形）必须完全在安全区内；
    辉光（alpha>0 的柔光）只要不超过整幅即可——被遮罩切掉的是柔光边缘，看不出来。
    """
    fgp = os.path.join(ROOT, 'AppScope/resources/base/media/foreground.png')
    if not os.path.exists(fgp):
        return True, '（首次生成，跳过）'
    im = Image.open(fgp).convert('RGBA')
    a = im.split()[3]
    solid = a.point(lambda v: 255 if v >= 24 else 0).getbbox()
    if solid is None:
        return False, '前景层没有实心内容'
    bb = solid
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    lim_w, lim_h = int(0.60 * 1024), int(0.46 * 1024)
    cx, cy = 512, 512
    corners = [(bb[0], bb[1]), (bb[2], bb[1]), (bb[0], bb[3]), (bb[2], bb[3])]
    far = max(((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 for x, y in corners)
    ok = w <= lim_w and h <= lim_h and far <= 512 * 0.98
    return ok, (f'实心内容 {w}x{h}px（上限 {lim_w}x{lim_h}）；最远角距中心 {far:.0f}px '
                f'（上限 502）→ ' + ('通过，圆形/超椭圆遮罩都不会切到' if ok else '超界，需要缩小'))


def render_simple(size):
    """小尺寸（16/24/32）专用简化版：去掉支架与倒影、柱子加粗。

    图钉大小下细节只会糊成一团 —— 简化版只保留"深色底板 + 近黑超宽屏 + 三根亮柱（一根绿）"，
    这是缩到 16px 还能认出来的最小信息量。
    """
    K = 8
    n = size * K
    im = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, n - 1, n - 1], radius=int(0.22 * n), fill=BG_TOP + (255,))
    sw = int(n * 0.74)
    sh = int(sw / 2.6)
    x0 = (n - sw) // 2
    y0 = (n - sh) // 2
    d.rounded_rectangle([x0, y0, x0 + sw, y0 + sh], radius=max(1, int(sh * 0.13)),
                        fill=(4, 6, 9, 255), outline=(0x5A, 0x66, 0x74, 255),
                        width=max(1, int(n * 0.010)))
    pad = int(sw * 0.11)
    bars = [0.45, 0.72, 1.00]
    bw = int(sw * 0.17)
    gap = int((sw - 2 * pad - bw * 3) / 2)
    bx = x0 + pad
    for hf in bars:
        h = int((sh - 2 * pad) * hf)
        col = BAR_HI if hf >= 1.0 else BAR
        d.rounded_rectangle([bx, y0 + sh - pad - h, bx + bw, y0 + sh - pad],
                            radius=max(1, bw // 2), fill=col + (255,))
        bx += bw + gap
    return im.resize((size, size), Image.LANCZOS)


ICO_SIZES = [256, 128, 64, 48, 32, 24, 16]


def make_ico(icon):
    """Windows exe 图标：<=32px 用简化版，其余用细节版（同一个设计，两套绘制）"""
    imgs = []
    for s in ICO_SIZES:
        imgs.append(render_simple(s) if s <= 32 else icon.resize((s, s), Image.LANCZOS))
    p = os.path.join(ROOT, 'win/icon/dshlcd.ico')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    imgs[0].save(p, format='ICO', sizes=[(s, s) for s in ICO_SIZES], append_images=imgs[1:])
    return p


def save(img, rel):
    p = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    img.save(p, 'PNG', optimize=True)
    return f'{os.path.getsize(p):>7} B  {img.size}  {rel}'


def main():
    bg = make_background()
    fg = make_foreground()
    icon = composite(bg, fg)
    print(save(bg, 'AppScope/resources/base/media/background.png'))
    print(save(fg, 'AppScope/resources/base/media/foreground.png'))
    print(save(icon, 'AppScope/resources/base/media/app_icon.png'))
    print(save(icon, 'entry/src/main/resources/base/media/startIcon.png'))
    prev = make_preview(icon)
    print(save(prev, 'docs/icon-preview.png'))
    ico = make_ico(icon)
    print(f'{os.path.getsize(ico):>7} B  {ICO_SIZES}  win/icon/dshlcd.ico')
    ok, msg = check_safe(icon)
    print(('✅ ' if ok else '❌ ') + msg)


if __name__ == '__main__':
    main()
