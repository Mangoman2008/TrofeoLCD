/**
 * ThemeDotii.ets —— 主题 5「Dotii 分页屏」（ESP32-S3 / LVGL 那套 UI 的移植）
 *
 * 来源（逐条照抄，不改设计）：
 *   ~/Documents/Dotii-368x448/main/state_ui.c        ← LVGL 主体（页面/状态栏/圆环/表情）
 *   ~/Documents/Dotii-368x448/components/.../bsp/display.h:22-23 ← 面板 368×448
 *   ~/Documents/Dotii-368x448/dotii-ui-sim.html      ← 网页仿真（**仅参考，多处与实机不一致**）
 *
 * ★ 以**实机 C 源码**为准。仿真页与实机已核对出的差异（勿照抄仿真页）：
 *   · 状态栏：实机 32px 高、y=416、底色 0x151A19，元素 x=6/20/224/276；
 *             仿真页是 24px / #0A0C0B / x=6/74/246/304
 *   · 状态栏只挂**余额页**（state_ui.c:2574），不是每页都挂
 *   · 圆点：只有余额页(y=403)与 Bambu 页(y=414)有；表情页与自定义页没有（1941/1652）
 *   · 圆环：实机 368×368 @y=40（圆心 184,224），描边中心线 r=171、宽 26
 *   · 表情部件运行时**统一 ×1.2**（set_dotii_part，1775-1782）；8 相位查表，无缓动
 *   · 自定义页实机**没有百分比**：是"我的页面/值/正文/页脚"或整帧图
 *
 * 移植规则（用户 2026-10-14 定）：源画布 368×448 → 等比 ×0.9333 → 343×418，屏幕居中，
 * 与主题 4「打砖块」同一块区域、同一个变换，屏上 origin ≈ (788, 22)。
 * 另：源固件**没有页面自动轮播**（只有表情 10s 一换）；本移植按用户要求让 4 页也 10s 轮播。
 */
import { Chrome } from './Chrome';
import { ThemeSnake, SnakeState } from './ThemeSnake';
/** 源画布与缩放 */
const kW: number = 368;
const kH: number = 448;
export const DOTII_SCALE: number = 0.9333;
export const DOTII_W: number = kW * DOTII_SCALE;   // 343.5
export const DOTII_H: number = kH * DOTII_SCALE;   // 418.1

export function dotiiX(): number {
  return Math.round((1920 - DOTII_W) / 2);
}
export function dotiiY(): number {
  return Math.round((462 - DOTII_H) / 2);
}

// ---------------------------------------------------------------------------
// 配色（state_ui.c:51-63 的 COLOR_* 宏）
// ★ ArkTS 不允许无类型对象字面量（arkts-no-untyped-obj-literals），写成显式类。
// ---------------------------------------------------------------------------
class DotiiColors {
  bg: string = '#000000';            // COLOR_BG
  surface: string = '#141A19';       // COLOR_SURFACE
  text: string = '#F1F8F5';          // COLOR_TEXT
  muted: string = '#8E9B97';         // COLOR_MUTED
  blue: string = '#5DA9FF';          // COLOR_BLUE
  cyan: string = '#20D6E6';          // COLOR_CYAN
  green: string = '#42D98C';         // COLOR_GREEN
  bambu: string = '#00AE42';         // COLOR_BAMBU
  warning: string = '#F2C66D';       // COLOR_WARNING
  danger: string = '#FF766F';        // COLOR_DANGER
  divider: string = '#38403E';       // 余额/Bambu 页中缝分隔线
  trackBambu: string = '#092A16';    // Bambu 环底
  trackCustom: string = '#2B2D28';   // 自定义环底
  dotOff: string = '#59605E';        // 未选圆点（也是环不可用色）
  statusBg: string = '#151A19';      // 底部状态栏底
  faceWarm: string = '#F4EAD2';      // 表情 warm
  faceAmber: string = '#F2C66D';     // 表情 amber
  faceCyan: string = '#58C8C8';      // 表情 cyan（源 0x55D8D0；JPEG 4:2:0 后偏灰，略降饱和）
  faceCoral: string = '#FF827A';     // 表情 coral
}
const CO: DotiiColors = new DotiiColors();
/** 页面圆点高亮色（state_ui.c:834：CYAN / BLUE / BAMBU / WARNING） */
const PAGE_COLORS: string[] = [CO.cyan, CO.blue, CO.bambu, CO.warning, '#00E070'];

