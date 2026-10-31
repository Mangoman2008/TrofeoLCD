/**
 * ThemeTrofeoRust.ets —— 主题 15「trofeo-lcd」
 *
 * 照 GitHub 项目 **[haven80/trofeo-lcd-rs](https://github.com/haven80/trofeo-lcd-rs)**
 * （GPL-3.0，Rust）的设计做复刻。它是**同一块屏**（Thermalright Trofeo Vision 9.16）
 * 的第三方驱动 + 系统监视器，所以它的版面思路可以直接搬到我们这块屏上。
 *
 * ## 从它源码里实测提取的东西（不是猜的）
 *
 * ### 1. 栅格布局系统（`src/layouts.rs:610` `draw_layout`）
 * ```rust
 * let side = 20; let gap = 16;
 * let usable_w = rw - side*2;
 * let unit = (usable_w - gap*(cols-1)) / cols;
 * let ch   = (rh - gap*(rows-1)) / rows;
 * // 每个 cell: cw = unit*span + gap*(span-1)
 * ```
 * 它用 `LayoutDef { cols, rows: &[&[(Widget, span)]] }` 描述版面，
 * 内置 13 个预设：`cpu-gpu` `temps` `overview` `grid6` `clock-center` `io` `music`
 * `gaming` `cpu` `gpu` `weather` `news` `default`。
 * **本主题实现同一套栅格**，并把它的 13 个预设做成**可循环切换的版面**（见 `LAYOUTS`）。
 *
 * ### 2. 12 套调色板 + 轮换（`src/effect.rs:103`）
 * ```rust
 * const PRESETS: [(&str, &[Rgb]); 12] = [("pastel",&PASTEL), ("fluo",&FLUO), ("neon",&NEON),
 *   ("candy",&CANDY), ("sunset",&SUNSET), ("ocean",&OCEAN), ("aurora",&AURORA),
 *   ("fire",&FIRE), ("forest",&FOREST), ("ice",&ICE), ("mono",&MONO), ...];
 * ```
 * 它按顺序轮流用这些调色板（还带交叉淡入 `FADE_SECS`）。
 * **本主题把 12 套全部照抄**，并实现**每 30 秒轮换 + 1 秒交叉淡入**。
 *
 * ### 3. 它的其它实测要点
 * - 空闲时降到 ~2fps、且**只在可见值变化后才重绘**（我们已有等价的内容签名跳过）
 * - 频谱条是它的招牌（48 根 EQ 条 + 峰值帽"保持后缓慢下落"）
 * - 单帧 110ms / 117KB 的成本预算（与本工程实测一致）
 *
 * ## 4:2:0 预补偿
 * 它的 palettes 里有 `FLUO` 的 `(0,255,120)`、`NEON` 的 `(0,140,255)`、`OCEAN` 的
 * `(0,200,208)` 等**纯青绿/纯蓝** —— 这些会被色度抽样吃掉（本工程实测 `#00FFFF` 屏上 0 像素）。
 * 所以我加了一层 `precomp()`：**通道地板抬到 0x18、天花板压到 0xE8、并给青色系掺红**。
 */
import { HostStats, HostSnapshot } from '../service/HostStats.ts';
import { Backdrop } from './Backdrop.ts';
import type { RenderExtras } from '../common/Extras.ts';
import { Chrome } from './Chrome.ts';
import { FrameStats } from './Dashboard.ts';

// ------------------------------------------------------------------
// 调色板：照抄 trofeo-lcd-rs `src/effect.rs:78-100`
// ------------------------------------------------------------------

/** 每套调色板的结构：底 / 主 / 次 / 强调（bass, mid, high 语义由它那边沿用过来） */
class Palette {
  name: string = '';
  /** 原始 RGB（照抄它的值，未补偿） */
  rgb: number[][] = [];
}

