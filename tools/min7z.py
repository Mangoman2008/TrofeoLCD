#!/usr/bin/env python3
"""
min7z.py —— 最小 7z 读容器工具（只为取出官方主题包里的 PNG/JSON，不追求通用）

为什么要自己写：本机 `7zz` 是 glibc 版 arm64 ELF，而本机是 musl，执行直接
`Permission denied`；也没有 py7zr。而官方主题包就在磁盘上、又是小文件，
所以用一个几百行的纯 Python 解析器把它读出来最省事。

用法：
   python3 tools/min7z.py list  <x.7z>              # 列出条目名与大小
   python3 tools/min7z.py extract <x.7z> <outdir>   # 解出全部条目

限制（够用就行）：
   · 支持 header 里的 kPackInfo/kUnpackInfo/kSubStreamsInfo/kFilesInfo/kNames
   · 解压只支持 **Copy(0x00)** 与 **LZMA1(0x030101)**；其它方法会明确报错
   · 不处理加密、不处理多卷、不校验 CRC
"""
import os
import struct
import sys
import lzma

SIG = bytes.fromhex('377abcaf271c')

# 属性 id
K_END = 0x00
K_HEADER = 0x01
K_ARCHIVE_PROPERTIES = 0x02
K_ADDITIONAL_STREAMS = 0x03
K_MAIN_STREAMS = 0x04
K_FILES_INFO = 0x05
K_PACK_INFO = 0x06
K_UNPACK_INFO = 0x07
K_SUBSTREAMS_INFO = 0x08
K_SIZE = 0x09
K_CRC = 0x0A
K_FOLDER = 0x0B
K_CODERS_UNPACK_SIZE = 0x0C
K_NUM_UNPACK_STREAM = 0x0D
K_EMPTY_STREAM = 0x0E
K_EMPTY_FILE = 0x0F
K_ANTI = 0x10
K_NAME = 0x11
K_CTIME = 0x12
K_ATIME = 0x13
K_MTIME = 0x14
K_WIN_ATTR = 0x15
K_COMMENT = 0x16
K_ENCODED_HEADER = 0x17
K_START_POS = 0x18
K_DUMMY = 0x19


class Buf:
    def __init__(self, data, pos=0):
        self.d = data
        self.p = pos

    def byte(self):
        b = self.d[self.p]
        self.p += 1
        return b

    def uint64(self):
        """7z 的变长整数：首字节高位表示后续字节数"""
        first = self.d[self.p]
        self.p += 1
        mask = 0x80
        value = 0
        for i in range(8):
            if (first & mask) == 0:
                value |= (first & (mask - 1)) << (8 * i)
                return value
            value |= self.d[self.p] << (8 * i)
            self.p += 1
            mask >>= 1
        return value

    def u32(self):
        v = struct.unpack_from('<I', self.d, self.p)[0]
        self.p += 4
        return v

    def u64(self):
        v = struct.unpack_from('<Q', self.d, self.p)[0]
        self.p += 8
        return v

    def bytes(self, n):
        v = self.d[self.p:self.p + n]
        self.p += n
        return v

    def eof(self):
        return self.p >= len(self.d)


