/**
 * ThemeTRCC.ets —— 主题 7「官方浅色风」（TRCC 官方 1920×462 主题的复刻）
 *
 * 来源（一手素材已解包落盘，见 docs/官方主题包分析.md）：
 *   ~/.cache/trcc/repos/thermalright-trcc-linux/src/trcc/data/theme1920462.7z
 *     → 20 文件 / 5 套主题，每套 { Theme.png 背景, 00.png/01.png 动画帧, config1.dc 布局 }
 *   · 解包用的是 openEuler 虚拟机上的 p7zip（本机 7zz 是 glibc 版、在 musl 上跑不起来）
 *   · 素材副本：[docs/官方主题462/](../docs/官方主题462/)
 *
 * 官方设计（识图量出的像素坐标，1920×462）：
 *   ┌───────────┐                              ┌───────────┐
 *   │ 左卡       │        17:03（≈100px）       │ 右卡       │
 *   │ (140,50)  │        中心 (960,133)         │ (1420,50) │
 *   │ 355×360   │   星期六 2025/05/17（居中）    │ 355×360   │
 *   │ CPU       │                              │ GPU       │
 *   │ 50℃ 1%    │                              │ 44℃ 3%    │
 *   │ 3593MHz   │                              │ 10MHz     │
 *   └───────────┘                              └───────────┘
 *   圆角 ≈20px、柔和投影；**浅色底 + 纯文字排版，没有圆环/曲线**
 *
 * 5 套配色是**闭环**轮换（每套的背景色 = 上一套的卡片色）：
 *   #96FFA8（薄荷绿）· #EEF7A3（淡黄绿）· #FF9855（橙）· #FF7070（珊瑚）· #4BE6E9（青）
 *
 * 与本项目其它 7 个主题（深色霓虹 + 环形曲线）风格正好相反，所以单独做成一档，
 * 由 /set?trcc=N（0..4）切换配色，N=-1 时按 30 秒自动轮换。
 */

import { Chrome } from './Chrome';

/** 官方 5 套配色：下表是"背景色"，卡片色取下一位（闭环） */
const TRCC_COLORS: string[] = ['#96FFA8', '#EEF7A3', '#FF9855', '#FF7070', '#4BE6E9'];
export const TRCC_THEME_COUNT: number = TRCC_COLORS.length;

/** 版面（像素，取自官方 Theme.png 的量测值） */
const CARD_X_L = 140;
const CARD_X_R = 1420;
const CARD_Y = 50;
const CARD_W = 355;
const CARD_H = 360;
const CARD_R = 20;
const CLOCK_CY = 133;      // 大时间中心 y
const CLOCK_SIZE = 100;    // 大时间字号
const DATE_CY = 232;       // 日期行中心 y（在时间下方、两卡之间）
const ROW_TITLE = 96;     // 卡片内标题（CPU/GPU）的 y
const ROW_MAIN = 205;      // 卡片内主数值的 y
const ROW_SUB = 315;       // 卡片内次数值的 y

/** 主题状态（由 LcdService 每帧填真实数据） */
export class TrccState {
  /** 配色索引 0..4；-1 = 自动轮换 */
  palette: number = 0;
  hour: number = 0;
  minute: number = 0;
  dateText: string = '';
  /** 左卡：CPU */
  cpuTemp: number = -1;
  cpuLoadPct: number = -1;
  cpuFreqMhz: number = -1;
  /** 右卡：第二项指标（这台机器没有独立 GPU，用 DeepSeek token 速率顶上） */
  gpuLabel: string = 'GPU';
  gpuTemp: number = -1;
  gpuLoadPct: number = -1;
  gpuFreqMhz: number = -1;
  /** 字号缩放（本屏比官方图大 1.0396 倍时用；默认 1.0 即按官方 1920×462 原样） */
  scale: number = 1.0;
}

export class ThemeTrcc {
  static readonly NAME: string = '官方浅色风';
  static readonly PALETTES: string[] = TRCC_COLORS;

  /** 当前套的卡片色（闭环：卡片色 = 下一套的背景色） */
  static cardColor(idx: number): string {
    return TRCC_COLORS[(idx + 1) % TRCC_COLORS.length];
  }

