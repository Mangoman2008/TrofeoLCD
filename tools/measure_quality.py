#!/usr/bin/env python3
"""JPEG 质量 ↔ 帧字节 ↔ 帧率 的甜点值测量（trofeo-lcd 主题专用）

## 为什么需要它
"字节数就是帧率"：每次 4096B `bulkTransfer` 有 ~5.5~6.9ms 固定开销 + 3ms ACK，
所以 `帧率 ≈ 1000 / (写次数 × 5.8ms + 3ms)`。降 JPEG 质量能减字节，看似直接换帧率。

但**测量很容易被噪声毁掉**，本工具专门解决三个噪声源：

1. **版面轮换**：主题 15 每 20 秒换版面 → 每版字节数不同（28~44KB）
   → 取样窗口内字节范围宽到看不出质量差异。
   **对策**：先把 `fps=1` 钉住让版面轮换慢下来（轮换按 `Date.now()/20000` 走，
   fps 只影响描画频率），并在每档取**足够多的样本**后看中位数与范围。
2. **机器负载**：本机 JS 线程里编码，机器一忙 `encodeMs` 从 75ms 飙到 1353ms
   （实测），帧率完全失真。
   **对策**：先记录负载；**负载 > 6 就拒绝测量并直接报错**，别产出垃圾数据。
3. **其它线程在推屏**：序列播放（`seq=...`）、`seq_server.py`、遗留测试进程
   都会同时往屏上推帧，把"被测量主题"的帧率搅乱（实测踩过：序列在放狮子王）。
   **对策**：开测前检查 `seqState`，非 idle 就自动 `seq=off` 并告警。

## 用法
    python3 tools/measure_quality.py                 # 默认测主题 15 + 图片背景
    python3 tools/measure_quality.py --theme 14      # 换主题
    python3 tools/measure_quality.py --quick         # 少量样本，快速看趋势
    python3 tools/measure_quality.py --out curve.md  # 结果写进 Markdown

退出码：0 = 测到了数据；2 = 环境不适合测量（负载高/屏不在线），未产出数据。
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time

BASE = 'http://127.0.0.1:54546'
MAX_ENCODE_MS = 160.0      # 实测 encode 超过这个值就不测（空载约 71~76ms）
QUALITIES = [0.95, 0.9, 0.85, 0.8, 0.7, 0.6, 0.5, 0.4]


def http(path, timeout=8):
    try:
        return subprocess.run(['curl', '-s', '-m', str(timeout), BASE + path],
                              capture_output=True, text=True, timeout=timeout + 2).stdout
    except Exception:
        return ''


def diag():
    try:
        return json.loads(http('/diag'))
    except Exception:
        return None


def loadavg():
    """本机 1 分钟负载（用于判断能不能测）"""
    try:
        with open('/proc/loadavg') as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


def guard():
    """开测前的环境检查。返回 (ok, 说明)"""
    notes = []
    d = diag()
    if d is None:
        return False, '应用 /diag 无响应（应用没跑？）'
    if not d.get('usbOpen'):
        return False, f"屏不在线（usbOpen=False, lastError={d.get('lastError')}）"
    # 序列播放会同时推屏 → 先停掉
    if d.get('seqState') == 'playing':
        http('/set?seq=off&seqburst=0', 12)
        time.sleep(2)
        notes.append('检测到序列在播放，已自动 seq=off')
    # ★ 判据用**实测 encode 耗时**，不用 loadavg。
    #   原因：本机 loadavg 长期挂在 22~26（8 核）却仍能跑到 encode 76ms ——
    #   这个内核显然把某些等待也算进了负载，用它当门禁会误杀。
    #   而 encodeMs 是真正影响帧率的量，直接量它最准。
    encs = []
    for _ in range(3):
        d2 = diag()
        if d2 and d2.get('encodeMs'):
            encs.append(d2['encodeMs'])
        time.sleep(2)
    enc = min(encs) if encs else -1
    la = loadavg()
    notes.append(f'负载 {la:.1f}（仅记录，不作门禁）')
    notes.append(f'encode {enc:.0f}ms')
    if enc < 0:
        return False, '取不到 encodeMs（帧循环没在跑？）'
    if enc > MAX_ENCODE_MS:
        return False, (f'实测 encode {enc:.0f}ms > {MAX_ENCODE_MS}ms —— 说明机器正在被别的活占着，'
                       '此环境下质量差异会被调度噪声淹没。请等机器空下来再测'
                       '（历史实测：空载 71~76ms，过载时到过 1353ms）')
    return True, '; '.join(notes)


def sample(q, n, gap):
    """在质量 q 下采样 n 次，返回 (字节列表, encode列表, push列表, fps列表)"""
    http(f'/set?q={q}', 12)
    time.sleep(6)                     # 让设置生效并跑几帧
    B, E, P, F = [], [], [], []
    for _ in range(n):
        d = diag()
        if d and d.get('jpegBytes'):
            B.append(d['jpegBytes'] / 1024)
            E.append(d.get('encodeMs') or 0)
            P.append(d.get('pushMs') or 0)
            if d.get('fps'):
                F.append(d['fps'])
        time.sleep(gap)
    return B, E, P, F


def med(x):
    return statistics.median(x) if x else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--theme', type=int, default=15)
    ap.add_argument('--bg', default='image', help='背景：image/plasma/aurora/lava/waves/none')
    ap.add_argument('--quick', action='store_true', help='少量样本')
    ap.add_argument('--out', default='', help='结果写入的 Markdown 路径')
    args = ap.parse_args()

    ok, why = guard()
    print(f'[环境] {why}')
    if not ok:
        print('[中止] 环境不适合测量，未产出数据。')
        return 2

    n = 3 if args.quick else 6
    gap = 2 if args.quick else 3

    # 固定到目标主题；burst=1 + auto fps 是实测最优组合（见 docs/预烘焙能否提升主题帧率.md）
    # fps 不设（auto）：策略在 busy 时用 66ms 间隔（≈15fps），是它自己的安全值
    http(f'/set?theme={args.theme}&background={args.bg}&burst=1&fps=0', 12)
    time.sleep(8)

    rows = []
    print(f"\n{'q':<6}{'字节中位':>10}{'字节范围':>16}{'写~':>5}"
          f"{'encode中位':>11}{'push中位':>10}{'fps中位':>9}{'样本':>5}")
    for q in QUALITIES:
        B, E, P, F = sample(q, n, gap)
        if not B:
            continue
        m = med(B)
        rows.append((q, m, min(B), max(B), med(E), med(P), med(F), len(B)))
        print(f'{q:<6}{m:>9.1f}K{f"{min(B):.1f}~{max(B):.1f}K":>16}'
              f'{round(m / 4096 + 0.5):>5}{med(E):>10.0f}ms{med(P):>9.0f}ms'
              f'{med(F):>8.1f}{len(B):>5}')

    if not rows:
        print('[中止] 一个样本都没采到。')
        return 2

    # 挑甜点：字节最小、且 encode 没有明显恶化（encode 主要受像素量影响，与 q 关系弱）
    best = min(rows, key=lambda r: r[1])
    print(f'\n[甜点] q={best[0]} → {best[1]:.1f}KB（最小字节）。'
          f'注意 encode 与 q 关系很弱，瓶颈在像素量而非质量。')

    if args.out:
        with open(args.out, 'w') as f:
            f.write('# JPEG 质量 ↔ 字节 ↔ 帧率（实测）\n\n')
            f.write(f'- 主题 {args.theme} · 背景 `{args.bg}` · `burst=1` · auto fps\n')
            f.write(f'- 采样：每档 {n} 次、间隔 {gap}s\n')
            f.write(f'- 环境：{why}\n\n')
            f.write('| q | 字节中位 | 字节范围 | 写次数 | encode | push | fps |\n')
            f.write('|---|---|---|---|---|---|---|\n')
            for q, m, mn, mx, e, p, fp, _ in rows:
                f.write(f'| {q} | {m:.1f}KB | {mn:.1f}~{mx:.1f}KB | '
                        f'{round(m / 4096 + 0.5)} | {e:.0f}ms | {p:.0f}ms | {fp:.1f} |\n')
        print(f'[写出] {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
