/**
 * ThemeMaid.ets — 主题 0「看板娘」：Q 版蓝发小女仆（2026-11-02 用户要求）
 *
 * 用户要求：第一个主题「用量」格子里找个地方画一个二次元角色，最好能动、
 * 不占整格（原话："在用量那一格子找地方放，你可以不搞那么大的"）。
 * 参考形象：Q 版蓝发小女孩，经典黑白女仆装 + 白色荷叶边头饰，大眼睛圆脸，
 * 双手捧小托盘，乖巧站姿，日系插画风，干净背景、柔和光影、细节精致。
 *
 * 落点（2026-11-02 定稿）：「用量」面板内部右上空区（TOKEN 数字右侧、
 * 余额横线上方，约 118×132）—— renderSmall() 半身小版：头 + 肩 + 捧托盘
 * （茶杯热气）+ 星星，同一套 canonical 坐标等比缩放裁剪。
 * 整格版 render()（头到脚 + 面板外壳）保留未接线，将来想让她站满一格再用。
 *
 * 动画全部时间驱动（nowMs），对低帧率友好（有效 ~3-4fps 也顺眼）：
 *   · 呼吸浮动    周期 2400ms、幅度 ±2.6px（头部 ×1.35，像在轻轻呼吸）
 *   · 眨眼        周期 3600ms、合眼 480ms —— 低帧率下也保证捕到闭眼帧
 *   · 偶尔笑弯眼  9s 周期里的前 1.5s（^ ^ 眼 + 更大的笑 + 腮红更红）
 *   · 头发风场    微风主相位 ~2.6s（全头同向）+ 每束涟漪 ~1.75s（两侧异相）；
 *                 发梢摆幅大于中段且相位滞后 → 波从发根传到发梢的飘逸甩尾感
 *   · 呆毛两根    随风甩 + 弹跳；托盘上茶杯冒热气（两缕交错升腾）
 *   · 星星闪      头侧两颗四角星轮流亮起
 * Q 版加强（2026-11-02 二轮，用户反馈"头发不够飘逸、不够 Q"）：
 *   · 头部整体放大 1.15 倍（scaleHead 锚在脖颈 (cx,198)：下巴不动，头往上方/两侧
 *     长大、脖子视觉变短）→ 头身比 ~1:1.5 的正宗 Q 版
 *   · 眼睛放大加粗（白眼球 12.5×14.5、睫毛 5px、瞳孔 5.2），腮红加大加圆
 *   · 长发重画：每侧两束波状长裙发（外深内亮分层），发梢尖收
 * 帧率配套在 LcdService：
 *   · contentSignature 带 `maid=`（250ms 量化相位）→ 不会被"内容未变则跳过"冻住
 *   · syncPongInterval 用 MAID_FPS_MS=220 提 tick 频率（不必像打砖块 66ms 那么急）
 */
import { C, F } from '../common/Theme';
import { Chrome } from './Chrome';

/** 女仆配色（局部小色板：只服务这一个模块，不动全局 C） */
class MaidKit {
  static readonly pink: string = '#F48FB1';
  static readonly skin: string = '#FFE3CB';
  static readonly skinShade: string = '#FFDFC4';
  static readonly lash: string = '#20243A';
  static readonly hair: string = '#4E7CE4';
  static readonly hairHi: string = '#6B98F0';
  static readonly hairDeep: string = '#446FCF';
  static readonly dress: string = '#2C324A';
  static readonly dressDark: string = '#20253A';
  static readonly sleeve: string = '#313850';
  static readonly white: string = '#F4F7FC';
  static readonly whiteDim: string = '#E4EAF4';
  static readonly eyeTop: string = '#63A1FF';
  static readonly eyeBot: string = '#2C5BD9';
  static readonly pupil: string = '#142F7A';
  static readonly mouth: string = '#BE5A62';
}

export class ThemeMaid {
  static readonly NAME: string = '看板娘';

  /** 动画相位量化步长（250ms，与天气主题 wxq= 同粒度）—— 进内容签名用 */
  static animTick(nowMs: number): number {
    return Math.floor(nowMs / 250);
  }

