#!/usr/bin/env python3
"""
extract_theme7z.py —— 把官方主题包（trcc 的 theme*.7z）解出里面的 PNG/JSON

背景：这些包就在本机磁盘上
    ~/.cache/trcc/repos/thermalright-trcc-linux/src/trcc/data/theme<W>x<H>.7z
但本机的 `7zz` 是 **glibc 版 arm64 ELF**，而本机是 musl → 执行报 Permission denied；
也没有 py7zr / libarchive。于是用 Python 自带的 `lzma` 手写解析：

实测这些包的结构（以 theme240240.7z 为例）：
    · Next Header 是 **Encoded Header**（属性 0x17），头自身是压缩的
    · 编码头压缩方法：**LZMA2**（method id 单字节 0x21，props 1 字节 → 字典大小按 7z 规则换算）
    · 主数据流：**先 LZMA2、再 BCJ-x86** 的过滤器链
      （Python 里要按 `[FILTER_X86, FILTER_LZMA2]` 的顺序给）
    · 解开后是一串 PNG（+ 少量 JSON），按子流顺序排列

切文件不依赖子流尺寸表（那张表在不同包里字段不齐），而是**按 PNG 自身结构走**：
读 chunk 长度直到 IEND，天然精确；JSON 用花括号配平。切完校验：
    · PNG：IHDR 尺寸 + 每个 chunk 的 CRC32
    · JSON：能不能 json.loads

用法：
    python3 tools/extract_theme7z.py <themeX.7z> <outdir>
"""
import json
import lzma
import os
import struct
import sys
import zlib


# --------------------------------------------------------------------------
# 7z 容器解析（只到"拿到解压后的数据流"为止）
# --------------------------------------------------------------------------
SIG = bytes.fromhex('377abcaf271c')
LZMA2_HEADER_PROPS = 0x21


