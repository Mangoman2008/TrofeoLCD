/**
 * ThemeAnimeHUD.ets —— 主题 13「明亮二次元 HUD」
 *
 * 设计来源：GitHub 上的二次元监控面板主题 **NanoMuse**（`saladinxp/komari-nano-muse`，
 * 与我们是同一类场景——服务器监控面板），设计令牌从它的 `dist/index.html` 提取，
 * 完整调研见 [docs/二次元UI-GitHub高星调研.md]。
 *
 * ## 与现有 12 个主题的最大区别：**这是唯一一个浅色主题**
 * 现有主题（含赛博二次元）都是深底霓虹。本主题走它的"白瓷片"路线：
 *   冷白渐变底 + **半透明白玻璃卡** + 深蓝灰文字 + 青色 HUD 装饰
 * → 好处是**浅底深字，文字对比度最高**，直接解决用户之前反馈的"字看着虚"。
 *
 * ## NanoMuse 令牌 → 本主题（★ = 已做 4:2:0 预补偿）
 * | NanoMuse | 原值 | 本主题用值 | 说明 |
 * |---|---|---|---|
 * | `--bg` | `#eaeff6` | `#EAEFF6` | 冷白底 |
 * | `--card-bg` | `rgba(242,248,255,.74)` | `rgba(255,255,255,0.74)` | 白瓷片（半透明，底纹透出） |
 * | `--border` | `rgba(180,205,225,.35)` | 同 | 1px 淡边 |
 * | `--t` | `#1a2c3e` | `#1A2C3E` | 主文字（深蓝灰） |
 * | `--cyan` | `#00b8d4` | ★`#2E9FB8` | 青是 4:2:0 重灾区（实测 `#00FFFF` 屏上 0 像素） |
 * | `--blue` | `#0096c7` | ★`#3E7FB8` | 同上 |
 * | `--g` | `#00e676` | ★`#20A85A` | 纯绿会被砍，压暗抬红 |
 * | `--r` | `#ff3d57` | ★`#D63A57` | R 贴顶，略压 |
 * | `--am` | `#ffab00` | `#D99400` | |
 * | `--glow` | `0 0 24px rgba(0,184,212,.18)` | 多层同心描边近似 | Canvas 无 shadowBlur（工程零使用） |
 *
 * ## 版面（1920×462）
 *   ① 冷白渐变底 + 极淡网格 + **电路线**（NanoMuse 的 SVG 折角走线 → 改用 lineTo 手绘）
 *   ② **四角青色 HUD 切角**（它的 `--corner-color`）
 *   ③ 五张**白瓷片半透明卡**（沿用定稿 v6 的落点与宽度）
 *   ④ 卡头：青色斜纹标题条 + 深蓝灰中文标题
 *   ⑤ **健康度圆环**：CPU/RAM/电量 综合成一个 Health 值，按值取色（它的核心语义）
 *   ⑥ **进度条内嵌水印配置**：条上叠 20% 透明的小字（NanoMuse 的手法，省版面又好看）
 *   ⑦ **角色剪影**：NanoMuse 用 `char.png`，我们下不到图 → **纯几何画一个动漫风侧影**
 *      （头部轮廓 + 刘海分层 + 发梢 + 肩线），用低 alpha 压在背景层，不抢数据
 *   ⑧ 粒子：缓慢上升的气泡（AcgUI 的 Bubble 手法）
 */
import type { Telemetry } from '../common/Types.ts';
import type { RenderExtras } from '../common/Extras.ts';
import { L } from '../common/Theme.ts';
import { Chrome } from './Chrome.ts';
import { FrameStats } from './Dashboard.ts';

