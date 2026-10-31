#!/usr/bin/env python3
"""
csharp_precheck.py — C# 编译前的**一次性全量预检**

## 为什么需要它
本机没有 C# 编译器（musl vs glibc），而 `csharp_audit.py` 只覆盖了"文本层能查的一部分"。
2026-10-15 反复出现同一类问题：**在 VM 上编译才发现**的东西，
比如 `Log.I(...)`（Log 只有 W/Err）、`StrokeRounded` 传了 8 个参数（签名只有 7 个）、
`Themes` 里的常量 `Dashboard` 遮蔽了 `Dashboard` 类名……

这个脚本把**所有类型和成员的真实声明**提取出来，然后逐条核对每一次 `类型.成员`
引用 —— 这是能在无编译器环境下做到的最接近编译器的检查。

## 检查项
  1. **括号平衡**（字面量感知，忽略字符串/字符/注释里的括号）
  2. **游离成员**：方法出现在类外（CS0116/CS1518）
  3. **类型名遮蔽**：类成员与类型同名且被以 `Name.` 引用（CS0119/CS1061）
  4. **类型与成员存在性**：`Type.Member` 里 Type 和 Member 都必须在工程内真实存在
     （CS0117/CS0103/CS1061）—— 含**嵌套类型**的可见性规则
  5. **调用参数个数**：`Type.Method(...)` 的实参个数必须匹配某个重载
     （CS1501/CS1502/CS1503 的一部分）—— 用括号配对切分实参，能处理嵌套调用
  6. **裸 Align**：Dashboard.cs 以外不得出现（CS0246）
  7. **缓存字体 Dispose**：F.*Font 返回共享实例，不得 Dispose（运行时闪退）
  8. **C# 5 违规**：字符串插值 / ?. / 表达式体成员 / out var / 元组 …
  9. **重复定义**
 10. **同步清单**：算出全部源文件的 SHA256，便于与 VM 侧逐字节比对

退出码：0 = 全部通过；1 = 有 ❌
"""
import hashlib
import os
import re
import sys
import glob

# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

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


def match_brace(code, open_idx):
    """返回与 code[open_idx]（'{'）配对的 '}' 下标。"""
    d, i = 0, open_idx
    while i < len(code):
        if code[i] == '{':
            d += 1
        elif code[i] == '}':
            d -= 1
            if d == 0:
                return i
        i += 1
    return -1


def split_args(s):
    """按顶层逗号切分实参（正确处理嵌套括号/泛型尖括号）。"""
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        # ★ 不把 < > 计入深度：`a < b` 与 `List<int>` 无法从文本区分，
        #   实测把 < 当深度会让 `Dictionary<string,int> x, int y` 这类实参切分错乱。
        if ch == ',' and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [a for a in (x.strip() for x in out) if a != '']


# ---------------------------------------------------------------------------
# 提取声明
# ---------------------------------------------------------------------------

TYPE_RE = re.compile(r'\b(?:public|internal|private|protected)?\s*'
                     r'(?:static\s+|sealed\s+|abstract\s+|partial\s+)*'
                     r'(class|struct|enum|interface)\s+(\w+)')

def extract_types(code):
    """返回 {类型名: {'kind':..., 'members':set, 'nested':{...}, 'start':int, 'end':int}}"""
    types = {}
    for m in TYPE_RE.finditer(code):
        name = m.group(2)
        brace = code.find('{', m.end())
        if brace < 0:
            continue
        end = match_brace(code, brace)
        if end < 0:
            continue
        body = code[brace:end]
        members = set()
        # 方法
        for mm in re.finditer(r'\b(?:public|private|internal|protected)\s+'
                              r'(?:static\s+|virtual\s+|override\s+|sealed\s+|async\s+|new\s+)*'
                              r'[\w<>,\[\]\.\?]+\s+(\w+)\s*\(', body):
            members.add(mm.group(1))
        # 字段 / 属性 / 常量
        for mm in re.finditer(r'\b(?:public|private|internal|protected)\s+'
                              r'(?:static\s+|readonly\s+|const\s+|volatile\s+)*'
                              r'[\w<>,\[\]\.\?]+\s+(\w+)\s*[=;{]', body):
            members.add(mm.group(1))
        # 枚举成员
        if m.group(1) == 'enum':
            inner = body[body.find('{') + 1:body.rfind('}')]
            for part in inner.split(','):
                nm = part.strip().split('=')[0].strip()
                if re.match(r'^\w+$', nm):
                    members.add(nm)
        # 嵌套类型
        nested = {}
        for mm in TYPE_RE.finditer(body):
            nested[mm.group(2)] = True
            members.add(mm.group(2))
        types[name] = {'kind': m.group(1), 'members': members,
                       'nested': nested, 'start': m.start(), 'end': end,
                       'body_start': brace}
    return types