/** 表情运行时放大系数（set_dotii_part：6/5，state_ui.c:1775-1782） */
const EXPR_GROW: number = 1.2;

export const DOTII_PAGES: number = 5;
/** 「贪吃蛇」页的下标（轮询里多出来的一页，逻辑移植自 ESP32-C3 bambu-zh） */
export const DOTII_SNAKE_PAGE: number = 4;
export const DOTII_PAGE_NAMES: string[] = ['表情', '余额', '打印机', '自定义', '贪吃蛇'];

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
export class DotiiState {
  page: number = 0;
  expr: number = 0;
  hour: number = 0;
  minute: number = 0;
  /** 余额页（源 s_balance 是"字符串原样显示"，state_ui.c:2342） */
  balanceTotal: string = '--';
  balanceGranted: string = '--';
  balanceTopped: string = '--';
  /** 胶囊状态机文案（state_ui.c:2244-2356）：可用/离线/未接入/预览数据/不可用/密钥无效/获取失败 */
  balanceStatus: string = '离线';
  balanceHasValue: boolean = false;
  /** Bambu 页 */
  prState: string = '';
  prPct: number = -1;
  prStatusText: string = '离线';
  prRemainText: string = '--';
  prFinishText: string = '--';
  prNozzle: number = -1;
  prBed: number = -1;
  prLayer: number = -1;
  prTotalLayer: number = -1;
  /** 底部状态栏（源只挂余额页） */
  wifiOn: boolean = false;
  wifiConnecting: boolean = false;
  connText: string = '';
  batt: number = -1;
  charging: boolean = false;
  /** 自定义页（源无百分比，是标题/值/正文/页脚四段文本） */
  customTitle: string = '我的页面';
  customValue: string = '';
  customBody: string = '';
  customFooter: string = '';
}

// ---------------------------------------------------------------------------
// 表情表（实机 render_dotii_expression，state_ui.c:1790-1902）
// 下表是**源码声明值**，渲染时统一 ×1.2
// ---------------------------------------------------------------------------
class Part {
  w: number = 0;
  h: number = 0;
  x: number = 0;
  y: number = 0;
  color: string = CO.faceWarm;
  opacity: number = 255;   // 0-255（源 LV_OPA_COVER=255 / 110）
}

export const DOTII_EXPR_NAMES: string[] = ['idle_breath', 'blink', 'curious', 'sleepy_yawn',
  'connecting', 'working', 'complete', 'failure'];

/**
 * 随机取一个**不同于当前**的表情下标。
 *
 * ★ 用户要求（2026-10-16）：表情要**随机**，不关联其他动作或结果。
 *   原来是 `(expr + 1) % 8` 顺序轮播，看着像"按顺序播一遍"。
 *
 * 放在这里而不是 LcdService：① 表情表的家在这里；
 * ② `SelfTest` 可直接 import 它做离线自检，不会形成
 *    SelfTest → LcdService → … 的循环依赖。
 *
 * 边界：表情只有 1 个时无法避开"与当前相同"，返回 0，不会死循环。
 */
