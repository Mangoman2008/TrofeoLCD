/**
 * Theme.cs — 视觉令牌（深色控制台风，取自 mac-thermalright-ai-monitor 的设计基准）
 *
 * 与鸿蒙版 entry/src/main/ets/common/Theme.ets 一一对应：
 *   C（颜色） / L（横屏布局） / V（竖屏布局） / F（字体）
 * ArkTS 侧用 '#RRGGBB' 字符串，这里换成 System.Drawing.Color；
 * ArkTS 侧用 `sans-serif` / `monospace` 字体名，这里换成
 * "Microsoft YaHei"（必须能显示中文）与 "Consolas"。
 *
 * 编译约束：.NET Framework 的 csc（C# 5 语法上限），所以没有字符串插值、
 * 没有表达式体成员、没有自动属性初始化器。
 */
using System;
using System.Collections.Generic;
using System.Drawing;

namespace DshLcd
{
    /// <summary>颜色令牌（对应 Theme.ets 的 class C）</summary>
    public static class C
    {
        public static readonly Color BgTop = Hex("#0A0C14");
        public static readonly Color BgBot = Hex("#10121C");
        public static readonly Color Panel = Hex("#141722");
        public static readonly Color PanelHi = Hex("#1A1E2C");
        public static readonly Color Border = Hex("#262A3A");

        public static readonly Color TextW = Hex("#E6EBF5");
        public static readonly Color TextS = Hex("#8C94A8");
        public static readonly Color TextL = Hex("#646C82");
        public static readonly Color TextD = Hex("#464C5F");

        public static readonly Color Blue = Hex("#4285F4");
        public static readonly Color Green = Hex("#34D399");
        public static readonly Color Orange = Hex("#FBBF24");
        public static readonly Color Red = Hex("#EF4444");
        public static readonly Color Purple = Hex("#A78BFA");
        public static readonly Color Cyan = Hex("#22D3EE");
        public static readonly Color Magenta = Hex("#D946EF");
        /// <summary>DeepSeek 品牌蓝，用作 DSH 面板强调色</summary>
        public static readonly Color Deepseek = Hex("#4D6BFE");

        public static readonly Color BarBg = Hex("#1E2230");

        /// <summary>状态徽章上的近黑文字（Dashboard.ets 里直接写死的 '#08090F'）</summary>
        public static readonly Color BadgeText = Hex("#08090F");

        /// <summary>照抄 C.byPercent：&lt;50 绿 / &lt;75 橙 / 其余红</summary>
        public static Color ByPercent(double pct)
        {
            if (pct < 50)
            {
                return Green;
            }
            if (pct < 75)
            {
                return Orange;
            }
            return Red;
        }

        /// <summary>'#RRGGBB' 或 '#AARRGGBB' → Color（ArkTS 侧的颜色字面量原样搬过来）</summary>
        public static Color Hex(string hex)
        {
            if (string.IsNullOrEmpty(hex))
            {
                return Color.Black;
            }
            string s = hex.Trim();
            if (s.Length > 0 && s[0] == '#')
            {
                s = s.Substring(1);
            }
            try
            {
                if (s.Length == 6)
                {
                    int rgb = int.Parse(s, System.Globalization.NumberStyles.HexNumber,
                        System.Globalization.CultureInfo.InvariantCulture);
                    return Color.FromArgb(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
                }
                if (s.Length == 8)
                {
                    uint argb = uint.Parse(s, System.Globalization.NumberStyles.HexNumber,
                        System.Globalization.CultureInfo.InvariantCulture);
                    return Color.FromArgb((int)((argb >> 24) & 0xFF), (int)((argb >> 16) & 0xFF),
                        (int)((argb >> 8) & 0xFF), (int)(argb & 0xFF));
                }
            }
            catch (Exception)
            {
            }
            return Color.Black;
        }

        /// <summary>Color → '#RRGGBB'（日志/自检里对照 ArkTS 用）</summary>
        public static string ToHex(Color c)
        {
            return string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "#{0:X2}{1:X2}{2:X2}", c.R, c.G, c.B);
        }
    }

    /// <summary>横屏布局（对应 Theme.ets 的 class L；1920×462，5 列网格）</summary>
    public static class L
    {
        /// <summary>整帧宽度（设备要求 1920）</summary>
        public const double Width = 1920;
        /// <summary>
    /// 帧高 = 462（Trofeo Vision 9.16）。
    /// 原来写 480（电商页宣传值），已被两份一手证据推翻：
    ///   · 官方 TRCC 2.1.8 的型号/主题表只有 1920X462 / 1920X440，没有 1920X480
    ///   · 同型号开源驱动 haven80/trofeo-lcd-rs 写明 "trofeo-9.16 (default, 1920x462)"
    /// </summary>
    public const double Height = 462;
        public const double Margin = 14;
        public const double Gap = 10;
        public const int PanelCount = 5;