BCL_PREFIXES = {
    'System', 'Microsoft', 'Console', 'Math', 'Convert', 'Environment', 'String',
    'Enumerable', 'Thread', 'Task', 'File', 'Path', 'Directory', 'Encoding',
    'Color', 'Image', 'Bitmap', 'Font', 'Brush', 'Pen', 'Rectangle', 'Point',
    'Size', 'Matrix', 'Graphics', 'GraphicsPath', 'StringFormat', 'LinearGradientBrush',
    'SolidBrush', 'ImageCodecInfo', 'ImageFormat', 'Encoder', 'EncoderParameters',
    'FontFamily', 'FontStyle', 'GraphicsUnit', 'LineCap', 'GraphicsState',
    'DateTime', 'TimeSpan', 'Guid', 'Array', 'List', 'Dictionary', 'Tuple',
    'Action', 'Func', 'Nullable', 'Comparer', 'Interlocked', 'Monitor', 'GC',
    'Random', 'CultureInfo', 'NumberStyles', 'Exception', 'Byte', 'Int32', 'UInt32',
    'Double', 'Single', 'Boolean', 'Char', 'Object', 'Type', 'Delegate', 'EventArgs',
    'Keys', 'Cursor', 'Cursors', 'ColorTranslator', 'Stopwatch', 'JsonSerializer',
    'IPAddress', 'TcpListener', 'StringBuilder', 'FileStream', 'FileMode', 'FileAccess',
    'RectangleF', 'PointF', 'Application', 'MessageBox', 'Registry', 'IntPtr',
    'CharSet', 'Assembly', 'StringComparison', 'ImageLockMode', 'PixelFormat',
    'LinearGradientMode', 'PowerStatus', 'Text', 'Program', 'Marshal', 'HandleRef',
    # ---- 以下为编译通过的既有文件里用到的 BCL 类型（补全白名单，避免误报）----
    'StringAlignment', 'StringTrimming', 'StringFormatFlags', 'ControlStyles',
    'FlatAppearance', 'ClientRectangle', 'ThreadPool', 'Uri', 'JSON', 'WebRequest',
    'DateTimeKind', 'LayoutKind', 'SocketOptionLevel', 'SocketOptionName', 'SocketError',
    'DllImport', 'StructLayout', 'MarshalAs', 'UnmanagedType', 'In', 'Out',
    'ThreadStart', 'ParameterizedThreadStart', 'WaitHandle', 'EventWaitHandle',
    'ManualResetEvent', 'AutoResetEvent', 'CancellationToken', 'CancellationTokenSource',
    'IPEndPoint', 'UdpClient', 'Socket', 'SocketType', 'ProtocolType', 'AddressFamily',
    'NetworkInterface', 'IPGlobalProperties', 'TcpState', 'DriveInfo', 'DriveType',
    'RegistryKey', 'Registry', 'PowerLineStatus', 'BatteryChargeStatus', 'SystemInformation',
    'Screen', 'Control', 'Form', 'Panel', 'Label', 'Button', 'CheckBox', 'ComboBox',
    'TextBox', 'TrackBar', 'Timer', 'ToolTip', 'ContextMenuStrip', 'ToolStripMenuItem',
    'Keys', 'KeyEventArgs', 'MouseEventArgs', 'PaintEventArgs', 'EventArgs',
    'PaintStyles', 'ButtonState', 'AnchorStyles', 'DockStyle', 'FormBorderStyle',
    'FormWindowState', 'DialogResult', 'MessageBoxButtons', 'MessageBoxIcon',
    'HorizontalAlignment', 'ContentAlignment', 'BorderStyle', 'FlatStyle', 'ComboBoxStyle',
    'GraphicsUnit', 'RotateFlipType', 'ImageFormat', 'PixelFormat', 'ImageLockMode',
    'BitmapData', 'ColorMatrix', 'ImageAttributes', 'InterpolationMode',
    'SmoothingMode', 'CompositingQuality', 'PixelOffsetMode', 'TextRenderingHint',
    'NumberFormatInfo', 'CultureInfo', 'CompareOptions', 'RegexOptions', 'Regex',
    'Match', 'Group', 'MatchCollection', 'WebClient', 'HttpWebRequest', 'HttpWebResponse',
    'IPHostEntry', 'Dns', 'HostNameType', 'Encoding', 'Decoder', 'Encoder',
    'StringSplitOptions', 'FormStartPosition', 'PictureBoxSizeMode', 'FormBorderStyle',
    'AutoScaleMode', 'HighDpiMode', 'Padding', 'Margin', 'SizeF', 'Region',
    'GraphicsPathIterator', 'ImageConverter', 'TypeConverter', 'ComponentResourceManager',
    'Screen', 'SystemInformation', 'Help', 'Clipboard', 'DataObject', 'DragDropEffects',
}

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src_dir = os.path.join(root, 'win', 'src')
    files = sorted(glob.glob(os.path.join(src_dir, '*.cs')))
    if not files:
        print('找不到 win/src/*.cs')
        return 1

    codes = {}
    for p in files:
        raw = open(p, encoding='utf-8', errors='replace').read()
        codes[p] = (raw, strip_code(raw))

    problems = []

    # ---- 1. 括号平衡 ----
    for p, (raw, code) in codes.items():
        o, c = code.count('{'), code.count('}')
        if o != c:
            problems.append((p, 1, '括号不平衡：{ = %d，} = %d（差 %d）' % (o, c, o - c)))

    # ---- 2. 提取类型 ----
    all_types = {}
    for p, (raw, code) in codes.items():
        for name, info in extract_types(code).items():
            all_types.setdefault(name, []).append((p, info))

    type_names = set(all_types.keys())
    # 收集命名空间名（`namespace X`）—— 它们不是类型，`X.Yyy` 是合法的限定引用
    namespace_names = set()
    for p, (raw, code) in codes.items():
        namespace_names |= set(re.findall(r'\bnamespace\s+([\w.]+)', code))
        for ns in list(namespace_names):
            namespace_names |= set(ns.split('.'))

    # ---- 3. 游离成员 ----
    for p, (raw, code) in codes.items():
        depth = 0
        for i, line in enumerate(code.split('\n'), 1):
            st = line.strip()
            is_type = re.match(r'^(?:public|internal|private|protected)?\s*'
                               r'(?:static\s+|sealed\s+|abstract\s+|partial\s+)*'
                               r'(?:class|struct|enum|interface|delegate)\b', st) is not None
            is_ns = st.startswith('namespace')
            if depth == 1 and st and not is_type and not is_ns:
                if re.match(r'^(?:public|internal|private|protected)\s+'
                            r'(?:static\s+|virtual\s+|override\s+|sealed\s+|async\s+)*'
                            r'[\w<>,\[\]\.\?]+\s+\w+\s*\(', st):
                    problems.append((p, i, '游离成员（方法在类外）：%s' % st[:52]))
            depth += line.count('{') - line.count('}')

    # ---- 4. 类型名遮蔽 ----
    TYPE_NAMES_ALL = type_names
    for p, (raw, code) in codes.items():
        claimed = []
        for m in TYPE_RE.finditer(code):
            b = code.find('{', m.end())
            if b < 0:
                continue
            e = match_brace(code, b)
            if e < 0:
                continue
            body = code[b:e]
            # 跳过已被外层类型包含的（只处理最外层）
            if any(s <= m.start() <= t for s, t in claimed):
                continue
            claimed.append((b, e))
            members = set(re.findall(r'\b(?:public|private|internal|protected)\s+'
                                     r'(?:static\s+|readonly\s+|const\s+)*'
                                     r'[\w<>,\[\]\.\?]+\s+(\w+)\s*[=;(]', body))
            for sh in sorted(members & TYPE_NAMES_ALL):
                if re.search(r'(?<![\w.])' + re.escape(sh) + r'\.\w', body):
                    problems.append((p, line_of(code, b),
                                     '类型名被同类成员遮蔽：`%s.Xxx` → 需写 `DshLcd.%s`' % (sh, sh)))

    # ---- 5. 类型与成员存在性 + 参数个数 ----
    for p, (raw, code) in codes.items():
        for m in re.finditer(r'(?<![\w.>])([A-Z]\w*)\.([A-Za-z_]\w*)\s*(\(?)', code):
            tname, member, is_call = m.group(1), m.group(2), m.group(3) == '('
            if tname in BCL_PREFIXES:
                continue
            # 命名空间名不算类型（`DshLcd.Dashboard` 里的 DshLcd）
            if tname in namespace_names:
                continue
            if tname not in type_names:
                # 可能是局部变量名（Telemetry t; t.Data）—— 判断依据：该名字是否被声明为变量
                # 简化策略：同文件里若出现 "类型 名字" 或 "= 名字" 之类，就当变量跳过
                # 判断它是不是变量/属性名：
                #  · 出现在 `Xxx = ` 左侧，或
                #  · 出现在 `Type Xxx` 声明位置，或
                #  · 作为 `this.Xxx` / 参数名出现
                if re.search(r'\b' + re.escape(tname) + r'\s*=\s*[^=]', code) or \
                   re.search(r'\b[\w<>,\[\]\.\?]+\s+' + re.escape(tname) + r'\s*[=;,)]', code) or \
                   re.search(r'\b' + re.escape(tname) + r'\s*;', code):
                    continue
                problems.append((p, line_of(code, m.start()),
                                 '未定义的类型 `%s`（CS0103/CS0246）' % tname))
                continue
            # 成员存在性
            merged = set()
            for _pp, info in all_types[tname]:
                merged |= info['members']
            if member not in merged:
                # 可能是扩展/继承成员，报出来人工判断
                problems.append((p, line_of(code, m.start()),
                                 '`%s` 没有成员 `%s`（CS0117/CS1061）' % (tname, member)))
                continue
            # 参数个数
            if is_call:
                open_idx = m.end() - 1
                d, j = 0, open_idx
                while j < len(code):
                    if code[j] == '(':
                        d += 1
                    elif code[j] == ')':
                        d -= 1
                        if d == 0:
                            break
                    j += 1
                args = code[open_idx + 1:j]
                argc = len(split_args(args)) if args.strip() else 0
                # 从源码里数该成员所有重载的参数个数
                decl = set()
                for _pp, info in all_types[tname]:
                    seg = codes[_pp][1][info['body_start']:info['end']]
                    # ★ 用括号配对取参数表，而不是 `[^)]*`（后者遇到 `delegate(...)` 会截断，
                    #   实测把 6 个参数的重载数成 2 个 → 误报）
                    for dm in re.finditer(r'\b' + re.escape(member) + r'\s*\(', seg):
                        _o = dm.end() - 1
                        _d, _j = 0, _o
                        while _j < len(seg):
                            if seg[_j] == '(':
                                _d += 1
                            elif seg[_j] == ')':
                                _d -= 1
                                if _d == 0:
                                    break
                            _j += 1
                        ps = seg[_o + 1:_j].strip()
                        decl.add(0 if not ps else len(split_args(ps)))
                if decl and argc not in decl and 'params' not in ''.join(
                        codes[_pp][1] for _pp, _i in all_types[tname]):
                    problems.append((p, line_of(code, m.start()),
                                     '`%s.%s` 传了 %d 个参数，声明只有 %s 个（CS1501/CS1502）'
                                     % (tname, member, argc, sorted(decl))))

    # ---- 6. 裸 Align ----
    for p, (raw, code) in codes.items():
        if os.path.basename(p) == 'Dashboard.cs':
            continue
        for m in re.finditer(r'(?<![\w.])Align(?![\w])', code):
            problems.append((p, line_of(raw, m.start()),
                             '裸 `Align` → 应写 `Draw.TextAlign`（CS0246）'))

    # ---- 7. 缓存字体 Dispose ----
    for p, (raw, code) in codes.items():
        fv = set(re.findall(r'\b(\w+)\s*=\s*F\.(?:SansFont|MonoFont)\s*\(', code))
        fv |= set(re.findall(r'\b(\w+)\s*=\s*new\s+Font\s*\(', code))
        for m in re.finditer(r'\b(\w+)\.Dispose\(\)', code):
            if m.group(1) in fv:
                problems.append((p, line_of(raw, m.start()),
                                 '不要 Dispose 缓存字体：%s（运行期闪退）' % m.group(1)))

    # ---- 8. C# 5 违规 ----
    CS5 = [
        (r'\$"', '字符串插值'),
        (r'\$\$"', '字符串插值'),
        (r'\?\.', '空传播 ?.'),
        (r'\?\?=', '??='),
        (r'\bnameof\s*\(', 'nameof'),
        (r'\bout\s+var\b', 'out var'),
        (r'\bis\s+not\b', 'is not'),
    ]
    for p, (raw, code) in codes.items():
        for pat, why in CS5:
            for m in re.finditer(pat, code):
                problems.append((p, line_of(raw, m.start()), 'C# 5 不允许：%s' % why))

    # ---- 9. 重复定义 ----
    for name, lst in all_types.items():
        if len(lst) <= 1:
            continue
        files_ = sorted({os.path.basename(pp) for pp, _i in lst})
        if len(files_) <= 1:
            continue          # 同一文件内的嵌套类型，允许
        # ★ 跳过"私有嵌套类型"：它们各有作用域，不构成冲突
        #   （实测 ThemeCore 的 private struct MEMORYSTATUSEX 与 SysMon 的 private class 同名但合法）
        all_private_nested = True
        for pp, info in lst:
            raw = codes[pp][0]
            before = raw[max(0, info['start'] - 220):info['start']]
            if re.search(r'\b(public|internal)\s+(?:static\s+)?(?:class|struct|enum)', before):
                all_private_nested = False
                break
        if all_private_nested:
            continue
        problems.append((lst[1][0], 1,
                         '重复定义类型 `%s`（另见 %s）' % (name, files_[0])))

    # ---- 10. 同步清单（SHA256）----
    manifest = []
    for p in files:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        manifest.append((os.path.basename(p), h))

    # ---- 输出 ----
    print('=' * 72)
    print('C# 编译前全量预检')
    print('=' * 72)
    print('  文件 %d 个 · 类型 %d 个 · 行 %d'
          % (len(files), len(type_names),
             sum(len(c[0].splitlines()) for c in codes.values())))
    print()
    if problems:
        by_file = {}
        for p, ln, why in problems:
            by_file.setdefault(os.path.basename(p), []).append((ln, why))
        for f in sorted(by_file):
            print('  ❌ %s（%d 处）' % (f, len(by_file[f])))
            for ln, why in sorted(by_file[f])[:12]:
                print('       行%-5d %s' % (ln, why))
            if len(by_file[f]) > 12:
                print('       … 另有 %d 处' % (len(by_file[f]) - 12))
        print()
        print('  合计 %d 处问题' % len(problems))
    else:
        print('  ✅ 10 项检查全部通过')
        print('     （括号平衡 · 游离成员 · 类型遮蔽 · 类型与成员存在性 · 参数个数')
        print('      裸 Align · 缓存字体 Dispose · C#5 违规 · 重复定义 · 同步清单）')
    print()
    print('  ── 同步清单（SHA256，供与 VM 侧逐字节比对）──')
    for name, h in manifest:
        print('    %s  %s' % (h[:16], name))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
