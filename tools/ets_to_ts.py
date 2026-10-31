#!/usr/bin/env python3
"""ets_to_ts.py —— 把 .ets 剥成 Node --experimental-strip-types 能跑的 .ts

给 tools/run_selftest.sh 用（2026-10-31 从 layout_check.py 的 prepare()/strip_enums
提炼而来）。做两件事：
  ① `export enum X { ... }` → `export const X = { ... } as const` 常量对象
     —— Node 的 strip-types 是 strip-only 模式，TS enum 需要代码生成，
     直接报 ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX（Node 26 无 --experimental-transform-types）。
     转换后成员访问语义等价（TileId.BRICK 照样可读）；枚举反查（TileId[3]）和
     Object.values 不可用 —— 本工程全库无此用法（2026-10-31 已核）。
     与 layout_check.py 版本的差异：先把枚举体里的注释删掉再解析成员 ——
     原实现按逗号切分后行注释会黏在下一个成员上，注释里一旦出现 '='
     就会把成员名切坏（现有枚举恰好没有，但别赌运气）。
  ② 相对导入补 .ts 扩展名（Node ESM 要求显式扩展名），与原 sed 等价。

只影响离线自检，不动真源码。
"""
import re
import sys

STRIP = re.compile(r"from '(\.\.?/[A-Za-z0-9_/]+)'")
ENUM_RE = re.compile(r'export\s+enum\s+(\w+)\s*\{(.*?)\}', re.S)
KIT_RE = re.compile(r"from '(@kit\.[A-Za-z0-9_.]+)'")

# ★ @kit 打桩表：真机 kit 在 Node 里不存在。这里只做**导入重定向** ——
#   `import { hilog } from '@kit.PerformanceAnalysisKit'` → `import { hilog } from '../kitstub/hilog.ts'`，
#   桩文件由调用方（run_selftest.sh 等）写到 $V/kitstub/ 下。
#   相对路径 `../` 对 $V 下所有模块成立（usb/common/service/render/mario 都是一层深）。
#   `import type { image } from '@kit.ImageKit'` 这类**纯类型导入**不重定向 ——
#   Node 的 strip 模式会把它整句擦除，模块名根本不会被解析。
#   没登记的 kit（值导入）直接报错退出 —— 宁可 prepare 阶段大声失败，
#   也不要等到 Node import 时抛晦涩的 ERR_INVALID_MODULE_SPECIFIER。
KIT_RE = re.compile(r"import\s+(type\s+)?(\{[^}]*\})\s*from\s+'(@kit\.[A-Za-z0-9_.]+)'")
KIT_STUBS = {
    '@kit.PerformanceAnalysisKit': 'hilog',
}


def rewrite_kits(text: str) -> str:
    def conv(m):
        if m.group(1):                      # import type —— 整句保留（Node 会擦掉）
            return m.group(0)
        kit = m.group(3)
        stub = KIT_STUBS.get(kit)
        if stub is None:
            raise SystemExit('ets_to_ts.py: 未登记的 kit 依赖 %s —— 先在 KIT_STUBS 加映射并在调用方生成桩' % kit)
        return "import %s from '../kitstub/%s.ts'" % (m.group(2), stub)
    return KIT_RE.sub(conv, text)


def strip_enums(text: str) -> str:
    def conv(m):
        name, body = m.group(1), m.group(2)
        body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)   # 块注释
        body = re.sub(r'//[^\n]*', '', body)                # 行注释
        pairs = []
        for item in body.split(','):
            item = item.strip()
            if not item:
                continue
            if '=' in item:
                k, v = item.split('=', 1)
                pairs.append((k.strip(), v.strip()))
            else:
                pairs.append((item, None))
        lines = ['export const %s = {' % name]
        for idx, (k, v) in enumerate(pairs):
            lines.append('  %s: %s,' % (k, v if v is not None else str(idx)))
        lines.append('} as const;')
        lines.append('export type %s = typeof %s[keyof typeof %s];' % (name, name, name))
        return '\n'.join(lines)
    return ENUM_RE.sub(conv, text)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit('usage: ets_to_ts.py <src.ets> <dst.ts>')
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding='utf-8') as fh:
        text = fh.read()
    text = strip_enums(text)
    text = rewrite_kits(text)
    text = STRIP.sub(lambda m: "from '%s.ts'" % m.group(1), text)
    with open(dst, 'w', encoding='utf-8') as fh:
        fh.write(text)


if __name__ == '__main__':
    main()
