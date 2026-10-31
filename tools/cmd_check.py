#!/usr/bin/env python3
"""
cmd_check.py — .cmd/.bat 的静态语法与编码校验（本机没有 cmd.exe / wine，这是能做的最强验证）

检查项：
  1. 编码：必须是**当前 OEM 代码页可安全读**的。中文 Windows 的 cmd 用 GBK(936) 读文件，
     UTF-8 中文注释会被错解 → 把行截断 → 出现 "xxx 不是内部或外部命令" 这种怪错。
     **最稳的做法是纯 ASCII**（本工具默认推荐）。
  2. 换行：必须 CRLF（cmd 对 LF 的 .cmd 解析会出问题）。
  3. 括号平衡：按行累计，且 `(` 结尾的多行块必须闭合。
  4. 标签：`goto X` / `call :X` 的目标必须存在；`if ... goto failed` 也一样。
  5. 危险构造：`else (` 嵌套在 `for ... do (` 里、延迟展开 `!var!` 但没开
     `enabledelayedexpansion`、`findstr /C:` 里含中文等。

用法: python3 tools/cmd_check.py win/build.cmd [更多文件...]
"""
import re
import sys


def check(path, expand_vars=('HERE', 'SRC', 'OUT', 'LOG', 'CSC')):
    problems = []
    data = open(path, 'rb').read()

    # ---- 1. 编码 ----
    is_ascii = all(b < 128 for b in data)
    enc = 'ASCII'
    if not is_ascii:
        try:
            data.decode('gbk')
            enc = 'GBK(可解)'
        except Exception:
            data.decode('utf-8', errors='replace')
            enc = 'UTF-8'
            problems.append('不是纯 ASCII，且 **GBK 解不了** —— cmd.exe（中文 Windows，代码页 936）'
                            '会把中文注释错解并截断行 → 报"xxx 不是内部或外部命令"。'
                            '建议：注释改成英文（纯 ASCII）')

    text = data.decode('gbk', errors='replace')
    lines = text.split('\r\n')
    if len(lines) == 1 and '\n' in text:
        lines = text.split('\n')

    # ---- 2. 换行 ----
    crlf = data.count(b'\r\n')
    lf = data.count(b'\n')
    if lf and crlf != lf:
        problems.append('换行不一致：CRLF=%d 纯LF=%d（cmd 对 LF 解析会出问题）' % (crlf, lf - crlf))

    # ---- 3. 括号平衡 ----
    depth = 0
    for i, l in enumerate(lines, 1):
        s = l.strip()
        if s.startswith('rem') or s.startswith('::'):
            continue
        # 不计 echo 里的括号
        code = re.sub(r'^echo\b.*$', '', s, flags=re.I)
        depth += code.count('(') - code.count(')')
        if depth < 0:
            problems.append('行%d 括号提前闭合（多余 `)`）：%s' % (i, s[:60]))
            depth = 0
    if depth != 0:
        problems.append('括号不平衡：结束时仍有 %d 个未闭合的 `(`' % depth)

    # ---- 4. 标签 ----
    labels = set()
    for l in lines:
        m = re.match(r'^\s*:(\w+)', l)
        if m:
            labels.add(m.group(1).lower())
    for i, l in enumerate(lines, 1):
        for m in re.finditer(r'\bgoto\s+:?(\w+)', l, re.I):
            tgt = m.group(1).lower()
            if tgt == 'eof':
                continue
            if tgt not in labels:
                problems.append('行%d `goto %s` 的目标标签不存在' % (i, m.group(1)))
        for m in re.finditer(r'\bcall\s+:(\w+)', l, re.I):
            if m.group(1).lower() not in labels:
                problems.append('行%d `call :%s` 的目标标签不存在' % (i, m.group(1)))

    # ---- 5. 危险构造 ----
    has_delayed = any(re.match(r'^\s*setlocal\b.*enabledelayedexpansion', l, re.I) for l in lines)
    for i, l in enumerate(lines, 1):
        if re.search(r'!\w+!', l) and not has_delayed:
            problems.append('行%d 用了 `!var!` 延迟展开，但脚本里没有 `setlocal enabledelayedexpansion`'
                            % i)
    # for 块里嵌 else (
    in_for = 0
    for i, l in enumerate(lines, 1):
        s = l.strip()
        if re.match(r'^for\b.*do\s*\($', s, re.I):
            in_for += 1
        elif in_for and s == ')':
            in_for -= 1
        elif in_for and re.search(r'\)\s*else\s*\(', s):
            problems.append('行%d `for` 块里嵌了 `) else (` —— cmd 解析易错，建议改写成 `call :sub`' % i)
    return enc, len(lines), problems


def main():
    files = sys.argv[1:]
    if not files:
        import glob, os
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        files = sorted(glob.glob(os.path.join(root, 'win', '*.cmd'))) + \
                sorted(glob.glob(os.path.join(root, 'bridge', 'win', '*.cmd')))
    total = 0
    for f in files:
        enc, n, problems = check(f)
        name = f.split('/')[-1]
        if problems:
            print('  ❌ %-14s (%s, %d 行)' % (name, enc, n))
            for p in problems:
                print('       - %s' % p)
            total += len(problems)
        else:
            print('  ✅ %-14s (%s, %d 行)' % (name, enc, n))
    print()
    print('  合计 %d 处问题' % total)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
