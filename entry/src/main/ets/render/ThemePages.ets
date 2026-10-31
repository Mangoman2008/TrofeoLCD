/**
 * ThemePages.ets —— 主题 3「分页屏」（搬 ESP32-S3 / DOTII 368×448 的那套 UI）
 *
 * 参考的那套固件 UI 长这样（368×448 竖屏）：
 *   · 顶部状态栏：时钟 / WiFi / 电量 / 连接名
 *   · 中间一页一页翻：表情、DeepSeek 余额、拓竹打印机、自定义、设置
 *   · 底部/侧边页面指示点，页色区分
 *
 * 我们这块屏是 1920×462 的**横长条**（4.16:1），照搬竖屏比例会把内容拉变形，
 * 所以做"拉伸优化"= 保留它的视觉语言（状态栏 + 分页 + 指示点 + 深色底 + 大数值），
 * 但把每一页重排成横向三栏，而不是把 368×448 硬拉宽。
 *
 * 页面：0 打印机 · 1 余额 · 2 DSH 会话 · 3 系统
 * 自动翻页与手动选页由 LcdService 控制（/set?page=N，界面里也能点）。
 */
import type { Telemetry, BalanceInfo, TokenInfo, PrinterInfo, PrinterTray, SystemInfo, TodoItem } from '../common/Types';
import type { RenderExtras } from '../common/Extras';
import { C, L, F } from '../common/Theme';
import { History } from '../common/History';
import { FocusTimer } from '../common/Toasts';
import { Chrome } from './Chrome';
import { FrameStats } from './Dashboard';

export class ThemePages {
  static readonly PAGE_COUNT: number = 4;

