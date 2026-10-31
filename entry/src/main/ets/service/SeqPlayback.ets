/**
 * SeqPlayback.ets — 预烘焙 JPEG 序列播放（纯逻辑，可离线自检）
 *
 * 为什么要有它：这块屏只认整帧 JPEG（见 usb/LyProtocol.ets），而本机实测每次
 * 4096B bulkTransfer 有 **~5.5ms 固定开销**、JPEG 编码 **~55ms/帧**，
 * 于是"实时渲染 + 编码"的天花板只有 ~6fps。把视频离线烘成 JPEG 帧序列后，
 * 运行时**零编码**、只把字节原样推出去，天花板抬到 ~8..16fps
 * （推导与实测见 .verify/video-seq/报告-预烘焙序列验证.md）。
 *
 * 本文件只放"不碰 USB、不碰网络"的纯策略：清单解析、帧间隔、游标推进、URL 拼装。
 * 拉帧（HTTP）在 LcdService，推帧（USB）在 usb/LcdUsb.ets。
 */

/** 原始（未信任）清单：每个字段都是 Object，逐项校验（同 common/Normalize.ets 的手法） */
export interface RawSeqManifest {
  name?: Object;
  count?: Object;
  fps?: Object;
  w?: Object;
  h?: Object;
  pattern?: Object;
  loop?: Object;
  rotate180?: Object;
}

/** 归一化后的清单 */
export class SeqManifest {
  name: string = 'seq';
  count: number = 0;
  fps: number = 12;
  w: number = 1920;
  h: number = 462;
  /** 帧文件名模板，%04d 换成 4 位序号 */
  pattern: string = 'f%04d.jpg';
  loop: boolean = true;
  /** 帧是否已在烘焙时按面板物理方向旋转过（本机 rotate180=true 时必须为 true） */
  rotate180: boolean = false;

  toString(): string {
    return `${this.name} ${this.count}帧 @${this.fps}fps ${this.w}x${this.h}`
      + `${this.loop ? ' loop' : ''}${this.rotate180 ? ' rot180' : ''}`;
  }
}

/** 播放状态机（LcdService 持有；状态变化都走这里，便于 /diag 取证） */
export class SeqState {
  /** idle | loading | playing | done | error */
  state: string = 'idle';
  /** 给人看的一句话（失败原因 / 进度） */
  msg: string = '';
  base: string = '';
  manifest: SeqManifest = new SeqManifest();
  frames: Uint8Array[] = [];
  cursor: number = 0;
  /** 本次最多拉多少帧（0 = 用清单的 count） */
  limit: number = 0;
  /** 载入耗时（ms） */
  loadMs: number = 0;
  /** 已推帧数 / 失败数 / 连续失败数 */
  pushed: number = 0;
  errors: number = 0;
  fails: number = 0;

  // ---- 边播边拉（stream=true）：帧不全驻内存，只用环形缓冲把窗口填满 ----
  /** true = 流式（内存只占 win 帧）；false = 一次性全拉进内存（默认，绝不抖动） */
  stream: boolean = false;
  /** 预取窗口（帧）。窗口越大越抗抖动，内存 = win × 每帧字节 */
  win: number = 24;
  /** 环形缓冲，容量 = min(count, win)；null = 该槽还没抓到 */
  buf: (Uint8Array | null)[] = [];
  /** 生产者：下一个要抓的帧号（跨圈累加，取模才是文件名） */
  head: number = 0;
  /** 消费者：下一个要播的帧号（跨圈累加） */
  tail: number = 0;
  /** 已抓帧数 / 缓冲不足导致本轮没推帧的次数 */
  fetched: number = 0;
  underruns: number = 0;
  /** 抓帧循环是否在跑（防止并发重入） */
  pumping: boolean = false;
}

/** 帧间隔上下限：太快会把 USB 端点灌爆（实测端点错误态、屏黑），太慢没有播放意义 */
export const SEQ_MIN_INTERVAL_MS: number = 16;    // 60fps 上限
export const SEQ_MAX_INTERVAL_MS: number = 2000;  // 0.5fps 下限
/** 一口气拉多少帧的内存上限：1920×462 q60 约 50~90KB/帧 */
export const SEQ_MAX_FRAMES: number = 480;
export const SEQ_DEFAULT_LIMIT: number = 120;
/** 流式模式的窗口上下限（帧）：太小会抖动，太大就失去"省内存"的意义 */
export const SEQ_MIN_WIN: number = 2;
export const SEQ_MAX_WIN: number = 120;
export const SEQ_DEFAULT_WIN: number = 24;

