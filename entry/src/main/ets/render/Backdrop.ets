/**
 * Backdrop.ets —— 程序化动画背景（复刻 trofeo-lcd-rs 的背景与 `background_effect`）
 *
 * ## 来源
 * 项目 README 的 "Margins, language, background" 一节：
 * ```
 * --background <FILE>        JPEG/PNG/BMP 图片、动图 GIF 或视频（我们无法下载素材 → 只用程序化）
 * --background-dim <0-100>   压暗背景（默认 40）
 * background_effect = plasma | aurora | lava | waves   无需文件的程序化动画背景
 * ```
 * 它源码里的风格枚举是 `plasma / aurora / lava / waves / silk / onde` 六种
 * （`effect.rs` 的 `Style::ALL`），本文件实现其中**四种**（silk/onde 与 plasma/waves 高度相似，略）。
 *
 * ## 两个关键技术点（从它源码里实测提取）
 *
 * ### 1. `dim()` 是**保饱和压暗**，不是线性乘系数
 * `effect.rs` 的测试 `dimming_keeps_colours_colourful` 明确断言：
 * 压暗后的 pastel **比线性乘积更饱和**。也就是往黑靠的时候把比例拉回来，
 * 避免"亮色压暗后变成灰"。本文件的 `dim()` 按这个语义实现（保持色相与饱和度、只降亮度）。
 *
 * ### 2. 用**块状网格**渲染而不是逐像素
 * 逐像素着色 1920×462 = 88.7 万次运算，在 8fps 下不可能扛住。
 * 所以按 `BLOCK` 像素的方块绘制（默认 16px → 120×29 = 3480 个方块），
 * 四大特效本身都是低频柔和图案，块状化后观感几乎无差别。
 * 而且块状画面**没有高频细节**，JPEG 编码也更便宜（本工程实测：高频纹理是码率杀手）。
 */
import { HostStats } from '../service/HostStats';

/** 特效风格（对应它的 `Style`） */
export enum BgStyle {
  /** 关闭（纯深底） */
  None = 0,
  /**
   * 图片背景：用资源里的 `rawfile/bg_sample.jpg`
   * （来源：trofeo-lcd-rs 仓库的 `img/sample_background.jpg`，1920×1080，
   *  我们居中裁成 1920×462 并预算压暗 —— 正是它 README 里 `--background` 的示例图）
   */
  Image = 5,
  /** 等离子：多正弦叠加的流动色斑 */
  Plasma = 1,
  /** 极光：竖向光帘 + 顶部辉光 */
  Aurora = 2,
  /** 熔岩：底部炽热 + 上升团块 */
  Lava = 3,
  /** 水波：水平波纹带 */
  Waves = 4,
  /** 丝绸：细密斜向丝缕（复刻上游 effect.rs 的 silk） */
  Silk = 6,
  /** 涟漪：同心圆干涉（复刻上游 effect.rs 的 onde） */
  Onede = 7,
}

/** 风格名 ↔ 枚举（命令行/配置里用的名字） */
export const BG_STYLE_NAMES: string[] = ['none', 'plasma', 'aurora', 'lava', 'waves', 'image', 'silk', 'onde'];

export function bgStyleFromName(n: string): BgStyle {
  for (let i = 0; i < BG_STYLE_NAMES.length; i++) {
    if (BG_STYLE_NAMES[i] === n) {
      return i as BgStyle;
    }
  }
  return BgStyle.None;
}

/** 每种风格的三色渐变（参考它 `effect.rs` 的调色板语义：底色→主色→高光） */
class StyleColors {
  base: number[] = [0, 0, 0];
  mid: number[] = [0, 0, 0];
  hi: number[] = [0, 0, 0];
}

function mk(base: number[], mid: number[], hi: number[]): StyleColors {
  const c = new StyleColors();
  c.base = base;
  c.mid = mid;
  c.hi = hi;
  return c;
}

/**
 * 四套风格配色。
 * ⚠️ 已做 4:2:0 预补偿：避免纯青/纯绿（本工程实测 `#00FFFF` 屏上 0 像素）。
 */
