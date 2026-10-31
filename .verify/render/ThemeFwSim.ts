/**
 * ThemeFwSim.ets —— 主题 6「固件仿真屏」
 *
 * 目的（用户 2026-10-14）：**把 ESP32-S3 那版固件的 UI 搬到这块 1920×462 上做仿真显示**。
 *   · 固件本体在 `~/Documents/拓竹P2S开发/备份-阶段-20261009-0046/`（源码 162 文件 + 刷机工具）
 *   · 固件支持 10 多块板子（`源码/boards/*.ini`），**不支持 1920×462**（源码里 grep 1920 = 0），
 *     所以只能把它的 UI 逐条抄过来重画，不能刷固件驱动本屏。
 *   · UI 是程序化绘制（不是位图），因此可以做到像素级忠实。
 *
 * 摆放（用户："你不是搞了打砖块吗？就按那个分辨率啊"）：
 *   · 与主题 4「打砖块」同一块区域 —— 逻辑 343×418，屏幕居中（origin ≈ 788,22）
 *   · 固件 UI 原生 240×240（S3 的 AMOLED 版是 368×448，本文件先按 240×240 抄，
 *     layout_368x448.h 的差异后面再补）→ **×1.4 = 336×336**，在区内居中
 *   · 两侧沿用打砖块那套信息栏
 *
 * 逐条来源（行号即出处，改代码时请对照原文件）：
 *   src/display_ui.h:12        18 个界面的枚举（SCREEN_*）
 *   include/config.h:72-92     RGB565 配色宏（本文件注释里给出换算后的 hex）
 *   include/layout_default.h   240 面板的版面常量（LY_*）
 *   src/clock_mode.cpp:17-19   时钟字模基准 CLK_BASE_W/H/COLON = 32/48/12
 *   src/clock_mode.cpp:387     drawClock()：时间居中、日期在下、底部信息行
 *   src/display_ui.cpp:6115+   各界面的分发
 */

import { Chrome } from './Chrome.ts';

// ---------------------------------------------------------------------------
// 坐标与缩放
// ---------------------------------------------------------------------------
/**
 * 固件 UI 的设计画布：**368×448**，即固件里的 `env:ws_amoled_18`
 * （`BOARD_PANEL="CO5300_368x448_QSPI"` + `DISPLAY_368x448=1`，
 * 见 源码/platformio.ini:208-227），版式常量取 `include/layout_368x448.h`。
 * 固件还有 240×240（C3/S3 mini）等其他档位，别混。
 */
const FW_W: number = 368;
const FW_H: number = 448;
/** 缩放：368×448 → 343×418 = ×0.9333（与主题 4 打砖块、主题 5 Dotii 同一套变换） */
const FW_SCALE: number = 0.9333;
/** 与打砖块同一块区域 */
const AREA_W: number = 343;
const AREA_H: number = 418;
const AREA_X: number = Math.round((1920 - AREA_W) / 2);
const AREA_Y: number = Math.round((462 - AREA_H) / 2);
/** 固件 UI 左上角（区内居中） */
const UI_X: number = AREA_X + (AREA_W - FW_W * FW_SCALE) / 2;
const UI_Y: number = AREA_Y + (AREA_H - FW_H * FW_SCALE) / 2;

export const FWSIM_PANEL_W: number = 758;

// ---------------------------------------------------------------------------
// 配色（config.h:72-92 的 RGB565 → hex，一条条换算过来的，别改）
// ---------------------------------------------------------------------------
class FwColors {
  bg: string = '#000000';         // CLR_BG        0x0000（原值）
  card: string = '#1E2A38';       // CLR_CARD      0x1926 → 预补偿 +6
  header: string = '#181C18';     // CLR_HEADER    0x10A2 → 预补偿 +8
  text: string = '#FFFFFF';       // CLR_TEXT_DEFAULT 0xFFFF
  dim: string = '#C5C2C5';        // CLR_TEXT_DIM  0xC618
  dark: string = '#7B7D7B';       // CLR_TEXT_DARK 0x7BEF
  green: string = '#20E020';      // CLR_GREEN     0x07E0 → 预补偿（纯绿被压一半）
  greenDark: string = '#0A8C0A';  // CLR_GREEN_DARK 0x0400 → 预补偿
  blue: string = '#4AA0F0';       // CLR_BLUE      0x34DF → 提亮，压后仍看得出蓝
  orange: string = '#F08818';     // CLR_ORANGE    0xFBE0 → 降饱和
  cyan: string = '#30D8E0';       // CLR_CYAN      0x07FF → 纯青压后几乎归零，必须降饱和
  red: string = '#F01010';        // CLR_RED       0xF800 → 预补偿
  yellow: string = '#F0E828';     // CLR_YELLOW    0xFFE0 → 略降
  gold: string = '#F0CC20';       // CLR_GOLD      0xFEA0 → 略降
  track: string = '#20261F';      // CLR_TRACK     0x18E3 → 预补偿 +6
}
const FW: FwColors = new FwColors();

// ---------------------------------------------------------------------------
// 18 个界面（display_ui.h:12-30 的 enum 顺序，一字不差）
// ---------------------------------------------------------------------------
export const FW_SCREENS: string[] = [
  'splash', 'ap_mode', 'connecting_wifi', 'wifi_connected', 'connecting_mqtt',
  'idle', 'printing', 'finished', 'clock', 'off', 'ota_update', 'split',
  'camera', 'power_confirm', 'dry_peek', 'hms', 'face', 'balance'
];
export const FW_SCREEN_LABELS: string[] = [
  '启动画面', '配网热点', '连接 WiFi', 'WiFi 已连', '连接 MQTT',
  '空闲', '打印中', '完成', '时钟·打砖块', '息屏', 'OTA 升级', '双机分屏',
  '相机画面', '电源确认', '烘干查看', '错误详情', '表情', '余额'
];
export const FW_SCREEN_COUNT: number = FW_SCREENS.length;

