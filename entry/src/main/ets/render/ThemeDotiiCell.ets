/**
 * ThemeDotiiCell.ets —— 主题 9「打印机位 Dotii」（测试主题）
 *
 * 用户 2026-10-14 要求：**把 Dotii 的内容替换到打印机格的位置，位置不够就从 DSH 会话那里挪**。
 *
 * 版面（逻辑 1920×462，沿用主题 0 的外边距/间隙）：
 *
 *   ┌─────────┬────────────────────┬──────────────────────────┬───┬──────────┐
 *   │ SYSTEM  │ DSH 会话（被扣窄） │ 打印机格（本主题＝Dotii）│gap│ VM       │
 *   │ 274.4   │ 607.6              │ 425                      │ 10│ 456      │
 *   └─────────┴────────────────────┴──────────────────────────┴───┴──────────┘
 *   x=14      288.4                …                        1430  1450
 *
 * 借位算法：打印机格取「够放 Dotii 源画布 + 一条窄信息栏」的宽度（425），
 * 缺口**全部从 DSH 会话格扣**（用户指定），VM 一格不动（x=1450 一个像素没变）。
 *
 * Dotii 内容复用主题 5 的 `ThemeDotii.renderPages()`（368×448 等比 ×0.9333），
 * 所以本主题里 Dotii 的显示与主题 5 完全一致，只是搬到了打印机格的位置。
 */
import type { PrinterInfo } from '../common/Types';
import { L } from '../common/Theme';
import { DotiiState, ThemeDotii } from './ThemeDotii';
import { Chrome } from './Chrome';

/**
 * 主题 9 档的几何。**全部写成推算好的字面量**并注明推导来源 ——
 * 用 `L.xxx` 互相引用会在不同加载顺序下变成"变量在声明前使用"
 * （布局校验器和真机构建对模块求值顺序的处理不一样，实测踩过）。
 *
 * 基准（Theme）：margin 14、gap 10、白板宽 1440、等宽 panelWidth 274.4、VM 左沿 vmX 1450。
 * 用户 2026-10-14 选定："从 DSH 会话再借、USAGE 也保留"这一档：
 *
 *   Dotii 右沿贴 VM 左侧留一个 gap → CELL_X = 1450 − 10 − 409 = 1031
 *   Dotii 格宽 409 = 343.5（原尺寸）+ 65.5 余量。
 *   原先那 65.5 是"左 10 内边距 + 右 55.5（其中 37.5 给打印机信息栏）"——
 *   但**信息栏根本画不出来**（37.5 < INFO_BAR_MIN 54），于是右侧只剩一块
 *   不对称的黑边（用户 2026-10-14：「Dotii 右边有一块黑色的、没有内容，能缩掉吗」）。
 *   → 修法：**取消信息栏预留，余量左右对称居中**（左右各约 22.8）。
 *     格宽与 DSH/USAGE 的位置都不动 —— 实测把余量还给 DSH 会让它压到 USAGE
 *     （DSH 右沿 674.9 > USAGE 左沿 639.6，重叠 35px），所以不做那件事。
 *
 * ⚠️ 与 USAGE 的间隙要留够 **30px**，不是 gap(10)：
 *   实测（第一版 gap=10）USAGE 右沿 ≈1011，但它里面的**大时钟文字右缘伸到 ~1016**
 *   （44px 字号居中，字宽超过面板内边距），与 Dotii 圆角窗只差 6px，肉眼就是"压住了"。
 *   USAGE 内容宽 = 274.4，左沿必须 ≤ 1031 − 30 − 274.4 = 726.6。
 *
 * ★ USAGE 面板要**专门加宽到 300**：实测它的 `HH:mm` 时钟用 44px 等宽字约需
 *   220px 净宽（加两侧内边距共 ~280），而等宽档只有 274.4 —— 差一点点就会被
 *   右边界面板盖住（实测 `10:08` 的末位被裁）。加宽到 300 后不再裁。
 *
 * 最终五格：14(274.4) | 298.4(331.2) | 639.6(300) | 1031(409) | 1450(VM)
 */