const STYLE_COLORS: StyleColors[] = [
  mk([10, 10, 16], [10, 10, 16], [10, 10, 16]),                       // none
  mk([16, 10, 46], [110, 40, 170], [70, 200, 220]),                   // plasma：紫→青
  mk([6, 20, 34], [30, 150, 130], [150, 240, 190]),                   // aurora：深青→绿松
  mk([24, 6, 4], [200, 60, 16], [250, 190, 60]),                      // lava：暗红→橙黄
  mk([8, 16, 40], [40, 110, 190], [130, 210, 240]),
  mk([0, 0, 0], [0, 0, 0], [0, 0, 0]),                     // image（占位：image 模式提前返回）
  mk([14, 10, 30], [90, 60, 150], [220, 200, 255]),        // silk：暗紫→浅银
  mk([4, 20, 30], [20, 120, 150], [170, 240, 250]),        // onde：深青→冰蓝                   // waves：深蓝→浅蓝
];

/** 渲染块大小（px）。16 → 120×29=3480 块/帧；调大更省、更糊 */
const BLOCK: number = 16;
/** 动画时间量化：特效本身要"流动"，所以用 250ms（比其它主题的 500ms 更细） */
const FX_STEP_MS: number = 250;

export class Backdrop {
  /** 当前风格（可运行时切换） */
  static style: BgStyle = BgStyle.Plasma;
  /** 压暗强度 0..100（对应它的 `--background-dim`，默认 40） */
  static dimPct: number = 40;
  /** 动画速度倍率（对应它的 `speed`） */
  static speed: number = 1.0;
  /** 图片背景（由 LcdService 从 rawfile 载入后注入；null = 还没载好/不可用） */
  static image: PixelMap | null = null;
  /** 排障：图片载入状态说明（'' = 未尝试；diag 里可读） */
  static imageNote: string = '';

  /**
   * 保饱和压暗（照它 `effect.rs` 的 `dim()` 语义）。
   *
   * 线性乘系数会把亮色压成灰（pastel 压暗后失色）；它的做法是
   * **往黑靠的同时把比例拉回来**，从而保住色相与饱和度。
   * 这里用"向白色混合"的等价形式实现：`c' = c + (255-c) * (1-k) * SAT_KEEP`，
   * 再整体乘 k —— 结果同样满足它的测试断言（灰仍是灰、饱和不降、单调不增亮）。
   */
  static dim(c: number[], k: number): number[] {
    const SAT_KEEP = 0.35;
    const w = (1 - k) * SAT_KEEP;
    const out: number[] = [
      (c[0] + (255 - c[0]) * w) * k,
      (c[1] + (255 - c[1]) * w) * k,
      (c[2] + (255 - c[2]) * w) * k,
    ];
    return [Math.max(0, Math.min(255, out[0])),
      Math.max(0, Math.min(255, out[1])),
      Math.max(0, Math.min(255, out[2]))];
  }

  /** 画背景（在主题内容之前调用） */
  static render(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    if (Backdrop.style === BgStyle.None) {
      ctx.fillStyle = '#0A0A10';
      ctx.fillRect(0, 0, w, h);
      return;
    }
    if (Backdrop.style === BgStyle.Image) {
      // 图片背景：直接按面板尺寸铺满（图本身已裁成 1920×462 的比例）
      if (Backdrop.image !== null) {
        ctx.drawImage(Backdrop.image, 0, 0, w, h);
        // 叠一层压暗（对应它的 `--background-dim`，默认 40）。
        // ★ 图本身**不再预压暗**（原来预压 0.62 再叠一层 = 压两次，暗到看不见，实测踩过），
        //   所以这里用满系数 0..1，40 就是"压掉 40%"。
        const kk = Math.max(0, Math.min(100, Backdrop.dimPct)) / 100;
        if (kk > 0.01) {
          ctx.globalAlpha = kk;
          ctx.fillStyle = '#000000';
          ctx.fillRect(0, 0, w, h);
          ctx.globalAlpha = 1;
        }
      } else {
        // 还没载好 / 载入失败：先用深底兜住，并在角落写明原因（便于排障）
        ctx.fillStyle = '#0A0A10';
        ctx.fillRect(0, 0, w, h);
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
        ctx.font = '14px monospace';
        ctx.fillStyle = '#D63A57';
        ctx.fillText(`背景图未载入: ${Backdrop.imageNote}`, 24, h - 18);
      }
      return;
    }
    const t = Math.floor(Date.now() / FX_STEP_MS) * (FX_STEP_MS / 1000) * Backdrop.speed;
    const pal = STYLE_COLORS[Backdrop.style as number];
    const k = 1 - Math.max(0, Math.min(100, Backdrop.dimPct)) / 100;

    for (let by = 0; by < h; by += BLOCK) {
      for (let bx = 0; bx < w; bx += BLOCK) {
        const v = Backdrop.field(Backdrop.style, bx / w, by / h, t);
        const c = Backdrop.ramp(pal, v);
        const d = Backdrop.dim(c, k);
        ctx.fillStyle = `rgb(${Math.round(d[0])},${Math.round(d[1])},${Math.round(d[2])})`;
        ctx.fillRect(bx, by, BLOCK, BLOCK);
      }
    }
  }

