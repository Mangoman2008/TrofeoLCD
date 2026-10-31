/**
 * ThemeDiag.ets — 主题 1「诊断终端」（风格参考隔壁 DiPlay / CarPlay 诊断仪）
 *
 * 与主题 0（仪表盘）的区别不只是配色，而是**看的东西不一样**：
 *   仪表盘：一眼扫全局（CPU 环、内存条、token、余额、时钟、待办）
 *   诊断终端：像 DiPlay 那样的"证据流"—— 顶部状态药丸 + 大段等宽日志流（按类型着色）
 *             + 右侧一栏紧凑指标 + 底部染色提示条。
 *
 * 布局（1920×462，横装）：
 *   ┌ 标题行：DSH 诊断终端 | 状态药丸 | 项目 · 模型 ───────────────┐
 *   │ 事件流（左侧 2/3，等宽，最多 11 行，按 idle/busy/tool/todo/err 着色）  │ 指标 │
 *   │ ...                                                        │ CPU  │
 *   │                                                            │ 内存 │
 *   │                                                            │ token│
 *   │                                                            │ 余额 │
 *   │                                                            │ 上下文│
 *   └ 底部染色条：数据桥 / 打印机 / USB / VM 的一行体检 ─────────────┘
 */
import type { Telemetry, BridgeEvent, BalanceInfo, TokenInfo } from '../common/Types';
import { C, L, F } from '../common/Theme';
import type { RenderExtras } from '../common/Extras';
import { Chrome } from './Chrome';
import { FocusTimer } from '../common/Toasts';
import { FrameStats } from './Dashboard';