  static pageName(p: number): string {
    if (p === 0) {
      return '拓竹打印机';
    }
    if (p === 1) {
      return 'DeepSeek 余额';
    }
    if (p === 2) {
      return 'DSH 会话';
    }
    return '系统状态';
  }

  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                vm: Object | null, vmAgeMs: number, vmErr: string,
                ex: RenderExtras, page: number): void {
    const W = L.width;
    const H = L.height;
    const M = 14;
    Chrome.background(ctx, W, H, ex.bg, 0.6);

    const barH = 46;
    const footH = 34;
    const contentY = M + barH + 8;
    const contentH = H - contentY - footH - M;

    // ---------- 顶部状态栏（时钟 / 连接 / USB / 电量）----------
    Chrome.card(ctx, M, M, W - M * 2, barH, 10, Chrome.alpha(C.panel, 0.92), C.border);
    const d = new Date();
    const p2 = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    const week = ['日', '一', '二', '三', '四', '五', '六'];
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textW;
    ctx.font = F.monoFont(18, 'bold');
    const clock = `${p2(d.getHours())}:${p2(d.getMinutes())}`;
    ctx.fillText(clock, M + 20, M + barH / 2);
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillStyle = C.textS;
    ctx.fillText(`${d.getMonth() + 1}月${d.getDate()}日 周${week[d.getDay()]}`,
      M + 20 + F.scale * 52, M + barH / 2);

    // 中间：当前页名 + 摘要
    ctx.textAlign = 'center';
    ctx.fillStyle = C.cyan;
    ctx.font = F.font(17, 'bold');
    ctx.fillText(ThemePages.pageName(page), W / 2 - 120, M + barH / 2);
    ctx.textAlign = 'left';
    // ★ 摘要按可用宽度截断：右侧还有 USB/桥/VM 三个状态点，过长会与它们压印。
    let smPages: string = ex.summary;
    if (smPages.length > 0) {
      ctx.font = F.fontSub(14, 'normal');
      const room = W / 2 + 150 - (W / 2 - 10);
      const avail = Math.max(120, room + 640);
      if (ctx.measureText(smPages).width > avail) {
        let q = smPages;
        while (q.length > 1 && ctx.measureText(q + '…').width > avail) {
          q = q.substring(0, q.length - 1);
        }
        smPages = q + '…';
      }
    }
    ctx.fillStyle = smPages.length > 0 ? C.textW : C.textD;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText(smPages.length > 0 ? smPages : '（等一句话摘要）',
      W / 2 - 10, M + barH / 2);

    // 右侧：USB / 桥 / VM 三个状态点
    const sys = t.system;
    const usbOk = fs.usbOpen;
    const brOk = fs.bridgeAge >= 0 && fs.bridgeAge < 5;
    const vmOk = vm !== null;
    const chips: string[] = [
      `USB ${usbOk ? '●' : '○'}`, `桥 ${brOk ? '●' : '○'}`, `VM ${vmOk ? '●' : '○'}`
    ];
    const cols: string[] = [
      usbOk ? C.green : C.red, brOk ? C.green : C.orange, vmOk ? C.green : C.orange
    ];
    if (sys !== undefined && sys.battery !== undefined && sys.battery >= 0) {
      chips.push(`电 ${sys.battery.toFixed(0)}%`);
      cols.push(sys.battery < 20 ? C.red : C.green);
    }
    let cx = W - M - 20;
    for (let i = chips.length - 1; i >= 0; i--) {
      ctx.textAlign = 'right';
      ctx.font = F.fontSub(14, 'normal');
      ctx.fillStyle = cols[i];
      ctx.fillText(chips[i], cx, M + barH / 2);
      cx -= ctx.measureText(chips[i]).width + 22;
    }

    // ---------- 内容区：一页一页 ----------
    if (page === 0) {
      ThemePages.bambuPage(ctx, M, contentY, W - M * 2, contentH, t.printer);
    } else if (page === 1) {
      ThemePages.balancePage(ctx, M, contentY, W - M * 2, contentH, t, ex);
    } else if (page === 2) {
      ThemePages.dshPage(ctx, M, contentY, W - M * 2, contentH, t, ex);
    } else {
      ThemePages.systemPage(ctx, M, contentY, W - M * 2, contentH, t, ex, fs);
    }

    // ---------- 底部：页面指示点（照搬它的分页指示）----------
    const dotY = H - M - footH / 2;
    const gap = 16;
    const totalW = ThemePages.PAGE_COUNT * gap * 2;
    let dx = (W - totalW) / 2;
    for (let i = 0; i < ThemePages.PAGE_COUNT; i++) {
      ctx.beginPath();
      ctx.arc(dx + gap / 2, dotY, i === page ? 7 : 4.5, 0, Math.PI * 2);
      ctx.fillStyle = i === page ? C.cyan : Chrome.alpha(C.textD, 0.8);
      ctx.fill();
      dx += gap * 2;
    }
    ctx.textAlign = 'center';
    ctx.fillStyle = C.textD;
    ctx.font = F.monoSub(12, 'normal');
    ctx.fillText(`${page + 1}/${ThemePages.PAGE_COUNT} · 每 10 秒自动翻页（可在应用里锁定）`,
      W / 2, H - M - 22);

    if (ex.toast !== null && Date.now() < ex.toast.until) {
      Chrome.toast(ctx, ex.toast, Date.now(), W, H, 150);
    }
  }

  // ---------------- 页 0：拓竹打印机 ----------------
  private static bambuPage(ctx: CanvasRenderingContext2D, x: number, y: number,
                           w: number, h: number, p: PrinterInfo | undefined): void {
    const cw = (w - 24) / 3;
    if (p === undefined) {
      Chrome.card(ctx, x, y, w, h, 12, C.panel, C.border);
      ctx.textAlign = 'center';
      ctx.fillStyle = C.textD;
      ctx.font = F.font(18, 'normal');
      ctx.fillText('未接打印机监控（桥端 --printer <url>）', x + w / 2, y + h / 2);
      return;
    }
    const perr = (p.monitorMode ?? '') === 'error' || (p.monitorError ?? '').length > 0;
    if (perr) {
      Chrome.card(ctx, x, y, w, h, 12, C.panel, Chrome.alpha(C.red, 0.5));
      ctx.textAlign = 'left';
      ctx.fillStyle = C.red;
      ctx.font = F.font(20, 'bold');
      ctx.fillText('打印机监控未登录', x + 28, y + 52);
      ctx.fillStyle = C.textS;
      ctx.font = F.fontSub(14, 'normal');
      const lines = ThemePages.wrap(ctx, p.monitorError ?? '', F.fontSub(14, 'normal'), w - 60, 3);
      let ly = y + 104;
      for (const ln of lines) {
        ctx.fillText(ln, x + 28, ly);
        ly += 34;
      }
      return;
    }

    const running = p.state === 'RUNNING';
    const accent = running ? C.purple : (p.state === 'OFFLINE' ? C.red : C.green);
    // 左：状态 + 大百分比 + 进度条
    Chrome.card(ctx, x, y, cw, h, 12, C.panel, C.border);
    Chrome.roundRect(ctx, x + 16, y + 1, cw - 32, 3, 1.5);
    ctx.fillStyle = Chrome.alpha(accent, 0.8);
    ctx.fill();
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText('拓竹 P2S', x + 20, y + 30);
    ctx.fillStyle = accent;
    ctx.font = F.font(16, 'bold');
    const lab = (p.stateLabel !== undefined && p.stateLabel.length > 0) ? p.stateLabel : (p.state ?? '');
    ctx.fillText(lab, x + 20, y + 66);
    const pct = p.percent ?? -1;
    ctx.fillStyle = C.textW;
    ctx.font = F.monoFont(34, 'bold');
    ctx.fillText(pct >= 0 ? `${pct}%` : '—', x + 20, y + 140);
    ctx.fillStyle = C.barBg;
    Chrome.roundRect(ctx, x + 20, y + 190, cw - 40, 12, 6);
    ctx.fill();
    if (pct > 0) {
      ctx.fillStyle = accent;
      Chrome.roundRect(ctx, x + 20, y + 190, Math.max(12, (cw - 40) * pct / 100), 12, 6);
      ctx.fill();
    }
    const layer = p.layer ?? -1;
    const tot = p.totalLayer ?? -1;
    ctx.fillStyle = C.textL;
    ctx.font = F.monoSub(14, 'normal');
    ctx.fillText(layer >= 0 ? `${layer}/${tot > 0 ? tot : '?'} 层` : '—', x + 20, y + 226);

    // 中：作业 + 温度
    Chrome.card(ctx, x + cw + 12, y, cw, h, 12, C.panel, C.border);
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText('当前作业', x + cw + 32, y + 30);
    ctx.fillStyle = C.textW;
    ctx.font = F.font(17, 'bold');
    const job = (p.jobName !== undefined && p.jobName.length > 0) ? p.jobName : '（无作业）';
    ctx.fillText(ThemePages.fit(ctx, job, F.font(17, 'bold'), cw - 40), x + cw + 32, y + 74);
    const nz = p.nozzleTemp ?? -1;
    const bd = p.bedTemp ?? -1;
    const ch = p.chamberTemp ?? -1;
    ctx.fillStyle = C.orange;
    ctx.font = F.monoFont(16, 'bold');
    ctx.fillText(`喷 ${nz >= 0 ? nz.toFixed(0) + '°' : '—'}`, x + cw + 32, y + 126);
    ctx.fillText(`床 ${bd >= 0 ? bd.toFixed(0) + '°' : '—'}`, x + cw + 32, y + 172);
    ctx.fillStyle = C.textL;
    ctx.fillText(`腔 ${ch >= 0 ? ch.toFixed(0) + '°' : '—'}`, x + cw + 32, y + 218);

    // 右：AMS 托盘（色块 + 类型 + 余量）
    const rx = x + (cw + 12) * 2;
    Chrome.card(ctx, rx, y, cw, h, 12, C.panel, C.border);
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText('AMS 耗材', rx + 20, y + 30);
    const trays: PrinterTray[] = p.trays ?? [];
    const now = p.trayNow ?? -1;
    let ty = y + 76;
    const lim = trays.length > 3 ? 3 : trays.length;
    for (let i = 0; i < lim; i++) {
      const tr = trays[i];
      const isNow = tr.index === now;
      ctx.fillStyle = tr.color ?? C.barBg;
      Chrome.roundRect(ctx, rx + 20, ty - 12, 26, 26, 6);
      ctx.fill();
      if (isNow) {
        Chrome.roundRect(ctx, rx + 19, ty - 13, 28, 28, 7);
        ctx.strokeStyle = C.textW;
        ctx.lineWidth = 2;
        ctx.stroke();
      }
      ctx.fillStyle = isNow ? C.textW : C.textS;
      ctx.font = F.fontSub(15, 'normal');
      const remain = tr.remain ?? -1;
      ctx.fillText(`${tr.type ?? '?'}${remain >= 0 ? '  ' + remain + '%' : ''}`, rx + 58, ty);
      ty += 42;
    }
    if (trays.length === 0) {
      ctx.fillStyle = C.textD;
      ctx.font = F.fontSub(14, 'normal');
      ctx.fillText('无 AMS 数据', rx + 20, y + 80);
    }
  }

  // ---------------- 页 1：DeepSeek 余额 ----------------
  private static balancePage(ctx: CanvasRenderingContext2D, x: number, y: number,
                             w: number, h: number, t: Telemetry, ex: RenderExtras): void {
    const cw = (w - 12) / 2;
    const bal: BalanceInfo | undefined = t.balance;
    const tk: TokenInfo = t.tokens ?? {};
    const total = bal === undefined || bal.total === undefined ? -1 : bal.total;
    const col = total < 0 ? C.textD : (total < 5 ? C.red : (total < 20 ? C.orange : C.green));

    // 左：余额 + 燃烧 + 还能用多久 + 曲线
    Chrome.card(ctx, x, y, cw, h, 12, C.panel, C.border);
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(15, 'normal');
    ctx.fillText('账户余额（云端实时）', x + 24, y + 34);
    ctx.fillStyle = col;
    ctx.font = F.monoFont(34, 'bold');
    ctx.fillText(total < 0 ? '—' : `${(bal !== undefined && bal.currency === 'USD') ? '$' : '¥'}${total.toFixed(2)}`,
      x + 24, y + 96);
    const perH = bal === undefined || bal.perHour === undefined ? -1 : bal.perHour;
    const eta = bal === undefined || bal.etaHours === undefined ? -1 : bal.etaHours;
    ctx.fillStyle = C.textL;
    ctx.font = F.fontSub(15, 'normal');
    ctx.fillText(`燃烧 ${perH > 0 ? perH.toFixed(2) + ' 元/时' : '攒采样中'}`, x + 24, y + 156);
    ctx.fillText(`还能用 ${eta > 0 ? (eta >= 24 ? (eta / 24).toFixed(1) + ' 天' : eta.toFixed(1) + ' 时') : '—'}`,
      x + 320, y + 156);
    // 余额曲线
    const gx = x + 24;
    const gw = cw - 48;
    const gy = y + 190;
    const gh = h - 210;
    if (gh > 20) {
      Chrome.sparkline(ctx, ex.history.balance, History.CAP, gx, gy, gw, gh, col, true, true);
    }

    // 右：今日 token + token 速率曲线
    Chrome.card(ctx, x + cw + 12, y, cw, h, 12, C.panel, C.border);
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(15, 'normal');
    ctx.fillText('今日 TOKEN', x + cw + 36, y + 34);
    ctx.fillStyle = C.textW;
    ctx.font = F.monoFont(40, 'bold');
    ctx.fillText(ThemePages.fmtTokens(tk.todayTotal ?? 0), x + cw + 36, y + 104);
    const tpm = (t.health !== undefined && t.health.tokensPerMin !== undefined) ? t.health.tokensPerMin : 0;
    ctx.fillStyle = C.cyan;
    ctx.font = F.fontSub(15, 'normal');
    ctx.fillText(`速率 ${tpm >= 1000 ? (tpm / 1000).toFixed(1) + 'k' : tpm.toFixed(0)}/分`,
      x + cw + 36, y + 176);
    const gy2 = y + 200;
    const gh2 = h - 220;
    if (gh2 > 20) {
      ctx.strokeStyle = Chrome.alpha(C.border, 0.9);
      ctx.lineWidth = 1;
      for (let i = 1; i <= 2; i++) {
        const ly = gy2 + gh2 * i / 3;
        ctx.beginPath();
        ctx.moveTo(x + cw + 36, ly);
        ctx.lineTo(x + cw + cw - 36, ly);
        ctx.stroke();
      }
      Chrome.sparkline(ctx, ex.history.tokens, History.CAP, x + cw + 36, gy2, cw - 72, gh2, C.cyan, true, true);
    }
  }

  // ---------------- 页 2：DSH 会话 ----------------
  private static dshPage(ctx: CanvasRenderingContext2D, x: number, y: number,
                         w: number, h: number, t: Telemetry, ex: RenderExtras): void {
    const ag = t.agent;
    const state = ag === undefined || ag.state === undefined ? 'unknown' : ag.state;
    const accent = state === 'busy' ? C.deepseek : (state === 'idle' ? C.green : C.textS);
    const lw = Math.floor(w * 0.62);
    const rw = w - lw - 12;

    Chrome.card(ctx, x, y, lw, h, 12, C.panel, C.border);
    Chrome.roundRect(ctx, x + 16, y + 1, lw - 32, 3, 1.5);
    ctx.fillStyle = Chrome.alpha(accent, 0.8);
    ctx.fill();
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText('项目', x + 24, y + 32);
    ctx.fillStyle = C.textW;
    ctx.font = F.font(24, 'bold');
    ctx.fillText(ThemePages.fit(ctx, ag === undefined || ag.project === undefined ? '—' : ag.project,
      F.font(24, 'bold'), lw - 60), x + 24, y + 78);
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText(`模型 ${ag === undefined || ag.model === undefined ? '—' : ag.model}`,
      x + 24, y + 132);
    ctx.fillStyle = accent;
    ctx.font = F.font(18, 'bold');
    const label = state === 'busy' ? '● 工作中' : (state === 'idle' ? '○ 空闲' : '○ ' + state);
    ctx.fillText(label, x + 24, y + 186);
    if (ag !== undefined && ag.tool !== undefined && ag.tool.length > 0) {
      ctx.fillStyle = C.cyan;
      ctx.font = F.monoSub(15, 'normal');
      ctx.fillText(`工具 ${ag.tool}`, x + 300, y + 186);
    }
    ctx.fillStyle = C.textL;
    ctx.font = F.fontSub(14, 'normal');
    const txt = ex.summary.length > 0 ? `▸ ${ex.summary}`
      : (ag === undefined || ag.lastText === undefined ? '' : ag.lastText);
    const lines = ThemePages.wrap(ctx, txt, F.fontSub(14, 'normal'), lw - 48, 2);
    let ly = y + 222;
    for (const ln of lines) {
      ctx.fillText(ln, x + 24, ly);
      ly += 30;
    }
    if (ex.focus.elapsedMs(Date.now()) > 0) {
      ctx.fillStyle = C.green;
      ctx.font = F.monoSub(13, 'normal');
      ctx.fillText(`专注 ${FocusTimer.fmt(ex.focus.elapsedMs(Date.now()))} · 番茄 ${ex.focus.pomodoros}`,
        x + 24, y + h - 18);
    }

    // 右：待办
    Chrome.card(ctx, x + lw + 12, y, rw, h, 12, C.panel, C.border);
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText('待办', x + lw + 32, y + 30);
    const todos = t.todos ?? [];
    let ty = y + 70;
    const lim = todos.length > 4 ? 4 : todos.length;
    for (let i = 0; i < lim; i++) {
      const td = todos[i];
      const done = td.status === 'completed';
      ctx.fillStyle = done ? C.green : C.textL;
      ctx.font = F.fontSub(14, 'normal');
      ctx.fillText(done ? '✓' : '○', x + lw + 32, ty);
      ctx.fillStyle = done ? C.textD : C.textS;
      const label = ThemePages.todoText(td);
      ctx.fillText(ThemePages.fit(ctx, label, F.fontSub(14, 'normal'), rw - 80), x + lw + 58, ty);
      ty += 34;
    }
    if (todos.length === 0) {
      ctx.fillStyle = C.textD;
      ctx.font = F.fontSub(14, 'normal');
      ctx.fillText('暂无待办', x + lw + 32, y + 76);
    }
  }

  // ---------------- 页 3：系统 ----------------
  private static systemPage(ctx: CanvasRenderingContext2D, x: number, y: number,
                            w: number, h: number, t: Telemetry, ex: RenderExtras,
                            fs: FrameStats): void {
    const cw = (w - 24) / 3;
    const sys: SystemInfo | undefined = t.system;
    const cpu = sys === undefined || sys.cpu === undefined ? 0 : sys.cpu;
    const memPct = (sys !== undefined && sys.memTotal !== undefined && sys.memTotal > 0)
      ? ((sys.memUsed ?? 0) / sys.memTotal * 100) : 0;

    ThemePages.metricCard(ctx, x, y, cw, h, 'CPU', `${cpu.toFixed(0)}%`, C.green, ex.history.cpu, '负载走势');
    ThemePages.metricCard(ctx, x + cw + 12, y, cw, h, '内存', `${memPct.toFixed(0)}%`, C.cyan,
      ex.history.mem, (sys !== undefined && sys.memTotal !== undefined)
        ? `${((sys.memUsed ?? 0) / 1024).toFixed(1)} / ${(sys.memTotal / 1024).toFixed(1)} GB` : '—');

    // 第三栏：本屏自身（推帧/错误/保活/背景）
    Chrome.card(ctx, x + (cw + 12) * 2, y, cw, h, 12, C.panel, C.border);
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText('本屏', x + (cw + 12) * 2 + 20, y + 30);
    const rows: string[] = [
      `推帧 ${fs.sent}`, `错误 ${fs.errors}`, `跳帧 ${fs.skippedFrames}`,
      `渲染 ${fs.renderMs.toFixed(0)}ms`, `编码 ${fs.encodeMs.toFixed(0)}ms`, `推送 ${fs.pushMs.toFixed(0)}ms`
    ];
    let ry = y + 72;
    for (let i = 0; i < rows.length; i++) {
      ctx.fillStyle = i % 2 === 0 ? C.textW : C.textL;
      ctx.font = F.monoSub(15, 'normal');
      ctx.fillText(rows[i], x + (cw + 12) * 2 + 20, ry);
      ry += 30;
    }
  }

  private static metricCard(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
                            title: string, value: string, color: string,
                            s: import('../common/History').Series, sub: string): void {
    Chrome.card(ctx, x, y, w, h, 12, C.panel, C.border);
    Chrome.roundRect(ctx, x + 16, y + 1, w - 32, 3, 1.5);
    ctx.fillStyle = Chrome.alpha(color, 0.8);
    ctx.fill();
    ctx.textAlign = 'left';
    ctx.fillStyle = C.textS;
    ctx.font = F.fontSub(14, 'normal');
    ctx.fillText(title, x + 20, y + 30);
    ctx.fillStyle = color;
    ctx.font = F.monoFont(34, 'bold');
    ctx.fillText(value, x + 20, y + 86);
    ctx.fillStyle = C.textD;
    ctx.font = F.fontSub(13, 'normal');
    ctx.fillText(sub, x + 20, y + 150);
    const gy = y + 170;
    const gh = h - 190;
    if (gh > 20) {
      Chrome.sparkline(ctx, s, History.CAP, x + 20, gy, w - 40, gh, color, true, true);
    }
  }

  // ---------------- 小工具 ----------------
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

  private static fit(ctx: CanvasRenderingContext2D, text: string, font: string, maxW: number): string {
    ctx.font = font;
    if (text.length === 0 || ctx.measureText(text).width <= maxW) {
      return text;
    }
    let s = text;
    while (s.length > 1 && ctx.measureText(s + '…').width > maxW) {
      s = s.substring(0, s.length - 1);
    }
    return s + '…';
  }

  /** 待办文本：TodoItem 只有 content 字段（以前这里猜了 text/title，编译期就报错了） */
  private static todoText(td: TodoItem): string {
    const c: string | undefined = td.content;
    if (c !== undefined && c.length > 0) {
      return c;
    }
    return '';
  }

  private static fmtTokens(n: number): string {
    if (n >= 100000000) {
      return `${(n / 100000000).toFixed(2)}亿`;
    }
    if (n >= 10000) {
      return `${(n / 10000).toFixed(1)}万`;
    }
    return `${n}`;
  }
}
