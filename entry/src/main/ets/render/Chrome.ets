/**
 * Chrome.ets —— 三个主题共用的"装饰件"
 *
 * 为什么集中在这里：弹窗、曲线、卡片、背景如果每个主题各写一份，
 * 就会出现"改了 A 主题忘了 B 主题"的经典冲突（这个项目已经踩过：手工镜像的布局）。
 * 所以凡是"多个主题都要画的东西"一律放这里，主题只负责摆位置。
 */
import type { History, Series } from '../common/History';
import type { Toast } from '../common/Toasts';
import { C, F } from '../common/Theme';

export class Chrome {
  // ---------------- 渐变缓存 ----------------
  /**
   * ★ 渐变缓存（2026-10-31 审计 C2）。
   *
   * 背景/曲线/暗角每帧都 createXxxGradient：一次对象分配 + addColorStop 的字符串
   * 解析，每帧 ×（背景 2 + 暗角 1 + 曲线 N）次 —— 而参数在帧间几乎不变，纯浪费。
   * 按"几何 + 颜色"拼 key 缓存 CanvasGradient 对象，命中即零开销。
   *
   * · 上限 32：满了整体清空（代价只是之后逐个重建，单次 <0.01ms，不值得 LRU）。
   * · ctx 变了整体作废：规范上 gradient 不绑定 ctx，但 ArkUI 原生实现未必；
   *   画布重建/分辨率变化后旧对象不可信，宁可重建。
   */
  private static gradOwner: CanvasRenderingContext2D | null = null;
  private static gradCache: Map<string, CanvasGradient> = new Map();

  private static gradient(ctx: CanvasRenderingContext2D, key: string,
                          make: () => CanvasGradient): CanvasGradient {
    if (Chrome.gradOwner !== ctx) {
      Chrome.gradOwner = ctx;
      Chrome.gradCache.clear();
    }
    const hit = Chrome.gradCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const g = make();
    if (Chrome.gradCache.size >= 32) {
      Chrome.gradCache.clear();
    }
    Chrome.gradCache.set(key, g);
    return g;
  }

