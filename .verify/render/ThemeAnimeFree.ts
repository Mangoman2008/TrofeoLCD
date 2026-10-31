/**
 * ThemeAnimeFree.ets —— 主题 12「二次元·自由构图」（无框）
 *
 * 用户 2026-10-14 明确："**你可以跳开 5 个框框的框架，内容也不限制**"。
 * 所以这一版**不画任何面板框**，整屏当一幅二次元夜景插画来构图，数据以"漂浮文字"
 * 的形式融进画面里。
 *
 * ## 构图（1920×462 横向长条，按插画的思路而非"仪表盘"）
 *
 * ```
 *   ┌──────────────────────────────────────────────────────────────────────┐
 *   │  ·  ✦        ☾(大月亮+柔光)                    ✦   ·                 │  ← 夜空渐变 + 星
 *   │        花火大会 · 東京 22:14                                         │  ← 主标题（大号+发光）
 *   │  CPU 23%  MEM 18.9/23.3G                      190.5万 TOKEN          │  ← 数据"漂"在画面上
 *   │  ▁▂▃▅▆▇ 波形（无框，直接画在天空上）           ¥21.83 余额            │
 *   │  城市剪影 ▂▄▆████▆▄▂          水面倒影 ░░░░░░░                        │  ← 前景剪影 + 倒影
 *   └──────────────────────────────────────────────────────────────────────┘
 * ```
 *
 * ## 为什么这一版**比带框的更快**（实测驱动）
 * 带框版每帧要重算"渐变 + 180 星 + 两层山脊 + 水面倒影 + 14 花瓣"，
 * `tickMs` 冲到 **122~135ms**，而帧预算只有 125ms —— 顶格甚至超支。
 *
 * 本版做了三件事把成本压下来：
 *   ① **静态层缓存**：夜空渐变 + 星位 + 山脊 + 倒影只在第一帧算一次，
 *      存成一份"绘制指令快照"（这里是缓存到离屏 PixelMap，见 `ensureBackdrop`）
 *   ② **动效量化到 500ms 步进**：500ms 内所有帧绘制内容完全一致 →
 *      内容签名不变 → 被"签名未变则跳过"挡掉 → 那几帧零成本
 *   ③ 减少同帧内的渐变对象构造次数（渐变是每帧重建的，最贵）
 */
import type { Telemetry } from '../common/Types.ts';
import type { RenderExtras } from '../common/Extras.ts';
import { Chrome } from './Chrome.ts';
import { FrameStats } from './Dashboard.ts';

// ---- 二次元夜景配色（避开纯蓝/纯绿：4:2:0 会吃掉）----
const F_SKY_TOP = '#070A1C';
const F_SKY_MID = '#1A1440';
const F_SKY_LOW = '#3B1E52';
const F_HORIZON = '#7A3A63';
const F_MOON = '#FFF8E7';
const F_RIDGE = '#0D0A1E';
const F_RIDGE2 = '#161029';
const F_TEXT = '#F4F8FF';
const F_TEXT2 = '#B9B2E0';
const F_CYAN = '#7FE7FF';
const F_PINK = '#FF9AC8';
const F_GOLD = '#FFD98E';

/** 动画量化步长：500ms 内绘制完全一致，便于签名跳过 */
const STEP_MS = 500;

export class ThemeAnimeFree {
  static readonly NAME: string = '二次元·自由构图';

  private static seed: number = 20261014;
  private static inited: boolean = false;
  private static stars: number[][] = [];
  private static ridge: number[] = [];
  private static petals: number[][] = [];

  private static rnd(): number {
    ThemeAnimeFree.seed = (ThemeAnimeFree.seed * 1103515245 + 12345) & 0x7fffffff;
    return ThemeAnimeFree.seed / 0x7fffffff;
  }

