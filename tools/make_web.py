#!/usr/bin/env python3
"""make_web.py — 把 web/preview.html 注入到两个宿主（鸿蒙 / Windows），保证网页预览页永远一致。

为什么要有这个脚本：网页预览页在两个地方各有一份实现——
  · 鸿蒙：entry/src/main/ets/bridge/FrameServer.ets  （ArkTS 模板字符串）
  · Windows：win/src/MiniHttp.cs                     （C# 逐行 StringBuilder）
两份手抄的结果就是实测过的走样：鸿蒙那份停在 1920×480 + 旧蓝色调色板，Windows 那份结构完全不同
（还把竖屏当成图片旋转 90° 再转一次）。改成"一份模板 + 生成注入"就没有第二次走样的机会。

用法：
  python3 tools/make_web.py           # 注入（重写两个宿主文件里的标记区间）
  python3 tools/make_web.py --check   # 只校验两边与模板是否一致（验证脚本 / 提交前用）

模板约束（脚本会强制检查）：不能出现反引号、${、反斜杠——
反引号与 ${ 会破坏 ArkTS 模板字符串，反斜杠会破坏 C# verbatim 字符串。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TPL = os.path.join(ROOT, 'web/preview.html')

BEG = '>>> WEB-PREVIEW (由 tools/make_web.py 从 web/preview.html 生成，勿手改) >>>'
END = '<<< WEB-PREVIEW <<<'

# (宿主文件, 声明行锚点, 声明行结束标记, 缩进)
# 锚点与结束标记**不含**字面量定界符（反引号 / @" " ）——定界符由 literal() 统一加。
# 踩过的坑：把定界符写进锚点会生成 `= ``<html>...``;` 这种双反引号，两个宿主都被写坏。
HOSTS = [
    ('entry/src/main/ets/bridge/FrameServer.ets',
     'private readonly previewHtmlText: string = ', ';', '  '),
    ('win/src/MiniHttp.cs',
     'private const string PreviewHtml = ', ';', '        '),
]


def read(p):
    with io.open(p, encoding='utf-8') as f:
        return f.read()


def write(p, s):
    with io.open(p, 'w', encoding='utf-8') as f:
        f.write(s)


def load_template():
    tpl = read(TPL)
    bad = [c for c in ['`', '${', '\\'] if c in tpl]
    if bad:
        print('❌ 模板里出现不能出现的字符（会破坏宿主字符串）：' + ', '.join(repr(c) for c in bad))
        sys.exit(2)
    if not tpl.endswith('\n'):
        tpl += '\n'
    return tpl


def literal(tpl, host):
    """把模板转成宿主语言里的字符串字面量"""
    if host.endswith('.ets'):
        return '`' + tpl + '`'          # ArkTS 模板字符串（模板已保证无反引号/${）
    return '@"' + tpl.replace('"', '""') + '"'   # C# verbatim 字符串


def want_region(tpl, host, anchor, term, indent):
    """标记区间应当长这样：标记行 + 声明行 + 结束标记行"""
    return (indent + '// ' + BEG + '\n'
            + indent + anchor + literal(tpl, host) + term + '\n'
            + indent + '// ' + END + '\n')


def find_region(src):
    """现有标记区间的 [i, j)；没有则 None"""
    i = src.find(BEG)
    if i < 0:
        return None
    i = src.rfind('\n', 0, i) + 1
    j = src.find(END)
    if j < 0:
        return None
    j = src.find('\n', j) + 1
    return (i, j)


def strip_old(src, anchor, term):
    """摘掉旧区间（或没有标记时的裸声明行），返回 (src, 插入位置) """
    span = find_region(src)
    if span is not None:
        return (src[:span[0]] + src[span[1]:], span[0])
    k = src.find(anchor)
    if k < 0:
        return (None, -1)
    e = src.find(term, k)
    if e < 0:
        return (None, -1)
    e = src.find('\n', e + len(term)) + 1
    return (src[:k] + src[e:], k)


def main():
    check = '--check' in sys.argv
    tpl = load_template()
    ok = True
    for rel, anchor, term, indent in HOSTS:
        path = os.path.join(ROOT, rel)
        src = read(path)
        want = want_region(tpl, rel, anchor, term, indent)
        span = find_region(src)
        cur = src[span[0]:span[1]] if span else None
        if check:
            same = (cur == want)
            print(('✅ ' if same else '❌ ') + rel + ': '
                  + ('与 web/preview.html 一致' if same
                     else '与模板不一致 —— 跑 python3 tools/make_web.py 重新注入'))
            ok = ok and same
            continue
        if cur == want:
            print('=  ' + rel + f': 已是最新（{len(tpl)} 字节）')
            continue
        stripped, pos = strip_old(src, anchor, term)
        if stripped is None:
            print(f'❌ {rel}: 既没有标记区间，也找不到锚点 {anchor!r}')
            ok = False
            continue
        write(path, stripped[:pos] + want + stripped[pos:])
        print('✍  ' + rel + f': 已注入（{len(tpl)} 字节）')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
