/**
 * History.ets —— 极简数值历史（给"历史曲线"用）
 *
 * 为什么单独一个文件：曲线要的数据处理（环形缓冲、归一化、采样点换算）是**纯逻辑**，
 * 放在这里就能离线自检（不需要画布/设备），也避免和渲染代码搅在一起。
 */

/** 一条等间隔采样的数值曲线（环形缓冲，满了就丢最旧的） */
export class Series {
  private buf: number[] = [];
  private cap: number;
  /** 采样上限（用于纵轴归一化：比如 CPU 固定 0..100，token 速率则是动态最大值） */
  readonly fixedMax: number;

  constructor(cap: number, fixedMax: number = -1) {
    this.cap = cap > 0 ? cap : 1;
    this.fixedMax = fixedMax;
  }

  push(v: number): void {
    const x = isFinite(v) && v >= 0 ? v : 0;
    this.buf.push(x);
    while (this.buf.length > this.cap) {
      this.buf.shift();
    }
  }

  /** 采一次"未知"值（比如桥断了）—— 用 -1 表示断点，绘制时跳过 */
  pushGap(): void {
    this.push(-1);
  }

  get length(): number {
    return this.buf.length;
  }

  at(i: number): number {
    return (i >= 0 && i < this.buf.length) ? this.buf[i] : -1;
  }

  last(): number {
    return this.buf.length > 0 ? this.buf[this.buf.length - 1] : -1;
  }

  /** 有效样本（跳过断点）的最大值，至少 1（避免除零） */
  maxValid(): number {
    let m = 0;
    for (const v of this.buf) {
      if (v > m) {
        m = v;
      }
    }
    return m > 0 ? m : 1;
  }

  /** 纵轴上限：固定上限优先（CPU/内存用 100），否则用动态最大值 */
  scaleMax(): number {
    return this.fixedMax > 0 ? this.fixedMax : this.maxValid();
  }

  /**
   * 把第 i 个采样点映射成画布坐标（i 从 0 = 最旧）。
   * 返回 y；断点（-1）返回 -1，调用方负责断开折线。
   */
  pointY(i: number, y0: number, h: number, max: number): number {
    const v = this.at(i);
    if (v < 0) {
      return -1;
    }
    const m = max > 0 ? max : 1;
    const r = Math.max(0, Math.min(1, v / m));
    return y0 + h - h * r;
  }

  /** 采样点 x 坐标（按容量铺满，不足时也从左往右画，不拉伸） */
  pointX(i: number, x0: number, w: number, cap: number): number {
    const c = cap > 1 ? cap : 2;
    return x0 + w * (i / (c - 1));
  }
}

/** 屏上要画的三条曲线（都按固定的采样上限建环形缓冲） */
export class History {
  /** 采样上限：每 tick 采一次，容量 90 ≈ 保持最近一段时间的走势 */
  static readonly CAP: number = 90;

  cpu: Series = new Series(History.CAP, 100);
  mem: Series = new Series(History.CAP, 100);
  /** token 速率（每分钟），量级不固定 → 动态纵轴 */
  tokens: Series = new Series(History.CAP);
  /** 余额曲线（动态纵轴，用来画"钱在往下掉"） */
  balance: Series = new Series(History.CAP);

  /** 采样间隔控制：避免每个 tick 都记（默认 2 秒一个点） */
  private lastAt: number = 0;
  static readonly SAMPLE_MS: number = 2000;

  /**
   * 每个 tick 调一次；到采样间隔才真的记一笔。
   * 返回是否真的采样了（决定要不要重绘）。
   */
  sample(now: number, cpuPct: number, memPct: number, tokensPerMin: number,
         balanceTotal: number): boolean {
    if (this.lastAt !== 0 && now - this.lastAt < History.SAMPLE_MS) {
      return false;
    }
    this.lastAt = now;
    this.cpu.push(cpuPct);
    this.mem.push(memPct);
    if (tokensPerMin >= 0) {
      this.tokens.push(tokensPerMin);
    } else {
      this.tokens.pushGap();
    }
    if (balanceTotal >= 0) {
      this.balance.push(balanceTotal);
    } else {
      this.balance.pushGap();
    }
    return true;
  }
}
