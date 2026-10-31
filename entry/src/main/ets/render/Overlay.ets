/**
 * Overlay.ets —— 全屏覆盖层（彩蛋与新装饰件）
 *
 * 这些是"锦上添花"的视觉层：不参与内容签名判重（由调用方决定何时画），
 * 也不改变任何面板布局 —— 只在已有画面之上盖一层。
 *
 * 目前包含：
 *   · bsod()：错误复古蓝屏（Win95 风格）。正常时完全不出现。
 *
 * 画布坐标约定：**逻辑坐标 1920×462**（与 Chrome.vignette 一致）。
 */

export class Overlay {
  /**
   * 边框扫掠（光沿边框环绕）。
   *
   * 移植自本机 BambuHelper/ESP32 的 `display_edge_glow.cpp`（门户里那个「扫掠（光沿边框环绕）」）：
   *   · 周长坐标 q 从左上角开始顺时针，扫掠头像跑马灯一样绕周长一圈
   *   · **拖尾长度 = 周长 / 4**，亮度按**二次方**衰减（原注释：brightness fades
   *     quadratically over the tail）
   *   · 原面板 30fps，这边画布只有 ~3fps，所以一圈放慢到 9 秒，
   *     否则每帧头会跳 400+px，看着一格一格蹦
   *
   * 实现：把「拖尾区间」按四条边切成至多 8 段，每段用线性渐变描边
   * （渐变两端就是该段两端的衰减亮度），所以整条拖尾是连续平滑的，
   * 每帧只有 8~16 次 stroke，成本很低。
   */
  static sweepBorder(ctx: CanvasRenderingContext2D, w: number, h: number, nowMs: number,
                     lapMs: number = 9000, thickness: number = 5,
                     color: string = '120,235,255'): void {
    const perim: number = 2 * (w + h);
    const head: number = ((nowMs % lapMs) / lapMs) * perim;
    const tail: number = perim / 4;

    // 周长坐标 → 屏幕点
    const pt = (q: number): number[] => {
      let v: number = q % perim;
      if (v < 0) {
        v += perim;
      }
      if (v < w) {
        return [v, 0];                       // 上边：左→右
      }
      if (v < w + h) {
        return [w, v - w];                   // 右边：上→下
      }
      if (v < 2 * w + h) {
        return [w - (v - (w + h)), h];       // 下边：右→左
      }
      return [0, h - (v - (2 * w + h))];     // 左边：下→上
    };
    // 某点距扫掠头的距离（沿尾巴方向）
    const distOf = (q: number): number => {
      let d: number = head - q;
      while (d < 0) {
        d += perim;
      }
      return d;
    };
    // 二次方衰减
    const alphaOf = (q: number): number => {
      const d: number = distOf(q);
      if (d > tail) {
        return 0;
      }
      const k: number = 1 - d / tail;
      return k * k;
    };

    // 静态细边框（很淡）：扫掠过时读得出"这是一圈边"
    ctx.strokeStyle = `rgba(${color},0.10)`;
    ctx.lineWidth = 1.5;
    ctx.strokeRect(0.75, 0.75, w - 1.5, h - 1.5);

    // 拖尾区间：[head - tail, head]，可能跨 0 点 → 拆成两段
    const spans: number[][] = [];
    const start: number = head - tail;
    if (start >= 0) {
      spans.push([start, head]);
    } else {
      spans.push([0, head]);
      spans.push([start + perim, perim]);
    }
    // 每条边的区间（上、右、下、左）
    const sides: number[][] = [[0, w], [w, w + h], [w + h, 2 * w + h], [2 * w + h, perim]];

    for (let s = 0; s < sides.length; s++) {
      const s0: number = sides[s][0];
      const s1: number = sides[s][1];
      for (let i = 0; i < spans.length; i++) {
        const a: number = Math.max(s0, spans[i][0]);
        const b: number = Math.min(s1, spans[i][1]);
        if (b - a < 0.5) {
          continue;
        }
        const pa = pt(a);
        const pb = pt(b);
        const aa = alphaOf(a);
        const ab = alphaOf(b);
        if (aa <= 0.004 && ab <= 0.004) {
          continue;
        }
        // 外层晕光（更宽更淡）
        const g = ctx.createLinearGradient(pa[0], pa[1], pb[0], pb[1]);
        g.addColorStop(0, `rgba(${color},${(aa * 0.9).toFixed(3)})`);
        g.addColorStop(1, `rgba(${color},${(ab * 0.9).toFixed(3)})`);
        ctx.strokeStyle = g;
        ctx.lineCap = 'round';
        ctx.lineWidth = thickness * 2.6;
        ctx.globalAlpha = 0.28;
        ctx.beginPath();
        ctx.moveTo(pa[0], pa[1]);
        ctx.lineTo(pb[0], pb[1]);
        ctx.stroke();
        // 主体亮线
        ctx.strokeStyle = g;
        ctx.lineWidth = thickness;
        ctx.globalAlpha = 1;
        ctx.beginPath();
        ctx.moveTo(pa[0], pa[1]);
        ctx.lineTo(pb[0], pb[1]);
        ctx.stroke();
        // 内侧白芯（只在很靠近头的位置）
        if (aa > 0.55 || ab > 0.55) {
          ctx.strokeStyle = 'rgba(255,255,255,0.85)';
          ctx.lineWidth = Math.max(1.6, thickness * 0.42);
          ctx.beginPath();
          ctx.moveTo(pa[0], pa[1]);
          ctx.lineTo(pb[0], pb[1]);
          ctx.stroke();
        }
      }
    }
    ctx.globalAlpha = 1;

    // ---- 白热核心：只覆盖头部前 150px，比整条拖尾亮一档 ----
    const coreLen: number = 150;
    for (let s = 0; s < sides.length; s++) {
      const s0: number = sides[s][0];
      const s1: number = sides[s][1];
      for (let i = 0; i < spans.length; i++) {
        const a: number = Math.max(s0, spans[i][0], head - coreLen);
        const b: number = Math.min(s1, spans[i][1], head);
        if (b - a < 0.5) {
          continue;
        }
        const pa = pt(a);
        const pb = pt(b);
        const fade: number = (b - a) / coreLen;
        const g = ctx.createLinearGradient(pa[0], pa[1], pb[0], pb[1]);
        g.addColorStop(0, `rgba(255,255,255,${(0.10 * fade).toFixed(3)})`);
        g.addColorStop(1, 'rgba(255,255,255,0.95)');
        ctx.strokeStyle = g;
        ctx.lineCap = 'round';
        ctx.lineWidth = Math.max(2, thickness * 0.55);
        ctx.beginPath();
        ctx.moveTo(pa[0], pa[1]);
        ctx.lineTo(pb[0], pb[1]);
        ctx.stroke();
      }
    }

    // ---- 头部光斑：一个柔和的径向光点，低帧率下也能一眼看到头在哪 ----
    const hp = pt(head);
    const spark = ctx.createRadialGradient(hp[0], hp[1], 1, hp[0], hp[1], 46);
    spark.addColorStop(0, 'rgba(255,255,255,0.85)');
    spark.addColorStop(0.35, `rgba(${color},0.45)`);
    spark.addColorStop(1, `rgba(${color},0)`);
    ctx.fillStyle = spark;
    ctx.fillRect(hp[0] - 48, hp[1] - 48, 96, 96);
  }