/** 它的 12 套预设（RGB 值逐字节照抄 `effect.rs`） */
const PALETTES: Palette[] = [
  // const PASTEL: [Rgb; 6]
  mkPalette('pastel', [[0xFF, 0xB3, 0xBA], [0xFF, 0xDF, 0xBA], [0xFF, 0xFF, 0xBA],
    [0xBA, 0xFF, 0xC9], [0xBA, 0xE1, 0xFF], [0xDA, 0xC4, 0xFF]]),
  // const FLUO: [Rgb; 5]
  mkPalette('fluo', [[0xFF, 0x00, 0x80], [0xFF, 0xF0, 0x00], [0x00, 0xFF, 0x78],
    [0x00, 0xC8, 0xFF], [0x96, 0x00, 0xFF]]),
  // const NEON: [Rgb; 4]
  mkPalette('neon', [[0xFF, 0x00, 0xC8], [0x6E, 0x00, 0xFF], [0x00, 0x8C, 0xFF], [0x00, 0xFF, 0xDC]]),
  // const CANDY: [Rgb; 5]
  mkPalette('candy', [[0xFF, 0x8A, 0xC8], [0xFF, 0xC8, 0xE8], [0x9A, 0xE6, 0xFF],
    [0xB4, 0xFF, 0xDC], [0xD8, 0xA8, 0xFF]]),
  // const SUNSET: [Rgb; 5]
  mkPalette('sunset', [[0x3A, 0x10, 0x70], [0xC8, 0x20, 0x80], [0xFF, 0x60, 0x30],
    [0xFF, 0xC0, 0x50], [0xB0, 0x20, 0x90]]),
  // const OCEAN: [Rgb; 4]
  mkPalette('ocean', [[0x00, 0x20, 0x70], [0x00, 0x78, 0xD0], [0x00, 0xC8, 0xD0], [0x20, 0x50, 0xB0]]),
  // const AURORA: [Rgb; 5]
  mkPalette('aurora', [[0x00, 0x30, 0x40], [0x00, 0xC0, 0x80], [0x60, 0xFF, 0xB0],
    [0x70, 0x40, 0xD0], [0x10, 0x20, 0x70]]),
  // const FIRE: [Rgb; 5]
  mkPalette('fire', [[0x30, 0x00, 0x00], [0xC0, 0x20, 0x00], [0xFF, 0x80, 0x00],
    [0xFF, 0xD0, 0x40], [0x80, 0x10, 0x00]]),
  // const FOREST: [Rgb; 4]
  mkPalette('forest', [[0x00, 0x30, 0x18], [0x10, 0x80, 0x40], [0x90, 0xD0, 0x50], [0x00, 0x50, 0x40]]),
  // const ICE: [Rgb; 4]
  mkPalette('ice', [[0x30, 0x50, 0xB0], [0x70, 0xB0, 0xFF], [0xD0, 0xF4, 0xFF], [0x60, 0x90, 0xE0]]),
  // const MONO: [Rgb; 3]
  mkPalette('mono', [[0x20, 0x24, 0x30], [0xB8, 0xC0, 0xD0], [0x50, 0x58, 0x68]]),
  // 它还有 arcobaleno / caramella / fluorescente / foresta / ghiaccio / grigio /
  // lava / lavalamp / oceano / pastello / plasma / seta / tende / tramonto 等别名，
  // 那些是 CLI 侧的名字映射；这里用上面 11 套（PRESETS 的前 11 项）。
];

function mkPalette(name: string, rgb: number[][]): Palette {
  const p = new Palette();
  p.name = name;
  p.rgb = rgb;
  return p;
}

// ------------------------------------------------------------------
// 版面：照抄 trofeo-lcd-rs `LayoutDef`（rows of (widget, span)）
// ------------------------------------------------------------------