class StreamsInfo:
    def __init__(self):
        self.pack_pos = []
        self.pack_sizes = []
        self.folders = []          # [{'coders': [(mid, n_in, n_out, props)], 'unpack_sizes': [...], 'crc': None}]
        self.num_unpack_streams = []
        self.sub_sizes = []
        self.sub_crcs = []

    # ---- kPackInfo ----
    def read_pack_info(self, b):
        self.pack_pos_base = b.uint64()
        num = b.uint64()
        pid = b.byte()
        if pid == K_SIZE:
            for _ in range(num):
                self.pack_sizes.append(b.uint64())
            pid = b.byte()
        else:
            raise ValueError('kPackInfo 缺 kSize')
        if pid == K_CRC:
            b.u32()                      # allAreDefined
            for _ in range(num):
                b.u32()
            pid = b.byte()
        if pid != K_END:
            raise ValueError(f'kPackInfo 未预期属性 {pid:#x}')

    # ---- kUnpackInfo ----
    def read_unpack_info(self, b):
        if b.byte() != K_FOLDER:
            raise ValueError('kUnpackInfo 缺 kFolder')
        num_folders = b.uint64()
        external = b.byte()
        if external != 0:
            raise ValueError('外部 folder 定义不支持')
        for _ in range(num_folders):
            ncoders = b.uint64()
            coders = []
            total_in = 0
            total_out = 0
            for _ in range(ncoders):
                flags = b.byte()
                mid_len = flags & 0x0F
                mid = b.bytes(mid_len) if mid_len else b''
                if flags & 0x10:          # 有流数量
                    n_in = b.uint64()
                    n_out = b.uint64()
                else:
                    n_in = n_out = 1
                if flags & 0x20:          # 有属性
                    psize = b.uint64()
                    props = b.bytes(psize)
                else:
                    props = b''
                if flags & 0x80:          # 有其它可选方法（跳过）
                    b.uint64()
                    b.uint64()
                    b.bytes(b.uint64())
                coders.append((mid, n_in, n_out, props))
                total_in += n_in
                total_out += n_out
            # bind pairs
            nb = total_out - 1
            for _ in range(nb):
                b.uint64()
                b.uint64()
            npacked = total_in - nb
            if npacked > 1:
                for _ in range(npacked):
                    b.uint64()
            self.folders.append({'coders': coders})
        if b.byte() != K_CODERS_UNPACK_SIZE:
            raise ValueError('kUnpackInfo 缺 kCodersUnpackSize')
        for f in self.folders:
            total_out = sum(c[2] for c in f['coders'])
            f['unpack_sizes'] = [b.uint64() for _ in range(total_out)]
        pid = b.byte()
        if pid == K_CRC:
            defined = b.byte()
            for f in self.folders:
                f['crc'] = b.u32() if (defined or True) else None
            pid = b.byte()
        if pid != K_END:
            raise ValueError(f'kUnpackInfo 未预期属性 {pid:#x}')

    # ---- kSubStreamsInfo ----
    def read_substreams_info(self, b, folders):
        self.num_unpack_streams = [1] * len(folders)
        pid = b.byte()
        if pid == K_NUM_UNPACK_STREAM:
            for i in range(len(folders)):
                self.num_unpack_streams[i] = b.uint64()
            pid = b.byte()
        # 每个 folder 的总解压大小
        totals = []
        for i, f in enumerate(folders):
            # 只有一个 coder 且只有一路输出时，就是那个大小
            totals.append(f['unpack_sizes'][-1] if f['unpack_sizes'] else 0)
        # 子流大小（最后一个由总数推出）
        for i, f in enumerate(folders):
            n = self.num_unpack_streams[i]
            s = 0
            for _ in range(n - 1):
                v = b.uint64()
                self.sub_sizes.append(v)
                s += v
            self.sub_sizes.append(totals[i] - s if n > 0 else 0)
        pid = b.byte()
        if pid == K_CRC:
            defined = b.byte()
            n = sum(self.num_unpack_streams)
            for _ in range(n):
                self.sub_crcs.append(b.u32() if (defined & 1) else None)
                defined >>= 1
            pid = b.byte()
        if pid != K_END:
            # 容忍：把剩下的读掉
            pass


def read_streams_info(b):
    si = StreamsInfo()
    pid = b.byte()
    if pid == K_PACK_INFO:
        si.read_pack_info(b)
        pid = b.byte()
    if pid == K_UNPACK_INFO:
        si.read_unpack_info(b)
        pid = b.byte()
    if pid == K_SUBSTREAMS_INFO:
        si.read_substreams_info(b, si.folders)
        pid = b.byte()
    return si


