#!/usr/bin/env python3
"""
make_sim.py — 生成 1:1 仿真页（自包含 HTML，双击即可看）

做三件事：
  1. 取数据：--data <json>（dsh-bridge.mjs --once 的输出）；不给则用内置示例
  2. 用 preview.py 的布局镜像渲染 1:1 PNG（正好 1920x462）
  3. 把 PNG 以 base64 内嵌进一个自包含 HTML（带 1:1 / 适应宽度 缩放切换）

用法：
  python3 tools/make_sim.py                                   # 示例数据
  python3 tools/make_sim.py --data /tmp/live.json             # 真实数据
  python3 tools/make_sim.py --live --weather 北京             # 直接调桥取实时数据
"""
import argparse
import base64
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import preview  # noqa: E402

HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>利民 9.16" LCD — 1:1 仿真页</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 20px 16px 40px;
    background: #07080c; color: #c9d1e0;
    font: 14px/1.6 "HarmonyOS Sans SC", "Noto Sans CJK SC", system-ui, sans-serif;
  }}
  header {{ max-width: 1920px; margin: 0 auto 14px; }}
  h1 {{ font-size: 17px; margin: 0 0 4px; color: #e6ebf5; font-weight: 600; }}
  .meta {{ font-size: 12px; color: #646c82; }}
  .meta b {{ color: #8c94a8; font-weight: 500; }}
  .bar {{
    max-width: 1920px; margin: 0 auto 12px; display: flex; gap: 8px;
    flex-wrap: wrap; align-items: center;
  }}
  button {{
    background: #141722; color: #c9d1e0; border: 1px solid #262a3a;
    border-radius: 7px; padding: 6px 13px; font-size: 13px; cursor: pointer;
  }}
  button:hover {{ background: #1a1e2c; }}
  button.on {{ background: #4d6bfe; border-color: #4d6bfe; color: #fff; }}
  .hint {{ font-size: 12px; color: #464c5f; margin-left: auto; }}
  .scroll {{
    max-width: 1920px; margin: 0 auto; overflow: auto;
    border: 1px solid #262a3a; border-radius: 12px; background: #000;
  }}
  /* 模拟屏体：16:4 的窄长条，外圈是屏幕边框 */
  .bezel {{ padding: 10px; background: #0c0e15; display: inline-block; }}
  img {{ display: block; width: 1920px; height: 462px; image-rendering: auto; }}
  .warn {{
    max-width: 1920px; margin: 12px auto 0; font-size: 12px; color: #8a7126;
    border-left: 2px solid #6b5613; padding-left: 10px;
  }}
</style>
</head>
<body>
<header>
  <h1>利民 Trofeo Vision 9.16 LCD — 1:1 仿真页</h1>
  <div class="meta">
    <b>分辨率</b> {w}×{h} · <b>生成时间</b> {generated} · <b>数据源</b> {source}
  </div>
</header>

<div class="bar">
  <button id="b100">1:1（100%）</button>
  <button id="bfit" class="on">适应宽度</button>
  <button id="b50">50%</button>
  <button id="b25">25%</button>
  <span class="hint">滚轮/拖动可平移 · 1:1 时是屏幕上的真实像素尺寸</span>
</div>

<div class="scroll" id="scroll">
  <div class="bezel"><img id="shot" src="data:image/png;base64,{b64}" alt="LCD 仪表盘 1:1"></div>
</div>

<div class="warn">
  这是 <code>tools/preview.py</code> 的布局镜像（PIL 绘制），用于在无硬件时审图；
  它与 App 里的 <code>Dashboard.ets</code> 是两套坐标的手工同步，最终画面以真机为准。
  数据：{source}
</div>

<script>
const img = document.getElementById('shot');
const btns = ['b100', 'bfit', 'b50', 'b25'].map(i => document.getElementById(i));
function setScale(px) {{
  img.style.width = px + 'px';
  img.style.height = (px * {h} / {w}) + 'px';
}}
function mark(el) {{ btns.forEach(b => b.classList.toggle('on', b === el)); }}
document.getElementById('b100').onclick = e => {{ setScale({w}); mark(e.target); }};
document.getElementById('b50').onclick  = e => {{ setScale({w} / 2); mark(e.target); }};
document.getElementById('b25').onclick  = e => {{ setScale({w} / 4); mark(e.target); }};
document.getElementById('bfit').onclick = e => {{
  const avail = document.getElementById('scroll').clientWidth - 22;
  setScale(Math.min({w}, avail)); mark(e.target);
}};
window.addEventListener('resize', () => {{
  if (document.getElementById('bfit').classList.contains('on')) setScale(
    Math.min({w}, document.getElementById('scroll').clientWidth - 22));
}});
document.getElementById('bfit').click();
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', help='桥输出的遥测 JSON 路径')
    ap.add_argument('--live', action='store_true', help='直接调用桥取实时数据')
    ap.add_argument('--weather', default='', help='--live 时顺带取天气（城市名）')
    ap.add_argument('--png', default=os.path.join(HERE, 'preview.png'))
    ap.add_argument('--out', default=os.path.join(HERE, 'sim.html'))
    a = ap.parse_args()

    source = '内置示例数据'
    if a.live:
        cmd = ['node', os.path.join(ROOT, 'bridge', 'dsh-bridge.mjs'), '--once']
        if a.weather:
            cmd += ['--weather', a.weather]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if out.returncode != 0:
            print('调桥失败:', out.stderr[-500:], file=sys.stderr)
            return 1
        text = out.stdout[out.stdout.index('{'):]
        a.data = os.path.join(HERE, '.live.json')
        with open(a.data, 'w', encoding='utf-8') as f:
            f.write(text)
        source = f'实时数据（dsh-bridge.mjs --once，{os.path.basename(a.data)}）'

    data = preview.load_telemetry(a.data) if a.data else preview.SAMPLE_DATA
    preview.render(data, a.png)

    from PIL import Image
    with Image.open(a.png) as im:
        w, h = im.size
    with open(a.png, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode('ascii')

    import datetime
    html = HTML.format(w=w, h=h, b64=b64, source=source,
                       generated=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f'1:1 图像: {a.png}  ({w}x{h})')
    print(f'仿真页  : {a.out}  ({os.path.getsize(a.out) / 1024:.0f} KB, 自包含)')
    if (w, h) != (1920, 462):
        print(f'⚠️ 尺寸不是 1920x462，而是 {w}x{h}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
