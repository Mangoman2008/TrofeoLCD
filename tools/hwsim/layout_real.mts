// layout_real.mts —— 用**真源码** Dashboard.ets 跑一遍渲染，把每个文字框吐成 JSON
//
// 与 tools/preview.py（手工镜像）的区别：这个跑的是 entry/src/main/ets/render/Dashboard.ets
// 本身，所以"改了源码审计却看不见"这类问题从根上没了。
//
// 用法： node tools/hwsim/layout_real.mts [--vertical]  （由 tools/layout_check.py 调用）
import { makeShim } from './canvas_shim.ts';
import { Dashboard, FrameStats } from '../../.verify/render/Dashboard.ts';
import { ThemeDiag } from '../../.verify/render/ThemeDiag.ts';
import { ThemeWall } from '../../.verify/render/ThemeWall.ts';
import { ThemePages } from '../../.verify/render/ThemePages.ts';
import { ThemePong, pongInit, pongTick as pongTickForAudit } from '../../.verify/render/ThemePong.ts';
import { ThemeDotii, DotiiState } from '../../.verify/render/ThemeDotii.ts';
import { ThemeFwSim, FwSimState } from '../../.verify/render/ThemeFwSim.ts';
import { ThemeTrcc, TrccState } from '../../.verify/render/ThemeTRCC.ts';
import { ThemeMac } from '../../.verify/render/ThemeMac.ts';
import { ThemeDotiiCell, DotiiCellInfo } from '../../.verify/render/ThemeDotiiCell.ts';
import { ThemeAnimeBG } from '../../.verify/render/ThemeAnimeBG.ts';
import { ThemeAnimeFree } from '../../.verify/render/ThemeAnimeFree.ts';
import { ThemeAnimeHUD } from '../../.verify/render/ThemeAnimeHUD.ts';
import { ThemeNanoMuse } from '../../.verify/render/ThemeNanoMuse.ts';
import { ThemeTrofeoRust } from '../../.verify/render/ThemeTrofeoRust.ts';
// ★ 2026-10-31 C3 补：ThemeAnime 此前漏了 import（只引了 BG/Free/HUD 三个变体），
//   --theme=10 直接 ReferenceError 崩溃 —— 主题 10 的布局审计从来没跑成过。
import { ThemeAnime } from '../../.verify/render/ThemeAnime.ts';
import { ThemeSnake, SnakeState } from '../../.verify/render/ThemeSnake.ts';
import { ThemeWeather } from '../../.verify/render/ThemeWeather.ts';
import { WeatherData, WxCond } from '../../.verify/service/WeatherService.ts';
import { History } from '../../.verify/render/../common/History.ts';
import { FocusTimer } from '../../.verify/render/../common/Toasts.ts';
import { L, V } from '../../.verify/common/Theme.ts';
import type { Telemetry } from '../../.verify/common/Types.ts';

// ★ 时钟钉死（2026-10-31 审计 C3）：主题 13/14/15 的时钟/时长文字直接取 Date.now()
//   （ThemeAnimeHUD:108、ThemeNanoMuse:121、ThemeTrofeoRust:214/219/234），
//   真时钟下文字宽度逐次漂移 → 审计结果不可复现（基线 13=20/14=58/15=6 个问题在抖）。
//   钉死后时钟、弹窗剩余、专注计时的文字全部确定 → 审计逐字节可复现。
//   1730000000000 ≈ 2024-10-27 22:13:20（UTC+8）。
const PINNED_NOW = 1730000000000;
Date.now = (): number => PINNED_NOW;
// ★ 无参 `new Date()` 同样要钉（ThemeAnime:316 / BG:377 / Free:117 / HUD:434 /
//   NanoMuse:237 的时钟走构造器，只钉 Date.now 会漏）。带参构造（主题 5/6/9/18
//   传的显式时间戳）原样放行。
const RealDate = Date;
class PinnedDate extends RealDate {
  constructor(ms?: number | string) {
    if (ms === undefined) {
      super(PINNED_NOW);
    } else {
      super(ms);
    }
  }
}
(globalThis as any).Date = PinnedDate;