/**
 * ★ 用户 2026-10-14 定：这块屏**只需要 4 个界面** ——
 * 打印中(6) / 表情(16) / 打砖块时钟(8) / 余额(17)。
 * 自动轮播只走这 4 个；其它界面（启动/配网/OTA/分屏/相机/电源确认/烘干/错误…）
 * 代码保留，用 /set?fws=N 仍可定点查看（N 是 display_ui.h 的原始枚举号）。
 */
export const FW_ROTATION: number[] = [6, 16, 8, 17];
export const FW_ROTATION_LABELS: string[] = ['打印中', '表情', '打砖块时钟', '余额'];

/** 仿真状态（由 LcdService 每帧按实时遥测填） */
export class FwSimState {
  /** 当前界面 0..17 */
  screen: number = 6;                 // 默认"打印中"（用户要的 4 个界面里的第一个）
  /** 24 小时制 */
  use24h: boolean = true;
  hour: number = 0;
  minute: number = 0;
  second: number = 0;
  dateText: string = '';
  /** 打印机 */
  prState: string = '';
  prModel: string = '';
  prJob: string = '';
  prPct: number = -1;
  prNozzle: number = -1;
  prBed: number = -1;
  prChamber: number = -1;
  prLayer: number = -1;
  prTotalLayer: number = -1;
  prRemainMin: number = -1;
  prEta: string = '';
  prTrays: number = 0;
  /** 余额（DeepSeek） */
  balTotal: string = '--';
  balGranted: string = '--';
  balTopped: string = '--';
  balStatus: string = '离线';
  /** 连接信息（底部信息行与配网页用） */
  wifiText: string = '未配置';
  ssid: string = '';
  ip: string = '';
  /** 表情（face 屏） */
  expr: number = 0;
  /** 时钟屏是否跑打砖块时钟（源 dispSettings.pongClock；drawClock() 只在关掉时才画普通时钟） */
  pongClock: boolean = true;
  /** OTA 升级屏（源 drawOtaUpdate：标题/进度条/百分比/状态/警告） */
  otaPct: number = 0;
  otaStatus: string = '准备中';
  /** 错误详情屏（源 drawHmsScreen） */
  hmsCount: number = 0;
  hmsLabel: string = '';
  hmsDetail: string = '';
  /** 烘干屏（源 drawIdleDrying：腔温 + 湿度） */
  dryTemp: number = -1;
  dryHumidity: number = -1;
  dryRemainMin: number = -1;
  /** 相机屏 */
  cameraOk: boolean = false;
  /** 第二台打印机（分屏屏用；数据源同第一台） */
  pr2Model: string = '';
  pr2State: string = '';
  pr2Pct: number = -1;
  /** 打砖块时钟的实时状态（由 LcdService 每帧从主题 4 那套物理状态机搬过来） */
  pongBallX: number = -1;
  pongBallY: number = -1;
  pongPaddleX: number = 184;
  pongBricks: boolean[][] = [];
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------
export class ThemeFwSim {
  static readonly NAME: string = '固件仿真屏';
  static readonly SCREEN_COUNT: number = FW_SCREEN_COUNT;

  static render(ctx: CanvasRenderingContext2D, st: FwSimState, nowMs: number,
                vig: number = 0, vigReach: number = 620, vigCorner: number = 0): void {
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, 1920, 462);

    ThemeFwSim.leftPanel(ctx, st);
    ThemeFwSim.rightPanel(ctx, st);

    // 仿真窗口外框（与打砖块同一块区域，一眼看出是"屏中屏"）
    ctx.strokeStyle = '#262A3A';
    ctx.lineWidth = 2;
    ctx.strokeRect(UI_X - 8, UI_Y - 6, FW_W * FW_SCALE + 16, FW_H * FW_SCALE + 12);

    // ---- 固件 UI：一次缩放变换，之后所有坐标都按固件的 240×240 写 ----
    ctx.save();
    ctx.translate(UI_X, UI_Y);
    ctx.scale(FW_SCALE, FW_SCALE);

    // 固件每屏都是整屏黑底起手（CLR_BG）
    ctx.fillStyle = FW.bg;
    ctx.fillRect(0, 0, FW_W, FW_H);

    const s = st.screen % FW_SCREEN_COUNT;
    switch (s) {
      case 0: ThemeFwSim.splash(ctx, st); break;
      case 1: ThemeFwSim.apMode(ctx, st); break;
      case 2: ThemeFwSim.connectingWifi(ctx, st); break;
      case 3: ThemeFwSim.wifiConnected(ctx, st); break;
      case 4: ThemeFwSim.connectingMqtt(ctx, st); break;
      case 5: ThemeFwSim.idle(ctx, st); break;
      case 6: ThemeFwSim.printing(ctx, st, nowMs); break;
      case 7: ThemeFwSim.finished(ctx, st); break;
      case 8: ThemeFwSim.clock(ctx, st, nowMs); break;
      case 9: ThemeFwSim.off(ctx); break;
      case 10: ThemeFwSim.otaUpdate(ctx, st, nowMs); break;
      case 11: ThemeFwSim.split(ctx, st); break;
      case 12: ThemeFwSim.camera(ctx, st); break;
      case 13: ThemeFwSim.powerConfirm(ctx, st); break;
      case 14: ThemeFwSim.dryPeek(ctx, st); break;
      case 15: ThemeFwSim.hmsScreen(ctx, st); break;
      case 16: ThemeFwSim.face(ctx, st, nowMs); break;
      case 17: ThemeFwSim.balance(ctx, st); break;
      case 100: ThemeFwSim.colorProbe(ctx); break;   // 隐藏：色卡标定用
      default: ThemeFwSim.placeholder(ctx, s); break;
    }
    ctx.restore();

    Chrome.vignette(ctx, 1920, 462, vig, vigReach, vigCorner);
  }

  // ======================= 固件界面（逐条照抄） =======================