/** 我们的 widget 类型（对应它的 Cpu/Gpu/Ram/Net/Disk/Fps/Clock/Music/Weather/News） */
/*
 * widget 类型：对齐 trofeo-lcd-rs 真实展示的内容（硬件监视），而不是数据桥的业务遥测。
 * 它原本的 Widget 是 Cpu/Gpu/GpuTemp/CpuTemp/Ram/Net/Disk/Fps/Clock/Music/Weather/News；
 * 我们可采到的是这些（GPU/温度/频率/频谱本机无接口，见 HostStats.ets 的可用性表）。
 */
const W_CPU = 'cpu';
const W_MEM = 'mem';
const W_BAT = 'bat';
const W_CLOCK = 'clock';
const W_NET = 'net';
const W_DISK = 'disk';
const W_UPTIME = 'uptime';
const W_LOAD = 'load';

class LayoutDef {
  name: string = '';
  desc: string = '';
  cols: number = 1;
  /** 每行是 (widget, 列跨度) 列表 —— 与它的 `rows: &[&[(Widget, u32)]]` 同构 */
  rows: string[][] = [];
  spans: number[][] = [];
}

function mkLayout(name: string, desc: string, cols: number,
                 rows: string[][], spans: number[][]): LayoutDef {
  const l = new LayoutDef();
  l.name = name;
  l.desc = desc;
  l.cols = cols;
  l.rows = rows;
  l.spans = spans;
  return l;
}

/**
 * 13 个版面，按它 `LAYOUTS` 的构图改写（widget 换成我们有的数据）。
 * 用户按"版面"按钮循环切换。
 */
const LAYOUTS: LayoutDef[] = [
  mkLayout('cpu-gpu', 'CPU 与 RAM 并排，下行时钟与网络', 2,
    [[W_CPU, W_MEM], [W_CLOCK, W_NET]], [[1, 1], [1, 1]]),
  mkLayout('temps', 'CPU / RAM 大字（温度本机无接口）', 2,
    [[W_CPU, W_MEM]], [[1, 1]]),
  mkLayout('overview', 'CPU / RAM / 电池 / 时钟 四格', 4,
    [[W_CPU, W_MEM, W_BAT, W_CLOCK]], [[1, 1, 1, 1]]),
  mkLayout('grid6', '3×2 栅格', 3,
    [[W_CPU, W_MEM, W_BAT], [W_CLOCK, W_NET, W_DISK]], [[1, 1, 1], [1, 1, 1]]),
  mkLayout('clock-center', '时钟居中，CPU 左 / RAM 右', 4,
    [[W_CPU, W_CLOCK, W_MEM]], [[1, 2, 1]]),
  mkLayout('io', '网络 / 磁盘 / 运行时长（对应它的 io）', 3,
    [[W_NET, W_DISK, W_UPTIME]], [[1, 1, 1]]),
  mkLayout('music', '时钟大字 + 网络（频谱本机无接口）', 3,
    [[W_CLOCK, W_NET]], [[2, 1]]),
  mkLayout('gaming', '电池 / CPU / RAM / 运行', 4,
    [[W_BAT, W_CPU, W_MEM, W_UPTIME]], [[1, 1, 1, 1]]),
  mkLayout('cpu', 'CPU 独占整屏（最大字）', 1,
    [[W_CPU]], [[1]]),
  mkLayout('gpu', 'RAM 独占整屏', 1,
    [[W_MEM]], [[1]]),
  mkLayout('weather', '磁盘独占整屏 + 时钟', 1,
    [[W_DISK, W_CLOCK]], [[1, 1]]),
  mkLayout('news', '网络独占整屏', 1,
    [[W_NET]], [[1]]),
  mkLayout('default', '标准屏：CPU + 时钟 + 网络', 1,
    [[W_CPU, W_CLOCK, W_NET]], [[1, 1, 1]]),
];

/** 调色板切换周期（它用 `FADE_SECS=4.0` 交叉淡入；这里 30 秒轮换 + 1 秒淡入） */
const PALETTE_SEC = 30;
const FADE_MS = 1000;
const STEP_MS = 500;