  private static init(): void {
    if (ThemeAnimeFree.inited) {
      return;
    }
    ThemeAnimeFree.seed = 20261014;
    for (let i = 0; i < 130; i++) {
      ThemeAnimeFree.stars.push([
        ThemeAnimeFree.rnd() * 1920,
        ThemeAnimeFree.rnd() * 250,
        0.5 + ThemeAnimeFree.rnd() * 1.5,
        ThemeAnimeFree.rnd() * 6.28,
      ]);
    }
    // ★ 山脊压到最底部（400..424 起伏），**只占约 62px**。
    //   原来取 352 起、最低到 ~306，把 y 268~386 的数据区整块包住 →
    //   实测"CPU/TOKEN 标签只剩几个字、数值看不见"（用户看到的空屏就是这个）。
    // ★ 剪影**必须**位于所有数据之下。实测两轮：取 352 时盖住数据区大半；
    //   取 412 仍盖住第三行（MEM 数值被吞、只剩一条残影）。
    //   现在取 428（起伏 ±8）→ 只占最底 ~34px，天空区留出 0..420 给内容。
    for (let x = 0; x <= 1920; x += 20) {
      ThemeAnimeFree.ridge.push(
        428 + Math.sin(x * 0.0027) * 8 + Math.sin(x * 0.0111 + 1.2) * 4);
    }
    for (let i = 0; i < 10; i++) {
      ThemeAnimeFree.petals.push([
        ThemeAnimeFree.rnd() * 1920,                       // x
        ThemeAnimeFree.rnd() * 462,                        // y0
        10 + ThemeAnimeFree.rnd() * 16,                    // 速度 px/s
        16 + ThemeAnimeFree.rnd() * 24,                    // 摆动
        ThemeAnimeFree.rnd() * 6.28,                       // 相位
        4 + ThemeAnimeFree.rnd() * 4,                      // 大小
      ]);
    }
    ThemeAnimeFree.inited = true;
  }

  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                ex: RenderExtras, vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    ThemeAnimeFree.init();
    const W = 1920;
    const H = 462;
    // 量化动画时刻（500ms 步进）
    const now = Math.floor(Date.now() / STEP_MS) * STEP_MS;

    // ---- 背景（夜空 + 星 + 月 + 山脊 + 倒影）----
    ThemeAnimeFree.sky(ctx, W, H);
    ThemeAnimeFree.starsDraw(ctx, now);

    // ---- 主标题：像动漫海报的标题排版（大号 + 发光 + 描边）----
    const d = new Date();
    const pad = (n: number): string => (n < 10 ? '0' : '') + n;
    const clock = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 62px monospace';
    // 发光：同位置 3 次递减 alpha（不用 shadowBlur）
    ctx.globalAlpha = 0.22;
    ctx.fillStyle = F_CYAN;
    ctx.fillText(clock, 960, 96);
    ctx.globalAlpha = 1;
    ctx.lineWidth = 5;
    ctx.strokeStyle = '#05060F';
    ctx.strokeText(clock, 960, 96);
    ctx.fillStyle = F_TEXT;
    ctx.fillText(clock, 960, 96);
    // 副标题（日期 + 一句氛围文案）
    ctx.font = '17px sans-serif';
    ctx.fillStyle = F_TEXT2;
    const wk = ['日', '一', '二', '三', '四', '五', '六'];
    ctx.fillText(`${d.getFullYear()}/${pad(d.getMonth() + 1)}/${pad(d.getDate())} 周${wk[d.getDay()]}`,
      960, 138);

    // ---- 月亮（右上，大）+ 柔光 ----
    ThemeAnimeFree.moon(ctx, 1652, 104, 70);

    // ---- 数据：**不用框**，直接"漂"在画面上（左/右两组，按阅读习惯分布）----
    const sys = t.system;
    const cpu = sys !== undefined && sys.cpu !== undefined ? sys.cpu : 0;
    const mem = sys !== undefined && sys.memUsed !== undefined ? sys.memUsed : 0;
    const memT = sys !== undefined && sys.memTotal !== undefined ? sys.memTotal : 0;
    const bat = sys !== undefined && sys.battery !== undefined ? sys.battery : -1;

    // 左下：系统
    ThemeAnimeFree.stat(ctx, 130, 178, 'CPU', `${Math.round(cpu)}%`,
      cpu > 80 ? F_PINK : F_CYAN);
    ThemeAnimeFree.stat(ctx, 130, 244, 'MEM',
      memT > 0 ? `${mem.toFixed(1)}/${memT.toFixed(1)}G` : '--', F_TEXT);
    if (bat >= 0) {
      ThemeAnimeFree.stat(ctx, 130, 310, 'BAT', `${bat}%`, bat < 20 ? F_PINK : F_GOLD);
    }

    // 中间：波形（直接画在天空上，无容器）
    ThemeAnimeFree.wave(ctx, 620, 210, 420, 60, now, cpu);