function sampleTelemetry(): Telemetry {
  const t: any = {};
  t.agent = {
    state: 'busy', activity: '执行命令', tool: 'bash',
    lastText: '我先去查一下这个屏幕的协议，确认握手参数和分辨率的消歧规则，然后再决定实现方案与验证路径，最后给你一个可跑的版本。',
    turn: 26, step: 6, project: 'WorkBuddy',
    sessionId: 'session-98fcbada-d9cd-4ef3-bbe2-2ae6224524ac',
    model: 'deepseek-v4-flash', provider: 'deepseek-official'
  };
  t.todos = [
    { content: '实现 shell 侧数据桥（尾部 zstd 解压 + 归一化）', status: 'completed' },
    { content: '构建签名 HAP 并在真机验证', status: 'in_progress' },
    { content: '接入拓竹打印机面板', status: 'pending' },
    { content: '写文档与交接说明', status: 'pending' }
  ];
  t.tokens = {
    todayInput: 306116, todayOutput: 499277, todayTotal: 805393,
    contextUsed: 567212, contextWindow: 1000000, costUsd: 0.1234
  };
  t.system = {
    cpu: 65.7, cores: 14, memUsed: 20817, memTotal: 23859,
    load1: 25.3, load5: 25.27, load15: 22.04,
    uptimeSec: 132886, host: 'localhost', cpuTemp: -1,
    battery: 82, charging: true
  };
  // 余额也要给：否则审计只验到"没有余额"的分支（'—'），真机上那行 ¥xx.xx + 明细行从没被审过
  t.events = [
    { t: '22:31:15', k: 'info', s: '桥已启动 · 项目 WorkBuddy · session-8a52035a' },
    { t: '22:31:36', k: 'busy', s: '状态 ? → busy' },
    { t: '22:31:36', k: 'tool', s: '调用工具 bash' },
    { t: '22:31:37', k: 'busy', s: '执行命令' },
    { t: '22:31:40', k: 'todo', s: '待办 0/0' },
    { t: '22:32:02', k: 'busy', s: '我先去查一下这个屏幕的协议，确认握手参数和分辨率…' },
    { t: '22:32:20', k: 'tool', s: '调用工具 edit' },
    { t: '22:32:41', k: 'err', s: '余额取数失败 请求失败: TimeoutError' },
    { t: '22:33:05', k: 'print', s: '打印机 printing' },
    { t: '22:33:30', k: 'idle', s: '状态 busy → idle' },
    { t: '22:34:02', k: 'busy', s: '继续排版审计' },
    { t: '22:34:40', k: 'tool', s: '调用工具 bash' }
  ];
  t.balance = { currency: 'CNY', total: 48.86, granted: 0, toppedUp: 48.86, available: true, error: '' };
  t.weather = { text: '晴', tempC: 18 };
  t.printer = {
    state: 'RUNNING', percent: 42, layer: 120, totalLayer: 300,
    nozzleTemp: 220, bedTemp: 60, chamberTemp: 35, fanSpeed: 100, speed: 4,
    remainingMin: 88, jobName: 'ws18 支架', model: 'P2S',
    trays: [
      { color: '#FF0000', type: 'PLA', empty: false },
      { color: '#00FF00', type: 'PLA', empty: false }
    ]
  };
  return t as Telemetry;
}