  /** BSOD 配色（Win95 蓝屏原色） */
  /**
   * HSV(hue 0..360, s=1, v=1) → 'rgb(r,g,b)'。
   * 用于彩虹渐变（不依赖 hsl() 字符串支持）。
   */
  private static hsvToCss(hue: number, value: number = 1): string {
    const h: number = ((hue % 360) + 360) % 360;
    const c: number = 1;
    const x: number = c * (1 - Math.abs(((h / 60) % 2) - 1));
    let r: number = 0;
    let g2: number = 0;
    let b: number = 0;
    if (h < 60) {
      r = c; g2 = x; b = 0;
    } else if (h < 120) {
      r = x; g2 = c; b = 0;
    } else if (h < 180) {
      r = 0; g2 = c; b = x;
    } else if (h < 240) {
      r = 0; g2 = x; b = c;
    } else if (h < 300) {
      r = x; g2 = 0; b = c;
    } else {
      r = c; g2 = 0; b = x;
    }
    // v=1 → 直接放大到 0..255（略提亮到 0.62 区间以外的饱和色）
    // value 用来做"呼吸"：v<1 时整体变暗（保持色相不变）
    const vv: number = Math.max(0, Math.min(1, value));
    const R: number = Math.round(r * 255 * vv);
    const G: number = Math.round(g2 * 255 * vv);
    const B: number = Math.round(b * 255 * vv);
    return `rgb(${R},${G},${B})`;
  }