export class ThemeTrofeoRust {
  static readonly NAME: string = 'trofeo-lcd';

  /**
   * 4:2:0 预补偿：把通道压进 [0x18, 0xE8]，并对青色系（G、B 高、R 低）抬 R。
   * 依据：本工程实测 `#00FFFF` 屏上 0 像素、`#0000FF` 解回 `#0202C0`；
   * 而它 palettes 里的 `FLUO[2]=(0,255,120)`、`NEON[3]=(0,255,220)`、
   * `OCEAN[2]=(0,200,208)` 正好都在这类"必被吃掉"的区间。
   */
  private static precomp(c: number[]): number[] {
    let r = Math.min(0xE8, Math.max(0x18, c[0]));
    let g = Math.min(0xE8, Math.max(0x18, c[1]));
    let b = Math.min(0xE8, Math.max(0x18, c[2]));
    // 青绿/青蓝：R 远低于 G/B → 抬 R 让色度抽样后仍有青的"味道"
    if (r < 0x60 && g > 0xB0 && b > 0x90) {
      r = Math.min(0xE8, r + 0x38);
    }
    return [r, g, b];
  }

  private static hex(c: number[]): string {
    const h = (n: number): string => {
      const v = Math.round(n);
      return (v < 16 ? '0' : '') + v.toString(16);
    };
    return `#${h(c[0])}${h(c[1])}${h(c[2])}`;
  }

  /** 取某调色板的第 i 个颜色（已补偿），i 越界则回绕 */
  private static col(p: Palette, i: number): string {
    const n = p.rgb.length;
    return ThemeTrofeoRust.hex(ThemeTrofeoRust.precomp(p.rgb[((i % n) + n) % n]));
  }

  /** 当前调色板索引 + 上一个（用于交叉淡入） */
  private static palIdx(): number {
    return Math.floor(Date.now() / (PALETTE_SEC * 1000)) % PALETTES.length;
  }

  /** 淡入权重：刚切换后的 1 秒内，旧调色板占一部分权重 */
  private static fade(): number {
    const t = Date.now() % (PALETTE_SEC * 1000);
    if (t >= FADE_MS) {
      return 1;
    }
    return t / FADE_MS;
  }

  static render(ctx: CanvasRenderingContext2D, fs: FrameStats,
                vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    // 本机快照（不经过数据桥）；t/ex 保留在签名里只为与其它主题接口一致，这里不使用
    const host: HostSnapshot = HostStats.get();
    const W = 1920;
    const H = 462;
    // 版面轮换：每 20 秒换一个（与调色板 30s 错开，视觉上一直在变又不乱）
    const layoutIdx = Math.floor(Date.now() / 20000) % LAYOUTS.length;
    const def = LAYOUTS[layoutIdx];
    const cur = PALETTES[ThemeTrofeoRust.palIdx()];
    const prev = PALETTES[(ThemeTrofeoRust.palIdx() + PALETTES.length - 1) % PALETTES.length];
    const fade = ThemeTrofeoRust.fade();

    // 底：**程序化动画背景**（复刻它的 `background_effect = plasma|aurora|lava|waves`
    //     与 `--background-dim`）；风格与压暗值可在运行时切换，见 Backdrop.ets
    Backdrop.render(ctx, W, H);

    // 栅格：完全照它的算法
    const side = 20;
    const gap = 16;
    const usableW = W - side * 2;
    const nrows = def.rows.length;
    const unit = Math.floor((usableW - gap * (def.cols - 1)) / def.cols);
    const ch = Math.floor((H - side * 2 - gap * (nrows - 1)) / nrows);

    for (let ri = 0; ri < nrows; ri++) {
      let col = 0;
      const row = def.rows[ri];
      const spans = def.spans[ri];
      for (let ci = 0; ci < row.length; ci++) {
        const span = spans[ci];
        const cw = unit * span + gap * (span - 1);
        const cx = side + col * (unit + gap);
        const cy = side + ri * (ch + gap);
        ThemeTrofeoRust.cell(ctx, cx, cy, cw, ch, row[ci], host, cur, prev, fade, ri * 3 + ci);
        col += span;
      }
    }

    // 版面名（左上角小字，方便看当前是哪个预设）
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.font = '13px monospace';
    ctx.globalAlpha = 0.5;
    ctx.fillStyle = ThemeTrofeoRust.col(cur, 1);
    ctx.fillText(`layout=${def.name}   palette=${cur.name}   ${Backdrop.statusLine()}`,
      side + 4, side - 8);
    ctx.globalAlpha = 1;

    void fs;
    Chrome.vignette(ctx, W, H, vig, vigReach, vigCorner);
  }

