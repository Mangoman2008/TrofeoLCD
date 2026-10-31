/**
 * ThemeDotii.cs — Dotii 分页屏（C# 5 移植版，对应 ArkTS 主题 5 / v6 版面的最右格）
 *
 * 逐值移植自 `entry/src/main/ets/render/ThemeDotii.ets`（552 行）与
 * `ThemeDotiiCell.ets`（272 行）。**几何与配色必须与 ArkTS 一致** —— 两边不一致会让
 * 同一主题在两个平台上长得不一样。
 *
 * ## 源信息（ArkTS 文件头记录的）
 * 源固件是 ESP32-S3 / LVGL 368×448 的 UI，本移植按 ×0.9333 等比（DOTII_SCALE）。
 * 4 页：表情 / 余额 / 打印机(Bambu) / 自定义，每页 10s 轮播（源只有表情 10s 一换）。
 * 配色取自源 `state_ui.c:51-63` 的 `COLOR_*` 宏。
 *
 * ⚠️ 语言上限 **C# 5**：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace DshLcd
{
    /// <summary>Dotii 源画布与缩放（对齐 ArkTS 的 kW/kH/DOTII_SCALE）</summary>
    public static class DotiiGeom
    {
        public const double KW = 368;      // 源画布宽
        public const double KH = 448;      // 源画布高
        public const double Scale = 0.9333;                 // 源 → 本屏的等比
        public const double W = KW * Scale;                 // 343.5
        public const double H = KH * Scale;                 // 418.1
        public const int Pages = 4;
        public static readonly string[] PageNames = new string[] { "表情", "余额", "打印机", "自定义" };
    }

    /// <summary>源 `state_ui.c:51-63` 的 COLOR_* 配色</summary>
    public static class DotiiColors
    {
        public static readonly Color Bg = Color.FromArgb(0x00, 0x00, 0x00);
        public static readonly Color Surface = Color.FromArgb(0x14, 0x1A, 0x19);
        public static readonly Color Text = Color.FromArgb(0xF1, 0xF8, 0xF5);
        public static readonly Color Muted = Color.FromArgb(0x8E, 0x9B, 0x97);
        public static readonly Color Blue = Color.FromArgb(0x5D, 0xA9, 0xFF);
        public static readonly Color Cyan = Color.FromArgb(0x20, 0xD6, 0xE6);
        public static readonly Color Green = Color.FromArgb(0x42, 0xD9, 0x8C);
        public static readonly Color Bambu = Color.FromArgb(0x00, 0xAE, 0x42);
        public static readonly Color Warning = Color.FromArgb(0xF2, 0xC6, 0x6D);
        public static readonly Color Danger = Color.FromArgb(0xFF, 0x76, 0x6F);
        public static readonly Color Divider = Color.FromArgb(0x38, 0x40, 0x3E);
        public static readonly Color TrackBambu = Color.FromArgb(0x09, 0x2A, 0x16);
        public static readonly Color TrackCustom = Color.FromArgb(0x2B, 0x2D, 0x28);
        public static readonly Color DotOff = Color.FromArgb(0x59, 0x60, 0x5E);
        public static readonly Color StatusBg = Color.FromArgb(0x15, 0x1A, 0x19);
        public static readonly Color FaceWarm = Color.FromArgb(0xF4, 0xEA, 0xD2);
        public static readonly Color FaceAmber = Color.FromArgb(0xF2, 0xC6, 0x6D);
        public static readonly Color FaceCyan = Color.FromArgb(0x58, 0xC8, 0xC8);
        public static readonly Color FaceCoral = Color.FromArgb(0xFF, 0x82, 0x7A);
        /// <summary>页面圆点高亮色（源 `state_ui.c:834`：CYAN / BLUE / BAMBU / WARNING）</summary>
        public static readonly Color[] PageColors = new Color[]
        { Cyan, Blue, Bambu, Warning };
    }

    /// <summary>
    /// Dotii 状态（对齐 ArkTS 的 `DotiiState`）。
    /// C# 侧由 `ThemeDotii.FromState()` 从 `State` 的遥测填出来。
    /// </summary>
    public class DotiiState
    {
        public int Page;
        public int Expr;
        public int Hour;
        public int Minute;

        // 余额页（源 s_balance 是"字符串原样显示"）
        public string BalanceTotal = "--";
        public string BalanceGranted = "--";
        public string BalanceTopped = "--";
        /// <summary>胶囊状态机文案：可用/离线/未接入/预览数据/不可用/密钥无效/获取失败</summary>
        public string BalanceStatus = "离线";
        public bool BalanceHasValue;

        // Bambu 页
        public string PrState = "";
        public double PrPct = -1;
        public string PrStatusText = "离线";
        public string PrRemainText = "--";
        public string PrFinishText = "--";
        public double PrNozzle = -1;
        public double PrBed = -1;
        public double PrLayer = -1;
        public double PrTotalLayer = -1;

        // 底部状态栏（源只挂余额页）
        public bool WifiOn;
        public bool WifiConnecting;
        public string ConnText = "";
        public double Batt = -1;
        public bool Charging;

        // 自定义页（源无百分比，是标题/值/正文/页脚四段文本）
        public string CustomTitle = "我的页面";
        public string CustomValue = "";
        public string CustomBody = "";
        public string CustomFooter = "";

        public static DotiiState FromState(State st)
        {
            DotiiState d = new DotiiState();
            DateTime now = DateTime.Now;
            d.Hour = now.Hour;
            d.Minute = now.Minute;
            if (st == null || st.Data == null) return d;

            // 页面轮播：4 页 × 10s（对齐 ArkTS 的 DOTII_PAGE_MS）
            d.Page = (int)((State.NowMs() / 10000) % DotiiGeom.Pages);
            // 表情按遥测的 agent 状态映射（源固件是 8 张表情轮播）
            d.Expr = FromAgentState(st.Data.Agent);

            BalanceInfo b = st.Data.Balance;
            if (b != null)
            {
                d.BalanceHasValue = b.Total >= 0 && string.IsNullOrEmpty(b.Error);
                d.BalanceTotal = b.Total >= 0 ? b.Total.ToString("0.00") : "--";
                d.BalanceGranted = b.Granted >= 0 ? b.Granted.ToString("0.00") : "--";
                d.BalanceTopped = b.ToppedUp >= 0 ? b.ToppedUp.ToString("0.00") : "--";
                if (!string.IsNullOrEmpty(b.Error)) d.BalanceStatus = "获取失败";
                else if (b.Available.HasValue && !b.Available.Value) d.BalanceStatus = "不可用";
                else if (b.Total >= 0) d.BalanceStatus = "可用";
                else d.BalanceStatus = "离线";
            }

            PrinterInfo p = st.Data.Printer;
            if (p != null)
            {
                d.PrState = p.State;
                d.PrPct = p.Percent;
                d.PrBed = p.BedTemp;            // ★ 原来漏了（ArkTS LcdService.ets:731 有）
                // ★ 2026-10-15：文案改成**自己映射 state**，对齐 ArkTS 的状态机
                //   （LcdService.ets:735-749）。原来直接用 `p.StateLabel` 有两个问题：
                //     ① 漏了「监控未登录」分支 —— 凭据出错时显示成"离线"，会误导用户去查打印机
                //     ② 文案依赖桥端 stateLabel 的取值，桥一变就漂移
                d.PrStatusText = DotiiPrinterStatus(p);
                d.PrLayer = p.Layer;
                d.PrTotalLayer = p.TotalLayer;
                d.PrNozzle = p.NozzleTemp;
                if (p.RemainingSec >= 0)
                {
                    d.PrRemainText = string.Format("{0}h{1:00}m", p.RemainingSec / 3600,
                                                   (p.RemainingSec % 3600) / 60);
                }
                if (p.Eta.Length > 0) d.PrFinishText = p.Eta;
            }
            return d;
        }

        /// <summary>
        /// 打印机状态 → 胶囊文案。逐条对齐 ArkTS `LcdService.prepareDotiiState()`：
        ///   monitorMode == "error" 或 monitorError 非空 → 「监控未登录」
        ///   RUNNING/PREPARE/PAUSE/FINISH/FAILED/OFFLINE（或空）→ 对应中文，其余 → 「待机」
        ///
        /// 「监控未登录」必须排最前：那是**凭据问题**（监控服务没登录云端），
        /// 不是打印机离线 —— 用户该去重新登录，而不是检查打印机。
        /// </summary>
        private static string DotiiPrinterStatus(PrinterInfo p)
        {
            if (p.MonitorMode == "error" || (p.MonitorError != null && p.MonitorError.Length > 0))
                return "监控未登录";
            string s = p.State == null ? "" : p.State;
            if (s == "RUNNING") return "打印中";
            if (s == "PAUSE") return "已暂停";
            if (s == "PREPARE") return "准备中";
            if (s == "FINISH") return "已完成";
            if (s == "FAILED") return "失败";
            if (s == "OFFLINE" || s.Length == 0) return "离线";
            return "待机";
        }

        /// <summary>agent 状态 → 表情号（0 idle_breath / 4 connecting / 5 working / 6 complete / 7 failure）</summary>
        private static int FromAgentState(AgentInfo ag)
        {
            if (ag == null) return 0;
            string s = ag.State;
            if (s == "busy") return 5;         // working
            if (s == "waiting") return 4;      // connecting
            if (s == "idle") return 0;         // idle_breath
            if (s == "error") return 7;        // failure
            return 0;
        }
    }

    public static class ThemeDotii
    {
        /// <summary>
        /// 字号系数：把 ArkTS 源码里的原始字号换算成 C# 这边的等效字号。
        ///
        /// ★ 2026-10-15 修正。原因：两边的字号缩放基准**不一样** ——
        ///     ArkTS: `F.font(48)` = 48 × `F.scale`(2.5) = 120px
        ///     C#   : `Sans(48)` = 48 × `F.Scale`(1.35) = 64.8px
        ///   我移植时直接照抄了 ArkTS 源码里的数字（48/40/88/96…），
        ///   结果每处都多出 2.5/1.35 = 1.85 倍，再经 Dotii 的 0.9333 变换后
        ///   **实际字号比鸿蒙版大 35%**（用户反馈"Dotti 文字太大了"）。
        ///
        ///   取 0.74 的推导：要让 C# 的最终像素 ≈ ArkTS 的最终像素
        ///     ArkTS: 48 × 2.5 × 0.9333          = 112.0
        ///     C#    : 48 × K × 1.35 × 0.9333 = 112.0  →  K = 1.85⁻¹ ≈ 0.74
        ///
        ///   如果屏上看着仍偏大/偏小，**只改这一个数**即可（全文件统一生效）。
        /// </summary>
        private const double FontK = 0.74;

        /// <summary>按 ArkTS 原始字号取字体（自动套 FontK 系数）</summary>
        private static Font Sans(double size, bool bold)
        {
            return F.SansFont(size * FontK, bold);
        }

        /// <summary>按 ArkTS 原始字号取等宽字体（自动套 FontK 系数）</summary>
        private static Font Mono(double size, bool bold)
        {
            return F.MonoFont(size * FontK, bold);
        }

        /// <summary>表情运行时放大系数（源 `set_dotii_part`：6/5）</summary>
        private const double ExprGrow = 1.2;
        /// <summary>表情时长（源按快照下发；这里取同量级的一组）</summary>
        private static readonly int[] ExprMs = new int[] { 2600, 480, 1900, 2600, 1500, 1500, 2000, 1700 };
        public static readonly string[] ExprNames = new string[]
        { "idle_breath", "blink", "curious", "sleepy_yawn", "connecting", "working", "complete", "failure" };

        /// <summary>表情相位（源 phase = elapsed*8/duration）</summary>
        public static int ExprPhase(long nowMs, int expr)
        {
            int dur = ExprMs[((expr % ExprMs.Length) + ExprMs.Length) % ExprMs.Length];
            if (dur <= 0) return 0;
            return (int)Math.Floor((nowMs % dur) * 8.0 / dur);
        }

        // ==================================================================
        // 页面渲染
        // ==================================================================

        /// <summary>
        /// 渲染到**指定格子**（对齐 ArkTS `ThemeDotiiCell.render`）。
        /// 调用方给格子矩形；本函数自己算居中与缩放（装得下 1:1，装不下等比缩）。
        /// </summary>
        public static void RenderCell(Graphics g, DotiiState st, double cellX, double cellY,
                                      double cellW, double cellH, long nowMs)
        {
            // 本格底板：纯黑（Dotii 是黑底 UI）
            Draw.FillRound(g, cellX, cellY, cellW, cellH, 14, DotiiColors.Bg);
            Draw.StrokeRound(g, cellX + 0.5, cellY + 0.5, cellW - 1, cellH - 1, 14,
                             Color.FromArgb(0x26, 0x2A, 0x3A), 1);

            const double padX = 10;
            double room = cellW - padX * 2;
            double fit = Math.Min(1, room / DotiiGeom.W);        // 装不下才缩
            double drawW = DotiiGeom.W * fit;
            double drawH = DotiiGeom.H * fit;
            double innerX = cellX + (cellW - drawW) / 2;
            double innerY = cellY + (cellH - drawH) / 2;

            GraphicsState gs = g.Save();
            try
            {
                g.TranslateTransform((float)innerX, (float)innerY);
                g.ScaleTransform((float)(DotiiGeom.Scale * fit), (float)(DotiiGeom.Scale * fit));
                Draw.FillRect(g, 0, 0, DotiiGeom.KW, DotiiGeom.KH, DotiiColors.Bg);
                RenderPages(g, st, nowMs);
            }
            finally
            {
                g.Restore(gs);
            }
        }

        /// <summary>Dotii 框在整屏里的左上角（对齐 ArkTS 的 dotiiX/dotiiY：居中）</summary>
        public static double BoxX() { return Math.Round((1920 - DotiiGeom.W) / 2); }
        public static double BoxY() { return Math.Round((462 - DotiiGeom.H) / 2); }

        /// <summary>
        /// 主题 5「Dotii 分页屏」**整屏版**：黑底铺满 1920×462，Dotii 框居中，
        /// 内部按 ×0.9333 等比（对齐 ArkTS `ThemeDotii.render`）。
        ///
        /// 与 `RenderCell`（v6 版面的最右格）的区别：这个是**整屏**，
        /// 那个是装进 409 宽的格子并按需再缩。
        /// </summary>
        public static void Render(Graphics g, DotiiState st, long nowMs)
        {
            Draw.FillRect(g, 0, 0, 1920, 462, DotiiColors.Bg);
            double x = BoxX(), y = BoxY();
            Draw.FillRect(g, x, y, DotiiGeom.W, DotiiGeom.H, DotiiColors.Bg);

            GraphicsState gs = g.Save();
            try
            {
                g.TranslateTransform((float)x, (float)y);
                g.ScaleTransform((float)DotiiGeom.Scale, (float)DotiiGeom.Scale);
                RenderPages(g, st, nowMs);
            }
            finally
            {
                g.Restore(gs);
            }
        }

        /// <summary>
        /// 只渲染**页面内容**（不含整屏底色、不含 translate/scale）——
        /// 供不同格子复用，调用方自己变换到目标区域（对齐 ArkTS 的 renderPages）。
        /// </summary>
        public static void RenderPages(Graphics g, DotiiState st, long nowMs)
        {
            int page = ((st.Page % DotiiGeom.Pages) + DotiiGeom.Pages) % DotiiGeom.Pages;
            if (page == 0)
            {
                FacePage(g, st, nowMs);          // 表情页：无圆点、无状态栏
            }
            else if (page == 1)
            {
                BalancePage(g, st);              // 余额页：圆点 + 状态栏
                Dots(g, 1);
                StatusBar(g, st);
            }
            else if (page == 2)
            {
                BambuPage(g, st);                // Bambu 页：圆点，无状态栏
                Dots(g, 2);
            }
            else
            {
                CustomPage(g, st);               // 自定义页：无圆点、无状态栏
            }
        }

        // ---------------- 页 0：表情 ----------------

        private class Part
        {
            public double W, H, X, Y;
            public Color C = DotiiColors.FaceWarm;
            public int Opa = 255;
        }

        private static Part Mk(double w, double h, double x, double y, Color c, int opa)
        {
            Part p = new Part();
            p.W = w; p.H = h; p.X = x; p.Y = y; p.C = c; p.Opa = opa;
            return p;
        }

        private static Part Hidden(Color c) { return Mk(0, 0, 0, 0, c, 0); }

        /// <summary>5 个部件：左眼 / 右眼 / 嘴 / 左点 / 右点（后两个常兼作"中点"）</summary>
        private static Part[] FaceParts(int expr, int phase)
        {
            int p = phase < 4 ? phase : 8 - phase;                  // 乒乓
            Color warm = DotiiColors.FaceWarm;
            Color amber = DotiiColors.FaceAmber;
            Color cyan = DotiiColors.FaceCyan;
            Color coral = DotiiColors.FaceCoral;

            if (expr == 1)
            {
                // BLINK：eye_h = 7（相位 2,3）/ 24（相位 1,4）/ 66（其余）
                double eh = (phase == 2 || phase == 3) ? 7 : ((phase == 1 || phase == 4) ? 24 : 66);
                return new Part[]
                {
                    Mk(58, eh, -78, -26, warm, 255), Mk(58, eh, 78, -26, warm, 255),
                    Mk(56, 12, 0, 70, warm, 255), Hidden(cyan), Hidden(cyan)
                };
            }
            if (expr == 2)
            {
                // CURIOUS：一 eye 大一 eye 小 + 琥珀方嘴
                return new Part[]
                {
                    Mk(62, 82, -76, -34, warm, 255), Mk(46, 62, 82, -26, warm, 255),
                    Mk(20 + p, 20 + p, 8, 70, amber, 255), Hidden(cyan), Hidden(cyan)
                };
            }
            if (expr == 3)
            {
                // SLEEPY_YAWN：眼挤成缝 + 琥珀嘴张开
                return new Part[]
                {
                    Mk(68, 10, -76, -18, warm, 255), Mk(68, 10, 76, -18, warm, 255),
                    Mk(26 + p * 3, 26 + p * 3, 0, 72, amber, 255), Hidden(cyan), Hidden(cyan)
                };
            }
            if (expr == 4)
            {
                // CONNECTING：青色眼交叉淡入 + 中点横移
                int lo = phase < 4 ? 255 : 110;
                int ro = phase < 4 ? 110 : 255;
                return new Part[]
                {
                    Mk(48, 64, -76, -28, cyan, lo), Mk(48, 64, 76, -28, cyan, ro),
                    Mk(56, 12, 0, 70, warm, 255), Hidden(cyan),
                    Mk(10, 10, phase * 22 - 77, 88, cyan, 255)
                };
            }
            if (expr == 5)
            {
                // WORKING：双眼同扫 + 青嘴 + 右点下落
                return new Part[]
                {
                    Mk(48, 68, -86 + p * 4, -30, warm, 255), Mk(48, 68, 70 + p * 4, -30, warm, 255),
                    Mk(62, 10, 0, 72, cyan, 255), Hidden(cyan),
                    Mk(10, 10, 134, -82 + phase * 7, cyan, 255)
                };
            }
            if (expr == 6)
            {
                // COMPLETE：眯眼笑 + 宽琥珀嘴 + 左点琥珀/右点青
                return new Part[]
                {
                    Mk(68, 14, -76, -28, warm, 255), Mk(68, 14, 76, -28, warm, 255),
                    Mk(108 + p, 20 + p / 2, 0, 62, amber, 255),
                    Mk(10 + p, 10 + p, -132, -76, amber, 255),
                    Mk(10 + p, 10 + p, 132, -76, cyan, 255)
                };
            }
            if (expr == 7)
            {
                // FAILURE：扁平珊瑚眼 + 珊瑚嘴 + 珊瑚中点
                return new Part[]
                {
                    Mk(58, 12, -76, -22, coral, 255), Mk(58, 12, 76, -22, coral, 255),
                    Mk(72, 12, 0, 80 + p / 2, coral, 255), Hidden(coral),
                    Mk(10 + p, 10 + p, 0, 52, coral, 255)
                };
            }
            // IDLE_BREATH：眼高呼吸（breath = p*2）+ 两个青点
            return new Part[]
            {
                Mk(52, 68 + p * 2, -78, -30, warm, 255), Mk(52, 68 + p * 2, 78, -30, warm, 255),
                Mk(56, 12, 0, 70, warm, 255),
                Mk(12, 12, -132, 52, cyan, 255), Mk(12, 12, 132, 52, cyan, 255)
            };
        }

        public static void FacePage(Graphics g, DotiiState st, long nowMs)
        {
            int expr = ((st.Expr % ExprNames.Length) + ExprNames.Length) % ExprNames.Length;
            int phase = ExprPhase(nowMs, expr);
            Part[] parts = FaceParts(expr, phase);
            double cx = DotiiGeom.KW / 2;
            double cy = DotiiGeom.KH / 2;
            for (int i = 0; i < parts.Length; i++)
            {
                Part q = parts[i];
                if (q.W <= 0 || q.H <= 0) continue;
                double w = q.W * ExprGrow;
                double h = q.H * ExprGrow;
                double px = cx + q.X * ExprGrow - w / 2;
                double py = cy + q.Y * ExprGrow - h / 2;
                Color c = Color.FromArgb((int)(q.Opa / 255.0 * 255), q.C);
                // LV_RADIUS_CIRCLE = 取 min(w,h)/2，等于胶囊两端是半圆
                Draw.FillRound(g, px, py, w, h, Math.Min(w, h) / 2, c);
            }
        }

        // ---------------- 页 1：余额 ----------------

        public static void BalancePage(Graphics g, DotiiState st)
        {
            double cx = DotiiGeom.KW / 2;
            Font f48 = Sans(48, true);
            Font f40 = Sans(40, true);
            Font f36 = Sans(36, true);
            Font f88 = Sans(88, true);

            Draw.Text(g, "DeepSeek", cx, 62, f48, DotiiColors.Text, Draw.TextAlign.Center);
            Draw.Text(g, Hhmm(st), cx, 108, f40, DotiiColors.Muted, Draw.TextAlign.Center);
            Draw.Text(g, "余额 (元)", cx, 146, f36, DotiiColors.Muted, Draw.TextAlign.Center);
            Draw.Text(g, st.BalanceTotal, cx, 216, f88,
                      st.BalanceHasValue ? DotiiColors.Text : DotiiColors.Muted, Draw.TextAlign.Center);


            StatusPill(g, 184, 276, 138, 48, st.BalanceStatus, BalanceColor(st));

            Draw.FillRect(g, 183, 350, 1, 42, DotiiColors.Divider);
            Metric(g, 43, 344, 132, "赠送", st.BalanceGranted);
            Metric(g, 193, 344, 132, "充值", st.BalanceTopped);

        }

        // ---------------- 页 2：Bambu ----------------

        public static void BambuPage(Graphics g, DotiiState st)
        {
            bool live = st.PrState == "RUNNING" || st.PrState == "PAUSE" || st.PrState == "PREPARE";
            double pct = (live && st.PrPct >= 0) ? st.PrPct : 0;
            // 环：圆心(184,224)、描边中心 r=171、宽 26、角度 140→400、实机**不圆头**
            Arc(g, 184, 224, 171, 26, 140, 400, pct, DotiiColors.TrackBambu,
                live ? DotiiColors.Bambu : DotiiColors.DotOff, false);

            double cx = DotiiGeom.KW / 2;
            Font f48 = Sans(48, true);
            Font f40 = Sans(40, true);
            Font f96 = Sans(96, true);
            Font f36 = Sans(36, true);
            Font f32 = Sans(32, true);

            Draw.Text(g, "Bambu", cx, 62, f48, DotiiColors.Text, Draw.TextAlign.Center);
            Draw.Text(g, Hhmm(st), cx, 108, f32, DotiiColors.Muted, Draw.TextAlign.Center);
            Draw.Text(g, "打印进度", cx, 158, f40, DotiiColors.Muted, Draw.TextAlign.Center);
            Draw.Text(g, live ? string.Format("{0:0}%", pct) : "--%", cx, 228, f96,
                      live ? DotiiColors.Text : DotiiColors.Muted, Draw.TextAlign.Center);

            // 三行温度/层数贴在环内大数字上方
            string rows = string.Format("喷嘴 {0}   热床 {1}   层 {2}/{3}",
                Temp(st.PrNozzle), Temp(st.PrBed),
                st.PrLayer >= 0 ? ((int)st.PrLayer).ToString() : "--",
                st.PrTotalLayer > 0 ? ((int)st.PrTotalLayer).ToString() : "--");
            Draw.Text(g, rows, cx, 298, f36, DotiiColors.Muted, Draw.TextAlign.Center);

            StatusPill(g, 184, 340, 138, 48, st.PrStatusText, PrinterColor(st));

            Draw.FillRect(g, 183, 388, 1, 48, DotiiColors.Divider);
            Metric(g, 43, 378, 132, "剩余", st.PrRemainText);
            Metric(g, 193, 378, 132, "完成", st.PrFinishText);

        }

        // ---------------- 页 3：自定义 ----------------

        public static void CustomPage(Graphics g, DotiiState st)
        {
            // 环：同几何，0→360，底 0x2B2D28，指示色缺省 warning（实机无百分比数字）
            Arc(g, 184, 224, 171, 26, 0, 360, 100, DotiiColors.TrackCustom,
                DotiiColors.Warning, true);

            double cx = DotiiGeom.KW / 2;
            Font f40 = Sans(40, true);
            Font f42 = Sans(42, true);
            Draw.Text(g, st.CustomTitle, cx, 70, f40, DotiiColors.Muted, Draw.TextAlign.Center);
            Draw.Text(g, st.CustomValue, cx, 176, f42, DotiiColors.Warning, Draw.TextAlign.Center);
            Draw.Text(g, st.CustomBody, cx, 258, f40, Color.FromArgb(0xC6, 0xD0, 0xCC), Draw.TextAlign.Center);
            Draw.Text(g, st.CustomFooter, cx, 372, f40, DotiiColors.Muted, Draw.TextAlign.Center);

        }

        // ---------------- 底部圆点 ----------------

        /// <summary>只有余额页（row=1）与 Bambu 页（row=2）有圆点</summary>
        public static void Dots(Graphics g, int row)
        {
            double y = row == 1 ? (DotiiGeom.KH - 40 - 2.5) : (DotiiGeom.KH - 29 - 2.5);
            const double gap = 8;
            double x = DotiiGeom.KW / 2 - (16 + 3 * 5 + 3 * 8) / 2.0;
            for (int i = 0; i < DotiiGeom.Pages; i++)
            {
                bool on = (i == row);
                double w = on ? 16 : 5;
                Color c = on ? DotiiColors.PageColors[i] : DotiiColors.DotOff;
                Draw.FillRound(g, x, y, w, 5, on ? 3 : 2.5, c);
                x += w + gap;
            }
        }

        // ---------------- 底部状态栏 ----------------

        /// <summary>底部状态栏（源只挂余额页）</summary>
        public static void StatusBar(Graphics g, DotiiState st)
        {
            const double h = 32;
            double y = DotiiGeom.KH - h;                 // 416
            Draw.FillRect(g, 0, y, DotiiGeom.KW, h, DotiiColors.StatusBg);

            // WiFi 圆点 10×10 @(6,11)
            Color wifi = st.WifiOn ? DotiiColors.Green
                       : (st.WifiConnecting ? DotiiColors.Warning : DotiiColors.Muted);
            Draw.FillCircle(g, 6 + 5, y + 11 + 5, 5, wifi);

            // 连接名 @(20,1) 宽 160、循环滚动
            GraphicsState gs = g.Save();
            try
            {
                g.SetClip(new RectangleF(20, (float)y, 160, (float)h));
                Font f28 = Sans(28, true);
                string conn = st.ConnText.Length > 0 ? st.ConnText : "未配置";
                double tw = Draw.Measure(g, conn, f28);
                double span = tw + 40;
                double off = (State.NowMs() % 14000) / 14000.0 * span;
                Draw.Text(g, conn, 20 - off, y + h / 2, f28, DotiiColors.Muted, Draw.TextAlign.Left);
                if (span < 160 + tw)
                {
                    Draw.Text(g, conn, 20 - off + span, y + h / 2, f28, DotiiColors.Muted, Draw.TextAlign.Left);
                }
            }
            finally
            {
                g.Restore(gs);
            }

            // 电量 @(224,8)
            Font fb = Mono(28, true);
            string batt = st.Batt >= 0
                ? string.Format("{0:0}%{1}", st.Batt, st.Charging ? "+" : "")
                : "--";
            Draw.Text(g, batt, 224, y + h / 2, fb, DotiiColors.Muted, Draw.TextAlign.Left);
            Draw.Text(g, Hhmm(st), 360, y + h / 2, fb, DotiiColors.Muted, Draw.TextAlign.Left);
        }

        // ---------------- 小部件 ----------------

        /// <summary>状态胶囊：底色 = 状态色 20% 不透明，内含圆点 + 描边文字</summary>
        private static void StatusPill(Graphics g, double cx, double cy, double w, double h,
                                       string text, Color color)
        {
            Font f38 = Sans(38, true);
            double textW = Draw.Measure(g, text, f38);
            const double dotR = 7;
            const double gap = 10;
            double needW = textW + dotR * 2 + gap + 24;
            double pw = Math.Max(w, needW);

            Draw.FillRound(g, cx - pw / 2, cy - h / 2, pw, h, h / 2,
                           Color.FromArgb((int)(0.2 * 255), color));

            double startX = cx - (dotR * 2 + gap + textW) / 2;
            Draw.FillCircle(g, startX + dotR, cy, dotR, color);

            // 描边 + 填充（源是 strokeText + fillText 叠加做"硬边字"）
            double tx = startX + dotR * 2 + gap;
            using (GraphicsPath path = new GraphicsPath())
            {
                path.AddString(text, f38.FontFamily, (int)FontStyle.Bold,
                               (float)(f38.Size * 96 / 72), new PointF(0, 0),
                               StringFormat.GenericTypographic);
                using (Matrix m = new Matrix())
                {
                    RectangleF b = path.GetBounds();
                    m.Translate((float)tx, (float)(cy - b.Height / 2 - b.Y));
                    path.Transform(m);
                }
                using (Pen pen = new Pen(color, 2))
                {
                    g.DrawPath(pen, path);
                }
                using (SolidBrush b2 = new SolidBrush(color))
                {
                    g.FillPath(b2, path);
                }
            }
        }

        /// <summary>数值块 132×56：值在上、题注在下</summary>
        private static void Metric(Graphics g, double x, double y, double w,
                                   string label, string value)
        {
            Font f40 = Sans(40, true);
            Font f34 = Sans(34, true);
            Draw.Text(g, value, x + w / 2, y + 8, f40, DotiiColors.Text, Draw.TextAlign.Center);
            Draw.Text(g, label, x + w / 2, y + 52, f34, DotiiColors.Muted, Draw.TextAlign.Center);

        }

        /// <summary>
        /// 圆环（源 make_usage_arc + ringSVG：底环 + 指示弧）。
        /// LVGL 角度：0° = 3 点方向、顺时针；半径传**描边中心线**。
        /// </summary>
        private static void Arc(Graphics g, double cx, double cy, double r, double w,
                                double a0, double a1, double pct,
                                Color trackColor, Color barColor, bool rounded)
        {
            double sweep = ((a1 - a0) % 360 + 360) % 360;
            if (sweep == 0) sweep = 360;
            using (Pen pen = new Pen(trackColor, (float)w))
            {
                pen.StartCap = rounded ? LineCap.Round : LineCap.Flat;
                pen.EndCap = rounded ? LineCap.Round : LineCap.Flat;
                g.DrawArc(pen, (float)(cx - r), (float)(cy - r), (float)(r * 2), (float)(r * 2),
                          (float)a0, (float)sweep);
            }
            double p = Math.Max(0, Math.Min(100, pct));
            if (p > 0)
            {
                using (Pen pen = new Pen(barColor, (float)w))
                {
                    pen.StartCap = rounded ? LineCap.Round : LineCap.Flat;
                    pen.EndCap = rounded ? LineCap.Round : LineCap.Flat;
                    g.DrawArc(pen, (float)(cx - r), (float)(cy - r), (float)(r * 2), (float)(r * 2),
                              (float)a0, (float)(sweep * p / 100));
                }
            }
        }

        private static string Hhmm(DotiiState st)
        {
            string hh = (st.Hour < 10 ? "0" : "") + st.Hour.ToString();
            string mm = (st.Minute < 10 ? "0" : "") + st.Minute.ToString();
            return hh + ":" + mm;
        }

        private static string Temp(double v)
        {
            return v >= 0 ? string.Format("{0:0}°C", v) : "--";
        }

        /// <summary>余额胶囊状态色（源 `state_ui.c:2244-2356`）</summary>
        private static Color BalanceColor(DotiiState st)
        {
            string s = st.BalanceStatus;
            if (s == "可用") return DotiiColors.Green;
            if (s == "不可用" || s == "密钥无效" || s == "获取失败") return DotiiColors.Danger;
            if (s == "预览数据") return DotiiColors.Warning;
            return DotiiColors.Muted;
        }

        /// <summary>Bambu 胶囊状态色（源 `state_ui.c:2394-2396`）</summary>
        private static Color PrinterColor(DotiiState st)
        {
            string s = st.PrState;
            if (s == "FAULT") return DotiiColors.Danger;
            if (s == "PAUSE") return DotiiColors.Warning;
            if (s == null || s.Length == 0 || s == "OFFLINE" || s == "UNKNOWN") return DotiiColors.Muted;
            return DotiiColors.Bambu;
        }
    }
}
