#!/usr/bin/env python3
"""layout_check.py —— 布局审计：**直接跑真源码** Dashboard.ets，检查文字框的越界与重叠。

和以前版本的差别（重要）：以前这里审计的是 tools/preview.py —— 一份**手工镜像**。
后果是改真源码时镜像不会跟着动，"审计通过"与真机是否重叠毫无关系
（1.8× 字号那一轮就踩了：改了 ArkTS，审计报出来的问题一模一样，因为它在看旧镜像）。

现在的链路：
  entry/.../render/Dashboard.ets  --(Node 剥类型)-->  .verify/render/Dashboard.ts
        --(canvas 打桩记录每个文字框)-->  JSON  -->  本脚本检查

检查项：
  1. 文字越出画布（1920×462）
  2. 文字越出所属面板
  3. 文字之间重叠（同面板两两比，10% 以上算问题）
  4. 文字压到面板内的横线

用法： python3 tools/layout_check.py [--vertical]
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
V = os.path.join(ROOT, '.verify')
NODE = 'node'


def load_files():
    """转译清单 —— 与 run_selftest.sh 共用 tools/ets_files.txt（2026-10-31 C3）。

    此前两边各维护一份、各自带一份剥类型实现，漏同步翻车三次
    （ThemeDotiiCell / ThemeSnake+mario 链 / ThemeAnime —— 主题 10 审计崩溃一轮）。
    引擎统一走 tools/ets_to_ts.py（enum 转换 + kit 打桩 + 相对导入补 .ts）。
    """
    path = os.path.join(HERE, 'ets_files.txt')
    with open(path, encoding='utf-8') as fh:
        return [l.strip() for l in fh
                if l.strip() and not l.strip().startswith('#')]


def prepare():
    """把真源码剥成 Node 能跑的 .ts —— 逐文件委托 tools/ets_to_ts.py。"""
    for f in load_files():
        src = os.path.join(ROOT, 'entry/src/main/ets', f + '.ets')
        dst = os.path.join(V, f + '.ts')
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        subprocess.run([sys.executable, os.path.join(HERE, 'ets_to_ts.py'), src, dst],
                       check=True)
    # @kit 桩：ets_to_ts.py 把 kit 导入重写到 '../kitstub/<name>.ts'，
    # 桩本体在 tools/kitstubs/ 维护（与 run_selftest.sh 共用）。
    dst = os.path.join(V, 'kitstub')
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(os.path.join(HERE, 'kitstubs')):
        shutil.copy(os.path.join(HERE, 'kitstubs', name), os.path.join(dst, name))


def write_hoststats_stub():
    """给布局审计用的 HostStats 桩。

    ★ 为什么需要（2026-10-15 补）：
      `service/HostStats.ets` 依赖三个**鸿蒙专属 kit**（`@kit.PerformanceAnalysisKit`
      / `@kit.BasicServicesKit` / `@kit.CoreFileKit`），在 Node 里跑不起来。
      而主题 15（`ThemeTrofeoRust`）会 import 它 → 报"找不到模块"，整个审计跑不动。
      所以这里生成一个**确定性桩**：字段与真 `HostSnapshot` 一致、值固定
      → 审计结果可复现，也不会因本机实时负载而抖动。

      桩只影响**布局审计**（只看文字框越界/重叠），不影响真机渲染。
    """
    dst = os.path.join(V, 'service', 'HostStats.ts')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    body = "// auto-generated: HostStats stub for layout audit (see layout_check.py)\n"
    body += "export class HostSnapshot {\n"
    body += "  cpuPct: number = 37;\n"
    body += "  cores: number = 8;\n"
    body += "  memUsedMB: number = 9344;\n"
    body += "  memTotalMB: number = 16384;\n"
    body += "  batteryPct: number = 76;\n"
    body += "  charging: boolean = true;\n"
    body += "  netRxKBs: number = 128.5;\n"
    body += "  netTxKBs: number = 12.25;\n"
    body += "  diskUsedPct: number = 62;\n"
    body += "  diskTotalGB: number = 512;\n"
    body += "  valid: boolean = true;\n"
    body += "}\n"
    body += "export class HostStats {\n"
    body += "  private static snap: HostSnapshot = new HostSnapshot();\n"
    body += "  static get(): HostSnapshot { return HostStats.snap; }\n"
    body += "  static available(): boolean { return true; }\n"
    body += "  static note(): string { return 'stub'; }\n"
    body += "}\n"
    with open(dst, 'w', encoding='utf-8') as fh:
        fh.write(body)


def render(vertical: bool, theme: int = 0, no_toast: bool = False, page: int = 0):
    args = [NODE, '--experimental-strip-types', 'tools/hwsim/layout_real.mts']
    if page:
        args.append('--page=%d' % page)
    if vertical:
        args.append('--vertical')
    if theme:
        args.append('--theme=%d' % theme)
    if no_toast:
        args.append('--no-toast')
    if '--printer-error' in sys.argv:
        args.append('--printer-error')
    for a in sys.argv:
        if a.startswith('--page='):
            args.append(a)
    p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=180)
    if p.returncode != 0:
        print('❌ 真源码渲染失败：')
        print(p.stderr[-2000:])
        sys.exit(2)
    line = [l for l in p.stdout.splitlines() if l.startswith('{')][-1]
    return json.loads(line)


def overlap(a, b):
    """返回重叠面积与较小者面积之比"""
    w = min(a['right'], b['right']) - max(a['left'], b['left'])
    h = min(a['bottom'], b['bottom']) - max(a['top'], b['top'])
    if w <= 0 or h <= 0:
        return 0.0
    inter = w * h
    small = min((a['right'] - a['left']) * (a['bottom'] - a['top']),
                (b['right'] - b['left']) * (b['bottom'] - b['top']))
    return inter / small if small > 0 else 0.0


def contained_and_deco(t, sx0, sy0, sx1, sy1):
    """文字是否**完整落在色块内**且是**低透明装饰字**（±2px 容差）。

    ★ 2026-10-31 C3：主题 13/14（AnimeHUD/NanoMuse）的 barWithWatermark 是
    文档化设计——"轨道上叠一层 22% 透明的小字（如 CPU 14 核），既不占额外版面"。
    完整在条内 + alpha < 0.7 → 内嵌水印，不算"压到"；
    只有**跨界**（一半在条外）或**实心字**压条才是真问题
    （当初用户实测的"电量压在内存条上"是实心标签跨界，仍会被抓）。
    """
    if t.get('alpha', 1) >= 0.7:
        return False
    return (t['left'] >= sx0 - 2 and t['right'] <= sx1 + 2
            and t['top'] >= sy0 - 2 and t['bottom'] <= sy1 + 2)


def main():
    vertical = '--vertical' in sys.argv
    theme = 0
    for a in sys.argv:
        if a.startswith('--theme='):
            theme = int(a.split('=')[1])
    prepare()
    write_hoststats_stub()
    page = 0
    for a in sys.argv:
        if a.startswith('--page='):
            page = int(a.split('=')[1])
    data = render(vertical, theme, False, page)
    # 弹窗是**覆盖层**：它压在内容上是设计意图，不该报"重叠"。
    # 做法：再渲染一趟不带弹窗的，两趟文字集合的差集就是弹窗自己画的字。
    overlay = []
    try:
        base = render(vertical, theme, True, page)
        base_keys = {(t['text'], round(t['left']), round(t['top'])) for t in base['texts']}
        overlay = [t for t in data['texts']
                   if (t['text'], round(t['left']), round(t['top'])) not in base_keys]
    except Exception:
        overlay = []
    ov_keys = {(t['text'], round(t['left']), round(t['top'])) for t in overlay}
    FW = data['frame']['w']
    FH = data['frame']['h']
    panels = data['panels']
    texts = [t for t in data['texts'] if t['text'].strip() != '']
    # 去重：同一串字在**同一位置**画两遍是刻意的"描边 + 填充"（strokeText + fillText），
    # 不是重叠。不去掉的话审计会把它当成 100% 重叠误报（主题 5 的状态胶囊就是这么画的）。
    seen_txt = set()
    uniq_texts = []
    for t in texts:
        k = (t['text'], round(t['left']), round(t['top']), round(t['right']))
        if k in seen_txt:
            continue
        seen_txt.add(k)
        uniq_texts.append(t)
    texts = uniq_texts

    problems = []

    def is_overlay(t):
        return (t['text'], round(t['left']), round(t['top'])) in ov_keys

    def panel_of(t):
        cx = (t['left'] + t['right']) / 2
        cy = (t['top'] + t['bottom']) / 2
        for p in panels:
            if p['x'] <= cx <= p['x'] + p['w'] and p['y'] <= cy <= p['y'] + p['h']:
                return p
        return None

    for t in texts:
        if t['left'] < 0 or t['top'] < 0 or t['right'] > FW or t['bottom'] > FH:
            problems.append(f"越出画布: {t['text'][:28]!r} box=({t['left']:.0f},{t['top']:.0f},"
                            f"{t['right']:.0f},{t['bottom']:.0f}) 画布={FW}x{FH}")
            continue
        p = panel_of(t)
        if is_overlay(t):
            continue              # 覆盖层不按面板边界判定（它故意盖在面板上）
        if p is None:
            problems.append(f"不在任何面板内: {t['text'][:28]!r} box=({t['left']:.0f},{t['top']:.0f},"
                            f"{t['right']:.0f},{t['bottom']:.0f})")
        elif (t['left'] < p['x'] - 1 or t['top'] < p['y'] - 1
              or t['right'] > p['x'] + p['w'] + 1 or t['bottom'] > p['y'] + p['h'] + 1):
            problems.append(f"越出面板({p['name']}): {t['text'][:26]!r} "
                            f"box=({t['left']:.0f},{t['top']:.0f},{t['right']:.0f},{t['bottom']:.0f}) "
                            f"面板=({p['x']:.0f},{p['y']:.0f},{p['x']+p['w']:.0f},{p['y']+p['h']:.0f})")

    for i in range(len(texts)):
        for j in range(i + 1, len(texts)):
            a, b = texts[i], texts[j]
            if is_overlay(a) or is_overlay(b):
                continue          # 覆盖层与底层内容的"重叠"是设计意图
            if panel_of(a) is not panel_of(b):
                continue
            # ★ 发光重绘是**设计意图**，不是重叠（2026-10-15 补）：
            #   NanoMuse 等主题要把同一段大字画两遍 —— 先一层低透明青色做 text-shadow
            #   发光、再画实色。两遍的内容与位置完全相同，只是透明度不同。
            #   桩记录不到 alpha（没进 TextBox），所以判据用"同文本 + 位置几乎相同"。
            #   不排除的话，一个 bigTile 就会报 6~8 条 98% 重叠的假问题。
            #   ★ 2026-10-31 C3：容差 3px → 4px —— ThemeAnime 系的"故障色差"是
            #   ±2px 两层（cx-2 青 / cx+2 品红 / cx 主色），同文本两两最远 4px，
            #   3px 容差漏掉 ±2 两端的配对，一条色差报一条假重叠（实测 6 条）。
            if a['text'] == b['text'] \
               and abs(a['left'] - b['left']) <= 4 and abs(a['top'] - b['top']) <= 3:
                continue
            # ★ 2026-10-31 C3：**同文低透明叠加 = 手工辉光/立体影**。
            #   这块画布没有 shadowBlur，主题 18 用 10 层 rgba(10,20,36,0.10~0.37)
            #   逐层偏移 (2.4,1.8) 叠出"立体温度"，层间最远偏 21.6px ——
            #   上面的 4px 容差罩不住。同字符串、至少一方 alpha<0.5 的重叠
            #   是"影子贴着本体"（主题 13/14 的单层 text-shadow 同理），不算打架；
            #   真问题是两个**不同**字符串、或两份**实心**字撞在一起。
            if a['text'] == b['text'] \
               and (a.get('alpha', 1) < 0.5 or b.get('alpha', 1) < 0.5):
                continue
            r = overlap(a, b)
            if r >= 0.10:
                problems.append(f"文字重叠 {r*100:.0f}%: {a['text'][:20]!r} "
                                f"({a['left']:.0f},{a['top']:.0f},{a['right']:.0f},{a['bottom']:.0f}) <-> "
                                f"{b['text'][:20]!r} "
                                f"({b['left']:.0f},{b['top']:.0f},{b['right']:.0f},{b['bottom']:.0f})")

    # 挑出"真正的分隔线"：Dashboard 自己的 roundRect 是拿 moveTo/lineTo 画的，
    # 它的四条边会成簇出现（端点与相邻竖直边重合）。分隔线则是一根孤立的横线 ——
    # 用"端点是否与其他线段共享"来区分，避免把"文字压在色块上"误报成"压线"。
    # ★ 2026-10-31 C3：带上 alpha —— 背景纹理线（ThemeAnime 的 60px 网格、扫描线，
    #   alpha 0.03~0.06）是"氛围"，压在上面是设计；结构分隔线才是"不能压"。
    #   以前桩不记 alpha，网格线被当成分隔线，主题 10 报"文字压线"假问题。
    segs = [(l['x1'], l['y1'], l['x2'], l['y2'], l.get('src', ''), l.get('alpha', 1))
            for l in data['lines']]
    # 5) 文字压到"进度条"（用户实测发现"电量"压在内存条上，而文字-文字检查查不出来）
    #    进度条是 Dashboard 用自己的 roundRect 画的（内部走 moveTo/lineTo），所以不能只看 rects，
    #    要从线段里把"上下两条横线、间距 ≤22px、x 范围相近"的细长矩形认出来。
    bar_rects = []
    hsegs = [l for l in data['lines'] if abs(l['y1'] - l['y2']) < 0.5 and abs(l['x2'] - l['x1']) >= 20]
    for i in range(len(hsegs)):
        for j in range(i + 1, len(hsegs)):
            a, b = hsegs[i], hsegs[j]
            dy = abs(a['y1'] - b['y1'])
            if dy < 6 or dy > 22:
                continue
            x0a, x1a = min(a['x1'], a['x2']), max(a['x1'], a['x2'])
            x0b, x1b = min(b['x1'], b['x2']), max(b['x1'], b['x2'])
            if abs(x0a - x0b) > 6 or abs(x1a - x1b) > 6:
                continue
            if x1a - x0a < 40:
                continue
            bar_rects.append((x0a, min(a['y1'], b['y1']), x1a, max(a['y1'], b['y1']), '进度条'))
    for t in texts:
        if is_overlay(t):
            continue
        # 内嵌水印（barWithWatermark，NanoMuse/AnimeHUD 的标志手法）：低透明小字
        # 叠在进度条轨道上。水印常**横跨"填充段"和"轨道余段"**（如 '23859G' 右对齐
        # 在轨道右端，而填充段只到 72% 处），对着填充段这半截看会误报 ——
        # 所以判据是"完整落在**任一**条内"，而不是对每根条单独判。
        wm = any(contained_and_deco(t, sx0, sy0, sx1, sy1)
                 for (sx0, sy0, sx1, sy1, _k) in bar_rects)
        for (sx0, sy0, sx1, sy1, kind) in bar_rects:
            # 覆盖层（弹窗）自己的进度条也不算
            if any(is_overlay(o) and min(sx1, o['right']) - max(sx0, o['left']) > 3
                   and min(sy1, o['bottom']) - max(sy0, o['top']) > 2 for o in overlay):
                break
            if wm:
                continue          # 文字是某根条的内嵌水印（见上），对着别的条也不算压
            ox = min(sx1, t['right']) - max(sx0, t['left'])
            oy = min(sy1, t['bottom']) - max(sy0, t['top'])
            if ox > 3 and oy > 2:
                problems.append(f"文字压到{kind}: {t['text'][:22]!r} "
                                f"文字({t['left']:.0f},{t['top']:.0f},{t['right']:.0f},{t['bottom']:.0f}) "
                                f"色块({sx0:.0f},{sy0:.0f},{sx1:.0f},{sy1:.0f})")
                break

    shapes = []
    for r in data['rects']:
        area = r['w'] * r['h']
        owner = None
        for p in panels:
            if p['x'] <= r['x'] + r['w'] / 2 <= p['x'] + p['w'] and p['y'] <= r['y'] + r['h'] / 2 <= p['y'] + p['h']:
                owner = p
                break
        if owner is None:
            continue
        if area > 0.6 * owner['w'] * owner['h']:
            continue
        # 只查"进度条"这类细长色块（高 ≤22px）：圆环（arc）与徽章/胶囊（文字本来就画在上面）
        # 不算 —— 否则会把"数字在圆环里"这种设计误报成重叠
        if r['w'] < 20 or r['h'] < 6 or r['h'] > 22:
            continue
        shapes.append((r['x'], r['y'], r['x'] + r['w'], r['y'] + r['h'], r['kind']))
    for t in texts:
        # 内嵌水印（同上）：完整落在任一形状条内且低透明 → 设计，不算压到
        wm = any(contained_and_deco(t, sx0, sy0, sx1, sy1)
                 for (sx0, sy0, sx1, sy1, _k) in shapes)
        for (sx0, sy0, sx1, sy1, kind) in shapes:
            if wm:
                continue
            ox = min(sx1, t['right']) - max(sx0, t['left'])
            oy = min(sy1, t['bottom']) - max(sy0, t['top'])
            if ox > 3 and oy > 3:
                problems.append(f"文字压到{kind}: {t['text'][:22]!r} "
                                f"文字({t['left']:.0f},{t['top']:.0f},{t['right']:.0f},{t['bottom']:.0f}) "
                                f"色块({sx0:.0f},{sy0:.0f},{sx1:.0f},{sy1:.0f})")
                break

    hlines = []
    for i, (x1, y1, x2, y2, src, alpha) in enumerate(segs):
        if abs(y1 - y2) > 0.5 or abs(x2 - x1) <= 40:
            continue
        if alpha < 0.15:
            continue          # 背景纹理线（网格/扫描线，alpha≤0.06）：压上面是设计
        shared = False
        for j, (a1, b1, a2, b2, _s, _alpha2) in enumerate(segs):
            if i == j:
                continue
            for (px, py) in ((x1, y1), (x2, y2)):
                if (abs(a1 - px) < 1.5 and abs(b1 - py) < 1.5) or (abs(a2 - px) < 1.5 and abs(b2 - py) < 1.5):
                    shared = True
                    break
            if shared:
                break
        if not shared:
            hlines.append((x1, y1, x2, y2, src))
    for t in texts:
        if is_overlay(t):
            continue          # 覆盖层自己带的线（弹窗卡边/进度条）不算"压线"
        for (x1, y1, x2, y2, src) in hlines:
            if any(is_overlay(o) and o['left'] < max(x1, x2) and o['right'] > min(x1, x2)
                   and o['top'] < y1 < o['bottom'] for o in overlay):
                continue
            if not (t['left'] < max(x1, x2) and t['right'] > min(x1, x2)):
                continue
            if t['top'] < y1 < t['bottom'] - 2:
                problems.append(f"文字压线: {t['text'][:24]!r} y={y1:.0f} "
                                f"文字 y={t['top']:.0f}..{t['bottom']:.0f} 线来自 {src}")
                break

    theme_name = {0: '', 1: '·主题1诊断终端', 2: '·主题2监控墙', 3: f'·主题3分页屏第{page+1}页'}.get(theme, '')
    mode = ('竖装' if vertical else '横装') + theme_name
    if overlay:
        mode += f'（覆盖层 {len(overlay)} 个文字已排除重叠判定）'
    print(f"===== 布局审计（真源码 {mode}）文字框 {len(texts)} 个 =====")
    if not problems:
        print(f"✅ 干净（{len(texts)} 个文字元素，画布 {FW}x{FH}）")
        return 0
    print(f"❌ {len(problems)} 个问题：")
    for s in problems:
        print('  - ' + s)
    return 1


if __name__ == '__main__':
    sys.exit(main())
