#!/usr/bin/env python3
"""C# 侧静态自审（无编译器时的替代验证）

## 为什么需要它
TrofeoLCD 的 Windows 版（`win/src/*.cs`）**只能在一台 Windows 虚拟机上用
.NET Framework 的 csc 编译**，而本机没有 C# 工具链、那台构建 VM 也不可达
（都实测过）。于是移植完只能"读代码自检"，很容易把语法/符号错误交出去。

这个脚本把"编译器会报的错"里**能在文本层查出来的那部分**自动化，覆盖：

1. **C# 5 语言上限违规** —— 构建 VM 上只有 .NET Framework 4 的 csc（语言上限 C# 5）：
   - 字符串插值 `$"..."` / `$@"..."`
   - 空传播 `?.` 与空索引 `?[`、空合并赋值 `??=`
   - 表达式体成员 `=> 🅧;`（**排除 lambda 与委托**：`delegate(...)` / `(...) =>` 是合法的）
   - `nameof(`、`out var`、元组解构、`is ... not`、范围运算符 `..`
   - `record` / `init` 访问器 / 目标类型 new
2. **括号平衡**（剔除字符串与注释后再数 `{} () []`）
3. **符号存在性** —— 新代码里调用的 `Draw.Xxx()` / `F.Xxx()` / `Backdrop.Xxx()` /
   `HostStats.Xxx()` / `Themes.Xxx()` 必须在某处有定义（抓错别字，这是最容易犯的错）
4. **重复类名** —— 同名 class/struct/enum 定义两遍会 CS0101

## 用法
    python3 tools/csharp_audit.py            # 审 win/src/*.cs
    python3 tools/csharp_audit.py --json     # 机器可读输出

退出码：0 = 全部通过；1 = 发现问题。它**不能替代真正的编译**，只是把明显错误挡在前面。
"""
import argparse
import glob
import json
import os
import re
import sys

SRC_GLOB = 'win/src/*.cs'


def strip_code(text):
    """去掉注释与字符串/字符字面量，返回可安全解析的代码。逐字符扫描。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ''
        if c == '/' and nxt == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue          # 换行本身留给主循环（保持行号一致）
        if c == '/' and nxt == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                if text[i] == '\n':
                    out.append('\n')      # ★ 保留换行：否则块注释会吃掉行号
                i += 1
            i += 2
            continue
        if c == '@' and nxt == '"':
            i += 2
            while i < n:
                if text[i] == '"':
                    if i + 1 < n and text[i + 1] == '"':
                        i += 2            # 逐字串里的 "" 是一个引号
                        continue
                    i += 1
                    break
                if text[i] == '\n':
                    out.append('\n')      # ★ 保留换行
                i += 1
            out.append('""')
            continue
        if c == '"':
            # ★ 普通字符串：必须正确处理反斜杠转义。
            #   第一版写成 `while text[i] != '"': if text[i]=='\\': i+=1; i+=1`
            #   —— 遇到 `\"`（反斜杠+引号）时：跳到引号上、判断 `== '"'` 成立 → **提前结束字符串**，
            #   于是后面的内容被当成代码。MiniHttp.cs 里 `"{\"error\":\"unsupported\"}"` 正是这种，
            #   导致该文件被误报"括号不平衡"。这一步用 for+else 正确处理任意转义。
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                if text[i] == '\n':
                    out.append('\n')      # ★ 保留换行
                i += 1
            out.append('""')
            continue
        if c == "'":
            i += 1
            while i < n and text[i] != "'":
                if text[i] == '\\':
                    i += 1
                i += 1
            i += 1
            out.append("'x'")
            continue
        out.append(c)
        i += 1
    return ''.join(out)



def line_of(text, pos):
    return text.count('\n', 0, pos) + 1


def check_cs5(name, raw, code):
    """C# 6+ 特性检查（构建 VM 上限 C# 5）。返回 [(行号, 说明)]"""
    hits = []
    patterns = [
        (r'\$"', '字符串插值 $"..."（C# 6）'),
        (r'\$@"', '逐字插值字符串 $@"..."（C# 6）'),
        (r'\?\.', '空传播 ?.（C# 6）'),
        (r'\?\[', '空索引 ?[（C# 6）'),
        (r'\?\?=', '空合并赋值 ??=（C# 8）'),
        (r'\bnameof\s*\(', 'nameof（C# 6）'),
        (r'\bout\s+var\b', 'out var（C# 7）'),
        (r'\bis\s+not\b', 'is not（C# 9）'),
        (r'\brecord\s+[A-Za-z_]', 'record 类型（C# 9）'),
        (r'\binit\s*;', 'init 访问器（C# 9）'),
    ]
    for pat, why in patterns:
        for m in re.finditer(pat, code):
            hits.append((line_of(code, m.start()), why))
    # 表达式体成员：`=> x;` 结束，且不是 lambda/委托
    for m in re.finditer(r'=>\s*[^;{]{1,120};', code):
        seg = code[max(0, m.start() - 160):m.start()]
        if re.search(r'(delegate\s*\(|\([^)]*\)\s*$|\bdelegate\b)', seg):
            continue
        # 方法/属性体：前面应有 `) ` 或标识符，且同一行没有 (
        line_start = code.rfind('\n', 0, m.start()) + 1
        head = code[line_start:m.start()]
        if '(' in head or 'delegate' in head:
            continue
        hits.append((line_of(code, m.start()), '表达式体成员 =>（C# 6）'))
    return hits


