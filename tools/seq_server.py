#!/usr/bin/env python3
"""seq_server.py — 把预烘焙序列目录通过 127.0.0.1 暴露给 App（HTTP）。

为什么走 HTTP 而不是让 App 读文件：App 里现有代码**没有任何文件 IO**
（全部输入来自 UDP 遥测 + 本机 HTTP），沙箱里也读不到工作区目录；
而 `fetchVmFrame()` 已经证明 App 能稳定访问 127.0.0.1 的 HTTP —— 沿用这条已验证的路。

App 侧用法：
  curl "http://127.0.0.1:54546/set?seq=http://127.0.0.1:8899"     # 开始播放
  curl "http://127.0.0.1:54546/set?seqfps=12"                     # 覆盖帧率
  curl "http://127.0.0.1:54546/set?seq=off"                       # 停止

用法：
  python3 tools/seq_server.py --dir ~/.cache/seq-demo --port 8899
"""
import argparse
import functools
import http.server
import os
import socket
import sys
import threading


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # 帧会被反复拉取，禁掉缓存对临时验证更省事
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        if os.environ.get("SEQ_SERVER_VERBOSE") == "1":
            sys.stderr.write("[seq] " + (fmt % args) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()

    d = os.path.abspath(os.path.expanduser(args.dir))
    if not os.path.isdir(d):
        print(f"目录不存在: {d}", file=sys.stderr)
        return 2
    man = os.path.join(d, "manifest.json")
    if not os.path.exists(man):
        # 允许"根目录下挂多个序列子目录"（/set?seq=http://host:port/子目录）
        subs = [x for x in sorted(os.listdir(d))
                if os.path.exists(os.path.join(d, x, "manifest.json"))]
        if not subs:
            print(f"没有 manifest.json（先跑 tools/make_seq.py）: {d}", file=sys.stderr)
            return 2
        print(f"根目录无清单，发现子序列: {', '.join(subs)}", flush=True)

    handler = functools.partial(Handler, directory=d)
    srv = http.server.ThreadingHTTPServer((args.host, args.port), handler)
    srv.daemon_threads = True

    # 绑定成功后再打印，脚本化调用（后台任务）可以据此判断就绪
    print(f"seq_server 就绪: http://{args.host}:{args.port}/  →  {d}", flush=True)
    print(f"  清单: http://{args.host}:{args.port}/manifest.json", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
