/**
 * LyProtocol.ets — 利民 Trofeo Vision 9.16 LCD 的 "LY" Bulk 协议实现
 *
 * 设备：VID 0x0416 / PID 0x5408（LY）、0x5409（LY1），**1920x462**（9.16 寸），USB Bulk
 * 参考：thermalright-trcc-linux (src/trcc/adapters/device/ly_lcd.py) 与
 *       m1ng-li/mac-thermalright-ai-monitor (Sources/MacTR/USB/LYProtocol.swift)
 *
 * 帧格式：整帧 JPEG 按 496 字节切片，每片加 16 字节块头组成 512 字节块。
 */

// ---- 协议常量 ----
const CHUNK_SIZE: number = 512;
const CHUNK_HEADER_SIZE: number = 16;
const CHUNK_DATA_SIZE: number = CHUNK_SIZE - CHUNK_HEADER_SIZE; // 496
const USB_WRITE_SIZE: number = 4096;
const HANDSHAKE_SIZE: number = 2048;
/**
 * 单帧 JPEG 上限（字节）。
 *
 * ★ 2026-10-15 由 650000 改为 450000 —— 这是**同一份协议的两套真源**里的一处，
 *   而 C# 侧（`win/src/Ly.cs:50`）早已按真机实测改成 450000。三条依据：
 *     · 厂商反编译 `USBLCDNEW.dll` 的 `max_frame_bytes = 450000`
 *     · 同型号开源驱动 trofeo-lcd(Rust) 的 `MAX_FRAME_BYTES = 450_000`
 *     · 真机实测：~360KB 正常显示，**~570KB 被固件忽略**
 *   旧值 650000 抄自 MacTR —— 那个项目声明了 maxJPEGSize 却从不检查它。
 *
 * ⚠️ 后果为什么危险：降质阶梯只在"超过这个值"时才启动（LcdService 里那三处
 *   `> LyProtocol.maxJpegSize()`）。所以 450~650KB 的帧，应用侧认为"没超限、不用降质"
 *   照常推送，**固件直接忽略** —— 表现为 `stats.sent` 正常增长、`sendJpeg` 返回 true、
 *   `/diag` 全绿，但屏上是旧画面。这是最难定位的一类故障。
 */
const MAX_JPEG_SIZE: number = 450000;

export const PID_LY: number = 0x5408;
export const PID_LY1: number = 0x5409;
export const VENDOR_ID: number = 0x0416;

/**
 * ★ 分块流复用缓冲（2026-10-31 审计 C1：buildChunkStream 零拷贝化）。
 *
 * 原实现每帧 `new Uint8Array(paddedChunks * 512)`：100KB 帧就是 ~104KB/帧的分配，
 * 连续推帧下 MB/s 级的持续垃圾、全压在 young-gen GC 上。改为模块级**只增不缩**缓冲：
 * 容量不足才重新分配，平时只返回精确长度的 subarray 视图，块内数据用 set() 整段拷贝。
 *
 * 复用安全性（为什么不会出现"上一帧的流被下一帧覆写"）：
 *   1. buildChunkStream 的调用方只有 LcdUsb.sendJpeg（stream 是局部变量，不外泄）
 *      和 SelfTest 的 KAT（同步断言，用完即弃）。
 *   2. sendJpeg 严格单飞：普通推帧 pushInFlight（LcdService:3604）、流水线 pushBusy
 *      背压丢帧（:3622）、序列推帧 pushBusy+pushInFlight 双护栏（:3822），三条路径
 *      互斥 —— 任意时刻至多一个 sendJpeg 在途，上一帧的流必然已全部 bulkTransfer
 *      完，缓冲才会被下一次 buildChunkStream 复用。
 *   3. bulkTransfer 在调用时同步完成 JS→native 的缓冲区拷贝，之后不持有 JS 侧引用。
 *
 * 上界：MAX_JPEG_SIZE=450000 → 缓冲最大 ~464KB，一次分配后常驻复用。
 */
let chunkStreamBuf: Uint8Array = new Uint8Array(0);

/**
 * PM -> FBL 覆写表（对应 trcc core/protocol.py 的 _PM_TO_FBL_OVERRIDES）
 * 68 -> 192（1280x480）、69 -> 192（1920x440）、65/66 -> 192、64/63 -> 114
 */
export function pmToFbl(pm: number): number {
  if (pm === 65 || pm === 66 || pm === 68 || pm === 69) {
    return 192;
  }
  if (pm === 64 || pm === 63) {
    return 114;
  }
  return pm;
}

/**
 * 编码旋转角。
 *
 * 依据 trcc `core/protocol.py` 的 encode 表：
 *   1920x462 / 1920x440 : SUB ∈ {2,3,4} -> 0°，否则 180°
 *   1280x480            : SUB == 2 -> 90°，否则 0°（本工程只支持 0/180）
 * 真机实测 Trofeo Vision 9.16 为 PM=65 SUB=5，即 180°。
 */