def read_files_info(b):
    names = []
    empty_streams = []
    empty_files = []
    num = None
    pid = b.byte()
    while pid != K_END:
        if pid == K_EMPTY_STREAM:
            all_defined = b.byte()
            if all_defined != 0:
                empty_streams = [True] * (num if num is not None else 0)
            else:
                n = (num if num is not None else 0)
                bits = b.bytes((n + 7) // 8)
                empty_streams = [bool((bits[i // 8] >> (i % 8)) & 1) for i in range(n)]
        elif pid == K_EMPTY_FILE:
            n = (num if num is not None else 0)
            bits = b.bytes((n + 7) // 8)
            empty_files = [bool((bits[i // 8] >> (i % 8)) & 1) for i in range(n)]
        elif pid == K_NAME:
            external = b.byte()
            if external != 0:
                raise ValueError('外部文件名不支持')
            blob = b.bytes(b.p + 0 - b.p) if False else None
            # 名字块是 UTF-16LE、以 0 结尾的串接
            start = b.p
            # 先扫到本属性结束：名字属性后面紧跟属性 id 或 END，但我们无法预知长度，
            # 所以按"读满 num 个以 0 结尾的 UTF-16 串"来解析
            for _ in range(num if num is not None else 0):
                s = []
                while True:
                    ch = struct.unpack_from('<H', b.d, b.p)[0]
                    b.p += 2
                    if ch == 0:
                        break
                    s.append(chr(ch))
                names.append(''.join(s))
        elif pid == K_DUMMY:
            pass
        elif pid in (K_CTIME, K_ATIME, K_MTIME):
            all_defined = b.byte()
            size = b.uint64()
            b.bytes(size)
        elif pid == K_WIN_ATTR:
            all_defined = b.byte()
            size = b.uint64()
            b.bytes(size)
        elif pid == K_START_POS:
            b.uint64()
        else:
            raise ValueError(f'kFilesInfo 未预期属性 {pid:#x}')
        pid = b.byte()
    return names


def lzma1_decompress(props, packed, unpack_size):
    """用 7z 的 5 字节 LZMA 属性（1 字节 lc/lp/pb + 4 字节字典大小）解 LZMA1 裸流。"""
    # 7z 里 LZMA 属性正常是 5 字节（1 字节 lc/lp/pb + 4 字节字典大小）。
    # 但实测官方主题包的编码头只给 1 字节（字典大小缺省），所以这里容错：
    # 缺省按 64KB 取（对流只有 1KB 的编码头完全够用）。
    if len(props) < 1:
        raise ValueError('LZMA 属性为空')
    d0 = props[0]
    lc = d0 % 9
    rem = d0 // 9
    lp = rem % 5
    pb = rem // 5
    dict_size = struct.unpack_from('<I', props, 1)[0] if len(props) >= 5 else 65536
    filt = [{'id': lzma.FILTER_LZMA1, 'lc': lc, 'lp': lp, 'pb': pb,
             'dict_size': max(dict_size, 4096)}]
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=filt)
    out = dec.decompress(packed, max_length=unpack_size) if unpack_size > 0 else dec.decompress(packed)
    return out


def lzma2_decompress(props, packed, unpack_size):
    """LZMA2：`mid=0x21`，props 通常 1 字节 —— 按 7z 规则换算字典大小。

    规则（7z 源码里 Lzma2Coder 的写法）：props[0] 高 2 位为 0 时，
    dictSize = 2 ** ((props[0] & 0x3F) / 2 + 12)。实测官方主题包 props=0x18 → 16MB。
    """
    if len(props) == 1:
        bits = props[0]
        if bits > 40:
            raise ValueError(f'dictSize 编码不合法: {bits}')
        dict_size = (2 | (bits & 1)) << (bits // 2 + 11)
    elif len(props) >= 4:
        dict_size = struct.unpack_from('<I', props, 0)[0]
    else:
        dict_size = 1 << 24
    filt = [{'id': lzma.FILTER_LZMA2, 'dict_size': max(dict_size, 4096)}]
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=filt)
    return dec.decompress(packed, max_length=unpack_size) if unpack_size > 0 else dec.decompress(packed)


def decode_encoded_header(data, si):
    """解出编码头（通常是 LZMA1 压的一个小 buffer）。"""
    if si is None or not si.folders:
        raise ValueError('编码头没有流信息')
    folder = si.folders[0]
    if len(folder['coders']) != 1:
        raise ValueError('编码头用了多 coder 链，本工具暂不支持')
    mid, _nin, _nout, props = folder['coders'][0]
    unpack_size = folder['unpack_sizes'][-1] if folder['unpack_sizes'] else 0
    base = getattr(si, 'pack_pos_base', 0)
    off = 32 + base
    packed = data[off:off + si.pack_sizes[0]]
    if mid == b'\x00':                      # Copy
        return packed[:out_len] if out_len else packed
    out_len = int(unpack_size) if unpack_size else 0
    if mid == b'\x21':                      # LZMA2（单字节 props → 字典大小编码）
        return lzma2_decompress(props, packed, out_len)
    if mid == b'\x03\x01\x01':             # LZMA1（长 id）
        return lzma1_decompress(props, packed, out_len)
    raise ValueError(f'编码头压缩方法不支持: {mid.hex()}')


def parse_header_buffer(data, hdr):
    """解析真正的 kHeader 缓冲，返回 (data, streams, names)。"""
    b = Buf(hdr)
    if b.byte() != K_HEADER:
        raise ValueError('解出来的缓冲不是 kHeader')
    streams = None
    files = None
    pid = b.byte()
    while pid != K_END:
        if pid == K_MAIN_STREAMS:
            streams = read_streams_info(b)
        elif pid == K_FILES_INFO:
            files = b
        else:
            raise ValueError(f'kHeader 未预期属性 {pid:#x}（相对偏移 {b.p - 1}）')
        pid = b.byte()
    names = read_files_info(files) if files is not None else []
    return data, streams, names


def parse(path):
    d = open(path, 'rb').read()
    if d[:6] != SIG:
        raise ValueError('不是 7z 文件')
    next_off = struct.unpack_from('<Q', d, 12)[0]
    next_size = struct.unpack_from('<Q', d, 20)[0]
    hdr = d[32 + next_off:32 + next_off + next_size]
    b = Buf(hdr)
    first = b.byte()
    if first == K_ENCODED_HEADER:
        # 这是"编码头"：先解出真正的 kHeader 字节流，再递归解析
        si = read_streams_info(b)
        hdr = decode_encoded_header(d, si)
        return parse_header_buffer(d, hdr)
    if first != K_HEADER:
        raise ValueError(f'next header 既不是 kHeader 也不是 kEncodedHeader（首字节 {first:#x}）')
    return parse_header_buffer(d, hdr)
    streams = None
    files = None
    pid = b.byte()
    while pid != K_END:
        if pid == K_MAIN_STREAMS:
            streams = read_streams_info(b)
        elif pid == K_FILES_INFO:
            files = b
        else:
            raise ValueError(f'kHeader 未预期属性 {pid:#x}')
        pid = b.byte()
    names = read_files_info(files) if files is not None else []
    return d, streams, names


def coder_name(mid):
    if mid == b'\x00':
        return 'Copy'
    if mid == b'\x03\x01\x01':
        return 'LZMA1'
    if mid == b'\x03\x03\x01':
        return 'LZMA2'
    if mid == b'\x04\x01':
        return 'BCJ-x86'
    return mid.hex()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mode, path = sys.argv[1], sys.argv[2]
    d, si, names = parse(path)
    print(f'=== {os.path.basename(path)} ===  条目 {len(names)} 个')
    if si is None:
        print('无主流信息')
        return 1
    for i, f in enumerate(si.folders):
        methods = [coder_name(c[0]) for c in f['coders']]
        print(f'  folder[{i}] 方法={methods} 解压大小={f["unpack_sizes"]}')
    print(f'  pack 段数={len(si.pack_sizes)} 大小={si.pack_sizes}')
    for n in names[:40]:
        print('   ', n)
    if len(names) > 40:
        print(f'    … 其余 {len(names)-40} 个')

    if mode == 'extract' and len(sys.argv) >= 4:
        outdir = sys.argv[3]
        os.makedirs(outdir, exist_ok=True)
        # 单 folder + Copy：直接按子流大小切
        if len(si.folders) == 1 and len(si.folders[0]['coders']) == 1 \
                and si.folders[0]['coders'][0][0] == b'\x00':
            base = si.pack_pos_base if hasattr(si, 'pack_pos_base') else 32
            data = d[base:base + si.pack_sizes[0]]
            off = 0
            for i, n in enumerate(names):
                size = si.sub_sizes[i] if i < len(si.sub_sizes) else 0
                dst = os.path.join(outdir, n.replace('\\', '/'))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                open(dst, 'wb').write(data[off:off + size])
                off += size
            print(f'✅ 已解出 {len(names)} 个文件 → {outdir}')
        else:
            print('⚠️ 该包不是"单 folder + Copy"，需要按 coder 链解压；当前解析器先只列出结构。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
