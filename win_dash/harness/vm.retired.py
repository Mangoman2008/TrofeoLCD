#!/usr/bin/env python3
"""win_dash/vm.py —— 在 Win11 ARM 虚拟机里编译并运行「仪表盘渲染自测」。

和 tools/win.py 同一套通道（共享盘 + livepad 注入），但用的是独立 VM 目录
（默认 C:\\dshlcd_dash），源码取自 win_dash/src/，并在推送前把交付物
win/src/Theme.cs、win/src/Dashboard.cs 同步进来，保证「测的就是要交的那份」。

  python3 win_dash/vm.py sync         只推源码
  python3 win_dash/vm.py build        推源码并编译（打印 build.log）
  python3 win_dash/vm.py run [args]   运行 exe（默认 --all）
  python3 win_dash/vm.py fetch        把 out\\*.jpg 拷回 win_dash/out/ 并打印尺寸
"""
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import vm_exec as V  # noqa: E402

VMNAME = os.environ.get("WIN_VMDIR", "dshlcd_dash")
VMDIR = os.path.join(os.path.expanduser("~"), ".VMDocs/.hwf_share/.disks/C", VMNAME)
SRC = os.path.join(VMDIR, "src")
OUT = os.path.join(VMDIR, "out")
EXE = "C:\\" + VMNAME + r"\out\dshlcd.exe"
LOCAL_SRC = os.path.join(HERE, "src")
LOCAL_OUT = os.path.join(HERE, "out")
DELIVER = os.path.join(ROOT, "win", "src")
KEEP = ["Log.cs", "Ly.cs", "Json.cs", "State.cs"]


def dec(data):
    for enc in ("utf-8", "gbk", "cp936"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", "replace")


def read(path):
    try:
        with open(path, "rb") as f:
            return dec(f.read())
    except OSError as e:
        return f"（读不到 {path}: {e}）"


def put(src, dst):
    """共享盘不接受 utime/chmod（copy2 会因 copystat 报 PermissionError），所以只写字节。"""
    with open(src, "rb") as f:
        data = f.read()
    with open(dst, "wb") as f:
        f.write(data)
    return len(data)


def sync():
    os.makedirs(LOCAL_SRC, exist_ok=True)
    # 1) 把手写的那几份从 win/src 补进工作副本（只在缺失时拷，避免覆盖我的改动）
    for name in KEEP:
        dst = os.path.join(LOCAL_SRC, name)
        if not os.path.exists(dst):
            put(os.path.join(DELIVER, name), dst)
    # 2) 交付物每次强制同步：win_dash 里跑的必须就是要交的 Theme.cs / Dashboard.cs
    for name in ("Theme.cs", "Dashboard.cs"):
        put(os.path.join(DELIVER, name), os.path.join(LOCAL_SRC, name))
    # 3) 全部 .cs 推到 VM 共享盘
    os.makedirs(SRC, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    n = 0
    for name in sorted(os.listdir(LOCAL_SRC)):
        if not name.endswith(".cs"):
            continue
        put(os.path.join(LOCAL_SRC, name), os.path.join(SRC, name))
        n += 1
    # 4) build.cmd 用 win/ 里的那份（CRLF + %~dp0 自定位，放哪个目录都能用）
    data = open(os.path.join(ROOT, "win", "build.cmd"), "rb").read()
    data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    with open(os.path.join(VMDIR, "build.cmd"), "wb") as f:
        f.write(data)
    print(f"[sync] {n} 个 .cs -> {SRC}，build.cmd -> {VMDIR}")
    return sorted(x for x in os.listdir(SRC) if x.endswith(".cs"))


def wait_fresh(path, since, timeout=300, markers=(), settle=4.0):
    t0 = time.time()
    last_size, last_change = -1, time.time()
    while time.time() - t0 < timeout:
        try:
            size = os.path.getsize(path)
            mtime = os.path.getmtime(path)
        except OSError:
            time.sleep(1.0)
            continue
        if mtime < since - 0.5:
            time.sleep(1.0)
            continue
        if size != last_size:
            last_size, last_change = size, time.time()
        text = read(path)
        if any(m in text for m in markers):
            return True
        if size > 0 and time.time() - last_change >= settle:
            return True
        time.sleep(1.0)
    return False


def build():
    names = sync()
    print("[build] 源码:", ", ".join(names))
    log = os.path.join(OUT, "build.log")
    try:
        os.remove(log)
    except OSError:
        pass
    t0 = time.time()
    print("[build] 注入 build.cmd …")
    V.run("cmd /c C:\\" + VMNAME + r"\build.cmd")
    if wait_fresh(log, t0, timeout=200, markers=("[OK]", "[FAIL]")):
        time.sleep(0.5)
        text = read(log)
        print("──────── build.log ────────")
        print(text.strip())
        return 0 if "[OK]" in text else 1
    print("（没等到 build.log）")
    return 1


def run(args):
    log = os.path.join(OUT, "dshlcd.log")
    try:
        os.remove(log)
    except OSError:
        pass
    cmd = EXE + (" " + args if args else "")
    t0 = time.time()
    print(f"[run] {cmd}")
    V.run(cmd)
    if wait_fresh(log, t0, timeout=300, markers=("== dash marker ==", "== dash done", "渲染结束 FAIL")):
        time.sleep(1.0)
        print("──────── dshlcd.log ────────")
        print(read(log).strip())
        return 0
    print("（没等到 dshlcd.log）")
    print(read(log).strip())
    return 1


def fetch():
    os.makedirs(LOCAL_OUT, exist_ok=True)
    got = 0
    for name in sorted(os.listdir(OUT)):
        if not name.lower().endswith((".jpg", ".jpeg", ".log")):
            continue
        put(os.path.join(OUT, name), os.path.join(LOCAL_OUT, name))
        size = os.path.getsize(os.path.join(LOCAL_OUT, name))
        print(f"[fetch] {name}  {size} B")
        got += 1
    return got


def main(argv):
    cmd = argv[0] if argv else "build"
    if cmd == "sync":
        sync()
        return 0
    if cmd == "build":
        return build()
    if cmd == "run":
        return run(" ".join(argv[1:]) or "--all")
    if cmd == "all":
        rc = build()
        if rc != 0:
            return rc
        rc = run("--all")
        fetch()
        return rc
    if cmd == "fetch":
        fetch()
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
