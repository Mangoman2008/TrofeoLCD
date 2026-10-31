/**
 * ThemeNanoMuse.ets —— 主题 14「NanoMuse · 大字号版」
 *
 * ## 演进过程（为什么做成"大字号版"）
 * 1. 用户要求"找 GitHub 高星项目" → 找到 **NanoMuse**（`saladinxp/komari-nano-muse`，
 *    服务器监控面板的 anime-HUD 主题，与我们同场景），从它的 `dist/index.html` 提取了
 *    完整设计令牌与版面语法（三栏 `280px 1fr 240px`、`repeat(5,1fr)` fleet、
 *    `.det-row` 键值行、`.sd-line` 渐变分隔线、`.nm-bg-shape` 青色描边框、
 *    `.fleet-lbl` 字距 2.5px、`.fleet-val` 青色发光）。
 * 2. 用户要求"字体放大 3 倍" → 放大后**一屏只能放约 1/3 的信息量**，
 *    于是按用户选定的方案 A：**以字换内容**——砍掉次要指标，保住核心 8 项。
 *
 * ## 版面（1920×462，三段式）
 * ```
 * ┌ 顶栏 56 ─────────────────────────────────────────────────────────────┐
 * │ ◆ NANOMUSE  TROFEO 9.16             07/14 周三   21:16        ● ON   │
 * ├─── 左 560 ──────────────────┬───── 中 750 ─────┬────── 右 560 ────────┤
 * │  ┌ CPU 40% ┐ ┌ MEM 77% ┐    │                  │                      │
 * │  └ BAT 94% ┘ └TOKEN 8.8万┘  │  大健康环 132px   │   打印机进度环 96px   │
 * │  SESSION  项目 WorkBuddy    │     41 HEALTH     │   已完成  136 / 136   │
 * │           状态 执行命令·flash│                  │   PRINT PROGRESS     │
 * ├─ 底栏 52 ────────────────────────────────────────────────────────────┤
 * │  余额 ¥19.49            TOKEN 8.8万              运行 0d8h            │
 * └──────────────────────────────────────────────────────────────────────┘
 * ```
 *
 * ## 砍掉了什么（放大 3 倍的必要代价，方案 A）
 * CORES 独立格 · LOAD/MEM 水印进度条 · 缓存命中 · 负载/运行 det-row ·
 * 模型名独立行（并进"状态"行）· 角色剪影（大字号下会与文字抢空间，且纯装饰）
 *
 * ## 4:2:0 预补偿
 * `#00b8d4→#2E9FB8` · `#00e676→#20A85A` · `#ff3d57→#D63A57` · `#0096c7→#3E7FB8`
 *
 * ## 性能要点（实测驱动）
 * 瓶颈是 **JPEG 编码**（`encodeMs`，机器繁忙时可达 1600ms），**渲染只要 11~22ms**。
 * 设计原则因此是"**让画面尽量静止**"：动画量化 500ms 步进、粒子 1.5s 步进且只 6 个、
 * 全部用纯色（不用每帧新建渐变对象）。
 */
import type { Telemetry } from '../common/Types';
import type { RenderExtras } from '../common/Extras';
import { Chrome } from './Chrome';
import { FrameStats } from './Dashboard';

// ---- 令牌（★ = 4:2:0 预补偿）----
const N_BG_TOP = '#F2F6FC';
const N_BG_BOT = '#DAE5F2';
const N_GLASS = '#FFFFFF';
const N_GLASS_A = 0.72;
const N_BORDER = '#B4CDE1';
const N_T1 = '#1A2C3E';
const N_T2 = '#4A6480';
const N_T3 = '#8098B0';
const N_CYAN = '#2E9FB8';        // ★ --cyan
const N_BLUE = '#3E7FB8';        // ★ --blue
const N_GREEN = '#20A85A';       // ★ --g
const N_RED = '#D63A57';         // ★ --r
const N_AMBER = '#D99400';
const N_RAIL = '#CFDEEB';
const N_SEP = '#94A3B8';

// 版面
const TOP_H = 56;
const BOT_H = 52;
const BODY_Y = TOP_H;
const BODY_H = 462 - TOP_H - BOT_H;
const PAD = 16;
const COL_L_W = 560;
const COL_R_W = 560;
const STEP_MS = 500;