/** 环形缓冲容量：min(count, win)；两者都非法时至少 1 */
export function seqBufCap(count: number, win: number): number {
  const c = count > 0 ? count : 0;
  const w = win > 0 ? win : SEQ_DEFAULT_WIN;
  if (c <= 0) {
    return 0;
  }
  return Math.min(c, w);
}

/** 帧号 i（跨圈累加）落在环形缓冲的哪个槽 */
export function seqBufSlot(i: number, cap: number): number {
  if (cap <= 0) {
    return -1;
  }
  const s = i % cap;
  return s < 0 ? s + cap : s;
}

/**
 * 生产者能不能再抓一帧：缓冲里必须留出"还没播的槽"。
 * 不循环时还要看总帧数是否已抓完。
 */
export function seqCanFetch(head: number, tail: number, cap: number,
                            count: number, loop: boolean): boolean {
  if (cap <= 0 || count <= 0) {
    return false;
  }
  if (!loop && head >= count) {
    return false;
  }
  return (head - tail) < cap;
}

/** 播放是否该收工：不循环且生产者已抓完、消费者也追平 */
export function seqShouldStop(head: number, tail: number, count: number, loop: boolean): boolean {
  return !loop && tail >= count && head >= count;
}

/** 缓冲里现有多少帧（给 /diag 看填充度） */
export function seqBufFill(buf: (Uint8Array | null)[]): number {
  let n = 0;
  for (const f of buf) {
    if (f !== null && f !== undefined) {
      n++;
    }
  }
  return n;
}

/**
 * 该不该唤起抓帧：**半窗滞回**。
 *
 * 每推一帧就唤起一次的话，抓帧会变成"每帧插一次 HTTP"，实测把推帧耗时从 91ms 抬到
 * 182ms（win=8 那组，见 .verify/video-seq/bench_stream.json）—— 同一个 JS 线程里
 * 插进来的 HTTP 回调会拖慢正在 await 的 bulkTransfer。
 * 所以只在窗口掉到一半以下时唤起，让抓帧成批发生（一次抓半个窗口）。
 */
export function seqNeedsPump(head: number, tail: number, cap: number): boolean {
  if (cap <= 0) {
    return false;
  }
  const ahead = head - tail;
  return ahead <= Math.floor(cap / 2);
}

/** 极速模式（burst）的帧间隔：等于"不等"，USB 有多快就推多快 */
export const SEQ_BURST_INTERVAL_MS: number = 1;

/**
 * 播放时用的帧间隔：burst=true 时几乎不等（1ms），否则按帧率算。
 *
 * 为什么需要：帧循环是 `tick → setTimeout(间隔) → tick`，间隔**加在推帧耗时之外**
 * （实测 movie 序列推帧 58ms + 16ms 间隔 → 只有 11.4fps，而 58ms 本身能到 17fps）。
 * 想跑满 USB 就把间隔压到 1ms。
 */
export function seqPlayInterval(fps: number, burst: boolean): number {
  return burst ? SEQ_BURST_INTERVAL_MS : seqIntervalMs(fps);
}

/** 帧率 → 帧间隔（ms）；非法值按 12fps 处理，结果夹到 [SEQ_MIN, SEQ_MAX] */
export function seqIntervalMs(fps: number): number {
  let f = fps;
  if (!isFinite(f) || f <= 0) {
    f = 12;
  }
  const ms = Math.round(1000 / f);
  if (ms < SEQ_MIN_INTERVAL_MS) {
    return SEQ_MIN_INTERVAL_MS;
  }
  if (ms > SEQ_MAX_INTERVAL_MS) {
    return SEQ_MAX_INTERVAL_MS;
  }
  return ms;
}

/**
 * 下一个游标：
 *   · 负游标 = 从头（刚载入时用）
 *   · 播到末尾：loop → 0，不循环 → -1（调用方据此停机）
 *   · 空序列 → -1
 */
