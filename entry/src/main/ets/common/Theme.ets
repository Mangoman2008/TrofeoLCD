/**
 * Theme.ets — 视觉令牌（深色控制台风，取自 mac-thermalright-ai-monitor 的设计基准）
 */

export class C {
  static readonly bgTop: string = '#0A0C14';
  static readonly bgBot: string = '#10121C';
  static readonly panel: string = '#141722';
  static readonly panelHi: string = '#1A1E2C';
  static readonly border: string = '#262A3A';

  static readonly textW: string = '#E6EBF5';
  static readonly textS: string = '#8C94A8';
  static readonly textL: string = '#646C82';
  static readonly textD: string = '#464C5F';

  static readonly blue: string = '#4285F4';
  static readonly green: string = '#34D399';
  static readonly orange: string = '#FBBF24';
  static readonly red: string = '#EF4444';
  static readonly purple: string = '#A78BFA';
  static readonly cyan: string = '#22D3EE';
  static readonly magenta: string = '#D946EF';
  /** DeepSeek 品牌蓝，用作 DSH 面板强调色 */
  static readonly deepseek: string = '#4D6BFE';

  static readonly barBg: string = '#1E2230';

  static byPercent(pct: number): string {
    if (pct < 50) {
      return C.green;
    }
    if (pct < 75) {
      return C.orange;
    }
    return C.red;
  }
}

export class L {
  /** 整帧宽度（设备要求 1920） */
  static readonly width: number = 1920;
  /**
   * 整帧高度 = 462（Trofeo Vision 9.16）。
   *
   * 原来写 480（电商页面的宣传值），已被两份一手证据推翻：
   *   · 官方 TRCC 2.1.8 的型号/主题表只有 1920X462 / 1920X440，**没有 1920X480**
   *     （TRCCCAP/Data/USBLCD/Theme1920462、Theme1920440）
   *   · 同型号开源驱动 haven80/trofeo-lcd-rs（crate trofeo_lcd 1.0.50，2026-10 仍在维护）
   *     明确写 "trofeo-9.16 (default, 1920x462)"
   * 结论：按 480 推帧会被屏裁掉/压扁 18 行。
   */
  static readonly height: number = 462;
  static readonly margin: number = 14;
  static readonly gap: number = 10;
  static readonly panelCount: number = 5;

  /**
   * 仪表盘占用宽度：右侧 L.vmWidth 让给 VM 画面。
   * 之前是整个 1920，现在右侧 480×480 交给 VM 监视画面。
   */
  static readonly vmWidth: number = 480;
  static readonly dashWidth: number = L.width - L.vmWidth;   // 1440

  static readonly panelWidth: number =
    (L.dashWidth - 2 * L.margin - (L.panelCount - 1) * L.gap) / L.panelCount;
  static readonly panelHeight: number = L.height - 2 * L.margin;
  static readonly panelY: number = L.margin;

  /** 面板 X 坐标（基于仪表盘区宽度） */
  static panelX(index: number): number {
    return L.margin + index * (L.panelWidth + L.gap);
  }

  /** VM 画面区域（含外边距，右侧贴边留 L.margin 空隙） */
  static readonly vmX: number = L.dashWidth + L.gap;
  static readonly vmY: number = L.margin;
  static readonly vmW: number = L.vmWidth - L.gap - L.margin;
  static readonly vmH: number = L.height - 2 * L.margin;

  /**
   * ★ 打印机面板的落点：从 **DSH 面板** 借一格（3 格 → 2 格），不碰 VM。
   *
   * 用户明确要求："不能压缩 VM 的空间，从 WorkBuddy 那里腾地"。
   * 所以：
   *   · VM 面板恢复整列（vmH 全高，不再上下切）→ 画面按 1680x1120 的原始比例居中，不被压扁
   *   · DSH 会话面板由 3 格缩到 2 格
   *   · 腾出来的这一格（index 3）正好放打印机面板，与系统/用量同宽同高，设计语言一致
   * 网格总数仍是 5 格（系统1 + DSH2 + 打印机1 + 用量1），所以系统/用量面板宽度一点没变。
   */
  static readonly prX: number = L.panelX(4);   // 旧落点：面板等宽时用（保留给 usPanelVisible=true 那档）
  /** 用量面板的位置（与打印机对调后由 4 变 3） */
  static readonly usX: number = L.panelX(3);
  static readonly prY: number = L.panelY;
  /** 旧宽度：面板等宽那一档（274.4） */
  static readonly prWGrid: number = L.panelWidth;
  static readonly prH: number = L.panelHeight;

  /**
   * ★★ 打印机面板加宽档（隐藏 USAGE 那一档）——用户 2026-10-14 定的「方案⑥b」。
   *
   * 起因：源画布（Dotii 368×448）在 274.4 宽的格子里只能 0.86×，字样和砖块都糊。
   * 用户要求："把 USAGE 隐藏，打印机把它的横向空间占了"。
   *
   * 于是：
   *   · USAGE 面板整个不画（usPanelVisible = false），腾出 panelWidth 274.4 + gap 10 = 284.4
   *   · 再从 DSH 会话面板借 163.6，把打印机格做成 **448 宽**
   *   · 448 = 源画布的纵向像素数，434 = 面板高（462 − 2×14）
   *     → 源画布按 1:1 放进去：368 宽居中（左右各空 40），448 高被 434 裁掉正中 14 行边缘留白
   *   · VM 面板坐标一个像素都不动（vmX 1450 / vmW 456），仍是整列
   *
   * 坐标：系统 14(274.4) | DSH 298.4(659.6) | 打印机 968(448) | VM 1450(456)
   *       968 + 448 = 1416，距 VM 左沿 1450 还有 34 的空隙，不会压到 VM
   */
  static readonly usPanelVisible: boolean = true;
  /** 打印机格宽度。① 等宽档 = panelWidth(274.4)；⑥b 加宽档 = 448（把下面这行改成 448，
   *  同时把 usPanelVisible 改成 false，就回到「隐藏 USAGE + 打印机 448 宽」那版） */
  static readonly prW: number = L.panelWidth;
  /** 打印机格左沿：从 VM 左侧往左留一个 gap 再减面板宽 */
  static readonly prXWide: number = L.dashWidth - L.gap - L.prW;   // 1440 − 10 − 448 = 982
  /** DSH 会话面板在加宽档下的宽度：系统面板左沿 → 打印机格左沿，去掉面板自身与两个 gap */
  static readonly agentWWide: number = L.prXWide - L.gap - L.panelX(1);
  /** DSH 面板右沿，供审计核对（应 = prXWide − gap = 972） */
  static readonly agentRightWide: number = L.panelX(1) + L.agentWWide;

