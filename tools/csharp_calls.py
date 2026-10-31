#!/usr/bin/env python3
"""
检查**工程内自定义方法**的调用点：实参个数是否与形参匹配。
对应编译错误 CS1501（参数个数不对）/ CS1502 / CS1503（参数类型不对）。

为什么需要：csharp_audit.py 查语法结构，查不出"调用时少传一个参数"这类错误；
而这一类正是本项目历史上真实踩过的（CS1502/CS1503）。

设计取舍：
  · 只查**能可靠解析**的调用 —— 方法名唯一（全工程只有一个同名定义）的才查。
    同名重载全部跳过（无法在不做完整重载解析的情况下判断）。
  · 实参切分做了括号/字符串/泛型感知，避免 `f(a,b(c,d),e)` 被误切成 4 个。
  · 只报告**确定不一致**的，宁可漏报不误报（误报会浪费用户时间）。
"""
import glob, os, re, sys

def strip_code(t):
    """去掉注释与字符串/字符字面量（保留换行，保证行号不漂）"""
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        # 行注释
        if c == '/' and i+1 < n and t[i+1] == '/':
            while i < n and t[i] != '\n': i += 1
            continue
        # 块注释
        if c == '/' and i+1 < n and t[i+1] == '*':
            i += 2
            while i+1 < n and not (t[i] == '*' and t[i+1] == '/'):
                if t[i] == '\n': out.append('\n')
                i += 1
            i += 2
            continue
        # 逐字字符串 @"..."
        if c == '@' and i+1 < n and t[i+1] == '"':
            i += 2
            while i < n:
                if t[i] == '"':
                    if i+1 < n and t[i+1] == '"': i += 2; continue
                    i += 1; break
                if t[i] == '\n': out.append('\n')
                i += 1
            out.append('""'); continue
        # 普通字符串
        if c == '"':
            i += 1
            while i < n:
                if t[i] == '\\': i += 2; continue
                if t[i] == '"': i += 1; break
                if t[i] == '\n': out.append('\n')
                i += 1
            out.append('""'); continue
        # 字符字面量
        if c == "'":
            i += 1
            while i < n:
                if t[i] == '\\': i += 2; continue
                if t[i] == "'": i += 1; break
                i += 1
            out.append("'x'"); continue
        out.append(c); i += 1
    return ''.join(out)

def split_args(s):
    """按顶层逗号切分（括号/尖括号/方括号/字符串感知）"""
    out, depth, cur, instr = [], 0, '', False
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if instr:
            cur += c
            if c == '\\': 
                if i+1 < n: cur += s[i+1]; i += 2; continue
            elif c == '"': instr = False
            i += 1; continue
        if c == '"': instr = True; cur += c; i += 1; continue
        if c in '([{': depth += 1; cur += c
        elif c in ')]}': depth -= 1; cur += c
        elif c == '<' and depth == 0:
            # 泛型实参：只有当后面能找到匹配的 > 且之后是 ( 或 . 才当尖括号
            j, d = i, 0
            while j < n and s[j] in '<>': d += 1 if s[j]=='<' else -1; j += 1
            if d == 0: depth += 1; cur += c
            else: cur += c
        elif c == '>' and depth > 0:
            depth -= 1; cur += c
        elif c == ',' and depth == 0:
            out.append(cur); cur = ''
        else: cur += c
        i += 1
    if cur.strip(): out.append(cur)
    return [a.strip() for a in out]

# ---- 1. 收集自定义方法定义（只保留"名字唯一"的）----
defs = {}
for p in sorted(glob.glob('win/src/*.cs')):
    src = strip_code(open(p, encoding='utf-8').read())
    for m in re.finditer(r'\b(?:public|private|protected|internal)\s+(?:static\s+|virtual\s+|override\s+|sealed\s+|new\s+|async\s+)*[\w<>,\[\]\.\?]+\s+(\w+)\s*\(([^)]*)\)\s*(?:\{|=>|$)', src):
        name, params = m.group(1), m.group(2)
        if name in ('if','for','while','switch','catch','lock','using','return','foreach','fixed','sizeof','typeof','nameof','get','set','delegate'):
            continue
        # 参数个数（去掉 this/out/ref/params 等修饰）
        ps = [x.strip() for x in split_args(params) if x.strip()]
        nparams = len(ps)
        # params 可变参数：个数校验无意义，标记为 -1 跳过
        if any(re.search(r'\bparams\b', x) for x in ps):
            nparams = -1
        defs.setdefault(name, set()).add(nparams)
uniq = {k: list(v)[0] for k, v in defs.items() if len(v) == 1 and list(v)[0] >= 0}

# ---- 2. 检查调用点 ----
problems = []
for p in sorted(glob.glob('win/src/*.cs')) + sorted(glob.glob('win/tools/*.cs')):
    raw = open(p, encoding='utf-8').read()
    src = strip_code(raw)
    for m in re.finditer(r'(?<![\w.])(\w+)\s*\(', src):
        name = m.group(1)
        if name not in uniq: continue
        # 排除 `new Name(` 构造调用（构造函数不在 defs 里按方法处理）
        if re.search(r'\bnew\s+$', src[max(0, m.start()-6):m.start()]): continue
        want = uniq[name]
        # 从 ( 开始匹配到配对 )
        start = m.end() - 1
        d, j = 0, start
        while j < len(src):
            if src[j] == '(': d += 1
            elif src[j] == ')':
                d -= 1
                if d == 0: break
            j += 1
        if j >= len(src): continue
        # ★ 已知限制：这里只看**配对括号内**的文本。因为 strip_code 保留了换行，
        #   多行调用是能正确算出的；但如果实参里含跨行字符串或注释，边界会偏。
        #   历史上唯一的误报来源是"我在第一行截断显示"，不是计数本身。
        inner = src[start+1:j]
        # 跳过定义行本身
        line = src.count('\n', 0, m.start()) + 1
        args = [a for a in split_args(inner) if a.strip()]
        got = len(args)
        # 空调用
        if got == 0 and want == 0: continue
        if got != want:
            # 排除方法定义行（形参表里也会出现名字）
            rawline = raw.split('\n')[line-1]
            if re.search(r'\b(?:public|private|protected|internal)\b', rawline): continue
            problems.append((os.path.basename(p), line, name, want, got, rawline.strip()[:88]))

print(f'  可唯一确定签名的自定义方法: {len(uniq)} 个')
if problems:
    for f, ln, name, want, got, txt in problems:
        print(f'  ❌ {f}:{ln}  {name}() 期望 {want} 个实参，给了 {got} 个')
        print(f'       {txt}')
    print(f'\n  共 {len(problems)} 处可疑')
else:
    print('  ✅ 未发现实参个数不匹配的调用')