export function nextSeqCursor(cursor: number, count: number, loop: boolean): number {
  if (count <= 0) {
    return -1;
  }
  if (cursor < 0) {
    return 0;
  }
  const nx = cursor + 1;
  if (nx >= count) {
    return loop ? 0 : -1;
  }
  return nx;
}

/** 第 index 帧的 URL：base + '/' + pattern（%04d → 至少 4 位序号，超出不截断） */
export function seqFrameUrl(base: string, pattern: string, index: number): string {
  let b = base;
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  const pat = pattern.length > 0 ? pattern : 'f%04d.jpg';
  let s = `${index}`;
  while (s.length < 4) {
    s = '0' + s;
  }
  return `${b}/${pat.split('%04d').join(s)}`;
}

/** 本次实际要拉的帧数：limit>0 时取 limit 与 count 的较小者；夹到 [0, SEQ_MAX_FRAMES] */
export function seqFetchCount(count: number, limit: number): number {
  let n = limit > 0 ? Math.min(limit, count) : count;
  if (n > SEQ_MAX_FRAMES) {
    n = SEQ_MAX_FRAMES;
  }
  return n < 0 ? 0 : n;
}

/** 解析 manifest.json。类型不可信：逐项校验，缺字段用默认值；count<=0 视为非法。 */
export function parseSeqManifest(text: string): SeqManifest | null {
  let raw: RawSeqManifest;
  try {
    raw = JSON.parse(text) as RawSeqManifest;
  } catch (e) {
    return null;
  }
  if (raw === null || raw === undefined) {
    return null;
  }
  const m = new SeqManifest();
  const nm = raw.name;
  if (typeof nm === 'string' && (nm as string).length > 0) {
    m.name = nm as string;
  }
  const cnt = raw.count;
  if (typeof cnt === 'number' && isFinite(cnt as number)) {
    m.count = Math.floor(cnt as number);
  }
  const fp = raw.fps;
  if (typeof fp === 'number' && isFinite(fp as number) && (fp as number) > 0) {
    m.fps = fp as number;
  }
  const ww = raw.w;
  if (typeof ww === 'number' && isFinite(ww as number) && (ww as number) > 0) {
    m.w = Math.floor(ww as number);
  }
  const hh = raw.h;
  if (typeof hh === 'number' && isFinite(hh as number) && (hh as number) > 0) {
    m.h = Math.floor(hh as number);
  }
  const pt = raw.pattern;
  if (typeof pt === 'string' && (pt as string).length > 0) {
    m.pattern = pt as string;
  }
  const lp = raw.loop;
  if (typeof lp === 'boolean') {
    m.loop = lp as boolean;
  }
  const r180 = raw.rotate180;
  if (typeof r180 === 'boolean') {
    m.rotate180 = r180 as boolean;
  }
  if (m.count <= 0) {
    return null;
  }
  return m;
}

// ---- 自检（纯计算；由 /diag 的 seqSelfTest 字段暴露，独立于 usb/SelfTest.ets 的计数）----

class SeqCheck {
  name: string;
  ok: boolean;

  constructor(name: string, ok: boolean) {
    this.name = name;
    this.ok = ok;
  }
}