/** 主题 18 的天气样本：字段全给真值（ok 分支），24h 曲线 + 7 天预报全部有内容可审 */
function sampleWeather(): WeatherData {
  const d = new WeatherData();
  d.ok = true;
  d.city = '深圳';
  d.lat = 22.5431;
  d.lon = 114.0579;
  d.tempC = 26.4;
  d.feelsC = 27.2;
  d.humidity = 68;
  d.windKph = 12.3;
  d.windDeg = 135;
  d.cond = WxCond.CLOUDY;
  d.code = 2;
  // 24h 温度：日内正弦周期（从当前小时起的"未来"曲线）
  d.hourly = [];
  for (let i = 0; i < 24; i++) {
    d.hourly.push(Math.round((23 + 4 * Math.sin((i / 24) * Math.PI * 2 - Math.PI / 2)) * 10) / 10);
  }
  d.dMin = [21, 22, 22, 20, 19, 20, 21];
  d.dMax = [28, 29, 27, 25, 24, 26, 27];
  d.dCond = [WxCond.CLOUDY, WxCond.CLEAR, WxCond.RAIN, WxCond.RAIN,
    WxCond.CLOUDY, WxCond.CLEAR, WxCond.CLEAR];
  d.atMs = PINNED_NOW;
  d.errText = '';
  return d;
}

const vertical = process.argv.includes('--vertical');
const shim = makeShim();
const fs = new FrameStats();
fs.usbOpen = true;
fs.usbLabel = 'USBDISPLAY (416:5408)';
fs.jpegW = 1920;
fs.jpegH = 462;
fs.jpegSize = 100724;
fs.sent = 1280;
fs.errors = 0;
fs.fps = 4.2;
fs.renderMs = 2.4;
fs.encodeMs = 50;
fs.pushMs = 104;
fs.quality = 0.9;
fs.bridgeAge = 1;

// 历史曲线塞一些真实感的采样点（正弦 + 噪声），否则曲线那段不被审
const hist = new History();
let seed = 7;
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
for (let i = 0; i < 60; i++) {
  hist.sample(i * 2000, 40 + 30 * Math.sin(i / 6) + rnd() * 8,
              55 + 12 * Math.sin(i / 9) + rnd() * 6,
              2000 + 1500 * Math.sin(i / 5) + rnd() * 400,
              48 - i * 0.02 + rnd() * 0.05);
}
const focus = new FocusTimer();
focus.tick(0, true);
const noToast = process.argv.includes('--no-toast');
// 打印机"监控未登录"分支也要审：这条分支在真机上正好是当前状态，不能只审正常打印
const printerError = process.argv.includes('--printer-error');
const extras = {
  history: hist,
  toast: noToast ? null : { text: '待办完成 3/6', kind: 'ok', until: Date.now() + 4000 },
  focus,
  bg: null,
  summary: '给副屏加历史曲线和余额燃烧速率'
};

