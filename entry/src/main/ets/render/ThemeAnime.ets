/**
 * ThemeAnime.ets —— 主题 10「赛博二次元」
 *
 * 设计方向：**赛博 + 二次元**（霓虹青紫、扫描线、故障色差、日文片假名装饰）。
 * 纯 Canvas 几何绘制 —— 不依赖任何外部图片/字体文件（屏上只能用系统 sans-serif/mono）。
 *
 * 版面沿用我们已定的 5 格（用户 2026-10-14 定稿的 v6 结构），但**整屏加二次元氛围层**：
 *   ① 底色：深紫黑渐变（#0B0B14 → #140A20），比纯黑更有"夜色感"
 *   ② 网格线：极淡的青色细线（每 60px 一条），像 CRT/全息投影
 *   ③ 扫描线：每 4px 一条 1px 暗线，alpha 很低（模拟 CRT）
 *   ④ 霓虹发光：标题与关键数值用"多次 fillText + 递减 alpha"做外发光
 *   ⑤ 故障色差：标题右侧错位 2px 画一层青色/品红（chromatic aberration）
 *   ⑥ 日文片假名装饰：标题旁竖排小字（如 システム / セッション），营造 ACG 氛围
 *   ⑦ 角标：四角画 L 形切角线（HUD 风格）
 *   ⑧ 心形/星星点缀：右上角画几颗微光星（8fps 下缓慢闪烁）
 *
 * 配色（赛博二次元常用的青/紫/粉三色系）：
 *   底 #0B0B14 / #140A20 · 面板 #16122A / 描边 #2A2244
 *   青 #22D3EE（霓虹主色）· 紫 #A855F7 · 粉 #FF2E97（强调）
 *   文字 #EAF6FF / #8FA3BF / #5A6B85
 *
 * ⚠️ 4:2:0 色度抽样：避免纯蓝/纯绿（会被吃掉），这里用的是偏灰的霓虹色，已可接受。
 */
import type { Telemetry, PrinterInfo } from '../common/Types';
import type { RenderExtras } from '../common/Extras';
import { L } from '../common/Theme';
import { Chrome } from './Chrome';
import { FrameStats } from './Dashboard';

// ---- 配色 ----
const A_BG_TOP = '#0B0B14';
const A_BG_BOT = '#140A20';
const A_PANEL = '#16122A';
const A_BORDER = '#2A2244';
const A_CYAN = '#22D3EE';
const A_PURPLE = '#A855F7';
const A_PINK = '#FF2E97';
const A_TEXT_W = '#EAF6FF';
const A_TEXT_S = '#8FA3BF';
const A_TEXT_L = '#5A6B85';

/** 各格的日文片假名装饰（营造 ACG 氛围用；不参与信息表达，纯装饰） */
const KANA = ['システム', 'セッション', 'つかう', 'スクリーン', 'ドティ'];

export class ThemeAnime {
  static readonly NAME: string = '赛博二次元';

  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                ex: RenderExtras, vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    const W = 1920;
    const H = 462;

    const dt0 = Date.now();
    ThemeAnime.backdrop(ctx, W, H, Date.now());
    const dt1 = Date.now();
    ThemeAnime.hudCorners(ctx, W, H);
    const dt2 = Date.now();

    // 五格（沿用定稿版式的落点与宽度；这是用户已认可的结构）
    const slots: number[][] = [
      [14, 274.4],            // 0 系统
      [298.4, 398],           // 1 DSH 会话
      [706, 300],             // 2 用量
      [1016, 424],            // 3 虚拟机
      [1450, 409],            // 4 Dotii
    ];
    const titles: string[] = ['系统', 'DSH 会话', '用量', '虚拟机', 'Dotii'];

    for (let i = 0; i < slots.length; i++) {
      const x = slots[i][0];
      const w = slots[i][1];
      ThemeAnime.panel(ctx, x, L.panelY, w, L.panelHeight,
        i % 3 === 0 ? A_CYAN : (i % 3 === 1 ? A_PURPLE : A_PINK));
      ThemeAnime.neonTitle(ctx, x, w, L.panelY,
        titles[i], KANA[i] !== undefined ? KANA[i] : '',
        i % 3 === 0 ? A_CYAN : (i % 3 === 1 ? A_PURPLE : A_PINK));
    }

