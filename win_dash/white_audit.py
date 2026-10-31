#!/usr/bin/env python3
"""white_audit.py —— 白色像素归因：分清「仪表盘自己画的」还是「VM 监控画面里的」。

背景：调色板最亮是 #E6EBF5(230,235,245)，Dashboard 自绘层不该出现 R,G,B 全 >=250。
但 VM 面板是把被监控机器的**真实桌面截图**等比放入后直接绘制的，桌面里有什么颜色
就有什么颜色（白窗、白网页都会原样出现）。所以正确的硬不变量是：

    VM 画面矩形**之外**不得有纯白像素；矩形之内属于外部内容。

  python3 win_dash/white_audit.py <渲染出来的.jpg> h|v [r180]
"""
import os
import sys
import urllib.request

from PIL import Image

# VM 画面"等比放入"后实际覆盖的矩形（逻辑坐标）
H_RECT = (1462, 115, 1894, 403)     # 横屏：面板 x1450..1906，内宽432、图像432x288 居中
V_RECT = (26, 256, 454, 541)        # 竖屏：面板 x14..466，内宽428、图像428x285 居中
LIVEPAD = os.environ.get("LIVEPAD", "http://127.0.0.1:8787")
TMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "_audit_vm.jpg")

# 四种可能的 device 变换下，VM 画面矩形落在哪里（不指定 --r180 时自动挑最合适的那个）
CAND = [
    ("横屏未翻转",    H_RECT),
    ("横屏rotate180", (LW_ := 1920 - H_RECT[2], 462 - H_RECT[3], 1920 - H_RECT[0], 462 - H_RECT[1])),
    ("竖屏rotate90",  (1920 - V_RECT[3], V_RECT[0], 1920 - V_RECT[1], V_RECT[2])),
]


def unrotate90(img):
    w, h = img.size
    out = Image.new("RGB", (h, w))
    src, dst = img.load(), out.load()
    for ly in range(w):
        for lx in range(h):
            dst[lx, ly] = src[w - 1 - ly, lx]
    return out


def main():
    path, mode = sys.argv[1], sys.argv[2]
    flipped = len(sys.argv) > 3 and sys.argv[3] == "r180"
    img = Image.open(path).convert("RGB")
    if flipped:
        img = img.transpose(Image.ROTATE_180)
    px = img.load()
    W, H = img.size
    whites = [(x, y) for y in range(H) for x in range(W) if min(px[x, y]) >= 250]
    best = None
    for name, rect in CAND:
        ins = sum(1 for (x, y) in whites
                  if rect[0] - 3 <= x <= rect[2] + 3 and rect[1] - 3 <= y <= rect[3] + 3)
        out = len(whites) - ins
        if best is None or out < best[2]:
            best = (name, rect, out, ins)
    cand, rect, outside, inside = best
    print(f"帧 {os.path.basename(path)}  纯白总数 {len(whites)}")
    print(f"  按「{cand}」解释：VM 画面矩形 {rect} 内 {inside}，外 {outside}")
    print(f"  → 仪表盘自绘区纯白 = {outside}（期望 0）")
    print(f"  → VM 画面矩形内纯白 = {inside}（被监控桌面的内容，允许）")

    # 抓一张当前被监控 VM 的真实桌面，按同一尺寸重采样后对比白像素数
    try:
        with urllib.request.urlopen(LIVEPAD + "/vm/frame.jpg", timeout=20) as r:
            data = r.read()
        open(TMP, "wb").write(data)
        src = Image.open(TMP).convert("RGB")
        rw, rh = rect[2] - rect[0], rect[3] - rect[1]
        sp = src.resize((rw, rh), Image.LANCZOS)
        spx = sp.load()
        sw = sum(1 for y in range(rh) for x in range(rw) if min(spx[x, y]) >= 250)
        print(f"  对照：**当前** VM 桌面 {src.size} 缩到 {rw}x{rh} 后纯白 = {sw}"
              f"（与 {inside} 接近就说明面板是忠实转绘；差得多说明这一帧拍摄时桌面内容已变）")
    except Exception as e:
        print(f"  （抓不到 livepad 源帧对照：{e}）")
    return 1 if outside > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
