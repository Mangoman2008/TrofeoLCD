#!/usr/bin/env python3
"""boxes.py —— 把真源码渲染出来的文字框按面板列出来（调版式时用来看"谁在哪、还剩多少空间"）。"""
import json, os, re, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout_check as LC

vertical = '--vertical' in sys.argv
LC.prepare()
d = LC.render(vertical)
panels = d['panels']
texts = [t for t in d['texts'] if t['text'].strip()]
def panel_of(t):
    cx, cy = (t['left']+t['right'])/2, (t['top']+t['bottom'])/2
    for p in panels:
        if p['x'] <= cx <= p['x']+p['w'] and p['y'] <= cy <= p['y']+p['h']:
            return p
    return None
from collections import defaultdict
groups = defaultdict(list)
for t in texts:
    p = panel_of(t)
    groups[p['name'] if p else '(不在面板内)'].append(t)
for name, items in groups.items():
    p = next((q for q in panels if q['name'] == name), None)
    print(f"\n=== {name} " + (f"({p['x']:.0f},{p['y']:.0f} {p['w']:.0f}x{p['h']:.0f} → {p['x']+p['w']:.0f},{p['y']+p['h']:.0f})" if p else ""))
    for t in sorted(items, key=lambda t: t['top']):
        print(f"  y {t['top']:>4.0f}..{t['bottom']:>4.0f}  x {t['left']:>4.0f}..{t['right']:>4.0f}  {t['size']:>4.0f}px  {t['text'][:34]!r}")
