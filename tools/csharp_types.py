#!/usr/bin/env python3
"""
csharp_types.py — 参数类型核对（作用域内变量类型跟踪）

## 为什么需要
2026-10-15 同一个"时间类型不一致"吃了两次编译失败：
  · 先 `DateTime` 传给了要 `long` 的 `Dispatch`（CS1503 参数7）
  · 修完又反过来：`long` 传给了要 `DateTime` 的 `Dashboard.Render*`（CS1503 参数6）
每次都白跑一轮编译。这个脚本把**调用点实参的推断类型**与**被调方法的声明类型**对齐核对。

## 做法（比按参数名猜可靠得多）
  1. 建"方法名 → 各重载的参数类型表"，参数类型按 `DateTime` / `long` / `int` / `string` / `double` 等归一
  2. 逐调用点：先在该方法体内**收集变量声明**（`DateTime now = ...` / `long x = ...` / 形参表），
     再对每个实参：
        · 加/减/取模运算、或整除后取模 → 数值
        · `X.NowMs()` → long
        · 标识符 → 查本作用域的声明类型（形参 + 局部变量 + 字段）
        · `DateTime.Now` / `new DateTime(...)` → DateTime
  3. 类型不一致且**两者都是明确的**（不在未知集合里）→ 报 ❌

用法: python3 tools/csharp_types.py
"""
import glob
import os
import re
import sys

NUMERIC = {'long', 'int', 'double', 'float', 'short', 'byte', 'uint', 'ulong', 'decimal'}
# 语句关键字长得像方法调用（`if (...)` / `while (...)`），必须排除
KEYWORDS = {'if', 'while', 'for', 'foreach', 'switch', 'catch', 'lock', 'using',
            'return', 'get', 'set', 'new', 'sizeof', 'typeof', 'nameof', 'delegate',
            'do', 'else', 'fixed', 'checked', 'unchecked', 'await', 'yield'}
# 属性/字段访问返回的是"数值"而不是其声明类型（`DateTime.Hour` 是 int，不是 DateTime）
NUMERIC_MEMBERS = {'Hour', 'Minute', 'Second', 'Millisecond', 'Day', 'Month', 'Year',
                   'Ticks', 'Length', 'Count', 'DayOfYear', 'DayOfWeek'}


def strip(t):
    """去注释 + 去字符串/字符字面量（保留换行以维持行号）。"""
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        nx = t[i + 1] if i + 1 < n else ''
        if c == '/' and nx == '/':
            while i < n and t[i] != '\n':
                i += 1
            continue
        if c == '/' and nx == '*':
            i += 2
            while i + 1 < n and not (t[i] == '*' and t[i + 1] == '/'):
                if t[i] == '\n':
                    out.append('\n')
                i += 1
            i += 2
            continue
        if c == '@' and nx == '"':
            i += 2
            while i < n:
                if t[i] == '"':
                    if i + 1 < n and t[i + 1] == '"':
                        i += 2
                        continue
                    i += 1
                    break
                if t[i] == '\n':
                    out.append('\n')
                i += 1
            out.append('""')
            continue
        if c == '"':
            i += 1
            while i < n:
                if t[i] == '\\':
                    i += 2
                    continue
                if t[i] == '"':
                    i += 1
                    break
                if t[i] == '\n':
                    out.append('\n')
                i += 1
            out.append('""')
            continue
        if c == "'":
            i += 1
            while i < n and t[i] != "'":
                if t[i] == '\\':
                    i += 1
                i += 1
            i += 1
            out.append("'x'")
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def split_top(s):
    out, d, cur = [], 0, ''
    for ch in s:
        if ch in '([{':
            d += 1
        elif ch in ')]}':
            d -= 1
        if ch == ',' and d == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out if x.strip()]


DECL = re.compile(r'\b(DateTime|long|int|double|float|string|bool|uint|byte|short|decimal|TrccState|FwSimState|DotiiState|PongState|History|Graphics|Bitmap|Color|Font)\s+(\w+)\s*(?:=|;|,|\))')

def build_signatures(codes):
    """方法名 → [(参数类型列表)]"""
    sigs = {}
    for p, c in codes.items():
        for m in re.finditer(r'\b(\w+)\s*\(([^;{}]*)\)\s*\{', c):
            name = m.group(1)
            if name in KEYWORDS:
                continue
            plist = []
            for pt in split_top(m.group(2)):
                mm = re.match(r'\s*(?:ref\s+|out\s+|params\s+)?([\w<>,\[\]\.\?]+)', pt)
                if not mm:
                    continue
                ty = mm.group(1).split('.')[-1].rstrip('?')
                plist.append(ty)
            if plist:
                sigs.setdefault(name, []).append(plist)
    return sigs