  /**
   * 时钟屏（clock_mode.cpp:387 drawClock）。
   * 版面：时间 HH:MM 居中（字模基准 32×48 + 冒号 12，见 clock_mode.cpp:17-19），
   * 下方日期（可选），底部一行打印机信息（dispSettings.showClockInfo）。
   */
  private static clock(ctx: CanvasRenderingContext2D, st: FwSimState, nowMs: number): void {
    // 源 clock_mode.cpp:38-56：SCREEN_W>=320 → autoSizeIndex=2 → sizeIndexToScale=1.5（Medium）
    const scale = 1.5;
    const digitW = Math.floor(32 * scale);      // CLK_BASE_W  32 → 48
    const digitH = Math.floor(48 * scale);      // CLK_BASE_H  48 → 72
    const colonW = Math.floor(12 * scale);      // CLK_BASE_COLON 12 → 18
    const blockW = 4 * digitW + colonW;         // = 210
    const timeX0 = (FW_W - blockW) / 2;         // = 79
    const dateH = 24;
    const gap = 14;                             // DATE_GAP（layout_368x448 档）
    const contentH = digitH + gap + dateH;
    const timeY = (FW_H - contentH) / 2;        // 源：竖直居中
    // ★ 源 display_ui.cpp:6192-6194：SCREEN_CLOCK 时先 drawClock()，
    //   若 dispSettings.pongClock 为真则由 clock_pong.cpp 另外叠上砖块/球/挡板。
    if (st.pongClock) {
      ThemeFwSim.clockPong(ctx, st);
    }

    const hh = st.use24h
      ? ThemeFwSim.pad2(st.hour)
      : ThemeFwSim.pad2(st.hour % 12 === 0 ? 12 : st.hour % 12);
    const mm = ThemeFwSim.pad2(st.minute);
    const colonOn = (nowMs % 1000) < 500;
    const glyphs: string[] = [hh.charAt(0), hh.charAt(1), ':', mm.charAt(0), mm.charAt(1)];

    // 数码字：步进严格等于 digitW（源是 7 段字模，这里用等宽粗体贴出同尺寸格子）
    const base = 96;
    ctx.font = `bold ${base}px monospace`;
    const adv = ctx.measureText('0').width;
    const fit = adv > 0 ? Math.floor(base * digitW / adv) : base;
    ctx.font = `bold ${fit}px monospace`;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.text;
    for (let i = 0; i < 5; i++) {
      let x = timeX0;
      if (i === 0) { x = timeX0; }
      else if (i === 1) { x = timeX0 + digitW; }
      else if (i === 2) { x = timeX0 + 2 * digitW; }
      else { x = timeX0 + 2 * digitW + colonW + (i - 3) * digitW; }
      if (i === 2) {
        if (colonOn) {
          const cw = Math.max(6, Math.floor(colonW * 0.45));
          ctx.fillStyle = FW.text;
          ctx.fillRect(x + (colonW - cw) / 2, timeY + Math.floor(digitH * 0.18), cw, cw);
          ctx.fillRect(x + (colonW - cw) / 2, timeY + Math.floor(digitH * 0.62), cw, cw);
        }
        continue;
      }
      ctx.fillText(glyphs[i], x, timeY + digitH / 2);
    }
    // 12 小时制的 AM/PM：源 ampmX = timeX0 + timeBlockW + 6，与数字底对齐
    if (!st.use24h) {
      ctx.font = 'bold 30px monospace';
      ctx.fillStyle = FW.dim;
      ctx.fillText(st.hour < 12 ? 'AM' : 'PM', timeX0 + blockW + 6, timeY + digitH - 14);
    }
    // 日期（源居中在时间下方 DATE_GAP 处）
    if (st.dateText.length > 0) {
      ctx.textAlign = 'center';
      ctx.font = 'bold 36px sans-serif';
      ctx.fillStyle = FW.dim;
      ctx.fillText(st.dateText, FW_W / 2, timeY + digitH + gap + dateH / 2);
    }
    // 底部信息行（源 drawClockInfo：底边距 4，行高 = 字高 + 3）
    if (st.wifiText.length > 0) {
      ctx.textAlign = 'center';
      ctx.font = 'bold 28px sans-serif';
      ctx.fillStyle = FW.dark;
      ctx.fillText(ThemeFwSim.fit(ctx, st.wifiText, FW_W - 6), FW_W / 2, FW_H - 22);
    }
    ctx.textAlign = 'left';
  }

  /**
   * 打砖块时钟（固件 clock_pong.cpp 的那套配色与几何，版式按 368 档）。
   *
   * 与主题 4「打砖块」**共用同一套物理常量**（球 ⌀20 / 挡板 72×5 / 砖块 36×17 / 5 行 9 列），
   * 区别只是这里的数字更大（368 档 Medium：48×72 格）且是固件那套 5 行彩色砖。
   * 砖色沿用固件的经典街机彩虹（clock_pong.cpp:93-99）：红/橙/黄/绿/蓝。
   */
  private static clockPong(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    const BrickRows = 5;
    const BrickCols = 9;
    const BrickW = 36;
    const BrickH = 17;
    const Gap = 2;
    const StartX = 5;
    const StartY = 40;
    const PaddleY = 430;
    const PaddleW = 72;
    const PaddleH = 5;
    const Ball = 20;
    // 固件原值（clock_pong.cpp:93-99）是纯 RGB565：红 #FF0000 / 橙 #FFA500 /
    // 黄 #FFFF00 / 绿 #00FF00 / 蓝 #0000FF。经 JPEG 4:2:0 后**纯蓝几乎归零、
    // 纯绿掉一半**（实测：蓝 #0000FF 解码回来只有 #0202C0 且偏暗），所以这里做预补偿：
    // 给低通道抬地板、把极值从 0/255 收回，让解码后的颜色更接近固件原意。
    const colors: string[] = ['#F01010', '#F0A018', '#F0E828', '#20E020', '#3A55E0'];

    // 砖块墙（源 drawAllBricks：逐块主体色 + 顶边白 1px + 底边黑 1px）
    const live = st.pongBricks;
    for (let r = 0; r < BrickRows; r++) {
      for (let c = 0; c < BrickCols; c++) {
        const alive = live.length > r && live[r].length > c ? live[r][c] : true;
        if (!alive) {
          continue;
        }
        const x = StartX + c * (BrickW + Gap);
        const y = StartY + r * (BrickH + Gap);
        ctx.fillStyle = colors[r % colors.length];
        ctx.fillRect(x, y, BrickW, BrickH);
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(x, y, BrickW, 1);
        ctx.fillStyle = '#000000';
        ctx.fillRect(x, y + BrickH - 1, BrickW, 1);
      }
    }
    // 球（源 drawBall：白色实心圆）
    if (st.pongBallX >= 0) {
      ctx.beginPath();
      ctx.arc(st.pongBallX + Ball / 2, st.pongBallY + Ball / 2, Ball / 2, 0, Math.PI * 2);
      ctx.fillStyle = '#FFFFFF';
      ctx.fill();
    }
    // 挡板（源 drawPaddle：青条 + 顶边白线）
    const px = Math.round(st.pongPaddleX - PaddleW / 2);
    ctx.fillStyle = '#00FFFF';
    ctx.fillRect(px, PaddleY, PaddleW, PaddleH);
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(px, PaddleY, PaddleW, 1);
  }