class Buf:
    def __init__(self, data, pos=0):
        self.d = data
        self.p = pos

    def byte(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def vint(self):
        first = self.d[self.p]
        self.p += 1
        mask = 0x80
        val = 0
        for i in range(8):
            if (first & mask) == 0:
                val |= (first & (mask - 1)) << (8 * i)
                return val
            val |= self.d[self.p] << (8 * i)
            self.p += 1
            mask >>= 1
        return val

    def take(self, n):
        v = self.d[self.p:self.p + n]
        self.p += n
        return v

    def eof(self):
        return self.p >= len(self.d)


def lzma2_dict_size(props: bytes) -> int:
    """7z 的 LZMA2 属性 → 字典大小（props 1 字节的高 6 位编码）"""
    if len(props) >= 4:
        return struct.unpack_from('<I', props, 0)[0]
    if not props:
        return 1 << 24
    bits = props[0]
    if bits > 40:
        raise ValueError(f'LZMA2 dictSize 编码不合法: {bits}')
    return (2 | (bits & 1)) << (bits // 2 + 11)


def read_streams_info(b: Buf) -> dict:
    """读 kPackInfo / kUnpackInfo（/ kSubStreamsInfo），够本项目用即可。

    ★ 注意：**单 coder 的 folder 没有 bind pair、也没有 pack index** ——
      早期版本无条件按 `total_out - 1` 去读，单 coder 时就会把这之后的
      kCodersUnpackSize 标记字节（0x0c）当成 bind pair 吃掉，导致后续解析全错位。
      官方主题包恰好都是单 coder，所以这个分支必须判对。
    """
    out = {'pack_pos': 0, 'pack_sizes': [], 'folders': [], 'sub_sizes': []}
    pid = b.byte()
    # 只在这三种属性下才继续消费；否则说明 StreamsInfo 为空，把这一字节还回去
    if pid not in (0x06, 0x07, 0x08):
        b.p -= 1
        return out
    if pid == 0x06:                                  # kPackInfo
        out['pack_pos'] = b.vint()
        n = b.vint()
        if b.byte() != 0x09:                         # kSize
            raise ValueError('kPackInfo 缺 kSize')
        out['pack_sizes'] = [b.vint() for _ in range(n)]
        if b.byte() != 0x00:
            raise ValueError('kPackInfo 未以 kEnd 结束')
        pid = b.byte()
    if pid == 0x07:                                  # kUnpackInfo
        if b.byte() != 0x0b:                         # kFolder
            raise ValueError('kUnpackInfo 缺 kFolder')
        nfolders = b.vint()
        if b.byte() != 0:
            raise ValueError('不支持外部 folder 定义')
        for _ in range(nfolders):
            ncoders = b.vint()
            coders = []
            total_in = total_out = 0
            for _ in range(ncoders):
                flags = b.byte()
                idlen = flags & 0x0F
                mid = b.take(idlen) if idlen else b''
                if flags & 0x10:
                    nin, nout = b.vint(), b.vint()
                else:
                    nin = nout = 1
                props = b''
                if flags & 0x20:
                    props = b.take(b.vint())
                if flags & 0x80:                     # 其它可选方法：跳过
                    b.take(b.vint()); b.take(b.vint()); b.take(b.vint())
                coders.append({'id': mid, 'in': nin, 'out': nout, 'props': props})
                total_in += nin
                total_out += nout
            # 只有多 coder 才有 bind pair 与 pack index；单 coder 两者都没有
            if total_out > 1:
                for _ in range(total_out - 1):
                    b.vint(); b.vint()
                npacked = total_in - (total_out - 1)
                if npacked > 1:
                    for _ in range(npacked):
                        b.vint()
            out['folders'].append({'coders': coders})
        if b.byte() != 0x0c:                         # kCodersUnpackSize
            raise ValueError('kUnpackInfo 缺 kCodersUnpackSize')
        for f in out['folders']:
            n = sum(c['out'] for c in f['coders'])
            f['unpack_sizes'] = [b.vint() for _ in range(n)]
        pid = b.byte()
        if pid == 0x0a:                              # kCRC
            b.byte()
            for f in out['folders']:
                f['crc'] = b.take(4)
            pid = b.byte()
        if pid != 0x00:
            raise ValueError(f'kUnpackInfo 未预期属性 {pid:#x}')
        pid = b.byte()
    if pid == 0x08:                                  # kSubStreamsInfo
        nums = [1] * len(out['folders'])
        pid2 = b.byte()
        if pid2 == 0x0d:                             # kNumUnpackStream
            for i in range(len(out['folders'])):
                nums[i] = b.vint()
            pid2 = b.byte()
        for i, f in enumerate(out['folders']):
            total = f['unpack_sizes'][-1]
            acc = 0
            for _ in range(nums[i] - 1):
                v = b.vint()
                out['sub_sizes'].append(v)
                acc += v
            out['sub_sizes'].append(total - acc)
        pid = b.byte()
    return out


def decompress_chain(folder: dict, packed: bytes) -> bytes:
    """按 coder 链解压。7z 的 coders 顺序 = 解压顺序；Python 过滤器链要反过来给。"""
    ids = [c['id'].hex() for c in folder['coders']]
    unpack = int(folder['unpack_sizes'][-1])
    if len(folder['coders']) == 1:
        c = folder['coders'][0]
        if c['id'] == b'\x00':
            return packed[:unpack]
        if c['id'] == bytes.fromhex('21'):
            filt = [{'id': lzma.FILTER_LZMA2, 'dict_size': lzma2_dict_size(c['props'])}]
        elif c['id'] == bytes.fromhex('030101'):
            filt = [{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 23}]
        else:
            raise ValueError(f'不支持的压缩方法 {ids}')
    else:
        # 形如 [LZMA2, BCJ-x86] → Python 要 [FILTER_X86, FILTER_LZMA2]
        filt = []
        for c in reversed(folder['coders']):
            if c['id'] == bytes.fromhex('21'):
                filt.append({'id': lzma.FILTER_LZMA2, 'dict_size': lzma2_dict_size(c['props'])})
            elif c['id'] == bytes.fromhex('03030103'):
                filt.append({'id': lzma.FILTER_X86})
            else:
                raise ValueError(f'过滤器链里有不支持的方法 {c["id"].hex()}')
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=filt)
    return dec.decompress(packed, max_length=unpack)


def parse_7z(path: str) -> bytes:
    d = open(path, 'rb').read()
    if d[:6] != SIG:
        raise ValueError('不是 7z 文件')
    next_off = struct.unpack_from('<Q', d, 12)[0]
    next_size = struct.unpack_from('<Q', d, 20)[0]
    nh = d[32 + next_off:32 + next_off + next_size]
    b = Buf(nh)
    attr = b.byte()
    if attr == 0x17:                                 # kEncodedHeader：头是压缩的
        si = read_streams_info(b)
        f = si['folders'][0]
        packed = d[32:32 + si['pack_sizes'][0]]
        hdr = decompress_chain(f, packed)
        # ★ 实测：官方主题包没有文件条目 —— 编码头解出来**就是载荷本身**
        #   （通常是一张 PNG）。所以先认 PNG/JPEG 签名，认出来直接返回。
        if hdr[:8] == PNG_SIG + b'\r\n\x1a\n' or hdr[:2] == b'\xff\xd8':
            return hdr
        b = Buf(hdr)
        if b.byte() != 0x01:
            raise ValueError(f'解出的缓冲既不是图片也不是 kHeader（首字节 {hdr[0]:#x}）')
    elif attr != 0x01:
        raise ValueError(f'未知的 Next Header 属性 {attr:#x}')
    # 主 StreamsInfo
    pid = b.byte()
    if pid != 0x04:
        raise ValueError(f'kHeader 里第一个属性不是 kMainStreamsInfo（{pid:#x}）')
    si = read_streams_info(b)
    if not si['folders']:
        raise ValueError('没有主数据流')
    f = si['folders'][0]
    packed = d[32 + si['pack_pos']:32 + si['pack_pos'] + si['pack_sizes'][0]]
    return decompress_chain(f, packed)


# --------------------------------------------------------------------------
# 按文件结构精确切分
# --------------------------------------------------------------------------
PNG_SIG = bytes.fromhex('89504e47')


def carve_png(data: bytes, pos: int):
    """从 pos（PNG 签名处）解析到 IEND 结束，顺带校验 chunk CRC 与 IHDR 尺寸。"""
    if data[pos:pos + 8] != PNG_SIG + b'\r\n\x1a\n':
        return None
    p = pos + 8
    w = h = -1
    while p + 8 <= len(data):
        (length,) = struct.unpack_from('>I', data, p)
        ctype = data[p + 4:p + 8]
        body = data[p + 8:p + 8 + length]
        (crc,) = struct.unpack_from('>I', data, p + 8 + length)
        if zlib.crc32(ctype + body) & 0xFFFFFFFF != crc:
            return None                                # CRC 不对 → 不是干净的 PNG
        if ctype == b'IHDR':
            w, h = struct.unpack_from('>II', body, 0)
        end = p + 12 + length
        if ctype == b'IEND':
            return end, w, h
        p = end
    return None


def carve_json(data: bytes, pos: int):
    """从 '{' 开始按花括号配平切一段 JSON（跳过字符串里的括号）。"""
    if data[pos:pos + 1] != b'{':
        return None
    depth = 0
    in_str = False
    esc = False
    for i in range(pos, len(data)):
        ch = data[i:i + 1]
        if in_str:
            if esc:
                esc = False
            elif ch == b'\\':
                esc = True
            elif ch == b'"':
                in_str = False
            continue
        if ch == b'"':
            in_str = True
        elif ch == b'{':
            depth += 1
        elif ch == b'}':
            depth -= 1
            if depth == 0:
                blob = data[pos:i + 1]
                try:
                    json.loads(blob.decode('utf-8'))
                    return i + 1, blob
                except Exception:
                    return None
    return None


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, outdir = sys.argv[1], sys.argv[2]
    data = parse_7z(src)
    print(f'{os.path.basename(src)} → 解开 {len(data)} 字节')

    # ★ 实测发现：官方主题包（theme<W>x<H>.7z）里**没有文件条目** ——
    #   整个载荷就是一张 PNG（1920×480 等），7z 只是给它套了个 LZMA2 压缩壳。
    #   所以这种情况直接落盘成 .png 就行，不需要走"切文件"那套。
    if data[:8] == PNG_SIG + b'\r\n\x1a\n':
        got = carve_png(data, 0)
        if got:
            end, w, h = got
            name = f'theme_{w}x{h}.png'
            open(os.path.join(outdir, name), 'wb').write(data[:end])
            print(f'✅ 载荷是一张 PNG：{name}  {end:,} B  （尾部多余 {len(data) - end} B）')
            return 0
    os.makedirs(outdir, exist_ok=True)

    idx = 0
    pos = 0
    n_png = n_json = n_skip = 0
    while pos < len(data):
        if data[pos:pos + 8] == PNG_SIG + b'\r\n\x1a\n':
            got = carve_png(data, pos)
            if got:
                end, w, h = got
                name = f'{idx:03d}_{w}x{h}.png'
                open(os.path.join(outdir, name), 'wb').write(data[pos:end])
                print(f'  ✅ PNG {name:14s} {end - pos:>9,} B')
                n_png += 1
                idx += 1
                pos = end
                continue
        if data[pos:pos + 1] == b'{':
            got = carve_json(data, pos)
            if got:
                end, blob = got
                name = f'{idx:03d}.json'
                open(os.path.join(outdir, name), 'wb').write(blob)
                print(f'  ✅ JSON {name:13s} {end - pos:>9,} B')
                n_json += 1
                idx += 1
                pos = end
                continue
        n_skip += 1
        pos += 1
    print(f'完成：{n_png} 个 PNG、{n_json} 个 JSON，跳过 {n_skip} 字节零散数据 → {outdir}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