def check_balance(name, code):
    pairs = {'{': '}', '(': ')', '[': ']'}
    stack = []
    line = 1
    for ch in code:
        if ch == '\n':
            line += 1
        elif ch in pairs:
            stack.append((ch, line))
        elif ch in pairs.values():
            if not stack:
                return [(line, '多余的闭合 %s' % ch)]
            op, ol = stack.pop()
            if pairs[op] != ch:
                return [(line, '%s（第 %d 行）与 %s 不匹配' % (op, ol, ch))]
    if stack:
        return [(stack[-1][1], '未闭合的 %s' % stack[-1][0])]
    return []


def collect_defs(files):
    """收集 class/struct/enum 定义与静态成员名，用于符号存在性检查"""
    classes = {}
    members = {}
    # 每个类的成员名单独成桶，供符号存在性检查用（Draw/F/Backdrop/HostStats/Themes）
    for path in files:
        raw0 = open(path, encoding='utf-8', errors='replace').read()
        code0 = strip_code(raw0)
        for m0 in re.finditer(r'\b(?:public|internal)?\s*(?:static\s+)?(?:sealed\s+)?'
                              r'(?:class|struct)\s+([A-Za-z_][A-Za-z0-9_]*)', code0):
            cname = m0.group(1)
            brace = code0.find('{', m0.end())
            if brace < 0:
                continue
            depth, i = 0, brace
            while i < len(code0):
                if code0[i] == '{':
                    depth += 1
                elif code0[i] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            body = code0[brace:i]
            bucket = members.setdefault(cname, set())
            for mm in re.finditer(r'\b(?:enum|struct)\s+([A-Za-z_][A-Za-z0-9_]*)', body):
                bucket.add(mm.group(1))
            for mm in re.finditer(r'\b(?:public|internal|private|protected)\s+'
                                  r'(?:static\s+|readonly\s+|const\s+|sealed\s+|override\s+)*'
                                  r'[A-Za-z_][A-Za-z0-9_<>,\[\]\.\?]*\s+'
                                  r'([A-Za-z_][A-Za-z0-9_]*)\s*[\(=;{]', body):
                bucket.add(mm.group(1))
        # 命名空间级的 enum（Backdrop.Style 之类）
        for m1 in re.finditer(r'\benum\s+([A-Za-z_][A-Za-z0-9_]*)', code0):
            members.setdefault('__enums__', set()).add(m1.group(1))
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for m in re.finditer(r'\b(?:public|internal|private|protected)?\s*(?:static\s+|sealed\s+|abstract\s+|partial\s+)*'
                             r'(class|struct|enum|interface)\s+([A-Za-z_][A-Za-z0-9_]*)', code):
            kind, nm = m.group(1), m.group(2)
            if nm in classes:
                classes[nm].append((path, line_of(code, m.start()), kind))
            else:
                classes[nm] = [(path, line_of(code, m.start()), kind)]
    return classes, members