  static render(ctx: CanvasRenderingContext2D, x: number, y: number,
                w: number, h: number, nowMs: number): void {
    ctx.save();
    ctx.translate(x, y);
    const cx = w / 2;

    ThemeMaid.panelChrome(ctx, w, h);

    // 身后一层很淡的暖粉光晕（"干净背景 + 柔和光影"）
    const glow = ctx.createRadialGradient(cx, 236, 10, cx, 236, 152);
    glow.addColorStop(0, 'rgba(255,205,220,0.10)');
    glow.addColorStop(1, 'rgba(255,205,220,0)');
    ctx.fillStyle = glow;
    ctx.fillRect(0, 46, w, h - 46);

    const bob = Math.sin(nowMs / 2400 * Math.PI * 2) * 2.6;

    ThemeMaid.groundShadow(ctx, cx, bob);
    ThemeMaid.legs(ctx, cx);

    // 身体组：随呼吸整体浮动
    ctx.save();
    ctx.translate(0, bob);
    ThemeMaid.backHair(ctx, cx, nowMs);
    ThemeMaid.body(ctx, cx, nowMs);
    ctx.restore();

    // 头部组：浮动 ×1.35（呼吸感）+ Q 版放大 1.15（锚在脖颈）
    ctx.save();
    ctx.translate(0, bob * 1.35);
    ThemeMaid.scaleHead(ctx, cx);
    ThemeMaid.head(ctx, cx, nowMs);
    ctx.restore();

    ThemeMaid.sparkles(ctx, cx, nowMs);
    ctx.restore();
  }

  /**
   * 半身小版（2026-11-02 用户改需求）：不占整格 —— 在「用量」面板右上空区画
   * Q 版半身小女仆：头 + 肩 + 捧托盘（茶杯热气）+ 星星，动画与整格版完全同源。
   *
   * canonical 半身区（沿用整格版的坐标，274 宽画布、cx=137）：
   *   宽 发梢最远 cx±83 = 166；高 呆毛顶（约 30，含呼吸/弹跳余量）到托盘底(284) = 258。
   * 按区域等比缩放（k = min(w/166, h/258)），底边对齐区域底、水平居中，
   * 裁剪矩形封边（呼吸浮动溢出的 1-2px 平切肉眼不可见）。
   */
  static renderSmall(ctx: CanvasRenderingContext2D, x: number, y: number,
                     w: number, h: number, nowMs: number): void {
    ctx.save();
    ctx.beginPath();
    ctx.rect(x, y, w, h);
    ctx.clip();
    const k = Math.min(w / 166, h / 258);
    ctx.translate(x + w / 2, y + h);
    ctx.scale(k, k);
    // 映射到整格版 canonical 坐标系：cx=137、半身底 y=284
    ctx.translate(-137, -284);

    // 身后一层很淡的暖粉光晕（同整格版，收窄到半身范围）
    const glow = ctx.createRadialGradient(137, 200, 8, 137, 200, 118);
    glow.addColorStop(0, 'rgba(255,205,220,0.10)');
    glow.addColorStop(1, 'rgba(255,205,220,0)');
    ctx.fillStyle = glow;
    ctx.fillRect(55, 30, 164, 254);

    const bob = Math.sin(nowMs / 2400 * Math.PI * 2) * 2.6;

    // 身体组：随呼吸整体浮动
    ctx.save();
    ctx.translate(0, bob);
    ThemeMaid.backHair(ctx, 137, nowMs);
    ThemeMaid.body(ctx, 137, nowMs);
    ctx.restore();

    // 头部组：浮动 ×1.35（呼吸感）+ Q 版放大 1.15（锚在脖颈）
    ctx.save();
    ctx.translate(0, bob * 1.35);
    ThemeMaid.scaleHead(ctx, 137);
    ThemeMaid.head(ctx, 137, nowMs);
    ctx.restore();

    ThemeMaid.sparkles(ctx, 137, nowMs);
    ctx.restore();
  }

  /** 面板外壳：与其它格同款（C.panel 底 + C.border 边 + 居中标题胶囊），胶囊用粉色 */
  private static panelChrome(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    ctx.fillStyle = C.panel;
    Chrome.roundRect(ctx, 0, 0, w, h, 14);
    ctx.fill();
    ctx.strokeStyle = C.border;
    ctx.lineWidth = 1;
    Chrome.roundRect(ctx, 0.5, 0.5, w - 1, h - 1, 14);
    ctx.stroke();

    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.font = F.font(19, 'bold');
    const title = '看板娘';
    const titleW = ctx.measureText(title).width;
    const pillH = 30;
    const pillW = titleW + 26;
    const pillX = (w - pillW) / 2;
    const pillY = 16;
    ctx.globalAlpha = 0.18;
    ctx.fillStyle = MaidKit.pink;
    Chrome.roundRect(ctx, pillX, pillY, pillW, pillH, pillH / 2);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.strokeStyle = MaidKit.pink;
    ctx.lineWidth = 2;
    Chrome.roundRect(ctx, pillX + 1, pillY + 1, pillW - 2, pillH - 2, (pillH - 2) / 2);
    ctx.stroke();
    ctx.fillStyle = MaidKit.pink;
    ctx.fillText(title, pillX + 13, pillY + pillH / 2 + 1);
  }