// ---- NanoMuse 令牌（★ 已 4:2:0 预补偿）----
const H_BG_TOP = '#F2F6FC';
const H_BG_BOT = '#DCE6F2';
const H_CARD = '#FFFFFF';
const H_CARD_A = 0.74;
const H_BORDER = '#B4CDE1';
const H_TEXT = '#1A2C3E';
const H_TEXT2 = '#4A6480';
const H_TEXT3 = '#8098B0';
const H_CYAN = '#2E9FB8';        // ★ 补偿：#00b8d4 → 压 G 抬 R
const H_CYAN_SOFT = '#8FC8DF';
const H_BLUE = '#3E7FB8';        // ★ 补偿
const H_GREEN = '#20A85A';       // ★ 补偿：#00e676
const H_RED = '#D63A57';         // ★ 补偿：#ff3d57
const H_AMBER = '#D99400';
const H_RAIL = '#C8DAEA';
const H_GRID = '#145A8C';        // 配 alpha 0.04 用

/** 动画量化步长（500ms；8fps 下静止期可被签名跳过） */
const STEP_MS = 500;

class Bubble {
  x: number = 0;
  y0: number = 0;
  r: number = 0;
  speed: number = 0;
  phase: number = 0;
}

export class ThemeAnimeHUD {
  static readonly NAME: string = '明亮二次元 HUD';

  private static seed: number = 20261015;
  private static inited: boolean = false;
  private static bubbles: Bubble[] = [];

  private static rnd(): number {
    ThemeAnimeHUD.seed = (ThemeAnimeHUD.seed * 1103515245 + 12345) & 0x7fffffff;
    return ThemeAnimeHUD.seed / 0x7fffffff;
  }

  private static init(): void {
    if (ThemeAnimeHUD.inited) {
      return;
    }
    ThemeAnimeHUD.seed = 20261015;
    for (let i = 0; i < 16; i++) {
      const b = new Bubble();
      b.x = ThemeAnimeHUD.rnd() * 1920;
      b.y0 = ThemeAnimeHUD.rnd() * 462;
      b.r = 3 + ThemeAnimeHUD.rnd() * 7;
      b.speed = 6 + ThemeAnimeHUD.rnd() * 10;
      b.phase = ThemeAnimeHUD.rnd() * 6.28;
      ThemeAnimeHUD.bubbles.push(b);
    }
    ThemeAnimeHUD.inited = true;
  }

  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                ex: RenderExtras, vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    ThemeAnimeHUD.init();
    const W = 1920;
    const H = 462;
    const now = Math.floor(Date.now() / STEP_MS) * STEP_MS;