const themeArg = process.argv.find((a) => a.startsWith('--theme='));
const theme = themeArg ? Number(themeArg.split('=')[1]) : 0;
const tm = sampleTelemetry();
if (printerError && tm.printer) {
  tm.printer.state = 'UNKNOWN';
  tm.printer.stateLabel = '未知';
  tm.printer.monitorMode = 'error';
  tm.printer.monitorError = 'cn 区返回 401: 请登录账号!';
  tm.printer.percent = -1;
  tm.printer.trays = [];
}
const pageArg = process.argv.find((a) => a.startsWith('--page='));
const page = pageArg ? Number(pageArg.split('=')[1]) : 0;
if (theme === 3) {
  (ThemePages as any).render(shim, tm, fs, null, 320, '', extras, page);
} else if (theme === 4) {
  // 主题 4「打砖块」：确定性种子 → 逐帧可复现，审计结果稳定
  const pong = pongInit(20261014);
  for (let i = 0; i < 120; i++) {
    pongTickForAudit(pong);
  }  pong.hour = 14;
  pong.minute = 26;
  pong.dateText = '周二 10月14日';
  (ThemePong as any).render(shim, pong, true, 25, 6);
} else if (theme === 5) {
  // 主题 5「Dotii 分页屏」：固定数据 + 固定时刻 → 审计可复现
  const ds = new DotiiState();
  ds.page = page; ds.hour = 14; ds.minute = 26; ds.batt = 78; ds.charging = false;
  ds.wifiText = '已连接'; ds.wifiOk = true; ds.connText = 'GXSZ-2.4G · 192.168.11.134';
  ds.balanceOk = true; ds.balanceTotal = 34.75; ds.balanceGranted = 0; ds.balanceTopped = 34.75;
  ds.prState = 'RUNNING'; ds.prPct = 63; ds.prModel = 'Bambu Lab P2S';
  ds.prNozzle = 220; ds.prBed = 60; ds.prLayer = 142; ds.prTotalLayer = 226;
  ds.prRemainSec = 4320; ds.prMaterial = 'PLA Basic';
  (ThemeDotii as any).render(shim, ds, 1700000000000);
} else if (theme === 6) {
  // 主题 6「固件仿真屏」：固定数据 + 固定界面 → 审计可复现
  const fw = new FwSimState();
  fw.screen = Number(process.argv.find((a) => a.startsWith('--fws='))?.split('=')[1] ?? 8);
  fw.hour = 14; fw.minute = 26; fw.dateText = '周二 10月14日';
  fw.prState = 'RUNNING'; fw.prModel = 'Bambu Lab P2S'; fw.prJob = 'plate_ws18_full.3mf';
  fw.prPct = 63; fw.prNozzle = 220; fw.prBed = 60; fw.prLayer = 142; fw.prTotalLayer = 226;
  fw.prRemainMin = 72; fw.prTrays = 3;
  fw.balTotal = '38.93'; fw.balGranted = '0.00'; fw.balTopped = '38.93'; fw.balStatus = '可用';
  fw.wifiText = 'USB 已连接'; fw.ssid = 'GXSZ-2.4G'; fw.ip = '192.168.11.134';
  (ThemeFwSim as any).render(shim, fw, 1700000000000, 0, 620, 0);
} else if (theme === 7) {
  // 主题 7「官方浅色风」：固定数据 → 审计可复现
  const tc = new TrccState();
  tc.palette = Number(process.argv.find((a) => a.startsWith('--trcc='))?.split('=')[1] ?? 0);
  tc.hour = 17; tc.minute = 3; tc.dateText = '星期六  2025/05/17';
  tc.cpuTemp = 50; tc.cpuLoadPct = 1;
  tc.cpuFreqMhz = 3593; tc.gpuLabel = 'TOKEN'; tc.gpuFreqMhz = 128; tc.gpuLoadPct = -1;
  (ThemeTrcc as any).render(shim, tc, 0, 620, 0);
} else if (theme === 8) {
  (ThemeMac as any).render(shim, tm, fs, extras, 0, 620, 0);
} else if (theme === 9) {
  // 主题 9「打印机位 Dotii」：Dotii 进打印机格（借位档 mode=1）
  // ★ 2026-10-15 补：以前没有这个分支 → --theme=9 会**回落到仪表盘**，
  //   审计报"干净"其实审的是仪表盘，这个主题从来没被查过。
  const ds9 = new DotiiState();
  ds9.page = page; ds9.hour = 14; ds9.minute = 26;
  ds9.balanceHasValue = true; ds9.balanceTotal = '34.75';
  ds9.balanceGranted = '0.00'; ds9.balanceTopped = '34.75'; ds9.balanceStatus = '可用';
  ds9.prState = 'RUNNING'; ds9.prPct = 63; ds9.prStatusText = '打印中';
  ds9.prLayer = 142; ds9.prTotalLayer = 226; ds9.prNozzle = 220; ds9.prBed = 60;
  ds9.connText = 'GXSZ-2.4G'; ds9.batt = 78; ds9.wifiOn = true;
  const dci = new DotiiCellInfo();
  (ThemeDotiiCell as any).render(shim, ds9, 1700000000000, dci, tm.printer, 0, 620, 0, 1);
} else if (theme === 10) {
  (ThemeAnime as any).render(shim, tm, fs, extras, 0, 620, 0);
} else if (theme === 11) {
  (ThemeAnimeBG as any).render(shim, tm, fs, extras, 0, 620, 0);
} else if (theme === 12) {
  (ThemeAnimeFree as any).render(shim, tm, fs, extras, 0, 620, 0);
} else if (theme === 13) {
  (ThemeAnimeHUD as any).render(shim, tm, fs, extras, 0, 620, 0);
} else if (theme === 14) {
  (ThemeNanoMuse as any).render(shim, tm, fs, extras, 0, 620, 0);
} else if (theme === 15) {
  (ThemeTrofeoRust as any).render(shim, fs, 0, 620, 0);
} else if (theme === 16) {
  // 主题 16「自走贪吃蛇」：照 LcdService:3212-3217 的真实路径
  //   （new SnakeState → reset 58×14 → step → 全屏 draw）。
  //   reset 的食物落点由 nowMs 播种（snkSeed）→ 钉死后棋局确定、审计可复现。
  const snake = new SnakeState();
  ThemeSnake.reset(snake, PINNED_NOW, 58, 14);
  ThemeSnake.step(snake, PINNED_NOW);
  (ThemeSnake as any).draw(shim, 0, 0, 1920, 462, snake, PINNED_NOW);
} else if (theme === 17) {
  // 主题 17「超级玛丽」：真实入口就是 LcdService:3207 的 Dashboard.mario.drawFullscreen。
  //   mario 链零 Math.random、零 Date.now（2026-10-31 已核），nowMs 钉死 → 逐字节可复现；
  //   step 的 dt 有 MAX_DT 钳制，首帧不会模拟"从 1970 年到现在"。
  (Dashboard.mario as any).drawFullscreen(shim, 1920, 462, PINNED_NOW);
} else if (theme === 18) {
  // 主题 18「天气」：真实路径 LcdService:3201 —— ThemeWeather.render(ctx, now, wx.data)。
  //   24h/7d 数组给足真实感的数据，让 24h 曲线与 7 天条全部被审到。
  (ThemeWeather as any).render(shim, PINNED_NOW, sampleWeather());
} else if (theme === 1) {
  (ThemeDiag as any).render(shim, tm, fs, null, 320, '', extras);
} else if (theme === 2) {
  (ThemeWall as any).render(shim, tm, fs, null, 320, '', extras);
} else {
  (Dashboard as any).render(shim, tm, fs, null, 320, '', vertical, extras);
}

