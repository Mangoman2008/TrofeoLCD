#!/usr/bin/env python3
"""
preview.py — 仪表盘布局镜像（开发期审图用，不是 App 的渲染代码路径）

用途：在没有 LCD 硬件的情况下，把 Dashboard.ets 的坐标/配色/字号还原成 PNG，
用来检查**布局问题**（重叠、溢出、越界）。

⚠️ 这是手工镜像：改动 Dashboard.ets 的布局后，本文件需要同步修改。
   它的价值在于"能看"，不是"能替代真机"。

用法：python3 tools/preview.py out.png
"""
import sys
import os
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 462   # 与 common/Theme.ets 的 L.height 对齐（原来是电商页的 480）

# ---- Theme.ets 的颜色（逐项对应）----
BG_TOP = (10, 12, 20)
BG_BOT = (16, 18, 28)
PANEL = (20, 23, 34)
PANEL_HI = (26, 30, 44)
BORDER = (38, 42, 58)
TEXT_W = (230, 235, 245)
TEXT_S = (140, 148, 168)
TEXT_L = (100, 108, 130)
TEXT_D = (70, 76, 95)
BLUE = (66, 133, 244)
GREEN = (52, 211, 153)
ORANGE = (251, 191, 36)
RED = (239, 68, 68)
PURPLE = (167, 139, 250)
CYAN = (34, 211, 238)
DEEPSEEK = (77, 107, 254)
BAR_BG = (30, 34, 48)

# ---- L（布局）----
MARGIN = 14
GAP = 10
PANEL_COUNT = 5
# 右侧 480 让给 VM 监视画面，仪表盘只用左侧 1440
VM_WIDTH = 480
DASH_W = W - VM_WIDTH
PANEL_W = (DASH_W - 2 * MARGIN - (PANEL_COUNT - 1) * GAP) / PANEL_COUNT
PANEL_H = H - 2 * MARGIN
PANEL_Y = MARGIN
VM_X = DASH_W + GAP
VM_Y = MARGIN
VM_W = VM_WIDTH - GAP - MARGIN
VM_H = H - 2 * MARGIN


def panel_x(i):
    return MARGIN + i * (PANEL_W + GAP)


FONT_DIR = '/system/fonts'
SANS = os.path.join(FONT_DIR, 'HarmonyOS_Sans_SC.ttf')
DIGIT = os.path.join(FONT_DIR, 'HarmonyOS_Sans_Digit.ttf')
MONO_CANDIDATES = ['DejaVuSansMono.ttf', 'NotoSansMono-Regular.ttf']
MONO = next((os.path.join(FONT_DIR, f) for f in MONO_CANDIDATES
             if os.path.exists(os.path.join(FONT_DIR, f))), DIGIT)

_cache = {}


# 字号总系数：必须与 common/Theme.ets 的 F.scale、win/src/Theme.cs 的 F.Scale 一致，
# 否则这个"布局镜像"量出来的重叠/溢出是假的（放大后才是真机看到的样子）
SCALE = 2.5


def font(size, weight='normal', mono=False):
    path = MONO if mono else SANS
    px = max(1, round(size * SCALE))
    key = (path, px)
    if key not in _cache:
        _cache[key] = ImageFont.truetype(path, px)
    return _cache[key]


def by_percent(pct):
    return GREEN if pct < 50 else (ORANGE if pct < 75 else RED)


def fmt_tokens(n):
    if n >= 100000000:
        return f'{n / 100000000:.2f}亿'
    if n >= 10000:
        return f'{n / 10000:.1f}万'
    return str(n)