    const dt3 = Date.now();
    // 各格内容（先用现有数据做简版：真实数值 + 霓虹配色）
    ThemeAnime.systemCell(ctx, slots[0][0], slots[0][1], t, fs);
    ThemeAnime.agentCell(ctx, slots[1][0], slots[1][1], t, ex);
    ThemeAnime.usageCell(ctx, slots[2][0], slots[2][1], t);
    ThemeAnime.vmCell(ctx, slots[3][0], slots[3][1], t);
    ThemeAnime.dotiiCell(ctx, slots[4][0], slots[4][1], t);

    const dt4 = Date.now();
    Chrome.vignette(ctx, W, H, vig, vigReach, vigCorner);
    const dt5 = Date.now();
    ThemeAnime.dbgSplit = [dt1 - dt0, dt2 - dt1, dt3 - dt2, dt4 - dt3, dt5 - dt4];
  }

  /** 诊断：分段耗时 [backdrop, corners, panels, cells, vignette] */
  static dbgSplit: number[] = [0, 0, 0, 0, 0];

  // ------------------------------------------------------------------
  // 氛围层
  // ------------------------------------------------------------------

  /** 底色渐变 + 网格 + 扫描线 + 微光星 */
  private static backdrop(ctx: CanvasRenderingContext2D, W: number, H: number, now: number): void {
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, A_BG_TOP);
    g.addColorStop(1, A_BG_BOT);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);

    // 网格（每 60px，极淡青色）
    ctx.strokeStyle = A_CYAN;
    ctx.globalAlpha = 0.055;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = 0; x <= W; x += 60) {
      ctx.moveTo(x + 0.5, 0);
      ctx.lineTo(x + 0.5, H);
    }
    for (let y = 0; y <= H; y += 60) {
      ctx.moveTo(0, y + 0.5);
      ctx.lineTo(W, y + 0.5);
    }
    ctx.stroke();
    ctx.globalAlpha = 1;

    // 扫描线（每 4px 一条 1px 暗线）
    ctx.fillStyle = '#000000';
    ctx.globalAlpha = 0.16;
    for (let y = 0; y < H; y += 4) {
      ctx.fillRect(0, y, W, 1);
    }
    ctx.globalAlpha = 1;

    // 右上角微光星（缓慢闪烁，周期 ~1.6s；8fps 下不会抖）
    const stars: number[][] = [[1846, 26, 3], [1806, 52, 2], [1878, 66, 2], [1770, 30, 2]];
    for (let i = 0; i < stars.length; i++) {
      const sx = stars[i][0];
      const sy = stars[i][1];
      const r = stars[i][2];
      const tw = 0.45 + 0.55 * Math.abs(Math.sin((now / 1600) + i * 1.3));
      ctx.globalAlpha = tw * 0.9;
      ctx.fillStyle = i % 2 === 0 ? A_CYAN : A_PINK;
      ThemeAnime.star(ctx, sx, sy, r);
    }
    ctx.globalAlpha = 1;
  }

  /** 四角 L 形切角（HUD 风格） */
  private static hudCorners(ctx: CanvasRenderingContext2D, W: number, H: number): void {
    const m = 8;
    const len = 26;
    ctx.strokeStyle = A_CYAN;
    ctx.globalAlpha = 0.5;
    ctx.lineWidth = 2;
    ctx.beginPath();
    // 左上
    ctx.moveTo(m, m + len); ctx.lineTo(m, m); ctx.lineTo(m + len, m);
    // 右上
    ctx.moveTo(W - m - len, m); ctx.lineTo(W - m, m); ctx.lineTo(W - m, m + len);
    // 左下
    ctx.moveTo(m, H - m - len); ctx.lineTo(m, H - m); ctx.lineTo(m + len, H - m);
    // 右下
    ctx.moveTo(W - m - len, H - m); ctx.lineTo(W - m, H - m); ctx.lineTo(W - m, H - m - len);
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  /** 面板：半透明底 + 霓虹描边 + 顶部一道发光横线 */
  private static panel(ctx: CanvasRenderingContext2D, x: number, y: number,
                       w: number, h: number, accent: string): void {
    ctx.fillStyle = A_PANEL;
    ctx.globalAlpha = 0.86;
    ThemeAnime.roundRect(ctx, x, y, w, h, 12);
    ctx.fill();
    ctx.globalAlpha = 1;

    ctx.strokeStyle = A_BORDER;
    ctx.lineWidth = 1;
    ThemeAnime.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 12);
    ctx.stroke();

    // 顶部霓虹发光横线（3 层递减 alpha 模拟 glow）
    for (let i = 0; i < 3; i++) {
      ctx.globalAlpha = 0.5 - i * 0.15;
      ctx.fillStyle = accent;
      ctx.fillRect(x + 10 - i, y + 2 + i, w - 20 + i * 2, 1);
    }
    ctx.globalAlpha = 1;
  }

  /**
   * 霓虹标题：主文字 + 故障色差（左右各错位 2px 画青/品红）+ 日文片假名竖排装饰。
   * 发光用"同位置多次 fillText + 递减 alpha"近似（Canvas 没有文字 glow）。
   */
  private static neonTitle(ctx: CanvasRenderingContext2D, x: number, w: number, y: number,
                           title: string, kana: string, accent: string): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 21px sans-serif';
    const cx = x + w / 2;
    const ty = y + 32;

    // 故障色差：青/品红各偏 2px
    ctx.globalAlpha = 0.5;
    ctx.fillStyle = A_CYAN;
    ctx.fillText(title, cx - 2, ty);
    ctx.fillStyle = A_PINK;
    ctx.fillText(title, cx + 2, ty);
    // 主文字（带描边做出"硬边"感）
    ctx.globalAlpha = 1;
    ctx.lineWidth = 3;
    ctx.strokeStyle = '#000000';
    ctx.strokeText(title, cx, ty);
    ctx.fillStyle = accent;
    ctx.fillText(title, cx, ty);

    // 日文片假名（竖排小字，贴在标题右侧；纯装饰）
    if (kana.length > 0) {
      ctx.font = '11px sans-serif';
      ctx.globalAlpha = 0.55;
      ctx.fillStyle = A_TEXT_S;
      ctx.textAlign = 'left';
      const kx = cx + ctx.measureText(title).width / 2 + 10;
      for (let i = 0; i < kana.length && i < 6; i++) {
        ctx.fillText(kana.substring(i, i + 1), kx, ty - 14 + i * 13);
      }
      ctx.globalAlpha = 1;
    }
    ctx.textAlign = 'left';
  }

  // ------------------------------------------------------------------
  // 五格内容（简版：真实数据 + 霓虹配色）
  // ------------------------------------------------------------------

  private static systemCell(ctx: CanvasRenderingContext2D, x: number, w: number,
                            t: Telemetry, fs: FrameStats): void {
    const sys = t.system;
    const cpu = sys !== undefined && sys.cpu !== undefined ? sys.cpu : 0;
    // 霓虹圆环
    const cx = x + w / 2;
    const cy = 176;
    const r = 62;
    ctx.lineWidth = 12;
    ctx.strokeStyle = '#241C3A';
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.stroke();
    ctx.strokeStyle = cpu > 80 ? A_PINK : A_CYAN;
    ctx.beginPath();
    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.min(cpu, 100) / 100);
    ctx.stroke();
    ctx.textAlign = 'center';
    ctx.fillStyle = A_TEXT_W;
    ctx.font = 'bold 46px monospace';
    ctx.fillText(`${Math.round(cpu)}%`, cx, cy);
    ctx.font = '14px sans-serif';
    ctx.fillStyle = A_TEXT_S;
    ctx.fillText('CPU', cx, cy + 38);
    ctx.textAlign = 'left';

    const mem = sys !== undefined && sys.memUsed !== undefined ? sys.memUsed : 0;
    const memT = sys !== undefined && sys.memTotal !== undefined ? sys.memTotal : 0;
    ThemeAnime.kv(ctx, x + 18, 288, '内存',
      memT > 0 ? `${mem.toFixed(1)} / ${memT.toFixed(1)} GB` : '--', A_TEXT_W);
    if (memT > 0) {
      ThemeAnime.bar(ctx, x + 18, 316, w - 36, 10, mem / memT * 100, A_PURPLE);
    }
    ThemeAnime.kv(ctx, x + 18, 352, '电量',
      sys !== undefined && sys.battery !== undefined && sys.battery >= 0
        ? `${sys.battery}%` : '--', A_CYAN);
    void fs;
  }

  private static agentCell(ctx: CanvasRenderingContext2D, x: number, w: number,
                           t: Telemetry, ex: RenderExtras): void {
    const ag = t.agent;
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 28px monospace';
    ctx.fillStyle = A_TEXT_W;
    ctx.fillText(ThemeAnime.fit(ctx,
      ag !== undefined && ag.project !== undefined ? ag.project : '等待数据',
      w - 40), x + 18, 108);
    ctx.font = 'bold 20px sans-serif';
    ctx.fillStyle = A_CYAN;
    ctx.fillText(ThemeAnime.fit(ctx, ag !== undefined && ag.activity !== undefined ? ag.activity : '--', w - 40),
      x + 18, 156);
    // 底部滚动留言条（与第一屏同款：3 行、由暗到亮）
    const feed = (ex.feed !== undefined && ex.feed.length > 0) ? ex.feed.slice(-3) : [];
    const alphas: number[] = [0.42, 0.68, 1];
    for (let i = 0; i < feed.length; i++) {
      ctx.globalAlpha = alphas[i];
      ctx.font = '15px sans-serif';
      ctx.fillStyle = i === feed.length - 1 ? A_TEXT_W : A_TEXT_S;
      ctx.fillText(ThemeAnime.fit(ctx, feed[i], w - 40), x + 18, 300 + i * 30);
    }
    ctx.globalAlpha = 1;
  }

  private static usageCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const tk = t.tokens;
    ThemeAnime.kv(ctx, x + 18, 96, '今日 TOKEN',
      tk !== undefined && tk.todayTotal !== undefined ? ThemeAnime.fmt(tk.todayTotal) : '--', A_TEXT_W);
    const bal = t.balance;
    const has = bal !== undefined && bal.total !== undefined && (bal.error === undefined || bal.error.length === 0);
    ThemeAnime.kv(ctx, x + 18, 152, '余额',
      has ? `¥${(bal !== undefined && bal.total !== undefined ? bal.total : 0).toFixed(2)}` : '--',
      has ? A_PINK : A_TEXT_L);
    const used = tk !== undefined && tk.contextUsed !== undefined ? tk.contextUsed : 0;
    const win = tk !== undefined && tk.contextWindow !== undefined ? tk.contextWindow : 0;
    const pct = win > 0 ? used / win * 100 : 0;
    ThemeAnime.kv(ctx, x + 18, 208, '上下文', win > 0 ? `${pct.toFixed(1)}%` : '--', A_PURPLE);
    if (win > 0) {
      ThemeAnime.bar(ctx, x + 18, 236, w - 36, 10, pct, A_PURPLE);
    }
    // 大时钟（霓虹）
    const d = new Date();
    const pad = (n: number): string => (n < 10 ? '0' : '') + n;
    ctx.textAlign = 'center';
    ctx.font = 'bold 54px monospace';
    ctx.globalAlpha = 0.45;
    ctx.fillStyle = A_CYAN;
    ctx.fillText(`${pad(d.getHours())}:${pad(d.getMinutes())}`, x + w / 2 - 2, 340);
    ctx.fillStyle = A_PINK;
    ctx.fillText(`${pad(d.getHours())}:${pad(d.getMinutes())}`, x + w / 2 + 2, 340);
    ctx.globalAlpha = 1;
    ctx.fillStyle = A_TEXT_W;
    ctx.fillText(`${pad(d.getHours())}:${pad(d.getMinutes())}`, x + w / 2, 340);
    ctx.textAlign = 'left';
  }

  private static vmCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    // VM 画面由 LcdService 的 PixelMap 提供；本主题先只画边框与占位，
    // 实际图像在 Dashboard 层绘制（主题 10 复用第一屏的 vmPanel 需要另接，见文件末说明）
    ctx.strokeStyle = A_CYAN;
    ctx.globalAlpha = 0.35;
    ctx.setLineDash([6, 6]);
    ctx.lineWidth = 1;
    ThemeAnime.roundRect(ctx, x + 12, 60, w - 24, 300, 8);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.globalAlpha = 1;
    ctx.textAlign = 'center';
    ctx.font = '16px sans-serif';
    ctx.fillStyle = A_TEXT_S;
    ctx.fillText('VM 画面（待接入本主题）', x + w / 2, 210);
    ctx.textAlign = 'left';
    void t;
  }

  private static dotiiCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const pr: PrinterInfo | undefined = t.printer;
    const st = pr !== undefined && pr.stateLabel !== undefined && pr.stateLabel.length > 0
      ? pr.stateLabel : '--';
    ctx.textAlign = 'center';
    ctx.font = 'bold 34px sans-serif';
    ctx.fillStyle = A_CYAN;
    ctx.fillText(st, x + w / 2, 200);
    ctx.font = '18px sans-serif';
    ctx.fillStyle = A_TEXT_S;
    const pct = pr !== undefined && pr.percent !== undefined && pr.percent >= 0 ? `${pr.percent}%` : '--';
    ctx.fillText(pct, x + w / 2, 250);
    ctx.textAlign = 'left';
  }

  // ------------------------------------------------------------------
  // 小工具
  // ------------------------------------------------------------------

  private static kv(ctx: CanvasRenderingContext2D, x: number, y: number,
                    label: string, value: string, valueColor: string): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.font = '15px sans-serif';
    ctx.fillStyle = A_TEXT_L;
    ctx.fillText(label, x, y);
    ctx.textAlign = 'right';
    ctx.font = 'bold 20px monospace';
    ctx.fillStyle = valueColor;
    ctx.fillText(value, x + 240, y);
    ctx.textAlign = 'left';
  }

  private static bar(ctx: CanvasRenderingContext2D, x: number, y: number, w: number,
                     h: number, pct: number, color: string): void {
    ctx.fillStyle = '#241C3A';
    ThemeAnime.roundRect(ctx, x, y, w, h, h / 2);
    ctx.fill();
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      ctx.fillStyle = color;
      ThemeAnime.roundRect(ctx, x, y, Math.max(h, w * p / 100), h, h / 2);
      ctx.fill();
    }
  }

  private static star(ctx: CanvasRenderingContext2D, cx: number, cy: number, r: number): void {
    ctx.beginPath();
    ctx.moveTo(cx, cy - r);
    ctx.lineTo(cx + r * 0.32, cy - r * 0.32);
    ctx.lineTo(cx + r, cy);
    ctx.lineTo(cx + r * 0.32, cy + r * 0.32);
    ctx.lineTo(cx, cy + r);
    ctx.lineTo(cx - r * 0.32, cy + r * 0.32);
    ctx.lineTo(cx - r, cy);
    ctx.lineTo(cx - r * 0.32, cy - r * 0.32);
    ctx.closePath();
    ctx.fill();
  }

  private static fit(ctx: CanvasRenderingContext2D, s: string, maxW: number): string {
    if (ctx.measureText(s).width <= maxW) {
      return s;
    }
    let t = s;
    while (t.length > 1 && ctx.measureText(t + '…').width > maxW) {
      t = t.substring(0, t.length - 1);
    }
    return t + '…';
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
