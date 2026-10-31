/**
 * ThemeCyber.cs — 主题 10「赛博二次元」（C# 5 移植版）
 *
 * 逐值移植自 `entry/src/main/ets/render/ThemeAnime.ets`（436 行里的 391 行主体）。
 * 设计方向：**赛博 + 二次元**（霓虹青紫、扫描线、故障色差、日文片假名装饰）。
 * 纯几何绘制 —— 不依赖任何外部图片/字体文件。
 *
 * 版面沿用 5 格（v6 结构），但**整屏加二次元氛围层**：
 *   ① 底色：深紫黑渐变（`#0B0B14 → #140A20`），比纯黑更有"夜色感"
 *   ② 网格线：极淡青色细线（每 60px 一条），像 CRT/全息投影
 *   ③ 扫描线：每 4px 一条 1px 暗线，alpha 很低（模拟 CRT）
 *   ④ 霓虹发光：标题用"多次 fillText + 递减 alpha"做外发光
 *   ⑤ 故障色差：标题左右错位 2px 画青/品红（chromatic aberration）
 *   ⑥ 日文片假名装饰：标题旁竖排小字（システム / セッション …）
 *   ⑦ 四角 L 形切角（HUD 风格）
 *   ⑧ 右上角微光星（缓慢闪烁）
 *
 * ⚠️ 命名说明：类名是 `ThemeCyber` 而**不是** `ThemeAnime` ——
 *   因为 `win/src/ThemeAnime.cs` 这个文件已存在（装的是主题 11~15 那 5 档二次元主题类）。
 *   ArkTS 侧把主题 10 放在 `ThemeAnime.ets` 里，C# 侧沿用同名文件会造成类名冲突。
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace DshLcd
{
    public static class ThemeCyber
    {
        // ---- 配色 ----
        private static readonly Color BgTop = Color.FromArgb(0x0B, 0x0B, 0x14);
        private static readonly Color BgBot = Color.FromArgb(0x14, 0x0A, 0x20);
        private static readonly Color PanelC = Color.FromArgb(0x16, 0x12, 0x2A);
        private static readonly Color BorderC = Color.FromArgb(0x2A, 0x22, 0x44);
        private static readonly Color Cyan = Color.FromArgb(0x22, 0xD3, 0xEE);
        private static readonly Color Purple = Color.FromArgb(0xA8, 0x55, 0xF7);
        private static readonly Color Pink = Color.FromArgb(0xFF, 0x2E, 0x97);
        private static readonly Color TextW = Color.FromArgb(0xEA, 0xF6, 0xFF);
        private static readonly Color TextS = Color.FromArgb(0x8F, 0xA3, 0xBF);
        private static readonly Color TextL = Color.FromArgb(0x5A, 0x6B, 0x85);

        /// <summary>各格的日文片假名装饰（纯装饰，不参与信息表达）</summary>
        private static readonly string[] Kana = new string[]
        { "システム", "セッション", "つかう", "スクリーン", "ドティ" };

        public static void Render(Graphics g, State st, long now)
        {
            const double W = 1920, H = 462;
            Backdrop(g, W, H, now);
            HudCorners(g, W, H);

            double[] sx = new double[] { 14, 298.4, 706, 1016, 1450 };
            double[] sw = new double[] { 274.4, 398, 300, 424, 409 };
            string[] titles = new string[] { "系统", "DSH 会话", "用量", "虚拟机", "Dotii" };
            for (int i = 0; i < sx.Length; i++)
            {
                Color accent = (i % 3 == 0) ? Cyan : ((i % 3 == 1) ? Purple : Pink);
                Panel(g, sx[i], L.PanelY, sw[i], L.PanelHeight, accent);
                NeonTitle(g, sx[i], sw[i], L.PanelY, titles[i], Kana[i], accent);
            }

            Telemetry t = (st == null) ? null : st.Data;
            SystemCell(g, sx[0], sw[0], t);
            AgentCell(g, sx[1], sw[1], t);
            UsageCell(g, sx[2], sw[2], t);
            // VM 画面（第 4 格）由调用方的 _vm.Render 负责，这里只画虚线占位框
            VmCell(g, sx[3], sw[3]);
            DotiiCell(g, sx[4], sw[4], t);
        }

        // ---------------- 氛围层 ----------------

        private static void Backdrop(Graphics g, double W, double H, long now)
        {
            using (LinearGradientBrush bg = new LinearGradientBrush(
                       new Rectangle(0, 0, (int)W, (int)H), BgTop, BgBot,
                       LinearGradientMode.Vertical))
            {
                g.FillRectangle(bg, 0, 0, (int)W, (int)H);
            }

            // 网格（每 60px，极淡青色，alpha 0.055）
            using (Pen p = new Pen(Color.FromArgb((int)(0.055 * 255), Cyan), 1))
            {
                for (int x = 0; x <= W; x += 60) g.DrawLine(p, x, 0, x, (float)H);
                for (int y = 0; y <= H; y += 60) g.DrawLine(p, 0, y, (float)W, y);
            }

            // 扫描线（每 4px 一条 1px 暗线，alpha 0.16）
            using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(0.16 * 255), 0, 0, 0)))
            {
                for (int y = 0; y < H; y += 4) g.FillRectangle(b, 0, y, (float)W, 1);
            }

            // 右上角微光星（缓慢闪烁，周期 ~1.6s；8fps 下不会抖）
            double[][] stars = new double[][]
            {
                new double[]{1846, 26, 3}, new double[]{1806, 52, 2},
                new double[]{1878, 66, 2}, new double[]{1770, 30, 2},
            };
            for (int i = 0; i < stars.Length; i++)
            {
                double tw = 0.45 + 0.55 * Math.Abs(Math.Sin(now / 1600.0 + i * 1.3));
                Color c = Color.FromArgb((int)(tw * 0.9 * 255), (i % 2 == 0) ? Cyan : Pink);
                Star(g, stars[i][0], stars[i][1], stars[i][2], c);
            }
        }

        /// <summary>四角 L 形切角（HUD 风格）</summary>
        private static void HudCorners(Graphics g, double W, double H)
        {
            const double m = 8, len = 26;
            using (Pen p = new Pen(Color.FromArgb((int)(0.5 * 255), Cyan), 2))
            {
                g.DrawLine(p, (float)m, (float)(m + len), (float)m, (float)m);
                g.DrawLine(p, (float)m, (float)m, (float)(m + len), (float)m);
                g.DrawLine(p, (float)(W - m - len), (float)m, (float)(W - m), (float)m);
                g.DrawLine(p, (float)(W - m), (float)m, (float)(W - m), (float)(m + len));
                g.DrawLine(p, (float)m, (float)(H - m - len), (float)m, (float)(H - m));
                g.DrawLine(p, (float)m, (float)(H - m), (float)(m + len), (float)(H - m));
                g.DrawLine(p, (float)(W - m - len), (float)(H - m), (float)(W - m), (float)(H - m));
                g.DrawLine(p, (float)(W - m), (float)(H - m), (float)(W - m), (float)(H - m - len));
            }
        }

        /// <summary>面板：半透明底 + 霓虹描边 + 顶部一道发光横线（3 层递减 alpha 模拟 glow）</summary>
        private static void Panel(Graphics g, double x, double y, double w, double h, Color accent)
        {
            Draw.FillRound(g, x, y, w, h, 12, Color.FromArgb((int)(0.86 * 255), PanelC));
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 12, BorderC, 1);
            for (int i = 0; i < 3; i++)
            {
                Draw.FillRect(g, x + 10 - i, y + 2 + i, w - 20 + i * 2, 1,
                              Color.FromArgb((int)((0.5 - i * 0.15) * 255), accent));
            }
        }

        /// <summary>
        /// 霓虹标题：主文字 + **故障色差**（左右各错位 2px 画青/品红）+ 日文片假名竖排装饰。
        /// 发光用"同位置多次低 alpha 重绘"近似（GDI+ 也没有文字 glow）。
        /// </summary>
        private static void NeonTitle(Graphics g, double x, double w, double y,
                                      string title, string kana, Color accent)
        {
            Font f = F.SansFont(21, true);
            double cx = x + w / 2;
            double ty = y + 32;

            // 故障色差：青/品红各偏 2px
            Draw.Text(g, title, cx - 2, ty, f, Color.FromArgb((int)(0.5 * 255), Cyan), Draw.TextAlign.Center);
            Draw.Text(g, title, cx + 2, ty, f, Color.FromArgb((int)(0.5 * 255), Pink), Draw.TextAlign.Center);
            // 主文字（描边做出"硬边"感 —— 用 GraphicsPath 描边）
            DrawOutlinedText(g, title, cx, ty, f, accent);

            // 日文片假名（竖排小字，贴在标题右侧；纯装饰）
            if (kana != null && kana.Length > 0)
            {
                Font kf = F.SansFont(11, false);
                double kx = cx + Draw.Measure(g, title, F.SansFont(21, true)) / 2 + 10;
                for (int i = 0; i < kana.Length && i < 6; i++)
                {
                    Draw.Text(g, kana.Substring(i, 1), kx, ty - 14 + i * 13, kf,
                              Color.FromArgb((int)(0.55 * 255), TextS), Draw.TextAlign.Left);
                }
            }
        }

        /// <summary>带黑描边的文字（GDI+ 用 GraphicsPath.AddString + DrawPath 实现）</summary>
        private static void DrawOutlinedText(Graphics g, string text, double cx, double cy,
                                             Font font, Color fill)
        {
            try
            {
                using (GraphicsPath path = new GraphicsPath())
                {
                    path.AddString(text, font.FontFamily, (int)FontStyle.Bold,
                                   (float)(font.Size * 96 / 72), new PointF(0, 0),
                                   StringFormat.GenericTypographic);
                    RectangleF b = path.GetBounds();
                    using (Matrix m = new Matrix())
                    {
                        m.Translate((float)(cx - b.Width / 2 - b.X), (float)(cy - b.Height / 2 - b.Y));
                        path.Transform(m);
                    }
                    using (Pen pen = new Pen(Color.Black, 3))
                    {
                        g.DrawPath(pen, path);
                    }
                    using (SolidBrush sb = new SolidBrush(fill))
                    {
                        g.FillPath(sb, path);
                    }
                }
            }
            catch (Exception)
            {
                // 字体不支持时退回普通绘制（不因为装饰性描边让整帧失败）
                Draw.Text(g, text, cx, cy, font, fill, Draw.TextAlign.Center);
            }
        }

        // ---------------- 五格内容 ----------------

        private static void SystemCell(Graphics g, double x, double w, Telemetry t)
        {
            SystemInfo sys = (t == null) ? null : t.System;
            double cpu = (sys == null) ? 0 : sys.Cpu;
            double cx = x + w / 2, cy = 176, r = 62;
            Draw.StrokeCircle(g, cx, cy, r, Color.FromArgb(0x24, 0x1C, 0x3A), 12);
            double p = Math.Max(0, Math.Min(100, cpu));
            if (p > 0)
            {
                Draw.Arc(g, cx, cy, r, -90, p * 3.6, cpu > 80 ? Pink : Cyan, 12);
            }
            Font bf = F.MonoFont(46, true);
            Draw.Text(g, ((long)Math.Round(cpu)).ToString() + "%", cx, cy, bf, TextW, Draw.TextAlign.Center);
            Font sf = F.SansFont(14, false);
            Draw.Text(g, "CPU", cx, cy + 38, sf, TextS, Draw.TextAlign.Center);

            double mem = (sys == null) ? 0 : sys.MemUsed;
            double memT = (sys == null) ? 0 : sys.MemTotal;
            KV(g, x + 18, 288, "内存",
               memT > 0 ? mem.ToString("0.0") + " / " + memT.ToString("0.0") + " GB" : "--", TextW);
            if (memT > 0) Bar(g, x + 18, 316, w - 36, 10, mem / memT * 100, Purple);
            KV(g, x + 18, 352, "电量",
               (sys == null || sys.Battery < 0) ? "--" : ((long)sys.Battery).ToString() + "%", Cyan);
        }

        private static void AgentCell(Graphics g, double x, double w, Telemetry t)
        {
            AgentInfo ag = (t == null) ? null : t.Agent;
            Font pf = F.MonoFont(28, true);
            Draw.Text(g, Draw.Fit(g, (ag == null || ag.Project == null) ? "等待数据" : ag.Project, pf, w - 40),
                      x + 18, 108, pf, TextW, Draw.TextAlign.Left);
            Font af = F.SansFont(20, true);
            Draw.Text(g, Draw.Fit(g, (ag == null || ag.Activity == null) ? "--" : ag.Activity, af, w - 40),
                      x + 18, 156, af, Cyan, Draw.TextAlign.Left);

            // 底部滚动留言条（与主题 0 同款：3 行、由暗到亮）
            Font ff = F.SansFont(15, false);
            int show = Math.Min(3, Dashboard.FeedCount);
            for (int i = 0; i < show; i++)
            {
                // FeedLineAt 是"倒数"语义：offset 越大越旧。
                // 屏幕上要从上到下排"旧→新"，所以这里把 offset 反过来用。
                string line = Dashboard.FeedLineAt(show - 1 - i);
                if (line == null) continue;
                bool newest = (i == show - 1);
                double[] alphas = new double[] { 0.42, 0.68, 1.0 };
                Draw.Text(g, Draw.Fit(g, line, ff, w - 40), x + 18, 296 + i * 30, ff,
                          Color.FromArgb((int)(alphas[Math.Min(i, 2)] * 255), newest ? TextW : TextS),
                          Draw.TextAlign.Left);
            }
        }

        private static void UsageCell(Graphics g, double x, double w, Telemetry t)
        {
            TokenInfo tk = (t == null) ? null : t.Tokens;
            BalanceInfo bal = (t == null) ? null : t.Balance;
            KV(g, x + 18, 96, "今日 TOKEN",
               (tk == null) ? "--" : Fmt(tk.TodayTotal), TextW);
            bool hasBal = bal != null && bal.Total >= 0;
            KV(g, x + 18, 152, "余额",
               hasBal ? "¥" + bal.Total.ToString("0.00") : "--", hasBal ? Pink : TextL);
            double used = (tk == null) ? 0 : tk.ContextUsed;
            double win = (tk == null) ? 0 : tk.ContextWindow;
            double pct = win > 0 ? used / win * 100 : 0;
            KV(g, x + 18, 208, "上下文", win > 0 ? pct.ToString("0.0") + "%" : "--", Purple);
            if (win > 0) Bar(g, x + 18, 236, w - 36, 10, pct, Purple);

            // 大时钟（霓虹：青/粉错位 + 白主字）
            DateTime d = DateTime.Now;
            string clock = string.Format("{0:00}:{1:00}", d.Hour, d.Minute);
            Font cf = F.MonoFont(54, true);
            Draw.Text(g, clock, x + w / 2 - 2, 340, cf, Color.FromArgb((int)(0.45 * 255), Cyan), Draw.TextAlign.Center);
            Draw.Text(g, clock, x + w / 2 + 2, 340, cf, Color.FromArgb((int)(0.45 * 255), Pink), Draw.TextAlign.Center);
            Draw.Text(g, clock, x + w / 2, 340, cf, TextW, Draw.TextAlign.Center);
        }

        private static void VmCell(Graphics g, double x, double w)
        {
            // VM 画面本体由调用方的 _vm.Render 画（C# 侧在 LcdRunner 里统一处理），
            // 这里只画轮廓，避免与真实画面重叠
            Draw.StrokeRound(g, x + 12, 60, w - 24, 300, 8,
                             Color.FromArgb((int)(0.35 * 255), Cyan), 1);
        }

        private static void DotiiCell(Graphics g, double x, double w, Telemetry t)
        {
            PrinterInfo pr = (t == null) ? null : t.Printer;
            string st = (pr == null || pr.StateLabel == null || pr.StateLabel.Length == 0)
                ? "--" : pr.StateLabel;
            Font pf = F.SansFont(34, true);
            Draw.Text(g, st, x + w / 2, 200, pf, Cyan, Draw.TextAlign.Center);
            Font sf = F.SansFont(18, false);
            Draw.Text(g, (pr == null || pr.Percent < 0) ? "--" : pr.Percent.ToString() + "%",
                      x + w / 2, 250, sf, TextS, Draw.TextAlign.Center);
        }

        // ---------------- 小部件 ----------------

        private static void KV(Graphics g, double x, double y, string label, string val, Color vc)
        {
            Font lf = F.SansFont(15, false);
            Font vf = F.MonoFont(20, true);
            Draw.Text(g, label, x, y, lf, TextL, Draw.TextAlign.Left);
            Draw.Text(g, val, x + 240, y, vf, vc, Draw.TextAlign.Right);

        }

        private static void Bar(Graphics g, double x, double y, double w, double h,
                                double pct, Color color)
        {
            Draw.FillRound(g, x, y, w, h, h / 2, Color.FromArgb(0x24, 0x1C, 0x3A));
            double p = Math.Max(0, Math.Min(100, pct));
            if (p > 0) Draw.FillRound(g, x, y, Math.Max(h, w * p / 100), h, h / 2, color);
        }

        /// <summary>四角星（不是圆点）</summary>
        private static void Star(Graphics g, double cx, double cy, double r, Color c)
        {
            PointF[] pts = new PointF[]
            {
                new PointF((float)cx, (float)(cy - r)),
                new PointF((float)(cx + r * 0.32), (float)(cy - r * 0.32)),
                new PointF((float)(cx + r), (float)cy),
                new PointF((float)(cx + r * 0.32), (float)(cy + r * 0.32)),
                new PointF((float)cx, (float)(cy + r)),
                new PointF((float)(cx - r * 0.32), (float)(cy + r * 0.32)),
                new PointF((float)(cx - r), (float)cy),
                new PointF((float)(cx - r * 0.32), (float)(cy - r * 0.32)),
            };
            using (SolidBrush b = new SolidBrush(c))
            {
                g.FillPolygon(b, pts);
            }
        }

        private static string Fmt(double n)
        {
            if (n >= 100000000) return (n / 100000000).ToString("0.00") + "亿";
            if (n >= 10000) return (n / 10000).ToString("0.0") + "万";
            return ((long)Math.Round(n)).ToString();
        }
    }
}