class Ctx:
    """模仿 CanvasRenderingContext2D 的最小子集"""

    def __init__(self, img):
        self.d = ImageDraw.Draw(img)
        self.img = img
        self.texts = []   # [(text, (x0,y0,x1,y1), color)]
        self.lines = []   # [(x0,y0,x1,y1)]
        self.boxes = []   # [(x0,y0,x1,y1,fill)]

    def round_rect(self, x, y, w, h, r, fill=None, outline=None, width=1):
        self.d.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=fill,
                                 outline=outline, width=width)
        if fill is not None:
            self.boxes.append((x, y, x + w, y + h, fill))

    def rect(self, x, y, w, h, fill):
        self.d.rectangle([x, y, x + w, y + h], fill=fill)

    def text(self, s, x, y, f, color, align='left'):
        anchor = {'left': 'lm', 'right': 'rm', 'center': 'mm'}[align]
        self.d.text((x, y), s, font=f, fill=color, anchor=anchor)
        if s:
            self.texts.append((s, self.d.textbbox((x, y), s, font=f, anchor=anchor), color))

    def line(self, x1, y1, x2, y2, color):
        self.d.line([x1, y1, x2, y2], fill=color, width=1)
        self.lines.append((x1, y1, x2, y2))

    def arc(self, cx, cy, r, start_deg, end_deg, color, width):
        self.d.arc([cx - r, cy - r, cx + r, cy + r], start=start_deg,
                   end=end_deg, fill=color, width=int(width))

    def measure(self, s, f):
        return self.d.textlength(s, font=f)


def fit_text(ctx, text, f, max_w):
    """单行截断（与 Dashboard.ets 的 fitText 同构）"""
    if not text or ctx.measure(text, f) <= max_w:
        return text
    lo, hi = 0, len(text)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if ctx.measure(text[:mid] + '…', f) <= max_w:
            lo = mid
        else:
            hi = mid - 1
    return text[:lo] + '…'


def wrap(ctx, text, f, max_w, max_lines):
    lines, cur, truncated = [], '', False
    for i, ch in enumerate(text):
        if ch == '\n':
            lines.append(cur)
            cur = ''
            if len(lines) >= max_lines:
                truncated = i < len(text) - 1
                break
            continue
        test = cur + ch
        if ctx.measure(test, f) > max_w and cur:
            lines.append(cur)
            cur = ch
            if len(lines) >= max_lines:
                truncated = True
                cur = ''
                break
        else:
            cur = test
    if cur and len(lines) < max_lines:
        lines.append(cur)
    if truncated and lines:
        last = lines[-1]
        while len(last) > 1 and ctx.measure(last + '…', f) > max_w:
            last = last[:-1]
        lines[-1] = last + '…'
    return lines


def panel(ctx, x, y, w, h, accent, title, right):
    ctx.round_rect(x, y, w, h, 14, fill=PANEL)
    ctx.round_rect(x + 0.5, y + 0.5, w - 1, h - 1, 14, outline=BORDER)
    ctx.round_rect(x + 18, y + 20, 4, 20, 2, fill=accent)
    ctx.text(title, x + 32, y + 31, font(19), accent, 'left')
    if right:
        ctx.text(right, x + w - 18, y + 31, font(16, mono=True), TEXT_L, 'right')


def bar(ctx, x, y, w, h, pct, color):
    ctx.round_rect(x, y, w, h, h / 2, fill=BAR_BG)
    p = max(0.0, min(100.0, pct))
    if p > 0:
        ctx.round_rect(x, y, max(h, w * p / 100), h, h / 2, fill=color)


def fit_text_to(ctx, text, f, panel_w, label_text, label_size):
    """给左侧标签留位置后截断右侧数值（与 Dashboard.valueMaxW 同构）"""
    lab_w = ctx.measure(label_text, font(label_size))
    avail = panel_w - 44 - lab_w - 10
    return fit_text(ctx, text, f, avail if avail > 60 else 60)


def label(ctx, s, x, y, size, color, align='left'):
    ctx.text(s, x, y, font(size), color, align)


def mono(ctx, s, x, y, size, color, align='left'):
    ctx.text(s, x, y, font(size, mono=True), color, align)