    // ① 冷白渐变底
    const g = ctx.createLinearGradient(0, 0, W * 0.4, H);
    g.addColorStop(0, H_BG_TOP);
    g.addColorStop(1, H_BG_BOT);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);

    // ② 极淡网格（NanoMuse `--grid-color` alpha 0.04）
    ctx.strokeStyle = H_GRID;
    ctx.globalAlpha = 0.04;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = 0; x <= W; x += 48) {
      ctx.moveTo(x + 0.5, 0);
      ctx.lineTo(x + 0.5, H);
    }
    for (let y = 0; y <= H; y += 48) {
      ctx.moveTo(0, y + 0.5);
      ctx.lineTo(W, y + 0.5);
    }
    ctx.stroke();
    ctx.globalAlpha = 1;

    // ③ 电路线（NanoMuse 的 SVG 折角走线 → lineTo 手绘）
    ThemeAnimeHUD.circuit(ctx);
    // ④ 角色剪影（NanoMuse 用 char.png；我们下不到图 → 纯几何画动漫风侧影）
    ThemeAnimeHUD.charSilhouette(ctx);
    // ⑤ 气泡粒子（AcgUI 的 Bubble 手法）
    ThemeAnimeHUD.bubblesDraw(ctx, now);

    // ⑥ 四角青色 HUD 切角
    ThemeAnimeHUD.corners(ctx, W, H);

    // ⑦ 五张白瓷片卡（沿用定稿 v6 落点）
    const slots: number[][] = [
      [14, 274.4], [298.4, 398], [706, 300], [1016, 424], [1450, 409],
    ];
    const titles: string[] = ['系统', 'DSH 会话', '用量', '虚拟机', 'Dotii'];
    for (let i = 0; i < slots.length; i++) {
      ThemeAnimeHUD.card(ctx, slots[i][0], L.panelY, slots[i][1], L.panelHeight, titles[i]);
    }

    ThemeAnimeHUD.systemCell(ctx, slots[0][0], slots[0][1], t);
    ThemeAnimeHUD.agentCell(ctx, slots[1][0], slots[1][1], t, ex);
    ThemeAnimeHUD.usageCell(ctx, slots[2][0], slots[2][1], t);
    ThemeAnimeHUD.vmCell(ctx, slots[3][0], slots[3][1]);
    ThemeAnimeHUD.dotiiCell(ctx, slots[4][0], slots[4][1], t);

    // 右下角漏光补偿（浅色主题上尤其明显）
    Chrome.vignette(ctx, W, H, vig, vigReach, vigCorner);
    void fs;
  }

  // ------------------------------------------------------------------
  // 背景装饰
  // ------------------------------------------------------------------

  /** 电路线：折角走线 + 渐变描边 + 箭头（NanoMuse 的标志性背景） */
  private static circuit(ctx: CanvasRenderingContext2D): void {
    ctx.globalAlpha = 0.13;
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = H_CYAN;
    const paths: number[][][] = [
      [[-20, 120], [180, 120], [220, 160], [420, 160]],
      [[-20, 300], [140, 300], [180, 260], [340, 260]],
      [[1940, 90], [1740, 90], [1700, 130], [1520, 130]],
      [[1940, 330], [1760, 330], [1720, 370], [1560, 370]],
      [[900, -20], [900, 40], [940, 80], [940, 150]],
      [[1100, -20], [1100, 30], [1060, 70], [1060, 120]],
    ];
    for (let p = 0; p < paths.length; p++) {
      const pts = paths[p];
      ctx.beginPath();
      ctx.moveTo(pts[0][0], pts[0][1]);
      for (let i = 1; i < pts.length; i++) {
        ctx.lineTo(pts[i][0], pts[i][1]);
      }
      ctx.stroke();
      // 端点小圆（NanoMuse 的箭头标记 → 用圆点更省笔画）
      const last = pts[pts.length - 1];
      ctx.beginPath();
      ctx.arc(last[0], last[1], 3, 0, Math.PI * 2);
      ctx.fillStyle = H_CYAN;
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  /**
   * 角色剪影：动漫风侧影（纯几何）。
   * NanoMuse 用真实角色图 `char.png`；本机下载通道受限、且本屏不能引外部字体/图，
   * 所以用**几何轮廓**表达"角色透出"：头部 + 分层刘海 + 发梢 + 肩颈线 + 一只眼睛的高光。
   * 放在右侧空白区（x≈870..1070 之间那段的背景层），alpha 很低，不抢数据。
   */
  private static charSilhouette(ctx: CanvasRenderingContext2D): void {
    const cx = 968;
    const headY = 210;
    const headR = 78;
    ctx.globalAlpha = 0.10;
    ctx.fillStyle = H_BLUE;
    // 肩/身
    ctx.beginPath();
    ctx.moveTo(cx - 130, 462);
    ctx.quadraticCurveTo(cx - 108, 322, cx - 44, 292);
    ctx.lineTo(cx + 44, 292);
    ctx.quadraticCurveTo(cx + 108, 322, cx + 130, 462);
    ctx.closePath();
    ctx.fill();
    // 头
    ctx.beginPath();
    ctx.arc(cx, headY, headR, 0, Math.PI * 2);
    ctx.fill();
    // 刘海上沿（盖住额头一部分，做出"发型"分层）
    ctx.globalAlpha = 0.14;
    ctx.beginPath();
    ctx.moveTo(cx - headR, headY - 18);
    ctx.quadraticCurveTo(cx - 30, headY - 96, cx + 18, headY - 84);
    ctx.quadraticCurveTo(cx + 62, headY - 74, cx + headR, headY - 24);
    ctx.quadraticCurveTo(cx + 30, headY - 46, cx - headR, headY - 18);
    ctx.closePath();
    ctx.fill();
    // 两侧发梢
    ctx.beginPath();
    ctx.moveTo(cx - headR - 4, headY - 10);
    ctx.quadraticCurveTo(cx - headR - 30, headY + 70, cx - headR + 6, headY + 120);
    ctx.quadraticCurveTo(cx - headR + 26, headY + 60, cx - headR + 22, headY - 6);
    ctx.closePath();
    ctx.fill();
    ctx.beginPath();
    ctx.moveTo(cx + headR + 4, headY - 10);
    ctx.quadraticCurveTo(cx + headR + 30, headY + 70, cx + headR - 6, headY + 120);
    ctx.quadraticCurveTo(cx + headR - 26, headY + 60, cx + headR - 22, headY - 6);
    ctx.closePath();
    ctx.fill();
    // 眼睛高光（一只，做出"侧脸看向数据"的感觉）
    ctx.globalAlpha = 0.22;
    ctx.fillStyle = H_CYAN;
    ctx.beginPath();
    ctx.arc(cx + 34, headY + 6, 9, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  /** 气泡缓慢上升（AcgUI 的 Bubble） */
  private static bubblesDraw(ctx: CanvasRenderingContext2D, now: number): void {
    const tSec = now / 1000;
    for (let i = 0; i < ThemeAnimeHUD.bubbles.length; i++) {
      const b = ThemeAnimeHUD.bubbles[i];
      const y = 480 - ((b.y0 + tSec * b.speed) % 520);
      const x = Math.round(b.x + Math.sin(tSec * 0.5 + b.phase) * 14);
      ctx.globalAlpha = 0.20;
      ctx.strokeStyle = H_CYAN;
      ctx.lineWidth = 1.2;
      ctx.beginPath();
      ctx.arc(x, Math.round(y), b.r, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }

  /** 四角 HUD 切角（NanoMuse `--corner-color`） */
  private static corners(ctx: CanvasRenderingContext2D, W: number, H: number): void {
    const m = 10;
    const len = 30;
    ctx.strokeStyle = H_CYAN;
    ctx.globalAlpha = 0.45;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(m, m + len); ctx.lineTo(m, m); ctx.lineTo(m + len, m);
    ctx.moveTo(W - m - len, m); ctx.lineTo(W - m, m); ctx.lineTo(W - m, m + len);
    ctx.moveTo(m, H - m - len); ctx.lineTo(m, H - m); ctx.lineTo(m + len, H - m);
    ctx.moveTo(W - m - len, H - m); ctx.lineTo(W - m, H - m); ctx.lineTo(W - m, H - m - len);
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  // ------------------------------------------------------------------
  // 白瓷片卡
  // ------------------------------------------------------------------

  private static card(ctx: CanvasRenderingContext2D, x: number, y: number,
                      w: number, h: number, title: string): void {
    // 半透明白瓷片（底纹透出 = NanoMuse 的"呼吸感"）
    ctx.fillStyle = H_CARD;
    ctx.globalAlpha = H_CARD_A;
    ThemeAnimeHUD.roundRect(ctx, x, y, w, h, 12);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.strokeStyle = H_BORDER;
    ctx.lineWidth = 1;
    ThemeAnimeHUD.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 12);
    ctx.stroke();

    // 卡头：青色斜纹标题条 + 深蓝灰标题（浅底上必须用深字）
    ctx.fillStyle = H_CYAN;
    ctx.globalAlpha = 0.12;
    ctx.fillRect(x + 1, y + 1, w - 2, 40);
    ctx.globalAlpha = 1;
    ctx.fillStyle = H_CYAN;
    ctx.fillRect(x + 1, y + 41, w - 2, 2);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 20px sans-serif';
    ctx.fillStyle = H_TEXT;
    ctx.fillText(title, x + w / 2, y + 22);
    ctx.textAlign = 'left';
  }

  // ------------------------------------------------------------------
  // 内容
  // ------------------------------------------------------------------

  private static systemCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const sys = t.system;
    const cpu = sys !== undefined && sys.cpu !== undefined ? sys.cpu : 0;
    const mem = sys !== undefined && sys.memUsed !== undefined ? sys.memUsed : 0;
    const memT = sys !== undefined && sys.memTotal !== undefined ? sys.memTotal : 0;
    const bat = sys !== undefined && sys.battery !== undefined ? sys.battery : -1;
    const memPct = memT > 0 ? mem / memT * 100 : 0;

    // ★ 健康度圆环（NanoMuse 的核心语义：多指标综合成一个 Health）
    const vals: number[] = [cpu, memPct];
    if (bat >= 0) {
      vals.push(100 - bat);
    }
    let sum = 0;
    for (const v of vals) {
      sum += v;
    }
    const health = vals.length > 0 ? sum / vals.length : 0;
    ThemeAnimeHUD.ring(ctx, x + w / 2, 168, 56, 13, health,
      health > 75 ? H_RED : (health > 50 ? H_AMBER : H_GREEN), `${Math.round(health)}`);

    // 进度条 + **内嵌水印配置**（NanoMuse 的手法）
    ThemeAnimeHUD.barWithWatermark(ctx, x + 18, 262, w - 36, 16, cpu,
      'CPU', `${sys !== undefined && sys.cores !== undefined ? sys.cores : 0} 核`, H_CYAN);
    ThemeAnimeHUD.barWithWatermark(ctx, x + 18, 312, w - 36, 16, memPct,
      'RAM', memT > 0 ? `${memT.toFixed(0)}G` : '--', H_BLUE);
    if (bat >= 0) {
      ThemeAnimeHUD.barWithWatermark(ctx, x + 18, 362, w - 36, 16, bat,
        'BAT', `${bat}%`, bat < 20 ? H_RED : H_GREEN);
    }
    // 内存数值行（放在条下方，避免和水印打架）
    ctx.font = 'bold 19px monospace';
    ctx.fillStyle = H_TEXT;
    ctx.textAlign = 'right';
    ctx.fillText(memT > 0 ? `${mem.toFixed(1)}/${memT.toFixed(1)} GB` : '--', x + w - 18, 240);
    ctx.textAlign = 'left';
    ctx.font = '14px sans-serif';
    ctx.fillStyle = H_TEXT3;
    ctx.fillText('内存', x + 18, 240);
  }

  private static agentCell(ctx: CanvasRenderingContext2D, x: number, w: number,
                           t: Telemetry, ex: RenderExtras): void {
    const ag = t.agent;
    ctx.textBaseline = 'middle';
    // 项目名：自动缩字号（浅底深字，可读性最好）
    ThemeAnimeHUD.shrink(ctx,
      ag !== undefined && ag.project !== undefined ? ag.project : '等待数据',
      x + 18, 110, w - 36, 30, H_TEXT);
    ctx.font = 'bold 19px sans-serif';
    ctx.fillStyle = H_CYAN;
    ctx.fillText(ThemeAnimeHUD.fit(ctx,
      ag !== undefined && ag.activity !== undefined ? ag.activity : '--', w - 36), x + 18, 156);
    // 芯片行（provider / turn / model）
    const chips: string[] = [];
    if (ag !== undefined && ag.provider !== undefined && ag.provider.length > 0) {
      chips.push(ag.provider);
    }
    if (ag !== undefined && ag.turn !== undefined) {
      chips.push(`turn ${ag.turn}`);
    }
    if (ag !== undefined && ag.model !== undefined && ag.model.length > 0) {
      chips.push(ag.model.startsWith('deepseek-') ? ag.model.substring(9) : ag.model);
    }
    let chipX = x + 18;
    for (const c of chips) {
      ctx.font = '14px monospace';
      const cw = ctx.measureText(c).width + 20;
      if (chipX + cw > x + w - 18) {
        break;
      }
      ctx.fillStyle = H_CYAN;
      ctx.globalAlpha = 0.10;
      ThemeAnimeHUD.roundRect(ctx, chipX, 176, cw, 30, 15);
      ctx.fill();
      ctx.globalAlpha = 1;
      ctx.fillStyle = H_TEXT2;
      ctx.textAlign = 'center';
      ctx.fillText(c, chipX + cw / 2, 191);
      ctx.textAlign = 'left';
      chipX += cw + 8;
    }
    // 底部滚动留言条（3 行，旧→新由淡到深）
    const feed = (ex.feed !== undefined && ex.feed.length > 0) ? ex.feed.slice(-3) : [];
    const alphas: number[] = [0.45, 0.7, 1];
    for (let i = 0; i < feed.length; i++) {
      ctx.globalAlpha = alphas[i];
      ctx.font = '15px sans-serif';
      ctx.fillStyle = i === feed.length - 1 ? H_TEXT : H_TEXT2;
      ctx.fillText(ThemeAnimeHUD.fit(ctx, feed[i], w - 36), x + 18, 288 + i * 30);
    }
    ctx.globalAlpha = 1;
  }

  private static usageCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const tk = t.tokens;
    const bal = t.balance;
    const hasBal = bal !== undefined && bal.total !== undefined
      && (bal.error === undefined || bal.error.length === 0);
    const used = tk !== undefined && tk.contextUsed !== undefined ? tk.contextUsed : 0;
    const win = tk !== undefined && tk.contextWindow !== undefined ? tk.contextWindow : 0;
    const pct = win > 0 ? used / win * 100 : 0;

    ThemeAnimeHUD.kv(ctx, x + 18, 96, '今日 TOKEN',
      tk !== undefined && tk.todayTotal !== undefined ? ThemeAnimeHUD.fmt(tk.todayTotal) : '--', H_TEXT);
    ThemeAnimeHUD.kv(ctx, x + 18, 152, '余额',
      hasBal ? `¥${(bal !== undefined && bal.total !== undefined ? bal.total : 0).toFixed(2)}` : '--',
      hasBal ? H_AMBER : H_TEXT3);
    ThemeAnimeHUD.barWithWatermark(ctx, x + 18, 200, w - 36, 16, pct, 'CTX',
      win > 0 ? `${(win / 1000).toFixed(0)}K` : '--', H_CYAN);

    // 大时钟（浅底深字 + 青色描边光晕）
    const d = new Date();
    const pad = (n: number): string => (n < 10 ? '0' : '') + n;
    ctx.textAlign = 'center';
    ctx.font = 'bold 56px monospace';
    ctx.fillStyle = H_TEXT;
    ctx.fillText(`${pad(d.getHours())}:${pad(d.getMinutes())}`, x + w / 2, 300);
    ctx.font = '15px sans-serif';
    ctx.fillStyle = H_TEXT3;
    const wk = ['日', '一', '二', '三', '四', '五', '六'];
    ctx.fillText(`${d.getFullYear()}/${pad(d.getMonth() + 1)}/${pad(d.getDate())} 周${wk[d.getDay()]}`,
      x + w / 2, 340);
    ctx.textAlign = 'left';
  }

  private static vmCell(ctx: CanvasRenderingContext2D, x: number, w: number): void {
    ctx.strokeStyle = H_CYAN;
    ctx.globalAlpha = 0.35;
    ctx.lineWidth = 1;
    ThemeAnimeHUD.roundRect(ctx, x + 16, 60, w - 32, 300, 8);
    ctx.stroke();
    // 虚线用短线段手绘（工程里 setLineDash 未经验证，避免依赖）
    ctx.globalAlpha = 0.22;
    for (let i = 0; i < 16; i++) {
      ctx.fillStyle = H_CYAN;
      ctx.fillRect(x + 16, 74 + i * 18, w - 32, 1);
    }
    ctx.globalAlpha = 1;
    ctx.textAlign = 'center';
    ctx.font = '16px sans-serif';
    ctx.fillStyle = H_TEXT3;
    ctx.fillText('VM 画面', x + w / 2, 214);
    ctx.textAlign = 'left';
    void w;
  }

  private static dotiiCell(ctx: CanvasRenderingContext2D, x: number, w: number, t: Telemetry): void {
    const pr = t.printer;
    const st = pr !== undefined && pr.stateLabel !== undefined && pr.stateLabel.length > 0
      ? pr.stateLabel : '--';
    const pct = pr !== undefined && pr.percent !== undefined && pr.percent >= 0 ? pr.percent : 0;
    ctx.textAlign = 'center';
    ThemeAnimeHUD.ring(ctx, x + w / 2, 190, 74, 15, pct, H_CYAN, `${Math.round(pct)}`);
    ctx.font = 'bold 24px sans-serif';
    ctx.fillStyle = H_TEXT;
    ctx.fillText(st, x + w / 2, 300);
    ctx.font = '15px sans-serif';
    ctx.fillStyle = H_TEXT3;
    const lr = pr !== undefined && pr.layer !== undefined && pr.layer >= 0
      ? `层 ${pr.layer}${pr.totalLayer !== undefined && pr.totalLayer > 0 ? '/' + pr.totalLayer : ''}` : '--';
    ctx.fillText(lr, x + w / 2, 334);
    ctx.textAlign = 'left';
  }

  // ------------------------------------------------------------------
  // 组件
  // ------------------------------------------------------------------

  /** 健康度圆环：底线 + 数值弧 + 中央大数字 + 单位 */
  private static ring(ctx: CanvasRenderingContext2D, cx: number, cy: number, r: number,
                      thick: number, pct: number, color: string, text: string): void {
    ctx.lineWidth = thick;
    ctx.strokeStyle = H_RAIL;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.stroke();
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      ctx.strokeStyle = color;
      ctx.beginPath();
      ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * p / 100);
      ctx.stroke();
    }
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = H_TEXT;
    ctx.font = 'bold 44px monospace';
    ctx.fillText(text, cx, cy + 2);
    ctx.font = '14px sans-serif';
    ctx.fillStyle = H_TEXT3;
    ctx.fillText('%', cx, cy + 34);
    ctx.textAlign = 'left';
  }

  /**
   * 进度条 + **内嵌水印配置**（NanoMuse 的标志手法）：
   * 轨道上叠一层 22% 透明的小字（如 `CPU 14 核`），既不占额外版面，又让"硬件配置"常驻可见。
   */
  private static barWithWatermark(ctx: CanvasRenderingContext2D, x: number, y: number,
                                  w: number, h: number, pct: number,
                                  wm1: string, wm2: string, color: string): void {
    ctx.fillStyle = H_RAIL;
    ThemeAnimeHUD.roundRect(ctx, x, y, w, h, h / 2);
    ctx.fill();
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      ctx.fillStyle = color;
      ThemeAnimeHUD.roundRect(ctx, x, y, Math.max(h, w * p / 100), h, h / 2);
      ctx.fill();
    }
    // 水印：压一层白色 22% 的小字在轨道左侧
    ctx.textBaseline = 'middle';
    ctx.globalAlpha = 0.55;
    ctx.font = '12px monospace';
    ctx.fillStyle = '#FFFFFF';
    ctx.fillText(wm1, x + 8, y + h / 2 + 0.5);
    ctx.textAlign = 'right';
    ctx.fillText(wm2, x + w - 8, y + h / 2 + 0.5);
    ctx.textAlign = 'left';
    ctx.globalAlpha = 1;
  }

  private static kv(ctx: CanvasRenderingContext2D, x: number, y: number,
                    label: string, value: string, valueColor: string): void {
    ctx.textBaseline = 'middle';
    ctx.font = '15px sans-serif';
    ctx.fillStyle = H_TEXT3;
    ctx.fillText(label, x, y);
    ctx.textAlign = 'right';
    ctx.font = 'bold 22px monospace';
    ctx.fillStyle = valueColor;
    ctx.fillText(value, x + 240, y);
    ctx.textAlign = 'left';
  }

  /** 自动缩字号绘制（浅底上字号可以大些，可读性最好） */
  private static shrink(ctx: CanvasRenderingContext2D, s: string,
                        x: number, y: number, maxW: number, startSize: number,
                        color: string): void {
    let sz = startSize;
    ctx.font = `bold ${sz}px monospace`;
    while (sz > 15 && ctx.measureText(s).width > maxW) {
      sz -= 1;
      ctx.font = `bold ${sz}px monospace`;
    }
    ctx.textBaseline = 'middle';
    ctx.fillStyle = color;
    ctx.fillText(ThemeAnimeHUD.fit(ctx, s, maxW), x, y);
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