  /** 打印机格内源画布的落点（1:1，横向居中） */
  static readonly prSrcW: number = 368;
  static readonly prSrcX: number = L.prXWide + (L.prW - L.prSrcW) / 2;   // 982 + 40 = 1022

  /** VM 面板高度 = 整列（有打印机时也不再切分） */
  static readonly vmHSplit: number = L.vmH;
}

/** 竖装布局（面板竖过来：逻辑空间 462×1920，绘制时整体旋转 90°） */
export class V {
  /** 竖装：宽 = 帧高 462，长 = 帧宽 1920（绘制时整体旋转 90°） */
  static readonly width: number = 462;
  static readonly height: number = 1920;
  static readonly margin: number = 14;
  /** 各分段（已算好，合计正好 1920） */
  static readonly hdrY: number = 14;
  static readonly hdrH: number = 116;
  static readonly vmY: number = 140;
  static readonly vmH: number = 480;
  static readonly sysY: number = 630;
  static readonly sysH: number = 380;
  static readonly agY: number = 1020;
  static readonly agH: number = 540;
  static readonly usY: number = 1570;
  static readonly usH: number = 336;
  /** 内容宽度 */
  static innerW(): number {
    return V.width - 2 * V.margin;
  }

  /** 竖装也把"VM 画面 + 打印机卡片"拆成上下两块（见 L.vmHSplit 的说明） */
  static readonly vmHSplit: number = 190;   // 同上：给打印机卡片让高度
  static readonly prY: number = V.vmY + V.vmHSplit + 16;             // 436
  static readonly prH: number = V.sysY - 16 - V.prY;                 // 178
}

/**
 * 打印机卡片（拓竹）内部布局。
 * 位置一律用"卡片高度的比例"表达：横屏卡 152 高、竖屏卡 178 高，
 * 同一套比例两边都放得下，也不会有哪一边算出越界的行。
 */
export class P {
  static readonly pad: number = 18;
  /** 五行文字的纵向比例 */
  // 行位置原本按 134px 高的卡片定（0.19≈y+26），1.8× 字号下卡片加高到 ~184px，
  // 而标题仍固定在 y+14..48 —— 所以内容整体下移到 0.33 起，末行贴近底边 0.97
  // rTitle = 与面板标题同一行（标题在 y+31，卡片高 188 时约 0.165）；
  // 其余四行依次往下，末行必须 ≤0.82，否则 1.8× 的字会越出卡片底边（审计实测过）
  static readonly rTitle: number = 0.14;
  static readonly rPct: number = 0.42;
  static readonly rBar: number = 0.605;
  static readonly rJob: number = 0.737;
  static readonly rTemps: number = 0.886;
  /** 右侧 AMS 托盘列 */
  static readonly trayColW: number = 132;
  static readonly trayTop: number = 0.40;
  static readonly trayPitch: number = 0.22;
  /** 一次最多画几个托盘（再多就显示 +N） */
  static readonly trayMax: number = 4;

  static row(y: number, h: number, frac: number): number {
    return y + h * frac;
  }
}

export class F {
  static readonly sans: string = 'sans-serif';
  static readonly mono: string = 'monospace';

  /**
   * 字号总系数。
   *
   * 真机反馈"字体有点小、看得费劲"：这块屏是 9.16 寸 1920×462，横向 8.5 px/mm，
   * 原来正文 16~17px 只有约 2mm 字高，桌面距离看确实吃力。这里统一放大，
   * 所有字号仍按"16/17/19…"写，改这一个数就整体缩放（位置不变，靠排版审计查重叠）。
   */
  static readonly scale: number = 2.5;

  /**
   * 次要信息的字号系数（分级字号）。
   *
   * 起因：统一放大到 2.5× 后面板装不下，只能砍信息（负载/主机名/上下文/日期/作业名…），
   * 用户反馈"很多字都看不到了"。改成两级：**重要的按 scale（2.5×）**，
   * **次要的按 scaleSub（2.0×）** —— 既保住大字的可读性，又把信息量找回来。
   */
  static readonly scaleSub: number = 2.0;

  static font(size: number, weight: string): string {
    return `${weight} ${Math.round(size * F.scale)}px ${F.sans}`;
  }

  static monoFont(size: number, weight: string): string {
    return `${weight} ${Math.round(size * F.scale)}px ${F.mono}`;
  }

  /** 次要信息（用 scaleSub） */
  static fontSub(size: number, weight: string): string {
    return `${weight} ${Math.round(size * F.scaleSub)}px ${F.sans}`;
  }

  static monoSub(size: number, weight: string): string {
    return `${weight} ${Math.round(size * F.scaleSub)}px ${F.mono}`;
  }
}