# ---------------- 面板 0：SYSTEM ----------------
def system_panel(ctx, x, y, w, h, sys):
    panel(ctx, x, y, w, h, BLUE, 'SYSTEM', '')
    cpu = sys['cpu']
    cx, cy, r = x + w / 2, y + 150, 62
    ctx.arc(cx, cy, r, 0, 360, BAR_BG, 14)
    ctx.arc(cx, cy, r, -90, -90 + 360 * cpu / 100, by_percent(cpu), 14)
    mono(ctx, f'{cpu:.0f}%', cx, cy - 10, 34, TEXT_W, 'center')     # 放大字号后上移，避免压到 cores
    label(ctx, f"{sys['cores']} cores", cx, cy + 30, 15, TEXT_S, 'center')

    mem_pct = (sys['memUsed'] / sys['memTotal'] * 100) if sys['memTotal'] > 0 else 0
    label(ctx, '内存', x + 22, y + 246, 17, TEXT_S)
    mono(ctx, fit_text_to(ctx, f"{sys['memUsed'] / 1024:.1f} / {sys['memTotal'] / 1024:.1f} GB",
                          font(16, mono=True), w, '内存', 17),
         x + w - 22, y + 246, 16, TEXT_W, 'right')
    bar(ctx, x + 22, y + 262, w - 44, 12, mem_pct, GREEN)

    label(ctx, '负载', x + 22, y + 300, 17, TEXT_S)
    mono(ctx, fit_text_to(ctx, f"{sys['load1']:.2f}  {sys['load5']:.2f}  {sys['load15']:.2f}",
                          font(16, mono=True), w, '负载', 17),
         x + w - 22, y + 300, 16, TEXT_W, 'right')

    if sys.get('cpuTemp', -1) >= 0:
        t = sys['cpuTemp']
        col = RED if t >= 85 else (ORANGE if t >= 70 else CYAN)
        label(ctx, 'CPU 温度', x + 22, y + 334, 17, TEXT_S)
        mono(ctx, fit_text_to(ctx, f'{t:.0f}°C', font(16, mono=True), w, 'CPU 温度', 17),
             x + w - 22, y + 334, 16, col, 'right')

    ctx.line(x + 22, y + h - 62, x + w - 22, y + h - 62, BORDER)
    up = sys['uptimeSec']
    up_text = f"up {up // 86400}d {up % 86400 // 3600}h {up % 3600 // 60}m"
    up_font = font(14, mono=True)
    up_w = ctx.measure(up_text, up_font)
    label(ctx, fit_text(ctx, sys['host'], font(16), w - 56 - up_w),
          x + 22, y + h - 38, 16, TEXT_S)
    mono(ctx, up_text, x + w - 22, y + h - 38, 14, TEXT_L, 'right')