/** 大字号刻度（对照原版：标签 12→24、键 13→26、值 19→38、fleet 值 34→72、环 76→132） */
const F_LABEL = 24;
const F_KEY = 26;
const F_VAL = 38;
const F_BIG = 72;
const F_HUGE = 132;

class Particle {
  x: number = 0;
  y0: number = 0;
  r: number = 0;
  speed: number = 0;
  phase: number = 0;
}

export class ThemeNanoMuse {
  static readonly NAME: string = 'NanoMuse 大字';

  private static seed: number = 20261017;
  private static inited: boolean = false;
  private static parts: Particle[] = [];

  private static rnd(): number {
    ThemeNanoMuse.seed = (ThemeNanoMuse.seed * 1103515245 + 12345) & 0x7fffffff;
    return ThemeNanoMuse.seed / 0x7fffffff;
  }

  private static init(): void {
    if (ThemeNanoMuse.inited) {
      return;
    }
    ThemeNanoMuse.seed = 20261017;
    for (let i = 0; i < 6; i++) {
      const p = new Particle();
      p.x = COL_L_W + ThemeNanoMuse.rnd() * (1920 - COL_L_W - COL_R_W);
      p.y0 = ThemeNanoMuse.rnd() * BODY_H;
      p.r = 3 + ThemeNanoMuse.rnd() * 5;
      p.speed = 5 + ThemeNanoMuse.rnd() * 8;
      p.phase = ThemeNanoMuse.rnd() * 6.28;
      ThemeNanoMuse.parts.push(p);
    }
    ThemeNanoMuse.inited = true;
  }

  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                ex: RenderExtras, vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    ThemeNanoMuse.init();
    const W = 1920;
    const H = 462;
    const now = Math.floor(Date.now() / STEP_MS) * STEP_MS;

    ThemeNanoMuse.backdrop(ctx, W, H);
    ThemeNanoMuse.bgShapes(ctx);
    ThemeNanoMuse.particles(ctx, now);

    const leftX = PAD;
    const midX = leftX + COL_L_W + PAD;
    const midW = W - COL_L_W - COL_R_W - PAD * 4;
    const rightX = midX + midW + PAD;

    ThemeNanoMuse.topBar(ctx, W, t);
    ThemeNanoMuse.leftColumn(ctx, leftX, COL_L_W, t, ex);
    ThemeNanoMuse.centerHero(ctx, midX, midW, t);
    ThemeNanoMuse.rightColumn(ctx, rightX, COL_R_W, t);
    ThemeNanoMuse.bottomBar(ctx, W, t);