  // ---------------- 背景 ----------------
  /**
   * 画背景：有背景图就画图（压暗 + 冷色蒙板），否则用主题自带渐变。
   * tint 为蒙板透明度（0..1），越大越暗、越能保证前景文字可读。
   */
  static background(ctx: CanvasRenderingContext2D, w: number, h: number,
                    bg: PixelMap | null, tint: number = 0.55): void {
    if (bg !== null) {
      ctx.drawImage(bg, 0, 0, w, h);
      ctx.fillStyle = `rgba(3,6,12,${tint.toFixed(2)})`;
      ctx.fillRect(0, 0, w, h);
    } else {
      const g = Chrome.gradient(ctx, `bg|${h}|${C.bgTop}|${C.bgBot}`, () => {
        const lg = ctx.createLinearGradient(0, 0, 0, h);
        lg.addColorStop(0, C.bgTop);
        lg.addColorStop(1, C.bgBot);
        return lg;
      });
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, w, h);
      // 左上角一抹主题色光晕：纯渐变太平，加一点层次
      const rg = Chrome.gradient(ctx, `halo|${w}|${h}`, () => {
        const rad = ctx.createRadialGradient(w * 0.18, -h * 0.25, 10, w * 0.18, -h * 0.25, h * 1.5);
        rad.addColorStop(0, 'rgba(88,166,255,0.10)');
        rad.addColorStop(1, 'rgba(88,166,255,0)');
        return rad;
      });
      ctx.fillStyle = rg;
      ctx.fillRect(0, 0, w, h);
    }
  }

  /**
   * 右下角漏光补偿（软件压暗）。
   *
   * 起因：用户实测这块屏**右下角漏光严重**，观感差。漏光是背光/贴合问题，软件改不了硬件，
   * 但可以用一层"从右下角向外衰减的暗色径向渐变"把那一角的亮度压下去，让它与画面其余部分
   * 的差异降到看不出来 —— 代价是那一角内容略暗。
   *
   * 参数（运行时 /set?vig=0..100，0 = 关）：
   *   strength 0..1  压暗强度（越大越暗）
   *   reach    半径像素（从右下角向外衰减到 0 的距离）
   * 默认值是按 1920×462 这块屏定的：右下角约 320×240 的范围最亮，所以 reach 取 620。
   */
  static vignette(ctx: CanvasRenderingContext2D, w: number, h: number,
                  strength: number = 0.5, reach: number = 620,
                  corner: number = 3): void {
    if (strength <= 0) {
      return;
    }
    // ★ 注意：整帧推之前会做 180° 旋转（本机型 rotMode=0 时 rotate180=true），
    //   所以"缓冲区里的哪个角"和"物理屏上的哪个角"是反的。
    //   物理屏右下角漏光 → 缓冲区里要压的是**左上角**（角码 0）。角码：0=左上 1=右上 2=左下 3=右下。
    const cx = (corner === 1 || corner === 3) ? w : 0;
    const cy = (corner === 2 || corner === 3) ? h : 0;
    const a0 = Math.min(0.92, strength);
    // ★ 椭圆渐变：这块屏是 1920×462（4.16:1），圆渐变会沿着长边铺出很远
    //   （实测 reach=620 时右上角被连带压暗 8.9）。用 save/scale 把平面按宽高比拉伸，
    //   再画"圆"渐变 —— 屏幕上就是一个贴着角的椭圆，衰减集中、不误伤同一条边的另一头。
    const rx = reach;
    const ry = Math.max(90, reach * (h / w));
    ctx.save();
    ctx.translate(cx, cy);
    ctx.scale(rx / ry, 1);
    // ★ C2：渐变本体只依赖 a0 与 ry（中心 (0,0)、半径 ry，坐标系由 paint 时的
    //   translate/scale 决定），按这两者缓存
    const g = Chrome.gradient(ctx, `vig|${a0.toFixed(3)}|${ry.toFixed(1)}`, () => {
      const vg = ctx.createRadialGradient(0, 0, 0, 0, 0, ry);
      vg.addColorStop(0, `rgba(0,0,0,${a0.toFixed(3)})`);
      vg.addColorStop(0.5, `rgba(0,0,0,${(a0 * 0.45).toFixed(3)})`);
      vg.addColorStop(1, 'rgba(0,0,0,0)');
      return vg;
    });
    ctx.fillStyle = g;
    ctx.fillRect(-rx, -ry, rx * 2, ry * 2);
    ctx.restore();
  }

  // ---------------- 卡片 ----------------
  /** 圆角卡片（填色 + 细边）；用作面板/指标卡的统一观感 */
  static card(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
              r: number, fill: string, border: string, borderW: number = 1): void {
    Chrome.roundRect(ctx, x, y, w, h, r);
    ctx.fillStyle = fill;
    ctx.fill();
    if (borderW > 0) {
      Chrome.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, r);
      ctx.strokeStyle = border;
      ctx.lineWidth = borderW;
      ctx.stroke();
    }
  }

  /** 胶囊（状态药丸/芯片） */
  static pill(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
              fill: string): void {
    Chrome.roundRect(ctx, x, y, w, h, h / 2);
    ctx.fillStyle = fill;
    ctx.fill();
  }

  static roundRect(ctx: CanvasRenderingContext2D, x: number, y: number,
                   w: number, h: number, r: number): void {
    const rr = Math.max(0, Math.min(r, w / 2, h / 2));
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

  // ---------------- 曲线 ----------------
  /**
   * 画一条历史曲线：折线 + 底部渐隐填充 + 末端亮点。
   * series 里 -1 表示断点（跳过，线断开）。
   */
  static sparkline(ctx: CanvasRenderingContext2D, s: Series, cap: number,
                   x: number, y: number, w: number, h: number,
                   color: string, fill: boolean = true, dot: boolean = true): void {
    if (s.length === 0) {
      return;
    }
    const max = s.scaleMax();
    const n = s.length;
    // 统一按容量铺开：样本不足时从右边对齐（新数据始终贴右，读起来像"直播"）
    const x0 = x + w * (1 - (n - 1) / (cap - 1 > 0 ? cap - 1 : 1));
    const step = w / (cap - 1 > 0 ? cap - 1 : 1);

    let started = false;
    const path = (): void => { /* noop 占位，保持结构清晰 */ };
    ctx.beginPath();
    let firstX = 0;
    let lastX = 0;
    let lastY = 0;
    for (let i = 0; i < n; i++) {
      const py = s.pointY(i, y, h, max);
      const px = x0 + i * step;
      if (py < 0) {
        started = false;
        continue;
      }
      if (!started) {
        ctx.moveTo(px, py);
        firstX = px;
        started = true;
      } else {
        ctx.lineTo(px, py);
      }
      lastX = px;
      lastY = py;
    }
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.stroke();
    path();

    if (fill && started) {
      ctx.lineTo(lastX, y + h);
      ctx.lineTo(firstX, y + h);
      ctx.closePath();
      const g = Chrome.gradient(ctx, `spark|${y}|${h}|${color}`, () => {
        const sg = ctx.createLinearGradient(0, y, 0, y + h);
        sg.addColorStop(0, Chrome.alpha(color, 0.28));
        sg.addColorStop(1, Chrome.alpha(color, 0.02));
        return sg;
      });
      ctx.fillStyle = g;
      ctx.fill();
    }
    if (dot && started) {
      ctx.beginPath();
      ctx.arc(lastX, lastY, 3.5, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
    }
  }

  /** 把 #RRGGBB 转成带透明度的 rgba（ArkTS 没有现成的） */
  static alpha(hex: string, a: number): string {
    const h = hex.startsWith('#') ? hex.substring(1) : hex;
    if (h.length !== 6) {
      return hex;
    }
    const r = Number.parseInt(h.substring(0, 2), 16);
    const g = Number.parseInt(h.substring(2, 4), 16);
    const b = Number.parseInt(h.substring(4, 6), 16);
    return `rgba(${r},${g},${b},${a.toFixed(2)})`;
  }

  // ---------------- 弹窗 ----------------
  /**
   * 事件弹窗：屏幕中上方一条大字 + 左侧色条 + 底部进度条（剩余时间）。
   * 三个主题共用同一套观感，只是位置不同（这里给的是"居中偏上"的默认位置）。
   */
  static toast(ctx: CanvasRenderingContext2D, t: Toast, now: number,
               w: number, h: number, top: number = 148): void {
    const left = now > t.until ? 0 : (t.until - now);
    const hold = 4000;
    const remain = Math.max(0, Math.min(1, left / hold));
    const color = Chrome.toastColor(t.kind);
    const tw = Math.min(w - 240, 1180);
    const x = (w - tw) / 2;
    const hh = 96;

    // 阴影：先画一层偏移的暗色，再画卡片 —— 廉价但有效的"浮起来"
    Chrome.roundRect(ctx, x + 3, top + 5, tw, hh, 14);
    ctx.fillStyle = 'rgba(0,0,0,0.45)';
    ctx.fill();
    Chrome.card(ctx, x, top, tw, hh, 14, 'rgba(13,17,23,0.96)', Chrome.alpha(color, 0.55));

    // 左侧色条
    Chrome.roundRect(ctx, x + 12, top + 16, 8, hh - 32, 4);
    ctx.fillStyle = color;
    ctx.fill();

    // 文字
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = C.textW;
    ctx.font = F.font(22, 'bold');
    ctx.fillText(t.text, x + 38, top + hh / 2 - 6);

    // 底部进度条（剩余时间）
    Chrome.roundRect(ctx, x + 38, top + hh - 20, tw - 60, 5, 3);
    ctx.fillStyle = 'rgba(255,255,255,0.10)';
    ctx.fill();
    if (remain > 0) {
      Chrome.roundRect(ctx, x + 38, top + hh - 20, (tw - 60) * remain, 5, 3);
      ctx.fillStyle = color;
      ctx.fill();
    }
  }

  static toastColor(kind: string): string {
    if (kind === 'ok') {
      return C.green;
    }
    if (kind === 'err') {
      return C.red;
    }
    if (kind === 'warn') {
      return C.orange;
    }
    return C.cyan;
  }
}