# ---------------- 面板 1-3：DEEPSEEK HARNESS ----------------
def agent_panel(ctx, x, y, w, h, t):
    ag = t['agent']
    state = ag['state']
    accent = {'busy': DEEPSEEK, 'waiting': ORANGE, 'idle': GREEN}.get(state, TEXT_L)
    panel(ctx, x, y, w, h, DEEPSEEK, 'DEEPSEEK HARNESS', ag.get('model', ''))

    left_w = int((w - 60) * 0.5)
    mid_x = x + left_w + 30
    seg_w = w - (mid_x - x) - 22

    # 状态徽章
    badge = {'busy': '● 工作中', 'waiting': '◆ 等待输入', 'idle': '○ 空闲'}.get(state, '— 未知')
    bf = font(18)
    bw = ctx.measure(badge, bf) + 40
    bx, by = x + w - 18 - bw, y + 52
    ctx.round_rect(bx, by, bw, 34, 17, fill=accent)
    ctx.text(badge, bx + bw / 2, by + 17, bf, (8, 9, 15), 'center')

    # 左列
    mono(ctx, fit_text(ctx, ag['project'], font(30, mono=True), left_w - 20), x + 22, y + 72, 30, TEXT_W)
    chips = [c for c in [ag.get('provider'), f"turn {ag.get('turn')}",
                         f"step {ag.get('step')}"] if c]
    cxp = x + 22
    chip_limit = x + left_w + 8
    for c in chips:
        cf = font(15, mono=True)
        cw = ctx.measure(c, cf) + 20
        if cxp + cw > chip_limit:
            break
        ctx.round_rect(cxp, y + 96, cw, 26, 13, fill=PANEL_HI)
        mono(ctx, c, cxp + cw / 2, y + 109, 15, TEXT_S, 'center')
        cxp += cw + 8

    label(ctx, fit_text(ctx, ag['activity'], font(22), left_w - 20), x + 22, y + 152, 22, accent)
    if ag.get('tool'):
        tf = font(16, mono=True)
        tool_text = fit_text(ctx, ag['tool'], tf, left_w - 60)
        tw = ctx.measure(tool_text, tf) + 24
        ctx.round_rect(x + 22, y + 176, tw, 28, 6, fill=PANEL_HI)
        mono(ctx, tool_text, x + 34, y + 190, 16, CYAN)

    ly = y + 224
    for ln in wrap(ctx, ag.get('lastText', ''), font(18), left_w - 20, 3):
        label(ctx, ln, x + 22, ly, 18, TEXT_S)
        ly += 26

    ctx.line(x + 22, y + h - 44, x + left_w + 8, y + h - 44, BORDER)
    label(ctx, '数据桥：已连接', x + 22, y + h - 24, 14, TEXT_L)

    # 右列：待办
    label(ctx, '任务进度', mid_x, y + 104, 17, TEXT_S)
    todos = t['todos']
    done = sum(1 for td in todos if td['status'] == 'completed')
    total = len(todos)
    mono(ctx, f'{done}/{total}' if total else '—', x + w - 22, y + 104, 30, TEXT_W, 'right')

    seg_y = y + 124
    if total:
        seg_gap = 4
        item_w = (seg_w - seg_gap * (total - 1)) / total
        for i, td in enumerate(todos):
            sx = mid_x + i * (item_w + seg_gap)
            st = td['status']
            col = GREEN if st == 'completed' else (DEEPSEEK if st == 'in_progress' else BAR_BG)
            ctx.round_rect(sx, seg_y, max(3, item_w), 10, 5, fill=col)
    else:
        bar(ctx, mid_x, seg_y, seg_w, 10, 0, BAR_BG)

    ty = y + 160
    for td in todos[:8]:
        st = td['status']
        glyph, col, tcol = ('✓', TEXT_D, TEXT_D) if st == 'completed' else \
                           (('▶', CYAN, TEXT_S) if st == 'in_progress' else ('○', TEXT_L, TEXT_S))
        label(ctx, glyph, mid_x, ty + 9, 17, col)
        lines = wrap(ctx, td['content'], font(17), seg_w - 26, 1)
        if lines:
            label(ctx, lines[0], mid_x + 22, ty + 9, 17, tcol)
        ty += 32


# ---------------- 面板 4：USAGE ----------------
def usage_panel(ctx, x, y, w, h, t, fs):
    panel(ctx, x, y, w, h, CYAN, 'USAGE', '')
    tk = t['tokens']

    label(ctx, '今日 TOKEN', x + 22, y + 72, 16, TEXT_S)
    mono(ctx, fit_text_to(ctx, fmt_tokens(tk['todayTotal']), font(34, mono=True),
                          w, '今日 TOKEN', 16),
         x + w - 22, y + 72, 34, TEXT_W, 'right')
    label(ctx, f"↑ {fmt_tokens(tk['todayInput'])}  ↓ {fmt_tokens(tk['todayOutput'])}",
          x + w - 22, y + 104, 15, TEXT_L, 'right')

    cpct = (tk['contextUsed'] / tk['contextWindow'] * 100) if tk['contextWindow'] > 0 else 0
    label(ctx, '上下文', x + 22, y + 140, 16, TEXT_S)
    mono(ctx, f'{cpct:.1f}%', x + w - 22, y + 140, 16, TEXT_W, 'right')
    bar(ctx, x + 22, y + 156, w - 44, 12, cpct, by_percent(cpct))

    if tk.get('costUsd') is not None:
        label(ctx, '预估花费', x + 22, y + 194, 16, TEXT_S)
        mono(ctx, f"${tk['costUsd']:.3f}", x + w - 22, y + 194, 16, ORANGE, 'right')

    ctx.line(x + 22, y + 224, x + w - 22, y + 224, BORDER)
    mono(ctx, fit_text(ctx, t['clock'], font(52, mono=True), w - 44), x + w / 2, y + 272, 52,
         TEXT_W, 'center')   # 时钟按可用宽度自适应，别越出面板
    label(ctx, t['date'], x + w / 2, y + 326, 16, TEXT_S, 'center')

    if t.get('weather'):
        label(ctx, t['weather'], x + w / 2, y + 348, 18, CYAN, 'center')
    if t.get('lyrics'):
        lines = wrap(ctx, t['lyrics'], font(16), w - 44, 1)
        if lines:
            label(ctx, lines[0], x + w / 2, y + 382, 16, PURPLE, 'center')

    ctx.line(x + 22, y + h - 46, x + w - 22, y + h - 46, BORDER)
    if fs['usbOpen']:
        usb_txt = f"USB ● {fs['sent']}帧"
    else:
        usb_txt = 'USB ○ 未连接'
    mono(ctx, usb_txt, x + 22, y + h - 26, 13, GREEN if fs['usbOpen'] else TEXT_D)
    mono(ctx, f"桥 ● {fs['bridgeAge']}s", x + w - 22, y + h - 26, 13, GREEN, 'right')



