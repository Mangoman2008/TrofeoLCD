/**
 * Dashboard.ets — 1920x462 仪表盘渲染
 *
 * 布局（5 列网格，列宽 370，间距 10，边距 14）：
 *   [0] 系统监控   [1-3] DSH 会话状态（三倍宽主面板）   [4] 用量 + 时钟
 */
// 全部是类型：必须 import type，否则 Node 类型剥离后会当成值导入而报错
import type { Telemetry, TodoItem, SystemInfo, TokenInfo, AgentInfo, PrinterInfo, PrinterTray, LyricsInfo, BalanceInfo } from '../common/Types';
import type { RenderExtras } from '../common/Extras';
import { Chrome } from './Chrome';
import { DotiiState, ThemeDotii, DOTII_EXPR_NAMES } from './ThemeDotii';
import { ThemeDotiiCell } from './ThemeDotiiCell';
import { ThemePong, PongState, pongInit, pongAdvance } from './ThemePong';
import { ThemeSnake, SnakeState } from './ThemeSnake';
import { MarioDemo } from '../mario/MarioDemo';
import { USAGE_X as DOTII_USAGE_X, USAGE_W as DOTII_USAGE_W, DSH_W as DOTII_DSH_W,
  CELL_W as DOTII_CELL_W, CELL_X as DOTII_CELL_X,
  V4_USAGE_X, V4_USAGE_W, V4_DSH_W,
  FINAL_VM_X, FINAL_VM_W, FINAL_USAGE_X, FINAL_USAGE_W, FINAL_DSH_W } from './ThemeDotiiCell';
import { FocusTimer } from '../common/Toasts';
import { C, L, V, F, P } from '../common/Theme';
import type { image } from '@kit.ImageKit';

export class FrameStats {
  usbOpen: boolean = false;
  usbLabel: string = '未连接';
  deviceInfo: string = '';
  bridgeAge: number = -1;
  sent: number = 0;
  errors: number = 0;
  fps: number = 0;
  jpegSize: number = 0;
  jpegW: number = 0;
  jpegH: number = 0;
  /** 分阶段耗时（EMA 平滑，毫秒）：定位瓶颈用 */
  renderMs: number = 0;
  encodeMs: number = 0;
  pushMs: number = 0;
  /** 本帧实际使用的 JPEG 质量（降质后 < 0.9） */
  quality: number = 0;
  /** 因内容未变化而跳过的帧数（省下编码+推送） */
  skippedFrames: number = 0;
  /** 诊断：帧循环被回调的次数（最小化后不再涨 = 事件循环被冻结） */
  tickCount: number = 0;
  /** 一轮 tick 自身耗时（EMA）；与 tickGapMs 一起定位"帧率上不去"卡在哪 */
  tickMs: number = 0;
  /** 两轮 tick 之间的实际间隔（含定时器被阻塞的时间） */
  tickGapMs: number = 0;
  /**
   * 渲染抛异常的次数。异常被 LcdService 的 try/finally 兜住（只坏这一帧、
   * 且保证 ctx.restore() 一定执行），这里计数便于发现"某个主题在悄悄抛异常"。
   */
  renderErrors: number = 0;
}

const W = L.width;
const H = L.height;

export class Dashboard {
  /**
   * 面板分配档位：
   *   0 = 标准（SYSTEM | DSH 会话 | [USAGE] | 打印机 | VM）
   *   1 = 打印机格让给别的用途（主题 9「打印机位 Dotii」）——
   *       宽度取 ThemeDotiiCell.CELL_W，缺口从 DSH 会话格扣，USAGE 整个不画。
   * 由 LcdService 在渲染前按主题设置。
   */
  static cellLayout: number = 0;

  /**
   * 打印机格「表情」槽要显示的表情下标，由 LcdService 每帧写入。
   *
   * 为什么用静态字段而不是给 printerPanel 加参数：printerPanel 已经 6 个参数，
   * 而本文件已有同类先例（cellLayout / dbgLastTheme 都是静态状态）。
   * LcdService 在 Dashboard.render **之前**调用 prepareDotiiState，所以这里读到的
   * 是当帧的值。
   */
  static dotiiFaceExpr: number = 0;

  /**
   * 打印机格「打砖块」槽（槽 5）的游戏状态。
   * ★ 独立于主题 4 的 pongState —— 若共用，切主题会把格子里的球复位，反之亦然。
   *   物理与画法仍共用同一套（pongAdvance / ThemePong.drawGame），只是状态各一份。
   */
  static cellPong: PongState | null = null;
  private static cellPongMs: number = 0;
  /** 槽 6 的自走贪吃蛇状态（懒初始化；这块屏无输入，蛇自己玩） */
  static cellSnake: SnakeState | null = null;
  /**
   * VM 面板没画面时播放的「超级玛丽演示版」（移植自本机 ~/WorkBuddy/SuperMario）。
   * 自动驾驶：一路向右 + 定时跳。开关见 marioEnabled。
   */
  static mario: MarioDemo = new MarioDemo();
  /** /set?mario=0 可关掉（默认开） */
  static marioEnabled: boolean = true;