// 面板矩形也由真源码的 Theme 常量算出来 —— 检查脚本里不再需要"镜像"任何布局数字
// 主题 1（诊断终端）自己的分区：标题行 / 事件流 / 右侧指标栏 / 底部体检条
const M = 14, metaH = 54, footH = 40, rightW = 520;
const diagPanels = [
  { name: '标题行', x: M, y: M, w: 1920 - M * 2, h: metaH + 50 },   // 含下方的一行摘要
  { name: '事件流', x: M, y: M + metaH + 14, w: 1920 - M * 2 - rightW - 12, h: 462 - (M + metaH + 14) - footH - M },
  { name: '指标栏', x: 1920 - M - rightW, y: M + metaH + 6, w: rightW, h: 462 - M - footH - metaH - 12 },
  { name: '底部体检条', x: M, y: 462 - M - footH + 4, w: 1920 - M * 2, h: footH - 8 }
];
// 主题 2（监控墙）自己的分区：标题行 / 三张曲线卡 / 余额卡 / 状态卡
const wGap = 12;
const wCw = (1920 - M * 2 - wGap * 3) / 4;
const wallPanels = [
  { name: '标题行', x: M, y: M, w: 1920 - M * 2, h: 56 },
  { name: '曲线卡1', x: M, y: M + 56, w: wCw, h: 196 },
  { name: '曲线卡2', x: M + wCw + wGap, y: M + 56, w: wCw, h: 196 },
  { name: '曲线卡3', x: M + (wCw + wGap) * 2, y: M + 56, w: wCw, h: 196 },
  { name: '打印卡', x: M + (wCw + wGap) * 3, y: M + 56, w: wCw, h: 196 },
  { name: '余额卡', x: M, y: M + 56 + 196 + wGap, w: wCw * 2 + wGap, h: 462 - M - (M + 56 + 196 + wGap) },
  { name: '状态卡', x: M + (wCw * 2 + wGap) + wGap, y: M + 56 + 196 + wGap, w: wCw,
    h: 462 - M - (M + 56 + 196 + wGap) }
];
const pagesPanels = [
  { name: '状态栏', x: 14, y: 14, w: 1892, h: 46 },
  { name: '内容区', x: 14, y: 68, w: 1892, h: 346 },
  { name: '底部', x: 14, y: 414, w: 1892, h: 34 }
];
// 主题 4「打砖块」：整屏一张画布，没有面板分区（源固件就是全屏画的）
const pongPanels = [{ name: '打砖块', x: 0, y: 0, w: 1920, h: 462 }];
const dotiiPanels = [{ name: 'Dotii', x: 0, y: 0, w: 1920, h: 462 }];
const fwPanels = [{ name: '固件仿真', x: 0, y: 0, w: 1920, h: 462 }];
const trccPanels = [{ name: '官方浅色风', x: 0, y: 0, w: 1920, h: 462 }];
const macPanels = [{ name: 'MacTR', x: 0, y: 0, w: 1920, h: 462 }];
// 主题 0：横装（等宽档 / ⑥b 加宽档，跟着 Theme 的 usPanelVisible 走）与竖装两套分区
const dashPanels = [
  { name: '系统', x: L.panelX(0), y: L.panelY, w: L.panelWidth, h: L.panelHeight },
  { name: 'DSH 会话', x: L.panelX(1), y: L.panelY,
    w: L.usPanelVisible ? (L.panelWidth * 2 + L.gap) : L.agentWWide, h: L.panelHeight },
  ...(L.usPanelVisible
    ? [{ name: '用量与时钟', x: L.usX, y: L.panelY, w: L.panelWidth, h: L.panelHeight }]
    : []),
  { name: '打印机', x: L.usPanelVisible ? L.prX : L.prXWide, y: L.prY, w: L.prW, h: L.prH },
  { name: 'VM 画面', x: L.vmX, y: L.vmY, w: L.vmW, h: L.vmH }
];
const dashPanelsV = [
  { name: '顶部时钟(V)', x: 0, y: V.hdrY, w: V.width, h: V.hdrH },
  { name: 'VM 画面(V)', x: 0, y: V.vmY, w: V.width, h: V.vmH },
  { name: '系统(V)', x: 0, y: V.sysY, w: V.width, h: V.sysH },
  { name: 'DSH(V)', x: 0, y: V.agY, w: V.width, h: V.agH },
  { name: '用量(V)', x: 0, y: V.usY, w: V.width, h: V.usH }
];
let panels = dashPanels;
if (theme === 3) {
  panels = pagesPanels;
} else if (theme === 4) {
  panels = pongPanels;
} else if (theme === 5) {
  panels = dotiiPanels;
} else if (theme === 6) {
  panels = fwPanels;
} else if (theme === 7) {
  panels = trccPanels;
} else if (theme === 8) {
  panels = macPanels;
} else if (theme >= 9 && theme <= 18) {
  // ★ 2026-10-15 补：主题 9~15 是**整屏主题**（没有五格/卡片分区）。
  //   以前没有对应面板矩形，全部回落到 dashPanels（仪表盘五格）
  //   → "越出面板(DSH 会话)"这类报错全是**假问题**（内容本来就不在那些格子里）。
  //   改用整张画布：仍能查出"越出画布"，但不再拿仪表盘的格子去套它们。
  //   2026-10-31 C3：16（贪吃蛇全屏棋盘）/17（玛丽全屏）/18（天气全屏）同为整屏主题。
  panels = [{ name: '整屏', x: 0, y: 0, w: 1920, h: 462 }];
} else if (theme === 2) {
  panels = wallPanels;
} else if (theme === 1) {
  panels = diagPanels;
} else if (vertical) {
  panels = dashPanelsV;
}

console.log(JSON.stringify({
  theme,
  vertical,
  frame: vertical ? { w: V.width, h: V.height } : { w: L.width, h: L.height },
  panels,
  texts: shim.texts,
  lines: shim.lines,
  rects: shim.rects
}));
