#!/usr/bin/env python3
"""make_seq.py — 把一张（或一组）图烘成 1920×462 的 JPEG 帧序列 + manifest.json。

用途：验证/使用「预烘焙序列」播放路径 —— 运行时 App 零编码，只把字节原样推给屏。
（这块屏只认整帧 JPEG；本机每次 4096B bulkTransfer ~5.5ms、编码 ~55ms/帧，
 所以预烘焙能省掉编码那一段。见 .verify/video-seq/报告-预烘焙序列验证.md）

动作：Ken Burns（缓慢推近 + 横移）+ 一条扫过的亮带，保证相邻帧确实不同。

用法：
  python3 tools/make_seq.py --src docs/V4版-屏上抓帧.png --out ~/.cache/seq-demo \
      --frames 120 --fps 12 --q 60
  python3 tools/make_seq.py --src a.jpg --src b.jpg --out DIR --frames 240 --no-rotate

产出：
  DIR/f0001.jpg … DIR/fNNNN.jpg（已按面板物理方向旋转，默认 180°）
  DIR/manifest.json  {name,count,fps,w,h,pattern,loop,rotate180,q,...}
"""
import argparse
import json
import os
import statistics
import sys

from PIL import Image, ImageDraw

PANEL_W, PANEL_H = 1920, 462
DEFAULT_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "docs", "V4版-屏上抓帧.png")


def writes_for(nbytes: int, wsize: int = 4096) -> int:
    """复刻 LyProtocol.buildChunkStream + writeChunks 的写次数（用于给出帧率预估）"""
    chunks = nbytes // 496 + 1
    padded = chunks + (-chunks % 4)
    stream = padded * 512
    n = pos = 0
    while pos < stream:
        rem = stream - pos
        pos += wsize if rem >= wsize else min(2048, rem)
        n += 1
    return n


def cover(im: Image.Image, w: int, h: int, zoom: float, pan: float) -> Image.Image:
    """把 im 按 cover 铺满 (w,h)，zoom>1 推近，pan∈[0,1] 横向移动取景窗口。"""
    sw, sh = im.size
    scale = max(w / sw, h / sh) * zoom
    nw, nh = max(w, int(sw * scale + 0.5)), max(h, int(sh * scale + 0.5))
    big = im.resize((nw, nh), Image.LANCZOS)
    max_x = max(0, nw - w)
    max_y = max(0, nh - h)
    x = int(max_x * pan)
    y = int(max_y / 2)
    return big.crop((x, y, x + w, y + h))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", action="append", default=[], help="源图（可多次；默认用 docs/ 里的面板抓帧）")
    ap.add_argument("--out", required=True)
    ap.add_argument("--frames", type=int, default=120)
    ap.add_argument("--fps", type=float, default=12.0)
    ap.add_argument("--q", type=int, default=60)
    ap.add_argument("--zoom", type=float, default=0.14, help="推近幅度（0.14 = 放大 14%%）")
    ap.add_argument("--bar", type=int, default=90,
                    help="扫过的亮带宽度（px）；0 = 不要亮带（画面更省字节，帧率更高）")
    ap.add_argument("--no-rotate", action="store_true", help="不按面板物理方向旋转（默认旋转 180°）")
    ap.add_argument("--loop", type=int, default=1)
    ap.add_argument("--name", default="")
    args = ap.parse_args()

    srcs = args.src if args.src else [os.path.normpath(DEFAULT_SRC)]
    imgs = []
    for p in srcs:
        if not os.path.exists(p):
            print(f"源图不存在: {p}", file=sys.stderr)
            return 2
        imgs.append(Image.open(p).convert("RGB"))
    if not imgs:
        print("没有可用源图", file=sys.stderr)
        return 2

    os.makedirs(args.out, exist_ok=True)
    for f in os.listdir(args.out):
        if f.startswith("f") and f.endswith(".jpg"):
            os.remove(os.path.join(args.out, f))

    rotate = not args.no_rotate
    n = args.frames
    sizes = []
    for i in range(n):
        t = i / max(1, n - 1) if n > 1 else 0.0          # 0..1
        base = imgs[(i * len(imgs)) // max(1, n)] if len(imgs) > 1 else imgs[0]
        # 三角波横移（来回扫），再叠一点推近
        pan = t * 2 if t < 0.5 else (1 - t) * 2
        zoom = 1.0 + args.zoom * (0.35 + 0.65 * abs(0.5 - t) * 2 * 0.5 + 0.5 * t)
        fr = cover(base, PANEL_W, PANEL_H, zoom, pan)
        # 一条扫过的亮带：保证帧间确有变化（也顺带压出 JPEG 体积）；--bar 0 关掉
        if args.bar > 0:
            d = ImageDraw.Draw(fr)
            bx = int((PANEL_W + args.bar * 4) * t) - args.bar * 2
            d.rectangle([bx, 0, bx + args.bar, PANEL_H], fill=(255, 255, 255))
        fr = Image.blend(fr, fr, 1.0)
        if rotate:
            fr = fr.rotate(180)
        out = os.path.join(args.out, f"f{i + 1:04d}.jpg")
        fr.save(out, "JPEG", quality=args.q, subsampling=2, optimize=False)
        sizes.append(os.path.getsize(out))
        if (i + 1) % 20 == 0 or i + 1 == n:
            print(f"  {i + 1}/{n} 帧…", flush=True)

    avg = int(statistics.mean(sizes))
    w_avg = writes_for(avg)
    manifest = {
        "name": args.name or os.path.basename(os.path.normpath(args.out)),
        "count": n,
        "fps": args.fps,
        "w": PANEL_W,
        "h": PANEL_H,
        "pattern": "f%04d.jpg",
        "loop": bool(args.loop),
        "rotate180": rotate,
        "q": args.q,
        "src": [os.path.basename(p) for p in srcs],
        "bytesMin": min(sizes),
        "bytesAvg": avg,
        "bytesMax": max(sizes),
        "writesAvg": w_avg,
        "estPushMsAvg": round(w_avg * 5.5 + 3, 1),
        "estFpsCap": round(1000 / (w_avg * 5.5 + 3), 1),
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    print(f"\n✅ {n} 帧 → {args.out}")
    print(f"   字节  min {min(sizes)} / avg {avg} / max {max(sizes)}"
          f"（q{args.q}，4:2:0{'，已旋转 180°' if rotate else ''}）")
    print(f"   平均写次数 {w_avg} → 推一帧 ≈ {w_avg * 5.5 + 3:.0f}ms → 上限 ≈ {1000 / (w_avg * 5.5 + 3):.1f}fps")
    print(f"   总占用 {sum(sizes) / 1024 / 1024:.1f} MB（App 会一次性拉进内存）")
    print(f"   manifest: {os.path.join(args.out, 'manifest.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
