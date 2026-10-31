#!/usr/bin/env python3
"""mp4_to_seq.py —— 真实视频 → 1920×462 预烘焙 JPEG 序列 + manifest.json（本机直接烘）

为什么能在本机跑：这台 HarmonyOS PC **不允许 exec 用户态二进制**（ffmpeg.bin 复制到可写目录后
仍 Permission denied，连 cp /bin/echo 都 EACCES），但**允许 dlopen 共享库** —— Python 的
PyAV 轮子自带完整 ffmpeg 共享库（libavcodec/63 等），进程内解码，不需要 exec 任何东西。

依赖（已装好）：
    python3 -m venv ~/.venvs/mp4seq && ~/.venvs/mp4seq/bin/pip install av
用法：
    ~/.venvs/mp4seq/bin/python tools/mp4_to_seq.py \
        --src video.mp4 --out ~/.cache/seq-root/mp4 --start 3 --duration 10 --fps 12 --q 60
产出：
    <out>/f0001.jpg …（已按面板物理方向旋转 180°）、<out>/manifest.json
"""
import argparse
import json
import os
import statistics
import sys

PANEL_W, PANEL_H = 1920, 462


def writes_for(nbytes: int, wsize: int = 4096) -> int:
    chunks = nbytes // 496 + 1
    padded = chunks + (-chunks % 4)
    stream = padded * 512
    n = pos = 0
    while pos < stream:
        rem = stream - pos
        pos += wsize if rem >= wsize else min(2048, rem)
        n += 1
    return n


def cover(im, w: int, h: int):
    """等比铺满 (w,h) 后居中裁切（不变形）"""
    sw, sh = im.size
    scale = max(w / sw, h / sh)
    nw, nh = max(w, int(sw * scale + 0.5)), max(h, int(sh * scale + 0.5))
    big = im.resize((nw, nh), 1)  # 1 = LANCZOS
    return big.crop(((nw - w) // 2, (nh - h) // 2, (nw - w) // 2 + w, (nh - h) // 2 + h))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="输入视频（mp4/mkv/mov/webm…）")
    ap.add_argument("--out", required=True)
    ap.add_argument("--start", type=float, default=0.0, help="从第几秒开始（秒）")
    ap.add_argument("--duration", type=float, default=10.0, help="取多长（秒）")
    ap.add_argument("--fps", type=float, default=12.0, help="输出帧率（这块屏再高也推不动）")
    ap.add_argument("--q", type=int, default=60)
    ap.add_argument("--no-rotate", action="store_true")
    ap.add_argument("--name", default="")
    args = ap.parse_args()

    try:
        import av  # noqa: F401  （缺了给出可执行的补救命令）
    except ImportError:
        print("缺少 PyAV。先跑：\n"
              "  python3 -m venv ~/.venvs/mp4seq && ~/.venvs/mp4seq/bin/pip install av\n"
              "再用 ~/.venvs/mp4seq/bin/python 运行本脚本。", file=sys.stderr)
        return 2

    import av
    from PIL import Image

    if not os.path.exists(args.src):
        print(f"输入不存在: {args.src}", file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)
    for f in os.listdir(args.out):
        if f.startswith("f") and f.endswith(".jpg"):
            os.remove(os.path.join(args.out, f))

    rotate = not args.no_rotate
    step = 1.0 / args.fps
    want = max(1, int(round(args.duration * args.fps)))
    t_end = args.start + args.duration

    sizes = []
    idx = 0
    src_info = {}
    with av.open(args.src) as c:
        vs = c.streams.video[0]
        vs.thread_type = "AUTO"
        src_info = {
            "codec": vs.codec_context.name,
            "width": vs.codec_context.width,
            "height": vs.codec_context.height,
            "avgRate": float(vs.average_rate) if vs.average_rate else None,
            "durationSec": float(c.duration / av.time_base) if c.duration else None,
        }
        if args.start > 0:
            c.seek(int(args.start / float(vs.time_base)), stream=vs)
        next_t = args.start
        for frame in c.decode(vs):
            t = float(frame.pts * vs.time_base) if frame.pts is not None else next_t
            if t < args.start - step:
                continue
            if t > t_end or idx >= want:
                break
            if t + 1e-6 < next_t:
                continue
            im = frame.to_image().convert("RGB")
            fr = cover(im, PANEL_W, PANEL_H)
            if rotate:
                fr = fr.rotate(180)
            out = os.path.join(args.out, f"f{idx + 1:04d}.jpg")
            fr.save(out, "JPEG", quality=args.q, subsampling=2, optimize=False)
            sizes.append(os.path.getsize(out))
            idx += 1
            next_t += step
            if idx % 20 == 0:
                print(f"  {idx}/{want} 帧…", flush=True)

    if idx == 0:
        print("一帧都没解出来（起点超出片长？）", file=sys.stderr)
        return 1

    avg = int(statistics.mean(sizes))
    w_avg = writes_for(avg)
    man = {
        "name": args.name or os.path.basename(os.path.normpath(args.out)),
        "count": idx, "fps": args.fps, "w": PANEL_W, "h": PANEL_H,
        "pattern": "f%04d.jpg", "loop": True, "rotate180": rotate, "q": args.q,
        "src": os.path.basename(args.src), "srcInfo": src_info,
        "start": args.start, "duration": args.duration,
        "bytesMin": min(sizes), "bytesAvg": avg, "bytesMax": max(sizes),
        "writesAvg": w_avg,
        "estPushMsAvg": round(w_avg * 5.5 + 3, 1),
        "estFpsCap": round(1000 / (w_avg * 5.5 + 3), 1),
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(man, fh, ensure_ascii=False, indent=2)

    print(f"\n✅ {idx} 帧 → {args.out}")
    print(f"   源: {src_info['codec']} {src_info['width']}x{src_info['height']}"
          f"（{args.start:.1f}s 起，取 {args.duration:.1f}s，输出 {args.fps}fps）")
    print(f"   字节 min {min(sizes)} / avg {avg} / max {max(sizes)}"
          f"（q{args.q}，4:2:0{'，已旋转 180°' if rotate else ''}）")
    print(f"   平均写次数 {w_avg} → 推一帧 ≈ {w_avg * 5.5 + 3:.0f}ms → 上限 ≈ {1000 / (w_avg * 5.5 + 3):.1f}fps")
    print(f"   总占用 {sum(sizes) / 1024 / 1024:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