        /// <summary>仪表盘右侧让给 VM 画面的宽度</summary>
        public const double VmWidth = 480;
        public const double DashWidth = Width - VmWidth;   // 1440

        public const double PanelWidth =
            (DashWidth - 2 * Margin - (PanelCount - 1) * Gap) / PanelCount;
        public const double PanelHeight = Height - 2 * Margin;
        public const double PanelY = Margin;

        /// <summary>面板 X 坐标（基于仪表盘区宽度）</summary>
        public static double PanelX(int index)
        {
            return Margin + index * (PanelWidth + Gap);
        }

        /// <summary>VM 画面区域（含外边距，右侧贴边留 Margin 空隙）</summary>
        public const double VmX = DashWidth + Gap;
        public const double VmY = Margin;
        public const double VmW = VmWidth - Gap - Margin;
        public const double VmH = Height - 2 * Margin;

        // 有打印机数据时右侧一列拆两块（对齐 Theme.ets 的 L.vmHSplit/prY/prH）
        public const double VmHSplit = 290;
        public const double PrY = VmY + VmHSplit + Gap;          // 314
        public const double PrH = Height - Margin - PrY;         // 152

        // ==========================================================
        // v6 定稿版面（2026-10-14 用户选定："就这个定格吧"）
        //   逐值与 ArkTS `render/ThemeDotiiCell.ets` 的 FINAL_* 常量一致 —— 两边必须同源，
        //   否则同一主题在两个平台上长得不一样（本工程已有"两份几何常量"的先例问题）。
        //
        //   宽度账（整条可用 1906）：
        //     SYSTEM 274.4 │ DSH 398 │ USAGE 300 │ VM 424 │ Dotii 409
        //     + margin 14×2 + gap 10×4 = 1906 ✅
        //   用户原话："对调后 DSH 可以对应缩小，VM 画面不变、usage 画面不变，
        //             但 VM 你要贴着 dotti 的边缘绘画"
        //   → 缺口是**从 DSH 会话扣的**（847.2 → 398），这是解开约束的关键。
        // ==========================================================
        /// <summary>v6：Dotii 在最右（右沿 1859，不碰 1906 边）</summary>
        public const double FinalDotiiX = 1450;
        public const double FinalDotiiW = 409;
        /// <summary>v6：USAGE 位置与尺寸**不变**</summary>
        public const double FinalUsageX = 706;
        public const double FinalUsageW = 300;
        /// <summary>v6：VM 面板（右沿 1440，与 Dotii 之间留 10px）</summary>
        public const double FinalVmX = 1016;
        public const double FinalVmW = 424;
        /// <summary>v6：DSH 会话缩小，把宽度让给 VM</summary>
        public const double FinalDshW = 398;

        /// <summary>v4 档：USAGE 右移到 Dotii 左边，DSH 吃掉中间空白</summary>
        public const double V4UsageX = 721;
        public const double V4UsageW = 300;
        public const double V4DshW = 412.6;
        /// <summary>
        /// 借位档（ArkTS cellLayout=1，主题 9「打印机位 Dotii」＋ cellLayout=2）：
        /// 逐值对齐 `ThemeDotiiCell.ets` 的 `CELL_X/CELL_W/USAGE_X/USAGE_W`。
        ///   SYSTEM 14(274.4) │ DSH 余下(427) │ USAGE 721(300) │ Dotii 1031(409)
        ///   + margin 14×2 + gap 10×3 = 1859 ✅
        /// **原始打印机格只有 274.4 宽，装不下 409 的 Dotii** → 必须借位（从 DSH 挪）。
        /// </summary>
        public const double CellBorrowX = 1031;
        public const double CellBorrowW = 409;
        public const double UsageBorrowX = 721;
        public const double UsageBorrowW = 300;

        /// <summary>对调档（mode 3/5）：Dotii 落在第五格</summary>
        public const double SwapCellX = 1450;
        public const double SwapCellW = 456;
    }

    /// <summary>竖装布局（对应 Theme.ets 的 class V；逻辑空间 462×1920，绘制时整体旋转 90°）</summary>
    public static class V
    {
        public const double Width = 462;
        public const double Height = 1920;
        public const double Margin = 14;
        /// <summary>各分段（已算好，合计正好 1920）</summary>
        public const double HdrY = 14;
        public const double HdrH = 116;
        public const double VmY = 140;
        public const double VmH = 480;
        public const double SysY = 630;
        // 竖装也拆两块（对齐 Theme.ets 的 V.vmHSplit/prY/prH）
        public const double VmHSplit = 280;
        public const double PrY = VmY + VmHSplit + 16;            // 436
        public const double PrH = SysY - 16 - PrY;                // 178
        public const double SysH = 380;
        public const double AgY = 1020;
        public const double AgH = 540;
        public const double UsY = 1570;
        public const double UsH = 336;

        /// <summary>内容宽度</summary>
        public static double InnerW()
        {
            return Width - 2 * Margin;
        }
    }