  /** 彩虹条每步推进的色相（度）。/set?ringdeg=N 调整，默认 24 */
  static ringStepDeg: number = 24;
  /** true=呼吸（默认，低帧率下观感最好） false=滚动 */
  static ringFxBreath: boolean = true;
  /** 一次呼吸的周期（毫秒）。用户 2026-10-20 定：**5800ms**（5.8 秒一呼一吸） */
  static ringBreathMs: number = 5800;
  /** 当前呼吸强度 0..1（只用于 /diag 观测） */
  static ringBreathValue: number = 0;

  private static readonly BG: string = '#0000AA';
  private static readonly FG: string = '#FFFFFF';
  private static readonly BAR: string = '#C0C0C0';

  /**
   * 复古蓝屏（Win95 / BSOD 风格）。
   *
   * 用途：agent 本轮出错时，盖一块"蓝屏"约几秒 —— 既是醒目的状态提示，
   * 也是给这块状态副屏加的彩蛋（用户 2026-10-19 点名要的「错误 → BSOD」）。
   *
   * @param ctx  画布
   * @param w    逻辑宽（1920）
   * @param h    逻辑高（462）
   * @param text 错误文本（来自 agent.errorText）
   * @param leftMs 还能显示多久（用于最后 600ms 轻微闪烁，像真的要重启）
   */
  static bsod(ctx: CanvasRenderingContext2D, w: number, h: number,
              text: string, leftMs: number): void {
    // 最后 600ms 闪两下，模拟"正在重启"
    if (leftMs < 600 && Math.floor(leftMs / 120) % 2 === 0) {
      return;
    }
    ctx.fillStyle = Overlay.BG;
    ctx.fillRect(0, 0, w, h);

    // 顶部标题条（灰底蓝字，Win95 的窗口标题栏质感）
    ctx.fillStyle = Overlay.BAR;
    ctx.fillRect(0, 0, w, 30);
    ctx.fillStyle = Overlay.BG;
    ctx.font = 'bold 19px monospace';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText(' TrofeoLCD ', 14, 16);

    // 正文
    ctx.fillStyle = Overlay.FG;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.font = 'bold 25px monospace';
    ctx.fillText('A fatal exception 0E has occurred at 0028:C0011E36.', 40, 62);
    ctx.fillText('The current session will be terminated.', 40, 94);

    // 错误正文（截断，避免长文本溢出）
    const shown = text.length > 96 ? `${text.substring(0, 96)}…` : text;
    ctx.font = '22px monospace';
    ctx.fillText(`*  ${shown}`, 40, 140);

    // 处置说明（我们不会真的重启，说明会自动恢复）
    ctx.font = '20px monospace';
    ctx.fillStyle = '#BFC3FF';
    ctx.fillText('*  Press any key to continue _', 40, 190);
    ctx.fillText('（本轮结束会自动恢复，不用管）', 40, 222);

    // 右下角技术细节区（聊胜于无的真实信息）
    ctx.fillStyle = '#8F94E8';
    ctx.font = '18px monospace';
    const sec = Math.max(0, Math.ceil(leftMs / 1000));
    ctx.fillText(`REBOOT IN ${sec}s`, w - 210, h - 34);
  }

