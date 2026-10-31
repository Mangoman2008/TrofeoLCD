#!/usr/bin/env python3
"""
给定一组 .cs 文件，算出编译所需的**传递闭包**（自动补齐被引用的同工程类型所在文件）。

为什么需要：2026-10-15 的手工文件列表漏了 State.cs，导致
`error CS0246: 未能找到类型或命名空间名称"PrinterInfo"` —— 白跑一轮编译。
手工维护列表必然会漏，所以改成算出来。

用法：
    python3 tools/csharp_closure.py win/src/MqttClient.cs win/tools/bambu-selftest.cs ...
"""
import re, sys, os, glob

def strip_code(t):
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if c == '/' and i+1 < n and t[i+1] == '/':
            while i < n and t[i] != '\n': i += 1
            continue
        if c == '/' and i+1 < n and t[i+1] == '*':
            i += 2
            while i+1 < n and not (t[i] == '*' and t[i+1] == '/'):
                if t[i] == '\n': out.append('\n')
                i += 1
            i += 2; continue
        if c == '@' and i+1 < n and t[i+1] == '"':
            i += 2
            while i < n:
                if t[i] == '"':
                    if i+1 < n and t[i+1] == '"': i += 2; continue
                    i += 1; break
                if t[i] == '\n': out.append('\n')
                i += 1
            out.append('""'); continue
        if c == '"':
            i += 1
            while i < n:
                if t[i] == '\\': i += 2; continue
                if t[i] == '"': i += 1; break
                if t[i] == '\n': out.append('\n')
                i += 1
            out.append('""'); continue
        if c == "'":
            i += 1
            while i < n:
                if t[i] == '\\': i += 2; continue
                if t[i] == "'": i += 1; break
                i += 1
            out.append("'x'"); continue
        out.append(c); i += 1
    return ''.join(out)

ALL = sorted(glob.glob('win/src/*.cs'))
# 类型 → 定义文件
owner = {}
for p in ALL:
    s = strip_code(open(p, encoding='utf-8').read())
    for m in re.finditer(r'\b(?:public|internal)\s+(?:sealed\s+|static\s+|abstract\s+)?(?:class|struct|enum|interface)\s+(\w+)', s):
        owner[m.group(1)] = p

# BCL / 语言关键字（不参与闭包）
BCL = set("""Array Math DateTime DateTimeKind TimeSpan Guid Environment Console Convert
String Int32 Int64 Double Boolean Object Exception ArgumentException InvalidOperationException
NotSupportedException FormatException IDisposable IComparable Nullable
List Dictionary StringBuilder Encoding UTF8Encoding CultureInfo NumberStyles
Thread ThreadStart Mutex Timer Stopwatch Interlocked Monitor
Color Font FontFamily FontStyle Graphics Bitmap Brush SolidBrush Pen Rectangle RectangleF
Point PointF Size SizeF GraphicsPath Matrix Region GraphicsUnit Image ImageFormat
StringFormat StringAlignment PenLineCap PenLineJoin LineCap DashStyle
Form Control Label Button TextBox ComboBox Panel Timer MessageBox MessageBoxButtons
MessageBoxIcon Application DialogResult Keys Cursor Cursors Padding SizeType
TcpClient SslStream NetworkStream IPAddress IPEndPoint Socket UdpClient
HttpWebRequest HttpWebResponse WebRequest Stream StreamReader StreamWriter MemoryStream
File Directory Path FileInfo Encoding ServicePointManager SecurityProtocolType
DecompressionMethods HttpStatusCode WebException Uri
X509Certificate X509CertificateCollection X509Chain SslPolicyErrors
RemoteCertificateValidationCallback SslProtocols AuthenticationException
Action Func EventHandler EventArgs
Task ValueTask CancellationToken
JsonValue Log SelfTest""".split())

seed = sys.argv[1:]
if not seed:
    print('用法: csharp_closure.py <起始文件...>'); sys.exit(2)
seed = [os.path.normpath(x) for x in seed]

need = set(seed)
changed = True
while changed:
    changed = False
    have = set()
    for p in list(need):
        if os.path.exists(p):
            have.add(p)
    # 已包含文件里定义的类型
    defined = set()
    for p in have:
        s = strip_code(open(p, encoding='utf-8').read())
        defined |= set(re.findall(r'\b(?:class|struct|enum|interface)\s+(\w+)', s))
    # 扫描这些文件里出现的所有标识符，若属于"别的文件定义的类型"就补上
    for p in list(have):
        s = strip_code(open(p, encoding='utf-8').read())
        for t, f in owner.items():
            if f in have: continue
            # ★ 收紧：必须出现在**类型上下文**里才算引用，否则字段/成员名会误判。
            #   2026-10-15 教训：State.cs 有个字段叫 `Color`，裸匹配会把 Theme.cs
            #   （定义了 C.Color）拉进闭包，而 Theme.cs 又依赖 Dashboard/Gui（WinForms），
            #   于是自检根本编不过 —— 典型的"工具太激进反而害人"。
            pats = [
                r'\bnew\s+' + re.escape(t) + r'\b',                   # new T(
                r'\b' + re.escape(t) + r'\s+\w+\s*[;=,)]',          # T x;  / T x = / T x,
                r'\b' + re.escape(t) + r'\s*\.',                     # T.Static()
                r'\b' + re.escape(t) + r'\[',                         # T[]
                r'\b(?:public|private|protected|internal)\s+' + re.escape(t) + r'\b',  # 可见性 T
                r'\b(?:out|ref|params)\s+' + re.escape(t) + r'\b',   # out T
                r'\bis\s+' + re.escape(t) + r'\b',
                r'\bas\s+' + re.escape(t) + r'\b',
                r'\(\s*' + re.escape(t) + r'\s*\)',                  # 强制转换 (T)
                r'<\s*' + re.escape(t) + r'\s*[,>]',                  # 泛型实参 List<T>
                r':' + re.escape(t) + r'\b',                            # 继承/实现
            ]
            if any(re.search(pt, s) for pt in pats):
                need.add(os.path.normpath(f)); changed = True

final = sorted(need)
print(f'  闭包共 {len(final)} 个文件:')
for f in final:
    print(f'    {f}')
print()
print('  build 脚本用（csc 参数片段）:')
for f in final:
    if f.startswith('win/src/'):
        print(f'  "%SRC%\\{os.path.basename(f)}" ^')
    else:
        print(f'  "%HERE%\\{f.replace("win/", "").replace("/", chr(92))}" ^')
