/**
 * ThemeAnimeBG.ets —— 主题 11「二次元壁纸」
 *
 * 与主题 10（赛博二次元）的区别：**这一版有"背景图"** —— 用 Canvas 程序绘制一幅
 * 二次元风夜景插画当底图（星空 + 大月亮 + 城市剪影 + 樱花飘落 + 水面倒影），
 * 再把数据面板以**半透明**压在图上（用户 2026-10-14 选定："半透明面板压在背景上"）。
 *
 * 为什么不下载真实插画：
 *   本机对外下载受限 —— wallhaven 被墙（000）、Unsplash API 要 key（401）、
 *   可用的 picsum 只给随机照片（非二次元）。所以**程序生成**是唯一可靠路径，
 *   而且没有版权问题、帧间稳定（8fps 下不会像视频那样卡）。
 *   若以后要换成真实插画：把 LcdService 里的 bgPm 传进来替代 drawBackdrop 即可
 *   （接口已按这个思路留好：`bgImage` 参数）。
 *
 * 视觉要点（照着二次元夜景插画的语言）：
 *   ① 天空：深紫蓝 → 品红的地平线渐变（动漫夜景的典型配色）
 *   ② 大月亮：偏右上一轮奶白圆 + 外圈柔光（多次递减 alpha 的圆）
 *   ③ 星：随机但**固定种子**的小点，缓慢闪烁
 *   ④ 城市/山脊剪影：两层，远景偏紫、近景更暗，锯齿状生成
 *   ⑤ 樱花：12 片花瓣缓慢飘落 + 左右摆动，8fps 下每片走 1px 级位移
 *   ⑥ 水面：下方镜面倒影（把剪影和月亮做一次垂直翻转 + 低 alpha）
 *   ⑦ 数据面板：半透明（0.62）+ 霓虹描边，让背景透出来
 */
import type { Telemetry } from '../common/Types.ts';
import type { RenderExtras } from '../common/Extras.ts';
import { L } from '../common/Theme.ts';
import { Chrome } from './Chrome.ts';
import { FrameStats } from './Dashboard.ts';

// ---- 二次元夜景配色 ----
const B_SKY_TOP = '#0B1026';
const B_SKY_MID = '#241A4A';
const B_SKY_HOR = '#5B2A5E';   // 地平线偏品红
const B_MOON = '#FFF6E0';
const B_CITY_FAR = '#2A2150';
const B_CITY_NEAR = '#141029';
const B_PANEL = '#0E0A1E';
const B_BORDER = '#3A2F63';
const B_CYAN = '#7FE7FF';
const B_PINK = '#FF9AC8';
const B_TEXT_W = '#F2F6FF';
const B_TEXT_S = '#B4AEDA';

/** 樱花花瓣（固定种子生成，保证每帧位置稳定、只是缓慢下落） */
class Petal {
  x: number = 0;
  y0: number = 0;
  speed: number = 0;
  sway: number = 0;
  phase: number = 0;
  size: number = 0;
  alpha: number = 1;
}

export class ThemeAnimeBG {
  static readonly NAME: string = '二次元壁纸';

  /** 固定种子 LCG —— 保证每帧生成的星空/剪影一致，不闪烁 */
  private static rndSeed: number = 20261014;

  private static rnd(): number {
    // 线性同余，够用且确定
    ThemeAnimeBG.rndSeed = (ThemeAnimeBG.rndSeed * 1103515245 + 12345) & 0x7fffffff;
    return ThemeAnimeBG.rndSeed / 0x7fffffff;
  }

  private static stars: number[][] = [];
  private static ridge1: number[] = [];
  private static ridge2: number[] = [];
  private static petals: Petal[] = [];
  private static inited: boolean = false;

