#!/usr/bin/env python3
"""
ly_reference.py — LY 协议的独立参考实现（用于生成 App 内自检的期望值）

严格照 thermalright-trcc-linux `src/trcc/adapters/device/ly_lcd.py` 的语义重写：
  _prepare_frame  : 512 字节分块（16 字节头 + 496 数据），LY 块数补齐到 4 的倍数
  _write_frame    : 4096 字节一次写，尾包 LY 取 min(2048, 剩余)
  握手解析        : resp[0]==3 && resp[1]==0xFF && resp[8]==1；
                    PM = 64 + resp[20]（≤3 记 1），SUB = resp[22] + 1
  旋转            : 1920x462/440 -> SUB∈{2,3,4} 为 0°，否则 180°

用途：算出已知答案，写进 ArkTS 自检（SelfTest.ets），在真机上跑一次即可确认
      ArkTS 实现与参考实现逐字节一致。

用法：python3 tools/ly_reference.py
"""
import struct

CHUNK_SIZE = 512
CHUNK_HEADER_SIZE = 16
CHUNK_DATA_SIZE = 496
USB_WRITE_SIZE = 4096
PID_LY = 0x5408


def prepare_frame(payload: bytes, pid: int = PID_LY) -> bytes:
    total_size = len(payload)
    num_chunks = total_size // CHUNK_DATA_SIZE + 1
    last_chunk_data = total_size % CHUNK_DATA_SIZE
    chunk_cmd = 1 if pid == PID_LY else 2

    chunks = bytearray(num_chunks * CHUNK_SIZE)
    for i in range(num_chunks):
        offset = i * CHUNK_SIZE
        is_last = (i == num_chunks - 1)
        data_len = last_chunk_data if is_last else CHUNK_DATA_SIZE

        chunks[offset] = 0x01
        chunks[offset + 1] = 0xFF
        struct.pack_into("<I", chunks, offset + 2, total_size)
        struct.pack_into("<H", chunks, offset + 6, data_len)
        chunks[offset + 8] = chunk_cmd
        struct.pack_into("<H", chunks, offset + 9, num_chunks)
        struct.pack_into("<H", chunks, offset + 11, i)
        chunks[offset + CHUNK_HEADER_SIZE:offset + CHUNK_HEADER_SIZE + data_len] = \
            payload[i * CHUNK_DATA_SIZE:i * CHUNK_DATA_SIZE + data_len]

    pad_multiple = 4 if pid == PID_LY else 1
    padded = num_chunks
    rem = padded % pad_multiple
    if rem:
        padded += pad_multiple - rem
    return bytes(chunks) + bytes(padded * CHUNK_SIZE - len(chunks))


def write_segments(frame: bytes, pid: int = PID_LY):
    """返回 [(offset, size), ...] —— 对应参考实现的 4096 字节写循环"""
    out, pos, total = [], 0, len(frame)
    while pos < total:
        remaining = total - pos
        if remaining >= USB_WRITE_SIZE:
            size = USB_WRITE_SIZE
        else:
            size = min(2048, remaining) if pid == PID_LY else remaining
        out.append((pos, size))
        pos += USB_WRITE_SIZE
    return out


def parse_handshake(resp: bytes, pid: int = PID_LY):
    if len(resp) < 37 or resp[0] != 3 or resp[1] != 0xFF or resp[8] != 1:
        return None
    if pid == PID_LY:
        raw = resp[20]
        if raw <= 3:
            raw = 1
        pm = 64 + raw
        sub = (resp[22] if len(resp) > 22 else 0) + 1
    else:
        pm = 49 + resp[20]
        sub = resp[22] if len(resp) > 22 else 0

    fbl = 192 if pm in (65, 66, 68, 69) else (114 if pm in (63, 64) else pm)
    if fbl == 192:
        if pm == 68:
            w, h = 1280, 480
        elif pm == 69:
            w, h = 1920, 440
        else:
            w, h = 1920, 480
    elif fbl == 114:
        w, h = 1600, 720
    elif fbl == 128:
        w, h = 1280, 480
    else:
        w, h = 1920, 480
    return {'pm': pm, 'sub': sub, 'fbl': fbl, 'w': w, 'h': h,
            'rot': encode_rotation(w, h, sub)}


def encode_rotation(w: int, h: int, sub: int) -> int:
    if w == 1920 and h in (462, 440, 480):
        return 0 if sub in (2, 3, 4) else 180
    if w == 1280 and h == 480:
        return 90 if sub == 2 else 0
    return 180


def fnv1a32(data: bytes) -> int:
    h = 2166136261
    for b in data:
        h ^= b
        h = (h * 16777619) & 0xFFFFFFFF
    return h


def kat_input(n: int = 1000) -> bytes:
    """确定性伪 JPEG 输入（分块器不关心内容，只要字节确定即可）"""
    return bytes(((i * 37 + 11) & 0xFF) for i in range(n))


def main():
    payload = kat_input()
    frame = prepare_frame(payload)
    segs = write_segments(frame)

    print('=== 分块流（payload %d 字节）===' % len(payload))
    print(f'  帧总长      : {len(frame)}')
    print(f'  块数(num_chunks 字段) : {struct.unpack_from("<H", frame, 9)[0]}')
    print(f'  补齐后块数  : {len(frame) // CHUNK_SIZE}')
    print(f'  第0块头     : magic={frame[0]:02x}{frame[1]:02x} '
          f'total={struct.unpack_from("<I", frame, 2)[0]} '
          f'len={struct.unpack_from("<H", frame, 6)[0]} cmd={frame[8]:02x} '
          f'count={struct.unpack_from("<H", frame, 9)[0]} '
          f'idx={struct.unpack_from("<H", frame, 11)[0]}')
    off = 2 * CHUNK_SIZE
    print(f'  第2块头(尾) : len={struct.unpack_from("<H", frame, off + 6)[0]} '
          f'idx={struct.unpack_from("<H", frame, off + 11)[0]}')
    print(f'  写分段      : {segs}')
    print(f'  FNV-1a 32   : {fnv1a32(frame)}  (0x{fnv1a32(frame):08X})')

    print()
    print('=== 握手解析（构造 resp[20]=1, resp[22]=4，即真机 9.16 的 PM=65/SUB=5）===')
    resp = bytearray(512)
    resp[0], resp[1], resp[8] = 3, 0xFF, 1
    resp[20], resp[22] = 1, 4
    r = parse_handshake(bytes(resp))
    print(f'  {r}')
    bad = bytearray(resp)
    bad[8] = 0
    print(f'  篡改 resp[8]=0 -> {parse_handshake(bytes(bad))}  (应为 None)')

    print()
    print('=== 旋转规则 ===')
    for (w, h, s) in [(1920, 480, 5), (1920, 462, 5), (1920, 462, 3),
                      (1920, 440, 2), (1280, 480, 2), (1280, 480, 1)]:
        print(f'  {w}x{h} SUB={s} -> {encode_rotation(w, h, s)}°')

    print()
    print('=== ArkTS 自检要用的常量 ===')
    print(f'  KAT_LEN        = {len(payload)}')
    print(f'  KAT_FRAME_LEN  = {len(frame)}')
    print(f'  KAT_FNV        = {fnv1a32(frame)}')
    print(f'  KAT_CHUNKS     = {struct.unpack_from("<H", frame, 9)[0]}')
    print(f'  KAT_PADDED     = {len(frame) // CHUNK_SIZE}')
    print(f'  KAT_SEGMENTS   = {len(segs)}  (首个 {segs[0][1]} 字节)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