/** 返回 "通过/总数"，有失败则附失败清单（风格同 usb/SelfTest.ets） */
export function seqSelfTest(): string {
  const items: SeqCheck[] = [];
  items.push(new SeqCheck('interval:12fps=83ms', seqIntervalMs(12) === 83));
  items.push(new SeqCheck('interval:0fps 回退 12fps', seqIntervalMs(0) === 83));
  items.push(new SeqCheck('interval:夹住 60fps', seqIntervalMs(240) === SEQ_MIN_INTERVAL_MS));
  items.push(new SeqCheck('interval:夹住下限', seqIntervalMs(0.1) === SEQ_MAX_INTERVAL_MS));
  items.push(new SeqCheck('cursor:循环回 0', nextSeqCursor(9, 10, true) === 0));
  items.push(new SeqCheck('cursor:不循环 → -1', nextSeqCursor(9, 10, false) === -1));
  items.push(new SeqCheck('cursor:正常 +1', nextSeqCursor(3, 10, true) === 4));
  items.push(new SeqCheck('cursor:负游标从头', nextSeqCursor(-5, 10, false) === 0));
  items.push(new SeqCheck('cursor:空序列 → -1', nextSeqCursor(0, 0, true) === -1));
  items.push(new SeqCheck('url:补零',
    seqFrameUrl('http://h/s', 'f%04d.jpg', 7) === 'http://h/s/f0007.jpg'));
  items.push(new SeqCheck('url:去掉尾斜杠',
    seqFrameUrl('http://h/s/', 'g%04d.jpg', 12) === 'http://h/s/g0012.jpg'));
  items.push(new SeqCheck('url:超 4 位不截断',
    seqFrameUrl('b', '%04d.jpg', 12345) === 'b/12345.jpg'));
  const m = parseSeqManifest('{"name":"t","count":30,"fps":15,"w":1920,"h":462,"loop":false,"rotate180":true}');
  items.push(new SeqCheck('manifest:正常解析',
    m !== null && m.count === 30 && m.fps === 15 && !m.loop && m.rotate180 && m.w === 1920));
  items.push(new SeqCheck('manifest:count=0 非法', parseSeqManifest('{"count":0}') === null));
  items.push(new SeqCheck('manifest:坏 JSON → null', parseSeqManifest('not json') === null));
  items.push(new SeqCheck('manifest:count 非数字 → null',
    parseSeqManifest('{"count":"30","fps":"15"}') === null));
  items.push(new SeqCheck('fetch:limit 生效', seqFetchCount(200, 30) === 30));
  items.push(new SeqCheck('fetch:limit=0 用 count', seqFetchCount(30, 0) === 30));
  items.push(new SeqCheck('fetch:上限 480', seqFetchCount(1000, 0) === SEQ_MAX_FRAMES));
  // ---- 流式（边播边拉）----
  items.push(new SeqCheck('bufcap:取小者', seqBufCap(1000, 24) === 24));
  items.push(new SeqCheck('bufcap:count 更小', seqBufCap(10, 24) === 10));
  items.push(new SeqCheck('bufcap:非法 → 0', seqBufCap(0, 24) === 0));
  items.push(new SeqCheck('slot:取模', seqBufSlot(25, 24) === 1));
  items.push(new SeqCheck('slot:负数回正', seqBufSlot(-1, 24) === 23));
  items.push(new SeqCheck('canfetch:窗口没满', seqCanFetch(5, 0, 24, 100, true)));
  items.push(new SeqCheck('canfetch:窗口满 → 停', !seqCanFetch(24, 0, 24, 100, true)));
  items.push(new SeqCheck('canfetch:窗口滑动后可再抓', seqCanFetch(24, 1, 24, 100, true)));
  items.push(new SeqCheck('canfetch:不循环抓完即停', !seqCanFetch(100, 90, 24, 100, false)));
  items.push(new SeqCheck('canfetch:循环则继续', seqCanFetch(100, 90, 24, 100, true)));
  items.push(new SeqCheck('stop:不循环追平 → 停', seqShouldStop(100, 100, 100, false)));
  items.push(new SeqCheck('stop:循环不停', !seqShouldStop(100, 100, 100, true)));
  const b: (Uint8Array | null)[] = [new Uint8Array(1), null, new Uint8Array(1)];
  items.push(new SeqCheck('fill:只数非空', seqBufFill(b) === 2));
  items.push(new SeqCheck('pump:窗口满 → 不抓', !seqNeedsPump(24, 0, 24)));
  items.push(new SeqCheck('pump:掉到一半 → 抓', seqNeedsPump(12, 0, 24)));
  items.push(new SeqCheck('pump:刚过半 → 不抓', !seqNeedsPump(13, 0, 24)));
  items.push(new SeqCheck('pump:cap=0 → 不抓', !seqNeedsPump(0, 0, 0)));
  items.push(new SeqCheck('burst:极速=1ms', seqPlayInterval(10, true) === SEQ_BURST_INTERVAL_MS));
  items.push(new SeqCheck('burst:普通按帧率', seqPlayInterval(10, false) === 100));

  let pass = 0;
  const fails: string[] = [];
  for (const it of items) {
    if (it.ok) {
      pass++;
    } else {
      fails.push(it.name);
    }
  }
  return fails.length === 0 ? `${pass}/${items.length}` : `${pass}/${items.length} 失败: ${fails.join(', ')}`;
}