def infer(expr, scope):
    """
    推断实参类型。**只返回有把握的结论**，其余一律 '?'（宁可不报，也不误报）。

    ★ 第一版把"含 + - * / %" 的都当成数值 → 所有字符串拼接
      （`"" + FmtTokens(x)`、`FitText(g, ...) + "…"`）全被误判成 num，
      对着 `string` 形参狂报错。字符串拼接是这个代码库里最常见的实参形态。
    """
    e = expr.strip()
    if not e:
        return '?'
    # ★ 三目 `cond ? a : b`：按两支分别推断，只有两支一致时才给结论。
    #   实测 `_st.Fresh ? _st.AgeSec() : -1` 这种混了 string 分支的，
    #   强推成数值会一直误报 —— 宁可不报。
    q = e.find('?')
    if q > 0:
        # 找与 ? 配对的 :
        d, colon = 0, -1
        for i in range(q, len(e)):
            if e[i] in '([{':
                d += 1
            elif e[i] in ')]}':
                d -= 1
            elif e[i] == ':' and d == 0:
                colon = i
                break
        if colon > 0:
            a = infer(e[q + 1:colon], scope)
            b = infer(e[colon + 1:], scope)
            return a if a == b else '?'
    if re.match(r'^DateTime\.Now\b', e) or re.match(r'^new\s+DateTime\b', e):
        return 'DateTime'
    if re.search(r'\b\w+\.NowMs\s*\(', e):
        return 'long'
    # 字符串字面量开头 → string（`"..." + x` 这种拼接）
    if e.startswith('""') or e.startswith('@"') or e.startswith('"'):
        return 'string'
    if re.search(r'\.(ToString|Substring|Trim|Replace|Format)\s*\(', e):
        return 'string'
    # `now.Hour` / `x.Length` 这类是数值，不是其声明类型
    mm2 = re.match(r'^[\w\.\(\)\[\]]+\.(\w+)$', e)
    if mm2 and mm2.group(1) in NUMERIC_MEMBERS:
        return 'num'
    if re.match(r'^\w+$', e):
        return scope.get(e, '?')
    if 'DateTime' in e:
        return 'DateTime'
    # 纯算术：把字符串字面量、字符串方法、以及已知 string 变量剔除后，
    # 若仍含运算符，才认为是数值
    stripped = re.sub(r'""|@""|"[^"]*"', '', e)
    for tok in re.findall(r'\b\w+\b', stripped):
        if scope.get(tok) == 'string':
            return 'string'
        if scope.get(tok) == 'DateTime':
            return 'DateTime'
    if re.search(r'[-*%]', stripped) or re.search(r'[\w\)]\s*/\s*[\w\(]', stripped):
        return 'num'
    # 单个 `+` 且两边都是数值字面量 → 数值
    if re.match(r'^[\d\s+]+$', stripped):
        return 'num'
    return '?'


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = sorted(glob.glob(os.path.join(root, 'win', 'src', '*.cs')))
    codes = {p: strip(open(p, encoding='utf-8', errors='replace').read()) for p in files}
    sigs = build_signatures(codes)

    problems = []
    for p, c in codes.items():
        # 逐方法体处理，保证作用域干净
        for fm in re.finditer(r'\b[\w<>,\[\]\.\?]+\s+(\w+)\s*\(([^;{}]*)\)\s*\{', c):
            b = c.find('{', fm.end() - 1)
            d, j = 0, b
            while j < len(c):
                if c[j] == '{':
                    d += 1
                elif c[j] == '}':
                    d -= 1
                    if d == 0:
                        break
                j += 1
            body = c[b:j]
            scope = {}
            for pt in split_top(fm.group(2)):
                mm = re.match(r'\s*(?:ref\s+|out\s+|params\s+)?([\w<>,\[\]\.\?]+)\s+(\w+)', pt)
                if mm:
                    scope[mm.group(2)] = mm.group(1).split('.')[-1].rstrip('?')
            for dm in DECL.finditer(body):
                scope[dm.group(2)] = dm.group(1)
            base = b
            # ★ 不能用 `(?<![\w.])` —— 那会把**带限定名的调用**（`DshLcd.Dashboard.RenderHorizontal(...)`）
            #   整段跳过，而实测出错的恰恰就是这类。这里允许前面是 `.`，
            #   只要求"名字本身"是一个合法标识符（由 \w+ 保证）。
            for cm in re.finditer(r'\b(\w+)\s*\(', body):
                name = cm.group(1)
                if name in KEYWORDS or name not in sigs:
                    continue
                o = cm.end() - 1
                d2, k = 0, o
                while k < len(body):
                    if body[k] == '(':
                        d2 += 1
                    elif body[k] == ')':
                        d2 -= 1
                        if d2 == 0:
                            break
                    k += 1
                args = split_top(body[o + 1:k])
                got = [infer(a, scope) for a in args]
                for decl in sigs[name]:
                    if len(decl) != len(got):
                        continue
                    for idx, (w, g) in enumerate(zip(decl, got)):
                        if g == '?':
                            continue
                        # ★ 只报"时间类型"方向的不一致 —— 这是实际吃过两次编译失败的那类。
                        #   通用类型推断在 C# 上不可靠（string 拼接、三目、泛型、匿名类型…），
                        #   放宽到全部类型只会淹没真问题。
                        if not ((w == 'DateTime' and g == 'long')
                                or (w == 'long' and g == 'DateTime')):
                            continue
                        ln = c.count('\n', 0, base + cm.start()) + 1
                        problems.append((p, ln,
                                         '%s(...) 第%d参声明为 `%s`，实参 `%s` 推断为 `%s`'
                                         % (name, idx + 1, w, args[idx][:32], g)))
                    break

    print('=' * 70)
    print('参数类型核对（DateTime / long / int 混淆）')
    print('=' * 70)
    if problems:
        for p, ln, why in problems[:40]:
            print('  ❌ %s:%d  %s' % (os.path.basename(p), ln, why))
        print()
        print('  合计 %d 处' % len(problems))
    else:
        print('  ✅ 未发现类型不一致')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