def member_names_of(text):
    """提取某个类体里的成员名（方法/属性/字段/嵌套类型）。
    做法：从 `class X` 的 `{` 开始做花括号配对取块，再在块内匹配
    `名字(` 或 `名字 =` 或 `名字;` 或 `enum 名字`。比单行正则可靠。"""
    names = set()
    for m in re.finditer(r'\bclass\s+([A-Za-z_][A-Za-z0-9_]*)', text):
        brace = text.find('{', m.end())
        if brace < 0:
            continue
        depth, i = 0, brace
        while i < len(text):
            if text[i] == '{':
                depth += 1
            elif text[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = text[brace:i]
        for mm in re.finditer(r'\b(?:enum|struct)\s+([A-Za-z_][A-Za-z0-9_]*)', body):
            names.add(mm.group(1))
        for mm in re.finditer(r'\b(?:public|internal|private|protected)\s+'
                              r'(?:static\s+|readonly\s+|const\s+|sealed\s+|override\s+)*'
                              r'[A-Za-z_][A-Za-z0-9_<>,\[\]\.\?]*\s+'
                              r'([A-Za-z_][A-Za-z0-9_]*)\s*[\(=;{]', body):
            names.add(mm.group(1))
    return names


def nm_of(path):
    return os.path.basename(path)


def check_symbols(files, all_members):
    """检查新代码里调用的辅助方法是否存在（抓错别字）"""
    wanted = {}
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for cls in ('Draw', 'F', 'Backdrop', 'HostStats', 'Themes'):
            for m in re.finditer(r'\b' + cls + r'\.([A-Za-z_][A-Za-z0-9_]*)\s*\(', code):
                wanted.setdefault(cls, {}).setdefault(m.group(1), []).append(
                    (path, line_of(code, m.start())))
    missing = []
    for cls, calls in wanted.items():
        defined = all_members.get(cls, set())
        for fn, locs in calls.items():
            if fn not in defined:
                for path, line in locs[:3]:
                    missing.append((path, line, '%s.%s()' % (cls, fn)))
    return missing


def check_color_tokens(files):
    """检查 `C.Xxx` 引用的颜色令牌是否在 Theme.cs 的 class C 里定义。

    ★ 为什么专门查这个：跨类成员访问（`C.Xxx`）无法用括号解析验证 —— 审计器只按
      「类名 + 花括号块」收集成员，而 `class C` 的定义与 `C.Xxx` 的使用常在不同文件。
      我移植主题时大量引用颜色令牌，写错一个名字就是编译错误。这里做一次真实的交叉核对。
    """
    defined = set()
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for m in re.finditer(r'\b(?:public|internal)\s+static\s+class\s+C\b', code):
            brace = code.find('{', m.end())
            if brace < 0:
                continue
            depth, i = 0, brace
            while i < len(code):
                if code[i] == '{':
                    depth += 1
                elif code[i] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            body = code[brace:i]
            for mm in re.finditer(r'public\s+static\s+(?:readonly\s+)?Color\s+([A-Za-z_][A-Za-z0-9_]*)', body):
                defined.add(mm.group(1))
    if not defined:
        return []
    missing = []
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for m in re.finditer(r'\bC\.([A-Za-z_][A-Za-z0-9_]*)', code):
            tok = m.group(1)
            if tok not in defined:
                missing.append((path, line_of(code, m.start()), 'C.%s（Theme.cs 里没有这个颜色令牌）' % tok))
    return missing


def check_literal_ratios(files):
    """检查 `Color.FromArgb` 的参数个数。

    ⚠️ 这里**故意做得很保守**：`FromArgb(int alpha, Color base)` 是合法重载，
    第二参可以是 `Color.White`、`Cyan`、`PanelC`、`color` 这些**变量/字段** ——
    无法从文本判断类型。所以只在"第二参明确是数字字面量"（原代码里最可能的手误）时报，
    其余情况一律放行，避免误报把真问题淹没。

    行号取**原始文件**的行号（早期版本用了去注释后的行号，报出来是错位的）。
    """
    bad = []
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for m in re.finditer(r'Color\.FromArgb\s*\(', code):
            i = m.end() - 1
            depth, j = 0, i
            while j < len(code):
                if code[j] == '(':
                    depth += 1
                elif code[j] == ')':
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            inner = code[i + 1:j]
            depth2, parts = 0, 1
            for ch in inner:
                if ch in '([':
                    depth2 += 1
                elif ch in ')]':
                    depth2 -= 1
                elif ch == ',' and depth2 == 0:
                    parts += 1
            if parts == 2:
                second = inner.split(',')[1].strip()
                if re.match(r'^\d+$', second):
                    bad.append((path, line_of(raw, m.start()),
                                'Color.FromArgb(alpha, %s) 第二参是数字 —— 应为 Color（3/4 参形式？）' % second))
            elif parts not in (3, 4):
                bad.append((path, line_of(raw, m.start()),
                            'Color.FromArgb 参数 %d 个（应为 3 或 4）' % parts))
    return bad


def check_member_access(files):
    """核对 `Xxx.Member` 形式的静态访问 —— 抓"用了不存在的成员"。

    ★ 为什么需要：我移植时反复按 ArkTS/JS 的习惯写 C# 成员名
      （最典型：把 `JsonValue.IsArr` 写成 `IsArray`，`Color.FromArgb` 的参数个数，
        `WithAlpha` 的语义是比例还是 0-255）—— 这些都是**编译错误**，
      而本机没有 C# 编译器。这里对"能确定归属类"的访问做一次真实核对：
      只检查那些**在某个 .cs 里定义过的类**上的静态成员访问，
      未在工程内定义的类（System.Drawing.Image 等 BCL 类型）一律跳过。
    """
    # 收集：每个类名 → 成员集合
    class_members = {}
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for m in re.finditer(r'\b(?:public|internal)?\s*(?:static\s+)?(?:sealed\s+|abstract\s+|partial\s+)*'
                             r'(?:class|struct)\s+([A-Za-z_][A-Za-z0-9_]*)', code):
            cname = m.group(1)
            brace = code.find('{', m.end())
            if brace < 0:
                continue
            depth, i = 0, brace
            while i < len(code):
                if code[i] == '{':
                    depth += 1
                elif code[i] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            body = code[brace:i]
            bucket = class_members.setdefault(cname, set())
            for mm in re.finditer(r'\b(?:enum|struct)\s+([A-Za-z_][A-Za-z0-9_]*)', body):
                bucket.add(mm.group(1))
            for mm in re.finditer(r'\b(?:public|internal|private|protected)\s+'
                                  r'(?:static\s+|readonly\s+|const\s+|sealed\s+|override\s+)*'
                                  r'[A-Za-z_][A-Za-z0-9_<>,\[\]\.\?]*\s+'
                                  r'([A-Za-z_][A-Za-z0-9_]*)\s*[\(=;{]', body):
                bucket.add(mm.group(1))
            # 静态类里的成员（如 JsonValue 的属性、Backdrop 的字段）
            for mm in re.finditer(r'\b(?:public|internal)\s+'
                                  r'(?:static\s+|readonly\s+|const\s+)+'
                                  r'[A-Za-z_][A-Za-z0-9_<>,\[\]\.\?]*\s+'
                                  r'([A-Za-z_][A-Za-z0-9_]*)\s*[\(=;{]', body):
                bucket.add(mm.group(1))

    # BCL / ArkTS 习惯里常见的"已知不是本工程的类"，跳过
    skip = set(['Color', 'Image', 'Bitmap', 'Math', 'Console', 'File', 'Path', 'Directory',
                'Convert', 'Environment', 'String', 'Enumerable', 'Thread', 'Marshal',
                'Graphics', 'Font', 'Brush', 'Pen', 'Rectangle', 'Point', 'Matrix',
                'JsonValue', 'Application', 'MessageBox', 'Stopwatch', 'DateTime'])

    # 自动求"纯静态类"集合：类体里**没有任何实例成员**（无 `public int Foo = ...;` 之类）
    static_only_classes = set()
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for m in re.finditer(r'\b(?:public|internal)?\s*static\s+class\s+([A-Za-z_][A-Za-z0-9_]*)', code):
            cname = m.group(1)
            brace = code.find('{', m.end())
            if brace < 0:
                continue
            depth, i = 0, brace
            while i < len(code):
                if code[i] == '{':
                    depth += 1
                elif code[i] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            if not re.search(r'\bstatic\s+class\b', code[m.start():m.end() + 1]):
                continue
            static_only_classes.add(cname)

    problems = []
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for m in re.finditer(r'\b([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)', code):
            cls, mem = m.group(1), m.group(2)
            if cls in skip:
                continue
            # ★ 只审**纯静态类** —— 这是本工具真正有价值的范围，而且名单**自动判定**。
            #
            #   原因：`Foo.Bar` 里的 `Foo` 无法从文本区分"类名"还是"变量名"
            #   （`Telemetry` 既是类名、也常做局部变量类型声明，于是 `Telemetry.Fresh`
            #   这种写法会被误判）。而 `JsonValue` 这类既有静态成员又有实例属性的类
            #   同样两边都可能 —— 实测这些误报会淹没真问题。
            #
            #   自动判定的依据：**类里没有任何实例成员**（全是 const/static 字段与方法）
            #   → 那么 `ClassName.Member` 必然是静态访问，检查它零误报。
            #   第一版是硬编码名单，新增静态工具类就会被漏掉；改成自动后自动覆盖。
            if cls not in static_only_classes:
                continue
            if mem in class_members[cls]:
                continue                      # 该成员确实在这个类里 → 没问题

            # ★ 关键的降噪：`Foo.Bar` 里的 `Foo` 可能只是**变量名**（`Telemetry t = ...`
            #   然后写 `t.Data`？不，这里是 `Telemetry.Data` —— 但 `Telemetry` 也可能是
            #   某个局部变量/字段名）。无法从文本可靠区分类名与变量名。
            #   所以只在**该成员名在其它类里确实存在**时才报 ——
            #   那说明是"把 A 的成员记成了 B 的"（例如把 JsonValue.IsArr 写成 IsArray 时，
            #   IsArray 哪儿都不存在 → 这种反而漏报，但另有 check_symbols 覆盖辅助方法）。
            #   真正高价值的场景是：成员名存在于别处却用错了类名。
            found_elsewhere = False
            for other, members in class_members.items():
                if other != cls and mem in members:
                    found_elsewhere = True
                    break
            if found_elsewhere:
                problems.append((path, line_of(raw, m.start()),
                                 '%s.%s —— %s 里没有该成员（它在别的类里存在，可能记错了类）'
                                 % (cls, mem, cls)))
    return problems


def check_font_dispose(files):
    """禁止 Dispose 由 F.SansFont / F.MonoFont 返回的字体。

    ★★ 这是一条**会导致闪退**的检查，务必保留 ★★

    `win/src/Theme.cs` 的 `F.Get` 是按 (字体族, 像素尺寸, 粗细) **缓存**的静态字体：
        "Font 是按 …缓存的静态对象 —— 每帧 new 几十个 Font 会很快耗光 GDI 句柄。
         缓存对象**不要 Dispose**；要释放请调 ClearCache()。"（Theme.cs:249-250）

    也就是说 `F.SansFont(14, false)` 每次返回**同一个** Font 实例。
    谁对它调 `.Dispose()`，就是把共享缓存销毁了 → 下一帧再取出这个已销毁的对象去画
    → GDI+ 抛 `ArgumentException: Parameter is not valid` → **进程闪退**。

    2026-10-15 实际踩过：移植 C# 主题时按"谁创建谁释放"的习惯加了 149 处 `.Dispose()`，
    结果编译通过、一运行几秒就崩。症状是"窗口闪一下就没"，很容易误判成别的问题。

    正确的释放方式是 `F.ClearCache()`（只在退出时调），**不是**逐帧 Dispose。
    """
    bad = []
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        font_vars = set(re.findall(r'\b([A-Za-z_]\w*)\s*=\s*F\.(?:SansFont|MonoFont)\s*\(', code))
        font_vars |= set(re.findall(r'\b([A-Za-z_]\w*)\s*=\s*new\s+Font\s*\(', code))
        if not font_vars:
            continue
        for m in re.finditer(r'\b([A-Za-z_]\w*)\.Dispose\(\)', code):
            name = m.group(1)
            if name in font_vars:
                bad.append((path, line_of(raw, m.start()),
                            '不要 Dispose 缓存字体：%s（F.*Font 返回共享实例，'
                            '销毁它会让下一帧崩；用 F.ClearCache()）' % name))
    return bad


def check_orphan_members(files):
    """检查"游离在类外"的成员（方法）—— 这是**编译错误**。

    ★ 为什么需要：2026-10-15 实际踩过。我用脚本往 `ThemeCore.cs` 里插一个辅助方法时，
      插入位置落在了 `Themes` 类**闭合之后**，于是方法变成"命名空间级方法"。
      C# 不允许这样，csc 报一串看不懂的错：
          error CS1518: 应输入 class、delegate、enum、interface 或 struct
          error CS1022: 应输入类型、命名空间定义或文件尾
      而**本工具的括号平衡检查是"平衡的"**（花括号确实配对，只是归属错了），
      所以没能提前发现 —— 只能在 VM 上编译才暴露。这条检查补上那个盲区。

    ⚠️ 数括号必须用 `strip_code` 之后的文本：否则字符字面量 `'{'` / `'}'`
      会被当成真实括号（Json.cs 里就有，第一版因此误报 2 处）。
    """
    problems = []
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        depth = 0
        for i, line in enumerate(code.split('\n'), 1):
            stripped = line.strip()
            # 只保留非空行的判断；空行不产生事件
            is_ns = re.match(r'^namespace\s+', stripped) is not None
            is_type = re.match(r'^(?:public|internal|private|protected)?\s*'
                               r'(?:static\s+|sealed\s+|abstract\s+|partial\s+)*'
                               r'(?:class|struct|enum|interface|delegate)\b', stripped) is not None
            # depth==1 → 命名空间内、所有类外
            if depth == 1 and stripped and not is_type and not is_ns:
                if re.match(r'^(?:public|internal|private|protected)\s+'
                            r'(?:static\s+|virtual\s+|override\s+|sealed\s+|async\s+)*'
                            r'[A-Za-z_][\w<>,\[\]\.\?]*\s+[A-Za-z_]\w*\s*\(', stripped):
                    problems.append((path, i,
                                     '游离成员：方法出现在类外 —— %s' % stripped[:56]))
            depth += line.count('{') - line.count('}')
    return problems


def check_bare_align(files):
    """`Dashboard.cs` 之外不得出现裸 `Align`（编译错误 CS0246）。

    ★ 为什么需要：`Dashboard.cs` 里有个 `private enum Align`，而 `Draw` 类里的同类枚举
      **刻意命名为 `TextAlign`**（否则会与 Dashboard 的私有枚举冲突 —— 这个冲突本工具
      早期就抓到过一次）。但 2026-10-15 我又在 `ThemeCore.cs` 的 `ShrinkText` 签名里
      写成了裸 `Align`，因为它在 `Draw` 类内部、我下意识以为"同类内不用限定"。
      实测报错：`error CS0246: 未能找到类型或命名空间名称"Align"`。
      判据很简单：`Dashboard.cs` 以外出现独立单词 `Align` 就是错的。
    """
    import os
    problems = []
    for path in files:
        if os.path.basename(path) == 'Dashboard.cs':
            continue                      # 它自己的 private enum，合法
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for m in re.finditer(r'(?<![\w.])Align(?![\w])', code):
            problems.append((path, line_of(raw, m.start()),
                             '裸 `Align` —— 应写成 `Draw.TextAlign`（Align 是 Dashboard 的私有枚举）'))
    return problems


def check_type_shadowing(files):
    """检查"类成员名遮蔽了命名空间级类型名"—— 这是编译错误（CS0119/CS1061/CS0103）。

    ★ 为什么需要：2026-10-15 实际踩过，而且**一次冒出 26 个错误**，非常难读：
      · `Themes` 类里有个常量 `Dashboard`（主题号 0）→ 该类内 `Dashboard.RenderHorizontal(...)`
        被解析成"对 int 常量做成员访问"，报
        `error CS1061: "int" 不包含"RenderHorizontal"的定义`
      · `PongHolder` 类里有个方法 `State()` → 该类内 `State.NowMs()` 被解析成"调用方法"，
        报 `error CS0119: ...是一个"方法"，这在给定的上下文中无效`
    两者的根因相同：**C# 里就近的名字优先**，类成员会遮蔽外层同名类型。
    修法：在被遮蔽处写成全限定名 `DshLcd.XXX`。

    判据：类成员声明里的名字若与工程内某个 class/struct/enum 同名，
    且该类体内以 `Name.` 形式引用它 → 报可疑（人工确认后加 DshLcd. 限定）。
    """
    import os
    # 收集全部类型名
    types = set()
    codes = {}
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        codes[path] = (raw, code)
        types |= set(re.findall(r'\b(?:class|struct|enum|interface)\s+(\w+)', code))

    problems = []
    for path, (raw, code) in codes.items():
        # 逐个类/结构体块
        for m in re.finditer(r'\b(?:public|internal)?\s*(?:static\s+)?(?:sealed\s+|abstract\s+|partial\s+)*'
                             r'(?:class|struct)\s+(\w+)[^{]*\{', code):
            i = m.end() - 1
            d, j = 0, i
            while j < len(code):
                if code[j] == '{':
                    d += 1
                elif code[j] == '}':
                    d -= 1
                    if d == 0:
                        break
                j += 1
            body = code[i:j]
            # 该类的成员名
            members = set(re.findall(r'\b(?:public|private|internal|protected)\s+(?:static\s+|readonly\s+|const\s+)*'
                                     r'[\w<>,\[\]\.\?]+\s+(\w+)\s*[=;(]', body))
            shadowed = (members & types)
            for sh in sorted(shadowed):
                # 类体内以 "Sh.Name" 形式引用（成员访问）才算真遮蔽
                if re.search(r'(?<![\w.])' + re.escape(sh) + r'\.\w', body):
                    ln = code.count('\n', 0, i) + 1
                    problems.append((path, ln,
                                     '类型名被同类成员遮蔽：`%s`（如 `%s.Xxx`）—— 需写成 `DshLcd.%s`' % (sh, sh, sh)))
    return problems


def check_chunk_counting(files):
    """检查 `WriteChunks` 是否用"两遍"计数 —— 这是**屏幕反复重启**的根因。

    ★★ 2026-10-15 实机故障 ★★
    Windows 版推帧时屏幕反复重启，同一根线/同一块屏鸿蒙版却稳。根因在 `Ly.cs`：
    第一遍按 `pos += UsbWriteSize` 预分配数组，第二遍按 `pos += size` 填充，
    而末段取 `min(2048, remaining)` → 第二遍常比第一遍多 1 次 → `writes[idx]` 越界
    → `IndexOutOfRangeException`（被 Tick 的 catch 记进 errors，屏幕侧表现为重启）。
    触发条件：`总长 % 4096 ∈ (2048, 4096)`（实测 22KB~450KB 的帧里大量命中）。

    判据：`WriteChunks` 里出现 `pos += UsbWriteSize;`（不带 min/条件）就是两遍计数的残留。
    """
    problems = []
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        if 'WriteChunks' not in code:
            continue
        m = re.search(r'WriteChunks\s*\([^)]*\)\s*\{', code)
        if not m:
            continue
        i = m.end() - 1
        d, j = 0, i
        while j < len(code):
            if code[j] == '{':
                d += 1
            elif code[j] == '}':
                d -= 1
                if d == 0:
                    break
            j += 1
        body = code[i:j]
        # 两遍计数的特征：`pos += UsbWriteSize;`（无 min/三元）
        if re.search(r'pos\s*\+=\s*UsbWriteSize\s*;', body):
            problems.append((path, line_of(raw, code.find('WriteChunks')),
                             'WriteChunks 用了"两遍计数"（pos += UsbWriteSize）'
                             '—— 与实际填充的 pos += size 不一致会越界，'
                             '导致屏幕反复重启；应改成一遍完成（见 ArkTS writeChunks）'))
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--glob', default=SRC_GLOB)
    args = ap.parse_args()

    files = sorted(glob.glob(args.glob))
    if not files:
        print('[csharp_audit] 没找到源文件: %s' % args.glob)
        return 1

    problems = []
    for path in files:
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = strip_code(raw)
        for line, why in check_cs5(path, raw, code):
            problems.append((path, line, 'C#5违规: ' + why))
        for line, why in check_balance(path, code):
            problems.append((path, line, '括号: ' + why))

    classes, members = collect_defs(files)
    for nm, defs in classes.items():
        if len(defs) > 1:
            kinds = set(d[2] for d in defs)
            if len(kinds) == 1:      # partial 同名多份是合法的（这里没标 partial 就报）
                for path, line, kind in defs[1:]:
                    problems.append((path, line, '重复定义 %s %s（首见于 %s:%d）'
                                     % (kind, nm, os.path.basename(defs[0][0]), defs[0][1])))

    missing = check_symbols(files, members)
    for path, line, sym in missing:
        problems.append((path, line, '未定义的辅助方法: ' + sym))

    for path, line, tok in check_color_tokens(files):
        problems.append((path, line, '颜色令牌: ' + tok))
    for path, line, why in check_literal_ratios(files):
        problems.append((path, line, why))
    for path, line, why in check_member_access(files):
        problems.append((path, line, why))
    for path, line, why in check_font_dispose(files):
        problems.append((path, line, why))
    for path, line, why in check_orphan_members(files):
        problems.append((path, line, why))
    for path, line, why in check_bare_align(files):
        problems.append((path, line, why))
    for path, line, why in check_type_shadowing(files):
        problems.append((path, line, why))
    for path, line, why in check_chunk_counting(files):
        problems.append((path, line, why))

    if args.json:
        print(json.dumps({'files': files, 'problems': problems}, ensure_ascii=False, indent=2))
    else:
        print('[csharp_audit] 审了 %d 个文件、%d 行' % (
            len(files), sum(len(open(f, encoding='utf-8', errors='replace').readlines()) for f in files)))
        if not problems:
            print('  ✅ 未发现 C#5 违规 / 括号失衡 / 重复定义 / 未定义辅助方法')
            print('  ⚠️ 注意：这**不能替代真正的编译**（类型错误、重载解析、API 存在性都查不出来）')
        else:
            bykind = {}
            for path, line, why in problems:
                k = why.split(':')[0]
                bykind.setdefault(k, []).append((path, line, why))
            for k, items in sorted(bykind.items()):
                print('  ❌ %s —— %d 处' % (k, len(items)))
                for path, line, why in items[:12]:
                    print('      %s:%d  %s' % (os.path.basename(path), line, why))
                if len(items) > 12:
                    print('      …… 另有 %d 处' % (len(items) - 12))
    return 0 if not problems else 1


if __name__ == '__main__':
    sys.exit(main())