export const CELL_W: number = 409;
export const CELL_X: number = 1031;
export const USAGE_W: number = 300;          // 比等宽档(274.4)宽 25.6，专为放下大时钟
export const USAGE_X: number = 721;
export const DSH_X: number = 298.4;
export const DSH_W: number = 412.6;
/** 右侧信息栏最小宽度（再窄就不画，优先保证 Dotii 内容）。本档余量 76px 不够放信息栏，故为 0。 */
const INFO_BAR_MIN: number = 54;
/** Dotii 内容在格内的目标宽度 */
const DOTII_WANT: number = 368 * 0.9333;                   // 343.5
/**
 * 按档位取"打印机格"的几何。
 *
 * `mode=1`（主题 9）：格宽 409（从 DSH 会话借位），Dotii 按 1.0 原尺寸画。
 * `mode=2`（主题 0 的"打印机格显示 Dotii"开关）：格宽 = 等宽档 274.4，
 *   **不动 DSH/USAGE**（第一屏其余面板保持原样），代价是 Dotii 会自动等比缩小。
 */
export class DotiiCellGeom {
  /**
   * 两个档位现在**共用借位几何**（格宽 409）。
   * 原先档位 2 用等宽档 274.4，结果 Dotii 被等比缩小 —— 用户否掉了这个做法：
   * 他明确要"从 DSH 会话挪横向空间"，也不接受缩小。
   * 保留 mode 参数是为了将来若要恢复"等宽档不缩水以外的其它排法"时有个挂点。
   */
  static x(mode: number): number {
    return (mode === 3 || mode === 5) ? SWAP_CELL_X
      : (mode === 6 ? V4SWAP_DOTII_X : CELL_X);
  }
  static w(mode: number): number {
    return (mode === 3 || mode === 5) ? SWAP_CELL_W
      : (mode === 6 ? V4SWAP_DOTII_W : CELL_W);
  }
  /** 信息栏是否画（借位档余量 409−343.5=65.5，放得下窄栏） */
  static showInfoBar(mode: number): boolean {
    return true;
  }
}

/**
 * 对调档（mode=3）几何：**VM 挪到最左、Dotii 挪到最右**（用户 2026-10-14 要求）。
 *
 * **注意：格子没有增减，只是四、五格的内容对调**（用户 2026-10-14 纠正过我一次：
 * "你按现有的、把 VM 从最后面的格子挪到第四个格子、Dotii 挪到第五个格子，
 *  怎么会有空间变化呢？" —— 他是对的，我一开始错去重排了其它面板的宽度）。
 *   标准档：第四格 = 打印机卡 / 第五格 = VM
 *   对调档：第四格 = **VM** / 第五格 = **Dotii**（x=1450、宽 456，即原 VM 列）
 *   SYSTEM / DSH / USAGE 全部原地不动。
 */
/**
 * **13:29 那一版**的几何（用户 2026-10-14 要求"保留/再看一下"）：
 *   SYSTEM 14(274.4) | DSH 298.4(412.6) | USAGE **721**(300) | Dotii 1031(409) | VM 1450(456)
 * 特征：USAGE 右移到 Dotii 左边、DSH 吃掉中间那段空白；Dotii 仍在**第四格**、VM 在第五格。
 * 与"对调档(3)"的区别：那档是 VM 进第四格、Dotii 进第五格。
 */
export const V4_USAGE_X: number = 721;
export const V4_USAGE_W: number = 300;
export const V4_DSH_W: number = 412.6;