def vm_panel(ctx, x, y, w, h, age_ms=-1):
    """VM 画面区域（镜像）：真机上这里画的是从 livepad 抓来的 PixelMap"""
    ctx.round_rect(x, y, w, h, 14, fill=PANEL)
    ctx.round_rect(x + 0.5, y + 0.5, w - 1, h - 1, 14, outline=BORDER)
    ctx.round_rect(x + 18, y + 20, 4, 20, 2, fill=CYAN)
    ctx.text('VM 画面', x + 32, y + 31, font(19), CYAN, 'left')
    ctx.text('0.3s', x + w - 18, y + 31, font(15, mono=True), TEXT_L, 'right')
    top = y + 52
    inner_h = h - 52 - 14
    inner_w = w - 24
    # 1680x1120 等比放入
    iw, ih = 1680, 1120
    sc = min(inner_w / iw, inner_h / ih)
    dw, dh = iw * sc, ih * sc
    dx = x + (w - dw) / 2
    dy = top + (inner_h - dh) / 2
    ctx.d.fill = None
    ctx.round_rect(dx, dy, dw, dh, 2, fill=(6, 8, 14))
    ctx.text(f'{dw:.0f}x{dh:.0f}', x + w / 2, y + h - 24, font(12, mono=True), TEXT_D, 'center')


def render(data, out):
    img = Image.new('RGB', (W, H), BG_TOP)
    # 背景渐变
    grad = Image.new('RGB', (1, H))
    gd = ImageDraw.Draw(grad)
    for yy in range(H):
        f = yy / (H - 1)
        gd.point((0, yy), fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * f) for i in range(3)))
    img.paste(grad.resize((W, H)), (0, 0))

    ctx = Ctx(img)
    system_panel(ctx, panel_x(0), PANEL_Y, PANEL_W, PANEL_H, data['system'])
    agent_panel(ctx, panel_x(1), PANEL_Y, PANEL_W * 3 + GAP * 2, PANEL_H, data)
    usage_panel(ctx, panel_x(4), PANEL_Y, PANEL_W, PANEL_H, data, data['fs'])
    vm_panel(ctx, VM_X, VM_Y, VM_W, VM_H)
    img.save(out)
    global LAST_CTX
    LAST_CTX = ctx
    return out


LAST_CTX = None