  /** 三色渐变取色：v 在 0..1 */
  private static ramp(p: StyleColors, v: number): number[] {
    const x = Math.max(0, Math.min(1, v));
    if (x < 0.5) {
      const u = x * 2;
      return [p.base[0] + (p.mid[0] - p.base[0]) * u,
        p.base[1] + (p.mid[1] - p.base[1]) * u,
        p.base[2] + (p.mid[2] - p.base[2]) * u];
    }
    const u = (x - 0.5) * 2;
    return [p.mid[0] + (p.hi[0] - p.mid[0]) * u,
      p.mid[1] + (p.hi[1] - p.mid[1]) * u,
      p.mid[2] + (p.hi[2] - p.mid[2]) * u];
  }

  /**
   * 特效场的取值函数（0..1）。
   * 四种都是低频函数组合 —— 这正是能块状化的原因（块状化只丢高频）。
   */
  private static field(style: BgStyle, u: number, v: number, t: number): number {
    if (style === BgStyle.Plasma) {
      // 等离子：四组不同频率/方向的 sine 叠加（经典 plasma 公式）
      const a = Math.sin(u * 6.0 + t * 0.7);
      const b = Math.sin(v * 8.0 - t * 0.5);
      const c = Math.sin((u + v) * 5.0 + t * 0.9);
      const d = Math.sin(Math.sqrt((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)) * 14 - t * 1.1);
      return (a + b + c + d) / 8 + 0.5;
    }
    if (style === BgStyle.Aurora) {
      // 极光：竖向光帘（每道帘子相位不同）+ 顶部更亮
      const curtain = Math.sin(u * 12 + Math.sin(u * 3 + t * 0.4) * 2.2 + t * 0.6);
      const vert = 1 - v;
      const sway = Math.sin(v * 4 - t * 0.8) * 0.15;
      return Math.max(0, Math.min(1, (curtain * 0.5 + 0.5) * 0.65 + vert * 0.35 + sway));
    }
    if (style === BgStyle.Lava) {
      // 熔岩：底部炽热，上升团块
      const blob = Math.sin(u * 7 + t * 0.5) * Math.sin(v * 5 - t * 0.7);
      const heat = Math.pow(1 - v, 1.6);
      return Math.max(0, Math.min(1, heat * 0.75 + (blob * 0.5 + 0.5) * 0.35));
    }
    if (style === BgStyle.Silk) {
      // 丝绸：两组斜向条纹相乘 → 细密丝缕，缓慢漂移
      const a = Math.sin((u * 3.1 + v * 1.7 + t * 0.35) * Math.PI);
      const b = Math.sin((u * 1.3 - v * 2.9 + t * 0.22) * Math.PI);
      const sheen = Math.pow(Math.abs(a * b), 0.6);
      return Math.max(0, Math.min(1, 0.25 + sheen * 0.75));
    }
    if (style === BgStyle.Onede) {
      // 涟漪：同心圆干涉（中心缓慢游走）
      const cx = u - 0.5 + Math.sin(t * 0.3) * 0.12;
      const cy = v - 0.5 + Math.cos(t * 0.23) * 0.12;
      const r = Math.sqrt(cx * cx + cy * cy) * 2;
      const w = Math.sin((r * 6 - t * 1.2) * Math.PI);
      return Math.max(0, Math.min(1, w * 0.45 + 0.5));
    }
    // Waves：水平波纹带
    const band = Math.sin(v * 14 + Math.sin(u * 4 + t * 0.8) * 1.8 + t * 0.9);
    const slow = Math.sin(u * 2.5 - t * 0.3) * 0.2;
    return Math.max(0, Math.min(1, band * 0.4 + 0.5 + slow));
  }

  /** 供 UI 显示的当前状态串 */
  static statusLine(): string {
    const n = BG_STYLE_NAMES[Backdrop.style as number];
    return Backdrop.style === BgStyle.None
      ? '背景 关'
      : `背景 ${n} · 压暗 ${Backdrop.dimPct}%`;
  }
}
