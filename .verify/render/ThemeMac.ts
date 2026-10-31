/**
 * ThemeMac.ets —— 主题 8「MacTR 五格」
 *
 * 来源：社区项目 **MacTR**（【beret21/MacTR】，macOS 版利民屏驱动）的设计令牌与绘制原语
 *       —— 规格由调研整理在 ../docs/主题素材库-GitHub调研.md 的 **T4** 小节，
 *       逐条带 `DesignTokens.swift` / `MonitorRenderer.swift` / `DrawingPrimitives.swift` 行号。
 *
 * 与我们主题 0 的关系：**几何完全一致**（margin 14 / gap 10 / 5 格 / 274.4×434），
 * 所以这不是"新布局"，而是**同一套格子里换一套视觉语言**：
 *
 *   · 面板圆角 16、描边 #262A3A
 *   · 强调色**顶条**：x+2, y, w−4, 高 3px、圆角 2
 *   · 顶条下方 **6 行 1px 渐隐光晕**（alpha = 0.12 × (1 − i/6)）
 *   · **弧表**：270° 扫角（135°→405°）、圆头端点、末端一个 thickness/2 的圆点
 *   · 阈值配色：pct < 50 → green，< 75 → orange，否则 red
 *   · 进度条圆角 = h/2，轨道 #1E2230
 *
 * 配色（MacTR 26 色令牌里我们用到的部分）：
 *   bgTop #0A0C14 / bgBot #10121C · panelBG #141722 / border #262A3A
 *   textW #E6EBF5 / textS #8C94A8 / textL #646C82 / textD #464C5F
 *   blue #4285F4（CPU）· green #34D399（内存）· cyan #22D3EE（SYSTEM）
 *   magenta #D946EF（第五格）· orange #FBBF24（警告）· red #EF4444（危险）
 *
 * 数据源全是本机真实项：CPU / 内存 / DSH token / SYSTEM / DSH 会话。
 * （MacTR 的 5 格是 CPU/GPU/内存/磁盘/SYSTEM；本机没有独显，所以第二格改成 token 速率，
 *   第五格用 DSH 会话数据 —— 宁可用真实数据换格子内容，也不编 GPU 数值。）
 */
import type { Telemetry, TokenInfo, SystemInfo } from '../common/Types.ts';
import type { RenderExtras } from '../common/Extras.ts';
import { History } from '../common/History.ts';
import { Chrome } from './Chrome.ts';
import { FrameStats } from './Dashboard.ts';

// ---- MacTR 设计令牌（取自 DesignTokens.swift:11-41）----
const M_BG_TOP = '#0A0C14';
const M_BG_BOT = '#10121C';
const M_PANEL = '#141722';
const M_BORDER = '#262A3A';
const M_TEXT_W = '#E6EBF5';
const M_TEXT_S = '#8C94A8';
const M_TEXT_L = '#646C82';
const M_TEXT_D = '#464C5F';
const M_BLUE = '#4285F4';
const M_GREEN = '#34D399';
const M_CYAN = '#22D3EE';
const M_MAGENTA = '#D946EF';
const M_ORANGE = '#FBBF24';
const M_RED = '#EF4444';
const M_BAR_BG = '#1E2230';

/** 阈值配色（DesignTokens.swift:40-46） */
function pctColor(pct: number): string {
  if (pct < 50) {
    return M_GREEN;
  }
  if (pct < 75) {
    return M_ORANGE;
  }
  return M_RED;
}

export class ThemeMac {
  static readonly NAME: string = 'MacTR 五格';
  static readonly PANEL_COUNT: number = 5;

  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                ex: RenderExtras, vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    const W = 1920;
    const H = 462;
    const M = 14;
    const GAP = 10;
    // 我们的仪表盘区是 1440（右侧 480 让给 VM），5 等分 → 与主题 0 同宽
    const dashW = 1440;
    const pw = (dashW - 2 * M - (ThemeMac.PANEL_COUNT - 1) * GAP) / ThemeMac.PANEL_COUNT;
    const ph = H - 2 * M;
    const py = M;