export class ThemeDiag {
  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                vm: Object | null, vmAgeMs: number, vmErr: string,
                ex: RenderExtras | null = null): void {
    ThemeDiag.background(ctx, ex === null ? null : ex.bg);

    const M = 14;
    const W = L.width;
    const H = L.height;
    const metaH = 54;                 // 顶部标题行
    const footH = 40;                 // 底部体检条
    const rightW = 520;               // 右侧指标栏
    const leftW = W - M * 2 - rightW - 12;

    // ---------- 顶部标题行 ----------
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textW;
    ctx.font = F.font(22, 'bold');
    ctx.fillText('DSH 诊断终端', M, M + metaH / 2);

    // 状态药丸（DiPlay 的 RUNNING 药丸同款做法：小字 + 底色 + 竖线）
    const state = (t.agent === undefined || t.agent.state === undefined) ? 'unknown' : t.agent.state;
    const label = ThemeDiag.stateText(state);
    const pillFont: string = F.monoSub(16, 'normal');
    ctx.font = pillFont;
    const pw = ctx.measureText(label).width + 26;
    const px0 = M + 360;   // 标题 2.0× 后有 313px 宽，药丸要往右让
    ctx.fillStyle = state === 'busy' ? C.deepseek : (state === 'idle' ? '#12301C' : '#2A2A33');
    ThemeDiag.roundRect(ctx, px0, M + metaH / 2 - 13, pw, 26, 13);
    ctx.fill();
    ctx.fillStyle = state === 'busy' ? '#FFFFFF' : (state === 'idle' ? C.green : C.textS);
    ctx.font = pillFont;
    ctx.textAlign = 'center';
    ctx.fillText(label, px0 + pw / 2, M + metaH / 2);

    // 项目 · 模型（右侧，等宽小字）
    ctx.textAlign = 'right';
    ctx.fillStyle = C.textS;
    ctx.font = F.monoSub(16, 'normal');
    const ag = t.agent;
    const proj = ag === undefined || ag.project === undefined ? '（未连接数据桥）' : ag.project;
    const mdl = ag === undefined || ag.model === undefined ? '' : ` · ${ag.model}`;
    ctx.fillText(`${proj}${mdl}`, W - M, M + metaH / 2);

    // 分隔线
    ThemeDiag.hline(ctx, M, W - M, M + metaH);

    // 一句话摘要：就画在分隔线下方，等宽大字一眼看到"现在在做什么"
    if (ex !== null && ex.summary.length > 0) {
      ctx.textAlign = 'left';
      ctx.fillStyle = C.cyan;
      ctx.font = F.fontSub(15, 'bold');
      // 摘要按画布宽度截断（事件流是等宽小字，过长会冲出右边）
      let dg: string = ex.summary.replace(/\n/g, ' ');
      const dgRoom = W - M * 2;
      if (ctx.measureText(dg).width > dgRoom) {
        while (dg.length > 1 && ctx.measureText(dg + '…').width > dgRoom) {
          dg = dg.substring(0, dg.length - 1);
        }
        dg += '…';
      }
      ctx.fillText(`▸ ${dg}`, M, M + metaH + 24);
    }

    // ---------- 左侧：事件流 ----------
    const events: BridgeEvent[] = t.events ?? [];
    const lineH = 38;   // 用户反馈字太小：事件行字号 13→16 后行距一起放大
    const top = M + metaH + 56;
    const maxLines = Math.floor((H - top - footH - M) / lineH);
    ctx.textAlign = 'left';
    if (events.length === 0) {
      ctx.fillStyle = C.textD;
      ctx.font = F.monoSub(16, 'normal');
      ctx.fillText('（还没有事件：桥端会记录状态/工具/待办/打印机的变化）', M, top + 18);
    }
    const show = events.length > maxLines ? events.slice(events.length - maxLines) : events;
    // 从底部往上排（终端习惯）：条数少的时候最新的一条贴着底部，上面留白看起来是"历史"，
    // 而不是"下面空一片"（第一版从顶部往下排，只有 4 条事件时下半屏全空，实测很空）
    const areaH = H - top - footH - M;
    const baseY = top + areaH - show.length * lineH + 8;
    for (let i = 0; i < show.length; i++) {
      const e = show[i];
      const y = baseY + i * lineH;
      ctx.font = F.monoSub(16, 'normal');
      ctx.fillStyle = C.textD;
      ctx.fillText(e.t ?? '', M, y);
      ctx.fillStyle = ThemeDiag.eventColor(e.k ?? 'info');
      ctx.fillText(ThemeDiag.eventTag(e.k ?? 'info'), M + 150, y);
      ctx.fillStyle = i === show.length - 1 ? C.textW : C.textS;
      ctx.fillText(e.s ?? '', M + 268, y);
    }

    // ---------- 右侧：指标栏 ----------
    const rx = W - M - rightW;
    ctx.fillStyle = C.panel;
    ThemeDiag.roundRect(ctx, rx, M + metaH + 6, rightW, H - M - footH - metaH - 12, 10);
    ctx.fill();
    ctx.strokeStyle = C.border;
    ctx.lineWidth = 1;
    ThemeDiag.roundRect(ctx, rx, M + metaH + 6, rightW, H - M - footH - metaH - 12, 10);
    ctx.stroke();

    const tk: TokenInfo = t.tokens ?? {};
    const bal: BalanceInfo | undefined = t.balance;
    const sys = t.system;
    let my = M + metaH + 32;
    const mv = (k: string, v: string, col: string) => {
      ctx.textAlign = 'left';
      ctx.fillStyle = C.textS;
      ctx.font = F.fontSub(13, 'normal');
      ctx.fillText(k, rx + 18, my);
      ctx.textAlign = 'right';
      ctx.fillStyle = col;
      ctx.font = F.monoSub(18, 'bold');
      ctx.fillText(v, rx + rightW - 18, my);
      my += 34;
    };
    mv('CPU', `${(sys === undefined || sys.cpu === undefined ? 0 : sys.cpu).toFixed(0)}%`, C.green);
    mv('内存', sys === undefined || sys.memTotal === undefined
      ? '—' : `${(sys.memUsed ?? 0) / 1024.0 > 0 ? ((sys.memUsed ?? 0) / 1024.0).toFixed(1) : '0'} / ${(sys.memTotal / 1024.0).toFixed(1)} GB`, C.textW);
    mv('今日 TOKEN', ThemeDiag.tokens(tk.todayTotal ?? 0), C.textW);
    const total = bal === undefined || bal.total === undefined ? -1 : bal.total;
    mv('余额', bal === undefined ? '—'
      : `${bal.currency === 'USD' ? '$' : '¥'}${total.toFixed(2)}`,
      total < 0 ? C.textD : (total < 5 ? C.red : (total < 20 ? C.orange : C.green)));

    const perH = bal === undefined || bal.perHour === undefined ? -1 : bal.perHour;
    const etaH = bal === undefined || bal.etaHours === undefined ? -1 : bal.etaHours;
    mv('燃烧', perH > 0 ? `${perH.toFixed(2)}/时` : '攒采样', perH > 0 ? C.orange : C.textD);
    mv('还能用', etaH > 0 ? (etaH >= 24 ? `${(etaH / 24).toFixed(1)} 天` : `${etaH.toFixed(1)} 时`) : '—',
      etaH > 24 ? C.green : C.orange);

    // 打印机（有数据才画）：状态 + 进度
    if (t.printer !== undefined) {
      const perr = (t.printer.monitorMode ?? '') === 'error'
        || (t.printer.monitorError ?? '').length > 0;
      const pst = t.printer.state ?? 'UNKNOWN';
      const pp = t.printer.percent ?? -1;
      const pLab = perr ? '未登录' : ((t.printer.stateLabel !== undefined && t.printer.stateLabel.length > 0)
        ? t.printer.stateLabel : pst);
      mv('打印机', !perr && pp >= 0 ? `${pLab} ${pp}%` : pLab,
        perr ? C.red : (pst === 'RUNNING' ? C.purple : (pst === 'OFFLINE' ? C.red : C.green)));
    }

    // 上下文条
    const cu = tk.contextUsed ?? 0;
    const cw = tk.contextWindow ?? 0;
    const cpct = cw > 0 ? (cu / cw * 100) : 0;
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(13, 'normal');
    ctx.fillText('上下文', rx + 18, my);
    ctx.textAlign = 'right';
    ctx.fillStyle = C.byPercent(cpct);
    ctx.font = F.monoSub(18, 'bold');
    ctx.fillText(cw > 0 ? `${cpct.toFixed(1)}%` : '—', rx + rightW - 18, my);
    ctx.fillStyle = C.barBg;
    ThemeDiag.roundRect(ctx, rx + 18, my + 28, rightW - 36, 10, 5);
    ctx.fill();
    if (cpct > 0) {
      ctx.fillStyle = C.byPercent(cpct);
      ThemeDiag.roundRect(ctx, rx + 18, my + 28, Math.max(10, (rightW - 36) * cpct / 100), 10, 5);
      ctx.fill();
    }

    // ---------- 底部：一行体检（染色） ----------
    const vmTxt = vm === null ? `无画面${vmErr.length > 0 ? '（' + vmErr + '）' : ''}`
      : `${(vmAgeMs / 1000).toFixed(1)}s 前 · ${fs.jpegW}x${fs.jpegH}`;
    const usbTxt = fs.usbOpen ? `USB 已连接 · 已推 ${fs.sent} 帧 · 错误 ${fs.errors}` : 'USB 未连接';
    const brTxt = fs.bridgeAge < 0 ? '数据桥 无数据' : `数据桥 ${fs.bridgeAge}s 前`;
    const ok = fs.usbOpen && fs.bridgeAge >= 0 && fs.errors === 0;
    ctx.fillStyle = ok ? '#0D2818' : '#2A1F10';
    ThemeDiag.roundRect(ctx, M, H - M - footH + 4, W - M * 2, footH - 8, 8);
    ctx.fill();
    ctx.textAlign = 'left';
    ctx.font = F.monoSub(16, 'normal');
    ctx.fillStyle = fs.bridgeAge >= 0 ? C.green : C.orange;
    ctx.fillText(brTxt, M + 16, H - M - footH / 2);
    // 三段时间按"测量宽度"依次排，避免 2.0× 下长文本相互压（审计抓到过 51%）
    ctx.font = F.monoSub(16, 'normal');
    const brW = ctx.measureText(brTxt).width;
    ctx.fillStyle = fs.usbOpen ? C.green : C.red;
    ctx.fillText(usbTxt, M + 16 + brW + 40, H - M - footH / 2);
    ctx.textAlign = 'right';
    ctx.fillStyle = vm === null ? C.orange : C.textS;
    ctx.fillText(`VM ${vmTxt}`, W - M - 16, H - M - footH / 2);
    ctx.textAlign = 'left';
    // 专注计时（有在专注才显示，避免平时占位）
    if (ex !== null && ex.focus.elapsedMs(Date.now()) > 0) {
      ctx.fillStyle = C.green;
      ctx.fillText(`专注 ${FocusTimer.fmt(ex.focus.elapsedMs(Date.now()))} · 番茄 ${ex.focus.pomodoros}`,
        M + 1160, H - M - footH / 2);
    }

    // 弹窗（三个主题共用同一套观感）
    if (ex !== null && ex.toast !== null && Date.now() < ex.toast.until) {
      Chrome.toast(ctx, ex.toast, Date.now(), W, H, 150);
    }
  }

  // ---------- 小工具 ----------
  private static stateText(state: string): string {
    if (state === 'busy') {
      return '● 工作中';
    }
    if (state === 'waiting') {
      return '● 等待输入';
    }
    if (state === 'idle') {
      return '○ 空闲';
    }
    return '○ 未知';
  }

  private static eventColor(k: string): string {
    if (k === 'err') {
      return C.red;
    }
    if (k === 'busy') {
      return C.deepseek;
    }
    if (k === 'idle') {
      return C.green;
    }
    if (k === 'tool') {
      return C.cyan;
    }
    if (k === 'todo') {
      return C.orange;
    }
    if (k === 'print') {
      return C.purple;
    }
    return C.textL;
  }

  private static eventTag(k: string): string {
    if (k === 'err') {
      return '[错误]';
    }
    if (k === 'busy') {
      return '[工作]';
    }
    if (k === 'idle') {
      return '[空闲]';
    }
    if (k === 'tool') {
      return '[工具]';
    }
    if (k === 'todo') {
      return '[待办]';
    }
    if (k === 'print') {
      return '[打印]';
    }
    return '[信息]';
  }

  private static tokens(n: number): string {
    if (n >= 100000000) {
      return `${(n / 100000000).toFixed(2)}亿`;
    }
    if (n >= 10000) {
      return `${(n / 10000).toFixed(1)}万`;
    }
    return `${n}`;
  }

  private static background(ctx: CanvasRenderingContext2D, bg: PixelMap | null): void {
    Chrome.background(ctx, L.width, L.height, bg, 0.62);
  }

  private static hline(ctx: CanvasRenderingContext2D, x0: number, x1: number, y: number): void {
    ctx.strokeStyle = C.border;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x0, y);
    ctx.lineTo(x1, y);
    ctx.stroke();
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