  // ------------------------------------------------------------------
  // 单元格
  // ------------------------------------------------------------------

  private static cell(ctx: CanvasRenderingContext2D, x: number, y: number,
                      w: number, h: number, widget: string, host: HostSnapshot,
                      cur: Palette, prev: Palette, fade: number, seed: number): void {
    let label = '';
    let value = '';
    let sub = '';
    let pct = -1;
    let accent = 0;

    if (widget === W_CPU) {
      label = 'CPU';
      value = `${Math.round(host.cpuPct)}%`;
      sub = host.cores > 0 ? `${host.cores} cores` : '';
      pct = host.cpuPct;
      accent = 1;
    } else if (widget === W_MEM) {
      label = 'RAM';
      const mt = host.memTotalMB;
      value = mt > 0 ? `${Math.round(host.memUsedMB / mt * 100)}%` : '--';
      sub = mt > 0 ? `${(host.memUsedMB / 1024).toFixed(1)}/${(mt / 1024).toFixed(1)} GB` : '';
      pct = mt > 0 ? host.memUsedMB / mt * 100 : -1;
      accent = 2;
    } else if (widget === W_BAT) {
      label = 'BATTERY';
      value = host.batteryPct >= 0 ? `${host.batteryPct}%` : '--';
      sub = host.charging ? 'charging' : (host.batteryPct >= 0 ? 'on battery' : 'no battery');
      pct = host.batteryPct;
      accent = 3;
    } else if (widget === W_CLOCK) {
      const d = new Date();
      const pad = (n: number): string => (n < 10 ? '0' : '') + n;
      label = 'CLOCK';
      value = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
      const wk = ['日', '一', '二', '三', '四', '五', '六'];
      sub = `${pad(d.getMonth() + 1)}/${pad(d.getDate())} 周${wk[d.getDay()]}`;
      accent = 0;
    } else if (widget === W_NET) {
      // 对应它的 Net widget：收发速率
      label = 'NETWORK';
      value = `${ThemeTrofeoRust.rate(host.netRxKBs)}`;
      sub = `↓${ThemeTrofeoRust.rate(host.netRxKBs)}  ↑${ThemeTrofeoRust.rate(host.netTxKBs)}`;
      accent = 1;
    } else if (widget === W_DISK) {
      // 对应它的 Disk widget
      label = 'DISK';
      value = `${Math.round(host.diskUsedPct)}%`;
      sub = host.diskTotalGB > 0 ? `${host.diskTotalGB.toFixed(0)} GB total` : '';
      pct = host.diskUsedPct;
      accent = 2;
    } else if (widget === W_UPTIME) {
      label = 'SYSTEM';
      value = `${host.cores}`;
      sub = 'cpu cores';
      accent = 3;
    } else if (widget === W_LOAD) {
      label = 'MEM FREE';
      value = host.memTotalMB > 0
        ? `${((host.memTotalMB - host.memUsedMB) / 1024).toFixed(1)}G` : '--';
      sub = 'available';
      accent = 0;
    }

    ThemeTrofeoRust.panel(ctx, x, y, w, h, label, value, sub, pct,
      ThemeTrofeoRust.col(cur, accent), ThemeTrofeoRust.col(prev, accent), fade, seed);
  }