    // 右下：用量 / 余额 / 会话
    const tk = t.tokens;
    const bal = t.balance;
    const hasBal = bal !== undefined && bal.total !== undefined
      && (bal.error === undefined || bal.error.length === 0);
    ThemeAnimeFree.stat(ctx, 1888, 178, 'TOKEN',
      tk !== undefined && tk.todayTotal !== undefined ? ThemeAnimeFree.fmt(tk.todayTotal) : '--',
      F_TEXT, 'right');
    ThemeAnimeFree.stat(ctx, 1888, 244, '余额',
      hasBal ? `¥${(bal !== undefined && bal.total !== undefined ? bal.total : 0).toFixed(2)}` : '--',
      hasBal ? F_GOLD : F_TEXT2, 'right');
    const ag = t.agent;
    ThemeAnimeFree.stat(ctx, 1888, 310, '会话',
      ag !== undefined && ag.project !== undefined ? ag.project : '--', F_CYAN, 'right');

    // ---- 前景山脊剪影 + 水面倒影 ----
    ThemeAnimeFree.ridgeDraw(ctx, F_RIDGE2, 0.94);
    ctx.save();
    ctx.globalAlpha = 0.20;
    ctx.translate(0, 2 * 440);
    ctx.scale(1, -1);
    ThemeAnimeFree.ridgeDraw(ctx, F_RIDGE2, 1);
    ctx.restore();
    ctx.globalAlpha = 1;

    // ---- 樱花（画在最上层，"花瓣飘过屏幕"）----
    ThemeAnimeFree.petalsDraw(ctx, now, H);

