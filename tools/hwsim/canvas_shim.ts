// canvas_shim.ts —— 给"真源码布局审计"用的 CanvasRenderingContext2D 打桩
//
// 为什么需要它：以前 tools/layout_check.py 审计的是 tools/preview.py（**手工镜像**），
// 改真源码 Dashboard.ets 时镜像不会跟着动 —— 结果是"审计通过"但真机上早就重叠了
// （1.8× 字号那一轮就踩了：改了 ArkTS，审计报的问题一模一样，因为它在看旧镜像）。
//
// 这个桩把 Dashboard 真正调用的那些 canvas API 都实现一遍，并记录：
//   · 每次 fillText/strokeText 的文字、坐标、字号、对齐 → 真实渲染包围盒
//   · moveTo/lineTo/arc/roundRect 等几何 → 边界（用于"压到分隔线"的检查）
// 于是 layout_check.py 可以审计**真源码**，镜像副本可以退休。
//
// 度量说明：Node 里没有字体引擎，measureText 用"按字符类型的经验宽度"估：
// 中日韩全角按 1.0em、ASCII 按 0.56em、空格 0.28em。审计关心的是"有没有重叠/越界"
// （差几个像素不影响结论），所以近似够用；真机最终观感仍以肉眼为准。

export interface TextBox {
  text: string;
  x: number;          // 记录时的锚点
  y: number;
  size: number;       // 字号（px）
  weight: string;
  align: string;
  baseline: string;
  left: number; top: number; right: number; bottom: number;
}

export interface LineSeg { x1: number; y1: number; x2: number; y2: number; kind: string; src?: string; }
export interface RectSeg { x: number; y: number; w: number; h: number; kind: string; }

function charWidth(ch: string, size: number): number {
  const c = ch.codePointAt(0) ?? 32;
  if (c > 0x2e80) return size;                 // 中日韩/全角
  if (ch === ' ') return size * 0.28;
  if (c >= 0x30 && c <= 0x39) return size * 0.55;  // 数字
  if (c >= 0x41 && c <= 0x5a) return size * 0.66;  // 大写
  return size * 0.56;
}

export function textWidth(s: string, size: number): number {
  let w = 0;
  for (const ch of s) w += charWidth(ch, size);
  return w;
}

/** 解析 'bold 30px monospace' 这类 font 字符串 */
function parseFont(f: string): { size: number; weight: string } {
  const m = /(\d+(?:\.\d+)?)px/.exec(f);
  const size = m ? Number(m[1]) : 16;
  const weight = /bold/i.test(f) ? 'bold' : 'normal';
  return { size, weight };
}


/**
 * 仿射矩阵 [a,b,c,d,e,f]：x' = a*x + c*y + e ; y' = b*x + d*y + f
 *
 * 为什么必须支持变换：主题 4「打砖块」用 ctx.translate+ctx.scale 把源画布（368×448）
 * 画进游戏区。桩如果忽略变换，砖块/时间就会被记在**源坐标**上（x≈43），
 * 审计于是报出"文字压到色块"这类**假问题**。这里让几何与文字都走矩阵。
 */
type Mat = [number, number, number, number, number, number];
const IDENT: Mat = [1, 0, 0, 1, 0, 0];
function matMul(m: Mat, n: Mat): Mat {
  return [
    m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]
  ];
}
function applyPt(m: Mat, x: number, y: number): [number, number] {
  return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
}
/** 平均缩放（用于半径） */
function applyScale(m: Mat, r: number): number {
  return r * (Math.hypot(m[0], m[1]) + Math.hypot(m[2], m[3])) / 2;
}

export class Ctx2DShim {
  texts: TextBox[] = [];
  lines: LineSeg[] = [];
  rects: RectSeg[] = [];
  fills: string[] = [];

  font = 'normal 16px sans-serif';
  fillStyle: any = '#000';
  strokeStyle: any = '#000';
  lineWidth = 1;
  globalAlpha = 1;
  textAlign = 'left';
  textBaseline = 'alphabetic';

  private path: Array<[number, number]> = [];
  private cur: [number, number] = [0, 0];
  private stack: any[] = [];
  /** 当前变换矩阵（save/restore 会一起存取） */
  private m: Mat = IDENT.slice() as Mat;
  /** roundRect 内部也会走 moveTo/lineTo —— 那些边不算"分隔线"，
   *  否则审计会把"文字压在色块上边缘"当成"文字压线"误报（实测误报过 7 条）*/
  private inShape = false;

