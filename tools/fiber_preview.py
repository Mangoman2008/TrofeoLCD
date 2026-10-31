#!/usr/bin/env python3
"""
fiber_preview.py —— 把 web/dashboard.html 里的「光纤 + 黑洞 + 步骤光包」渲染成 PNG，用来核对几何。

为什么需要它：
  · 本机没有浏览器，也没有 SVG 光栅化器（rsvg/cairosvg/inkscape 都没有），
    页面里的动效我看不到，只能靠"读代码"确认 —— 这条路已经错过一次（黑洞会不会压到标题、
    光纤是不是真的从黑洞边缘长出来，光靠读代码看不出来）。
  · 做法：**把页面里那段生成 SVG 的 JS 真跑一遍**（node + 假 DOM），拿到与浏览器里
    完全相同的几何；再用 PIL 复刻成图。CSS 动画（自转/dash/闪烁）不会体现，
    但**位置、尺寸、层次、是否压字**这些几何问题全都能看出来。

用法：
  python3 tools/fiber_preview.py                     # → .build-output/fiber-preview.png
  python3 tools/fiber_preview.py --out /tmp/x.png    # 指定输出（本机 /tmp 只读，别用）
  python3 tools/fiber_preview.py --packets 3         # 预览里画几个光包（默认 2）
"""
import io
import os
import re
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, 'web', 'dashboard.html')
W, H = 1920, 462
ZONE_X = [300, 1080, 1500]          # 与 dashboard.html 的 grid-template-columns 一致
TRUNK_Y = [13, 19, 25, 31, 37]
TRUNK_C = ['#39d0ff', '#a06bff', '#3ff0d8', '#39a8ff', '#ff6fd8']

BG = (3, 7, 12)
GRID = (10, 26, 38)
TEXT = (215, 236, 251)
DIM = (81, 112, 137)