export function randomExpr(cur: number): number {
  const n = DOTII_EXPR_NAMES.length;
  if (n <= 1) {
    return 0;
  }
  let v = cur;
  for (let i = 0; i < n; i++) {
    v = Math.floor(Math.random() * n) % n;
    if (v !== cur) {
      return v;
    }
  }
  // 兜底：错开一位，保证与本帧不同
  return (cur + 1) % n;
}
/** 表情时长（源按快照下发；非 800..10000ms 时回落 800，这里取同量级的一组） */
const EXPR_MS: number[] = [2600, 480, 1900, 2600, 1500, 1500, 2000, 1700];

function mk(w: number, h: number, x: number, y: number, c: string, opa: number): Part {
  const q = new Part();
  q.w = w;
  q.h = h;
  q.x = x;
  q.y = y;
  q.color = c;
  q.opacity = opa;
  return q;
}
function hidden(c: string): Part {
  return mk(0, 0, 0, 0, c, 0);
}

/** 5 个部件：左眼 / 右眼 / 嘴 / 左点 / 右点（后两个常兼作"中点"） */
function faceParts(expr: number, phase: number): Part[] {
  const p = phase < 4 ? phase : 8 - phase;                       // 乒乓
  const eyes = (w: number, h: number, x: number, y: number, c: string, opa: number): Part[] =>
    [mk(w, h, -x, y, c, opa), mk(w, h, x, y, c, opa)];

  switch (expr) {
    case 1: {   // BLINK：eye_h = 7（相位 2,3）/ 24（相位 1,4）/ 66（其余）
      const eh = (phase === 2 || phase === 3) ? 7 : ((phase === 1 || phase === 4) ? 24 : 66);
      return eyes(58, eh, 78, -26, CO.faceWarm, 255)
        .concat([mk(56, 12, 0, 70, CO.faceWarm, 255), hidden(CO.faceCyan), hidden(CO.faceCyan)]);
    }

    case 2:     // CURIOUS：一 eye 大一 eye 小 + 琥珀方嘴
      return [mk(62, 82, -76, -34, CO.faceWarm, 255), mk(46, 62, 82, -26, CO.faceWarm, 255),
        mk(20 + p, 20 + p, 8, 70, CO.faceAmber, 255), hidden(CO.faceCyan), hidden(CO.faceCyan)];

    case 3:     // SLEEPY_YAWN：眼挤成缝 + 琥珀嘴张开
      return eyes(68, 10, 76, -18, CO.faceWarm, 255)
        .concat([mk(26 + p * 3, 26 + p * 3, 0, 72, CO.faceAmber, 255),
          hidden(CO.faceCyan), hidden(CO.faceCyan)]);

    case 4: {   // CONNECTING：青色眼交叉淡入 + 中点横移
      const lo = phase < 4 ? 255 : 110;
      const ro = phase < 4 ? 110 : 255;
      return [mk(48, 64, -76, -28, CO.faceCyan, lo), mk(48, 64, 76, -28, CO.faceCyan, ro),
        mk(56, 12, 0, 70, CO.faceWarm, 255), hidden(CO.faceCyan),
        mk(10, 10, phase * 22 - 77, 88, CO.faceCyan, 255)];
    }

    case 5:     // WORKING：双眼同扫 + 青嘴 + 右点下落
      return [mk(48, 68, -86 + p * 4, -30, CO.faceWarm, 255), mk(48, 68, 70 + p * 4, -30, CO.faceWarm, 255),
        mk(62, 10, 0, 72, CO.faceCyan, 255), hidden(CO.faceCyan),
        mk(10, 10, 134, -82 + phase * 7, CO.faceCyan, 255)];

    case 6:     // COMPLETE：眯眼笑 + 宽琥珀嘴 + 左点琥珀/右点青
      return [mk(68, 14, -76, -28, CO.faceWarm, 255), mk(68, 14, 76, -28, CO.faceWarm, 255),
        mk(108 + p, 20 + Math.floor(p / 2), 0, 62, CO.faceAmber, 255),
        mk(10 + p, 10 + p, -132, -76, CO.faceAmber, 255),
        mk(10 + p, 10 + p, 132, -76, CO.faceCyan, 255)];

    case 7:     // FAILURE：扁平珊瑚眼 + 珊瑚嘴 + 珊瑚中点
      return [mk(58, 12, -76, -22, CO.faceCoral, 255), mk(58, 12, 76, -22, CO.faceCoral, 255),
        mk(72, 12, 0, 80 + Math.floor(p / 2), CO.faceCoral, 255), hidden(CO.faceCoral),
        mk(10 + p, 10 + p, 0, 52, CO.faceCoral, 255)];

    default:    // IDLE_BREATH：眼高呼吸（breath = p*2）+ 两个青点
      return eyes(52, 68 + p * 2, 78, -30, CO.faceWarm, 255)
        .concat([mk(56, 12, 0, 70, CO.faceWarm, 255),
          mk(12, 12, -132, 52, CO.faceCyan, 255), mk(12, 12, 132, 52, CO.faceCyan, 255)]);
  }
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------
export class ThemeDotii {
  static readonly NAME: string = 'Dotii 分页屏';
  static readonly PAGE_COUNT: number = DOTII_PAGES;

  /** 表情相位（源 phase = elapsed*8/duration，state_ui.c:1809-1810） */
  static exprPhase(nowMs: number, expr: number): number {
    const dur = EXPR_MS[expr % EXPR_MS.length];
    return Math.floor((nowMs % dur) * 8 / dur);
  }

  /**
   * 只渲染**页面内容**（不含整屏底色、不含 dotii 框的 translate/scale、不画漏光）。
   *
   * 供主题 9「打印机位 Dotii」把同一套内容搬到别的格子里复用 —— 调用方自己
   * save/translate/scale 到目标区域，再调这个函数。
   */
  static renderPages(ctx: CanvasRenderingContext2D, st: DotiiState, nowMs: number): void {
    const page = st.page % DOTII_PAGES;
    if (page === 0) {
      ThemeDotii.facePage(ctx, st, nowMs);      // 表情页：无圆点、无状态栏
    } else if (page === 1) {
      ThemeDotii.balancePage(ctx, st);          // 余额页：圆点(y=403) + 状态栏
      ThemeDotii.dots(ctx, 1);
      ThemeDotii.statusBar(ctx, st);
    } else if (page === 2) {
      ThemeDotii.bambuPage(ctx, st);            // Bambu 页：圆点(y=414)，无状态栏
      ThemeDotii.dots(ctx, 2);
    } else if (page === 3) {
      ThemeDotii.customPage(ctx, st);           // 自定义页：无圆点、无状态栏
    } else {
      ThemeDotii.snakePage(ctx, st, nowMs);     // 贪吃蛇页（移植自 ESP32-C3 的 c3 贪吃蛇）
      ThemeDotii.dots(ctx, DOTII_SNAKE_PAGE);
    }
  }

  static render(ctx: CanvasRenderingContext2D, st: DotiiState, nowMs: number,
                vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    const X = dotiiX();
    const Y = dotiiY();

    ctx.fillStyle = CO.bg;
    ctx.fillRect(0, 0, 1920, 462);
    ctx.fillRect(X, Y, DOTII_W, DOTII_H);

    ctx.save();
    ctx.translate(X, Y);
    ctx.scale(DOTII_SCALE, DOTII_SCALE);

    ThemeDotii.renderPages(ctx, st, nowMs);
    // ★ 注意顺序：必须先 restore() 再画漏光补偿。
    //   原来这一行写在 scale(0.9333)+translate 之内 → 补偿被缩到 0.9333 并平移到
    //   Dotii 框的角上，**物理右下角实际没被压到**（主题 4/6 都是在 restore 之后画的）。
    ctx.restore();
    // 右下角漏光补偿（全屏坐标系，压暗物理右下角那一块）
    Chrome.vignette(ctx, 1920, 462, vig, vigReach, vigCorner);
  }

  /**
   * 页 4：贪吃蛇（移植自 ESP32-C3 bambu-zh 的 snake_logic / snake_ui）。
   *
   * 与主题 16（全屏）和打印机格槽 6 共用 `ThemeSnake` 引擎，只是棋盘尺寸不同：
   * Dotii 内容区是 368×448 的竖版，所以用 **20×20** 的大棋盘（每格约 18px），
   * 与源实现的 20×20 网格一致。
   *
   * 状态用静态字段挂住 —— 翻到别的页再翻回来，这一局会**接着打**而不是重开。
   */
  private static snakeSt: SnakeState | null = null;

  static snakePage(ctx: CanvasRenderingContext2D, st: DotiiState, nowMs: number): void {
    if (ThemeDotii.snakeSt === null) {
      ThemeDotii.snakeSt = new SnakeState();
      ThemeSnake.reset(ThemeDotii.snakeSt, nowMs, 20, 20);
    }
    const g: SnakeState = ThemeDotii.snakeSt;
    ThemeSnake.step(g, nowMs);
    // ★ 直接传**整个内容区**，让 ThemeSnake 自己在里面等比居中。
    //   原来传的是"正好等于棋盘大小"的矩形 → draw() 里下方余白算出来是 0
    //   → 记分牌退回"压在棋盘底部"，结果蛇就画到记分牌上去了（实测踩到）。
    //   20×20 格在 368×448 里 → 每格 18.4px、棋盘 368×368、上下各留 40px 余白。
    ThemeSnake.draw(ctx, 0, 0, kW, kH, g, nowMs);
  }

  /** 供内容签名使用：贪吃蛇页当前步数（-1 = 还没开局） */
  static snakeTick(): number {
    return ThemeDotii.snakeSt === null ? -1 : ThemeDotii.snakeSt.tick;
  }

  // ---------------- 页 0：表情（state_ui.c:1926-1944 / 1790-1902）----------------
  static facePage(ctx: CanvasRenderingContext2D, st: DotiiState, nowMs: number): void {
    const expr = st.expr % DOTII_EXPR_NAMES.length;
    const phase = ThemeDotii.exprPhase(nowMs, expr);
    const parts = faceParts(expr, phase);
    const cx = kW / 2;
    const cy = kH / 2;
    for (const q of parts) {
      if (q.w <= 0 || q.h <= 0) {
        continue;
      }
      const w = q.w * EXPR_GROW;                       // 运行时统一 ×1.2
      const h = q.h * EXPR_GROW;
      const px = cx + q.x * EXPR_GROW - w / 2;
      const py = cy + q.y * EXPR_GROW - h / 2;
      ctx.globalAlpha = q.opacity / 255;
      ctx.fillStyle = q.color;
      ThemeDotii.pill(ctx, px, py, w, h, Math.min(w, h) / 2);   // LV_RADIUS_CIRCLE
      ctx.fill();
      ctx.globalAlpha = 1;
    }
  }

  // ---------------- 页 1：余额（state_ui.c:877-963 / 2244-2356）----------------
  static balancePage(ctx: CanvasRenderingContext2D, st: DotiiState): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    // 自上而下：标题 62 · 时钟 108 · 题注 158 · 大金额 208 · 状态胶囊 276 · 两块数值 344
    // （底部 416 起是状态栏，数值块题注到 ≈404 为止）
    ctx.fillStyle = CO.text;
    ctx.font = 'bold 48px sans-serif';
    ctx.fillText('DeepSeek', kW / 2, 62);
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText(ThemeDotii.hhmm(st), kW / 2, 108);

    // 题注只写"余额"（源是"余额 (元)"，本屏 40px 下括号会被大数字压住）
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 36px sans-serif';
    ctx.fillText('余额 (元)', kW / 2, 146);

    // 大金额（源 digits_64 ×1.102 ≈ 本屏 88px 视觉）
    ctx.fillStyle = st.balanceHasValue ? CO.text : CO.muted;
    ctx.font = 'bold 88px sans-serif';
    ctx.fillText(st.balanceTotal, kW / 2, 216);

    ThemeDotii.statusPill(ctx, 184, 276, 138, 48, st.balanceStatus, ThemeDotii.balanceColor(st));

    ctx.fillStyle = CO.divider;
    ctx.fillRect(183, 350, 1, 42);
    ThemeDotii.metric(ctx, 43, 344, 132, '赠送', st.balanceGranted);
    ThemeDotii.metric(ctx, 193, 344, 132, '充值', st.balanceTopped);
  }

  // ---------------- 页 2：Bambu（state_ui.c:1435-1594 / 2393-2443）----------------
  static bambuPage(ctx: CanvasRenderingContext2D, st: DotiiState): void {
    const live = st.prState === 'RUNNING' || st.prState === 'PAUSE' || st.prState === 'PREPARE';
    const pct = live && st.prPct >= 0 ? st.prPct : 0;
    // 环：圆心(184,224)、描边中心 r=171、宽 26、角度 140→400、实机**不圆头**
    ThemeDotii.arc(ctx, 184, 224, 171, 26, 140, 400, pct, CO.trackBambu,
      live ? CO.bambu : CO.dotOff, false);

    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = CO.text;
    ctx.font = 'bold 48px sans-serif';
    ctx.fillText('Bambu', kW / 2, 62);
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 32px sans-serif';
    ctx.fillText(ThemeDotii.hhmm(st), kW / 2, 108);

    ctx.font = 'bold 40px sans-serif';
    ctx.fillText('打印进度', kW / 2, 158);

    ctx.fillStyle = live ? CO.text : CO.muted;
    ctx.font = 'bold 96px sans-serif';
    ctx.fillText(live ? `${pct}%` : '--%', kW / 2, 228);

    // 三行温度/层数贴在环内大数字上方（源在详情页；此处合在一页好看全）
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 36px sans-serif';
    const rows = `喷嘴 ${ThemeDotii.temp(st.prNozzle)}   热床 ${ThemeDotii.temp(st.prBed)}   层 ${st.prLayer >= 0 ? st.prLayer : '--'}/${st.prTotalLayer > 0 ? st.prTotalLayer : '--'}`;
    ctx.fillText(rows, kW / 2, 298);

    ThemeDotii.statusPill(ctx, 184, 340, 138, 48, st.prStatusText, ThemeDotii.printerColor(st));

    ctx.fillStyle = CO.divider;
    ctx.fillRect(183, 388, 1, 48);
    ThemeDotii.metric(ctx, 43, 378, 132, '剩余', st.prRemainText);
    ThemeDotii.metric(ctx, 193, 378, 132, '完成', st.prFinishText);
  }

  // ---------------- 页 3：自定义（state_ui.c:1596-1654）----------------
  static customPage(ctx: CanvasRenderingContext2D, st: DotiiState): void {
    // 环：同几何，0→360，底 0x2B2D28，指示色缺省 warning（实机无百分比数字）
    ThemeDotii.arc(ctx, 184, 224, 171, 26, 0, 360, 100, CO.trackCustom, CO.warning, true);

    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText(st.customTitle, kW / 2, 70);          // TOP_MID y=54
    ctx.fillStyle = CO.warning;
    ctx.font = 'bold 42px sans-serif';
    ctx.fillText(st.customValue, kW / 2, 176);         // CENTER(0,-52)
    ctx.fillStyle = '#C6D0CC';
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText(st.customBody, kW / 2, 258);          // CENTER(0,32)
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText(st.customFooter, kW / 2, 372);        // BOTTOM_MID(-54)
    // 环外底部：移植说明（自加一行，便于一眼认出这是移植版）
    ctx.fillStyle = CO.dotOff;
    ctx.font = 'bold 30px sans-serif';
    // 页脚原本写「源：ESP32-S3 LVGL 368×448 · 等比移植」——用户要求删掉这类来源说明
    void kW;
  }

  // ---------------- 底部圆点（state_ui.c:831-875）----------------
  /** 只有余额页（row=1，y_ofs=−40）与 Bambu 页（row=2，y_ofs=−29）有圆点 */
  static dots(ctx: CanvasRenderingContext2D, row: number): void {
    const y = row === 1 ? (kH - 40 - 2.5) : (kH - 29 - 2.5);
    const gap = 8;
    // ★ 总宽按**页数**算，不能写死 4 页的 (16 + 3*5 + 3*8)。
    //   加了第 5 页（贪吃蛇）之后写死的公式会让整排点子右偏半个点。
    const small: number = 5;
    const totalW: number = 16 + (DOTII_PAGES - 1) * small + (DOTII_PAGES - 1) * gap;
    let x = kW / 2 - totalW / 2;
    for (let i = 0; i < DOTII_PAGES; i++) {
      const on = i === row;
      const w = on ? 16 : 5;
      ctx.fillStyle = on ? PAGE_COLORS[i] : CO.dotOff;
      ThemeDotii.pill(ctx, x, y, w, 5, on ? 3 : 2.5);
      ctx.fill();
      x += w + gap;
    }
  }

  // ---------------- 底部状态栏（state_ui.c:2543-2619；只挂余额页）----------------
  static statusBar(ctx: CanvasRenderingContext2D, st: DotiiState): void {
    const h = 32;
    const y = kH - h;                       // 416
    ctx.fillStyle = CO.statusBg;
    ctx.fillRect(0, y, kW, h);

    ctx.textBaseline = 'middle';
    // WiFi 圆点 10×10 @(6,11)（相对状态栏）
    ctx.fillStyle = st.wifiOn ? CO.green : (st.wifiConnecting ? CO.warning : CO.muted);
    ctx.beginPath();
    ctx.arc(6 + 5, y + 11 + 5, 5, 0, Math.PI * 2);
    ctx.fill();
    // 连接名 @(20,1) 宽 160、×1.25 视觉、循环滚动
    ctx.save();
    ctx.beginPath();
    ctx.rect(20, y, 160, h);
    ctx.clip();
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 28px sans-serif';
    const conn = st.connText.length > 0 ? st.connText : '未配置';
    const tw = ctx.measureText(conn).width;
    const span = tw + 40;
    const off = (Date.now() % 14000) / 14000 * span;
    ctx.fillText(conn, 20 - off, y + h / 2);
    if (span < 160 + tw) {
      ctx.fillText(conn, 20 - off + span, y + h / 2);
    }
    ctx.restore();
    // 电量 @(224,8)
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 30px sans-serif';
    const batt = st.batt >= 0 ? `${st.batt.toFixed(0)}%${st.charging ? '+' : ''}` : '--';
    ctx.font = 'bold 28px monospace';
    ctx.fillText(batt, 224, y + h / 2);
    // 时钟（源 @276，montserrat_16；本屏 28px 的 "14:26" 约 70px 宽，右对齐到 360 更稳）
    ctx.font = 'bold 28px monospace';
    ctx.fillText(ThemeDotii.hhmm(st), 360, y + h / 2);
  }

  // ---------------- 小部件 ----------------
  /** 状态胶囊：底色 = 状态色 20% 不透明，内含 14×14 圆点 + 描边 2px 的文字 */
  private static statusPill(ctx: CanvasRenderingContext2D, cx: number, cy: number,
                            w: number, h: number, text: string, color: string): void {
    // ★ 先量文字再定宽：源里胶囊是固定 138×48，但**中文状态词会超**
    //   （「监控未登录」≈190px、「密钥无效」≈152px），固定宽会让文字溢出胶囊。
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.font = 'bold 38px sans-serif';
    const textW = ctx.measureText(text).width;
    const dotR = 7;
    const gap = 10;
    const needW = textW + dotR * 2 + gap + 24;      // 24 = 左右内边距
    const pw = Math.max(w, needW);

    ctx.globalAlpha = 0.2;
    ctx.fillStyle = color;
    ThemeDotii.pill(ctx, cx - pw / 2, cy - h / 2, pw, h, h / 2);
    ctx.fill();
    ctx.globalAlpha = 1;

    const startX = cx - (dotR * 2 + gap + textW) / 2;
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.arc(startX + dotR, cy, dotR, 0, Math.PI * 2);
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = color;
    ctx.strokeText(text, startX + dotR * 2 + gap, cy);
    ctx.fillText(text, startX + dotR * 2 + gap, cy);
    ctx.textAlign = 'center';
  }

  /** 数值块 132×56：值在上、题注在下 */
  private static metric(ctx: CanvasRenderingContext2D, x: number, y: number,
                        w: number, label: string, value: string): void {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = CO.text;
    ctx.font = 'bold 40px sans-serif';
    ctx.fillText(value, x + w / 2, y + 8);
    ctx.fillStyle = CO.muted;
    ctx.font = 'bold 34px sans-serif';
    ctx.fillText(label, x + w / 2, y + 52);
  }

  private static pill(ctx: CanvasRenderingContext2D, x: number, y: number,
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

  /**
   * 圆环（源 make_usage_arc + ringSVG：底环 + 指示弧）。
   * LVGL 角度：0° = 3 点方向、顺时针；描边从外沿向内画，所以半径传**描边中心线**。
   */
  private static arc(ctx: CanvasRenderingContext2D, cx: number, cy: number, r: number,
                     w: number, a0: number, a1: number, pct: number,
                     trackColor: string, barColor: string, rounded: boolean): void {
    const toRad = (deg: number): number => deg * Math.PI / 180;
    const sweep = ((a1 - a0) % 360 + 360) % 360 || 360;
    ctx.lineWidth = w;
    ctx.lineCap = rounded ? 'round' : 'butt';
    ctx.beginPath();
    ctx.arc(cx, cy, r, toRad(a0), toRad(a0 + sweep));
    ctx.strokeStyle = trackColor;
    ctx.stroke();
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      ctx.beginPath();
      ctx.arc(cx, cy, r, toRad(a0), toRad(a0 + sweep * p / 100));
      ctx.strokeStyle = barColor;
      ctx.stroke();
    }
    ctx.lineCap = 'butt';
  }

  private static hhmm(st: DotiiState): string {
    const hh = (st.hour < 10 ? '0' : '') + st.hour;
    const mm = (st.minute < 10 ? '0' : '') + st.minute;
    return `${hh}:${mm}`;
  }

  private static temp(v: number): string {
    return v >= 0 ? `${v.toFixed(0)}°C` : '--';
  }

  /** 余额胶囊状态色（state_ui.c:2244-2356） */
  private static balanceColor(st: DotiiState): string {
    if (st.balanceStatus === '可用') {
      return CO.green;
    }
    if (st.balanceStatus === '不可用' || st.balanceStatus === '密钥无效'
      || st.balanceStatus === '获取失败') {
      return CO.danger;
    }
    if (st.balanceStatus === '预览数据') {
      return CO.warning;
    }
    return CO.muted;
  }

  /** Bambu 胶囊状态色（state_ui.c:2394-2396） */
  private static printerColor(st: DotiiState): string {
    if (st.prState === 'FAULT') {
      return CO.danger;
    }
    if (st.prState === 'PAUSE') {
      return CO.warning;
    }
    if (st.prState.length === 0 || st.prState === 'OFFLINE' || st.prState === 'UNKNOWN') {
      return CO.muted;
    }
    return CO.bambu;
  }
}