  /**
   * 全宽跑马灯（新闻条）。
   *
   * 1920×462 这块屏的最大特点是**极宽极矮**（4.16:1）——
   * 社区主题大多针对 320×480 竖屏，用不上这个比例；但跑马灯正好吃满它的宽度。
   *
   * @param y       条带顶边（逻辑坐标）
   * @param h       条带高
   * @param text    滚动内容
   * @param offset  已滚动的像素（由调用方按时间算）
   */
  static ticker(ctx: CanvasRenderingContext2D, w: number, y: number, h: number,
                text: string, offset: number): void {
    // 底条：半透明深色 + 顶部 1px 高光，避免糊在面板上
    ctx.fillStyle = 'rgba(6, 8, 14, 0.82)';
    ctx.fillRect(0, y, w, h);
    ctx.fillStyle = 'rgba(80, 200, 255, 0.35)';
    ctx.fillRect(0, y, w, 1);

    ctx.save();
    ctx.beginPath();
    ctx.rect(0, y, w, h);
    ctx.clip();
    ctx.font = 'bold 22px monospace';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#7FD4FF';
    // 文本长度（用 measureText 拿宽度，做无缝循环）
    const tw = Math.max(1, ctx.measureText(text).width);
    // 起点从右缘进入，向左滚；滚完一遍接一遍（间距 120px）
    const span = tw + 120;
    let x = w - (offset % span);
    // 画两份，保证右侧始终有内容填满
    while (x < w + span) {
      ctx.fillText(text, x, y + h / 2);
      x += span;
    }
    ctx.restore();
  }

  /**
   * 一天时间轴：每 1 分钟一格，横向铺满整条屏。
   *
   * 这是 4.16:1 才好看的玩法 —— 1440 分钟铺 1920px，一格约 1.33px。
   * 颜色：干活=暖色，空闲=暗色，深夜窗口=深蓝。
   *
   * @param buckets 长度 1440 的数组：0=空闲, 1=忙碌（调用方维护）
   * @param nowMin  当前分钟（0..1439），用于画游标
   */
  static timeline(ctx: CanvasRenderingContext2D, w: number, y: number, h: number,
                  buckets: number[], nowMin: number, nightStart: number, nightEnd: number): void {
    ctx.fillStyle = 'rgba(6, 8, 14, 0.78)';
    ctx.fillRect(0, y, w, h);
    const n = buckets.length;
    if (n <= 0) {
      return;
    }
    const step = w / n;
    for (let i = 0; i < n; i++) {
      const inNight = nightStart !== nightEnd
        && ((nightStart < nightEnd) ? (i >= nightStart && i < nightEnd)
          : (i >= nightStart || i < nightEnd));
      const busy = buckets[i] > 0;
      // ★ 初版夜间底 #16233A 几乎与面板背景同色，整条带子"看不见"（实测）。
      //   提亮一档，让时间轴始终看得出来是一条时间线，而不是一块空地。
      ctx.fillStyle = busy ? '#FFB454' : (inNight ? '#26395C' : '#2C3444');
      // 忙碌时用整格高，空闲只画下半，形成"条形图"观感
      const bh = busy ? h - 4 : Math.max(6, h * 0.45);
      ctx.fillRect(i * step, y + (h - bh), Math.max(1, step + 0.5), bh);
    }
    // 当前时刻游标
    const cx = (nowMin / n) * w;
    ctx.fillStyle = '#7FD4FF';
    ctx.fillRect(cx, y, 2, h);
    // 每 6 小时一个刻度
    ctx.fillStyle = 'rgba(160, 180, 210, 0.35)';
    for (let hh = 0; hh <= 24; hh += 6) {
      const x = (hh / 24) * w;
      ctx.fillRect(x, y, 1, 4);
      ctx.fillRect(x, y + h - 4, 1, 4);
    }
  }