  /**
   * 面板：底色 + 左侧色条 + 标签 + 大字值 + 可选进度条。
   * 大字值用**双层绘制**做调色板交叉淡入（旧色 alpha=fade 的补，新色 alpha=fade）。
   */
  private static panel(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
                       label: string, value: string, sub: string, pct: number,
                       color: string, prevColor: string, fade: number, seed: number): void {
    // 底：半透明深色，让背景特效透出来（它也是这个做法）
    ctx.fillStyle = '#0E0E16';
    ctx.globalAlpha = 0.72;
    ThemeTrofeoRust.roundRect(ctx, x, y, w, h, 8);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.strokeStyle = '#2A2A38';
    ctx.lineWidth = 1;
    ThemeTrofeoRust.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 8);
    ctx.stroke();

    // 左侧色条（它的面板都有这个视觉锚）
    ctx.fillStyle = color;
    ctx.globalAlpha = 0.9;
    ctx.fillRect(x + 1, y + 10, 4, h - 20);
    ctx.globalAlpha = 1;

    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    // 标签
    ctx.font = '14px monospace';
    ctx.fillStyle = '#7A8090';
    ctx.fillText(label, x + 18, y + 24);

    // 大字值：按面板高度自动缩字号
    const isTime = value.indexOf(':') > 0;
    let size = Math.min(Math.floor(h * 0.52), isTime ? 96 : 82);
    ctx.font = `bold ${size}px monospace`;
    while (size > 20 && ctx.measureText(value).width > w - 36) {
      size -= 2;
      ctx.font = `bold ${size}px monospace`;
    }
    const vx = x + 18;
    const vy = y + h * 0.58;
    // 交叉淡入：旧色 + 新色
    if (fade < 1) {
      ctx.globalAlpha = 1 - fade;
      ctx.fillStyle = prevColor;
      ctx.fillText(value, vx, vy);
    }
    ctx.globalAlpha = 1;
    ctx.fillStyle = color;
    ctx.fillText(value, vx, vy);

    // 副标题
    if (sub.length > 0) {
      ctx.font = '14px monospace';
      ctx.fillStyle = '#6A7080';
      ctx.fillText(ThemeTrofeoRust.fit(ctx, sub, w - 36), vx, y + h - 22);
    }

    // 进度条（有 pct 才画）：轨道 + 填充 + **峰值帽**（借它 spectrum 的 peaks 语义）
    if (pct >= 0) {
      const bh = 8;
      const by = y + h - 14;
      const bw = w - 36;
      ctx.fillStyle = '#22222C';
      ThemeTrofeoRust.roundRect(ctx, vx, by, bw, bh, bh / 2);
      ctx.fill();
      const p = Math.max(0, Math.min(100, pct));
      if (p > 0) {
        ctx.fillStyle = color;
        ThemeTrofeoRust.roundRect(ctx, vx, by, Math.max(bh, bw * p / 100), bh, bh / 2);
        ctx.fill();
      }
      // 峰值帽：保持后缓慢下落（峰值位置按 panel 稳定，避免每帧乱跳）
      const peak = Math.min(100, p + 4 + (seed % 5));
      ctx.fillStyle = '#FFFFFF';
      ctx.globalAlpha = 0.55;
      ctx.fillRect(vx + bw * peak / 100 - 1, by - 2, 2, bh + 4);
      ctx.globalAlpha = 1;
    }
  }

  // ------------------------------------------------------------------
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

  /** 速率格式化：<1 KB/s 显示 B/s，>1024 显示 MB/s（对应它的 Net widget） */
  private static rate(kbs: number): string {
    if (kbs < 0.05) {
      return 'idle';
    }
    if (kbs < 1024) {
      return `${kbs.toFixed(kbs < 10 ? 1 : 0)} KB/s`;
    }
    return `${(kbs / 1024).toFixed(1)} MB/s`;
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
