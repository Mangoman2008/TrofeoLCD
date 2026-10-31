#!/usr/bin/env python3
"""win.py —— 在 Win11 ARM 虚拟机里编译/运行 dshlcd 的收发一体脚本。

通道（实测可行）：
  主机 --文件--> ~/.VMDocs/.hwf_share/.disks/C/dshlcd/  （客户机磁盘直挂，VM 立即可见）
  VM   --执行--> livepad 输入注入（Win+R -> 文本 -> 回车），见 tools/vm_exec.py
  VM   --日志--> C:\\dshlcd\\out\\*.log  ，主机直接读回

子命令：
  push                把 win/ 下的源码与 .cmd 同步进 VM（.cmd 自动转 CRLF）
  build               注入 build.cmd 编译，等 build.log 出来并打印
  run <参数...>       注入 dshlcd.exe 的参数，等日志更新并打印新增内容
  log [n]             打印 out\\dshlcd.log 最后 n 行（默认全部）
  buildlog            打印 out\\build.log
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vm_exec as V  # noqa: E402

WIN = os.path.join(os.path.dirname(HERE), os.environ.get("WIN_SRC", "win"))
# WIN_VMDIR 可切换 VM 侧目录名：并行干活时各用一份，避免互相覆盖
VMNAME = os.environ.get("WIN_VMDIR", "dshlcd")
VMDIR = os.path.join(os.path.expanduser("~"), ".VMDocs/.hwf_share/.disks/C", VMNAME)
OUT = os.path.join(VMDIR, "out")
def exe_path() -> str:
    """跑当前版本号的 arm64 产物（与 win/dist 同名，避免点到历史遗留文件）。"""
    try:
        ver = int(open(VERSION_FILE).read().strip())
    except Exception:
        ver = 0
    return "C:\\" + VMNAME + f"\\out\\dshlcd_arm64_v{ver}.exe"


def dec(data: bytes) -> str:
    for enc in ("utf-8", "gbk", "cp936"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", "replace")


def read(path: str) -> str:
    try:
        with open(path, "rb") as f:
            return dec(f.read())
    except OSError as e:
        return f"（读不到 {path}: {e}）"


VERSION_FILE = os.path.join(WIN, ".buildno")


def next_version() -> int:
    """构建号自增（存在 win/.buildno）。产物名与程序内版本号都用它。"""
    n = 0
    try:
        n = int(open(VERSION_FILE).read().strip())
    except Exception:
        n = 0
    n += 1
    try:
        with open(VERSION_FILE, "w") as f:
            f.write(str(n))
    except OSError:
        pass
    return n


def src_fingerprint() -> str:
    """源码指纹：所有 .cs 的 md5 汇总，写进程序里，一眼能看出"跑的是哪份代码"。"""
    import hashlib
    h = hashlib.md5()
    src = os.path.join(WIN, "src")
    for name in sorted(os.listdir(src)):
        if name.endswith(".cs") and name != "BuildInfo.cs":
            h.update(open(os.path.join(src, name), "rb").read())
    return h.hexdigest()[:10]


def write_buildinfo(ver: int, fp: str) -> None:
    cs = os.path.join(WIN, "src", "BuildInfo.cs")
    body = ("// 本文件由 tools/win.py 自动生成，请勿手改（每次构建覆盖）\n"
            "namespace DshLcd\n{\n"
            "    public static class BuildInfo\n    {\n"
            f'        public const string Version = "v{ver}";\n'
            f'        public const string BuiltAt = "{time.strftime("%Y-%m-%d %H:%M:%S")}";\n'
            f'        public const string SourceFingerprint = "{fp}";\n'
            "        public static string Stamp { get { return Version + \" (\" + BuiltAt + \", 源码 \" + SourceFingerprint + \")\"; } }\n"
            "    }\n}\n")
    open(cs, "w", encoding="utf-8").write(body)

    # exe 文件属性（右键 → 详细信息）与 win32icon 一起构成"这版是哪个构建"的线索。
    # 同样每次构建覆盖；AssemblyVersion 必须是数字四段，构建号放进第三段。
    ai = os.path.join(WIN, "src", "AssemblyInfo.cs")
    body2 = ("// 本文件由 tools/win.py 自动生成，请勿手改（每次构建覆盖）\n"
             "using System.Reflection;\n"
             '[assembly: AssemblyTitle("dshlcd — 利民 Trofeo Vision 9.16 LCD 副屏推送器")]\n'
             '[assembly: AssemblyProduct("dshlcd")]\n'
             '[assembly: AssemblyCompany("dsh")]\n'
             '[assembly: AssemblyDescription("LY 协议 USB 推帧 / UDP 遥测 / VM 监视画面 / 网页预览 / 诊断接口")]\n'
             f'[assembly: AssemblyVersion("1.0.{ver}.0")]\n'
             f'[assembly: AssemblyFileVersion("1.0.{ver}.0")]\n'
             f'[assembly: AssemblyInformationalVersion("v{ver} built {time.strftime("%Y-%m-%d %H:%M:%S")} src {fp}")]\n')
    open(ai, "w", encoding="utf-8").write(body2)


def push() -> int:
    os.makedirs(os.path.join(VMDIR, "src"), exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    # 先算版本号并生成 BuildInfo.cs —— 必须在下面的拷贝循环之前，
    # 否则这个文件不会被推进 VM，编译就会报 "BuildInfo does not exist"（已踩）
    ver, fp = next_version(), src_fingerprint()
    write_buildinfo(ver, fp)
    n = 0
    src = os.path.join(WIN, "src")
    for name in sorted(os.listdir(src)):
        if not name.endswith(".cs"):
            continue
        data = open(os.path.join(src, name), "rb").read()
        with open(os.path.join(VMDIR, "src", name), "wb") as f:
            f.write(data)
        n += 1
    # exe 图标：csc /win32icon 要读这个文件，不推过去就只能编出无图标的 exe
    icodir = os.path.join(WIN, "icon")
    if os.path.isdir(icodir):
        os.makedirs(os.path.join(VMDIR, "icon"), exist_ok=True)
        for name in sorted(os.listdir(icodir)):
            if name.lower().endswith(".ico"):
                data = open(os.path.join(icodir, name), "rb").read()
                with open(os.path.join(VMDIR, "icon", name), "wb") as f:
                    f.write(data)
                n += 1
                print("       + icon/" + name)
    cmddir = os.path.join(os.path.dirname(HERE), "win")
    for name in sorted(os.listdir(cmddir)):
        if not name.endswith(".cmd"):
            continue
        # cmd.exe 对 LF 结尾的多行块解析很糟 —— 一律转 CRLF
        data = open(os.path.join(cmddir, name), "rb").read()
        try:
            ver = int(open(VERSION_FILE).read().strip())
        except Exception:
            ver = 0
        data = data.replace(b"__VER__", str(ver).encode())
        data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        with open(os.path.join(VMDIR, name), "wb") as f:
            f.write(data)
    n += 1   # BuildInfo.cs 已在上面的拷贝循环里一起推送
    print(f"[push] v{ver}（源码 {fp}）：{n} 个 .cs + .cmd -> {VMDIR}")
    return 0


def wait_fresh(path: str, since: float, timeout: float = 240, markers=(), settle: float = 3.0) -> bool:
    """等文件出现且比 since 更新，并且【稳定下来】。

    VM 侧写文件是异步的：只看"文件出现"会读到只有一行的半成品（csc 还没编译完）。
    判定条件：出现终态标记，或长度连续 settle 秒不变。
    """
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


def wait_variants(log: str, t0: float, timeout: float = 480) -> bool:
    """等 build-variants.cmd 把两个架构都真的编完。

    不能用 wait_fresh()：那家伙在"文件大小稳定 N 秒"时也会返回 True，
    而这个脚本一开头就先写了一个头行，之后 csc 要跑几十秒 ——
    实测就是这样拿到一份**只有头行**的"成功"构建日志（win_verify.sh 第 1/2 步据此误报 FAIL）。
    """
    while time.time() - t0 < timeout:
        try:
            # 必须比本次开始时间新：只删文件不够（注入失败时旧日志会"复活"，
            # 里面的 arm64 size= 会让这里误判成构建成功，然后 dist 同步就找不到 vN 产物）
            if os.path.getmtime(log) < t0 - 0.5:
                time.sleep(2.0)
                continue
            text = read(log)
        except OSError:
            text = ""
        if "[FAIL]" in text:
            return True
        if ("arm64 size=" in text) and ("x64 size=" in text):
            return True
        time.sleep(2.0)
    return False


def build() -> int:
    log = os.path.join(OUT, "variants.log")
    for p in (log,):
        try:
            os.remove(p)
        except OSError:
            pass
    t0 = time.time()
    # 走 Roslyn + WinForms 的双架构构建（老 csc 不支持 /platform:arm64，
    # 也编不了 Gui.cs 用到的 System.Windows.Forms）
    print("[build] 注入 build-variants.cmd …")
    V.run("cmd /c C:\\" + VMNAME + r"\build-variants.cmd")
    if wait_variants(log, t0):
        time.sleep(0.5)
        text = read(log)
        # CS0016 = 上一次运行的 exe 还占着文件：杀掉重编一次（Windows 上很常见）
        if "CS0016" in text or "正在使用此文件" in text:
            print("[build] exe 被占用，先 taskkill 再重编一次 …")
            V.run("taskkill /IM dshlcd_arm64.exe /F")
            V.run("taskkill /IM dshlcd_x64.exe /F")
            time.sleep(2.5)
            for f in (log,):
                try:
                    os.remove(f)
                except OSError:
                    pass
            t1 = time.time()
            V.run("cmd /c C:\\" + VMNAME + r"\build-variants.cmd")
            if wait_variants(log, t1):
                time.sleep(0.5)
                text = read(log)
        print("──────── build.log ────────")
        print(text.strip())
        ok = "[OK]" in text
        if ok:
            sync_dist()
        return 0 if ok else 1
    print("（没等到 build.log）")
    return 1


def sync_dist() -> None:
    """把带版本号的产物复制到 win/dist，并打印清单（省得再手动拷、也省得点错文件）。"""
    import shutil
    try:
        ver = int(open(VERSION_FILE).read().strip())
    except Exception:
        ver = 0
    dist = os.path.join(os.path.dirname(HERE), "win", "dist")
    os.makedirs(dist, exist_ok=True)
    got = []
    for arch in ("arm64", "x64"):
        src = os.path.join(OUT, f"dshlcd_{arch}_v{ver}.exe")
        if os.path.exists(src):
            dst = os.path.join(dist, os.path.basename(src))
            shutil.copyfile(src, dst)
            got.append(f"{os.path.basename(dst)} ({os.path.getsize(dst)//1024} KB)")
    print("[dist] 已同步 -> win/dist/：" + ("，".join(got) if got else "（没找到产物）"))


def run(args, timeout=240) -> int:
    log = os.path.join(OUT, "dshlcd.log")
    try:
        os.remove(log)
    except OSError:
        pass
    # 统一走 .cmd 包装再注入：把"exe + 一长串参数"直接打进 Win+R 太脆
    # （实测连着两次不生效，而完全相同的命令写进 .cmd 用 cmd /c 调起就稳定）。
    cmd = exe_path() + (" " + args if args else "")
    wrapper = os.path.join(VMDIR, "run-once.cmd")
    try:
        with open(wrapper, "w", encoding="ascii", newline="") as f:
            f.write("@echo off\r\ncd /d %~dp0\r\n" + cmd + "\r\n")
    except OSError as e:
        print(f"[run] 写 run-once.cmd 失败：{e}")
        return 1
    t0 = time.time()
    print(f"[run] {cmd}")
    V.run("cmd /c C:\\" + VMNAME + r"\run-once.cmd")
    # 只认终态标记：以前拿"日志静默 4 秒"当结束信号，结果 8 秒的演示跑到一半
    # （正好没输出）就被判成结束，日志读一半、产物还没落盘
    settle = float(os.environ.get("WIN_SETTLE", "3600"))
    if wait_fresh(log, t0, timeout=timeout, markers=("已写出", "演示结束", "自检全部通过", "自检有", "探测结束"), settle=settle):
        time.sleep(0.8)
        print("──────── dshlcd.log ────────")
        print(read(log).strip())
        return 0
    print("（没等到 dshlcd.log）")
    return 1


def main(argv) -> int:
    if not argv:
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "vm":
        # 直接注入一条命令：win.py vm "C:\dshlcd\out\dshlcd.exe --probe"
        V.run(" ".join(rest))
        return 0
    if cmd == "push":
        return push()
    if cmd == "build":
        push()
        return build()
    if cmd == "run":
        return run(" ".join(rest))
    if cmd == "log":
        text = read(os.path.join(OUT, "dshlcd.log"))
        n = int(rest[0]) if rest else 0
        lines = text.splitlines()
        print("\n".join(lines[-n:] if n else lines))
        return 0
    if cmd == "buildlog":
        print(read(os.path.join(OUT, "build.log")).strip())
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