  /**
   * 伪频谱瀑布图（/set?spec=1）。
   *
   * 不解码音频（鸿蒙侧拿不到回环音频、也不该为装饰去申请录音权限），
   * 而是拿**真实业务指标**当驱动：token 速率 / CPU 占用。
   * 视觉上就是一条向左滚动的柱状瀑布 —— 极宽的屏正好铺得开。
   *
   * @param values 每根柱子的 0..1 强度（最新在**末尾**，即最右）
   */
  static spectrum(ctx: CanvasRenderingContext2D, w: number, y: number, h: number,
                  values: number[]): void {
    const n = values.length;
    if (n <= 0) {
      return;
    }
    ctx.fillStyle = 'rgba(4, 6, 10, 0.80)';
    ctx.fillRect(0, y, w, h);
    ctx.fillStyle = 'rgba(80, 200, 255, 0.28)';
    ctx.fillRect(0, y, w, 1);

    const step = w / n;
    const bw = Math.max(1, step * 0.72);
    for (let i = 0; i < n; i++) {
      const v = Math.max(0, Math.min(1, values[i]));
      if (v <= 0.001) {
        continue;
      }
      const bh = Math.max(1, h * v);
      const bx = i * step;
      // 高度分档上色：低=青、中=绿、高=黄/红（像真的频谱分析仪）
      ctx.fillStyle = v > 0.82 ? '#FF5C5C' : (v > 0.6 ? '#FFD24A' : (v > 0.34 ? '#5BE38C' : '#3FB6FF'));
      ctx.fillRect(bx, y + h - bh, bw, bh);
      // 顶部 1px 高光，让柱子看起来有峰值
      ctx.fillStyle = 'rgba(255,255,255,0.55)';
      ctx.fillRect(bx, y + h - bh, bw, 1);
    }
  }