/** 对调档下 Dotii 落在**第五格（原 VM 列）**：x=1450、宽 456 */
export const SWAP_CELL_X: number = 1450;
export const SWAP_CELL_W: number = 456;
/**
 * **用户实际看到的那一版**（v4）的对调：第四/五格内容互换、格子尺寸不变。
 *   第四格 (1151.6, 274.4) = VM      ← 原本是 Dotii
 *   第五格 (1450, 456)     = Dotii   ← 原本是 VM
 * 前三格（SYSTEM / DSH / USAGE）完全按 v4 原样（USAGE 721 / 宽 300）。
 */
export const V4SWAP_DOTII_X: number = 1450;
export const V4SWAP_DOTII_W: number = 456;

/**
 * **用户最终要的版面（2026-10-14）**：Dotii 在最右、VM 保持原大小、贴着 Dotii 左边画，
 * USAGE 尺寸不变，缺口从 **DSH 会话**扣（用户原话："对调后 DSH 可以对应缩小，
 * VM 画面不变、usage 画面不变，但 VM 你要贴着 dotti 的边缘绘画"）。
 *
 * 宽度账（整条 1906 可用）：
 *   SYSTEM 274.4 │ DSH 430 │ USAGE 300 │ VM 432 │ Dotii 409  + 4×gap(10) + margin(14) = 1906 ✅
 *   VM 可用区宽 = 432 − 24 = 408 → 画面 408×272（等比，和它原来在第五格时同量级）
 */
export const FINAL_DOTII_X: number = 1450;      // Dotii 仍在最右（右沿 1859，不碰 1906 边）
export const FINAL_USAGE_X: number = 706;       // USAGE 右沿 1006
export const FINAL_USAGE_W: number = 300;       // 尺寸不变
export const FINAL_VM_X: number = 1016;         // VM 面板左沿
export const FINAL_VM_W: number = 424;          // VM 面板宽（右沿 1440，与 Dotii 之间 10px）
export const FINAL_DSH_W: number = 398;         // DSH 会话（缩小，让位给 VM）

/** Dotii 源画布 368×448 等比 ×0.9333 → 343.5×418.1 */
export const DOTII_SCALE: number = 0.9333;
export const DOTII_W: number = 368 * DOTII_SCALE;
export const DOTII_H: number = 448 * DOTII_SCALE;

/** 右侧信息栏要显示的真实数据（本格原本的职责） */
export class DotiiCellInfo {
  prState: string = '';
  prPct: number = -1;
  prNozzle: number = -1;
  prBed: number = -1;
  prLayer: number = -1;
  prRemainText: string = '--';
  trays: number = 0;
  balance: string = '--';
}

export class ThemeDotiiCell {
  static readonly NAME: string = '打印机位 Dotii';

  /**
   * Dotii 内容在某个格子里的落位（**单一真源**）。
   *
   * 为什么抽出来：现在有**两处**要把 368×448 的 Dotii 内容缩进格子 ——
   * ① 整个 Dotii 页（renderPages）② 打印机格的「表情」槽（只画脸）。
   * 两处若各算一套，迟早在缩放/居中上漂移（本项目已经栽过两次同类问题：
   * printerSlot 与内容签名不一致、Dotii 页号漏出签名）。
   *
   * 原实现有一处隐患：`innerY` 用**未缩放**的 DOTII_H(418) 算居中。
   * 当前档位 h 恰为 434 时看不出来，但若格高不是 434（如 V.prH=178），
   * 就会明显偏上。这里改用**缩放后**的 drawH —— 对 h=434 结果不变。
   *
   * @param cellX 格子左沿（屏幕坐标）
   * @param y     格子上沿
   * @param w     格子宽
   * @param h     格子高
   * @returns [innerX, innerY, scale] —— 调用方 translate+scale 后按 368×448 画
   */
  static layout(cellX: number, y: number, w: number, h: number): number[] {
    const padX = 10;
    const room = w - padX * 2;
    // 装得下就 1:1（× DOTII_SCALE）；装不下才等比缩到格内
    const fit = Math.min(1, room / DOTII_WANT);
    const drawW = DOTII_WANT * fit;
    const drawH = DOTII_H * fit;
    return [cellX + (w - drawW) / 2, y + (h - drawH) / 2, DOTII_SCALE * fit];
  }