  /**
   * 打印机格「表情」槽（PRINTER_SLOTS 的槽 3/4）。
   *
   * 复用主题 5 的 facePage —— 那里已有 8 个表情的几何与时长表（固件 state_ui.c 移植），
   * 不重新抄一套。落位用 ThemeDotiiCell.layout（与「打印机位 Dotii」同一个函数），
   * 避免两处各算一套缩放/居中而漂移。
   *
   * 已知取舍：facePage 是给 368×448 整屏设计的，而格子只有 274 宽
   * → 脸缩到约 0.62×（交接单说的 0.86 是按 343.5 宽估的，274 格子放不下）。
   * 表情本身就是大色块，缩小后仍清晰。
   */
  private static faceSlot(ctx: CanvasRenderingContext2D, x: number, y: number,
                          w: number, h: number, nowMs: number, slot: number): void {
    const lay: number[] = ThemeDotiiCell.layout(x, y, w, h);
    const innerX: number = lay[0];
    const innerY: number = lay[1];
    const k: number = lay[2];
    ctx.save();
    ctx.translate(innerX, innerY);
    ctx.scale(k, k);
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, 368, 448);
    const st: DotiiState = new DotiiState();
    // ★ 两个表情槽要显示**不同**的脸（审计 H4）：原来槽 3/4 都用同一个
    //   dotiiFaceExpr，10 秒的第二段是纯重复。这里按槽位错开半个表（8 个表情 → 偏移 4）。
    const n = DOTII_EXPR_NAMES.length;
    st.expr = n > 0 ? (Dashboard.dotiiFaceExpr + (slot === 4 ? Math.floor(n / 2) : 0)) % n : 0;
    ThemeDotii.facePage(ctx, st, nowMs);
    ctx.restore();
  }

  /**
   * 打印机格「打砖块」槽（槽 5，30 秒 = 3 × 10s 槽）。
   *
   * 复刻源固件 clock_pong（用户要求：**照搬源常数、保持 5 行 9 列**）——
   * 不碰任何物理常数，只用 ThemePong.drawGame 把同一套画法画到格子里。
   *
   * 尺寸：源游戏区 343×418（kScale 0.9333）；格子只有 274 宽 → 再套一个 fit
   * 等比缩到格内（≈0.74×），几何比例一点没变，只是整体变小。
   * ★ 不做「非等比压扁」——那会把球压成椭圆、砖块变形。
   *
   * 状态独立于主题 4（见 cellPong 注释）；离槽不重置，回来接着打。
   */
  /**
   * 槽 6：自走贪吃蛇。
   * 这块屏是输出-only 的，所以蛇由 ThemeSnake 的贪心+洪泛安全检查自己走。
   */
  private static snakeSlot(ctx: CanvasRenderingContext2D, x: number, y: number,
                           w: number, h: number, nowMs: number): void {
    if (Dashboard.cellSnake === null) {
      Dashboard.cellSnake = new SnakeState();
      ThemeSnake.reset(Dashboard.cellSnake, nowMs);
    }
    const st: SnakeState = Dashboard.cellSnake;
    ThemeSnake.step(st, nowMs);
    ThemeSnake.draw(ctx, x, y, w, h, st, nowMs);
  }

  private static pongSlot(ctx: CanvasRenderingContext2D, x: number, y: number,
                         w: number, h: number, nowMs: number): void {
    if (Dashboard.cellPong === null) {
      Dashboard.cellPong = pongInit(nowMs);
      Dashboard.cellPongMs = nowMs;
    }
    const st: PongState = Dashboard.cellPong;
    const dt = Dashboard.cellPongMs > 0 ? (nowMs - Dashboard.cellPongMs) : 0;
    Dashboard.cellPongMs = nowMs;
    // ★ 必须每帧喂时钟（修 bug：格内打砖块恒显 00:00）
    //   原实现只给**主题 4** 的 pongState 赋了 hour/minute（LcdService 里那条），
    //   而打印机格用的是独立的 Dashboard.cellPong，没人赋值 → 永远 0 点 0 分。
    const dn = new Date();
    st.hour = dn.getHours();
    st.minute = dn.getMinutes();
    pongAdvance(st, dt);

    // 源游戏区尺寸（与 ThemePong 侧一致：368×448 × 0.9333）
    const gw = 368 * 0.9333;
    const gh = 448 * 0.9333;
    const fit = Math.min(1, w / gw);
    const ax = x + (w - gw * fit) / 2;
    const ay = y + (h - gh * fit) / 2;
    // is24h 传 true：格子内空间有限，24 小时制更短，不易挤出
    ThemePong.drawGame(ctx, st, true, ax, ay, 0.9333 * fit);
  }


  /**
   * 本帧实际用到的版式坐标（调试用，暴露到 /diag）。
   * 起因：主题 9 里我设的 USAGE 落点没生效（屏上仍在原位），光读代码看不出
   * 运行时到底走了哪条分支 —— 直接把 render() 里算出来的值记下来最省事。
   */
  static dbgUsX: number = -1;
  static dbgUsW: number = -1;
  static dbgAgentW: number = -1;
  static dbgCellMode: number = -1;
  /**
   * 排障探针：**最后一次真正被调用的主题号**。
   * 起因：实测 `theme=15`（diag 读到）但屏上画的是主题 0，且 `renderMs` 仅 2.8ms
   * （主题 15 不可能这么快）→ 说明调度没走到预期分支。此字段让 diag 直接暴露"哪条分支在画"。
   */
  static dbgLastTheme: number = -1;
  /** 打印机格是否正画着 Dotii（档位 2） */
  static dbgDotiiInPrinter: number = -1;
  /** VM 画面适配的中间量（排障用）：源图宽高、可用区、最终绘制框 */
  static dbgVmSrcW: number = -1;
  static dbgVmSrcH: number = -1;
  static dbgVmInnerW: number = -1;
  static dbgVmInnerH: number = -1;
  static dbgVmDrawW: number = -1;
  static dbgVmDrawH: number = -1;

  /**
   * @param cellLayoutOverride 面板分配档位：
   *   0 = 标准（SYSTEM | DSH会话 | USAGE | 打印机 | VM）
   *   1 = 打印机格整体让给 Dotii，**缺口从 DSH 会话借、USAGE 加宽左移**（主题 9 用）
   *   2 = 打印机格画 Dotii，**其余面板保持标准版式**（主题 0 开"打印机格显示 Dotii"时用）。
   *   3 = 对调档：第四格 = VM、第五格 = **Dotii**（只换这两格内容，其它面板不动）。
   *   4 = **13:29 那一版**：Dotii 留第四格、VM 留第五格；USAGE 右移到 Dotii 左边贴住、
   *       DSH 会话吃掉中间空白（412.6）。
   *       这档不动 DSH/USAGE，代价是 Dotii 可用宽度只有等宽档的 274.4，会自动等比缩小。
   *   ★ 必须**显式传参**，不能依赖静态字段：实测给 `Dashboard.cellLayout` 赋值后，
   *   渲染侧读到的仍是 0 —— 打包后 Dashboard 模块存在多份实例，静态字段不跨副本共享。
   *   起初我把档位做成静态字段，运行时自证（diag 暴露 dbgCellMode）才抓到这个问题。
   */
  static render(ctx: CanvasRenderingContext2D, t: Telemetry, fs: FrameStats,
                vm: image.PixelMap | null = null, vmAgeMs: number = -1,
                vmErr: string = '', vertical: boolean = false,
                ex: RenderExtras | null = null,
                cellLayoutOverride: number = -1): void {
    if (ex !== null && ex.bg !== null) {
      // 自定义背景图：压暗后铺满，保证前景文字依旧清楚
      ctx.drawImage(ex.bg, 0, 0, L.width, L.height);
      ctx.fillStyle = 'rgba(3,6,12,0.62)';
      ctx.fillRect(0, 0, L.width, L.height);
    }
    if (vertical) {
      // ★ 竖装分支**不支持档位**（cellLayoutOverride 在这里被忽略，2026-10-31 注明，
      //   原审查中-20）：档位几何全按横装 1920×462 写死。调用方（LcdService）已在
      //   竖装下停掉"打印机格画 Dotii"（dotiiInPrinter 加了 !verticalMode 护栏），
      //   主题 9 也有 HORIZONTAL_ONLY 竖装回落，这里无需再处理档位。
      Dashboard.renderVertical(ctx, t, fs, vm, vmAgeMs, vmErr);
      return;
    }
    Dashboard.background(ctx);

    const pw = L.panelWidth;
    const ph = L.panelHeight;
    const py = L.panelY;

    // 面板 0：系统
    Dashboard.systemPanel(ctx, L.panelX(0), py, pw, ph, t.system);

    // 打印机格让位档（主题 9）：DSH 会话格被扣窄，USAGE 不画，打印机格由主题自己画
    const cellLay = cellLayoutOverride >= 0 ? cellLayoutOverride : Dashboard.cellLayout;
    const swapMode = cellLay === 3;         // 对调档：VM 第四格 / Dotii 第五格
    const v4Mode = cellLay === 4;          // 13:29 版：Dotii 第四格 / VM 第五格 + USAGE 右移
    const v5Mode = cellLay === 5;          // 组合档（已废弃，保留位）
    const v6Mode = cellLay === 6;          // ★ 用户最终版面：Dotii 最右 / VM 保持原大小贴它左边 / 缺口从 DSH 扣
    // ★ 必须包含 swapMode(3)：漏了它的话，对调档下 Dashboard 会**照旧画打印机卡**，
    //   而 Dotii 又被画在第五格、彼此重叠 —— 表现就是"第五格显示打印机卡、
    //   Dotii 不见了"（用户 2026-10-14 实测反馈）。
    const cellMode = cellLay === 1 || cellLay === 2 || swapMode || v4Mode || v5Mode || v6Mode;
    const dotiiInPrinter = cellLay === 2;   // 打印机格内嵌 Dotii（主题 0 的开关）
    // ★ 档位 2 也用**借位档**的几何：用户 2026-10-14 明确"从 DSH 会话挪横向空间"，
    //   而且不能把 Dotii 等比缩小（用户原话"你做了等比例缩小了吧"）。
    //   所以 1 与 2 共用同一套版式，唯一区别：2 不画打印机卡（那一格要让给 Dotii）。
    // 面板 1-2：DSH 会话（加宽档：横向剩下的空间都归它，见 Theme.agentWWide）
    const agentX = L.panelX(1);
    let agentW = L.usPanelVisible ? (pw * 2 + L.gap) : L.agentWWide;
    if (swapMode) {
      agentW = L.agentWWide;          // 对调档不动 DSH（只换四、五格内容）
    } else if (v6Mode) {
      agentW = FINAL_DSH_W;           // ★ 最终版面：DSH 缩小，把宽度让给 VM
    } else if (v4Mode || v5Mode) {
      agentW = V4_DSH_W;              // v4/组合档：DSH 吃掉中间空白
    } else if (cellMode) {
      // 主题 9 档：USAGE 保留（但左移），缺口全部从 DSH 会话格扣。
      // 几何真源在 ThemeDotiiCell（CELL_X / USAGE_X / DSH_W），这里按它算。
      agentW = DOTII_DSH_W;
    }
    Dashboard.dbgAgentW = agentW;
    Dashboard.dbgCellMode = cellLay;
    Dashboard.dbgDotiiInPrinter = dotiiInPrinter ? 1 : 0;
    Dashboard.agentPanel(ctx, agentX, py, agentW, ph, t, ex);

    // 面板 3：拓竹打印机面板（加宽档 448×434 —— 用户 2026-10-14「隐藏 USAGE、横向空间给打印机」）
    // 没有打印机数据时这一格不画，DSH 面板按需自己撑开（此处保持原宽，视觉更整齐）
    const pr: PrinterInfo | undefined = t.printer;
    if (!cellMode && !dotiiInPrinter && pr !== undefined) {
      Dashboard.printerPanel(ctx, L.prXWide, L.prY, L.prW, L.prH, pr);
    }

    // 面板 3：用量 + 时钟 —— 加宽档下**整个不画**（它的横向空间已让给打印机）。
    // 想恢复：把 Theme 的 usPanelVisible 改回 true 即可，printerPanel 会自动回到等宽落点 prX。
    if (L.usPanelVisible) {
      // USAGE 落点：
      //   v4/v5  → 左移到 721、宽 300（Dotii 在第四格时要腾出空间）
      //   主题 9(档位1) → 借位档的 DOTII_USAGE_X
      //   ★ 其余（含**对调档**）→ **原地不动**（L.usX / pw）。
      //     对调档曾因为 cellMode 把 swapMode 也算进去，导致 USAGE 被左移、
      //     与压进第四格的 VM 面板**重叠**（用户 2026-10-14 反馈"USAGE 一半被 VM 挡住"）。
      // ★ v6 **不**左移 USAGE：它的 VM 在第四格(1151)，USAGE 保持原位(867/274.4)刚好不重叠；
      //   若跟着 v4 左移到 721，右沿 1021 就会与 VM 面板(867..1141) 重叠 120px —— 实测踩过。
      const shifted = v4Mode || v5Mode || cellLay === 1;
      // v6 最终版面：USAGE 尺寸不变(300)、落点 706（右沿 1006，不与 VM 的 1016 重叠）
      const usx = v6Mode ? FINAL_USAGE_X : (shifted ? DOTII_USAGE_X : L.usX);
      const usw = v6Mode ? FINAL_USAGE_W
        : ((v4Mode || v5Mode) ? V4_USAGE_W : (shifted ? DOTII_USAGE_W : pw));
      Dashboard.dbgUsX = usx;
      Dashboard.dbgUsW = usw;
      Dashboard.usagePanel(ctx, usx, py, usw, ph, t, fs, ex);
    }

    // ★ 对调档（主题 0 的 Dotii 开关）：**只把四、五格的内容对调**
    //   标准档：第四格=打印机卡、第五格(最右)=VM
    //   对调档：第四格=**VM**、第五格(最右)=**Dotii**
    //   格子数、各格尺寸、其它面板一律不动（用户明确：格子没变，不该有空间变化）。
    // ★ 2026-10-14 修正（用户："VM 画面大小还是一样没变"）：
    //   v5 档原来也把 VM 塞进第四格（274 宽）→ VM 可用区只剩 250×368，
    //   画面被压得又小又扁（实测绘制 250×167），用户要的"占满右边空白"根本没发生。
    //   现在 **v5 档不再对调 VM**：只有明确的对调档(swapMode)才把 VM 挪进第四格，
    //   v5 保持 VM 在第五格（456 宽）→ 可用区 432×368、画面 432×288（大 1.7 倍）。
    if (v6Mode) {
      // ★ 最终版面：VM 保持原大小、**贴着 Dotii 的左边**画（面板右沿 1440，与 Dotii 隔 10px）
      Dashboard.vmPanel(ctx, FINAL_VM_X, L.vmY, FINAL_VM_W, L.vmH, vm, vmAgeMs, vmErr);
    } else if (swapMode) {
      Dashboard.vmPanel(ctx, L.panelX(3), L.vmY, L.panelWidth, L.vmH, vm, vmAgeMs, vmErr);
    } else {
      Dashboard.vmPanel(ctx, L.vmX, L.vmY, L.vmW, L.vmH, vm, vmAgeMs, vmErr);
    }
  }

  /** 竖装布局：逻辑空间 462×1920（绘制时由调用方整体旋转 90°） */
  private static renderVertical(ctx: CanvasRenderingContext2D, t: Telemetry,
                                fs: FrameStats, vm: image.PixelMap | null,
                                vmAgeMs: number, vmErr: string): void {
    const g = ctx.createLinearGradient(0, 0, 0, V.height);
    g.addColorStop(0, C.bgTop);
    g.addColorStop(1, C.bgBot);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, V.width, V.height);

    const x = V.margin;
    const w = V.innerW();
    Dashboard.headerV(ctx, x, V.hdrY, w, V.hdrH, t);
    const prV: PrinterInfo | undefined = t.printer;
    if (prV !== undefined) {
      Dashboard.vmPanel(ctx, x, V.vmY, w, V.vmHSplit, vm, vmAgeMs, vmErr);
      Dashboard.printerPanel(ctx, x, V.prY, w, V.prH, prV);
    } else {
      Dashboard.vmPanel(ctx, x, V.vmY, w, V.vmH, vm, vmAgeMs, vmErr);
    }
    Dashboard.systemPanel(ctx, x, V.sysY, w, V.sysH, t.system);
    Dashboard.agentPanelV(ctx, x, V.agY, w, V.agH, t);
    Dashboard.usagePanelV(ctx, x, V.usY, w, V.usH, t, fs);
  }

  /** 竖屏顶部：大时钟 + 日期 + 天气/歌词 */
  private static headerV(ctx: CanvasRenderingContext2D, x: number, y: number,
                         w: number, h: number, t: Telemetry): void {
    Dashboard.roundRect(ctx, x, y, w, h, 14);
    ctx.fillStyle = C.panel;
    ctx.fill();
    ctx.strokeStyle = C.border;
    ctx.lineWidth = 1;
    Dashboard.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 14);
    ctx.stroke();

    const d = new Date();
    const time = `${Dashboard.pad2(d.getHours())}:${Dashboard.pad2(d.getMinutes())}:${Dashboard.pad2(d.getSeconds())}`;
    Dashboard.monoFit(ctx, time, x + w / 2, y + 40, 46, C.textW, 'center', 'bold', w - 30);

    const week = ['日', '一', '二', '三', '四', '五', '六'];
    const dateStr = `${d.getFullYear()}-${Dashboard.pad2(d.getMonth() + 1)}-${Dashboard.pad2(d.getDate())} 周${week[d.getDay()]}`;
    Dashboard.label(ctx, dateStr, x + w / 2, y + 74, 16, C.textS, 'center');

    const wx = t.weather;
    let bottom = '';
    if (wx !== undefined && wx.text !== undefined) {
      bottom = `${wx.text}` + (wx.tempC !== undefined ? ` ${wx.tempC.toFixed(0)}°C` : '');
    }
    const lyr = t.lyrics;
    if (lyr !== undefined && lyr.line !== undefined && lyr.line.length > 0) {
      bottom = bottom.length > 0 ? `${bottom} · ${lyr.line}` : lyr.line;
    }
    if (bottom.length > 0) {
      Dashboard.label(ctx, Dashboard.fitText(ctx, bottom, F.font(16, 'normal'), w - 44),
        x + w / 2, y + 98, 16, C.cyan, 'center');
    }
  }

  /** 竖屏 DSH 面板：单列堆叠（项目/状态/活动/最后一句/进度/待办） */
  private static agentPanelV(ctx: CanvasRenderingContext2D, x: number, y: number,
                             w: number, h: number, t: Telemetry): void {
    const ag: AgentInfo = t.agent ?? {};
    const state = ag.state ?? 'unknown';
    const accent = Dashboard.stateColor(state);
    // 2.5× 下 'DEEPSEEK HARNESS' 有 ~490px 宽，会压到右侧的模型名 → 标题缩短
    // 面板从 3 格缩到 2 格后，标题右侧放不下 17 字符的模型名 → 挪到下面的 chips 里放短名
    Dashboard.panel(ctx, x, y, w, h, C.deepseek, 'DSH 会话', '');

    // 状态徽章（忙碌时呼吸）
    let alpha = 1.0;
    if (state === 'busy') {
      const ph = (Date.now() % 2400) / 2400;
      alpha = 0.55 + 0.45 * (0.5 + 0.5 * Math.sin(ph * Math.PI * 2));
    }
    const badgeText = Dashboard.stateText(state);
    ctx.font = F.font(18, 'bold');
    const bw = ctx.measureText(badgeText).width + 40;
    ctx.globalAlpha = alpha;
    ctx.fillStyle = accent;
    Dashboard.roundRect(ctx, x + w - 18 - bw, y + 52, bw, 34, 17);
    ctx.fill();
    ctx.globalAlpha = 1.0;
    ctx.fillStyle = '#08090F';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(badgeText, x + w - 18 - bw / 2, y + 69);

    // 项目名
    const project = ag.project ?? '（未连接数据桥）';
    Dashboard.mono(ctx, Dashboard.fitText(ctx, project, F.monoFont(26, 'bold'), w - 44),
      x + 22, y + 110, 26, C.textW, 'left', 'bold');

    // 活动行 + 工具
    Dashboard.label(ctx, Dashboard.fitText(ctx, ag.activity ?? '等待数据…',
      F.font(22, 'normal'), w - 44), x + 22, y + 150, 22, accent, 'left');
    if (ag.tool !== undefined && ag.tool.length > 0) {
      const toolText = Dashboard.fitText(ctx, ag.tool, F.monoFont(16, 'normal'), w - 80);
      ctx.font = F.monoFont(16, 'normal');
      const tw = ctx.measureText(toolText).width + 24;
      ctx.fillStyle = C.panelHi;
      Dashboard.roundRect(ctx, x + 22, y + 172, tw, 28, 6);
      ctx.fill();
      Dashboard.mono(ctx, toolText, x + 34, y + 186, 16, C.cyan, 'left', 'normal');
    }

    // 最后一句（2 行）
    const lines = Dashboard.wrap(ctx, ag.lastText ?? '', F.font(17, 'normal'), w - 44, 2);
    let ly = y + 216;
    for (const ln of lines) {
      Dashboard.label(ctx, ln, x + 22, ly, 17, C.textS, 'left');
      ly += 24;
    }

    // 任务进度
    const todos: TodoItem[] = t.todos ?? [];
    let done = 0;
    for (const td of todos) {
      if (td.status === 'completed') {
        done++;
      }
    }
    Dashboard.label(ctx, '任务进度', x + 22, y + 300, 17, C.textS, 'left');
    Dashboard.mono(ctx, todos.length > 0 ? `${done}/${todos.length}` : '—',
      x + w - 22, y + 300, 26, C.textW, 'right', 'bold');

    const segY = y + 322;
    const segW = w - 44;
    if (todos.length > 0) {
      const gap = 4;
      const itemW = (segW - gap * (todos.length - 1)) / todos.length;
      for (let i = 0; i < todos.length; i++) {
        const sx = x + 22 + i * (itemW + gap);
        const st = todos[i].status ?? 'pending';
        let col = C.barBg;
        if (st === 'completed') {
          col = C.green;
        } else if (st === 'in_progress') {
          col = C.deepseek;
        }
        ctx.fillStyle = col;
        Dashboard.roundRect(ctx, sx, segY, Math.max(3, itemW), 10, 5);
        ctx.fill();
      }
    } else {
      Dashboard.bar(ctx, x + 22, segY, segW, 10, 0, C.barBg);
    }

    // 待办列表（最多 6 条，避免溢出；多于 6 条时同样轮播）
    let ty = y + 356;
    const shown = Math.min(todos.length, 6);
    const startIdx = Dashboard.carouselSlice(todos.length, shown, Dashboard.carouselTick());
    if (todos.length === 0) {
      Dashboard.label(ctx, '暂无待办（DSH 写入 todo/write 后显示）', x + 22, ty + 8, 16,
        C.textL, 'left');
    }
    for (let i = 0; i < shown; i++) {
      const td = todos[(startIdx + i) % todos.length];
      const st = td.status ?? 'pending';
      let glyph = '○';
      let col = C.textL;
      if (st === 'completed') {
        glyph = '✓';
        col = C.textD;
      } else if (st === 'in_progress') {
        glyph = '▶';
        col = C.cyan;
      }
      Dashboard.label(ctx, glyph, x + 22, ty + 9, 17, col, 'left');
      const one = Dashboard.wrap(ctx, td.content ?? '', F.font(16, 'normal'), segW - 26, 1);
      Dashboard.label(ctx, one.length > 0 ? one[0] : '', x + 44, ty + 9, 16,
        st === 'completed' ? C.textD : C.textS, 'left');
      ty += 30;
    }
  }

  /** 竖屏用量面板（比横屏矮，布局重排） */
  private static usagePanelV(ctx: CanvasRenderingContext2D, x: number, y: number,
                             w: number, h: number, t: Telemetry, fs: FrameStats): void {
    Dashboard.panel(ctx, x, y, w, h, C.cyan, '用量', '');
    const tk: TokenInfo = t.tokens ?? {};
    const inTok = tk.todayInput ?? 0;
    const outTok = tk.todayOutput ?? 0;
    const ctxUsed = tk.contextUsed ?? 0;
    const ctxWin = tk.contextWindow ?? 0;
    const cost = tk.costUsd ?? -1;

    Dashboard.label(ctx, '今日 TOKEN', x + 22, y + 68, 16, C.textS, 'left');
    Dashboard.mono(ctx, Dashboard.fitText(ctx, Dashboard.fmtTokens(tk.todayTotal ?? 0),
      F.monoFont(30, 'bold'), Dashboard.valueMaxW(ctx, w, '今日 TOKEN', F.font(16, 'normal'))),
      x + w - 22, y + 68, 30, C.textW, 'right', 'bold');
    Dashboard.label(ctx, `↑ ${Dashboard.fmtTokens(inTok)}  ↓ ${Dashboard.fmtTokens(outTok)}`,
      x + w - 22, y + 98, 15, C.textL, 'right');

    const cpct = ctxWin > 0 ? (ctxUsed / ctxWin * 100) : 0;
    // ★ 百分比原本在 y+130、进度条在 y+146 —— 竖装下审计报"文字压到进度条"
    //   （这串 16px 字的实际占位高到 y+146）。上移到 y+120，留出 12px 净空。
    Dashboard.label(ctx, '上下文', x + 22, y + 120, 16, C.textS, 'left');
    Dashboard.mono(ctx, ctxWin > 0 ? `${cpct.toFixed(1)}%` : '—', x + w - 22, y + 120, 16,
      C.textW, 'right', 'normal');
    Dashboard.bar(ctx, x + 22, y + 150, w - 44, 12, cpct, C.byPercent(cpct));

    if (cost >= 0) {
      Dashboard.label(ctx, '预估花费', x + 22, y + 180, 16, C.textS, 'left');
      Dashboard.mono(ctx, `$${cost.toFixed(3)}`, x + w - 22, y + 180, 16, C.orange,
        'right', 'normal');
    }

    // ★ 这里原本有一条 1px 分隔线（y+204）。但竖装时 44px 大时钟画在 y+244，
    //   而等宽大字的实际占位是 y+189..y+299 —— **任何 y 位置的分隔线都躲不开它**
    //   （实测 layout_check --vertical 两次报"文字压线: '12:19'"）。
    //   竖装本来就是次要形态，为它牺牲一条装饰线不值：**竖装不画这条线**。

    const d = new Date();
    const time = `${Dashboard.pad2(d.getHours())}:${Dashboard.pad2(d.getMinutes())}`;
    Dashboard.monoFit(ctx, time, x + w / 2, y + 244, 44, C.textW, 'center', 'bold', w - 30);

    const usbTxt = fs.usbOpen ? `USB ● ${fs.sent}帧` : 'USB ○ 未连接';
    Dashboard.mono(ctx, usbTxt, x + 22, y + 296, 13,
      fs.usbOpen ? C.green : C.textD, 'left', 'normal');
    const br = fs.bridgeAge < 0 ? '桥 ○' : `桥 ● ${fs.bridgeAge}s`;
    Dashboard.mono(ctx, br, x + w - 22, y + 296, 13,
      fs.bridgeAge >= 0 && fs.bridgeAge < 10 ? C.green : C.textD, 'right', 'normal');
    Dashboard.mono(ctx, `${fs.renderMs.toFixed(0)}/${fs.encodeMs.toFixed(0)}/${fs.pushMs.toFixed(0)}ms`,
      x + w / 2, y + 318, 12, C.textD, 'center', 'normal');
  }

  /**
   * VM 画面区域。
   * VM 帧是 1680×1120（3:2），本区域接近正方形，所以按「等比放入」处理：
   * 不裁切、不变形，上下自然留黑边。
   */
  private static vmPanel(ctx: CanvasRenderingContext2D, x: number, y: number,
                         w: number, h: number, pm: image.PixelMap | null,
                         ageMs: number, vmErr: string): void {
    ctx.fillStyle = C.panel;
    Dashboard.roundRect(ctx, x, y, w, h, 14);
    ctx.fill();
    ctx.strokeStyle = C.border;
    ctx.lineWidth = 1;
    Dashboard.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 14);
    ctx.stroke();

    const accent = C.cyan;          // VM 功能色（状态/边框）
    const pillColor = C.blue;       // 胶囊统一蓝 #4285F4（用户选定）
    // 标题与其它面板保持一致：**胶囊包裹**（用户建议），中文标题
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.font = F.font(19, 'bold');
    const vmTitleW = ctx.measureText('虚拟机').width;
    const vmPillH = 30;
    ctx.globalAlpha = 0.18;
    ctx.fillStyle = pillColor;
    const vmPillX = x + (w - (vmTitleW + 26)) / 2;
    Dashboard.roundRect(ctx, vmPillX, y + 16, vmTitleW + 26, vmPillH, vmPillH / 2);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.strokeStyle = pillColor;
    ctx.lineWidth = 2;
    Dashboard.roundRect(ctx, vmPillX + 1, y + 17, vmTitleW + 24, vmPillH - 2, (vmPillH - 2) / 2);
    ctx.stroke();
    ctx.fillStyle = pillColor;
    ctx.fillText('虚拟机', vmPillX + 13, y + 16 + vmPillH / 2 + 1);

    const ageTxt = ageMs < 0 ? '无帧' : `${(ageMs / 1000).toFixed(1)}s`;
    ctx.textAlign = 'right';
    ctx.fillStyle = C.textL;
    ctx.font = F.monoFont(15, 'normal');
    ctx.fillText(ageTxt, x + w - 18, y + 31);
    ctx.textAlign = 'left';

    const top = y + 52;
    const innerH = h - 52 - 14;
    const innerW = w - 24;
    Dashboard.dbgVmInnerW = innerW;
    Dashboard.dbgVmInnerH = innerH;

    if (pm === null) {
      // ★ VM 没有画面 → 播超级玛丽演示版（用户 2026-10-21 要求）
      //   放在"等待 VM 画面"原来那块区域里，等比放大、两侧留黑边。
      if (Dashboard.marioEnabled) {
        const nowMs: number = Date.now();
        Dashboard.mario.step(nowMs);
        Dashboard.mario.draw(ctx, x + 12, top, innerW, innerH, nowMs);
        return;
      }
      ctx.textAlign = 'center';
      ctx.fillStyle = C.textD;
      ctx.font = F.font(17, 'normal');
      ctx.fillText('等待 VM 画面…', x + w / 2, y + h / 2 - 26);
      ctx.font = F.font(13, 'normal');
      // 2.0× 下这一行会冲出画面（审计实测右边界 1928 > 1920）→ 按面板宽度截断
      ctx.fillText(Dashboard.fitText(ctx,
        vmErr.length > 0 ? vmErr : 'livepad 127.0.0.1:8787/vm/frame.jpg',
        F.font(13, 'normal'), w - 24), x + w / 2, y + h / 2 + 12);
      ctx.textAlign = 'left';
      return;
    }

    let iw = 0;
    let ih = 0;
    try {
      const info = pm.getImageInfoSync();
      iw = info.size.width;
      ih = info.size.height;
    } catch (e) {
      iw = 0;
    }
    if (iw <= 0 || ih <= 0) {
      return;
    }
    // ★ 用户 2026-10-14："VM 放大到原来的大小、占有右边空白没有显示的区域，不要遮挡 USAGE"。
    //   原实现是 `Math.min(innerW/iw, innerH/ih)` 等比缩放 —— 画面只有 1680×1120，
    //   在 432×396 的可用区里**被宽度限制**，画出来只占可用宽的一部分，
    //   左右留出大片黑边（实测画面仅 ~289 宽、槽位可用宽 432）。
    //   改成**先按宽度铺满**（画布坐标系下 456 宽的槽位），需要时再等比降高；
    //   这样画面填满槽位宽度、右沿仍在槽位内，**不会碰到左边的 USAGE 面板**。
    //   注：等比不变形；只有当可用区比原图比例更高时才会出现上下留白（正常）。
    Dashboard.dbgVmSrcW = iw;
    Dashboard.dbgVmSrcH = ih;
    const scale = innerW / iw;              // 以"铺满可用宽度"为基准
    const dw = iw * scale;
    const dh = ih * scale;
    let dx = x + (w - dw) / 2;
    let dy = top + (innerH - dh) / 2;
    if (dh > innerH) {
      // 铺满宽度会超出可用高度时，退回归一化缩放（保持完整可见、不变形）
      const s2 = Math.min(innerW / iw, innerH / ih);
      const w2 = iw * s2;
      const h2 = ih * s2;
      dx = x + (w - w2) / 2;
      dy = top + (innerH - h2) / 2;
    }
    Dashboard.dbgVmDrawW = dw;
    Dashboard.dbgVmDrawH = dh;
    try {
      ctx.drawImage(pm, dx, dy, dw, dh);
    } catch (e) {
      // 画失败不影响其它面板
    }
    // 画面外框，便于看出黑边范围
    ctx.strokeStyle = C.border;
    ctx.strokeRect(dx, dy, dw, dh);
  }

  // ---------- 打印机卡片（拓竹） ----------

  /** 状态 -> 主题色（一眼看出打印中/暂停/故障） */
  private static printerAccent(state: string): string {
    if (state === 'RUNNING') { return C.green; }
    if (state === 'PAUSE') { return C.orange; }
    if (state === 'PREPARE') { return C.blue; }
    if (state === 'FINISH') { return C.cyan; }
    if (state === 'FAILED' || state === 'STUCK') { return C.red; }
    if (state === 'IDLE') { return C.textS; }
    return C.textD;
  }

  private static printerStateText(state: string): string {
    if (state === 'IDLE') { return '空闲'; }
    if (state === 'PREPARE') { return '准备中'; }
    if (state === 'RUNNING') { return '打印中'; }
    if (state === 'PAUSE') { return '已暂停'; }
    if (state === 'FINISH') { return '已完成'; }
    if (state === 'FAILED') { return '失败'; }
    if (state === 'STUCK') { return '卡住'; }
    if (state === 'OFFLINE') { return '离线'; }
    return '未知';
  }

  /** 剩余时长：1h20m / 35m / 40s（面板空间小，不用 : 分隔） */
  private static fmtDuration(sec: number): string {
    if (sec < 0) { return '—'; }
    const s = Math.floor(sec);
    const hh = Math.floor(s / 3600);
    const mm = Math.floor((s % 3600) / 60);
    if (hh > 0) {
      return `${hh}h${mm < 10 ? '0' : ''}${mm}m`;
    }
    if (mm > 0) {
      return `${mm}m`;
    }
    return `${s}s`;
  }

  /** 画一个"喷 220→220°"式的温度块，返回下一个块的起始 x */
  private static printerTemp(ctx: CanvasRenderingContext2D, x: number, y: number,
                             tag: string, cur: number, target: number): number {
    const curTxt = cur >= 0 ? `${Math.round(cur)}°` : '—';
    const txt = target >= 0 && target !== cur
      ? `${tag} ${curTxt}→${Math.round(target)}°`
      : `${tag} ${curTxt}`;
    Dashboard.mono(ctx, txt, x, y, 13, cur >= 0 ? C.textS : C.textD, 'left', 'normal');
    ctx.font = F.monoFont(13, 'normal');
    return x + ctx.measureText(txt).width + 14;
  }

  /** 右侧 AMS 托盘列：色块 + 材料 + 剩余，当前进料那个加亮描边 */
  private static printerTrays(ctx: CanvasRenderingContext2D, x: number, y: number,
                              h: number, p: PrinterInfo): void {
    const trays: PrinterTray[] = p.trays ?? [];
    const now: number = p.trayNow ?? -1;
    // 表头与第一盘间距：1.8× 后字号 ~20px，0.16→0.22 只剩 11px 会相压（审计实测 25%）
    Dashboard.label(ctx, trays.length > 0 ? 'AMS' : '耗材', x, y + h * 0.10, 11, C.textS, 'left');
    let ty = y + h * P.trayTop;
    const lim = trays.length < P.trayMax ? trays.length : P.trayMax;
    for (let i = 0; i < lim; i++) {
      const tr: PrinterTray = trays[i];
      const isNow: boolean = now >= 0 && tr.index === now;
      ctx.fillStyle = tr.color ?? C.barBg;
      Dashboard.roundRect(ctx, x, ty - 6, 13, 13, 3);
      ctx.fill();
      ctx.strokeStyle = isNow ? C.textW : C.border;
      ctx.lineWidth = isNow ? 2 : 1;
      Dashboard.roundRect(ctx, x + 0.5, ty - 5.5, 12, 12, 3);
      ctx.stroke();
      const remain = tr.remain ?? -1;
      const txt = `${tr.type ?? '?'}${remain >= 0 ? ' ' + remain + '%' : ''}`;
      Dashboard.label(ctx,
        Dashboard.fitText(ctx, txt, F.font(13, 'normal'), P.trayColW - 24),
        x + 20, ty, 13, isNow ? C.textW : C.textS, 'left');
      ty += h * P.trayPitch;
    }
    if (trays.length > P.trayMax) {
      Dashboard.label(ctx, `+${trays.length - P.trayMax} 盘`, x, ty, 12, C.textL, 'left');
    }
  }

  /**
   * 打印机卡片：状态 / 进度 / 温度 / AMS。
   * 只在遥测里带 printer 段时出现（桥端 --printer 打开才有），
   * 位置见 Theme 的 L.prY/L.prH（横屏）与 V.prY/V.prH（竖屏）。
   */
  private static printerPanel(ctx: CanvasRenderingContext2D, x: number, y: number,
                              w: number, h: number, p: PrinterInfo): void {
    const state: string = p.state ?? 'UNKNOWN';
    const offline: boolean = state === 'OFFLINE' || p.online === false;
    const accent = Dashboard.printerAccent(state);
    Dashboard.panel(ctx, x, y, w, h, accent, '打印机');

    // ★ 加宽档（2026-10-14 用户定：隐藏 USAGE，横向空间归打印机）：这一格现在是 448×434。
    // 源画布（Dotii 368×448）要求「1:1 + 居中」—— 448 = 源的纵向像素数，格子宽度就是照着它定的
    // （见 Theme.prW 注释：982 + 448 = 1430，VM 左沿 1450 一点没动）。
    // 下面的子版式因此按**两列 + 本地 y** 重排，不再沿用 274 宽那套竖排坐标。
    const wide = w >= 400;
    // ★ 与内容签名调用**同一个**函数（见 printerSlot 的注释）
    const sub = Dashboard.printerSlot();
    const lx = x + 22;
    const rx = x + w - 22;
    const colW = (w - 44 - 30) / 2;

    // ★ 真实优先：监控服务连不上云端（多为 token 过期）时，直接说清楚，别显示含混的"未知"
    if ((p.monitorMode ?? '') === 'error' || (p.monitorError ?? '').length > 0) {
      // 屏上不做"设置指导"（用户明确不要）：只说清状态与原因，怎么修在应用里看
      Dashboard.label(ctx, '监控未登录', lx, y + 140, 22, C.red, 'left');
      Dashboard.label(ctx, Dashboard.fitText(ctx, p.monitorError ?? '', F.fontSub(15, 'normal'), w - 44),
        lx, y + 200, 15, C.textS, 'left', 'sub');
      Dashboard.label(ctx, '凭据失效，需在软件端续期', lx, y + 240, 15, C.textL, 'left', 'sub');
      return;
    }

    const stateTxt = (p.stateLabel !== undefined && p.stateLabel.length > 0)
      ? p.stateLabel : Dashboard.printerStateText(state);

    const trays: PrinterTray[] = p.trays ?? [];
    const now: number = p.trayNow ?? -1;
    let nowType = '';
    for (const tr of trays) {
      if (tr.index === now) {
        nowType = tr.type ?? '';
      }
    }

    const pct: number = p.percent ?? -1;
    const nz = p.nozzleTemp ?? -1;
    const nzT = p.nozzleTarget ?? -1;
    const bd = p.bedTemp ?? -1;
    const bdT = p.bedTarget ?? -1;
    const ch = p.chamberTemp ?? -1;
    const fan = p.coolingFan ?? -1;
    const layer = p.layer ?? -1;
    const total = p.totalLayer ?? -1;

    // 顶部一条状态行（加宽档两列都能用）：左＝状态，右＝当前料
    Dashboard.label(ctx, stateTxt, lx, y + 80, wide ? 20 : 16, offline ? C.textD : accent, 'left', 'sub');
    if (nowType.length > 0) {
      Dashboard.mono(ctx, `料 ${nowType}`, rx, y + 80, wide ? 17 : 14, C.textL, 'right', 'normal', 'sub');
    }

    // 子页 0：概览（大百分比 + 进度条 + 层数 + 作业名）
    if (sub === 0) {
      Dashboard.mono(ctx, pct >= 0 ? `${pct}%` : '—', lx, y + 180, wide ? 52 : 28,
        offline ? C.textL : C.textW, 'left', 'bold');
      // 层数：单独一行，且与上方大百分比拉开（96px 字号的行高会压到 y+224）
      if (layer >= 0) {
        const lt = `层 ${layer}${total > 0 ? '/' + total : ''}`;
        Dashboard.mono(ctx, lt, lx, y + 236, wide ? 22 : 15, C.textL, 'left', 'normal', 'sub');
      }
      Dashboard.bar(ctx, lx, y + 262, w - 44, wide ? 18 : 14, pct >= 0 ? pct : 0, accent);
      const job = (p.jobName !== undefined && p.jobName.length > 0) ? p.jobName : '（无作业）';
      Dashboard.label(ctx, Dashboard.fitText(ctx, job, F.fontSub(wide ? 16 : 14, 'normal'), w - 44),
        lx, y + 318, wide ? 16 : 14, C.textS, 'left', 'sub');

    // 子页 1：温度（喷/床/腔 + 目标）
    // 加宽档用三列摊平（源格子是竖长条，这里横过来正好一行一个温度）
    } else if (sub === 1) {
      if (wide) {
        const t3 = (w - 44 - 60) / 3;
        const zones: string[] = ['喷嘴', '热床', '腔体'];
        const vals: number[] = [nz, bd, ch];
        const tgts: number[] = [nzT, bdT, -1];
        const cols: string[] = [C.orange, C.orange, C.textL];
        for (let i = 0; i < 3; i++) {
          const cx = lx + i * (t3 + 30);
          Dashboard.label(ctx, zones[i], cx, y + 140, 15, C.textS, 'left', 'sub');
          Dashboard.mono(ctx, vals[i] >= 0 ? `${vals[i].toFixed(0)}°` : '—', cx, y + 205, 30,
            cols[i], 'left', 'bold');
          Dashboard.label(ctx, tgts[i] >= 0 ? `目标 ${tgts[i].toFixed(0)}°` : '', cx, y + 255, 13,
            C.textD, 'left', 'sub');
        }
        if (fan >= 0) {
          Dashboard.label(ctx, `风扇 ${fan.toFixed(0)}%`, rx, y + 140, 14, C.textD, 'right', 'sub');
        }
      } else {
        Dashboard.label(ctx, '喷嘴', lx, y + 130, 14, C.textS, 'left', 'sub');
        Dashboard.mono(ctx, nz >= 0 ? `${nz.toFixed(0)}°` : '—', rx, y + 130, 20, C.orange,
          'right', 'bold', 'sub');
        Dashboard.label(ctx, nzT >= 0 ? `目标 ${nzT.toFixed(0)}°` : '', lx, y + 164, 12, C.textD, 'left', 'sub');

        Dashboard.label(ctx, '热床', lx, y + 214, 14, C.textS, 'left', 'sub');
        Dashboard.mono(ctx, bd >= 0 ? `${bd.toFixed(0)}°` : '—', rx, y + 214, 20, C.orange,
          'right', 'bold', 'sub');
        Dashboard.label(ctx, bdT >= 0 ? `目标 ${bdT.toFixed(0)}°` : '', lx, y + 248, 12, C.textD, 'left', 'sub');

        Dashboard.label(ctx, '腔体', lx, y + 298, 14, C.textS, 'left', 'sub');
        Dashboard.mono(ctx, ch >= 0 ? `${ch.toFixed(0)}°` : '—', rx, y + 298, 20, C.textL,
          'right', 'bold', 'sub');
        if (fan >= 0) {
          Dashboard.label(ctx, `风扇 ${fan.toFixed(0)}%`, lx, y + 336, 12, C.textD, 'left', 'sub');
        }
      }

    // 槽 3/4：表情（固件 face_ui 的 8 个表情，每槽一个 · 用户 2026-10-14 定「一个占满 10s」）
    // ★ 复用主题 5 的 facePage —— 不重抄几何，避免两套实现漂移。
    } else if (sub === 3 || sub === 4) {
      Dashboard.faceSlot(ctx, x, y, w, h, Date.now(), sub);
    // 子页 2：AMS 托盘（色块 + 类型 + 余量）
    // 加宽档两列并排（最多 4 盘：左 2 右 2），信息量翻倍且不挤
    } else if (sub === 5) {
      // 槽 5：打砖块（源 clock_pong，照搬常数、保持 5 行 9 列）
      Dashboard.pongSlot(ctx, x, y, w, h, Date.now());
    } else if (sub === 6) {
      // 槽 6：自走贪吃蛇
      Dashboard.snakeSlot(ctx, x, y, w, h, Date.now());
    } else {
      const lim = trays.length > 4 ? 4 : trays.length;
      const perCol = wide ? 2 : 4;
      const rowH = wide ? 62 : 46;
      for (let i = 0; i < lim; i++) {
        const tr = trays[i];
        const isNow = tr.index === now;
        const cx = wide ? (lx + Math.floor(i / perCol) * (colW + 30)) : lx;
        const cy = y + (wide ? 150 : 150) + (i % perCol) * rowH;
        const vx = cx + (wide ? colW : w - 44);
        ctx.fillStyle = tr.color ?? C.barBg;
        Dashboard.roundRect(ctx, cx, cy - 11, wide ? 26 : 22, wide ? 26 : 22, 6);
        ctx.fill();
        if (isNow) {
          Dashboard.roundRect(ctx, cx - 1, cy - 12, wide ? 28 : 24, wide ? 28 : 24, 7);
          ctx.strokeStyle = C.textW;
          ctx.lineWidth = 2;
          ctx.stroke();
        }
        const remain = tr.remain ?? -1;
        Dashboard.mono(ctx, `${tr.type ?? '?'}`, cx + (wide ? 40 : 34), cy, wide ? 17 : 15,
          isNow ? C.textW : C.textS, 'left', 'normal', 'sub');
        Dashboard.mono(ctx, remain >= 0 ? `${remain}%` : '—', vx, cy, wide ? 17 : 15, C.textL,
          'right', 'normal', 'sub');
      }
      if (trays.length === 0) {
        Dashboard.label(ctx, '无 AMS 数据', lx, y + 160, 14, C.textD, 'left', 'sub');
      }
    }

    // 底部：轮播指示点（打印机 3 个子页 + 表情 + 打砖块 = 6，见 PRINTER_SLOTS）
    const dots = Dashboard.PRINTER_SLOTS;
    let dxp = x + w / 2 - ((dots - 1) * 14) / 2;
    for (let i = 0; i < dots; i++) {
      ctx.beginPath();
      ctx.arc(dxp, y + h - 26, i === sub ? 5 : 3, 0, Math.PI * 2);
      ctx.fillStyle = i === sub ? accent : C.textD;
      ctx.fill();
      dxp += 14;
    }
  }


  private static background(ctx: CanvasRenderingContext2D): void {
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, C.bgTop);
    g.addColorStop(1, C.bgBot);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  }

  private static roundRect(ctx: CanvasRenderingContext2D, x: number, y: number,
                           w: number, h: number, r: number): void {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  /**
   * @param accent  面板**功能色**（进度条/数值/状态用它）
   * @param pillColor 标题胶囊的底色。默认浅灰 C.textS —— 用户 2026-10-14 选定
   *   "四个面板的胶囊统一浅灰"，让面板之间的区分交给标题文字，而不是颜色差异。
   *   传空字符串则跟随 accent。
   */
  private static panel(ctx: CanvasRenderingContext2D, x: number, y: number, w: number,
                       h: number, accent: string, title: string, right?: string,
                       pillColor: string = ''): void {
    ctx.fillStyle = C.panel;
    Dashboard.roundRect(ctx, x, y, w, h, 14);
    ctx.fill();
    ctx.strokeStyle = C.border;
    ctx.lineWidth = 1;
    Dashboard.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 14);
    ctx.stroke();

    // 标题：**胶囊（pill）包裹** —— 用户 2026-10-14 建议"加个胶囊把文字括起来会不会好看点"。
    // 底色 = 强调色 18% 不透明，描边同强调色 2px，圆角 = 半高（真正的胶囊形）。
    // 原来的"左侧 4px 强调条"去掉了（胶囊本身已经起到强调作用，两者并存会太花）。
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.font = F.font(19, 'bold');
    const titleW = ctx.measureText(title).width;
    const pillH = 30;
    // ★ 标题胶囊**水平居中**（用户 2026-10-14："系统、DSH 会话这几个搞到居中会不会好看点"）
    const pillX = x + (w - (titleW + 26)) / 2;
    const pillY = y + 16;
    const pillW = titleW + 26;
    const pill = pillColor.length > 0 ? pillColor : C.blue;   // 用户选定：#4285F4 蓝
    ctx.globalAlpha = 0.18;
    ctx.fillStyle = pill;
    Dashboard.roundRect(ctx, pillX, pillY, pillW, pillH, pillH / 2);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.strokeStyle = pill;
    ctx.lineWidth = 2;
    Dashboard.roundRect(ctx, pillX + 1, pillY + 1, pillW - 2, pillH - 2, (pillH - 2) / 2);
    ctx.stroke();
    ctx.fillStyle = pill;
    ctx.fillText(title, pillX + 13, pillY + pillH / 2 + 1);

    if (right !== undefined) {
      ctx.textAlign = 'right';
      ctx.fillStyle = C.textL;
      ctx.font = F.monoFont(16, 'normal');
      ctx.fillText(right, x + w - 18, y + 31);
      ctx.textAlign = 'left';
    }
  }

  /**
   * 文字。scale='sub' 时用子字号（F.scaleSub，2.0×）—— 分级字号的落点：
   * 重要的按主字号（2.5×），次要的按子字号，从而在同样面积里既保住可读性又保住信息量。
   */
  private static label(ctx: CanvasRenderingContext2D, text: string, x: number, y: number,
                       size: number, color: string, align: CanvasTextAlign,
                       scale: string = 'main'): void {
    ctx.textAlign = align;
    ctx.textBaseline = 'middle';
    ctx.fillStyle = color;
    ctx.font = scale === 'sub' ? F.fontSub(size, 'normal') : F.font(size, 'normal');
    ctx.fillText(text, x, y);
  }

  /**
   * 等宽大字按可用宽度自动缩字号：`wx`/`HH:mm` 这种 5-6 字符的 44px 等宽字
   * 实测要 ~330px，而 USAGE 面板只有 274 宽 —— 直接画会**超出面板被后面的面板盖住**
   * （实测在主题 9 里与 Dotii 圆角窗只差几像素，肉眼就是"压住了"）。
   */
  private static monoFit(ctx: CanvasRenderingContext2D, text: string, x: number, y: number,
                         size: number, color: string, align: CanvasTextAlign,
                         weight: string, maxW: number): void {
    ctx.textAlign = align;
    ctx.textBaseline = 'middle';
    ctx.fillStyle = color;
    let sz = size;
    ctx.font = F.monoFont(sz, weight);
    while (sz > 12 && ctx.measureText(text).width > maxW) {
      sz -= 2;
      ctx.font = F.monoFont(sz, weight);
    }
    ctx.fillText(text, x, y);
  }

  private static mono(ctx: CanvasRenderingContext2D, text: string, x: number, y: number,
                      size: number, color: string, align: CanvasTextAlign, weight: string,
                      scale: string = 'main'): void {
    ctx.textAlign = align;
    ctx.textBaseline = 'middle';
    ctx.fillStyle = color;
    ctx.font = scale === 'sub' ? F.monoSub(size, weight) : F.monoFont(size, weight);
    ctx.fillText(text, x, y);
  }

  private static bar(ctx: CanvasRenderingContext2D, x: number, y: number, w: number,
                     h: number, pct: number, color: string): void {
    ctx.fillStyle = C.barBg;
    Dashboard.roundRect(ctx, x, y, w, h, h / 2);
    ctx.fill();
    const p = Math.max(0, Math.min(100, pct));
    if (p > 0) {
      ctx.fillStyle = color;
      Dashboard.roundRect(ctx, x, y, Math.max(h, w * p / 100), h, h / 2);
      ctx.fill();
    }
  }

  /** 单行截断：超出 maxW 就裁掉并加省略号（防止长项目名/主机名撑破面板） */
  /**
   * 按可用宽度**自动缩小字号**，而不是截断加省略号。
   *
   * 起因（用户 2026-10-14）：DSH 会话面板的项目名 `WorkBuddy` 被截成 `WorkB...`，
   * 用户建议"缩小一点或者变两行，我见它的底部还有空间"。
   * 截断会把信息丢掉；缩字号既能完整显示，又不需要改版面高度。
   *
   * @param draw 实际绘制回调：(text, size) => void
   * @param minSize 允许缩到的最小字号（再小就回到截断，避免小到看不清）
   * @returns 最终使用的字号
   */
  private static drawShrink(ctx: CanvasRenderingContext2D, text: string,
                            maxW: number, startSize: number, minSize: number,
                            fontOf: (size: number) => string,
                            draw: (text: string, size: number) => void): number {
    let size = startSize;
    while (size > minSize) {
      ctx.font = fontOf(size);
      if (ctx.measureText(text).width <= maxW) {
        break;
      }
      size -= 1;
    }
    ctx.font = fontOf(size);
    if (ctx.measureText(text).width > maxW) {
      // 缩到下限仍放不下 → 回到"截断"兜底，保证不会压到别的元素
      draw(Dashboard.fitText(ctx, text, fontOf(size), maxW), size);
      return size;
    }
    draw(text, size);
    return size;
  }

  private static fitText(ctx: CanvasRenderingContext2D, text: string, font: string,
                         maxW: number): string {
    ctx.font = font;
    if (text.length === 0 || ctx.measureText(text).width <= maxW) {
      return text;
    }
    let lo = 0;
    let hi = text.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi + 1) / 2);
      if (ctx.measureText(text.substring(0, mid) + '…').width <= maxW) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return text.substring(0, lo) + '…';
  }

  /**
   * 右侧数值的安全宽度：面板内宽减去左侧标签宽度与间隔。
   * 面板变窄后（274px），长数值必须截断，否则会压到标签上。
   */
  private static valueMaxW(ctx: CanvasRenderingContext2D, panelW: number,
                           labelText: string, labelFont: string): number {
    ctx.font = labelFont;
    const labW = ctx.measureText(labelText).width;
    const avail = panelW - 44 - labW - 10;
    return avail > 60 ? avail : 60;
  }

  /** 返回文本占宽 */
  private static measure(ctx: CanvasRenderingContext2D, text: string, font: string): number {
    ctx.font = font;
    return ctx.measureText(text).width;
  }

  /** 按宽度折行（支持中英文混排） */
  private static wrap(ctx: CanvasRenderingContext2D, text: string, font: string,
                      maxW: number, maxLines: number): string[] {
    ctx.font = font;
    const lines: string[] = [];
    let cur = '';
    let truncated = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      if (ch === '\n') {
        lines.push(cur);
        cur = '';
        if (lines.length >= maxLines) {
          truncated = i < text.length - 1;
          break;
        }
        continue;
      }
      const test = cur + ch;
      if (ctx.measureText(test).width > maxW && cur.length > 0) {
        lines.push(cur);
        cur = ch;
        if (lines.length >= maxLines) {
          truncated = true;
          cur = '';
          break;
        }
      } else {
        cur = test;
      }
    }
    if (cur.length > 0 && lines.length < maxLines) {
      lines.push(cur);
    }
    if (truncated && lines.length > 0) {
      let last = lines[lines.length - 1];
      while (last.length > 1 && ctx.measureText(last + '…').width > maxW) {
        last = last.substring(0, last.length - 1);
      }
      lines[lines.length - 1] = last + '…';
    }
    return lines;
  }

  private static fmtTokens(n: number): string {
    if (n >= 100000000) {
      return (n / 100000000).toFixed(2) + '亿';
    }
    if (n >= 10000) {
      return (n / 10000).toFixed(1) + '万';
    }
    return `${n}`;
  }

  private static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  // ---------- 面板 0：系统 ----------

  private static systemPanel(ctx: CanvasRenderingContext2D, x: number, y: number,
                             w: number, h: number, sys?: SystemInfo): void {
    Dashboard.panel(ctx, x, y, w, h, C.blue, '系统');

    const cpu = sys?.cpu ?? 0;
    const cores = sys?.cores ?? 0;
    const memUsed = sys?.memUsed ?? 0;
    const memTotal = sys?.memTotal ?? 0;
    const load1 = sys?.load1 ?? 0;
    const load5 = sys?.load5 ?? 0;
    const load15 = sys?.load15 ?? 0;
    const temp = sys?.cpuTemp ?? -1;
    const host = sys?.host ?? '-';
    const uptime = sys?.uptimeSec ?? 0;

    // CPU 圆环
    const cx = x + w / 2;
    // 2.5× 下百分比字号 34*2.5=85px 塞不进 124px 直径的环 → 半径加大、字号收到 22
    const cy = y + 170;
    const r = 74;
    ctx.lineWidth = 14;
    ctx.strokeStyle = C.barBg;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.stroke();

    const pct = Math.max(0, Math.min(100, cpu));
    ctx.strokeStyle = C.byPercent(pct);
    ctx.beginPath();
    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * pct / 100);
    ctx.stroke();

    // 1.8× 字号下 61px 的数值会压到 cores 行：数值再上移、cores 再下移（审计实测重叠 13%）
    Dashboard.mono(ctx, `${pct.toFixed(0)}%`, cx, cy - 16, 34, C.textW, 'center', 'bold');
    Dashboard.label(ctx, cores > 0 ? `${cores} cores` : 'CPU', cx, cy + 44, 15, C.textS, 'center');

    // 内存
    const memPct = memTotal > 0 ? (memUsed / memTotal * 100) : 0;
    // 竖装时这个面板只有 380 高（横装 452），而底部"主机名+运行时长"两行位置是固定的
    // （分隔线 y+h-62、文字 y+h-38），不整块上移的话"CPU 温度"行会压到主机名上
    // —— 子代理在 Windows 渲染里实测到 y=956..977 两行墨迹连成一片。横装 dy=0，布局不变。
    const dy = h >= 420 ? 0 : -34;

    Dashboard.label(ctx, '内存', x + 22, y + 296 + dy, 17, C.textS, 'left');
    const memTxt = `${(memUsed / 1024).toFixed(1)} / ${(memTotal / 1024).toFixed(1)} GB`;
    Dashboard.mono(ctx, Dashboard.fitText(ctx, memTxt, F.monoFont(16, 'normal'),
      Dashboard.valueMaxW(ctx, w, '内存', F.font(17, 'normal'))),
      x + w - 22, y + 296 + dy, 16, C.textW, 'right', 'normal');
    Dashboard.bar(ctx, x + 22, y + 320 + dy, w - 44, 14, memPct, C.green);

    // 负载（次要信息 → 2.0× 子字号，塞在内存条与电量之间的空档）
    Dashboard.label(ctx, '负载', x + 22, y + 254 + dy, 17, C.textS, 'left', 'sub');
    // 只显示 1 分钟负载：三个值在 2.0× 下会把左侧标签压掉
    const loadTxt = `${load1.toFixed(2)}`;
    Dashboard.mono(ctx, Dashboard.fitText(ctx, loadTxt, F.monoSub(16, 'normal'),
      Dashboard.valueMaxW(ctx, w, '负载', F.fontSub(17, 'normal'))),
      x + w - 22, y + 254 + dy, 16, C.textW, 'right', 'sub');

    // 温度（本机若不暴露 thermal_zone 则不显示）
    if (temp >= 0) {
      const ty = y + 358 + dy;
      Dashboard.label(ctx, 'CPU 温度', x + 22, ty, 17, C.textS, 'left');
      Dashboard.mono(ctx, Dashboard.fitText(ctx, `${temp.toFixed(0)}°C`, F.monoFont(16, 'normal'),
        Dashboard.valueMaxW(ctx, w, 'CPU 温度', F.font(17, 'normal'))),
        x + w - 22, ty, 16,
        temp >= 85 ? C.red : (temp >= 70 ? C.orange : C.cyan), 'right', 'normal');
    }

    // 电量（本机采集才有；桥端数据没有这一项时不显示）。
    // 注意：这一行与上面的"CPU 温度"共用 y+334+dy —— 面板高度不够再开一行
    // （分隔线在 y+h-62，334+17 已经贴上了）。实测两者不会同时出现：
    // 鸿蒙侧取不到 thermal_zone（temp<0），Windows 侧没有无依赖的温度读数（CpuTemp=-1）。
    const batt = sys?.battery ?? -1;
    if (batt >= 0) {
      const by = y + 358 + dy;
      // 1.8× 下"电量（充电中）"有 7 个字（≈217px），会压到右侧数值 → 充电用闪电前缀
      Dashboard.label(ctx, sys?.charging === true ? '⚡ 电量' : '电量', x + 22, by, 17, C.textS, 'left');
      Dashboard.mono(ctx, `${Math.round(batt)}%`, x + w - 22, by, 16,
        batt <= 20 ? C.red : (batt <= 40 ? C.orange : C.green), 'right', 'normal');
    }

    // 主机名 + 运行时长（次要信息 → 2.0× 子字号）
    const days = Math.floor(uptime / 86400);
    const hrs = Math.floor((uptime % 86400) / 3600);
    const upText = `up ${days}d ${hrs}h`;
    Dashboard.mono(ctx, upText, x + w - 22, y + h - 24, 14, C.textL, 'right', 'sub');
  }

  // ---------- 面板 1-3：DSH 会话 ----------

  private static agentPanel(ctx: CanvasRenderingContext2D, x: number, y: number,
                            w: number, h: number, t: Telemetry,
                            ex: RenderExtras | null = null): void {
    const ag: AgentInfo = t.agent ?? {};
    const state = ag.state ?? 'unknown';
    const accent = Dashboard.stateColor(state);
    // 2.5× 下 'DEEPSEEK HARNESS' 有 ~490px 宽，会压到右侧的模型名 → 标题缩短
    // 面板从 3 格缩到 2 格后，标题右侧放不下 17 字符的模型名 → 挪到下面的 chips 里放短名
    Dashboard.panel(ctx, x, y, w, h, C.deepseek, 'DSH 会话', '');

    // 2 格宽（558）下的左右分栏：左侧放项目/活动/最后一句，右侧放进度与待办
    const leftW = Math.floor((w - 60) * 0.52);
    const midX = x + leftW + 30;
    const midW = w - leftW - 60;

    // ---- 状态徽章（忙碌时呼吸）----
    let alpha = 1.0;
    if (state === 'busy') {
      const phase = (Date.now() % 2400) / 2400;
      alpha = 0.55 + 0.45 * (0.5 + 0.5 * Math.sin(phase * Math.PI * 2));
    } else if (state === 'waiting') {
      const phase = (Date.now() % 1000) / 1000;
      alpha = phase < 0.5 ? 1.0 : 0.35;
    }
    const badgeText = Dashboard.stateText(state);
    ctx.font = F.font(18, 'bold');
    const bw = ctx.measureText(badgeText).width + 40;
    const bx = x + w - 18 - bw;
    // 1.8× 字号下行距整体放大；徽章盒子也跟着长高，否则 32px 的字塞不进 34px 的圆角条
    const by = y + 96;
    ctx.globalAlpha = alpha;
    ctx.fillStyle = accent;
    Dashboard.roundRect(ctx, bx, by, bw, 46, 23);
    ctx.fill();
    ctx.globalAlpha = 1.0;
    ctx.fillStyle = '#08090F';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(badgeText, bx + bw / 2, by + 23);

    // ---- 左列：项目 / 活动 / 最后一句 ----
    // ★ 项目名：**先缩字号，仍放不下就画两行**（用户 2026-10-14："workbuddy 后面的
    //   uddy 看不见了，缩小一点或者变两行？我见它的底部还有空间"）。
    //   原来只做截断（`WorkB...`），项目名会丢信息。可用宽度取左列宽 −20；
    //   若两行后仍超宽，再退回截断（保证不压到右列）。
    //   ⚠️ 这段必须写在 `agentPanel`（横装）里 —— 我一开始误改到 `agentPanelV`
    //   （竖装专用），结果横装毫无变化，白折腾了一轮。
    const project = ag.project ?? '（未连接数据桥）';
    const projMaxW = leftW - 20;
    const projSize = Dashboard.drawShrink(ctx, project, projMaxW, 30, 18,
      (sz: number) => F.monoFont(sz, 'bold'),
      (txt: string, sz: number) => {
        Dashboard.mono(ctx, txt, x + 22, y + 108, sz, C.textW, 'left', 'bold');
      });
    const projLine1 = Dashboard.fitText(ctx, project, F.monoFont(projSize, 'bold'), projMaxW);
    if (projLine1.endsWith('…') && projLine1.length < project.length) {
      const shown = projLine1.substring(0, projLine1.length - 1);
      Dashboard.mono(ctx, shown, x + 22, y + 92, projSize, C.textW, 'left', 'bold');
      const rest = project.substring(shown.length);
      Dashboard.drawShrink(ctx, rest, projMaxW, 24, 14,
        (sz: number) => F.monoFont(sz, 'bold'),
        (txt: string, sz: number) => {
          Dashboard.mono(ctx, txt, x + 22, y + 130, sz, C.textW, 'left', 'bold');
        });
    }

    const chips: string[] = [];
    if (ag.provider !== undefined && ag.provider.length > 0) {
      chips.push(ag.provider);
    }
    if (ag.turn !== undefined) {
      chips.push(`turn ${ag.turn}`);
    }
    if (ag.step !== undefined) {
      chips.push(`step ${ag.step}`);
    }
    // 工具名也放这一行：2.5× 下单独的芯片块会和"最后一句"重叠（审计实测 100%）
    if (ag.tool !== undefined && ag.tool.length > 0) {
      chips.push(ag.tool);
    }
    // 模型短名也放这一行（标题行放不下；去掉 deepseek- 前缀省地方）
    if (ag.model !== undefined && ag.model.length > 0) {
      chips.push(ag.model.startsWith('deepseek-') ? ag.model.substring(9) : ag.model);
    }
    let chipX = x + 22;
    const chipLimit = x + leftW + 8;   // 左列右缘，越过就会和右列标题撞上
    for (const c of chips) {
      ctx.font = F.monoFont(15, 'normal');
      const cw = ctx.measureText(c).width + 20;
      if (chipX + cw > chipLimit) {
        break;
      }
      ctx.fillStyle = C.panelHi;
      Dashboard.roundRect(ctx, chipX, y + 178, cw, 42, 21);
      ctx.fill();
      Dashboard.mono(ctx, c, chipX + cw / 2, y + 199, 15, C.textS, 'center', 'normal');
      chipX += cw + 8;
    }

    // 活动行
    const activity = ag.activity ?? '等待数据…';
    Dashboard.label(ctx, Dashboard.fitText(ctx, activity, F.font(22, 'normal'), leftW - 20),
      x + 22, y + 226, 22, accent, 'left');

    // ---- 底部"三行滚动留言条"（用户 2026-10-14 要求）----
    // 原来是最多 2 行 18px 静态文字（3 行会压到底部分隔线，审计实测过）。
    // 现在改成：字号缩到 15px、行距 30 → 3 行放得下（302..390 共 88px）；
    // 内容取 feed 的最后 3 条，**旧→新、由暗到亮**；新内容到来时整体向上滚 30px，
    // 在 300ms 内缓动到位 —— 就是"带点滚动感"的效果。
    const feedFont = F.font(15, 'normal');
    // ★ 必须判 `ex.feed !== undefined`：RenderExtras 的 feed 是后加的字段，
    //   离线审计器/其它调用方构造的 extras 可能没有它 → 直接读 .length 会抛
    //   `Cannot read properties of undefined`（审计实测报过）。
    const feedAll: string[] = (ex !== null && ex.feed !== undefined && ex.feed.length > 0)
      ? ex.feed : [];
    const fallbackText: string = (ex !== null && ex.summary.length > 0)
      ? `▸ ${ex.summary}` : (ag.lastText ?? '');
    let feed: string[] = feedAll.length > 0 ? feedAll.slice(-3) : [];
    if (feed.length === 0 && fallbackText.length > 0) {
      feed = Dashboard.wrap(ctx, fallbackText, feedFont, leftW - 20, 3);
    }
    // 上滚动画：新条目到达后 300ms 内，整体从 +30px 缓动到 0
    let scrollOff = 0;
    if (ex !== null && ex.feedAt !== undefined && ex.feedAt > 0) {
      const dt = Date.now() - ex.feedAt;
      if (dt < 300) {
        scrollOff = 30 * (1 - dt / 300);
      }
    }
    const feedTop = y + 268 + scrollOff;
    const alphas: number[] = [0.42, 0.68, 1.0];
    for (let i = 0; i < feed.length; i++) {
      const ln = Dashboard.fitText(ctx, feed[i], feedFont, leftW - 20);
      ctx.globalAlpha = alphas[i] !== undefined ? alphas[i] : 1;
      Dashboard.label(ctx, ln, x + 22, feedTop + i * 30, 15,
        i === feed.length - 1 ? C.textW : C.textS, 'left', 'sub');
    }
    ctx.globalAlpha = 1;

    // 底部状态条
    ctx.strokeStyle = C.border;
    ctx.beginPath();
    ctx.moveTo(x + 22, y + h - 58);
    ctx.lineTo(x + leftW + 8, y + h - 58);
    ctx.stroke();
    const bridge = t.agent === undefined ? '数据桥：无数据' : '数据桥：已连接';
    let footX = Dashboard.labelW(ctx, bridge, x + 22, y + h - 30, 14, C.textL, 'left');
    if (ex !== null && ex.focus.elapsedMs(Date.now()) > 0) {
      const ft = `专注 ${FocusTimer.fmt(ex.focus.elapsedMs(Date.now()))} · 番茄 ${ex.focus.pomodoros}`;
      footX = Dashboard.labelW(ctx, ft, footX + 24, y + h - 30, 14, C.green, 'left', 'sub');
    }
    const lyr = t.lyrics;
    if (lyr !== undefined && lyr.line !== undefined && lyr.line.length > 0) {
      Dashboard.monoSub(ctx, Dashboard.fitText(ctx, `♪ ${lyr.line}`, F.monoSub(14, 'normal'), 460),
        x + w - 22, y + h - 30, 14, C.textL, 'right', 'normal');
    }

    // ---- 右列：待办进度 + 列表 ----
    // 注意：右列整体从 y+104 起算，避开右上角的状态徽章（y+52..y+86），
    // 否则「N/M」进度数字会与徽章重叠（布局审计 layout_check.py 抓到的真问题）
    // 徽章在 y+44..90（1.8× 后更高），进度行原来 y+96 会与它相压（审计实测 26%）
    Dashboard.label(ctx, '进度', midX, y + 186, 17, C.textS, 'left');

    const todos: TodoItem[] = t.todos ?? [];
    let done = 0;
    for (const td of todos) {
      if (td.status === 'completed') {
        done++;
      }
    }
    const total = todos.length;
    const progText = total > 0 ? `${done}/${total}` : '—';
    Dashboard.mono(ctx, progText, x + w - 22, y + 186, 30, C.textW, 'right', 'bold');

    // 分段进度条
    const segY = y + 250;
    const segW = w - (midX - x) - 22;
    if (total > 0) {
      const segGap = 4;
      const segItemW = (segW - segGap * (total - 1)) / total;
      for (let i = 0; i < total; i++) {
        const sx = midX + i * (segItemW + segGap);
        const st = todos[i].status ?? 'pending';
        let col = C.barBg;
        if (st === 'completed') {
          col = C.green;
        } else if (st === 'in_progress') {
          col = C.deepseek;
        }
        ctx.fillStyle = col;
        Dashboard.roundRect(ctx, sx, segY, Math.max(3, segItemW), 10, 5);
        ctx.fill();
      }
    } else {
      Dashboard.bar(ctx, midX, segY, segW, 10, 0, C.barBg);
    }

    // 待办列表
    let ty = y + 288;
    // 一屏 2 条；待办多于 2 条时**轮播**（每 CAROUSEL_MS 向前滚一格），
    // 这样屏幕高度只够 2 行的前提下也能把全部待办都看到
    const shown = Math.min(todos.length, 2);
    const tick = Dashboard.carouselTick();
    const startIdx = Dashboard.carouselSlice(todos.length, shown, tick);
    if (todos.length === 0) {
      // ★ 原文「暂无待办（DSH 写入 todo/write 事件后显示）」在 398 宽的 DSH 面板里
      //   右列只有 163px，17px 字号实测约 337px → **会越界插进"用量"面板**（用户实测反馈）。
      //   改成短文案 + 按列宽截断，双保险。
      Dashboard.label(ctx, Dashboard.fitText(ctx, '暂无待办（DSH 写入后显示）',
        F.font(15, 'normal'), midW), midX, ty, 15,
        C.textL, 'left');
    }
    for (let i = 0; i < shown; i++) {
      const td = todos[(startIdx + i) % todos.length];
      const st = td.status ?? 'pending';
      let glyph = '○';
      let col = C.textL;
      if (st === 'completed') {
        glyph = '✓';
        col = C.textD;
      } else if (st === 'in_progress') {
        glyph = '▶';
        col = C.cyan;
      }
      Dashboard.label(ctx, glyph, midX, ty, 17, col, 'left');
      const itemFont = F.font(17, 'normal');
      // 复选框 1.8× 后宽到 ~34px，文字要从 midX+44 起，否则会压在圆点上
      const itemLines = Dashboard.wrap(ctx, td.content ?? '', itemFont, segW - 52, 1);
      Dashboard.label(ctx, Dashboard.fitText(ctx,
        itemLines.length > 0 ? itemLines[0] : '', F.font(16, 'normal'), midW - 44),
        midX + 44, ty, 16,
        st === 'completed' ? C.textD : C.textS, 'left');
      ty += 58;
    }
    // 轮播页码（只有多于 2 条时才显示），让它一眼看出列表在滚动
    if (todos.length > shown) {
      const pages = todos.length;
      Dashboard.mono(ctx, `${startIdx + 1}›${Math.min(startIdx + shown, pages)}/${pages}`,
        x + w - 22, y + h - 30, 12, C.textD, 'right', 'normal', 'sub');
    }
  }

  /**
   * 轮播节拍：每 CAROUSEL_MS 递增一次。
   * 渲染端用它决定"现在该显示哪几条"，LcdService 的内容签名也用它 ——
   * 这样到点会真的重推一帧（否则签名不变，屏上不会翻滚）。
   */
  static carouselTick(): number {
    return Math.floor(Date.now() / Dashboard.CAROUSEL_MS);
  }

  /**
   * 轮播该从第几条开始显示（纯函数，可离线自检）。
   * total ≤ shown 时不轮播（一直从 0 开始）；否则按节拍取模循环。
   */
  static carouselSlice(total: number, shown: number, tick: number): number {
    if (total <= shown || total <= 0 || tick < 0) {
      return 0;
    }
    return tick % total;
  }

  /** 轮播间隔（毫秒） */
  private static readonly CAROUSEL_MS: number = 8000;

  /** 打印机面板内部轮播间隔（毫秒） */
  static readonly PRINTER_CAROUSEL_MS: number = 10000;

  /**
   * 打印机格内容轮播槽位数（每槽 PRINTER_CAROUSEL_MS = 10s）：
   *   0/1/2 = 打印机三屏（概览 / 温度 / AMS）
   *   3/4   = 表情（源固件 face_ui 的 8 个表情，每槽只用一个 —— 用户 2026-10-14 定）
   *   5     = 打砖块（源固件 clock_pong，用户指定 30s）
   * ★ 槽 3/4/5 的渲染在 B 线里实现（交接单 HANDOFF-打印机格复刻.md），
   *   本文件先只登记槽位与指示点，未实现的槽位回落到子页 0，不会画空白。
   */
  static readonly PRINTER_SLOTS: number = 6;
  /** 打砖块那一槽实际占的时长（用户指定 30s = 3 × 10s 槽） */
  static readonly PRINTER_GAME_MS: number = 30000;

  /**
   * 当前打印机格内容槽位（0..PRINTER_SLOTS-1），LcdService 的内容签名也用它。
   *
   * 时间轴：0–10s 概览 · 10–20s 温度 · 20–30s AMS · 30–40s 表情 · 40–50s 表情
   *        · 50–80s 打砖块 · 然后循环（整轮 80s）。
   */
  static printerSubPage(): number {
    // ★ 2026-10-15 修复（代码审查【致命-2】）：本函数原来与真正渲染用的算法**不一致**——
    //   这里用 `% (3*10s + 30s)` 再 `if(slot===0/1/2)`，30 秒之后**恒返回 0**；
    //   而渲染侧（printerPanel 里）用的是 `Math.floor(now / PRINTER_CAROUSEL_MS) % 4`。
    //   后果：子页从 2→3、3→0 时**内容签名不变** → 该帧被"签名未变则跳过"挡掉
    //   → 打印机格周期性停住 20 秒（底部指示点也停），最容易被误判成屏端固件丢帧。
    //   修法：收敛成**这一个纯函数**，渲染与签名都调它，从结构上不可能再漂。
    return Dashboard.printerSlot();
  }

  /**
   * 打印机格的当前子页（**唯一真源**）。
   * 时间轴：0–10s 概览 · 10–20s 温度 · 20–30s AMS · 30–40s 表情，然后循环（整轮 40s）。
   * 渲染侧与内容签名侧都必须调用本函数。
   */
  static printerSlot(): number {
    // ★ 2026-10-16：原来写死 `% 4` → **永远不可能返回 5**，
    //   于是「打砖块」槽（5）永远走不到，即使它的渲染分支已经写好。
    //   这正是本文件注释里早就警告过的那类不一致：
    //   "渲染与签名必须调同一个函数" —— 但函数本身的范围也得覆盖全部槽位。
    //
    // 时间轴（与 PRINTER_SLOTS / PRINTER_GAME_MS 的注释一致，整轮 80s）：
    //   块 0    0–10s   槽 0 概览
    //   块 1   10–20s   槽 1 温度
    //   块 2   20–30s   槽 2 AMS
    //   块 3   30–40s   槽 3 表情
    //   块 4   40–50s   槽 4 表情
    //   块 5/6/7 50–80s 槽 5 打砖块（30s = 3 × 10s 块）
    //   块 8/9   80–100s 槽 6 自走贪吃蛇（20s = 2 × 10s 块）
    // → 整轮 100s。★ 加槽位时必须同步改这里，否则新槽永远走不到
    //   （历史上就踩过 `% 4` 导致槽 5 不可达）。
    const chunk = Math.floor(Date.now() / Dashboard.PRINTER_CAROUSEL_MS) % 10;
    if (chunk <= 4) {
      return chunk;
    }
    return chunk <= 7 ? 5 : 6;
  }

  /** 画一段文字并返回它的右边界（用于把多段小字接成一行） */
  private static labelW(ctx: CanvasRenderingContext2D, text: string, x: number, y: number,
                        size: number, color: string, align: CanvasTextAlign,
                        scale: string = 'main'): number {
    Dashboard.label(ctx, text, x, y, size, color, align, scale);
    ctx.font = scale === 'sub' ? F.fontSub(size, 'normal') : F.font(size, 'normal');
    return x + ctx.measureText(text).width;
  }

  /** 子字号等宽（给底部小字用） */
  private static monoSub(ctx: CanvasRenderingContext2D, text: string, x: number, y: number,
                         size: number, color: string, align: CanvasTextAlign,
                         weight: string): void {
    Dashboard.mono(ctx, text, x, y, size, color, align, weight, 'sub');
  }

  /** 面板内的一条横向分隔线（用法与原来内联写的 moveTo/lineTo 完全一致） */
  private static hlineLocal(ctx: CanvasRenderingContext2D, x0: number, x1: number, y: number): void {
    ctx.strokeStyle = C.border;
    ctx.beginPath();
    ctx.moveTo(x0, y);
    ctx.lineTo(x1, y);
    ctx.stroke();
  }

  private static stateColor(state: string): string {
    if (state === 'busy') {
      return C.deepseek;
    }
    if (state === 'waiting') {
      return C.orange;
    }
    if (state === 'idle') {
      return C.green;
    }
    return C.textL;
  }

  private static stateText(state: string): string {
    if (state === 'busy') {
      return '● 工作中';
    }
    if (state === 'waiting') {
      return '◆ 等待输入';
    }
    if (state === 'idle') {
      return '○ 空闲';
    }
    return '— 未知';
  }

  // ---------- 面板 4：用量 + 时钟 ----------

  private static usagePanel(ctx: CanvasRenderingContext2D, x: number, y: number,
                            w: number, h: number, t: Telemetry, fs: FrameStats,
                            ex: RenderExtras | null = null): void {
    Dashboard.panel(ctx, x, y, w, h, C.cyan, '用量');

    const tk: TokenInfo = t.tokens ?? {};
    const todayTotal = tk.todayTotal ?? 0;
    const bal: BalanceInfo | undefined = t.balance;

    // ---- 今日 TOKEN：数字改到标签下面（用户要求）且缩到 2.0× ----
    Dashboard.label(ctx, '今日 TOKEN', x + 22, y + 86, 16, C.textS, 'left');
    Dashboard.mono(ctx, Dashboard.fitText(ctx, Dashboard.fmtTokens(todayTotal),
      F.monoSub(30, 'bold'), w - 44), x + 22, y + 152, 30, C.textW, 'left', 'bold', 'sub');

    // ---- 余额 ----
    Dashboard.hlineLocal(ctx, x + 22, x + w - 22, y + 196);
    const cur = (bal !== undefined && bal.currency === 'USD') ? '$' : '¥';
    Dashboard.label(ctx, '余额', x + 22, y + 222, 16, C.textS, 'left');
    if (bal === undefined) {
      Dashboard.mono(ctx, '—', x + w - 22, y + 226, 24, C.textD, 'right', 'bold', 'sub');
    } else if (bal.error !== undefined && bal.error.length > 0) {
      // ★ 这里原来给的可用宽度是 `w - 44`（=256），但文字是**右对齐**从 x+w-22 往左排，
      //   于是 256 宽必然越过左边的"余额"标签 → 实测两段文字叠在一起
      //   （用户截图反馈："余额 取数失败 请求失败: TypeError"）。
      //   正确算法：右缘往左只剩 `w - 44 - 62`（给"余额"标签留 62px），并按该宽度截断。
      const errMaxW = w - 44 - 62;
      Dashboard.mono(ctx, Dashboard.fitText(ctx, `取数失败 ${bal.error}`,
        F.font(13, 'normal'), errMaxW),
        x + w - 22, y + 226, 13, C.red, 'right', 'normal');
    } else {
      const total = bal.total ?? -1;
      const col = total < 0 ? C.textD : (total < 5 ? C.red : (total < 20 ? C.orange : C.green));
      // ★ 哨兵 -1 表示"没有数"，不能格式化成 "¥-1.00"（审计 M8）。
      //   同一份内容另两处（Dotii 页 / 打印机格）都显示 '—'，这里原来会显示负数。
      const balTxt = total < 0 ? '—' : `${cur}${total.toFixed(2)}`;
      Dashboard.mono(ctx, Dashboard.fitText(ctx, balTxt,
        F.monoSub(24, 'bold'), Dashboard.valueMaxW(ctx, w, '余额', F.font(16, 'normal'))),
        x + w - 22, y + 226, 24, col, 'right', 'bold', 'sub');
      // 还能用多久（子字号，贴在"余额"标签右侧；算不出来就不画）
      const eta = bal.etaHours ?? -1;
      if (eta > 0) {
        const etaTxt = eta >= 24 ? `还能 ${(eta / 24).toFixed(1)} 天` : `还能 ${eta.toFixed(1)} 时`;
        Dashboard.label(ctx, etaTxt, x + 108, y + 226, 13,
          eta > 24 ? C.green : C.orange, 'left', 'sub');
      }
    }

    // ---- 上下文占用（次要，2.0×）----
    const ctxUsed = tk.contextUsed ?? 0;
    const ctxWin = tk.contextWindow ?? 0;
    const cpct = ctxWin > 0 ? (ctxUsed / ctxWin * 100) : 0;
    Dashboard.label(ctx, '上下文', x + 22, y + 274, 16, C.textS, 'left', 'sub');
    Dashboard.mono(ctx, ctxWin > 0 ? `${cpct.toFixed(1)}%` : '—', x + w - 22, y + 274, 16,
      C.byPercent(cpct), 'right', 'sub');
    Dashboard.bar(ctx, x + 22, y + 296, w - 44, 10, cpct, C.byPercent(cpct));

    // ---- 时钟 + 日期（日期加月日、用子字号，用户要求）----
    const d = new Date();
    const time = `${Dashboard.pad2(d.getHours())}:${Dashboard.pad2(d.getMinutes())}`;
    Dashboard.mono(ctx, Dashboard.fitText(ctx, time, F.monoFont(28, 'bold'), w - 44),
      x + w / 2, y + 344, 28, C.textW, 'center', 'bold');
    const week = ['日', '一', '二', '三', '四', '五', '六'];
    const dateStr = `${d.getMonth() + 1}月${d.getDate()}日 周${week[d.getDay()]}`;
    Dashboard.label(ctx, dateStr, x + w / 2, y + 396, 14, C.textL, 'center', 'sub');

    // ---- 底部：本屏 USB 状态 ----
    const usbTxt = fs.usbOpen ? `USB ● ${fs.sent}帧` : 'USB ○ 未连接';
    Dashboard.mono(ctx, usbTxt, x + 22, y + h - 14, 13,
      fs.usbOpen ? C.green : C.textD, 'left', 'normal', 'sub');
  }
}