  /**
   * 复古掌机滤镜（/set?retro=1）：扫描线 + 淡绿染色 + 轻微暗角。
   *
   * 为什么不做真·4 色调色板量化：需要逐像素读写（getImageData/PixelMap 往返），
   * 在 462 高、3fps 的帧预算里代价太大。扫描线+染色在视觉上已能给出"老屏幕"的感觉，
   * 且成本是几十次 fillRect。
   */
  static retro(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    // 淡绿染色（Game Boy 的橄榄绿调）
    // ★ 染色强度要克制：实测 0.11 会把「黄色警示圈」染成绿色，
    //   破坏语义色（绿=正常/黄=警告/红=危险）。这里回到 0.07，
    //   复古感主要靠**扫描线**来给（它对颜色的破坏小得多）。
    ctx.fillStyle = 'rgba(120, 255, 170, 0.07)';
    ctx.fillRect(0, 0, w, h);
    // 扫描线：每 3 行压暗 1 行
    ctx.fillStyle = 'rgba(0, 0, 0, 0.24)';
    for (let y = 0; y < h; y += 3) {
      ctx.fillRect(0, y, w, 1);
    }
    // 顶部/底部略压暗，模拟小屏可视角度
    const g = ctx.createLinearGradient(0, 0, 0, h);
    g.addColorStop(0, 'rgba(0,0,0,0.22)');
    g.addColorStop(0.18, 'rgba(0,0,0,0)');
    g.addColorStop(0.82, 'rgba(0,0,0,0)');
    g.addColorStop(1, 'rgba(0,0,0,0.22)');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, w, h);
  }

  /**
   * 整点彩虹跑马灯。
   *
   * 与普通跑马灯同一套滚动逻辑，区别是文字用**彩虹渐变**填充，且渐变的相位随时间移动
   * （所以颜色会像流动的虹光，而不是固定的七彩字）。
   *
   * @param offset 已滚动像素
   * @param nowMs  当前时间（驱动彩虹流动）
   */
  static rainbowTicker(ctx: CanvasRenderingContext2D, w: number, y: number, h: number,
                       text: string, offset: number, nowMs: number): void {
    // 深色底 + 顶部虹色高光
    ctx.fillStyle = 'rgba(4, 6, 12, 0.90)';
    ctx.fillRect(0, y, w, h);

    // ★ 必须用 rgb() 而不是 hsl()：实测 ArkTS 的 canvas 对 `hsl(...)` 支持不可靠
    //   （首版用 hsl 生成的渐变整块不可见，只留下深色底，抓帧才看出来）。
    //   这里自己把 HSV(h,1,1) 换算成 RGB 字符串。
    const g = ctx.createLinearGradient(0, 0, w, 0);
    const phase = (nowMs / 18) % 360;
    for (let i = 0; i <= 8; i++) {
      const hue = (phase + i * 45) % 360;
      g.addColorStop(i / 8, Overlay.hsvToCss(hue));
    }
    ctx.fillStyle = g;
    ctx.fillRect(0, y, w, 2);
    ctx.fillRect(0, y + h - 2, w, 2);

    ctx.save();
    ctx.beginPath();
    ctx.rect(0, y, w, h);
    ctx.clip();
    ctx.font = 'bold 24px monospace';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = g;
    const tw = Math.max(1, ctx.measureText(text).width);
    const span = tw + 120;
    let x = w - (offset % span);
    while (x < w + span) {
      ctx.fillText(text, x, y + h / 2);
      x += span;
    }
    ctx.restore();
  }

  /**
   * 纯彩虹带：沿屏幕四边走一整圈、颜色绕环流动（**不画文字**）。
   *
   * 用户 2026-10-20 定稿：不要滚动文字，只要一条彩虹色带在转；带子加粗一倍、速度更快。
   *
   * 实现要点：
   *   · 走**环带中心线**的闭合矩形（上/右/下/左首尾相接），四角自然转 90°；
   *   · 每条边用一个线性渐变上色，色相按**弧长**推进（绕一圈过 K 个完整彩虹），
   *     再叠加 `nowMs` 相位 → 颜色沿环流动；
   *   · 渐变端点色严格按弧长算，所以四条边在角上的颜色是**接得上**的。
   *
   * @param band 环带宽度（像素）
   */
  static rainbowRing(ctx: CanvasRenderingContext2D, w: number, h: number, band: number,
                     nowMs: number): void {
    const W: number = w;
    const H: number = h;
    const lenH: number = W - band;      // 水平边长度
    const lenV: number = H - band;      // 垂直边长度
    const P: number = 2 * lenH + 2 * lenV;
    if (P <= 0) {
      return;
    }
    /** 绕一圈经过几个完整彩虹 */
    const K: number = 720;

    // ── 呼吸模式：彩虹**静止不动**，只让整体亮度缓慢起伏 ──
    //   ★ 这是低帧率下的正解：3.5fps 时"滚动"每帧要跳一大段（看着像闪），
    //     而呼吸是 3.6 秒一个周期 → 每个周期有 ~12 帧采样，肉眼读得出平滑明暗。
    if (Overlay.ringFxBreath) {
      const period: number = Overlay.ringBreathMs;
      const ph: number = (nowMs % period) / period;
      // 0..1 的余弦呼吸：0=最暗、1=最亮，两端自动缓入缓出
      const breath: number = 0.5 - 0.5 * Math.cos(ph * Math.PI * 2);
      Overlay.ringBreathValue = breath;
      const v: number = 0.40 + 0.60 * breath;      // 亮度 40% ↔ 100%
      // 色相也很慢地漂一点（0.06°/ms ≈ 3.4°/s），让呼吸不至于太死板
      const drift: number = (nowMs * 0.006) % 360;
      const hueAtB = (s: number): number => {
        return ((s / P) * K + drift) % 360;
      };
      const makeGradB = (x0: number, y0: number, x1: number, y1: number,
                         s0: number, s1: number): CanvasGradient => {
        const g: CanvasGradient = ctx.createLinearGradient(x0, y0, x1, y1);
        const stops: number = 12;
        for (let i = 0; i <= stops; i++) {
          const t: number = i / stops;
          g.addColorStop(t, Overlay.hsvToCss(hueAtB(s0 + (s1 - s0) * t), v));
        }
        return g;
      };
      ctx.fillStyle = makeGradB(band / 2, 0, W - band / 2, 0, 0, lenH);
      ctx.fillRect(0, 0, W, band);
      ctx.fillStyle = makeGradB(W - band / 2, band / 2, W - band / 2, H - band / 2,
        lenH, lenH + lenV);
      ctx.fillRect(W - band, band, band, H - band * 2);
      ctx.fillStyle = makeGradB(W - band / 2, H - band / 2, band / 2, H - band / 2,
        lenH + lenV, 2 * lenH + lenV);
      ctx.fillRect(0, H - band, W, band);
      ctx.fillStyle = makeGradB(band / 2, H - band / 2, band / 2, band / 2,
        2 * lenH + lenV, P);
      ctx.fillRect(0, band, band, H - band * 2);
      return;
    }

    /**
     * ★ 相位必须**按帧率对齐**成定步长（用户反馈"只是闪，不是滚动"）。
     *
     * 原因：这块屏实测只有 ~3.5fps（每帧约 285ms，瓶颈是 JPEG 编码 + USB 推送）。
     * 原来用连续速度 0.30 度/ms → **每帧跳 85°**，而一个彩虹周期才 360°，
     * 于是相邻两帧的颜色几乎全换了 → 眼睛看到的是"闪"，不是"流"。
     *
     * 改成：每 STEP_MS 秒推进 STEP_DEG 度。
     *   STEP_DEG=24° / STEP_MS=300ms ≈ 80°/秒 → 绕完一整圈(720°)约 9 秒，
     *   每帧只挪 24°（约一个彩虹周期的 1/15）→ 连续追帧就像在"推着走"。
     * 用 /set?ringdeg=N 调每步度数（4..120，越小越慢越顺）。
     */
    const STEP_MS: number = 300;
    const stepDeg: number = Overlay.ringStepDeg;
    const steps: number = Math.floor(nowMs / STEP_MS);
    const phaseDeg: number = (steps * stepDeg) % 360;

    // 弧长 s → 色相。四条边的渐变端点都用这个算，保证角上接得上。
    const hueAt = (s: number): number => {
      return ((s / P) * K + phaseDeg) % 360;
    };

    // 给一条边生成"沿边方向"的彩虹渐变
    const makeGrad = (x0: number, y0: number, x1: number, y1: number,
                      s0: number, s1: number): CanvasGradient => {
      const g: CanvasGradient = ctx.createLinearGradient(x0, y0, x1, y1);
      const stops: number = 12;
      for (let i = 0; i <= stops; i++) {
        const t: number = i / stops;
        g.addColorStop(t, Overlay.hsvToCss(hueAt(s0 + (s1 - s0) * t)));
      }
      return g;
    };

    // 上边：s ∈ [0, lenH)
    ctx.fillStyle = makeGrad(band / 2, 0, W - band / 2, 0, 0, lenH);
    ctx.fillRect(0, 0, W, band);
    // 右边：s ∈ [lenH, lenH+lenV)
    ctx.fillStyle = makeGrad(W - band / 2, band / 2, W - band / 2, H - band / 2,
      lenH, lenH + lenV);
    ctx.fillRect(W - band, band, band, H - band * 2);
    // 下边：s ∈ [lenH+lenV, 2lenH+lenV)，方向从右到左
    ctx.fillStyle = makeGrad(W - band / 2, H - band / 2, band / 2, H - band / 2,
      lenH + lenV, 2 * lenH + lenV);
    ctx.fillRect(0, H - band, W, band);
    // 左边：s ∈ [2lenH+lenV, P)，方向从下到上
    ctx.fillStyle = makeGrad(band / 2, H - band / 2, band / 2, band / 2,
      2 * lenH + lenV, P);
    ctx.fillRect(0, band, band, H - band * 2);
  }
}