export function encodeRotation(w: number, h: number, sub: number): number {
  if (w === 1920 && (h === 462 || h === 440 || h === 480 || h === 400)) {
    return (sub === 2 || sub === 3 || sub === 4) ? 0 : 180;
  }
  if (w === 1280 && h === 480) {
    return sub === 2 ? 90 : 0;
  }
  return 180;
}

/** 设备信息（握手结果） */
export class DeviceInfo {
  pm: number = 0;
  sub: number = 0;
  fbl: number = 0;
  width: number = 1920;
  height: number = 462;   // 9.16 的默认高度（见 Theme.L.height 的说明）
  rotate: boolean = true;
  /** 编码旋转角（0 或 180；依据设备 SUB 字节决定） */
  rotateDeg: number = 180;
  pid: number = PID_LY;

  constructor(pm: number, sub: number, fbl: number, w: number, h: number,
              rotate: boolean, rotateDeg: number, pid: number) {
    this.pm = pm;
    this.sub = sub;
    this.fbl = fbl;
    this.width = w;
    this.height = h;
    this.rotate = rotate;
    this.rotateDeg = rotateDeg;
    this.pid = pid;
  }

  toString(): string {
    return `PM=${this.pm} SUB=${this.sub} FBL=${this.fbl} ${this.width}x${this.height} rot=${this.rotateDeg}°`;
  }
}

export class LyProtocol {
  /** 构造 2048 字节握手包 */
  static buildHandshake(): Uint8Array {
    const buf = new Uint8Array(HANDSHAKE_SIZE);
    buf[0] = 0x02;
    buf[1] = 0xFF;
    buf[8] = 0x01;
    return buf;
  }

  /**
   * 解析握手响应（512 字节）
   * 校验 resp[0]==0x03 && resp[1]==0xFF && resp[8]==0x01
   */
  static parseHandshakeResponse(resp: Uint8Array, pid: number): DeviceInfo | null {
    if (resp.length < 37) {
      return null;
    }
    if (resp[0] !== 0x03 || resp[1] !== 0xFF || resp[8] !== 0x01) {
      return null;
    }

    let pm: number;
    let sub: number;
    if (pid === PID_LY) {
      let rawPm = resp[20];
      if (rawPm <= 3) {
        rawPm = 1;
      }
      pm = 64 + rawPm;
      sub = resp[22] + 1;
    } else {
      // LY1：trcc 已修正为 49 + resp[20]（旧写法 50 + resp[36] 取错了回复字节）
      pm = 49 + resp[20];
      sub = resp[22];
    }

    const fbl = pmToFbl(pm);
    let w = 1920;
    let h = 462;

    if (fbl === 192) {
      // FBL 192 被多个分辨率共用，需按 PM 二次消歧
      if (pm === 68) {
        w = 1280;
        h = 462;
      } else if (pm === 69) {
        // 9.16 之外的另一个型号：开源驱动按 resp[20]==5（即 PM=69）判定为
        // "Trofeo Vision 11.3 (1920x400)"，所以这里给 400，不再给 440
        w = 1920;
        h = 400;
      } else {
        // 分辨率分歧：电商页面写 1920x480（宣传值）；厂商反编译（trcc）的型号/主题表
        // 只有 1920X462 / 1920X440，同型号开源驱动 haven80/trofeo-lcd-rs 也写
        // "trofeo-9.16 (default, 1920x462)"。取 462。
        w = 1920;
        h = 462;
      }
    } else if (fbl === 114) {
      w = 1600;
      h = 720;
    } else if (fbl === 128) {
      w = 1280;
      h = 462;
    }

    const deg = encodeRotation(w, h, sub);
    return new DeviceInfo(pm, sub, fbl, w, h, deg !== 0, deg, pid);
  }

