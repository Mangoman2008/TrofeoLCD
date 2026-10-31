#!/usr/bin/env python3
"""frames_to_seq.py — 把一批现成的 1920×462 图（例如 App 自己抓下来的 /frame.jpg）
重新编码成"预烘焙序列"目录 + manifest.json。

和 make_seq.py 的区别：不做 Ken Burns，只做"重编码 + 可选旋转 180°"，
用来把 App 现在渲染的内容变成一段可零编码直推的序列（对比同一内容的两种路径）。

用法：
  python3 tools/frames_to_seq.py --src-dir .verify/video-seq --glob 'f*.jpg' \
      --out ~/.cache/seq-root/dash --q 60 --frames 120
"""
import argparse
import glob
import json
import os
import statistics
import sys

from PIL import Image

PANEL_W, PANEL_H = 1920, 462


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-dir", required=True)
    ap.add_argument("--glob", default="*.jpg")
    ap.add_argument("--out", required=True)
    ap.add_argument("--q", type=int, default=60)
    ap.add_argument("--fps", type=float, default=12.0)
    ap.add_argument("--frames", type=int, default=0, help="输出帧数（默认 = 源图数；超出则循环）")
    ap.add_argument("--no-rotate", action="store_true")
    ap.add_argument("--name", default="")
    args = ap.parse_args()

    srcs = sorted(glob.glob(os.path.join(args.src_dir, args.glob)))
    if not srcs:
        print(f"没匹配到源图: {args.src_dir}/{args.glob}", file=sys.stderr)
        return 2
    n = args.frames if args.frames > 0 else len(srcs)
    rotate = not args.no_rotate
    os.makedirs(args.out, exist_ok=True)
    for f in os.listdir(args.out):
        if f.startswith("f") and f.endswith(".jpg"):
            os.remove(os.path.join(args.out, f))

    sizes = []
    for i in range(n):
        im = Image.open(srcs[i % len(srcs)]).convert("RGB")
        if im.size != (PANEL_W, PANEL_H):
            im = im.resize((PANEL_W, PANEL_H), Image.LANCZOS)
        if rotate:
            im = im.rotate(180)
        out = os.path.join(args.out, f"f{i + 1:04d}.jpg")
        im.save(out, "JPEG", quality=args.q, subsampling=2, optimize=False)
        sizes.append(os.path.getsize(out))

    avg = int(statistics.mean(sizes))
    chunks = avg // 496 + 1
    padded = chunks + (-chunks % 4)
    stream = padded * 512
    writes = pos = 0
    while pos < stream:
        rem = stream - pos
        pos += 4096 if rem >= 4096 else min(2048, rem)
        writes += 1
    man = {
        "name": args.name or os.path.basename(os.path.normpath(args.out)),
        "count": n, "fps": args.fps, "w": PANEL_W, "h": PANEL_H,
        "pattern": "f%04d.jpg", "loop": True, "rotate180": rotate, "q": args.q,
        "src": [os.path.basename(p) for p in srcs],
        "bytesMin": min(sizes), "bytesAvg": avg, "bytesMax": max(sizes),
        "writesAvg": writes,
        "estPushMsAvg": round(writes * 5.5 + 3, 1),
        "estFpsCap": round(1000 / (writes * 5.5 + 3), 1),
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(man, fh, ensure_ascii=False, indent=2)
    print(f"✅ {n} 帧（源 {len(srcs)} 张，q{args.q}）→ {args.out}")
    print(f"   字节 min {min(sizes)} / avg {avg} / max {max(sizes)}"
          f" → 写次数 {writes} → 预估 {man['estPushMsAvg']}ms/帧 ≈ {man['estFpsCap']}fps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