    void fs;
    Chrome.vignette(ctx, W, H, vig, vigReach, vigCorner);
  }

  // ------------------------------------------------------------------
  // 背景
  // ------------------------------------------------------------------

  private static backdrop(ctx: CanvasRenderingContext2D, W: number, H: number): void {
    const g = ctx.createLinearGradient(0, 0, W * 0.35, H);
    g.addColorStop(0, N_BG_TOP);
    g.addColorStop(1, N_BG_BOT);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
    ctx.strokeStyle = '#145A8C';
    ctx.globalAlpha = 0.04;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = 0; x <= W; x += 64) {
      ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, H);
    }
    for (let y = 0; y <= H; y += 64) {
      ctx.moveTo(0, y + 0.5); ctx.lineTo(W, y + 0.5);
    }
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  /** `.nm-bg-shape`：青色 1px 描边装饰框（path 批处理，一次 stroke） */
  private static bgShapes(ctx: CanvasRenderingContext2D): void {
    const shapes: number[][] = [
      [40, 80, 210, 130], [330, 320, 140, 90],
      [1180, 100, 220, 110], [1500, 290, 160, 120],
      [1720, 80, 170, 150], [860, 340, 180, 80],
    ];
    ctx.strokeStyle = N_CYAN;
    ctx.globalAlpha = 0.26;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = 0; i < shapes.length; i++) {
      const s = shapes[i];
      ctx.rect(s[0], s[1], s[2], s[3]);
    }
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  /** 粒子：1.5s 步进（放慢是为了让静止期能被"签名未变则跳过"挡掉，省下 JPEG 编码） */
  private static particles(ctx: CanvasRenderingContext2D, now: number): void {
    const tSec = Math.floor(now / 1500) * 1.5;
    ctx.strokeStyle = N_CYAN;
    ctx.lineWidth = 1.2;
    ctx.globalAlpha = 0.20;
    for (let i = 0; i < ThemeNanoMuse.parts.length; i++) {
      const p = ThemeNanoMuse.parts[i];
      const y = BODY_Y + BODY_H - ((p.y0 + tSec * p.speed) % (BODY_H + 20));
      const x = Math.round(p.x + Math.sin(tSec * 0.5 + p.phase) * 12);
      ctx.beginPath();
      ctx.arc(x, Math.round(y), p.r, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }

  // ------------------------------------------------------------------
  // 顶栏 / 底栏
  // ------------------------------------------------------------------

  private static topBar(ctx: CanvasRenderingContext2D, W: number, t: Telemetry): void {
    ctx.fillStyle = N_GLASS;
    ctx.globalAlpha = 0.58;
    ctx.fillRect(0, 0, W, TOP_H);
    ctx.globalAlpha = 1;
    ctx.strokeStyle = N_BORDER;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, TOP_H + 0.5);
    ctx.lineTo(W, TOP_H + 0.5);
    ctx.stroke();

    const ly = TOP_H / 2;
    const lx = PAD + 14;
    ctx.fillStyle = N_CYAN;
    ctx.beginPath();
    ctx.moveTo(lx, ly - 12);
    ctx.lineTo(lx + 12, ly);
    ctx.lineTo(lx, ly + 12);
    ctx.lineTo(lx - 12, ly);
    ctx.closePath();
    ctx.fill();

    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ThemeNanoMuse.tracked(ctx, 'NANOMUSE', lx + 24, ly, 30, N_T1, 6);
    const bw = ThemeNanoMuse.trackedW(ctx, 'NANOMUSE', 30, 6);
    ctx.font = '24px sans-serif';
    ctx.fillStyle = N_T3;
    ctx.fillText('TROFEO 9.16', lx + 34 + bw, ly);

    const d = new Date();
    const pad = (n: number): string => (n < 10 ? '0' : '') + n;
    const wk = ['日', '一', '二', '三', '四', '五', '六'];
    ctx.textAlign = 'right';
    ctx.font = '22px sans-serif';
    ctx.fillStyle = N_T3;
    // ★ 2026-10-31 布局审计修：原锚 W-PAD-168 → 日期右缘 1736、左缘 1625，
    //   会伸进时钟（右缘 1668，bold 38px '11:33'）43px，时钟后画直接盖住 '10/'。
    //   改 -100：右缘 1804 / 左缘 1693，距时钟 25px、距 ON/OFF 27px。
    ctx.fillText(`${pad(d.getMonth() + 1)}/${pad(d.getDate())} 周${wk[d.getDay()]}`,
      W - PAD - 100, ly + 2);
    ctx.font = 'bold 38px monospace';
    ctx.fillStyle = N_T1;
    ctx.fillText(`${pad(d.getHours())}:${pad(d.getMinutes())}`, W - PAD - 236, ly);

    const online = t.system !== undefined;
    const dotX = W - PAD - 16;
    ctx.fillStyle = online ? N_GREEN : N_RED;
    ctx.beginPath();
    ctx.arc(dotX, ly, 7, 0, Math.PI * 2);
    ctx.fill();
    ctx.font = '22px monospace';
    ctx.fillStyle = N_T2;
    ctx.fillText(online ? 'ON' : 'OFF', dotX - 18, ly);
    ctx.textAlign = 'left';
  }

  private static bottomBar(ctx: CanvasRenderingContext2D, W: number, t: Telemetry): void {
    const y0 = 462 - BOT_H;
    ctx.fillStyle = N_GLASS;
    ctx.globalAlpha = 0.58;
    ctx.fillRect(0, y0, W, BOT_H);
    ctx.globalAlpha = 1;
    ctx.strokeStyle = N_BORDER;
    ctx.beginPath();
    ctx.moveTo(0, y0 + 0.5);
    ctx.lineTo(W, y0 + 0.5);
    ctx.stroke();

    const cy = y0 + BOT_H / 2;
    const tk = t.tokens;
    const bal = t.balance;
    const sys = t.system;
    const hasBal = bal !== undefined && bal.total !== undefined
      && (bal.error === undefined || bal.error.length === 0);
    // 底栏只留 3 项（大字号下 4 项会挤）
    const items: string[][] = [
      ['余额', hasBal ? `¥${(bal !== undefined && bal.total !== undefined ? bal.total : 0).toFixed(2)}` : '--'],
      ['TOKEN', tk !== undefined && tk.todayTotal !== undefined ? ThemeNanoMuse.fmt(tk.todayTotal) : '--'],
      ['运行', sys !== undefined && sys.uptimeSec !== undefined ? ThemeNanoMuse.uptime(sys.uptimeSec) : '--'],
    ];
    const cw = (W - PAD * 2) / items.length;
    for (let i = 0; i < items.length; i++) {
      const x = PAD + i * cw;
      ThemeNanoMuse.tracked(ctx, items[i][0], x, cy - 12, 18, N_T3, 3);
      ctx.font = 'bold 30px monospace';
      ctx.fillStyle = N_T1;
      ctx.fillText(items[i][1], x, cy + 14);
      if (i > 0) {
        ctx.strokeStyle = N_BORDER;
        ctx.beginPath();
        ctx.moveTo(x - PAD, y0 + 10);
        ctx.lineTo(x - PAD, 462 - 10);
        ctx.stroke();
      }
    }
    ctx.textAlign = 'left';
  }

  // ------------------------------------------------------------------
  // 左栏：2×2 大数字格 + SESSION
  // ------------------------------------------------------------------

  private static leftColumn(ctx: CanvasRenderingContext2D, x: number, w: number,
                            t: Telemetry, ex: RenderExtras): void {
    const sys = t.system;
    const cpu = sys !== undefined && sys.cpu !== undefined ? sys.cpu : 0;
    const mem = sys !== undefined && sys.memUsed !== undefined ? sys.memUsed : 0;
    const memT = sys !== undefined && sys.memTotal !== undefined ? sys.memTotal : 0;
    const bat = sys !== undefined && sys.battery !== undefined ? sys.battery : -1;
    const memPct = memT > 0 ? mem / memT * 100 : 0;
    const tk = t.tokens;

    // ★ 版面实测修正：原格高 138 + SESSION 两行 → 最低到 y=524，**超出底栏 410 共 114px**。
    //   压到 106（间距 10）后 SESSION 两行落在 y 318~416，正好放得下。
    const gw = (w - PAD) / 2;
    const gh = 92;   // 再让 28px：状态行(44px 字)必须整行落在内容区底 410 以上
    const g0 = BODY_Y + 14;
    const boxes: string[][] = [
      ['CPU', `${Math.round(cpu)}%`],
      ['MEM', memT > 0 ? `${Math.round(memPct)}%` : '--'],
      ['BAT', bat >= 0 ? `${bat}%` : '--'],
      ['TOKEN', tk !== undefined && tk.todayTotal !== undefined ? ThemeNanoMuse.fmt(tk.todayTotal) : '--'],
    ];
    const cols: string[] = [N_CYAN, N_BLUE, bat >= 0 && bat < 20 ? N_RED : N_GREEN, N_AMBER];
    for (let i = 0; i < boxes.length; i++) {
      const bx = x + (i % 2) * (gw + PAD);
      const by = g0 + Math.floor(i / 2) * (gh + 10);
      ThemeNanoMuse.bigTile(ctx, bx, by, gw, gh, boxes[i][0], boxes[i][1], cols[i]);
    }

    let dy = g0 + gh * 2 + 10 + 20;
    ThemeNanoMuse.sectionLabel(ctx, x, dy, 'SESSION');
    dy += 30;
    const ag = t.agent;
    ThemeNanoMuse.detRow(ctx, x, w, dy, '项目',
      ag !== undefined && ag.project !== undefined ? ag.project : '--', N_T1);
    dy += 42;
    let act = ag !== undefined && ag.activity !== undefined ? ag.activity : '--';
    if (ag !== undefined && ag.model !== undefined && ag.model.length > 0) {
      act += ` · ${ag.model.startsWith('deepseek-') ? ag.model.substring(9) : ag.model}`;
    }
    ThemeNanoMuse.detRow(ctx, x, w, dy, '状态', act, N_CYAN);
    // 留言条：只在还有余量时画（内容区底 410，状态行 y=396 已用尽 → 这里放最后 1 行）
    const feed = (ex.feed !== undefined && ex.feed.length > 0) ? ex.feed.slice(-1) : [];
    if (feed.length > 0 && dy + 44 <= 410) {
      ctx.font = '20px sans-serif';
      ctx.fillStyle = N_T2;
      ctx.fillText(ThemeNanoMuse.fit(ctx, feed[0], w), x, dy + 44);
    }
  }

  /** 大数字格：小标签（大字距） + 超大值（带青色发光） */
  private static bigTile(ctx: CanvasRenderingContext2D, x: number, y: number,
                         w: number, h: number, label: string, val: string, col: string): void {
    ctx.fillStyle = N_GLASS;
    ctx.globalAlpha = N_GLASS_A;
    ThemeNanoMuse.roundRect(ctx, x, y, w, h, 14);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.strokeStyle = N_BORDER;
    ctx.lineWidth = 1;
    ThemeNanoMuse.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 14);
    ctx.stroke();

    // ★ 实测修正（2026-10-31 二修）：原注释"中间留出 24px 净空"算的是
    //   标签中心(y+22)到值中心(y+52)的距离，不是包络净空 ——
    //   值 72px 半高 26 → 顶到 y+26，标签 24px 半高 8.6 → 底到 y+30.6，
    //   包络咬合 4.6px（标签 'C/P/U' 左端正好压在值 '6' 的顶上）。
    //   修法：标签 y+20、值中心 y+h-34 → 标签底 28.6 / 值顶 32.1，净空 3.5px；
    //   值底 y+84 距格底 92 还有 8px。
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ThemeNanoMuse.tracked(ctx, label, x + 18, y + 20, F_LABEL, N_T3, 5);
    // 值：先画一层青色低透明（近似 `.fleet-val` 的 text-shadow 发光）
    ctx.font = `bold ${F_BIG}px monospace`;
    const vy = y + h - 34;
    ctx.globalAlpha = 0.20;
    ctx.fillStyle = N_CYAN;
    ctx.fillText(val, x + 20, vy);
    ctx.globalAlpha = 1;
    ctx.fillStyle = col;
    ctx.fillText(ThemeNanoMuse.fit(ctx, val, w - 40), x + 18, vy);
  }

  // ------------------------------------------------------------------
  // 中栏：大健康环
  // ------------------------------------------------------------------

  private static centerHero(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const sys = t.system;
    const cpu = sys !== undefined && sys.cpu !== undefined ? sys.cpu : 0;
    const mem = sys !== undefined && sys.memUsed !== undefined ? sys.memUsed : 0;
    const memT = sys !== undefined && sys.memTotal !== undefined ? sys.memTotal : 0;
    const bat = sys !== undefined && sys.battery !== undefined ? sys.battery : -1;
    const memPct = memT > 0 ? mem / memT * 100 : 0;
    const vals: number[] = [cpu, memPct];
    if (bat >= 0) {
      vals.push(100 - bat);
    }
    let sum = 0;
    for (const v of vals) {
      sum += v;
    }
    const health = vals.length > 0 ? sum / vals.length : 0;

    const cx = x + w / 2;
    const cy = BODY_Y + BODY_H / 2 - 6;
    const R = 132;
    ctx.lineWidth = 24;
    ctx.strokeStyle = N_RAIL;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, Math.PI * 2);
    ctx.stroke();
    const p = Math.max(0, Math.min(100, health));
    const hcol = health > 75 ? N_RED : (health > 50 ? N_AMBER : N_GREEN);
    if (p > 0) {
      ctx.strokeStyle = hcol;
      ctx.beginPath();
      ctx.arc(cx, cy, R, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * p / 100);
      ctx.stroke();
    }
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = `bold ${F_HUGE}px monospace`;
    ctx.globalAlpha = 0.20;
    ctx.fillStyle = N_CYAN;
    ctx.fillText(`${Math.round(health)}`, cx, cy);
    ctx.globalAlpha = 1;
    ctx.fillStyle = N_T1;
    ctx.fillText(`${Math.round(health)}`, cx, cy);
    ctx.font = '28px sans-serif';
    ctx.fillStyle = N_T3;
    ctx.fillText('HEALTH', cx, cy + 92);
    ctx.textAlign = 'left';
  }

  // ------------------------------------------------------------------
  // 右栏：打印机
  // ------------------------------------------------------------------

  private static rightColumn(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const pr = t.printer;
    const pct = pr !== undefined && pr.percent !== undefined && pr.percent >= 0 ? pr.percent : 0;
    const st = pr !== undefined && pr.stateLabel !== undefined && pr.stateLabel.length > 0
      ? pr.stateLabel : '--';

    // ★ 实测修正：原来环中心 172 + 状态 320 + 层数 362 → 状态压在底栏下。整体上移。
    ThemeNanoMuse.sectionLabel(ctx, x, BODY_Y + 16, 'PRINTER');

    const cx = x + w / 2;
    const cy = BODY_Y + 156;
    const R = 92;
    ctx.lineWidth = 20;
    ctx.strokeStyle = N_RAIL;
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, Math.PI * 2);
    ctx.stroke();
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      ctx.strokeStyle = N_CYAN;
      ctx.beginPath();
      ctx.arc(cx, cy, R, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * p / 100);
      ctx.stroke();
    }
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 84px monospace';
    ctx.fillStyle = N_T1;
    ctx.fillText(`${Math.round(pct)}`, cx, cy - 6);
    ctx.font = '26px sans-serif';
    ctx.fillStyle = N_T3;
    ctx.fillText('%', cx, cy + 52);

    ctx.font = 'bold 44px sans-serif';
    ctx.fillStyle = N_T1;
    ctx.fillText(ThemeNanoMuse.fit(ctx, st, w), cx, BODY_Y + 288);
    const lr = pr !== undefined && pr.layer !== undefined && pr.layer >= 0
      ? `层 ${pr.layer}${pr.totalLayer !== undefined && pr.totalLayer > 0 ? ' / ' + pr.totalLayer : ''}`
      : '--';
    ctx.font = '28px monospace';
    ctx.fillStyle = N_T2;
    ctx.fillText(lr, cx, BODY_Y + 332);
    ctx.textAlign = 'left';
  }

  // ------------------------------------------------------------------
  // NanoMuse 组件
  // ------------------------------------------------------------------

  /** `.det-row`：键 + 分隔线 + 值（纯色分隔线，避免每帧建渐变对象） */
  private static detRow(ctx: CanvasRenderingContext2D, x: number, w: number,
                        y: number, key: string, val: string, valColor: string): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.font = `${F_KEY}px monospace`;
    ctx.fillStyle = N_T3;
    ctx.fillText(key, x, y);
    const kw = ctx.measureText(key).width;
    ctx.font = `bold ${F_VAL}px monospace`;
    const shown = ThemeNanoMuse.fit(ctx, val, w - kw - 30);
    const vw = ctx.measureText(shown).width;
    const lx = x + kw + 12;
    const lw = w - kw - vw - 28;
    if (lw > 10) {
      ctx.globalAlpha = 0.22;
      ctx.strokeStyle = N_SEP;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(lx, y + 0.5);
      ctx.lineTo(lx + lw, y + 0.5);
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
    ctx.textAlign = 'right';
    ctx.fillStyle = valColor;
    ctx.fillText(shown, x + w, y);
    ctx.textAlign = 'left';
  }

  /** 段落标签（全大写 + 大字距 + 右侧延伸线） */
  private static sectionLabel(ctx: CanvasRenderingContext2D, x: number, y: number, text: string): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ThemeNanoMuse.tracked(ctx, text, x, y, F_LABEL, N_T3, 5);
    const w = ThemeNanoMuse.trackedW(ctx, text, F_LABEL, 5);
    ctx.strokeStyle = N_BORDER;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x + w + 12, y + 0.5);
    ctx.lineTo(x + w + 150, y + 0.5);
    ctx.stroke();
  }

  /** 带字距的文字（Canvas 无 letterSpacing → 逐字画） */
  private static tracked(ctx: CanvasRenderingContext2D, s: string, x: number, y: number,
                         size: number, color: string, sp: number): void {
    ctx.font = `600 ${size}px monospace`;
    ctx.fillStyle = color;
    let cx = x;
    for (let i = 0; i < s.length; i++) {
      const ch = s.substring(i, i + 1);
      ctx.fillText(ch, cx, y);
      cx += ctx.measureText(ch).width + sp;
    }
  }

  private static trackedW(ctx: CanvasRenderingContext2D, s: string, size: number, sp: number): number {
    ctx.font = `600 ${size}px monospace`;
    let w = 0;
    for (let i = 0; i < s.length; i++) {
      w += ctx.measureText(s.substring(i, i + 1)).width + sp;
    }
    return w;
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

  private static uptime(sec: number): string {
    const d = Math.floor(sec / 86400);
    const h = Math.floor((sec % 86400) / 3600);
    return `${d}d${h}h`;
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
