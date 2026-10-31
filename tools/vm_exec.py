#!/usr/bin/env python3
"""在 Win11 ARM 虚拟机里执行命令（经 livepad 输入注入通道）。

原理：Win+R 打开"运行"框 -> 注入整条命令文本（走虚拟机剪贴板 + Ctrl+V）-> 回车。
输出请让命令自己重定向到共享盘（C:\\...），主机侧直接读
~/.VMDocs/.hwf_share/.disks/C/... 即可，不需要 OCR。

  python3 tools/vm_exec.py "cmd /c echo hi> C:\\__dirtest\\t.txt"
  python3 tools/vm_exec.py --check C:/__dirtest/t.txt
  python3 tools/vm_exec.py --frame out.jpg          # 抓一张 VM 画面
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

BASE = os.environ.get("LIVEPAD", "http://127.0.0.1:8787")
TOKEN = os.environ.get("LIVEPAD_TOKEN", "eieabgs")
VK_WIN, VK_R, VK_RETURN, VK_ESC = 0x5B, 0x52, 0x0D, 0x1B
LOCK = os.path.expanduser("~/.dshlcd-vm-inject.lock")
LOCK_STALE = 300.0


class InjectLock(object):
    """串行化"往 Run 框打字"这件事。

    两个进程同时注入 = 两条命令的字符交错，VM 里会收到一串谁也看不懂的东西
    （实测过一次，表现是"注入偶尔失灵"，排查代价很高）。所以用文件锁排队。
    """

    def __init__(self, timeout=600.0, poll=1.0):
        self.timeout = timeout
        self.poll = poll

    def __enter__(self):
        t0 = time.time()
        while True:
            try:
                fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(os.getpid()).encode())
                os.close(fd)
                return self
            except FileExistsError:
                try:
                    if time.time() - os.path.getmtime(LOCK) > LOCK_STALE:
                        os.remove(LOCK)
                        continue
                except OSError:
                    pass
                if time.time() - t0 > self.timeout:
                    raise RuntimeError("等 VM 注入锁超时（另一个进程在注入？）")
                time.sleep(self.poll)

    def __exit__(self, *exc):
        try:
            os.remove(LOCK)
        except OSError:
            pass
        return False


def post_event(ev):
    """主机侧 /vm/input 一次只接收【一个】事件对象（不是数组），别问，问就是踩过。"""
    body = json.dumps(ev).encode("utf-8")
    req = urllib.request.Request(BASE + "/vm/input?k=" + TOKEN, data=body,
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode("utf-8", "replace")


def key(vk, down):
    return {"t": "key", "vk": vk, "down": bool(down)}


def tap(vk):
    return [key(vk, True), key(vk, False)]


def send(events, gap_ms=0, per_gap_ms=45):
    """逐个投递事件；per_gap 保证按键顺序不乱，gap 用于批间停顿。"""
    out = ""
    for ev in events:
        out = post_event(ev)
        if per_gap_ms:
            time.sleep(per_gap_ms / 1000.0)
    if gap_ms:
        time.sleep(gap_ms / 1000.0)
    return out


def run(cmd, settle=1.2, wait_for=None, timeout=90, text_wait=1.8):
    """Win+R -> 文本 -> 回车。cmd 为完整命令行。

    时序是实测出来的：剪贴板 + Ctrl+V 落地需要时间，回车发早了就是给空框按回车
    （Run 框不会关，也不报错，看上去像"注入失效"，其实只是太急）。
    整段注入用文件锁串行化，见 InjectLock。
    """
    with InjectLock():
        print(f"[vm] 注入命令: {cmd}")
        send([key(VK_WIN, True), key(VK_R, True), key(VK_R, False), key(VK_WIN, False)], 1300)
        send([{"t": "text", "s": cmd}], 0, per_gap_ms=0)
        time.sleep(text_wait)
        send(tap(VK_RETURN), 0.6, per_gap_ms=60)
        send(tap(VK_RETURN), 0)
    if wait_for:
        t0 = time.time()
        while time.time() - t0 < timeout:
            if os.path.exists(wait_for):
                time.sleep(settle)
                return reading(wait_for)
            time.sleep(1.0)
        return f"（超时 {timeout}s 未出现 {wait_for}）"
    time.sleep(settle)
    return ""


def reading(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError as e:
        return f"（读不到 {path}: {e}）"


def frame(path):
    with urllib.request.urlopen(BASE + "/vm/frame.jpg", timeout=15) as r:
        data = r.read()
    with open(path, "wb") as f:
        f.write(data)
    print(f"[vm] 画面 {len(data)}B -> {path}")
    return path


def fg():
    """当前前台窗口（判断注入会不会被 UIPI 吃掉：前台若是"管理员:"窗口，注入无效）。"""
    with urllib.request.urlopen(BASE + "/vm/status", timeout=8) as r:
        d = json.load(r)
    rep = ((d.get("control") or {}).get("reports") or {}).get("input") or {}
    return rep


def click(nx, ny, button="l"):
    send([{"t": "move", "x": nx, "y": ny}], per_gap_ms=0)
    send([{"t": "btn", "x": nx, "y": ny, "b": button, "down": True},
          {"t": "btn", "x": nx, "y": ny, "b": button, "down": False}], per_gap_ms=60)


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    if argv[0] == "--check":
        print(reading(argv[1]))
        return 0
    if argv[0] == "--frame":
        frame(argv[1] if len(argv) > 1 else "vm-frame.jpg")
        return 0
    if argv[0] == "--fg":
        r = fg()
        print(f"前台: {r.get('fgTitle')!r}  锁屏={r.get('locked')}  注入数={r.get('injected')}  "
              f"最近事件={r.get('lastEvent')!r}  窗口={r.get('windows')}")
        return 0
    if argv[0] == "--click":
        click(float(argv[1]), float(argv[2]))
        print("已点击")
        return 0
    if argv[0] == "--text":
        send([{"t": "text", "s": argv[1]}], per_gap_ms=0)
        print("已投递文本")
        return 0
    if argv[0] == "--keys":
        send([key(int(x), True) for x in argv[1:]] + [key(int(x), False) for x in reversed(argv[1:])])
        print("已投递按键")
        return 0
    if argv[0] == "--run":
        # --run "C:\path\x.cmd" [--wait C:/dshlcd/out/x.log] [--timeout 300]
        rest = argv[1:]
        wait = None
        timeout = 300
        cmd_parts = []
        i = 0
        while i < len(rest):
            if rest[i] == "--wait":
                wait = rest[i + 1]; i += 2
            elif rest[i] == "--timeout":
                timeout = int(rest[i + 1]); i += 2
            else:
                cmd_parts.append(rest[i]); i += 1
        print(run(" ".join(cmd_parts), wait_for=wait, timeout=timeout) or "已投递")
        return 0
    print(run(" ".join(argv)) or "已投递")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