  /** 地面软阴影：她浮起来时影子微微变浅变小 */
  private static groundShadow(ctx: CanvasRenderingContext2D, cx: number, bob: number): void {
    const lift = bob / 2.6;   // -1..1
    ctx.fillStyle = 'rgba(0,0,0,0.32)';
    ctx.beginPath();
    ctx.ellipse(cx, 414, 54 - lift * 4, 9 - lift * 0.8, 0, 0, Math.PI * 2);
    ctx.fill();
  }

  /** 腿：白丝袜 + 玛丽珍鞋（脚跟着地，不随呼吸浮动） */
  private static legs(ctx: CanvasRenderingContext2D, cx: number): void {
    ctx.fillStyle = MaidKit.white;
    Chrome.roundRect(ctx, cx - 30, 286, 17, 106, 8);
    ctx.fill();
    Chrome.roundRect(ctx, cx + 13, 286, 17, 106, 8);
    ctx.fill();
    ctx.fillStyle = MaidKit.lash;
    Chrome.roundRect(ctx, cx - 33, 391, 30, 22, 10);
    ctx.fill();
    Chrome.roundRect(ctx, cx + 3, 391, 30, 22, 10);
    ctx.fill();
    // 鞋扣小亮点
    ctx.fillStyle = 'rgba(255,255,255,0.35)';
    ctx.beginPath();
    ctx.arc(cx - 18, 397, 2, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(cx + 18, 397, 2, 0, Math.PI * 2);
    ctx.fill();
  }

  /** 头部 Q 版放大：以脖颈 (cx,198) 为锚放大 1.15 —— 下巴不动，头往上方/两侧长大 */
  private static scaleHead(ctx: CanvasRenderingContext2D, cx: number): void {
    ctx.translate(cx, 198);
    ctx.scale(1.15, 1.15);
    ctx.translate(-cx, -198);
  }

  /** 微风主相位（~2.6s 一轮）：全头共用 → 整头头发随风同向摆 */
  private static wind(nowMs: number): number {
    return Math.sin(nowMs / 2600 * Math.PI * 2);
  }

  /** 每束发自己的小涟漪（~1.75s，phase 错开 → 两侧/各束不同步，更自然） */
  private static ripple(nowMs: number, phase: number): number {
    return Math.sin(nowMs / 1750 * Math.PI * 2 + phase);
  }

  /** 后发：底色圆 + 每侧两束波状长裙发（外深内亮分层）。
   *  飘逸的关键：发梢摆幅 > 中段、且相位滞后（波从发根往发梢传）；
   *  微风（全头同向）+ 涟漪（两侧异相）叠加，任何时刻两侧发形都不同。 */
  private static backHair(ctx: CanvasRenderingContext2D, cx: number, nowMs: number): void {
    ctx.fillStyle = MaidKit.hairDeep;
    ctx.beginPath();
    ctx.arc(cx, 150, 74, 0, Math.PI * 2);
    ctx.fill();
    const w = ThemeMaid.wind(nowMs);
    for (let i = 0; i < 2; i++) {
      const dir = i === 0 ? -1 : 1;
      const rl = ThemeMaid.ripple(nowMs, i * 1.9);
      const swM = w * 3 + rl * 2;       // 中段摆
      const swT = w * 5 + rl * 3.5;     // 发梢摆（幅度更大）
      const vy = rl * 2.2;              // 发梢上下飘
      // 外层深色长束（发梢尖收）
      ctx.fillStyle = MaidKit.hairDeep;
      ctx.beginPath();
      ctx.moveTo(cx + dir * 42, 110);
      ctx.quadraticCurveTo(cx + dir * 80, 148, cx + dir * (76 + swM), 200);
      ctx.quadraticCurveTo(cx + dir * (72 + swT), 238, cx + dir * (60 + swT), 260 + vy);
      ctx.quadraticCurveTo(cx + dir * (68 + swT), 220, cx + dir * (56 + swM), 168);
      ctx.quadraticCurveTo(cx + dir * 44, 134, cx + dir * 28, 116);
      ctx.closePath();
      ctx.fill();
      // 内层亮色束（叠出层次）
      ctx.fillStyle = MaidKit.hair;
      ctx.beginPath();
      ctx.moveTo(cx + dir * 36, 122);
      ctx.quadraticCurveTo(cx + dir * 66, 156, cx + dir * (62 + swM), 196);
      ctx.quadraticCurveTo(cx + dir * (57 + swT), 226, cx + dir * (47 + swT), 244 + vy);
      ctx.quadraticCurveTo(cx + dir * (55 + swT), 210, cx + dir * (46 + swM * 0.7), 162);
      ctx.quadraticCurveTo(cx + dir * 38, 138, cx + dir * 26, 126);
      ctx.closePath();
      ctx.fill();
    }
  }

  /** 躯干：女仆裙（黑白）+ 围裙 + 领结 + 泡泡袖 + 捧托盘的手 */
  private static body(ctx: CanvasRenderingContext2D, cx: number, nowMs: number): void {
    // 脖子
    ctx.fillStyle = MaidKit.skinShade;
    ctx.fillRect(cx - 9, 196, 18, 26);

    // 裙上身（肩 → 腰，左亮右暗的柔和光）
    const dg = ctx.createLinearGradient(cx - 37, 0, cx + 37, 0);
    dg.addColorStop(0, MaidKit.dress);
    dg.addColorStop(1, MaidKit.dressDark);
    ctx.fillStyle = dg;
    ctx.beginPath();
    ctx.moveTo(cx - 37, 218);
    ctx.quadraticCurveTo(cx - 20, 212, cx + 20, 212);
    ctx.quadraticCurveTo(cx + 36, 214, cx + 37, 220);
    ctx.quadraticCurveTo(cx + 35, 240, cx + 30, 254);
    ctx.lineTo(cx - 30, 254);
    ctx.quadraticCurveTo(cx - 35, 240, cx - 37, 218);
    ctx.closePath();
    ctx.fill();

    // A 字裙摆
    const sg = ctx.createLinearGradient(0, 252, 0, 300);
    sg.addColorStop(0, MaidKit.dress);
    sg.addColorStop(1, MaidKit.dressDark);
    ctx.fillStyle = sg;
    ctx.beginPath();
    ctx.moveTo(cx - 30, 252);
    ctx.quadraticCurveTo(cx - 40, 278, cx - 58, 298);
    ctx.lineTo(cx + 58, 298);
    ctx.quadraticCurveTo(cx + 40, 278, cx + 30, 252);
    ctx.closePath();
    ctx.fill();

    // 腰后蝴蝶结（露在腰两侧的小白翼）
    ctx.fillStyle = MaidKit.whiteDim;
    ctx.beginPath();
    ctx.moveTo(cx - 30, 250);
    ctx.lineTo(cx - 40, 257);
    ctx.lineTo(cx - 31, 265);
    ctx.closePath();
    ctx.fill();
    ctx.beginPath();
    ctx.moveTo(cx + 30, 250);
    ctx.lineTo(cx + 40, 257);
    ctx.lineTo(cx + 31, 265);
    ctx.closePath();
    ctx.fill();

    // 围裙：胸兜 + 裙片（底部荷叶边）
    const ag = ctx.createLinearGradient(cx - 47, 0, cx + 47, 0);
    ag.addColorStop(0, MaidKit.white);
    ag.addColorStop(1, MaidKit.whiteDim);
    ctx.fillStyle = ag;
    Chrome.roundRect(ctx, cx - 19, 222, 38, 31, 6);
    ctx.fill();
    ctx.beginPath();
    ctx.moveTo(cx - 24, 251);
    ctx.lineTo(cx - 46, 288);
    ctx.lineTo(cx + 46, 288);
    ctx.lineTo(cx + 24, 251);
    ctx.closePath();
    ctx.fill();
    for (let i = 0; i < 6; i++) {
      ctx.beginPath();
      ctx.arc(cx - 45 + i * 18, 288, 9, 0, Math.PI);
      ctx.fill();
    }

    // 裙摆底边的白荷叶边
    ctx.fillStyle = MaidKit.white;
    for (let i = 0; i < 7; i++) {
      ctx.beginPath();
      ctx.arc(cx - 54 + i * 18, 298, 8.5, 0, Math.PI);
      ctx.fill();
    }

    // 领口白荷叶边 + 粉色领结
    ctx.fillStyle = MaidKit.white;
    ctx.beginPath();
    ctx.ellipse(cx, 213, 25, 9, 0, 0, Math.PI * 2);
    ctx.fill();
    for (let i = 0; i < 5; i++) {
      const edge = i === 0 || i === 4;
      ctx.beginPath();
      ctx.arc(cx - 16 + i * 8, edge ? 218.5 : 220, 4.5, 0, Math.PI);
      ctx.fill();
    }
    ctx.fillStyle = MaidKit.pink;
    ctx.beginPath();
    ctx.moveTo(cx - 3, 219);
    ctx.lineTo(cx - 13, 213);
    ctx.lineTo(cx - 12, 226);
    ctx.closePath();
    ctx.fill();
    ctx.beginPath();
    ctx.moveTo(cx + 3, 219);
    ctx.lineTo(cx + 13, 213);
    ctx.lineTo(cx + 12, 226);
    ctx.closePath();
    ctx.fill();
    ctx.beginPath();
    ctx.arc(cx, 219, 3.6, 0, Math.PI * 2);
    ctx.fill();

    // 泡泡袖（深色比裙身亮半档，白荷叶袖口）
    ctx.fillStyle = MaidKit.sleeve;
    ctx.beginPath();
    ctx.ellipse(cx - 40, 230, 15, 13, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.ellipse(cx + 40, 230, 15, 13, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = MaidKit.white;
    for (let i = 0; i < 3; i++) {
      const off = -9 + i * 9;
      ctx.beginPath();
      ctx.arc(cx - 40 + off, 240, 4.8, 0, Math.PI);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(cx + 40 + off, 240, 4.8, 0, Math.PI);
      ctx.fill();
    }

    // 双臂（捧托盘）：袖口弯到托盘沿
    ctx.strokeStyle = MaidKit.skinShade;
    ctx.lineWidth = 9;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(cx - 41, 238);
    ctx.quadraticCurveTo(cx - 47, 254, cx - 40, 263);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(cx + 41, 238);
    ctx.quadraticCurveTo(cx + 47, 254, cx + 40, 263);
    ctx.stroke();

    // 托盘（银灰椭圆，上亮下暗两层）
    ctx.fillStyle = '#8F97AB';
    ctx.beginPath();
    ctx.ellipse(cx, 272.5, 45, 10.5, 0, 0, Math.PI * 2);
    ctx.fill();
    const tg = ctx.createLinearGradient(0, 262, 0, 276);
    tg.addColorStop(0, '#D9DEE9');
    tg.addColorStop(1, '#B4BCCD');
    ctx.fillStyle = tg;
    ctx.beginPath();
    ctx.ellipse(cx, 267, 45, 10.5, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = 'rgba(255,255,255,0.5)';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.ellipse(cx, 267, 43, 9.6, 0, Math.PI, Math.PI * 2);
    ctx.stroke();

    // 茶杯：碟 + 杯身 + 把手 + 杯沿茶面
    ctx.fillStyle = '#E9EDF5';
    ctx.beginPath();
    ctx.ellipse(cx, 259, 16, 4.5, 0, 0, Math.PI * 2);
    ctx.fill();
    const cg = ctx.createLinearGradient(0, 238, 0, 258);
    cg.addColorStop(0, '#F8FAFD');
    cg.addColorStop(1, '#DCE2EF');
    ctx.fillStyle = cg;
    ctx.beginPath();
    ctx.moveTo(cx - 10.5, 238);
    ctx.lineTo(cx - 8.5, 257);
    ctx.quadraticCurveTo(cx, 260.5, cx + 8.5, 257);
    ctx.lineTo(cx + 10.5, 238);
    ctx.closePath();
    ctx.fill();
    ctx.strokeStyle = '#EDF1F8';
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.arc(cx + 12.5, 246, 5.5, -Math.PI * 0.45, Math.PI * 0.45);
    ctx.stroke();
    ctx.fillStyle = '#C9D2E4';
    ctx.beginPath();
    ctx.ellipse(cx, 238, 10.5, 3.4, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = '#C89B6A';
    ctx.beginPath();
    ctx.ellipse(cx, 238.3, 8, 2.5, 0, 0, Math.PI * 2);
    ctx.fill();

    // 热气：两缕交错升腾（相位错开半轮，任何时刻都有气在冒）
    for (let i = 0; i < 2; i++) {
      const p = ((nowMs / 1700) + i * 0.5) % 1;
      const sy = 230 - p * 26;
      const sx = cx + (i === 0 ? -5 : 6) + Math.sin(p * Math.PI * 2 + i * 2) * 3;
      const a = Math.sin(p * Math.PI) * 0.5;
      ctx.fillStyle = '#FFFFFF';
      ctx.globalAlpha = a;
      ctx.beginPath();
      ctx.arc(sx, sy, 3.2, 0, Math.PI * 2);
      ctx.fill();
      ctx.globalAlpha = a * 0.7;
      ctx.beginPath();
      ctx.arc(sx + 1.5, sy - 6, 2.4, 0, Math.PI * 2);
      ctx.fill();
      ctx.globalAlpha = a * 0.4;
      ctx.beginPath();
      ctx.arc(sx + 3, sy - 11, 1.7, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;

    // 双手压在托盘沿上（捧的姿态）
    ctx.fillStyle = MaidKit.skinShade;
    ctx.beginPath();
    ctx.arc(cx - 40, 266.5, 6.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(cx + 40, 266.5, 6.5, 0, Math.PI * 2);
    ctx.fill();
  }

  /** 头：脸 + 五官 + 刘海/侧发/头饰/呆毛（侧发在刘海下层、眉毛透出刘海）。
   *  内部是 canonical 坐标；调用方先 scaleHead() 放大 1.15 再进来。 */
  private static head(ctx: CanvasRenderingContext2D, cx: number,
                      nowMs: number): void {
    // 脸 + 下巴淡影
    ctx.fillStyle = MaidKit.skin;
    ctx.beginPath();
    ctx.arc(cx, 150, 58, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = 'rgba(235,170,135,0.18)';
    ctx.beginPath();
    ctx.ellipse(cx, 198, 27, 9, 0, 0, Math.PI * 2);
    ctx.fill();

    // 侧发（两束垂在脸侧的波状发束，风场驱动、发梢甩动；发根藏在刘海/头饰下）
    const hw = ThemeMaid.wind(nowMs);
    ctx.fillStyle = MaidKit.hair;
    for (let i = 0; i < 2; i++) {
      const dir = i === 0 ? -1 : 1;
      const rl = ThemeMaid.ripple(nowMs, i * 1.9 + 0.6);
      const swM = hw * 2 + rl * 1.5;
      const swT = hw * 4 + rl * 2.5;
      ctx.beginPath();
      ctx.moveTo(cx + dir * 48, 112);
      ctx.quadraticCurveTo(cx + dir * 74, 136, cx + dir * (70 + swM * 0.5), 168);
      ctx.quadraticCurveTo(cx + dir * (66 + swM), 196, cx + dir * (56 + swT), 220);
      ctx.quadraticCurveTo(cx + dir * (52 + swM), 192, cx + dir * 50, 162);
      ctx.quadraticCurveTo(cx + dir * 44, 134, cx + dir * 34, 116);
      ctx.closePath();
      ctx.fill();
    }

    // 刘海：外缘贴着头弧、内缘三束圆齿盖住额头（齿隙避开放大后的眼睛）
    const bg2 = ctx.createLinearGradient(0, 86, 0, 152);
    bg2.addColorStop(0, MaidKit.hairHi);
    bg2.addColorStop(1, MaidKit.hair);
    ctx.fillStyle = bg2;
    ctx.beginPath();
    ctx.moveTo(cx - 60, 128);
    ctx.arc(cx, 150, 64, Math.PI * 1.112, Math.PI * 1.888);
    ctx.quadraticCurveTo(cx + 56, 132, cx + 48, 144);
    ctx.quadraticCurveTo(cx + 36, 134, cx + 20, 126);
    ctx.quadraticCurveTo(cx + 12, 136, cx, 148);
    ctx.quadraticCurveTo(cx - 12, 136, cx - 20, 126);
    ctx.quadraticCurveTo(cx - 36, 134, cx - 48, 144);
    ctx.quadraticCurveTo(cx - 56, 132, cx - 60, 128);
    ctx.closePath();
    ctx.fill();
    // 发丝高光（左上弧形光带）
    ctx.strokeStyle = 'rgba(255,255,255,0.25)';
    ctx.lineWidth = 5;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.arc(cx, 150, 57, Math.PI * 1.26, Math.PI * 1.54);
    ctx.stroke();

    // 女仆头饰：白色荷叶边发带（骑在头顶）+ 三粒褶皱圆
    ctx.fillStyle = MaidKit.white;
    ctx.beginPath();
    ctx.arc(cx, 150, 71, Math.PI * 1.25, Math.PI * 1.75);
    ctx.arc(cx, 150, 60, Math.PI * 1.75, Math.PI * 1.25, true);
    ctx.closePath();
    ctx.fill();
    ctx.strokeStyle = 'rgba(150,160,190,0.35)';
    ctx.lineWidth = 1;
    ctx.stroke();
    for (let i = 0; i < 3; i++) {
      const fa = Math.PI * (1.33 + i * 0.17);
      ctx.beginPath();
      ctx.arc(cx + Math.cos(fa) * 71, 150 + Math.sin(fa) * 71, 5.5, 0, Math.PI * 2);
      ctx.fill();
    }

    // 呆毛（两根：主毛随风甩 + 副毛小卷，Q 感担当）
    const bnc = ThemeMaid.ripple(nowMs, 0.3) * 1.5;
    ctx.strokeStyle = MaidKit.hairHi;
    ctx.lineWidth = 5;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(cx + 2, 92);
    ctx.quadraticCurveTo(cx + 8, 68, cx + 18 + hw * 4, 56 + bnc);
    ctx.quadraticCurveTo(cx + 12 + hw * 5, 66, cx + 10, 82);
    ctx.stroke();
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.moveTo(cx - 8, 94);
    ctx.quadraticCurveTo(cx - 12, 78, cx - 20 + hw * 3, 70 + bnc * 0.8);
    ctx.stroke();

    // 眨眼相位：3600ms 一轮，合(140) → 闭(200) → 睁(140)
    const bt = nowMs % 3600;
    let blink = 0;
    if (bt < 140) {
      blink = bt / 140;
    } else if (bt < 340) {
      blink = 1;
    } else if (bt < 480) {
      blink = 1 - (bt - 340) / 140;
    }
    // 偶尔笑弯眼：9s 周期里的前 1.5s
    const happy = (nowMs % 9000) < 1500;

    // 腮红（笑的时候更红一点；加大加圆更 Q）
    ctx.fillStyle = happy ? 'rgba(255,120,145,0.45)' : 'rgba(255,120,145,0.30)';
    ctx.beginPath();
    ctx.ellipse(cx - 39, 168, 10, 6, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.ellipse(cx + 39, 168, 10, 6, 0, 0, Math.PI * 2);
    ctx.fill();

    ThemeMaid.eye(ctx, cx - 25, 150, blink, happy);
    ThemeMaid.eye(ctx, cx + 25, 150, blink, happy);

    // 眉毛（画在刘海之上——透出刘海的萌系画法）
    ctx.strokeStyle = 'rgba(58,92,184,0.75)';
    ctx.lineWidth = 2.6;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.arc(cx - 25, 138, 9, Math.PI * 1.15, Math.PI * 1.85);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(cx + 25, 138, 9, Math.PI * 1.15, Math.PI * 1.85);
    ctx.stroke();

    // 鼻子（小点）
    ctx.fillStyle = 'rgba(214,140,110,0.8)';
    ctx.beginPath();
    ctx.arc(cx, 163, 1.5, 0, Math.PI * 2);
    ctx.fill();

    // 嘴：平时小开怀笑，开心时笑得更开（露一点牙）
    ctx.fillStyle = MaidKit.mouth;
    ctx.beginPath();
    if (happy) {
      ctx.arc(cx, 168, 8.5, Math.PI * 0.08, Math.PI * 0.92);
      ctx.closePath();
      ctx.fill();
      ctx.fillStyle = 'rgba(255,255,255,0.9)';
      ctx.fillRect(cx - 6, 167, 12, 2.4);
    } else {
      ctx.arc(cx, 168, 5.5, Math.PI * 0.12, Math.PI * 0.88);
      ctx.closePath();
      ctx.fill();
    }
  }

  /** 大眼睛：白色眼底 + 蓝渐变虹膜（配蓝发）+ 双高光 + 粗上睫毛；
   *  眨眼用"上眼睑下压"表现半闭，笑的时候换成 ^ ^ 弯月眼。
   *  二轮加大：白眼球 12.5×14.5、虹膜 10.8、瞳孔 5.2、睫毛 5px —— Q 版水灵大眼 */
  private static eye(ctx: CanvasRenderingContext2D, ex: number, ey: number,
                     blink: number, happy: boolean): void {
    if (happy) {
      ctx.strokeStyle = MaidKit.lash;
      ctx.lineWidth = 4.5;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(ex - 11, ey + 3);
      ctx.quadraticCurveTo(ex, ey - 8, ex + 11, ey + 3);
      ctx.stroke();
      return;
    }
    if (blink >= 0.99) {
      // 完全闭眼：下弯睫毛线
      ctx.strokeStyle = MaidKit.lash;
      ctx.lineWidth = 4;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(ex - 11, ey + 1);
      ctx.quadraticCurveTo(ex, ey + 6, ex + 11, ey + 1);
      ctx.stroke();
      return;
    }
    // 白眼球
    ctx.fillStyle = '#FCFDFF';
    ctx.beginPath();
    ctx.ellipse(ex, ey, 12.5, 14.5, 0, 0, Math.PI * 2);
    ctx.fill();
    // 虹膜（纵向渐变）
    const ig = ctx.createLinearGradient(0, ey - 10, 0, ey + 12);
    ig.addColorStop(0, MaidKit.eyeTop);
    ig.addColorStop(1, MaidKit.eyeBot);
    ctx.fillStyle = ig;
    ctx.beginPath();
    ctx.arc(ex, ey + 1.5, 10.8, 0, Math.PI * 2);
    ctx.fill();
    // 瞳孔
    ctx.fillStyle = MaidKit.pupil;
    ctx.beginPath();
    ctx.arc(ex, ey + 2, 5.2, 0, Math.PI * 2);
    ctx.fill();
    // 高光：大（左上）+ 小（右下）
    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath();
    ctx.arc(ex - 4, ey - 3.5, 3.8, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 0.85;
    ctx.beginPath();
    ctx.arc(ex + 4, ey + 5, 1.9, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
    // 下睑淡线
    ctx.strokeStyle = 'rgba(32,36,58,0.30)';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(ex, ey + 6.5, 10.2, Math.PI * 0.15, Math.PI * 0.85);
    ctx.stroke();
    if (blink > 0.02) {
      // 半闭：肤色上眼睑往下压（clip 在眼眶里），眼睑线跟着下移
      ctx.save();
      ctx.beginPath();
      ctx.ellipse(ex, ey, 13.5, 15.5, 0, 0, Math.PI * 2);
      ctx.clip();
      const lidY = ey - 14.5 + blink * 21.5;
      ctx.fillStyle = MaidKit.skin;
      ctx.fillRect(ex - 14, ey - 16, 28, lidY - ey + 16);
      ctx.strokeStyle = MaidKit.lash;
      ctx.lineWidth = 3.2;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(ex - 12, lidY);
      ctx.quadraticCurveTo(ex, lidY + 2.5, ex + 12, lidY);
      ctx.stroke();
      ctx.restore();
    } else {
      // 睁眼：上睫毛主笔
      ctx.strokeStyle = MaidKit.lash;
      ctx.lineWidth = 5;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.arc(ex, ey - 0.5, 12.6, Math.PI * 1.08, Math.PI * 1.92);
      ctx.stroke();
    }
  }

  /** 头侧两颗四角星轮流亮起（治愈系点缀；位置避开加宽后的头发轮廓） */
  private static sparkles(ctx: CanvasRenderingContext2D, cx: number, nowMs: number): void {
    const ph = Math.sin(nowMs / 3600 * Math.PI * 2);
    ThemeMaid.star(ctx, cx + 86, 110, 7, ph);
    ThemeMaid.star(ctx, cx - 82, 172, 5, -ph);
  }

  private static star(ctx: CanvasRenderingContext2D, sx: number, sy: number,
                      r: number, a: number): void {
    if (a <= 0.05) {
      return;
    }
    ctx.globalAlpha = a * 0.85;
    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath();
    ctx.moveTo(sx, sy - r);
    ctx.quadraticCurveTo(sx + r * 0.22, sy - r * 0.22, sx + r, sy);
    ctx.quadraticCurveTo(sx + r * 0.22, sy + r * 0.22, sx, sy + r);
    ctx.quadraticCurveTo(sx - r * 0.22, sy + r * 0.22, sx - r, sy);
    ctx.quadraticCurveTo(sx - r * 0.22, sy - r * 0.22, sx, sy - r);
    ctx.closePath();
    ctx.fill();
    ctx.globalAlpha = 1;
  }
}