  /**
   * 打印中（display_ui.cpp:6151 SCREEN_PRINTING）。
   * 版面常量取自 layout_default.h：ETA 区 y=190 高 30、底栏 y=222 高 18、
   * 空闲/打印共用的名字 y=30 与状态徽标 y=50/60。
   */
  private static printing(ctx: CanvasRenderingContext2D, st: FwSimState, nowMs: number): void {
    // 版式（layout_368x448.h）：名字 y=42、状态徽标 y=72 高 28 文字 86、
    // 环内大百分比居中、ETA 区 y=362（文字 383）、文件名 y=410、底栏 y=424 高 24
    const pct = st.prPct >= 0 ? st.prPct : 0;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 34px sans-serif';
    ctx.fillStyle = FW.text;
    ctx.fillText(ThemeFwSim.fit(ctx, st.prModel.length > 0 ? st.prModel : 'Bambu Lab P2S', FW_W - 20),
      FW_W / 2, 42);

    const badge = st.prState === 'PAUSE' ? '已暂停' : (st.prState === 'RUNNING' ? '打印中' : '空闲');
    const badgeClr = st.prState === 'PAUSE' ? FW.yellow : (st.prState === 'RUNNING' ? FW.green : FW.dark);
    ctx.font = 'bold 30px sans-serif';
    const bw = ctx.measureText(badge).width + 30;
    ctx.fillStyle = badgeClr;
    ThemeFwSim.roundRect(ctx, (FW_W - bw) / 2, 72, bw, 28, 14);
    ctx.fill();
    ctx.fillStyle = FW.bg;
    ctx.fillText(badge, FW_W / 2, 86);

    // 中央进度环（半径按 LY_GAUGE_R 一档；368 档的仪表半径见 layout 里的 LY_GAUGE_*）
    const cx = FW_W / 2;
    const cy = 218;
    const r = 96;
    ctx.lineWidth = 16;
    ctx.strokeStyle = FW.track;
    ctx.beginPath();
    ctx.arc(cx, cy, r, -Math.PI / 2, Math.PI * 1.5);
    ctx.stroke();
    if (pct > 0) {
      ctx.strokeStyle = pct >= 95 ? FW.gold : FW.green;
      ctx.beginPath();
      ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * pct / 100);
      ctx.stroke();
    }
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 76px monospace';
    ctx.fillText(`${pct}`, cx - 18, cy - 6);
    ctx.font = 'bold 34px monospace';
    ctx.fillStyle = FW.dim;
    ctx.fillText('%', cx + 56, cy - 16);

    // ETA 区（y=362，文字 383）：层数 + 剩余
    ctx.font = 'bold 28px monospace';
    ctx.fillStyle = FW.dim;
    const layer = st.prLayer >= 0
      ? `层 ${st.prLayer}${st.prTotalLayer > 0 ? '/' + st.prTotalLayer : ''}` : '层 --';
    ctx.textAlign = 'left';
    ctx.fillText(layer, 16, 383);
    ctx.textAlign = 'right';
    ctx.fillText(st.prRemainMin >= 0 ? `剩 ${ThemeFwSim.hhmm2(st.prRemainMin)}` : '剩 --', FW_W - 16, 383);
    // 文件名（y=410，居中，两侧留 8）
    ctx.textAlign = 'center';
    ctx.font = 'bold 26px sans-serif';
    ctx.fillStyle = FW.text;
    ctx.fillText(ThemeFwSim.fit(ctx, st.prJob.length > 0 ? st.prJob : '（无作业）', FW_W - 16),
      FW_W / 2, 410);