    /// <summary>
    /// 打印机卡片内部布局（对齐 Theme.ets 的 class P）。
    /// 位置一律用卡片高度的比例表达：横屏卡 152 高、竖屏卡 178 高，一套比例两边都放得下，
    /// 也不会有哪一边算出越界的行。
    /// </summary>
    public static class P
    {
        public const double Pad = 18;
        public const double RTitle = 0.19;
        public const double RPct = 0.40;
        public const double RBar = 0.58;
        public const double RJob = 0.76;
        public const double RTemps = 0.94;
        public const double TrayColW = 132;
        public const double TrayTop = 0.28;
        public const double TrayPitch = 0.20;
        public const int TrayMax = 4;

        public static double Row(double y, double h, double frac)
        {
            return y + h * frac;
        }
    }

    /// <summary>
    /// 字体（对应 Theme.ets 的 class F）。
    /// ArkTS 用 'sans-serif' / 'monospace' 两个逻辑字体名，C# 侧映射到
    /// "Microsoft YaHei"（中文必须能显示）与 "Consolas"。
    ///
    /// Font 是按 (字体族, 像素尺寸, 粗细) 缓存的静态对象 —— 每帧 new 几十个 Font
    /// 会很快耗光 GDI 句柄。缓存对象**不要 Dispose**；要释放请调 ClearCache()。
    /// </summary>
    public static class F
    {
        /// <summary>ArkTS 逻辑字体名（保留，便于和鸿蒙版对照）</summary>
        public const string Sans = "sans-serif";
        public const string Mono = "monospace";

        /// <summary>字号总系数 —— 与 Theme.ets 的 F.scale 必须一致（真机反馈字太小）。
        /// 调用方仍按 16/17/19… 写字号，这里统一乘。</summary>
        public const double Scale = 1.35;

        private const string SansFamily = "Microsoft YaHei";
        private const string MonoFamily = "Consolas";

        private static readonly Dictionary<string, Font> Cache = new Dictionary<string, Font>();
        private static readonly object Gate = new object();

        /// <summary>等宽字体（Consolas），ArkTS 的 F.monoFont 等价物。
        /// 注意：这里乘 Scale —— 与 ArkTS 的 F.monoFont 行为一致。</summary>
        public static Font MonoFont(double size, bool bold)
        {
            return Get(MonoFamily, size * Scale, bold, FontFamily.GenericMonospace);
        }

        /// <summary>中文正文字体（微软雅黑），ArkTS 的 F.font 等价物。
        /// 注意：这里乘 Scale —— 与 ArkTS 的 F.font 行为一致。</summary>
        public static Font SansFont(double size, bool bold)
        {
            return Get(SansFamily, size * Scale, bold, FontFamily.GenericSansSerif);
        }

        /// <summary>仅用于日志：还原 ArkTS 的 F.font(size, weight) 字符串</summary>
        public static string FontSpec(double size, string weight)
        {
            return weight + " " + size.ToString(System.Globalization.CultureInfo.InvariantCulture)
                + "px " + Sans;
        }

        /// <summary>仅用于日志：还原 ArkTS 的 F.monoFont(size, weight) 字符串</summary>
        public static string MonoFontSpec(double size, string weight)
        {
            return weight + " " + size.ToString(System.Globalization.CultureInfo.InvariantCulture)
                + "px " + Mono;
        }

        /// <summary>已缓存的字体个数（自检/日志用）</summary>
        public static int CacheCount()
        {
            lock (Gate)
            {
                return Cache.Count;
            }
        }

        /// <summary>释放并清空字体缓存（正常帧循环里不要调）</summary>
        public static void ClearCache()
        {
            lock (Gate)
            {
                foreach (KeyValuePair<string, Font> kv in Cache)
                {
                    try { kv.Value.Dispose(); }
                    catch (Exception) { }
                }
                Cache.Clear();
            }
        }

        private static Font Get(string family, double size, bool bold, FontFamily fallback)
        {
            float px = (float)size;
            if (px < 1f)
            {
                px = 1f;
            }
            if (px > 400f)
            {
                px = 400f;
            }
            string key = family + "|" + px.ToString("F2", System.Globalization.CultureInfo.InvariantCulture)
                + "|" + (bold ? "b" : "n");
            lock (Gate)
            {
                Font f;
                if (Cache.TryGetValue(key, out f))
                {
                    return f;
                }
                FontStyle style = bold ? FontStyle.Bold : FontStyle.Regular;
                try
                {
                    f = new Font(family, px, style, GraphicsUnit.Pixel);
                }
                catch (Exception)
                {
                    // 系统里没有这个字体族：退到 GDI+ 通用族，绝不因为字体问题整帧崩掉
                    f = new Font(fallback, px, style, GraphicsUnit.Pixel);
                }
                Cache[key] = f;
                return f;
            }
        }
    }
}
