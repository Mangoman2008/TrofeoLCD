/**
 * ThemeWall.ets —— 主题 2「监控墙」
 *
 * 与另两个主题的分工：
 *   主题 0 仪表盘   —— 一眼扫全局（环/条/大字）
 *   主题 1 诊断终端 —— 证据流（等宽日志，像 DiPlay）
 *   主题 2 监控墙   —— **趋势**：CPU/内存/token 速率/余额的曲线 + 还能用多久 + 健康灯 + 专注计时
 *
 * 曲线数据来自应用侧采样的 History（不是桥发的瞬时值），所以能看出走势。
 */
import type { Telemetry, BalanceInfo, TokenInfo, SummaryInfo, PrinterInfo } from '../common/Types.ts';
import type { RenderExtras } from '../common/Extras.ts';
import { C, L, F } from '../common/Theme.ts';
import { History, Series } from '../common/History.ts';
import { FocusTimer } from '../common/Toasts.ts';
import { Chrome } from './Chrome.ts';
import { FrameStats } from './Dashboard.ts';

export class ThemeWall {
  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                vm: Object | null, vmAgeMs: number, vmErr: string,
                ex: RenderExtras): void {
    const W = L.width;
    const H = L.height;
    const M = 14;

    Chrome.background(ctx, W, H, ex.bg, 0.6);

    // ---------- 顶部：标题 + 一句话摘要 + 健康灯 ----------
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textW;
    ctx.font = F.font(19, 'bold');
    ctx.fillText('监控墙', M + 4, M + 26);

    let sm: string = ex.summary.length > 0 ? ex.summary.replace(/\n/g, ' ') : '（等桥端摘要）';
    // ★ 桥端摘要长度没有上限：过长会与右上健康灯压印/冲出画布（审计样例是短句所以查不出）。
    //   这里按实际测量宽度截断 —— 健康灯从右边排，左侧给它留出约 560px。
    if (sm.length > 0) {
      ctx.font = F.fontSub(14, 'normal');
      const room = W - (M + 180) - 580;
      if (room > 40 && ctx.measureText(sm).width > room) {
        let t = sm;
        while (t.length > 1 && ctx.measureText(t + '…').width > room) {
          t = t.substring(0, t.length - 1);
        }
        sm = t + '…';
      }
    }
    ctx.fillStyle = ex.summary.length > 0 ? C.cyan : C.textD;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText(sm, M + 180, M + 26);

    // 健康灯（右上）：USB / 桥 / livepad / 打印机
    const hs = t.health;
    const vmOk = vm !== null;
    const lights: string[] = [
      `USB ${fs.usbOpen ? '●' : '○'}`,
      `桥 ${fs.bridgeAge >= 0 && fs.bridgeAge < 5 ? '●' : '○'}`,
      `VM ${vmOk ? '●' : '○'}`,
      `打印 ${(hs !== undefined && hs.printer === true) ? '●' : '○'}`
    ];
    const colors: string[] = [
      fs.usbOpen ? C.green : C.red,
      (fs.bridgeAge >= 0 && fs.bridgeAge < 5) ? C.green : C.orange,
      vmOk ? C.green : C.orange,
      (hs !== undefined && hs.printer === true) ? C.green : C.textD
    ];
    ctx.textAlign = 'right';
    ctx.font = F.fontSub(14, 'normal');
    let lx = W - M - 4;
    for (let i = lights.length - 1; i >= 0; i--) {
      ctx.fillStyle = colors[i];
      ctx.textAlign = 'right';
      ctx.fillText(lights[i], lx, M + 26);
      ctx.font = F.monoSub(13, 'normal');
      lx -= ctx.measureText(lights[i]).width + 26;
      ctx.font = F.fontSub(14, 'normal');
    }

    // ---------- 中间：三张曲线卡 ----------
    const cardY = M + 56;
    const cardH = 196;
    const gap = 12;
    const cw = (W - M * 2 - gap * 3) / 4;
    const sys = t.system;
    const tk: TokenInfo = t.tokens ?? {};
    const hs2 = t.health;
    const cpuNow: number = sys !== undefined && sys.cpu !== undefined ? sys.cpu : 0;
    const memPct: number = (sys !== undefined && sys.memTotal !== undefined && sys.memTotal > 0)
      ? ((sys.memUsed ?? 0) / sys.memTotal * 100) : 0;
    const memTxt: string = (sys !== undefined && sys.memTotal !== undefined)
      ? `${((sys.memUsed ?? 0) / 1024).toFixed(1)} / ${(sys.memTotal / 1024).toFixed(1)} GB` : '—';
    const tpm: number = hs2 !== undefined && hs2.tokensPerMin !== undefined ? hs2.tokensPerMin : 0;

    ThemeWall.chartCard(ctx, M, cardY, cw, cardH, 'CPU', `${cpuNow.toFixed(0)}%`,
      C.green, ex.history.cpu, ThemeWall.spanText(ex.history.cpu.length));
    ThemeWall.chartCard(ctx, M + cw + gap, cardY, cw, cardH, '内存', `${memPct.toFixed(0)}%`,
      C.cyan, ex.history.mem, memTxt);
    ThemeWall.chartCard(ctx, M + (cw + gap) * 2, cardY, cw, cardH, 'TOKEN 速率',
      ThemeWall.fmtRate(tpm), C.deepseek, ex.history.tokens,
      `今日 ${ThemeWall.fmtTokens(tk.todayTotal ?? 0)}`);
    // 第四张卡：拓竹打印机（没接打印机时显示"未连接"，不留空洞）
    ThemeWall.printerCard(ctx, M + (cw + gap) * 3, cardY, cw, cardH, t.printer);

    // ---------- 底部：余额卡（宽） + 状态卡 ----------
    const by = cardY + cardH + gap;
    const bh = H - M - by;
    const bw = cw * 2 + gap;                       // 余额卡占两张卡宽
    ThemeWall.balanceCard(ctx, M, by, bw, bh, t.balance, ex);
    ThemeWall.statusCard(ctx, M + bw + gap, by, cw, bh, ex, fs, vmOk, vmAgeMs, t.printer);

    // ---------- 弹窗（三个主题共用） ----------
    if (ex.toast !== null && Date.now() < ex.toast.until) {
      Chrome.toast(ctx, ex.toast, Date.now(), W, H, 150);
    }
  }

  /** 一张曲线卡：标题 + 大数字 + 副标题 + 曲线 */
  private static chartCard(ctx: CanvasRenderingContext2D, x: number, y: number,
                           w: number, h: number, title: string, value: string,
                           color: string, s: import('../common/History').Series, sub: string): void {
    Chrome.card(ctx, x, y, w, h, 12, C.panel, C.border);
    // 顶部一道主题色的细高光，比纯描边更有"屏"的感觉
    Chrome.roundRect(ctx, x + 16, y + 1, w - 32, 2, 1);
    ctx.fillStyle = Chrome.alpha(color, 0.75);
    ctx.fill();

    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText(title, x + 18, y + 28);

    ctx.fillStyle = color;
    ctx.font = F.monoFont(26, 'bold');
    ctx.fillText(value, x + 18, y + 72);

    ctx.fillStyle = C.textD;
    ctx.font = F.fontSub(12, 'normal');
    ctx.textAlign = 'right';
    ctx.fillText(sub, x + w - 18, y + 28);
    ctx.textAlign = 'left';

    // 曲线（留出上下空隙，避免贴边）
    const gx = x + 18;
    const gy = y + 104;
    const gw = w - 36;
    const gh = h - 104 - 20;
    // 背景网格线：两条横线，让曲线有"量程"参照
    ctx.strokeStyle = Chrome.alpha(C.border, 0.9);
    ctx.lineWidth = 1;
    for (let i = 1; i <= 2; i++) {
      const ly = gy + gh * i / 3;
      ctx.beginPath();
      ctx.moveTo(gx, ly);
      ctx.lineTo(gx + gw, ly);
      ctx.stroke();
    }
    Chrome.sparkline(ctx, s, History.CAP, gx, gy, gw, gh, color, true, true);
  }

  /** 打印机卡：状态 + 进度 + 温度 + AMS 托盘色点 */
  private static printerCard(ctx: CanvasRenderingContext2D, x: number, y: number,
                             w: number, h: number, p: PrinterInfo | undefined): void {
    const perr = p !== undefined && ((p.monitorMode ?? '') === 'error'
      || (p.monitorError ?? '').length > 0);
    const has = p !== undefined && p.state !== undefined;
    const running = has && p.state === 'RUNNING';
    const accent = !has ? C.textD : (running ? C.purple : (p.state === 'OFFLINE' ? C.red : C.green));
    Chrome.card(ctx, x, y, w, h, 12, C.panel, C.border);
    Chrome.roundRect(ctx, x + 16, y + 1, w - 32, 2, 1);
    ctx.fillStyle = Chrome.alpha(accent, 0.75);
    ctx.fill();

    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText('拓竹打印机', x + 18, y + 28);

    if (!has) {
      ctx.fillStyle = C.textD;
      ctx.font = F.fontSub(13, 'normal');
      ctx.fillText('未接监控服务', x + 18, y + 76);
      ctx.fillText('bridge --printer <url>', x + 18, y + 112);
      return;
    }
    if (perr) {
      // 真实状态优先：云端凭据问题就直说，不做任何美化
      ctx.fillStyle = C.red;
      ctx.font = F.fontSub(15, 'normal');
      ctx.fillText('监控未登录', x + 18, y + 62);
      ctx.fillStyle = C.textS;
      ctx.font = F.fontSub(12, 'normal');
      const el = ThemeWall.wrap(ctx, p.monitorError ?? '', F.fontSub(12, 'normal'), w - 36, 3);
      let eyy = y + 96;
      for (const ln of el) {
        ctx.fillText(ln, x + 18, eyy);
        eyy += 28;
      }
      return;
    }
    const pp = p.percent ?? -1;
    const lab = (p.stateLabel !== undefined && p.stateLabel.length > 0) ? p.stateLabel : p.state;
    ctx.fillStyle = accent;
    ctx.font = F.fontSub(15, 'normal');
    ctx.fillText(lab, x + 18, y + 62);
    if (pp >= 0) {
      ctx.textAlign = 'right';
      ctx.font = F.monoFont(24, 'bold');
      ctx.fillText(`${pp}%`, x + w - 18, y + 62);
      ctx.textAlign = 'left';
      // 进度条
      ctx.fillStyle = C.barBg;
      Chrome.roundRect(ctx, x + 18, y + 100, w - 36, 10, 5);
      ctx.fill();
      ctx.fillStyle = accent;
      Chrome.roundRect(ctx, x + 18, y + 100, Math.max(10, (w - 36) * pp / 100), 10, 5);
      ctx.fill();
    }
    const tz = p.nozzleTemp ?? -1;
    const bd = p.bedTemp ?? -1;
    ctx.fillStyle = C.textL;
    ctx.font = F.monoSub(13, 'normal');
    ctx.fillText(`喷 ${tz >= 0 ? tz.toFixed(0) + '°' : '—'}  床 ${bd >= 0 ? bd.toFixed(0) + '°' : '—'}`,
      x + 18, y + 134);
    // AMS 托盘色点（当前进料加亮圈）
    const trays = p.trays ?? [];
    const now = p.trayNow ?? -1;
    let tx = x + 18;
    const maxT = trays.length > 4 ? 4 : trays.length;
    for (let i = 0; i < maxT; i++) {
      const tr = trays[i];
      ctx.fillStyle = tr.color ?? C.barBg;
      ctx.beginPath();
      ctx.arc(tx + 8, y + 168, 8, 0, Math.PI * 2);
      ctx.fill();
      if (tr.index === now) {
        ctx.strokeStyle = C.textW;
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(tx + 8, y + 168, 11, 0, Math.PI * 2);
        ctx.stroke();
      }
      tx += 30;
    }
    if (maxT > 0) {
      ctx.fillStyle = C.textD;
      ctx.font = F.monoSub(12, 'normal');
      ctx.fillText(`AMS ${maxT}`, tx + 4, y + 168);
    }
  }

  /** 余额卡：当前余额 + 每小时燃烧 + 还能用多久 + 余额曲线 */
  private static balanceCard(ctx: CanvasRenderingContext2D, x: number, y: number,
                             w: number, h: number, bal: BalanceInfo | undefined,
                             ex: RenderExtras): void {
    Chrome.card(ctx, x, y, w, h, 12, C.panel, C.border);
    const total: number = bal === undefined || bal.total === undefined ? -1 : bal.total;
    const cur: string = (bal !== undefined && bal.currency === 'USD') ? '$' : '¥';
    const col: string = total < 0 ? C.textD : (total < 5 ? C.red : (total < 20 ? C.orange : C.green));

    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText('DeepSeek 余额', x + 18, y + 26);
    ctx.fillStyle = col;
    ctx.font = F.monoFont(28, 'bold');
    ctx.fillText(total < 0 ? '—' : `${cur}${total.toFixed(2)}`, x + 18, y + 86);

    // 燃烧速率 + 还能用多久
    const perH: number = bal === undefined || bal.perHour === undefined ? -1 : bal.perHour;
    const eta: number = bal === undefined || bal.etaHours === undefined ? -1 : bal.etaHours;
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(13, 'normal');
    ctx.fillText('燃烧速率', x + 300, y + 34);
    ctx.fillStyle = perH > 0 ? C.orange : C.textD;
    ctx.font = F.monoSub(15, 'bold');
    ctx.fillText(perH > 0 ? `${perH.toFixed(2)}/时` : '攒采样中', x + 300, y + 74);

    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(13, 'normal');
    ctx.fillText('还能用', x + 470, y + 34);
    ctx.fillStyle = eta > 0 ? (eta > 24 ? C.green : C.orange) : C.textD;
    ctx.font = F.monoSub(15, 'bold');
    ctx.fillText(eta > 0 ? ThemeWall.fmtEta(eta) : '—', x + 470, y + 74);

    // 余额曲线（占右半张卡）
    const gx = x + w * 0.52;
    const gw = w * 0.44;
    const gy = y + 22;
    const gh = h - 44;
    ctx.strokeStyle = Chrome.alpha(C.border, 0.9);
    ctx.lineWidth = 1;
    for (let i = 1; i <= 2; i++) {
      const ly = gy + gh * i / 3;
      ctx.beginPath();
      ctx.moveTo(gx, ly);
      ctx.lineTo(gx + gw, ly);
      ctx.stroke();
    }
    Chrome.sparkline(ctx, ex.history.balance, History.CAP, gx, gy, gw, gh, col, true, true);
  }

  /** 状态卡：专注计时 + 番茄 + 连接体检 */
  private static statusCard(ctx: CanvasRenderingContext2D, x: number, y: number,
                            w: number, h: number, ex: RenderExtras, fs: FrameStats,
                            vmOk: boolean, vmAgeMs: number, printer: PrinterInfo | undefined): void {
    // 打印机已挪到顶部第四张卡（见 printerCard）
    Chrome.card(ctx, x, y, w, h, 12, C.panel, C.border);
    const now = Date.now();
    const focusing = ex.focus.startedAt !== 0;
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText(focusing ? '专注中' : '已暂停', x + 18, y + 26);

    ctx.fillStyle = focusing ? C.green : C.textD;
    ctx.font = F.monoFont(28, 'bold');
    ctx.fillText(FocusTimer.fmt(ex.focus.elapsedMs(now)), x + 18, y + 86);

    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(13, 'normal');
    ctx.fillText(`番茄 ${ex.focus.pomodoros}`, x + 240, y + 34);
    ctx.fillStyle = C.orange;
    ctx.font = F.monoSub(15, 'bold');
    ctx.fillText(`帧 ${fs.sent}`, x + 240, y + 74);

    // 打印机：状态 + 进度 + 喷嘴/床温（没开打印机时只画 VM/错误那行）
    const pr = ex === null ? undefined : undefined;
    ctx.fillStyle = C.textD;
    ctx.font = F.fontSub(12, 'normal');
    const vmTxt = vmOk ? `VM ${(vmAgeMs / 1000).toFixed(1)}s` : 'VM 无画面';
    ctx.fillText(`${vmTxt} · 错误 ${fs.errors}`, x + 18, y + h - 22);

  }

  /** 简易折行（ThemeWall 自己用，避免依赖 Dashboard 的私有方法） */
  private static wrap(ctx: CanvasRenderingContext2D, text: string, font: string,
                      maxW: number, maxLines: number): string[] {
    ctx.font = font;
    const out: string[] = [];
    let cur = '';
    for (const ch of text) {
      const next = cur + ch;
      if (ctx.measureText(next).width > maxW && cur.length > 0) {
        out.push(cur);
        cur = ch;
        if (out.length >= maxLines) {
          return out;
        }
      } else {
        cur = next;
      }
    }
    if (cur.length > 0 && out.length < maxLines) {
      out.push(cur);
    }
    return out;
  }

  // ---------- 小工具 ----------
  private static fmtTokens(n: number): string {
    if (n >= 100000000) {
      return `${(n / 100000000).toFixed(2)}亿`;
    }
    if (n >= 10000) {
      return `${(n / 10000).toFixed(1)}万`;
    }
    return `${n}`;
  }

  private static fmtRate(n: number): string {
    return n >= 1000 ? `${(n / 1000).toFixed(1)}k/分` : `${n.toFixed(0)}/分`;
  }

  private static fmtEta(hours: number): string {
    if (hours >= 24) {
      return `${(hours / 24).toFixed(1)} 天`;
    }
    return `${hours.toFixed(1)} 时`;
  }

  /** 曲线覆盖的时间跨度（采样间隔 2 秒） */
  private static spanText(samples: number): string {
    const sec = samples * 2;
    if (sec >= 60) {
      return `跨度 ${Math.round(sec / 60)} 分钟`;
    }
    return `跨度 ${sec} 秒`;
  }
}