    // 底栏（y=424 高 24）：左边 WiFi、右边 AMS 盘数
    ctx.fillStyle = FW.header;
    ctx.fillRect(0, 424, FW_W, 24);
    ctx.textAlign = 'left';
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText(st.wifiText, 6, 436);
    ctx.textAlign = 'right';
    ctx.fillText(`AMS ${st.prTrays}`, FW_W - 8, 436);
    ctx.textAlign = 'left';
  }

  /** 空闲（layout_368x448.h:158-164：名字 42 / 状态 72-100 / 表盘 y=206 r=50 中心 ±86） */
  private static idle(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 34px sans-serif';
    ctx.fillText(ThemeFwSim.fit(ctx, st.prModel.length > 0 ? st.prModel : '未连接打印机', FW_W - 20),
      FW_W / 2, 42);
    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 30px sans-serif';
    ctx.fillText('空闲', FW_W / 2, 86);
    ThemeFwSim.gauge(ctx, FW_W / 2 - 86, 206, 50, st.prNozzle, 260, '喷', FW.orange);
    ThemeFwSim.gauge(ctx, FW_W / 2 + 86, 206, 50, st.prBed, 100, '床', FW.cyan);
  }

  /** 完成（layout_368x448.h:182-194：双表盘 r50 @(110/258,148)、文字 238、文件名 276、底栏 414 高 26） */
  private static finished(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ThemeFwSim.gauge(ctx, 110, 148, 50, st.prNozzle, 260, '喷', FW.orange);
    ThemeFwSim.gauge(ctx, 258, 148, 50, st.prBed, 100, '床', FW.cyan);
    ctx.fillStyle = FW.green;
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText('打印完成', FW_W / 2, 238);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 28px sans-serif';
    ctx.fillText(ThemeFwSim.fit(ctx, st.prJob.length > 0 ? st.prJob : '（无作业）', FW_W - 24),
      FW_W / 2, 276);
    ctx.fillStyle = FW.header;
    ctx.fillRect(0, 414, FW_W, 26);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText(st.wifiText, FW_W / 2, 427);
  }

  /** 启动画面（源 splash：居中 logo + 版本行） */
  private static splash(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.green;
    ctx.font = 'bold 44px sans-serif';
    ctx.fillText('BambuHelper', FW_W / 2, FW_H / 2 - 40);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 28px sans-serif';
    ctx.fillText('正在启动…', FW_W / 2, FW_H / 2 + 20);
    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 22px monospace';
    ctx.fillText('ESP32-S3 · 固件仿真', FW_W / 2, FW_H - 36);
  }

  /** 配网热点（layout_368x448.h:196-202：标题 56 / SSID 标 112 值 150 / 密码 196…） */
  private static apMode(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.cyan;
    ctx.font = 'bold 34px sans-serif';
    ctx.fillText('配网模式', FW_W / 2, 56);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 24px sans-serif';
    ctx.fillText('热点名称', FW_W / 2, 112);
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 28px monospace';
    ctx.fillText(st.ssid.length > 0 ? st.ssid : 'BambuHelper-XXXX', FW_W / 2, 150);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 24px sans-serif';
    ctx.fillText('密码', FW_W / 2, 196);
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 28px monospace';
    ctx.fillText('12345678', FW_W / 2, 226);
    ctx.fillStyle = FW.green;
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText('浏览器打开 192.168.4.1', FW_W / 2, 286);
    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 22px monospace';
    ctx.fillText(st.ip, FW_W / 2, 330);
  }

  /** 连接中（WiFi / MQTT 共用一套文案，源里是 SCREEN_CONNECTING_*） */
  private static connecting(ctx: CanvasRenderingContext2D, title: string, sub: string,
                            nowMs: number): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 34px sans-serif';
    ctx.fillText(title, FW_W / 2, 170);
    // 三点跳动（源是动画点；这里按 400ms 步进）
    const n = Math.floor(nowMs / 400) % 4;
    let dots = '';
    for (let i = 0; i < n; i++) {
      dots += '●';
    }
    ctx.fillStyle = FW.green;
    ctx.font = 'bold 32px sans-serif';
    ctx.fillText(dots, FW_W / 2, 224);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 24px sans-serif';
    ctx.fillText(sub, FW_W / 2, 278);
  }

  private static connectingWifi(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ThemeFwSim.connecting(ctx, '连接 WiFi', st.ssid.length > 0 ? st.ssid : st.wifiText, Date.now());
  }
  private static wifiConnected(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ThemeFwSim.connecting(ctx, 'WiFi 已连接', st.ip, Date.now());
  }
  private static connectingMqtt(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ThemeFwSim.connecting(ctx, '连接打印机', 'MQTT 握手中', Date.now());
  }

  /**
   * 表情页（face_ui.cpp；源部件表：眼 52×72 @(∓78,−30)、嘴 56×12 @(0,70)，
   * 运行时统一 ×1.2 —— 与 dotii 那套同源，但固件这里的画布是 240×240，
   * 所以这里按 240/288 的比例再缩一次）。
   */
  private static face(ctx: CanvasRenderingContext2D, st: FwSimState, nowMs: number): void {
    const k = FW_W / 288;                    // 源部件表以 288 单位制给出，368 档即原生（k≈1.28）
    const p = Math.floor((nowMs % 2600) / 325) % 8;
    const ping = p < 4 ? p : 8 - p;
    const cx = FW_W / 2;
    const cy = FW_H / 2;
    const part = (w: number, h: number, x: number, y: number, c: string): void => {
      const W = w * 1.2 * k;
      const H = h * 1.2 * k;
      if (W <= 0 || H <= 0) {
        return;
      }
      ctx.fillStyle = c;
      ThemeFwSim.roundRect(ctx, cx + x * 1.2 * k - W / 2, cy + y * 1.2 * k - H / 2, W, H, Math.min(W, H) / 2);
      ctx.fill();
    };
    switch (st.expr % 6) {
      case 0:   // idle_breath
        part(52, 72 + ping * 3, -78, -30, '#F4EAD2');
        part(52, 72 + ping * 3, 78, -30, '#F4EAD2');
        part(56, 12, 0, 70, '#F4EAD2');
        break;
      case 1:   // blink
        part(58, (p === 2 || p === 3) ? 7 : ((p === 1 || p === 4) ? 24 : 66), -78, -26, '#F4EAD2');
        part(58, (p === 2 || p === 3) ? 7 : ((p === 1 || p === 4) ? 24 : 66), 78, -26, '#F4EAD2');
        part(56, 12, 0, 70, '#F4EAD2');
        break;
      case 2:   // curious
        part(62, 82, -76, -34, '#F4EAD2');
        part(46, 62, 82, -26, '#F4EAD2');
        part(20 + ping, 20 + ping, 8, 70, '#F2C66D');
        break;
      case 3:   // sleepy_yawn
        part(68, 10, -76, -18, '#F4EAD2');
        part(68, 10, 76, -18, '#F4EAD2');
        part(26 + ping * 3, 26 + ping * 3, 0, 72, '#F2C66D');
        break;
      case 4:   // working
        part(48, 68, -86 + ping * 4, -30, '#F4EAD2');
        part(48, 68, 70 + ping * 4, -30, '#F4EAD2');
        part(62, 10, 0, 72, '#55D8D0');
        break;
      default:  // complete
        part(68, 14, -76, -28, '#F4EAD2');
        part(68, 14, 76, -28, '#F4EAD2');
        part(108 + ping, 20 + Math.floor(ping / 2), 0, 62, '#F2C66D');
        break;
    }
  }

  /**
   * 余额屏（balance_ui.cpp）。源是"余额/赠送/充值"三段 + 状态徽标；
   * 这一屏正是接管会话里待确认的那件事（缺字：余额/赠金/充值/几分钟前）。
   */
  private static balance(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 32px sans-serif';
    ctx.fillText('DeepSeek 余额', FW_W / 2, 92);

    ctx.fillStyle = FW.green;
    ctx.font = 'bold 86px monospace';
    ctx.fillText(st.balTotal, FW_W / 2, 200);

    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText(`赠送 ${st.balGranted} · 充值 ${st.balTopped}`, FW_W / 2, 272);

    // 状态徽标
    const clr = st.balStatus === '可用' ? FW.green
      : (st.balStatus === '预览数据' ? FW.yellow : FW.dark);
    ctx.font = 'bold 28px sans-serif';
    const w = ctx.measureText(st.balStatus).width + 34;
    ctx.fillStyle = clr;
    ThemeFwSim.roundRect(ctx, (FW_W - w) / 2, 312, w, 40, 20);
    ctx.fill();
    ctx.fillStyle = FW.bg;
    ctx.fillText(st.balStatus, FW_W / 2, 332);

    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText('几分钟前更新', FW_W / 2, 386);
  }

  /**
   * 色卡标定探针（隐藏界面，/set?fws=100）：每行一个固件原色 + 两个候选补偿值。
   * 目的：JPEG 走 4:2:0 色度抽样，纯蓝/纯绿会被压掉；这里实测"补偿后解码回来是否更像原色"。
   * 每一行三格：左=固件原值，中=补偿 A，右=补偿 B。
   */
  private static colorProbe(ctx: CanvasRenderingContext2D): void {
    const rows: string[][] = [
      ['#0000FF', '#2020C8', '#3030E0'],   // CLR 蓝（最容易被吃掉）
      ['#00FF00', '#18E018', '#00E000'],   // CLR 绿
      ['#FF0000', '#F01010', '#E81818'],   // CLR 红
      ['#00FFFF', '#20E8E8', '#10D8E8'],   // CLR 青
      ['#FF7D00', '#F08010', '#E87818'],   // CLR 橙
      ['#FFFF00', '#F0E820', '#E8E020'],   // CLR 黄
      ['#FFD700', '#F0CC18', '#E8C420'],   // CLR 金
      ['#319AFF', '#4090F0', '#4A88E8'],   // CLR 蓝（浅）
      ['#191C19', '#202420', '#282C28'],   // CLR 轨道
      ['#192431', '#202C38', '#283440'],   // CLR 卡片
      ['#101410', '#181C18', '#202420']    // CLR 页眉
    ];
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    for (let i = 0; i < rows.length; i++) {
      const y = 8 + i * 40;
      for (let k = 0; k < 3; k++) {
        ctx.fillStyle = rows[i][k];
        ctx.fillRect(30 + k * 112, y, 100, 34);
      }
      ctx.fillStyle = '#FFFFFF';
      ctx.font = 'bold 22px monospace';
      ctx.fillText(rows[i][0], 30, y + 34 + 10 > FW_H ? y + 17 : y + 50);
    }
  }

  /** 息屏（源 SCREEN_OFF：整屏黑，只留一点背光提示） */
  private static off(ctx: CanvasRenderingContext2D): void {
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, FW_W, FW_H);
  }

  /**
   * OTA 升级（display_ui.cpp:880 drawOtaUpdate）。
   * 版面：标题 cy−60、副题 cy−36、进度条 (20, cy−10) 宽 sw−40 高 14、
   *       百分比 cy+14、状态 cy+34、橙色警告 cy+58。
   */
  private static otaUpdate(ctx: CanvasRenderingContext2D, st: FwSimState, nowMs: number): void {
    const cx = FW_W / 2;
    const cy = FW_H / 2;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 44px sans-serif';
    ctx.fillText('正在更新', cx, cy - 60);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 28px sans-serif';
    ctx.fillText('BambuHelper 固件', cx, cy - 30);

    // 进度条（源 fillRoundRect barX=20 barY=cy-10 barW=sw-40 barH=14 r=4）
    const barX = 20;
    const barY = cy + 4;
    const barW = FW_W - 40;
    const barH = 14;
    ctx.fillStyle = FW.track;
    ThemeFwSim.roundRect(ctx, barX, barY, barW, barH, 4);
    ctx.fill();
    const pct = Math.max(0, Math.min(100, st.otaPct));
    if (pct > 0) {
      ctx.fillStyle = pct >= 95 ? FW.gold : FW.green;
      ThemeFwSim.roundRect(ctx, barX, barY, Math.max(8, barW * pct / 100), barH, 4);
      ctx.fill();
    }
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 30px monospace';
    ctx.fillText(`${pct}%`, cx, cy + 40);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText(st.otaStatus, cx, cy + 76);
    ctx.fillStyle = FW.orange;
    ctx.fillText('请勿断电', cx, cy + 112);
  }

  /**
   * 双机分屏（display_split.cpp:597 drawSplit + layout_368x448.h:75-90）。
   * 上下两半：分割线 y=224，每半有表盘(r=42)、两行槽位（A: 74/158，B: 298/382）。
   */
  private static split(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    const half = FW_H / 2;
    // 分隔线
    ctx.fillStyle = FW.track;
    ctx.fillRect(0, half - 1, FW_W, 2);

    const drawHalf = (top: number, name: string, state: string, pct: number,
                      noz: number, bed: number): void => {
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = FW.text;
      ctx.font = 'bold 26px sans-serif';
      ctx.fillText(ThemeFwSim.fit(ctx, name, FW_W - 16), FW_W / 2, top + 26);
      ctx.fillStyle = pct >= 0 ? FW.green : FW.dark;
      ctx.font = 'bold 24px monospace';
      ctx.fillText(pct >= 0 ? `${pct}%` : '--', 56, top + 74);
      ctx.fillStyle = FW.dim;
      ctx.font = 'bold 22px sans-serif';
      ctx.fillText(state, FW_W - 56, top + 74);
      ThemeFwSim.gauge(ctx, 96, top + 158, 42, noz, 260, '喷', FW.orange);
      ThemeFwSim.gauge(ctx, 272, top + 158, 42, bed, 100, '床', FW.cyan);
    };
    drawHalf(0, st.prModel.length > 0 ? st.prModel : '打印机 A', st.prState, st.prPct,
      st.prNozzle, st.prBed);
    drawHalf(half, st.pr2Model.length > 0 ? st.pr2Model : '打印机 B', st.pr2State, st.pr2Pct,
      st.prNozzle, st.prBed);
  }

  /** 相机画面（display_ui.cpp:2994；本移植没有相机通路 → 画源里的"暂不可用"框） */
  private static camera(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ctx.fillStyle = FW.bg;
    ctx.fillRect(0, 0, FW_W, FW_H);
    ctx.fillStyle = FW.card;
    ctx.fillRect(8, 60, FW_W - 16, 240);
    ctx.strokeStyle = FW.track;
    ctx.lineWidth = 2;
    ctx.strokeRect(8, 60, FW_W - 16, 240);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 28px sans-serif';
    ctx.fillText('相机画面暂不可用', FW_W / 2, 180);
    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText('（本屏无相机通路）', FW_W / 2, 222);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText(st.prJob.length > 0 ? st.prJob : '（无作业）', FW_W / 2, 340);
  }

  /** 电源确认（display_ui.cpp:5453 drawPowerConfirm：整屏提示 + 居中大字） */
  private static powerConfirm(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    // 源在"发送中"时整屏变红警示
    ctx.fillStyle = FW.bg;
    ctx.fillRect(0, 0, FW_W, FW_H);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.yellow;
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText('电源操作', FW_W / 2, 140);
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 30px sans-serif';
    ctx.fillText('按住 1.2 秒确认', FW_W / 2, 214);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText('向右滑动取消', FW_W / 2, 262);
    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText('（仿真显示，不下发指令）', FW_W / 2, 340);
  }

  /**
   * 烘干查看（display_ui.cpp:1373 drawIdleDrying）。
   * 源是"腔温 + 湿度 + 剩余时间"三块读数。
   */
  private static dryPeek(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.orange;
    ctx.font = 'bold 36px sans-serif';
    ctx.fillText('AMS 烘干中', FW_W / 2, 70);
    ThemeFwSim.gauge(ctx, FW_W / 2 - 86, 200, 58, st.dryTemp, 120, '腔温', FW.orange);
    ThemeFwSim.gauge(ctx, FW_W / 2 + 86, 200, 58, st.dryHumidity, 100, '湿度', FW.cyan);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 28px monospace';
    ctx.fillText(st.dryRemainMin >= 0 ? `剩余 ${ThemeFwSim.hhmm2(st.dryRemainMin)}` : '剩余 --',
      FW_W / 2, 320);
    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText('点击返回', FW_W / 2, 386);
  }

  /**
   * 错误详情（display_ui.cpp:5708 drawHmsScreen）。
   * 源：顶部"打印机错误"，下面逐条列 HMS 码与说明；有错误时标题用红色。
   */
  private static hmsScreen(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    const has = st.hmsCount > 0;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = has ? FW.red : FW.green;
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText(has ? '打印机错误' : '打印机正常', FW_W / 2, 56);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 24px sans-serif';
    ctx.fillText(has ? `共 ${st.hmsCount} 条` : '无待处理错误', FW_W / 2, 96);

    if (has) {
      ctx.fillStyle = FW.card;
      ThemeFwSim.roundRect(ctx, 12, 130, FW_W - 24, 150, 12);
      ctx.fill();
      ctx.textAlign = 'left';
      ctx.fillStyle = FW.red;
      ctx.font = 'bold 28px monospace';
      ctx.fillText(ThemeFwSim.fit(ctx, st.hmsLabel, FW_W - 48), 28, 168);
      ctx.fillStyle = FW.dim;
      ctx.font = 'bold 24px sans-serif';
      ctx.fillText(ThemeFwSim.fit(ctx, st.hmsDetail, FW_W - 48), 28, 210);
      ctx.fillStyle = FW.dark;
      ctx.font = 'bold 22px sans-serif';
      ctx.fillText('点击查看下一条', 28, 250);
    }
    ctx.textAlign = 'center';
    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText('点击返回', FW_W / 2, 340);
  }

  /** 还没抄的界面（split / camera / power_confirm / dry_peek / hms / ota） */
  private static placeholder(ctx: CanvasRenderingContext2D, screen: number): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 18px sans-serif';
    ctx.fillText('此界面待移植', FW_W / 2, FW_H / 2 - 14);
    ctx.fillStyle = FW.dark;
    ctx.font = 'bold 16px monospace';
    ctx.fillText(FW_SCREENS[screen], FW_W / 2, FW_H / 2 + 18);
    ctx.font = 'bold 14px sans-serif';
    ctx.fillText(FW_SCREEN_LABELS[screen], FW_W / 2, FW_H / 2 + 44);
  }

  // ======================= 小部件 =======================
  /** 温度表盘（源 drawTempGauge 的简化：环 + 中心值 + 标签） */
  private static gauge(ctx: CanvasRenderingContext2D, cx: number, cy: number, r: number,
                       value: number, vmax: number, label: string, color: string): void {
    ctx.lineWidth = 6;
    ctx.strokeStyle = FW.track;
    ctx.beginPath();
    ctx.arc(cx, cy, r, Math.PI * 0.75, Math.PI * 2.25);
    ctx.stroke();
    const p = value >= 0 ? Math.max(0, Math.min(1, value / vmax)) : 0;
    if (p > 0) {
      ctx.strokeStyle = color;
      ctx.beginPath();
      ctx.arc(cx, cy, r, Math.PI * 0.75, Math.PI * 0.75 + Math.PI * 1.5 * p);
      ctx.stroke();
    }
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = FW.text;
    ctx.font = 'bold 20px monospace';
    ctx.fillText(value >= 0 ? `${value.toFixed(0)}°` : '--', cx, cy - 4);
    ctx.fillStyle = FW.dim;
    ctx.font = 'bold 14px sans-serif';
    ctx.fillText(label, cx, cy + 16);
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

  // ======================= 两侧信息栏 =======================
  private static leftPanel(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    const x = 14;
    const y = 14;
    const w = FWSIM_PANEL_W;
    const h = 462 - 28;
    ThemeFwSim.panelBox(ctx, x, y, w, h, '#22D3EE');
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#22D3EE';
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText('固件仿真屏', x + 34, y + 44);
    ctx.fillStyle = '#8C94A8';
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText('ESP32-S3 固件 UI · 按源码 1:1 抄绘', x + 34, y + 84);

    const inner = x + 34;
    const innerW = w - 68;
    const rows: string[][] = [
      ['当前界面', ThemeFwSim.rotationLabel(st.screen)],
      ['轮播', `${ThemeFwSim.rotationPos(st.screen)}/4 · 每 12 秒`],
      ['设计画布', '240×240 → ×1.4 = 336×336'],
      ['数据源', '本机遥测（打印机/余额/系统）'],
      ['时钟模式', st.pongClock ? '打砖块时钟' : '普通时钟']
    ];
    let ry = y + 150;
    for (const r of rows) {
      ThemeFwSim.statRow(ctx, inner, innerW, ry, r[0], r[1], '#E6EBF5');
      ry += 52;
    }
    ctx.fillStyle = '#646C82';
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText('来源：备份-阶段-20261009-0046/源码', inner, y + h - 30);
  }

  private static rightPanel(ctx: CanvasRenderingContext2D, st: FwSimState): void {
    const x = 1920 - 14 - FWSIM_PANEL_W;
    const y = 14;
    const w = FWSIM_PANEL_W;
    const h = 462 - 28;
    ThemeFwSim.panelBox(ctx, x, y, w, h, '#00AE42');
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#34D399';
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText('固件实时数据', x + 34, y + 44);
    ctx.fillStyle = '#8C94A8';
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText('下面这些值就是固件那些屏在显示的东西', x + 34, y + 84);

    const inner = x + 34;
    const innerW = w - 68;
    const rows: string[][] = [
      ['打印机状态', st.prState.length > 0 ? st.prState : '--'],
      ['进度 / 层', `${st.prPct >= 0 ? st.prPct + '%' : '--'} · ${st.prLayer >= 0 ? st.prLayer : '--'}/${st.prTotalLayer > 0 ? st.prTotalLayer : '--'}`],
      ['喷嘴 / 热床', `${st.prNozzle >= 0 ? st.prNozzle.toFixed(0) + '°' : '--'} / ${st.prBed >= 0 ? st.prBed.toFixed(0) + '°' : '--'}`],
      ['剩余', st.prRemainMin >= 0 ? ThemeFwSim.hhmm2(st.prRemainMin) : '--'],
      ['DeepSeek 余额', `${st.balTotal}（${st.balStatus}）`],
      ['连接', st.wifiText]
    ];
    let ry = y + 150;
    for (const r of rows) {
      ThemeFwSim.statRow(ctx, inner, innerW, ry, r[0], r[1], '#E6EBF5');
      ry += 46;
    }
    ctx.fillStyle = '#646C82';
    ctx.font = 'bold 24px sans-serif';
    ctx.fillText('切换界面：/set?fws=N（0..17）', inner, y + h - 30);
  }

  private static panelBox(ctx: CanvasRenderingContext2D, x: number, y: number,
                          w: number, h: number, accent: string): void {
    ctx.fillStyle = '#141722';
    ThemeFwSim.roundRect(ctx, x, y, w, h, 14);
    ctx.fill();
    ctx.strokeStyle = '#262A3A';
    ctx.lineWidth = 1;
    ThemeFwSim.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 14);
    ctx.stroke();
    ctx.fillStyle = accent;
    ThemeFwSim.roundRect(ctx, x + 18, y + 20, 4, 26, 2);
    ctx.fill();
  }

  private static statRow(ctx: CanvasRenderingContext2D, x: number, w: number, y: number,
                         label: string, value: string, color: string): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = '#8C94A8';
    ctx.font = 'bold 26px sans-serif';
    ctx.fillText(label, x, y);
    ctx.textAlign = 'right';
    ctx.fillStyle = color;
    ctx.font = 'bold 30px monospace';
    ctx.fillText(ThemeFwSim.fit(ctx, value, w - 240), x + w, y);
    ctx.textAlign = 'left';
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

  /** 当前界面在这 4 个轮播界面里的名字（不在轮播集里则回落到原始枚举名） */
  private static rotationLabel(screen: number): string {
    for (let i = 0; i < FW_ROTATION.length; i++) {
      if (FW_ROTATION[i] === screen) {
        return FW_ROTATION_LABELS[i];
      }
    }
    return FW_SCREEN_LABELS[screen % FW_SCREEN_COUNT];
  }

  /** 位次 1..4（不在轮播集里返回 0） */
  private static rotationPos(screen: number): number {
    for (let i = 0; i < FW_ROTATION.length; i++) {
      if (FW_ROTATION[i] === screen) {
        return i + 1;
      }
    }
    return 0;
  }

  private static pad2(n: number): string {
    return (n < 10 ? '0' : '') + n;
  }

  /** 分钟 → "1h12m" */
  private static hhmm2(min: number): string {
    return `${Math.floor(min / 60)}h${ThemeFwSim.pad2(min % 60)}m`;
  }
}