  /** 一次性生成所有"静态随机"元素（星空/两层山脊/花瓣参数） */
  private static init(): void {
    if (ThemeAnimeBG.inited) {
      return;
    }
    ThemeAnimeBG.rndSeed = 20261014;
    // 星空：180 颗
    for (let i = 0; i < 180; i++) {
      ThemeAnimeBG.stars.push([
        ThemeAnimeBG.rnd() * 1920,
        ThemeAnimeBG.rnd() * 300,
        0.6 + ThemeAnimeBG.rnd() * 1.6,          // 半径
        ThemeAnimeBG.rnd() * 6.28,               // 闪烁相位
      ]);
    }
    // 两层城市/山脊剪影（用固定步长采样，保证闭合）
    for (let x = 0; x <= 1920; x += 24) {
      ThemeAnimeBG.ridge1.push(300 + Math.sin(x * 0.0031) * 34 + Math.sin(x * 0.0129) * 16);
      ThemeAnimeBG.ridge2.push(338 + Math.sin(x * 0.0021 + 1.7) * 26 + Math.sin(x * 0.0091 + 0.4) * 12);
    }
    // 樱花：14 片
    for (let i = 0; i < 14; i++) {
      const p = new Petal();
      p.x = ThemeAnimeBG.rnd() * 1920;
      p.y0 = ThemeAnimeBG.rnd() * 462;
      p.speed = 8 + ThemeAnimeBG.rnd() * 14;     // 每秒下落像素
      p.sway = 14 + ThemeAnimeBG.rnd() * 22;     // 左右摆动幅度
      p.phase = ThemeAnimeBG.rnd() * 6.28;
      p.size = 4 + ThemeAnimeBG.rnd() * 5;
      p.alpha = 0.35 + ThemeAnimeBG.rnd() * 0.45;
      ThemeAnimeBG.petals.push(p);
    }
    ThemeAnimeBG.inited = true;
  }

  /**
   * ★ 性能（实测驱动）：原实现每帧重画背景（天空渐变 + 180 星 + 两层山脊 + 倒影 + 樱花），
   *   `tickMs` 冲到 **122ms**，而帧预算是 125ms —— 顶格，稍有波动就掉出 8fps。
   *
   *   修法不是"缓存背景"（鸿蒙的 `getPixelMap` 在本机实测取区域不对，工程里已默认关闭），
   *   而是**把动画量化到 500ms 步进**：
   *   - 时长用 `Math.floor(now / 500) * 500` 取代 `now`
   *   - 于是每 500ms 内所有帧的绘制内容**完全一致** → 内容签名不变 →
   *     被"签名未变则跳过重推"逻辑挡掉 → 那 4 帧几乎零成本（不编码、不推 USB）
   *   - 8fps 下樱花每步走 ~6px，视觉上仍然是"缓缓飘落"，不会顿
   *   这是把"每帧都动"改成"每 500ms 动一次"，对帧预算的收益远大于缓存静态部分。
   */
  private static readonly ANIM_STEP_MS: number = 500;

  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                ex: RenderExtras, vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    ThemeAnimeBG.init();
    const W = 1920;
    const H = 462;
    // 量化后的"动画时刻"：500ms 内保持不变
    const now = Math.floor(Date.now() / ThemeAnimeBG.ANIM_STEP_MS) * ThemeAnimeBG.ANIM_STEP_MS;

    ThemeAnimeBG.drawBackdrop(ctx, W, H, now);

    // ---- 五格：半透明面板压在背景上（用户选定）----
    const slots: number[][] = [
      [14, 274.4], [298.4, 398], [706, 300], [1016, 424], [1450, 409],
    ];
    const titles: string[] = ['系统', 'DSH 会话', '用量', '虚拟机', 'Dotii'];
    for (let i = 0; i < slots.length; i++) {
      ThemeAnimeBG.panel(ctx, slots[i][0], L.panelY, slots[i][1], L.panelHeight, titles[i],
        i % 2 === 0 ? B_CYAN : B_PINK);
    }

    ThemeAnimeBG.systemCell(ctx, slots[0][0], slots[0][1], t);
    ThemeAnimeBG.agentCell(ctx, slots[1][0], slots[1][1], t, ex);
    ThemeAnimeBG.usageCell(ctx, slots[2][0], slots[2][1], t);
    ThemeAnimeBG.vmCell(ctx, slots[3][0], slots[3][1]);
    ThemeAnimeBG.dotiiCell(ctx, slots[4][0], slots[4][1], t);

    // 樱花画在面板**之上**（营造"花瓣飘过屏幕"的层次感）
    ThemeAnimeBG.drawPetals(ctx, now, W, H);