  /**
   * 把整帧 JPEG 打成 LY 分块流。
   * 块头（16 字节，小端）：[0]=01 [1]=FF | LE32 总长@2 | LE16 本块长@6 |
   *   [8]=cmd | LE16 总块数@9 | LE16 块序号@11 | [13..15]=0
   */
  static buildChunkStream(jpeg: Uint8Array, pid: number): Uint8Array {
    const total = jpeg.length;
    const numChunks = Math.floor(total / CHUNK_DATA_SIZE) + 1;
    const cmd: number = (pid === PID_LY) ? 0x01 : 0x02;

    // LY 类型要求块数补齐到 4 的倍数
    let paddedChunks = numChunks;
    if (pid === PID_LY) {
      const rem = numChunks % 4;
      if (rem !== 0) {
        paddedChunks = numChunks + (4 - rem);
      }
    }

    // ★ C1：复用模块级缓冲（见 chunkStreamBuf 的注释）——容量不足才扩，平时零分配
    const need: number = paddedChunks * CHUNK_SIZE;
    if (chunkStreamBuf.length < need) {
      chunkStreamBuf = new Uint8Array(need);
    }
    const out = chunkStreamBuf.subarray(0, need);
    const view = new DataView(out.buffer);

    for (let i = 0; i < numChunks; i++) {
      const off = i * CHUNK_SIZE;
      const isLast = (i === numChunks - 1);
      const dataLen = isLast ? (total % CHUNK_DATA_SIZE) : CHUNK_DATA_SIZE;

      out[off] = 0x01;
      out[off + 1] = 0xFF;
      view.setUint32(off + 2, total, true);
      view.setUint16(off + 6, dataLen, true);
      out[off + 8] = cmd;
      view.setUint16(off + 9, numChunks, true);
      view.setUint16(off + 11, i, true);
      // [13..15] 保持 0

      // ★ C1：set() 整段拷贝替代逐字节循环（TypedArray.set 走 memcpy，快一个数量级）
      const srcOff = i * CHUNK_DATA_SIZE;
      out.set(jpeg.subarray(srcOff, srcOff + dataLen), off + CHUNK_HEADER_SIZE);
    }

    // ★ C1 复用收尾：尾块 dataLen 之后的残区 + 补齐块，在**复用**时留着上一帧的字节。
    //   新分配的 buffer 天生全 0，复用的不是 —— 必须显式清零，保证与旧实现逐字节一致
    //   （设备按块头 dataLen 读，理论上不看残区，但别赌固件真的不看）。
    const residueFrom = (numChunks - 1) * CHUNK_SIZE + CHUNK_HEADER_SIZE + (total % CHUNK_DATA_SIZE);
    if (residueFrom < need) {
      out.fill(0, residueFrom, need);
    }
    return out;
  }

  /** 一帧需要分的 USB 写次数（4096 字节一次，LY 尾包最小 2048） */
  /**
   * 每次 bulkTransfer 送多少字节。协议里 512B 分块不变，这里只是"每次传输合几个块"：
   * 一次 4096B 写 ↔ 8 个块。真机上 100KB 帧要 25 次写（~5ms/次），是帧率的主要开销，
   * 所以做成可调（/set?wsize=N）以便实测多大能过。
   */
  static writeSize: number = USB_WRITE_SIZE;

  static setWriteSize(n: number): number {
    if (n >= 2048 && n <= 65536 && (n % 512) === 0) {
      LyProtocol.writeSize = n;
    }
    return LyProtocol.writeSize;
  }

  static writeChunks(chunkStream: Uint8Array, pid: number): Uint8Array[] {
    const writes: Uint8Array[] = [];
    const total = chunkStream.length;
    const ws = LyProtocol.writeSize;
    let pos = 0;
    while (pos < total) {
      const remaining = total - pos;
      let size: number;
      if (remaining >= ws) {
        size = ws;
      } else {
        // ★ LY 的收尾包必须 ≤2048（见本文件顶部常量说明）。
        //   注意：不能写成 `pos += ws` —— 那样当剩余量落在 (2048, ws) 区间时，
        //   实际只发了 2048 字节、位置却推进了 ws，**尾部 2048..ws-1 字节被静默丢弃**
        //   （实测 ws=4096 时会丢 2048..4095 字节 = 帧尾 4~8 个分块；设备侧表现为
        //   那一帧永远解不出来 → 偶发"画面不刷新/需要重发才显示"）。
        size = (pid === PID_LY) ? Math.min(2048, remaining) : remaining;
      }
      // ★ C1：subarray 视图替代 slice 拷贝（4096B × ~25 次/帧 → 零拷贝）。
      //   安全：视图只被 sendJpeg 的 bulkTransfer 消费（调用时即完成 native 拷贝），
      //   单飞护栏保证底层缓冲不会在消费期间被复用（见 chunkStreamBuf 注释）。
      writes.push(chunkStream.subarray(pos, pos + size));
      // 按**实际发送长度**推进（本行原来是 pos += ws，是丢帧尾的根因）
      pos += size;
    }
    return writes;
  }

  static maxJpegSize(): number {
    return MAX_JPEG_SIZE;
  }
}

/** 从 JPEG 字节流中读出宽高（SOF 标记），用于校验实际渲染尺寸 */
export class JpegInfo {
  width: number = 0;
  height: number = 0;
  valid: boolean = false;
}

export function parseJpegSize(data: Uint8Array): JpegInfo {
  const info = new JpegInfo();
  if (data.length < 4 || data[0] !== 0xFF || data[1] !== 0xD8) {
    return info;
  }
  let i = 2;
  while (i + 9 < data.length) {
    if (data[i] !== 0xFF) {
      i++;
      continue;
    }
    const marker = data[i + 1];
    // SOF0..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15
    const isSof = (marker >= 0xC0 && marker <= 0xC3) ||
      (marker >= 0xC5 && marker <= 0xC7) ||
      (marker >= 0xC9 && marker <= 0xCB) ||
      (marker >= 0xCD && marker <= 0xCF);
    if (isSof) {
      info.height = (data[i + 5] << 8) | data[i + 6];
      info.width = (data[i + 7] << 8) | data[i + 8];
      info.valid = true;
      return info;
    }
    const segLen = (data[i + 2] << 8) | data[i + 3];
    if (segLen <= 0) {
      break;
    }
    i += 2 + segLen;
  }
  return info;
}