  static render(ctx: CanvasRenderingContext2D, st: TrccState, vig: number = 0,
                vigReach: number = 620, vigCorner: number = 0,
                bgImage: Object | null = null): void {
    const idx = ((st.palette % TRCC_THEME_COUNT) + TRCC_THEME_COUNT) % TRCC_THEME_COUNT;
    const bg = TRCC_COLORS[idx];
    const card = ThemeTrcc.cardColor(idx);
    const s = st.scale > 0 ? st.scale : 1;

    if (bgImage !== null) {
      // ★ 官方素材是**两层**（实测）：
      //     00.png = 纯背景色（整幅不透明）        ← 现在改用下面这张
      //     01.png = 卡片叠加层（背景透明 + 卡片/投影，28% 不透明）
      //   工程里 rawfile 放的是 01.png（卡片层）。而画布每帧开头会整体清成透明，
      //   所以这里**先铺官方背景色**、再叠卡片层，就得到与官方完全一致的合成结果。
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, 1920, 462);
      ctx.drawImage(bgImage as PixelMap, 0, 0, 1920, 462);
    } else {
      // 底图还没载入（或载入失败）时的兜底：按官方配色自绘
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, 1920, 462);
      ThemeTrcc.cardShadow(ctx, CARD_X_L, CARD_Y, CARD_W, CARD_H, CARD_R);
      ThemeTrcc.cardShadow(ctx, CARD_X_R, CARD_Y, CARD_W, CARD_H, CARD_R);
      ctx.fillStyle = card;
      ThemeTrcc.roundRect(ctx, CARD_X_L, CARD_Y, CARD_W, CARD_H, CARD_R);
      ctx.fill();
      ThemeTrcc.roundRect(ctx, CARD_X_R, CARD_Y, CARD_W, CARD_H, CARD_R);
      ctx.fill();
    }

    // 卡片内文字：深色（官方卡片上是黑字）
    // 官方卡片上的字是接近纯黑的深色（用灰会显得虚、和官方差距明显）
    const ink = '#101010';
    const inkSoft = '#101010';
    // 每行都传**拼好的字符串**，避免"温度"和"速率"共用一套单位拼法
    ThemeTrcc.cardText(ctx, CARD_X_L, CARD_W, 'CPU',
      st.cpuTemp >= 0 ? `${st.cpuTemp.toFixed(0)}°C` : '--',
      st.cpuLoadPct >= 0 ? `${st.cpuLoadPct.toFixed(0)}%` : '--',
      st.cpuFreqMhz > 0 ? `${st.cpuFreqMhz}MHz` : '--', ink, inkSoft);
    ThemeTrcc.cardText(ctx, CARD_X_R, CARD_W, st.gpuLabel,
      st.gpuTemp >= 0 ? `${st.gpuTemp.toFixed(0)}/min` : '--',
      st.gpuLoadPct >= 0 ? `今日 ${st.gpuLoadPct}` : '',
      st.gpuFreqMhz > 0 ? `${st.gpuFreqMhz}MHz` : '--', ink, inkSoft);

    // 居中大时间（官方 ≈100px、中心 y=133）+ 日期行
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    // 官方大时间是**灰色 #808080**（这个是对的，别改成黑）
    ctx.fillStyle = '#808080';
    ctx.font = `bold ${Math.round(CLOCK_SIZE * s)}px sans-serif`;
    ctx.fillText(`${ThemeTrcc.pad2(st.hour)}:${ThemeTrcc.pad2(st.minute)}`, 960, CLOCK_CY * s);

    if (st.dateText.length > 0) {
      ctx.fillStyle = '#4A4A4A';
      ctx.font = `bold ${Math.round(34 * s)}px sans-serif`;
      ctx.fillText(st.dateText, 960, DATE_CY * s);
    }

    ctx.textAlign = 'left';
    // 右下角漏光补偿（浅色主题上尤其明显，必须画）
    Chrome.vignette(ctx, 1920, 462, vig, vigReach, vigCorner);
  }

  /** 卡片内三行文字：标题 / 主数值（温度·占用）/ 次数值（频率） */
  private static cardText(ctx: CanvasRenderingContext2D, x: number, w: number,
                          title: string, main1: string, main2: string, sub: string,
                          ink: string, inkSoft: string): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    // 字号按官方原图量测（对比图里官方卡片：标题≈80px、主数值≈100px、次数值≈80px）
    ctx.fillStyle = ink;
    ctx.font = 'bold 80px sans-serif';
    ctx.fillText(title, x + w / 2, ROW_TITLE);

    // ★ 主数值那一行是**两个数并排**（官方：`50℃  1%`）。两串字各自量宽、
    //   按总宽居中排，而不是写死 ±62/+78 的偏移 —— 写死会在数字变长时压在一起
    //   （实测 `50°C` 与 `1%` 叠了 28%），也会在只显示一个值时偏到一边。
    if (main2.length > 0) {
      ctx.font = 'bold 100px sans-serif';
      const w1 = ctx.measureText(main1).width;
      const w2 = ctx.measureText(main2).width;
      const gap = 30;
      const total = w1 + w2 + gap;
      let cx = x + w / 2 - total / 2;
      ctx.textAlign = 'left';
      ctx.fillStyle = ink;
      ctx.fillText(main1, cx, ROW_MAIN);
      ctx.fillText(main2, cx + w1 + gap, ROW_MAIN);
      ctx.textAlign = 'center';
    } else {
      ctx.fillStyle = ink;
      ctx.font = 'bold 100px sans-serif';
      ctx.fillText(main1, x + w / 2, ROW_MAIN);
    }

    ctx.fillStyle = ink;
    ctx.font = 'bold 80px sans-serif';
    ctx.fillText(sub, x + w / 2, ROW_SUB);
  }

  /** 柔和投影：在卡片位置偏移几像素画一层半透明深色，再模糊感由低透明度近似 */
  private static cardShadow(ctx: CanvasRenderingContext2D, x: number, y: number,
                            w: number, h: number, r: number): void {
    for (let i = 3; i >= 1; i--) {
      ctx.globalAlpha = 0.06 * i;
      ctx.fillStyle = '#000000';
      ThemeTrcc.roundRect(ctx, x + i, y + i + 2, w, h, r);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
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

  private static pad2(n: number): string {
    return (n < 10 ? '0' : '') + n;
  }
}