SAMPLE_DATA = {
        'agent': {
            'state': 'busy', 'project': 'WorkBuddy', 'activity': '执行命令',
            'tool': 'bash', 'provider': 'deepseek-official', 'turn': 228, 'step': 2,
            'model': 'deepseek-v4-flash',
            'lastText': '我先去查一下这个屏幕的协议，确认握手参数和分辨率的消歧规则，'
                        '然后再决定渲染管线怎么搭。顺手把分块头的字段顺序核对一遍。',
        },
        'todos': [
            {'content': '验证命令行 HAP 构建通路', 'status': 'completed'},
            {'content': '实现 LY 协议编码器（握手 + 512B 分块）', 'status': 'completed'},
            {'content': '实现 ArkTS 仪表盘渲染（1920×462）', 'status': 'completed'},
            {'content': '实现 USB 推帧与应用内预览', 'status': 'in_progress'},
            {'content': '实现 shell 侧数据桥（尾部 zstd 解压 → UDP）', 'status': 'pending'},
            {'content': '构建签名 HAP 并在真机验证', 'status': 'pending'},
        ],
        'tokens': {'todayTotal': 229085, 'todayInput': 102416, 'todayOutput': 126669,
                   'contextUsed': 674266, 'contextWindow': 1000000, 'costUsd': None},
        'system': {'cpu': 52.1, 'cores': 16, 'memUsed': 20842, 'memTotal': 23859,
                   'load1': 19.37, 'load5': 22.41, 'load15': 23.98,
                   'uptimeSec': 13488, 'host': 'localhost', 'cpuTemp': -1},
        'clock': '21:47:09', 'date': '2026-10-11 周六',
        'weather': None, 'lyrics': None,
        'fs': {'usbOpen': True, 'sent': 1280, 'bridgeAge': 1},
    }
def load_telemetry(path):
    """把 dsh-bridge.mjs 输出的真实遥测 JSON 映射成渲染用的数据结构"""
    import json
    from datetime import datetime
    with open(path, 'r', encoding='utf-8') as f:
        t = json.load(f)
    ag = t.get('agent') or {}
    tk = t.get('tokens') or {}
    sysd = t.get('system') or {}
    wx = t.get('weather') or {}
    ly = t.get('lyrics') or {}

    ts = t.get('ts')
    now = datetime.fromtimestamp(ts / 1000) if ts else datetime.now()
    week = ['一', '二', '三', '四', '五', '六', '日']

    weather_txt = None
    if wx.get('text'):
        weather_txt = wx['text']
        if wx.get('tempC') is not None:
            weather_txt += f" {wx['tempC']:.0f}°C"

    return {
        'agent': {
            'state': ag.get('state') or 'unknown',
            'project': ag.get('project') or '（未知项目）',
            'activity': ag.get('activity') or '空闲',
            'tool': ag.get('tool') or '',
            'provider': ag.get('provider') or '',
            'turn': ag.get('turn') or 0,
            'step': ag.get('step') or 0,
            'model': ag.get('model') or '',
            'lastText': ag.get('lastText') or '',
        },
        'todos': [{'content': td.get('content', ''), 'status': td.get('status', 'pending')}
                  for td in (t.get('todos') or [])],
        'tokens': {
            'todayTotal': tk.get('todayTotal') or 0,
            'todayInput': tk.get('todayInput') or 0,
            'todayOutput': tk.get('todayOutput') or 0,
            'contextUsed': tk.get('contextUsed') or 0,
            'contextWindow': tk.get('contextWindow') or 1000000,
            'costUsd': tk.get('costUsd'),
        },
        'system': {
            'cpu': sysd.get('cpu') or 0,
            'cores': sysd.get('cores') or 0,
            'memUsed': sysd.get('memUsed') or 0,
            'memTotal': sysd.get('memTotal') or 1,
            'load1': sysd.get('load1') or 0,
            'load5': sysd.get('load5') or 0,
            'load15': sysd.get('load15') or 0,
            'uptimeSec': sysd.get('uptimeSec') or 0,
            'host': sysd.get('host') or 'localhost',
            'cpuTemp': sysd.get('cpuTemp', -1),
        },
        'clock': now.strftime('%H:%M:%S'),
        'date': f"{now.strftime('%Y-%m-%d')} 周{week[now.weekday()]}",
        'weather': weather_txt,
        'lyrics': ly.get('line'),
        'fs': {'usbOpen': True, 'sent': int(os.environ.get('SIM_SENT', '1024')),
               'bridgeAge': 1},
    }


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser(description='仪表盘 1:1 布局镜像渲染')
    ap.add_argument('out', nargs='?', default='preview.png')
    ap.add_argument('--data', help='dsh-bridge.mjs --once 输出的遥测 JSON')
    a = ap.parse_args()
    data = load_telemetry(a.data) if a.data else SAMPLE_DATA
    print('已生成', render(data, a.out))