def extract_svg(packets=2):
    """跑页面里那段 JS，拿回它生成的 SVG（与浏览器里逐字节相同）"""
    html = io.open(HTML, encoding='utf-8').read()
    js = re.search(r'<script>([\s\S]*?)</script>', html).group(1)
    start = js.index('const ZONE_X')
    end = js.index('/** 时间线光纤上的下流光脉冲')
    code = js[start:end]
    harness = """
const esc = (s) => String(s ?? '')
const clip = (s, n) => { s = String(s ?? ''); return s.length > n ? s.slice(0, n - 1) + '…' : s }
function mk(tag){return{tag,attrs:{},innerHTML:'',textContent:'',style:{},dataset:{},kids:[],handlers:{},offsetWidth:1,
  classList:{add(){},remove(){},contains(){return false}},
  setAttribute(k,v){this.attrs[k]=v},getAttribute(k){return this.attrs[k]},appendChild(c){this.kids.push(c)},
  addEventListener(t,f){this.handlers[t]=f},remove(){this.removed=true},getBoundingClientRect(){return{}}}}
const $ = (id) => (id === 'fiberNet' ? fiberNet : id === 'stepBadge' ? badge : mk(id))
const fiberNet = mk('fiberNet'), badge = mk('badge')
globalThis.stubEl = (id) => (id === 'fiberNet' ? fiberNet : id === 'stepBadge' ? badge : mk(id))
globalThis.document = {
  createElementNS: (ns, tag) => mk(tag),
  querySelectorAll: () => [0,1,2,3].map(() => mk('z')),
}
""" + code + """
// 网络本体
buildFiber()
// 再造几个"步骤光包"，模拟运行时（标签取真实数据里的样子）
const demo = [
  ['tool', 'bash · cd /storage/Users/currentUser/WorkBuddy/TrofeoLCD; ls -la', 690],
  ['assistant', '思考「现在写可视化面板 UI —— 用 Canvas 画光纤质感的」', 690],
  ['jev', 'JEV needs_human=0.23  risk=1.40  continue=0.81', 1290],
  ['usage', '用量 今日 44.8 万 token', 1710],
]
for (let i = 0; i < PACKETS; i++) spawnPacket(demo[i % demo.length][0], demo[i % demo.length][1], demo[i % demo.length][2])
console.log(JSON.stringify({ net: fiberNet.innerHTML, pkts: globalThis.__pkts || [] }))
""".replace('PACKETS', str(packets))
    # spawnPacket 里把节点 append 到 fiberNet.kids，这里把它们也吐出来
    harness = harness.replace("console.log(JSON.stringify({ net: fiberNet.innerHTML, pkts: globalThis.__pkts || [] }))",
                              "console.log(JSON.stringify({ net: fiberNet.innerHTML, kids: fiberNet.kids.map(k => ({ cls: k.attrs.class, path: k.style.offsetPath, html: k.innerHTML })) }))")
    harness = harness.replace("globalThis.document = {", "globalThis.__mk = mk\nglobalThis.document = {")
    harness = harness.replace("createElementNS: (ns, tag) => mk(tag),", "createElementNS: (ns, tag) => globalThis.__mk(tag),")
    # ★ 不用 tempfile：本机 TMPDIR 指向用户主目录，会在 ~ 下留临时文件。
    #   统一写到工程的 .build-output/ 里，跑完删掉。
    scratch = os.path.join(ROOT, '.build-output')
    os.makedirs(scratch, exist_ok=True)
    path = os.path.join(scratch, '.fiber-harness.mjs')
    io.open(path, 'w', encoding='utf-8').write(harness)
    try:
        out = subprocess.run(['node', path], capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            sys.stderr.write(out.stderr[-2000:])
            raise SystemExit('node 侧生成失败')
        import json
        return json.loads(out.stdout.strip().split('\n')[-1])
    finally:
        os.unlink(path)


def hex2rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def draw_line(d, pts, color, width):
    d.line([tuple(p) for p in pts], fill=color, width=width, joint='curve')


def text_size(txt, size):
    try:
        f = ImageFont.truetype('/system/fonts/HarmonyOS_Sans_SC_Regular.ttf', size)
    except Exception:
        try:
            f = ImageFont.truetype('DejaVuSansMono.ttf', size)
        except Exception:
            f = ImageFont.load_default()
    return f


def render(data, packets=2):
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)
    glow = Image.new('RGB', (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)

    # 背景网格
    for x in range(0, W, 32):
        d.line([(x, 0), (x, H)], fill=GRID)
    for y in range(0, H, 32):
        d.line([(0, y), (W, y)], fill=GRID)
    # 顶栏与分区线
    d.line([(0, 42), (W, 42)], fill=(22, 50, 74))
    for x in ZONE_X:
        d.line([(x, 42), (x, H)], fill=(11, 26, 38))
    for x, label in [(14, 'AGENT DASHBOARD'), (0, ''), (ZONE_X[0] + 12, 'DEEPSEEK HARNESS · 当前在做'),
                     (ZONE_X[1] + 12, 'JEV 决策'), (ZONE_X[2] + 12, '用量 / 副屏')]:
        if label and x:
            d.text((x + 104 if x == 14 else x, 14), label, font=text_size(label, 14), fill=TEXT if x == 14 else (207, 232, 248))

    # ── 光纤：护套 + 芯 + 流动光（静态复刻，dash 相位随便取）──
    for i, y in enumerate(TRUNK_Y):
        c = hex2rgb(TRUNK_C[i % len(TRUNK_C)])
        draw_line(d, [(78, y), (1906, y)], (11, 33, 48), 6)
        draw_line(d, [(78, y), (1906, y)], tuple(int(v * (0.9 - i * 0.1)) for v in c), 2)
        draw_line(gd, [(78, y), (1906, y)], tuple(int(v * (0.9 - i * 0.1)) for v in c), 3)
        # 流动光：按 dash 8/24 抽样几段
        for x0 in range(78 + i * 9, 1906, 32):
            draw_line(d, [(x0, y), (min(1906, x0 + 8), y)], (234, 247, 255), 1)
    for x in ZONE_X:
        c = hex2rgb(TRUNK_C[ZONE_X.index(x) % len(TRUNK_C)])
        draw_line(d, [(x, 42), (x, 458)], (11, 33, 48), 6)
        draw_line(d, [(x, 42), (x, 458)], c, 2)
        draw_line(gd, [(x, 42), (x, 458)], c, 3)
        for y0 in range(52, 458, 52):
            draw_line(d, [(x, y0), (x, min(458, y0 + 12))], (234, 247, 255), 1)
        d.ellipse([x - 4, TRUNK_Y[2] - 4, x + 4, TRUNK_Y[2] + 4], outline=c, width=2)
    for x in (150, 690, 1290, 1710):
        c = hex2rgb(TRUNK_C[(x % 4 + 1) % len(TRUNK_C)])
        draw_line(d, [(x, TRUNK_Y[4]), (x, 74)], (11, 33, 48), 6)
        draw_line(d, [(x, TRUNK_Y[4]), (x, 74)], c, 2)

    # ── 黑洞 ──
    cx, cy, R = 48, 27, 28
    for r, a in [(78, 0.10), (60, 0.16), (42, 0.22)]:
        gd.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(57, 208, 255), width=3)
    d.ellipse([cx - 42, cy - 9.5, cx + 42, cy + 9.5], outline=(57, 208, 255), width=3)     # 吸积盘
    d.ellipse([cx - 51, cy - 12, cx + 51, cy + 12], outline=(160, 107, 255), width=2)      # 外盘
    d.ellipse([cx - 32, cy - 5.6, cx + 32, cy + 5.6], outline=(255, 255, 255), width=2)    # 内热盘
    d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=(0, 0, 0))                            # 事件视界
    d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=(242, 251, 255), width=1)          # 光子环
    gd.ellipse([cx - R, cy - R, cx + R, cy + R], outline=(242, 251, 255), width=3)
    # 极向喷流
    for (y0, y1) in [(0, -34), (54, 88)]:
        for k in range(10):
            t = k / 9
            yy = y0 + (y1 - y0) * t
            d.line([(cx, yy), (cx, yy + 2)], fill=(143, 232, 255), width=max(1, int(3 * (1 - t))))
            gd.line([(cx, yy), (cx, yy + 2)], fill=(143, 232, 255), width=max(1, int(3 * (1 - t))))

    # ── 光包（沿 path 取固定进度，直观核对"从黑洞飞到分区"的路径）──
    demo_progress = [0.18, 0.42, 0.66, 0.86]
    for i, k in enumerate(data.get('kids', [])[:packets]):
        m = re.search(r"path\('M (\d+) (\d+) L (\d+) (\d+) L (\d+) (\d+)'\)", k.get('path') or '')
        if not m:
            continue
        x0, y0, x1, y1, x2, y2 = [float(v) for v in m.groups()]
        t = demo_progress[i % len(demo_progress)]
        if t < 0.72:                       # 先沿总线水平飞
            px = x0 + (x1 - x0) * (t / 0.72)
            py = y0
        else:                              # 再沿支线下降
            px = x1
            py = y1 + (y2 - y1) * ((t - 0.72) / 0.28)
        label = re.search(r'<text[^>]*>([^<]*)<', k.get('html') or '')
        label = label.group(1) if label else ''
        col = {'tool': (57, 208, 255), 'assistant': (94, 242, 160), 'user': (255, 111, 216),
               'todo': (160, 107, 255), 'jev': (160, 107, 255), 'usage': (63, 240, 216)}.get(k.get('cls', '').split()[-1], (57, 208, 255))
        for rr, w in [(9, 1), (6, 1), (3, 3)]:
            gd.ellipse([px - rr, py - rr, px + rr, py + rr], outline=col, width=w)
        d.ellipse([px - 3, py - 3, px + 3, py + 3], fill=(255, 255, 255))
        if label:
            d.text((px + 10, py - 16), label[:60], font=text_size(label[:60], 13), fill=(234, 247, 255))

    img = Image.blend(img, Image.blend(img, glow.filter(ImageFilter.GaussianBlur(4)), 0.85), 0.55)
    return img


def main():
    out = os.path.join(ROOT, '.build-output', 'fiber-preview.png')
    packets = 2
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == '--out' and i + 1 < len(args):
            out = args[i + 1]
        if a == '--packets' and i + 1 < len(args):
            packets = int(args[i + 1])
    os.makedirs(os.path.dirname(out), exist_ok=True)
    data = extract_svg(packets)
    img = render(data, packets)
    img.save(out)
    print('几何核对图 → %s  (%d×%d, %d 字节)' % (out, img.width, img.height, os.path.getsize(out)))
    print('光包数：%d ｜ 光纤元素：%d 字节 SVG' % (len(data.get('kids', [])), len(data.get('net', ''))))


if __name__ == '__main__':
    main()