    // 背景：垂直渐变（bgTop → bgBot）
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, M_BG_TOP);
    g.addColorStop(1, M_BG_BOT);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);

    const sys: SystemInfo | undefined = t.system;
    const tk: TokenInfo = t.tokens ?? {};
    const cpu = sys !== undefined && sys.cpu !== undefined ? sys.cpu : 0;
    const memUsed = sys !== undefined && sys.memUsed !== undefined ? sys.memUsed : 0;
    const memTotal = sys !== undefined && sys.memTotal !== undefined ? sys.memTotal : 0;
    const memPct = memTotal > 0 ? (memUsed / memTotal) * 100 : 0;
    const tpm = t.health !== undefined && t.health.tokensPerMin !== undefined
      ? t.health.tokensPerMin : 0;

    const px = (i: number): number => M + i * (pw + GAP);

    // ---- 第 1 格：CPU ----
    ThemeMac.panel(ctx, px(0), py, pw, ph, M_BLUE, 'CPU');
    ThemeMac.arcGauge(ctx, px(0) + pw / 2, py + 150, 70, 13, cpu, M_BLUE);
    ThemeMac.kv(ctx, px(0) + 18, py + 268, '核心', sys !== undefined && sys.cores !== undefined ? `${sys.cores}` : '--', M_TEXT_W);
    ThemeMac.kv(ctx, px(0) + 18, py + 306, '负载', sys !== undefined && sys.load1 !== undefined ? sys.load1.toFixed(2) : '--', M_TEXT_S);
    ThemeMac.kv(ctx, px(0) + 18, py + 344, '温度', sys !== undefined && sys.cpuTemp !== undefined && sys.cpuTemp >= 0 ? `${sys.cpuTemp.toFixed(0)}°C` : '--', M_ORANGE);

    // ---- 第 2 格：TOKEN 速率（替代 MacTR 的 GPU 格；本机无独显，不编数据）----
    const tpmPct = tpm > 0 ? Math.min(100, tpm / 50) : 0;   // 50 tok/min 视作满格
    ThemeMac.panel(ctx, px(1), py, pw, ph, M_MAGENTA, 'TOKEN');
    ThemeMac.arcGauge(ctx, px(1) + pw / 2, py + 150, 70, 13, tpmPct, M_MAGENTA);
    ThemeMac.kv(ctx, px(1) + 18, py + 268, '速率', `${tpm.toFixed(0)}/min`, M_TEXT_W);
    ThemeMac.kv(ctx, px(1) + 18, py + 306, '今日', ThemeMac.fmtTokens(tk.todayTotal ?? 0), M_TEXT_S);
    ThemeMac.kv(ctx, px(1) + 18, py + 344, '上下文', tk.contextUsed !== undefined ? `${tk.contextUsed}` : '--', M_TEXT_L);

    // ---- 第 3 格：内存 ----
    ThemeMac.panel(ctx, px(2), py, pw, ph, M_GREEN, '内存');
    ThemeMac.arcGauge(ctx, px(2) + pw / 2, py + 150, 70, 13, memPct, pctColor(memPct));
    ThemeMac.kv(ctx, px(2) + 18, py + 268, '已用',
      `${(memUsed / 1024).toFixed(1)} GB`, M_TEXT_W);
    ThemeMac.kv(ctx, px(2) + 18, py + 306, '总量',
      memTotal > 0 ? `${(memTotal / 1024).toFixed(1)} GB` : '--', M_TEXT_S);
    ThemeMac.bar(ctx, px(2) + 18, py + 348, pw - 36, 10, memPct, pctColor(memPct));

    // ---- 第 4 格：磁盘（本机取不到磁盘读数 → 用历史曲线长度与桥龄兜底，不编数值）----
    ThemeMac.panel(ctx, px(3), py, pw, ph, M_ORANGE, 'DISK');
    const hist: History = ex.history;
    ThemeMac.arcGauge(ctx, px(3) + pw / 2, py + 150, 70, 13, 0, M_ORANGE);
    ThemeMac.kv(ctx, px(3) + 18, py + 268, '采样', `${hist.cpu.length} 点`, M_TEXT_W);
    ThemeMac.kv(ctx, px(3) + 18, py + 306, '桥龄',
      fs.bridgeAge >= 0 ? `${fs.bridgeAge.toFixed(0)}s` : '--', M_TEXT_S);
    ThemeMac.kv(ctx, px(3) + 18, py + 344, '推帧', `${fs.fps.toFixed(1)}fps`, M_TEXT_L);

    // ---- 第 5 格：SYSTEM（大时钟 + 日期 + 运行时长）----
    ThemeMac.panel(ctx, px(4), py, pw, ph, M_CYAN, 'SYSTEM');
    const d = new Date();
    const pad = (n: number): string => (n < 10 ? '0' : '') + n;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = M_TEXT_W;
    ctx.font = 'bold 60px monospace';
    ctx.fillText(`${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`,
      px(4) + pw / 2, py + 108);
    ctx.fillStyle = M_TEXT_S;
    ctx.font = 'bold 30px sans-serif';
    ctx.fillText(`${d.getFullYear()}/${pad(d.getMonth() + 1)}/${pad(d.getDate())}`, px(4) + pw / 2, py + 168);
    ctx.fillStyle = M_TEXT_D;
    ctx.font = 'bold 26px sans-serif';
    const wk = ['日', '一', '二', '三', '四', '五', '六'];
    ctx.fillText(`星期${wk[d.getDay()]}`, px(4) + pw / 2, py + 210);
    // 分隔线
    ctx.fillStyle = M_BORDER;
    ctx.fillRect(px(4) + 18, py + 236, pw - 36, 1);
    ThemeMac.kv(ctx, px(4) + 18, py + 272, '运行',
      sys !== undefined && sys.uptimeSec !== undefined ? ThemeMac.uptime(sys.uptimeSec) : '--', M_TEXT_W);
    ThemeMac.kv(ctx, px(4) + 18, py + 310, '主机',
      sys !== undefined && sys.host !== undefined ? sys.host : '--', M_TEXT_S);
    ThemeMac.kv(ctx, px(4) + 18, py + 348, '健康',
      t.health !== undefined && t.health.printer === true ? 'OK' : '--', M_GREEN);

    Chrome.vignette(ctx, W, H, vig, vigReach, vigCorner);
  }

  // ------------------------------------------------------------------
  // 绘制原语（照 MacTR 的 DrawingPrimitives.swift）
  // ------------------------------------------------------------------

  /** 面板：圆角 16 + 描边 + 强调顶条 + 6 行渐隐光晕 */
  static panel(ctx: CanvasRenderingContext2D, x: number, y: number,
               w: number, h: number, accent: string, title: string): void {
    ctx.fillStyle = M_PANEL;
    ThemeMac.roundRect(ctx, x, y, w, h, 16);
    ctx.fill();
    ctx.strokeStyle = M_BORDER;
    ctx.lineWidth = 1;
    ThemeMac.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 16);
    ctx.stroke();

    // 强调顶条（x+2, y, w−4, 3px, 圆角 2）
    ctx.fillStyle = accent;
    ThemeMac.roundRect(ctx, x + 2, y, w - 4, 3, 2);
    ctx.fill();
    // 顶条下方 6 行 1px 渐隐光晕（alpha = 0.12 × (1 − i/6)）
    for (let i = 0; i < 6; i++) {
      ctx.globalAlpha = 0.12 * (1 - i / 6);
      ctx.fillStyle = accent;
      ctx.fillRect(x + 2, y + 3 + i, w - 4, 1);
    }
    ctx.globalAlpha = 1;

    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = accent;
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText(title, x + 16, y + 38);
  }

  /**
   * 弧表：270° 扫角（135°→405°，即从左上沿顺时针到底部），圆头端点，
   * 末端一个 thickness/2 的圆点；中央大字数值 + 小号 %。
   */
  static arcGauge(ctx: CanvasRenderingContext2D, cx: number, cy: number, r: number,
                  thick: number, pct: number, accent: string): void {
    const a0 = 135 * Math.PI / 180;
    const sweep = 270 * Math.PI / 180;
    ctx.lineWidth = thick;
    ctx.lineCap = 'round';
    // 轨道
    ctx.strokeStyle = M_BAR_BG;
    ctx.beginPath();
    ctx.arc(cx, cy, r, a0, a0 + sweep);
    ctx.stroke();
    // 进度
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      const a1 = a0 + sweep * p / 100;
      ctx.strokeStyle = accent;
      ctx.beginPath();
      ctx.arc(cx, cy, r, a0, a1);
      ctx.stroke();
      // 末端圆点（DrawingPrimitives.swift:72-111）
      ctx.fillStyle = accent;
      ctx.beginPath();
      ctx.arc(cx + r * Math.cos(a1), cy + r * Math.sin(a1), thick / 2, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.lineCap = 'butt';
    // 中央数值
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = M_TEXT_W;
    ctx.font = 'bold 52px monospace';
    ctx.fillText(`${Math.round(p)}`, cx - 8, cy);
    ctx.font = 'bold 24px monospace';
    ctx.fillStyle = M_TEXT_S;
    ctx.fillText('%', cx + 34, cy + 8);
  }

  /** 一行"标签 + 值"（左标签、右值，都在面板内） */
  static kv(ctx: CanvasRenderingContext2D, x: number, y: number,
            label: string, value: string, valueColor: string): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = M_TEXT_L;
    ctx.font = 'bold 24px sans-serif';
    ctx.fillText(label, x, y);
    ctx.textAlign = 'right';
    ctx.fillStyle = valueColor;
    ctx.font = 'bold 28px monospace';
    ctx.fillText(value, x + 202, y);
    ctx.textAlign = 'left';
  }

  /** 进度条：圆角 = h/2，轨道 M_BAR_BG */
  static bar(ctx: CanvasRenderingContext2D, x: number, y: number, w: number,
             h: number, pct: number, color: string): void {
    ctx.fillStyle = M_BAR_BG;
    ThemeMac.roundRect(ctx, x, y, w, h, h / 2);
    ctx.fill();
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      ctx.fillStyle = color;
      ThemeMac.roundRect(ctx, x, y, Math.max(h, w * p / 100), h, h / 2);
      ctx.fill();
    }
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

  private static uptime(sec: number): string {
    const d = Math.floor(sec / 86400);
    const h = Math.floor((sec % 86400) / 3600);
    return d > 0 ? `${d}d ${h}h` : `${h}h`;
  }

  private static fmtTokens(n: number): string {
    if (n >= 100000000) {
      return (n / 100000000).toFixed(2) + '亿';
    }
    if (n >= 10000) {
      return (n / 10000).toFixed(1) + '万';
    }
    return `${n}`;
  }
}