  // ---- 状态 ----
  save(): void {
    this.stack.push({ font: this.font, fillStyle: this.fillStyle, m: this.m.slice() as Mat });
  }
  restore(): void {
    const s = this.stack.pop();
    if (s) { this.font = s.font; this.fillStyle = s.fillStyle; this.m = s.m; }
  }
  translate(x: number, y: number): void { this.m = matMul(this.m, [1, 0, 0, 1, x, y]); }
  rotate(a: number): void {
    this.m = matMul(this.m, [Math.cos(a), Math.sin(a), -Math.sin(a), Math.cos(a), 0, 0]);
  }
  scale(x: number, y: number): void { this.m = matMul(this.m, [x, 0, 0, y, 0, 0]); }
  getLineDash(): number[] { return []; }
  setLineDash(_seg: number[]): void { /* 审计不关心虚线 */ }
  setTransform(a: number, b: number, c: number, d: number, e: number, f: number): void {
    this.m = [a, b, c, d, e, f];
  }
  clip(): void { }
  beginPath(): void { this.path = []; }
  closePath(): void { }
  moveTo(x: number, y: number): void {
    this.cur = applyPt(this.m, x, y);
    this.path.push(this.cur);
  }
  lineTo(x: number, y: number): void {
    // 记一个调用点：审计报"某条线被压"时能直接指出是 Dashboard 里哪一行画的
    const st = new Error().stack ?? '';
    const mm = /Dashboard\.ts:(\d+):/.exec(st);
    const to = applyPt(this.m, x, y);
    this.lines.push({ x1: this.cur[0], y1: this.cur[1], x2: to[0], y2: to[1],
                      kind: this.inShape ? 'shape' : 'line',
                      src: mm ? ('Dashboard.ts:' + mm[1]) : '' });
    this.cur = to; this.path.push(to);
  }
  quadraticCurveTo(cx: number, cy: number, x: number, y: number): void {
    const to = applyPt(this.m, x, y);
    this.lines.push({ x1: this.cur[0], y1: this.cur[1], x2: to[0], y2: to[1],
                      kind: this.inShape ? 'shape' : 'line' });
    this.cur = to; this.path.push(to);
  }
  arc(x: number, y: number, r: number, _a0: number, _a1: number): void {
    const p = applyPt(this.m, x, y);
    const rr = applyScale(this.m, r);
    this.rects.push({ x: p[0] - rr, y: p[1] - rr, w: rr * 2, h: rr * 2, kind: 'arc' });
  }
  roundRect(x: number, y: number, w: number, h: number, _r?: number): void {
    const p = applyPt(this.m, x, y);
    const sx = Math.hypot(this.m[0], this.m[1]);
    const sy = Math.hypot(this.m[2], this.m[3]);
    this.rects.push({ x: p[0], y: p[1], w: w * sx, h: h * sy, kind: 'roundRect' });
    // 真实实现内部会走路径命令：这里用 inShape 标记，避免污染"分隔线"判定
    this.inShape = true;
    this.moveTo(x, y); this.lineTo(x + w, y); this.lineTo(x + w, y + h);
    this.lineTo(x, y + h); this.lineTo(x, y);
    this.inShape = false;
  }
  rect(x: number, y: number, w: number, h: number): void {
    const p = applyPt(this.m, x, y);
    const sx = Math.hypot(this.m[0], this.m[1]);
    const sy = Math.hypot(this.m[2], this.m[3]);
    this.rects.push({ x: p[0], y: p[1], w: w * sx, h: h * sy, kind: 'rect' });
  }
  fillRect(x: number, y: number, w: number, h: number): void {
    const p = applyPt(this.m, x, y);
    const sx = Math.hypot(this.m[0], this.m[1]);
    const sy = Math.hypot(this.m[2], this.m[3]);
    this.fills.push(String(this.fillStyle));
    this.rects.push({ x: p[0], y: p[1], w: w * sx, h: h * sy, kind: 'fillRect' });
  }
  strokeRect(x: number, y: number, w: number, h: number): void {
    const p = applyPt(this.m, x, y);
    const sx = Math.hypot(this.m[0], this.m[1]);
    const sy = Math.hypot(this.m[2], this.m[3]);
    this.rects.push({ x: p[0], y: p[1], w: w * sx, h: h * sy, kind: 'strokeRect' });
  }
  fill(): void { this.fills.push(String(this.fillStyle)); }
  stroke(): void { }
  createRadialGradient(_x0: number, _y0: number, _r0: number, _x1: number, _y1: number,
                       _r1: number): any {
    return { addColorStop: (_o: number, _c: string): void => { /* 只关心几何，不关心颜色 */ } };
  }

  createLinearGradient(_x0: number, _y0: number, _x1: number, _y1: number): any {
    return { addColorStop: () => { } };
  }
  drawImage(): void { /* VM 画面：不参与文字审计 */ }

  measureText(s: string): { width: number } {
    return { width: textWidth(s, parseFont(this.font).size) };
  }

  // ---- 文字：记录真实包围盒 ----
  private record(text: string, x: number, y: number): void {
    const { size: rawSize, weight } = parseFont(this.font);
    const size = applyScale(this.m, rawSize);      // 变换会把字号一起缩放
    const p = applyPt(this.m, x, y);
    x = p[0];
    y = p[1];
    const w = textWidth(text, size);
    // ★ 字高近似取 0.72em（2026-10-15 修）：
    //   原来写 `h = size`（1.0em），而**真实字形的视觉高度约 0.72em**
    //   （含上下伸部的全高约 1.0em，但文字框实际不会占满）。
    //   用 1.0em 会让"上下相邻两行"被误判成重叠：
    //   例 NanoMuse 的标签在 y+22、值在 y+h-40，字号 72 → 框高 72，
    //   于是标签框底(≈118) 压过值框顶(≈86)，报一堆 75% 假重叠。
    //   0.72em 后相邻两行不再互相咬合，而真正的同行重叠仍能报出来。
    const h = size * 0.72;
    let left = x;
    if (this.textAlign === 'center') left = x - w / 2;
    else if (this.textAlign === 'right') left = x - w;
    let top = y;
    if (this.textBaseline === 'middle') top = y - h / 2;
    else if (this.textBaseline === 'top') top = y;
    else top = y - h * 0.8;               // alphabetic / bottom：基线在下方
    this.texts.push({
      text, x, y, size, weight,
      align: this.textAlign, baseline: this.textBaseline,
      left, top, right: left + w, bottom: top + h
    });
  }

  fillText(text: string, x: number, y: number): void { this.record(String(text), x, y); }
  strokeText(text: string, x: number, y: number): void { this.record(String(text), x, y); }
}

export function makeShim(): Ctx2DShim {
  return new Ctx2DShim();
}