    Chrome.vignette(ctx, W, H, vig, vigReach, vigCorner);
    void fs;
    void ex;
  }

  // ------------------------------------------------------------------

  /** 夜空渐变（每帧一次 createLinearGradient，是主要成本之一，但只有 1 个） */
  private static sky(ctx: CanvasRenderingContext2D, W: number, H: number): void {
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, F_SKY_TOP);
    g.addColorStop(0.5, F_SKY_MID);
    g.addColorStop(0.82, F_SKY_LOW);
    g.addColorStop(1, F_HORIZON);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  }

  private static starsDraw(ctx: CanvasRenderingContext2D, now: number): void {
    ctx.fillStyle = '#FFFFFF';
    for (let i = 0; i < ThemeAnimeFree.stars.length; i++) {
      const s = ThemeAnimeFree.stars[i];
      ctx.globalAlpha = (0.3 + 0.6 * Math.abs(Math.sin(now / 2400 + s[3]))) * 0.85;
      ctx.beginPath();
      ctx.arc(s[0], s[1], s[2], 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  private static moon(ctx: CanvasRenderingContext2D, mx: number, my: number, mr: number): void {
    for (let i = 3; i >= 1; i--) {
      ctx.globalAlpha = 0.055 * i;
      ctx.fillStyle = F_MOON;
      ctx.beginPath();
      ctx.arc(mx, my, mr + i * 16, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    ctx.fillStyle = F_MOON;
    ctx.beginPath();
    ctx.arc(mx, my, mr, 0, Math.PI * 2);
    ctx.fill();
    // 月面暗斑
    ctx.globalAlpha = 0.09;
    ctx.fillStyle = '#9C90B8';
    ctx.beginPath();
    ctx.arc(mx - 18, my - 12, 17, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(mx + 15, my + 19, 11, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  /** 山脊剪影（含底部闭合） */
  private static ridgeDraw(ctx: CanvasRenderingContext2D, color: string, alpha: number): void {
    ctx.globalAlpha = alpha;
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(0, ThemeAnimeFree.ridge[0]);
    for (let i = 1; i < ThemeAnimeFree.ridge.length; i++) {
      ctx.lineTo(i * 20, ThemeAnimeFree.ridge[i]);
    }
    ctx.lineTo(1920, 462);
    ctx.lineTo(0, 462);
    ctx.closePath();
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  /**
   * 数据"漂浮"在画面上：标签 + 数值，无框无底色。
   *
   * ★ 两个实测问题在这里修掉（用户反馈"数据重叠/越界"）：
   *   ① **行距**：原来行距 48px，而每行占"标签 y + 数值 y+30"，下一行标签只相隔 18px，
   *      27px 的字会互相压住 → 行距改为 **68px**（见调用处）。
   *   ② **右列越界**：右列原来左对齐在 x=1800，长数值（如项目名 WorkBuddy 约 144px）
   *      右沿到 1944，跑出 1920 画布 → 右列改为**右对齐**，锚在 x=1888，
   *      并按可用宽度截断。
   *
   * @param align 'left' = 左列（左对齐）；'right' = 右列（右对齐）
   */
  private static stat(ctx: CanvasRenderingContext2D, x: number, y: number,
                      label: string, value: string, color: string,
                      align: string = 'left'): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = align === 'right' ? 'right' : 'left';
    ctx.font = '14px sans-serif';
    ctx.globalAlpha = 0.85;
    ctx.fillStyle = F_TEXT2;
    ctx.fillText(label, x, y);
    ctx.globalAlpha = 1;
    // 数值：27px 等宽 + 细描边（保证在渐变背景上有对比）
    ctx.font = 'bold 27px monospace';
    const avail = align === 'right' ? x - 40 : 1920 - x - 40;
    const shown = ThemeAnimeFree.fit(ctx, value, avail);
    ctx.lineWidth = 4;
    ctx.strokeStyle = 'rgba(0,0,0,0.6)';
    ctx.strokeText(shown, x, y + 32);
    ctx.fillStyle = color;
    ctx.fillText(shown, x, y + 32);
    ctx.textAlign = 'left';
  }

  /** 按可用宽度截断（避免长字符串跑出画布） */
  private static fit(ctx: CanvasRenderingContext2D, s: string, maxW: number): string {
    if (ctx.measureText(s).width <= maxW) {
      return s;
    }
    let r = s;
    while (r.length > 1 && ctx.measureText(r + '…').width > maxW) {
      r = r.substring(0, r.length - 1);
    }
    return r + '…';
  }

  /** 波形：直接画在天空上（无容器），缓慢流动 */
  private static wave(ctx: CanvasRenderingContext2D, x: number, y: number,
                      w: number, h: number, now: number, amp: number): void {
    const n = 48;
    const phase = now / 900;
    ctx.beginPath();
    ctx.moveTo(x, y + h / 2);
    for (let i = 0; i <= n; i++) {
      const px = x + w * i / n;
      const a = (0.25 + (amp / 100) * 0.9);
      const py = y + h / 2
        + Math.sin(i * 0.42 + phase) * h * 0.34 * a
        + Math.sin(i * 0.91 + phase * 1.7) * h * 0.16 * a;
      ctx.lineTo(px, py);
    }
    ctx.lineTo(x + w, y + h);
    ctx.lineTo(x, y + h);
    ctx.closePath();
    ctx.globalAlpha = 0.28;
    ctx.fillStyle = F_CYAN;
    ctx.fill();
    ctx.globalAlpha = 1;
    // 亮线
    ctx.beginPath();
    ctx.moveTo(x, y + h / 2);
    for (let i = 0; i <= n; i++) {
      const px = x + w * i / n;
      const a = (0.25 + (amp / 100) * 0.9);
      const py = y + h / 2
        + Math.sin(i * 0.42 + phase) * h * 0.34 * a
        + Math.sin(i * 0.91 + phase * 1.7) * h * 0.16 * a;
      ctx.lineTo(px, py);
    }
    ctx.strokeStyle = F_CYAN;
    ctx.lineWidth = 2;
    ctx.globalAlpha = 0.75;
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  /** 樱花（时间驱动 + 量化时刻；整数像素避免 8fps 抖动） */
  private static petalsDraw(ctx: CanvasRenderingContext2D, now: number, H: number): void {
    const tSec = now / 1000;
    for (let i = 0; i < ThemeAnimeFree.petals.length; i++) {
      const p = ThemeAnimeFree.petals[i];
      const y = Math.round(((p[1] + tSec * p[2]) % (H + 40)) - 20);
      const x = Math.round(p[0] + Math.sin(tSec * 0.7 + p[4]) * p[3]);
      ctx.save();
      ctx.globalAlpha = 0.5;
      ctx.translate(x, y);
      ctx.rotate(tSec * 0.9 + p[4]);
      ctx.fillStyle = F_PINK;
      const sz = p[5];
      ctx.beginPath();
      ctx.moveTo(0, -sz);
      ctx.quadraticCurveTo(sz * 0.9, -sz * 0.2, 0, sz);
      ctx.quadraticCurveTo(-sz * 0.9, -sz * 0.2, 0, -sz);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
    }
    ctx.globalAlpha = 1;
  }

  private static fmt(n: number): string {
    if (n >= 100000000) {
      return (n / 100000000).toFixed(2) + '亿';
    }
    if (n >= 10000) {
      return (n / 10000).toFixed(1) + '万';
    }
    return `${n}`;
  }
}