  static render(ctx: CanvasRenderingContext2D, st: DotiiState, nowMs: number,
                info: DotiiCellInfo, pr: PrinterInfo | undefined,
                vig: number = 0, vigReach: number = 620, vigCorner: number = 0,
                mode: number = 1): void {
    const y = L.panelY;
    const h = L.panelHeight;
    const cellX = DotiiCellGeom.x(mode);
    const cellW = DotiiCellGeom.w(mode);

    // ---- 本格底板：纯黑（Dotii 是黑底 UI）----
    ctx.fillStyle = '#000000';
    ThemeDotiiCell.roundRect(ctx, cellX, y, cellW, h, 14);
    ctx.fill();
    ctx.strokeStyle = '#262A3A';
    ctx.lineWidth = 1;
    ThemeDotiiCell.roundRect(ctx, cellX + 0.5, y + 0.5, cellW - 1, h - 1, 14);
    ctx.stroke();

    // ---- 落位：与"打印机格表情槽"共用同一个函数（见 layout 注释）----
    const lay: number[] = ThemeDotiiCell.layout(cellX, y, cellW, h);
    const innerX: number = lay[0];
    const innerY: number = lay[1];
    const k: number = lay[2];

    ctx.save();
    ctx.translate(innerX, innerY);
    ctx.scale(k, k);
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, 368, 448);
    ThemeDotii.renderPages(ctx, st, nowMs);      // 复用主题 5 的页面渲染
    ctx.restore();

    // ---- 右侧窄信息栏：打印机实时数据 ----
    // 信息栏已取消（占位太窄、画出来也没意义，用户要求把那块黑边缩掉）。
    // 数据仍由 prepareDotiiCellInfo() 备好，将来若要恢复信息栏，直接调 infoBar 即可。
    void info;

    Chrome.vignette(ctx, 1920, 462, vig, vigReach, vigCorner);
    void pr;
  }

  /** 右侧信息栏：真实打印机/余额数据 */
  private static infoBar(ctx: CanvasRenderingContext2D, x: number, y: number,
                         w: number, h: number, info: DotiiCellInfo): void {
    if (w < 40) {
      return;   // 格太窄就放弃信息栏，保证 Dotii 内容优先
    }
    ctx.fillStyle = '#0E1418';
    ThemeDotiiCell.roundRect(ctx, x, y, w, h, 10);
    ctx.fill();

    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#00AE42';
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText('打印机', x + 10, y + 24);

    const rows: string[][] = [
      ['状态', info.prState.length > 0 ? info.prState : '--'],
      ['进度', info.prPct >= 0 ? `${info.prPct}%` : '--'],
      ['喷嘴', info.prNozzle >= 0 ? `${info.prNozzle.toFixed(0)}°` : '--'],
      ['热床', info.prBed >= 0 ? `${info.prBed.toFixed(0)}°` : '--'],
      ['层', info.prLayer >= 0 ? `${info.prLayer}` : '--'],
      ['剩余', info.prRemainText],
      ['AMS', `${info.trays}`],
      ['余额', info.balance]
    ];
    const step = Math.min(46, Math.max(28, (h - 80) / rows.length));
    let ry = y + 58;
    for (const r of rows) {
      ctx.fillStyle = '#8C94A8';
      ctx.font = 'bold 18px sans-serif';
      ctx.fillText(r[0], x + 10, ry);
      ctx.textAlign = 'right';
      ctx.fillStyle = '#E6EBF5';
      ctx.font = 'bold 20px monospace';
      ctx.fillText(ThemeDotiiCell.fit(ctx, r[1], w - 24), x + w - 10, ry);
      ctx.textAlign = 'left';
      ry += step;
    }
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