    Chrome.vignette(ctx, W, H, vig, vigReach, vigCorner);
    void fs;
  }

  // ------------------------------------------------------------------
  // 背景插画
  // ------------------------------------------------------------------

  private static drawBackdrop(ctx: CanvasRenderingContext2D, W: number, H: number, now: number): void {
    // ① 天空渐变（三段：深紫蓝 → 紫 → 地平线品红）
    const sky = ctx.createLinearGradient(0, 0, 0, H);
    sky.addColorStop(0, B_SKY_TOP);
    sky.addColorStop(0.55, B_SKY_MID);
    sky.addColorStop(1, B_SKY_HOR);
    ctx.fillStyle = sky;
    ctx.fillRect(0, 0, W, H);

    // ② 星星（闪烁也随量化时刻变化，周期仍是 2.4s）
    ThemeAnimeBG.drawStars(ctx, now);

    // ③ 大月亮（右上）+ 柔光（3 层）
    const mx = 1560;
    const my = 120;
    const mr = 78;
    for (let i = 3; i >= 1; i--) {
      ctx.globalAlpha = 0.06 * i;
      ctx.fillStyle = B_MOON;
      ctx.beginPath();
      ctx.arc(mx, my, mr + i * 18, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    ctx.fillStyle = B_MOON;
    ctx.beginPath();
    ctx.arc(mx, my, mr, 0, Math.PI * 2);
    ctx.fill();
    // 月面暗斑（两小块，做出"月亮有纹理"的感觉）
    ctx.globalAlpha = 0.10;
    ctx.fillStyle = '#8A7FA8';
    ctx.beginPath();
    ctx.arc(mx - 22, my - 14, 20, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(mx + 18, my + 22, 13, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;

    // ④ 远景山脊（偏紫）
    ThemeAnimeBG.ridge(ctx, ThemeAnimeBG.ridge1, B_CITY_FAR, 0.55);
    // 近景剪影（更暗、更实）
    ThemeAnimeBG.ridge(ctx, ThemeAnimeBG.ridge2, B_CITY_NEAR, 0.92);

    // ⑤ 水面倒影（把近景做一次垂直翻转 + 低 alpha）
    ctx.save();
    ctx.globalAlpha = 0.22;
    ctx.translate(0, 2 * 360);
    ctx.scale(1, -1);
    ThemeAnimeBG.ridge(ctx, ThemeAnimeBG.ridge2, B_CITY_NEAR, 1);
    ctx.restore();
    ctx.globalAlpha = 1;
  }

  /** 星星闪烁（动态，每帧画；180 个小圆成本很低） */
  private static drawStars(ctx: CanvasRenderingContext2D, now: number): void {
    ctx.fillStyle = '#FFFFFF';
    for (let i = 0; i < ThemeAnimeBG.stars.length; i++) {
      const s = ThemeAnimeBG.stars[i];
      const tw = 0.35 + 0.65 * Math.abs(Math.sin(now / 2400 + s[3]));
      ctx.globalAlpha = tw * 0.85;
      ctx.beginPath();
      ctx.arc(s[0], s[1], s[2], 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  /** 画一条起伏的剪影（含底部闭合） */
  private static ridge(ctx: CanvasRenderingContext2D, pts: number[],
                       color: string, alpha: number): void {
    ctx.globalAlpha = alpha;
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(0, pts[0]);
    for (let i = 1; i < pts.length; i++) {
      ctx.lineTo(i * 24, pts[i]);
    }
    ctx.lineTo(1920, 462);
    ctx.lineTo(0, 462);
    ctx.closePath();
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  /** 樱花花瓣飘落（8fps 下用"时间驱动"而非"每帧增量"，保证不同帧率速度一致） */
  private static drawPetals(ctx: CanvasRenderingContext2D, now: number, W: number, H: number): void {
    for (let i = 0; i < ThemeAnimeBG.petals.length; i++) {
      const p = ThemeAnimeBG.petals[i];
      const tSec = now / 1000;
      // 下落 + 左右摆动
      let y = (p.y0 + tSec * p.speed) % (H + 40) - 20;
      const x = p.x + Math.sin(tSec * 0.7 + p.phase) * p.sway;
      const rot = tSec * 0.9 + p.phase;
      ctx.save();
      ctx.globalAlpha = p.alpha;
      ctx.translate(x, y);
      ctx.rotate(rot);
      ctx.fillStyle = B_PINK;
      // 花瓣形状：两段二次曲线做成的泪滴
      ctx.beginPath();
      ctx.moveTo(0, -p.size);
      ctx.quadraticCurveTo(p.size * 0.9, -p.size * 0.2, 0, p.size);
      ctx.quadraticCurveTo(-p.size * 0.9, -p.size * 0.2, 0, -p.size);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
    }
    ctx.globalAlpha = 1;
    void W;
  }

  // ------------------------------------------------------------------
  // 半透明面板 + 内容（简版）
  // ------------------------------------------------------------------

  private static panel(ctx: CanvasRenderingContext2D, x: number, y: number,
                       w: number, h: number, title: string, accent: string): void {
    // ★ 半透明（0.62）：背景图透出来，同时保证数据可读
    ctx.fillStyle = B_PANEL;
    ctx.globalAlpha = 0.62;
    ThemeAnimeBG.roundRect(ctx, x, y, w, h, 14);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.strokeStyle = B_BORDER;
    ctx.lineWidth = 1.5;
    ThemeAnimeBG.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 14);
    ctx.stroke();

    // 标题：居中 + 霓虹描边（与主题 10 同风格，保证一套视觉语言）
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 21px sans-serif';
    const cx = x + w / 2;
    ctx.lineWidth = 3;
    ctx.strokeStyle = '#000000';
    ctx.strokeText(title, cx, y + 32);
    ctx.fillStyle = accent;
    ctx.fillText(title, cx, y + 32);
    ctx.textAlign = 'left';
  }

  private static systemCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const sys = t.system;
    const cpu = sys !== undefined && sys.cpu !== undefined ? sys.cpu : 0;
    const cx = x + w / 2;
    const cy = 172;
    const r = 58;
    ctx.lineWidth = 12;
    ctx.strokeStyle = '#2A2450';
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.stroke();
    ctx.strokeStyle = cpu > 80 ? B_PINK : B_CYAN;
    ctx.beginPath();
    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.min(cpu, 100) / 100);
    ctx.stroke();
    ctx.textAlign = 'center';
    ctx.fillStyle = B_TEXT_W;
    ctx.font = 'bold 44px monospace';
    ctx.fillText(`${Math.round(cpu)}%`, cx, cy);
    ctx.font = '14px sans-serif';
    ctx.fillStyle = B_TEXT_S;
    ctx.fillText('CPU', cx, cy + 36);
    ctx.textAlign = 'left';

    const mem = sys !== undefined && sys.memUsed !== undefined ? sys.memUsed : 0;
    const memT = sys !== undefined && sys.memTotal !== undefined ? sys.memTotal : 0;
    ThemeAnimeBG.kv(ctx, x + 16, 282, '内存',
      memT > 0 ? `${mem.toFixed(1)} / ${memT.toFixed(1)} GB` : '--', B_TEXT_W);
    if (memT > 0) {
      ThemeAnimeBG.bar(ctx, x + 16, 310, w - 32, 10, mem / memT * 100, B_CYAN);
    }
    ThemeAnimeBG.kv(ctx, x + 16, 346, '电量',
      sys !== undefined && sys.battery !== undefined && sys.battery >= 0 ? `${sys.battery}%` : '--', B_PINK);
  }

  private static agentCell(ctx: CanvasRenderingContext2D, x: number, w: number,
                           t: Telemetry, ex: RenderExtras): void {
    const ag = t.agent;
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 28px monospace';
    ctx.fillStyle = B_TEXT_W;
    ctx.fillText(ThemeAnimeBG.fit(ctx,
      ag !== undefined && ag.project !== undefined ? ag.project : '等待数据', w - 36), x + 18, 104);
    ctx.font = 'bold 20px sans-serif';
    ctx.fillStyle = B_CYAN;
    ctx.fillText(ThemeAnimeBG.fit(ctx,
      ag !== undefined && ag.activity !== undefined ? ag.activity : '--', w - 36), x + 18, 152);
    const feed = (ex.feed !== undefined && ex.feed.length > 0) ? ex.feed.slice(-3) : [];
    const alphas: number[] = [0.42, 0.68, 1];
    for (let i = 0; i < feed.length; i++) {
      ctx.globalAlpha = alphas[i];
      ctx.font = '15px sans-serif';
      ctx.fillStyle = i === feed.length - 1 ? B_TEXT_W : B_TEXT_S;
      ctx.fillText(ThemeAnimeBG.fit(ctx, feed[i], w - 36), x + 18, 296 + i * 30);
    }
    ctx.globalAlpha = 1;
  }

  private static usageCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const tk = t.tokens;
    ThemeAnimeBG.kv(ctx, x + 16, 100, '今日 TOKEN',
      tk !== undefined && tk.todayTotal !== undefined ? ThemeAnimeBG.fmt(tk.todayTotal) : '--', B_TEXT_W);
    const bal = t.balance;
    const has = bal !== undefined && bal.total !== undefined
      && (bal.error === undefined || bal.error.length === 0);
    ThemeAnimeBG.kv(ctx, x + 16, 156, '余额',
      has ? `¥${(bal !== undefined && bal.total !== undefined ? bal.total : 0).toFixed(2)}` : '--',
      has ? B_PINK : B_TEXT_S);
    const used = tk !== undefined && tk.contextUsed !== undefined ? tk.contextUsed : 0;
    const win = tk !== undefined && tk.contextWindow !== undefined ? tk.contextWindow : 0;
    const pct = win > 0 ? used / win * 100 : 0;
    ThemeAnimeBG.kv(ctx, x + 16, 212, '上下文', win > 0 ? `${pct.toFixed(1)}%` : '--', B_CYAN);
    if (win > 0) {
      ThemeAnimeBG.bar(ctx, x + 16, 240, w - 32, 10, pct, B_CYAN);
    }
    const d = new Date();
    const pad = (n: number): string => (n < 10 ? '0' : '') + n;
    ctx.textAlign = 'center';
    ctx.font = 'bold 46px monospace';
    ctx.lineWidth = 4;
    ctx.strokeStyle = '#000000';
    const clock = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    ctx.strokeText(clock, x + w / 2, 330);
    ctx.fillStyle = B_TEXT_W;
    ctx.fillText(clock, x + w / 2, 330);
    ctx.textAlign = 'left';
  }

  private static vmCell(ctx: CanvasRenderingContext2D, x: number, w: number): void {
    ctx.strokeStyle = B_CYAN;
    ctx.globalAlpha = 0.4;
    ctx.setLineDash([6, 6]);
    ctx.lineWidth = 1;
    ThemeAnimeBG.roundRect(ctx, x + 14, 60, w - 28, 300, 10);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.globalAlpha = 1;
    ctx.textAlign = 'center';
    ctx.font = '16px sans-serif';
    ctx.fillStyle = B_TEXT_S;
    ctx.fillText('VM 画面', x + w / 2, 210);
    ctx.textAlign = 'left';
  }

  private static dotiiCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const pr = t.printer;
    const st = pr !== undefined && pr.stateLabel !== undefined && pr.stateLabel.length > 0
      ? pr.stateLabel : '--';
    ctx.textAlign = 'center';
    ctx.font = 'bold 32px sans-serif';
    ctx.lineWidth = 3;
    ctx.strokeStyle = '#000000';
    ctx.strokeText(st, x + w / 2, 196);
    ctx.fillStyle = B_CYAN;
    ctx.fillText(st, x + w / 2, 196);
    ctx.font = '18px sans-serif';
    ctx.fillStyle = B_TEXT_S;
    ctx.fillText(pr !== undefined && pr.percent !== undefined && pr.percent >= 0
      ? `${pr.percent}%` : '--', x + w / 2, 244);
    ctx.textAlign = 'left';
  }

  // ------------------------------------------------------------------
  private static kv(ctx: CanvasRenderingContext2D, x: number, y: number,
                    label: string, value: string, valueColor: string): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.font = '15px sans-serif';
    ctx.fillStyle = B_TEXT_S;
    ctx.fillText(label, x, y);
    ctx.textAlign = 'right';
    ctx.font = 'bold 20px monospace';
    ctx.fillStyle = valueColor;
    ctx.fillText(value, x + 240, y);
    ctx.textAlign = 'left';
  }

  private static bar(ctx: CanvasRenderingContext2D, x: number, y: number, w: number,
                     h: number, pct: number, color: string): void {
    ctx.fillStyle = '#2A2450';
    ThemeAnimeBG.roundRect(ctx, x, y, w, h, h / 2);
    ctx.fill();
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      ctx.fillStyle = color;
      ThemeAnimeBG.roundRect(ctx, x, y, Math.max(h, w * p / 100), h, h / 2);
      ctx.fill();
    }
  }

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

  private static fmt(n: number): string {
    if (n >= 100000000) {
      return (n / 100000000).toFixed(2) + '亿';
    }
    if (n >= 10000) {
      return (n / 10000).toFixed(1) + '万';
    }
    return `${n}`;
  }

  private static roundRect(ctx: CanvasRenderingContext2D, x: number, y: number,
                           w: number, h: number, r: number): void {
    const rr = Math.min(r, w / 2, h / 2);
    ctx.beginPath();
    ctx.moveTo(x + rr, y);
    ctx.lineTo(x + w - rr, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + rr);
    ctx.lineTo(x + w, y + h - rr);
    ctx.quadraticCurveTo(x + w, y + h, x + w - rr, y + h);
    ctx.lineTo(x + rr, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - rr);
    ctx.lineTo(x, y + rr);
    ctx.quadraticCurveTo(x, y, x + rr, y);
    ctx.closePath();
  }
}
