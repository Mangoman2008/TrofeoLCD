/**
 * ThemeAnime.cs — 5 档二次元主题（C# 5 移植版，对应 ArkTS 的主题 11~15）
 *
 * | 本文件 | ArkTS 源 | 主题号 | 特征 |
 * |---|---|---|---|
 * | `ThemeAnimeBG`   | `ThemeAnimeBG.ets`   | 11 | 程序生成夜景插画（星空/月亮/山脊/倒影/樱花）+ 半透明面板 |
 * | `ThemeAnimeFree` | `ThemeAnimeFree.ets` | 12 | 无框自由构图，数据"漂"在插画上 |
 * | `ThemeAnimeHUD`  | `ThemeAnimeHUD.ets`  | 13 | **唯一浅色主题**：冷白瓷片 + 青 HUD（照 GitHub NanoMuse 的设计语言） |
 * | `ThemeNanoMuse`  | `ThemeNanoMuse.ets`  | 14 | 大字号版：2×2 大数字格 + 大健康环 + 打印机环 |
 * | `ThemeTrofeoRust`| `ThemeTrofeoRust.ets`| 15 | 复刻 trofeo-lcd-rs：13 个栅格版面 + 12 套调色板轮换 + 程序化背景 |
 *
 * ⚠️ 语言上限 **C# 5**：禁用字符串插值 `$"..."`、空传播 `?.`、表达式体成员、`out var`、元组。
 *
 * ⚠️ 本文件是"逐行对照 ArkTS"的移植，几何常量与配色**必须与 ArkTS 源一致** ——
 *    两边不一致会让同一主题在两个平台上长得不一样（工程里已有"两份几何常量"的先例问题）。
 */
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace DshLcd
{
    /// <summary>
    /// 固定种子伪随机 —— 保证每帧生成的星空/山脊/花瓣位置一致，画面不闪。
    /// 等价于 ArkTS 里那套 `seed = seed * 1103515245 + 12345` 的 LCG。
    /// </summary>
    internal class Lcg
    {
        private long _s;
        public Lcg(long seed) { _s = seed & 0x7fffffff; }
        public double Next()
        {
            _s = (_s * 1103515245 + 12345) & 0x7fffffff;
            return (double)_s / 0x7fffffff;
        }
        public void Reset(long seed) { _s = seed & 0x7fffffff; }
    }

    // ==================================================================
    // 主题 11：二次元壁纸（程序生成夜景插画 + 半透明面板）
    // ==================================================================
    public static class ThemeAnimeBG
    {
        private static readonly Color SkyTop = Color.FromArgb(11, 16, 38);
        private static readonly Color SkyMid = Color.FromArgb(36, 26, 74);
        private static readonly Color SkyHor = Color.FromArgb(91, 42, 94);
        private static readonly Color MoonC = Color.FromArgb(255, 246, 224);
        private static readonly Color RidgeFar = Color.FromArgb(42, 33, 80);
        private static readonly Color RidgeNear = Color.FromArgb(20, 16, 41);
        private static readonly Color PanelC = Color.FromArgb(14, 10, 30);
        private static readonly Color BorderC = Color.FromArgb(58, 47, 99);
        private static readonly Color Cyan = Color.FromArgb(127, 231, 255);
        private static readonly Color Pink = Color.FromArgb(255, 154, 200);
        private static readonly Color TextW = Color.FromArgb(242, 246, 255);
        private static readonly Color TextS = Color.FromArgb(180, 174, 218);

        private static readonly Lcg Rnd = new Lcg(20261014);
        private static bool _inited;
        private static readonly List<double[]> Stars = new List<double[]>();
        private static readonly List<double> Ridge = new List<double>();
        private static readonly List<double[]> Petals = new List<double[]>();

        private const int W = 1920, H = 462;

        private static void Init()
        {
            if (_inited) return;
            Rnd.Reset(20261014);
            for (int i = 0; i < 180; i++)
            {
                Stars.Add(new double[] { Rnd.Next() * W, Rnd.Next() * 300,
                                         0.6 + Rnd.Next() * 1.6, Rnd.Next() * 6.28 });
            }
            for (int x = 0; x <= W; x += 20)
            {
                Ridge.Add(412 + Math.Sin(x * 0.0027) * 12 + Math.Sin(x * 0.0111 + 1.2) * 6);
            }
            for (int i = 0; i < 14; i++)
            {
                Petals.Add(new double[] { Rnd.Next() * W, Rnd.Next() * H,
                                          8 + Rnd.Next() * 14, 14 + Rnd.Next() * 22,
                                          Rnd.Next() * 6.28, 4 + Rnd.Next() * 5,
                                          0.35 + Rnd.Next() * 0.45 });
            }
            _inited = true;
        }

        public static void Render(Graphics g, State st, long now)
        {
            Init();
            Sky(g);
            StarsDraw(g, now);
            Moon(g);
            RidgeDraw(g, RidgeFar, 0.55);
            RidgeDraw(g, RidgeNear, 0.92);

            // 水面倒影（垂直翻转 + 低 alpha）
            GraphicsState gs = g.Save();
            g.TranslateTransform(0, 2 * 440);
            g.ScaleTransform(1, -1);
            RidgeDraw(g, RidgeNear, 0.22);
            g.Restore(gs);

            // 五格：半透明面板压在背景上（用户选定）
            double[] slotX = new double[] { 14, 298.4, 706, 1016, 1450 };
            double[] slotW = new double[] { 274.4, 398, 300, 424, 409 };
            string[] titles = new string[] { "系统", "DSH 会话", "用量", "虚拟机", "Dotii" };
            for (int i = 0; i < slotX.Length; i++)
            {
                Panel(g, slotX[i], 14, slotW[i], 434, titles[i],
                      (i % 2 == 0) ? Cyan : Pink);
            }
            Content(g, st, slotX, slotW);

            // 樱花画在面板之上（层次感）
            PetalsDraw(g, now);
        }

        private static void Sky(Graphics g)
        {
            using (LinearGradientBrush b = new LinearGradientBrush(
                       new Rectangle(0, 0, W, H), SkyTop, SkyHor, LinearGradientMode.Vertical))
            {
                ColorBlend cb = new ColorBlend(3);
                cb.Colors = new Color[] { SkyTop, SkyMid, SkyHor };
                cb.Positions = new float[] { 0f, 0.55f, 1f };
                b.InterpolationColors = cb;
                g.FillRectangle(b, 0, 0, W, H);
            }
        }

        private static void StarsDraw(Graphics g, long now)
        {
            for (int i = 0; i < Stars.Count; i++)
            {
                double[] s = Stars[i];
                double tw = 0.35 + 0.65 * Math.Abs(Math.Sin(now / 2400.0 + s[3]));
                Draw.FillCircle(g, s[0], s[1], s[2],
                    Color.FromArgb((int)(tw * 0.85 * 255), 255, 255, 255));
            }
        }

        private static void Moon(Graphics g)
        {
            double mx = 1560, my = 120, mr = 78;
            for (int i = 3; i >= 1; i--)
            {
                Draw.FillCircle(g, mx, my, mr + i * 18,
                    Color.FromArgb((int)(0.06 * i * 255), MoonC));
            }
            Draw.FillCircle(g, mx, my, mr, MoonC);
            Draw.FillCircle(g, mx - 22, my - 14, 20, Color.FromArgb(26, 138, 127, 168));
            Draw.FillCircle(g, mx + 18, my + 22, 13, Color.FromArgb(26, 138, 127, 168));
        }

        private static void RidgeDraw(Graphics g, Color c, double alpha)
        {
            PointF[] pts = new PointF[Ridge.Count + 2];
            for (int i = 0; i < Ridge.Count; i++)
            {
                pts[i] = new PointF((float)(i * 20), (float)Ridge[i]);
            }
            pts[Ridge.Count] = new PointF(W, H);
            pts[Ridge.Count + 1] = new PointF(0, H);
            using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(alpha * 255), c)))
            {
                g.FillPolygon(b, pts);
            }
        }

        private static void PetalsDraw(Graphics g, long now)
        {
            double tSec = now / 1000.0;
            for (int i = 0; i < Petals.Count; i++)
            {
                double[] p = Petals[i];
                double y = ((p[1] + tSec * p[2]) % (H + 40)) - 20;
                double x = p[0] + Math.Sin(tSec * 0.7 + p[4]) * p[3];
                GraphicsState gs = g.Save();
                g.TranslateTransform((float)x, (float)y);
                g.RotateTransform((float)((tSec * 0.9 + p[4]) * 180 / Math.PI));
                double sz = p[5];
                using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(p[6] * 255), Pink)))
                {
                    g.FillEllipse(b, (float)-sz / 2, (float)-sz, (float)sz, (float)(sz * 2));
                }
                g.Restore(gs);
            }
        }

        private static void Panel(Graphics g, double x, double y, double w, double h,
                                  string title, Color accent)
        {
            Draw.FillRound(g, x, y, w, h, 14, Color.FromArgb(158, PanelC));   // 0.62 半透明
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 14, BorderC, 1.5);
            Font f = F.SansFont(21, true);
            Draw.Text(g, title, x + w / 2, y + 32, f, accent, Draw.TextAlign.Center);
        }

        private static void Content(Graphics g, State st, double[] sx, double[] sw)
        {
            HostSnapshot hs = HostStats.Get(State.NowMs());
            double memPct = hs.MemTotalMB > 0 ? hs.MemUsedMB / hs.MemTotalMB * 100 : 0;

            // 系统格：CPU 环
            double cx = sx[0] + sw[0] / 2, cy = 172, r = 58;
            Draw.StrokeCircle(g, cx, cy, r, Color.FromArgb(42, 36, 80), 12);
            double p = Math.Max(0, Math.Min(100, hs.CpuPct));
            Draw.Arc(g, cx, cy, r, -90, p * 3.6, hs.CpuPct > 80 ? Pink : Cyan, 12);
            Font big = F.MonoFont(44, true);
            Draw.Text(g, string.Format("{0}%", (int)Math.Round(hs.CpuPct)), cx, cy, big, TextW, Draw.TextAlign.Center);
            Font lbl = F.SansFont(14, false);
            Draw.Text(g, "CPU", cx, cy + 36, lbl, TextS, Draw.TextAlign.Center);

            KV(g, sx[0] + 16, 282, "内存", hs.MemTotalMB > 0
                ? string.Format("{0:0.0} / {1:0.0} GB", hs.MemUsedMB / 1024, hs.MemTotalMB / 1024) : "--", TextW);
            Bar(g, sx[0] + 16, 310, sw[0] - 32, 10, memPct, Cyan);
            KV(g, sx[0] + 16, 346, "电量", hs.BatteryPct >= 0
                ? string.Format("{0}%", (int)hs.BatteryPct) : "--", Pink);

            // 会话格
            Font proj = F.MonoFont(28, true);
            Draw.Text(g, Fit(g, st.Data.Agent.Project, proj, sw[1] - 36), sx[1] + 18, 104, proj, TextW, Draw.TextAlign.Left);
            Font act = F.SansFont(20, true);
            Draw.Text(g, Fit(g, st.Data.Agent.Activity, act, sw[1] - 36), sx[1] + 18, 152, act, Cyan, Draw.TextAlign.Left);

            // 用量格
            Font kv = F.SansFont(15, false);
            Font kvm = F.MonoFont(20, true);
            Draw.Text(g, "今日 TOKEN", sx[2] + 16, 100, kv, TextS, Draw.TextAlign.Left);
            Draw.Text(g, Fmt(st.Data.Tokens.TodayTotal), sx[2] + sw[2] - 16, 100, kvm, TextW, Draw.TextAlign.Right);
            Draw.Text(g, "余额", sx[2] + 16, 156, kv, TextS, Draw.TextAlign.Left);
            Draw.Text(g, string.Format("¥{0:0.00}", st.Data.Balance.Total), sx[2] + sw[2] - 16, 156, kvm, Pink, Draw.TextAlign.Right);
            double winW = st.Data.Tokens.ContextWindow;
            double ctxPct = winW > 0 ? st.Data.Tokens.ContextUsed / winW * 100 : 0;
            Draw.Text(g, "上下文", sx[2] + 16, 212, kv, TextS, Draw.TextAlign.Left);
            Draw.Text(g, winW > 0 ? string.Format("{0:0.0}%", ctxPct) : "--", sx[2] + sw[2] - 16, 212, kvm, Cyan, Draw.TextAlign.Right);
            Bar(g, sx[2] + 16, 240, sw[2] - 32, 10, ctxPct, Cyan);


            // 大时钟
            DateTime d = DateTime.Now;
            Font clk = F.MonoFont(46, true);
            Draw.Text(g, string.Format("{0:00}:{1:00}", d.Hour, d.Minute),
                      sx[2] + sw[2] / 2, 330, clk, TextW, Draw.TextAlign.Center);

            // 虚拟机格 + Dotii 格（占位，与 ArkTS 侧同款文案）
            Font ph = F.SansFont(16, false);
            Draw.Text(g, "VM 画面", sx[3] + sw[3] / 2, 210, ph, TextS, Draw.TextAlign.Center);
            string ps = st.Data.Printer != null && !string.IsNullOrEmpty(st.Data.Printer.StateLabel)
                ? st.Data.Printer.StateLabel : "--";
            Font pf = F.SansFont(32, true);
            Draw.Text(g, ps, sx[4] + sw[4] / 2, 196, pf, Cyan, Draw.TextAlign.Center);
            Draw.Text(g, st.Data.Printer != null && st.Data.Printer.Percent >= 0
                ? string.Format("{0}%", (int)st.Data.Printer.Percent) : "--",
                sx[4] + sw[4] / 2, 244, ph, TextS, Draw.TextAlign.Center);
        }

        private static void KV(Graphics g, double x, double y, string label, string val, Color vc)
        {
            Font f = F.SansFont(15, false);
            Draw.Text(g, label, x, y, f, TextS, Draw.TextAlign.Left);
            Font m = F.MonoFont(20, true);
            Draw.Text(g, val, x + 240, y, m, vc, Draw.TextAlign.Right);
        }

        private static void Bar(Graphics g, double x, double y, double w, double h,
                                double pct, Color c)
        {
            Draw.FillRound(g, x, y, w, h, h / 2, Color.FromArgb(42, 36, 80));
            double p = Math.Max(0, Math.Min(100, pct));
            if (p > 0) Draw.FillRound(g, x, y, Math.Max(h, w * p / 100), h, h / 2, c);
        }

        internal static string Fit(Graphics g, string s, Font f, double maxW)
        {
            return Draw.Fit(g, s, f, maxW);
        }

        internal static string Fmt(double n)
        {
            if (n >= 100000000) return string.Format("{0:0.00}亿", n / 100000000);
            if (n >= 10000) return string.Format("{0:0.0}万", n / 10000);
            return ((long)Math.Round(n)).ToString();
        }
    }

    // ==================================================================
    // 主题 12：二次元·自由构图（无框）
    // ==================================================================
    public static class ThemeAnimeFree
    {
        private static readonly Color SkyTop = Color.FromArgb(7, 10, 28);
        private static readonly Color SkyMid = Color.FromArgb(26, 20, 64);
        private static readonly Color SkyLow = Color.FromArgb(59, 30, 82);
        private static readonly Color SkyHor = Color.FromArgb(122, 58, 99);
        private static readonly Color MoonC = Color.FromArgb(255, 248, 231);
        private static readonly Color RidgeC = Color.FromArgb(13, 10, 30);
        private static readonly Color TextW = Color.FromArgb(244, 248, 255);
        private static readonly Color Text2 = Color.FromArgb(185, 178, 224);
        private static readonly Color Cyan = Color.FromArgb(127, 231, 255);
        private static readonly Color Pink = Color.FromArgb(255, 154, 200);
        private static readonly Color Gold = Color.FromArgb(255, 217, 142);

        private const int W = 1920, H = 462;
        private const int StepMs = 500;

        private static readonly Lcg Rnd = new Lcg(20261014);
        private static bool _inited;
        private static readonly List<double[]> Stars = new List<double[]>();
        private static readonly List<double> Ridge = new List<double>();
        private static readonly List<double[]> Petals = new List<double[]>();

        private static void Init()
        {
            if (_inited) return;
            Rnd.Reset(20261014);
            for (int i = 0; i < 130; i++)
            {
                Stars.Add(new double[] { Rnd.Next() * W, Rnd.Next() * 250,
                                         0.5 + Rnd.Next() * 1.5, Rnd.Next() * 6.28 });
            }
            // ★ 山脊压到最底部（428 起伏 ±8）：ArkTS 侧实测取 352/412 都会盖住数据区
            for (int x = 0; x <= W; x += 20)
            {
                Ridge.Add(428 + Math.Sin(x * 0.0027) * 8 + Math.Sin(x * 0.0111 + 1.2) * 4);
            }
            for (int i = 0; i < 10; i++)
            {
                Petals.Add(new double[] { Rnd.Next() * W, Rnd.Next() * H,
                                          10 + Rnd.Next() * 16, 16 + Rnd.Next() * 24,
                                          Rnd.Next() * 6.28, 4 + Rnd.Next() * 4 });
            }
            _inited = true;
        }

        public static void Render(Graphics g, State st, long now)
        {
            Init();
            long q = (now / StepMs) * StepMs;          // 动画量化：500ms 内绘制完全一致
            Sky(g);
            StarsDraw(g, q);

            HostSnapshot hs = HostStats.Get(now);
            double memPct = hs.MemTotalMB > 0 ? hs.MemUsedMB / hs.MemTotalMB * 100 : 0;

            // 主标题：大时钟 + 日期
            DateTime d = DateTime.Now;
            Font clk = F.MonoFont(62, true);
            string clock = string.Format("{0:00}:{1:00}", d.Hour, d.Minute);
            // 发光：同位置多次低 alpha 重绘（不用 shadowBlur）
            Draw.Text(g, clock, 960, 96, clk, Color.FromArgb(56, Cyan), Draw.TextAlign.Center);
            Draw.Text(g, clock, 960, 96, clk, TextW, Draw.TextAlign.Center);
            Font sub = F.SansFont(17, false);
            string[] wk = new string[] { "日", "一", "二", "三", "四", "五", "六" };
            Draw.Text(g, string.Format("{0}/{1:00}/{2:00} 周{3}",
                d.Year, d.Month, d.Day, wk[(int)d.DayOfWeek]), 960, 138, sub, Text2, Draw.TextAlign.Center);

            Moon(g, 1652, 104, 70);

            // 数据：不用框，直接"漂"在画面上（左列左对齐 / 右列右对齐）
            Stat(g, 130, 178, "CPU", string.Format("{0}%", (int)Math.Round(hs.CpuPct)),
                 hs.CpuPct > 80 ? Pink : Cyan, Draw.TextAlign.Left);
            Stat(g, 130, 244, "MEM", hs.MemTotalMB > 0
                 ? string.Format("{0:0.1}/{1:0.1}G", hs.MemUsedMB / 1024, hs.MemTotalMB / 1024) : "--",
                 TextW, Draw.TextAlign.Left);
            if (hs.BatteryPct >= 0)
            {
                Stat(g, 130, 310, "BAT", string.Format("{0}%", (int)hs.BatteryPct),
                     hs.BatteryPct < 20 ? Pink : Gold, Draw.TextAlign.Left);
            }
            Wave(g, 620, 210, 420, 60, q, hs.CpuPct);

            Stat(g, 1888, 178, "TOKEN", ThemeAnimeBG.Fmt(st.Data.Tokens.TodayTotal), TextW, Draw.TextAlign.Right);
            Stat(g, 1888, 244, "余额", string.Format("¥{0:0.00}", st.Data.Balance.Total),
                 st.Data.Balance.Total > 0 ? Gold : Text2, Draw.TextAlign.Right);
            Stat(g, 1888, 310, "会话", st.Data.Agent.Project, Cyan, Draw.TextAlign.Right);

            // 山脊 + 倒影
            RidgeDraw(g, RidgeC, 0.94);
            GraphicsState gs = g.Save();
            g.TranslateTransform(0, 2 * 440);
            g.ScaleTransform(1, -1);
            RidgeDraw(g, RidgeC, 0.20);
            g.Restore(gs);

            PetalsDraw(g, q);
        }

        private static void Sky(Graphics g)
        {
            using (LinearGradientBrush b = new LinearGradientBrush(
                       new Rectangle(0, 0, W, H), SkyTop, SkyHor, LinearGradientMode.Vertical))
            {
                ColorBlend cb = new ColorBlend(4);
                cb.Colors = new Color[] { SkyTop, SkyMid, SkyLow, SkyHor };
                cb.Positions = new float[] { 0f, 0.5f, 0.82f, 1f };
                b.InterpolationColors = cb;
                g.FillRectangle(b, 0, 0, W, H);
            }
        }

        private static void StarsDraw(Graphics g, long now)
        {
            for (int i = 0; i < Stars.Count; i++)
            {
                double[] s = Stars[i];
                double tw = (0.3 + 0.6 * Math.Abs(Math.Sin(now / 2400.0 + s[3]))) * 0.85;
                Draw.FillCircle(g, s[0], s[1], s[2], Color.FromArgb((int)(tw * 255), 255, 255, 255));
            }
        }

        private static void Moon(Graphics g, double mx, double my, double mr)
        {
            for (int i = 3; i >= 1; i--)
            {
                Draw.FillCircle(g, mx, my, mr + i * 16, Color.FromArgb((int)(0.055 * i * 255), MoonC));
            }
            Draw.FillCircle(g, mx, my, mr, MoonC);
            Draw.FillCircle(g, mx - 18, my - 12, 17, Color.FromArgb(23, 156, 144, 184));
            Draw.FillCircle(g, mx + 15, my + 19, 11, Color.FromArgb(23, 156, 144, 184));
        }

        private static void RidgeDraw(Graphics g, Color c, double alpha)
        {
            PointF[] pts = new PointF[Ridge.Count + 2];
            for (int i = 0; i < Ridge.Count; i++) pts[i] = new PointF((float)(i * 20), (float)Ridge[i]);
            pts[Ridge.Count] = new PointF(W, H);
            pts[Ridge.Count + 1] = new PointF(0, H);
            using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(alpha * 255), c)))
            {
                g.FillPolygon(b, pts);
            }
        }

        /// <summary>数据"漂浮"：小标签 + 大数值，数值带细描边保证在渐变背景上有对比</summary>
        private static void Stat(Graphics g, double x, double y, string label, string val,
                                 Color c, Draw.TextAlign align)
        {
            Font lf = F.SansFont(14, false);
            Draw.Text(g, label, x, y, lf, Text2, align);
            Font vf = F.MonoFont(27, true);
            string shown = Fit(g, val, vf, 380);
            Draw.Text(g, shown, x, y + 32, vf, c, align);
        }

        private static void Wave(Graphics g, double x, double y, double w, double h,
                                 long now, double amp)
        {
            int n = 48;
            double phase = now / 900.0;
            double a = 0.25 + (amp / 100) * 0.9;
            PointF[] pts = new PointF[n + 3];
            for (int i = 0; i <= n; i++)
            {
                double px = x + w * i / n;
                double py = y + h / 2
                    + Math.Sin(i * 0.42 + phase) * h * 0.34 * a
                    + Math.Sin(i * 0.91 + phase * 1.7) * h * 0.16 * a;
                pts[i] = new PointF((float)px, (float)py);
            }
            pts[n + 1] = new PointF((float)(x + w), (float)(y + h));
            pts[n + 2] = new PointF((float)x, (float)(y + h));
            using (SolidBrush b = new SolidBrush(Color.FromArgb(71, Cyan)))
            {
                g.FillPolygon(b, pts);
            }
            using (Pen p = new Pen(Color.FromArgb(191, Cyan), 2))
            {
                for (int i = 1; i <= n; i++) g.DrawLine(p, pts[i - 1], pts[i]);
            }
        }

        private static void PetalsDraw(Graphics g, long now)
        {
            double tSec = now / 1000.0;
            for (int i = 0; i < Petals.Count; i++)
            {
                double[] p = Petals[i];
                double y = Math.Round(((p[1] + tSec * p[2]) % (H + 40)) - 20);
                double x = Math.Round(p[0] + Math.Sin(tSec * 0.7 + p[4]) * p[3]);
                GraphicsState gs = g.Save();
                g.TranslateTransform((float)x, (float)y);
                g.RotateTransform((float)((tSec * 0.9 + p[4]) * 180 / Math.PI));
                using (SolidBrush b = new SolidBrush(Color.FromArgb(128, Pink)))
                {
                    double sz = p[5];
                    g.FillEllipse(b, (float)-sz / 2, (float)-sz, (float)sz, (float)(sz * 2));
                }
                g.Restore(gs);
            }
        }

        private static string Fit(Graphics g, string s, Font f, double maxW)
        {
            return Draw.Fit(g, s, f, maxW);
        }
    }

    // ==================================================================
    // 主题 13：明亮二次元 HUD（唯一浅色主题）
    // ==================================================================
    public static class ThemeAnimeHUD
    {
        // NanoMuse 令牌 → 本主题（★ = 已做 4:2:0 预补偿）
        private static readonly Color BgTop = Color.FromArgb(0xF2, 0xF6, 0xFC);
        private static readonly Color BgBot = Color.FromArgb(0xDC, 0xE6, 0xF2);
        private static readonly Color CardC = Color.White;
        private static readonly Color BorderC = Color.FromArgb(0xB4, 0xCD, 0xE1);
        private static readonly Color Text1 = Color.FromArgb(0x1A, 0x2C, 0x3E);
        private static readonly Color Text2 = Color.FromArgb(0x4A, 0x64, 0x80);
        private static readonly Color Text3 = Color.FromArgb(0x80, 0x98, 0xB0);
        private static readonly Color Cyan = Color.FromArgb(0x2E, 0x9F, 0xB8);   // ★ #00b8d4
        private static readonly Color Blue = Color.FromArgb(0x3E, 0x7F, 0xB8);   // ★ #0096c7
        private static readonly Color Green = Color.FromArgb(0x20, 0xA8, 0x5A);  // ★ #00e676
        private static readonly Color Red = Color.FromArgb(0xD6, 0x3A, 0x57);    // ★ #ff3d57
        private static readonly Color Amber = Color.FromArgb(0xD9, 0x94, 0x00);
        private static readonly Color Rail = Color.FromArgb(0xC8, 0xDA, 0xEA);

        private const int W = 1920, H = 462;
        private const int StepMs = 500;

        public static void Render(Graphics g, State st, long now)
        {
            long q = (now / StepMs) * StepMs;
            Sky(g);
            Grid(g);
            Circuit(g);
            Corners(g);

            double[] sx = new double[] { 14, 298.4, 706, 1016, 1450 };
            double[] sw = new double[] { 274.4, 398, 300, 424, 409 };
            string[] titles = new string[] { "系统", "DSH 会话", "用量", "虚拟机", "Dotii" };
            for (int i = 0; i < sx.Length; i++) Card(g, sx[i], 14, sw[i], 434, titles[i]);

            HostSnapshot hs = HostStats.Get(now);
            double memPct = hs.MemTotalMB > 0 ? hs.MemUsedMB / hs.MemTotalMB * 100 : 0;
            // 健康度：CPU / RAM / (100-电量) 综合（NanoMuse 的核心语义）
            double health = hs.CpuPct;
            int n = 1;
            health += memPct; n++;
            if (hs.BatteryPct >= 0) { health += (100 - hs.BatteryPct); n++; }
            health = health / n;

            Ring(g, sx[0] + sw[0] / 2, 168, 56, 13, health,
                 health > 75 ? Red : (health > 50 ? Amber : Green),
                 ((int)Math.Round(health)).ToString());
            WmBar(g, sx[0] + 14, 262, sw[0] - 28, 16, hs.CpuPct, "CPU",
                  string.Format("{0} 核", hs.Cores), Cyan);
            WmBar(g, sx[0] + 14, 312, sw[0] - 28, 16, memPct, "RAM",
                  hs.MemTotalMB > 0 ? string.Format("{0:0}G", hs.MemTotalMB / 1024) : "--", Blue);
            if (hs.BatteryPct >= 0)
            {
                WmBar(g, sx[0] + 14, 362, sw[0] - 28, 16, hs.BatteryPct, "BAT",
                      string.Format("{0}%", (int)hs.BatteryPct), hs.BatteryPct < 20 ? Red : Green);
            }

            // DSH 会话格
            Font lf = F.SansFont(15, false);
            Font mf = F.MonoFont(22, true);
            Draw.ShrinkText(g, st.Data.Agent.Project, sx[1] + 18, 110,
                FontFamily.GenericMonospace, true, 30, 17, sw[1] - 36, Text1, Draw.TextAlign.Left);
            Font act = F.SansFont(19, true);
            Draw.Text(g, Draw.Fit(g, st.Data.Agent.Activity, act, sw[1] - 36),
                      sx[1] + 18, 156, act, Cyan, Draw.TextAlign.Left);

            // 用量格
            Draw.Text(g, "今日 TOKEN", sx[2] + 14, 96, lf, Text3, Draw.TextAlign.Left);
            Draw.Text(g, ThemeAnimeBG.Fmt(st.Data.Tokens.TodayTotal), sx[2] + sw[2] - 14, 96, mf, Text1, Draw.TextAlign.Right);
            Draw.Text(g, "余额", sx[2] + 14, 152, lf, Text3, Draw.TextAlign.Left);
            Draw.Text(g, string.Format("¥{0:0.00}", st.Data.Balance.Total), sx[2] + sw[2] - 14, 152, mf, Amber, Draw.TextAlign.Right);
            double winW = st.Data.Tokens.ContextWindow;
            double ctxPct = winW > 0 ? st.Data.Tokens.ContextUsed / winW * 100 : 0;
            WmBar(g, sx[2] + 14, 200, sw[2] - 28, 16, ctxPct, "CTX",
                  winW > 0 ? string.Format("{0:0}K", winW / 1000) : "--", Cyan);

            DateTime d = DateTime.Now;
            Font clk = F.MonoFont(56, true);
            Draw.Text(g, string.Format("{0:00}:{1:00}", d.Hour, d.Minute),
                      sx[2] + sw[2] / 2, 300, clk, Text1, Draw.TextAlign.Center);
            string[] wk = new string[] { "日", "一", "二", "三", "四", "五", "六" };
            Draw.Text(g, string.Format("{0}/{1:00}/{2:00} 周{3}", d.Year, d.Month, d.Day, wk[(int)d.DayOfWeek]),
                      sx[2] + sw[2] / 2, 340, lf, Text3, Draw.TextAlign.Center);


            // Dotii 格：打印机进度环
            double ppct = st.Data.Printer != null && st.Data.Printer.Percent >= 0
                ? st.Data.Printer.Percent : 0;
            Ring(g, sx[4] + sw[4] / 2, 190, 74, 15, ppct, Cyan, ((int)Math.Round(ppct)).ToString());
            Font pf = F.SansFont(24, true);
            Draw.Text(g, st.Data.Printer != null ? st.Data.Printer.StateLabel : "--",
                      sx[4] + sw[4] / 2, 300, pf, Text1, Draw.TextAlign.Center);
        }

        private static void Sky(Graphics g)
        {
            using (LinearGradientBrush b = new LinearGradientBrush(
                       new Rectangle(0, 0, W, H), BgTop, BgBot, LinearGradientMode.Horizontal))
            {
                g.FillRectangle(b, 0, 0, W, H);
            }
        }

        private static void Grid(Graphics g)
        {
            using (Pen p = new Pen(Color.FromArgb(10, 20, 90, 140), 1))   // alpha 0.04
            {
                for (int x = 0; x <= W; x += 64) g.DrawLine(p, x, 0, x, H);
                for (int y = 0; y <= H; y += 64) g.DrawLine(p, 0, y, W, y);
            }
        }

        /// <summary>NanoMuse 的电路线背景（折角走线 + 端点圆点）</summary>
        private static void Circuit(Graphics g)
        {
            double[][][] paths = new double[][][]
            {
                new double[][] { new double[]{-20,120}, new double[]{180,120}, new double[]{220,160}, new double[]{420,160} },
                new double[][] { new double[]{-20,300}, new double[]{140,300}, new double[]{180,260}, new double[]{340,260} },
                new double[][] { new double[]{1940,90}, new double[]{1740,90}, new double[]{1700,130}, new double[]{1520,130} },
                new double[][] { new double[]{1940,330}, new double[]{1760,330}, new double[]{1720,370}, new double[]{1560,370} },
                new double[][] { new double[]{900,-20}, new double[]{900,40}, new double[]{940,80}, new double[]{940,150} },
                new double[][] { new double[]{1100,-20}, new double[]{1100,30}, new double[]{1060,70}, new double[]{1060,120} },
            };
            using (Pen p = new Pen(Color.FromArgb(33, Cyan), 1.5f))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(33, Cyan)))
            {
                for (int i = 0; i < paths.Length; i++)
                {
                    double[][] pts = paths[i];
                    for (int k = 1; k < pts.Length; k++)
                    {
                        g.DrawLine(p, (float)pts[k - 1][0], (float)pts[k - 1][1],
                                      (float)pts[k][0], (float)pts[k][1]);
                    }
                    double[] last = pts[pts.Length - 1];
                    g.FillEllipse(b, (float)(last[0] - 3), (float)(last[1] - 3), 6, 6);
                }
            }
        }

        private static void Corners(Graphics g)
        {
            const double m = 10, len = 30;
            using (Pen p = new Pen(Color.FromArgb(115, Cyan), 2))
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

        private static void Card(Graphics g, double x, double y, double w, double h, string title)
        {
            Draw.FillRound(g, x, y, w, h, 12, Color.FromArgb(189, CardC));  // 0.74
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 12, BorderC, 1);
            // 卡头：青色斜纹标题条（12% 底 + 2px 分隔线）
            using (SolidBrush b = new SolidBrush(Color.FromArgb(31, Cyan)))
            {
                g.FillRectangle(b, (float)(x + 1), (float)(y + 1), (float)(w - 2), 40);
            }
            using (SolidBrush b = new SolidBrush(Cyan))
            {
                g.FillRectangle(b, (float)(x + 1), (float)(y + 41), (float)(w - 2), 2);
            }
            Font f = F.SansFont(20, true);
            Draw.Text(g, title, x + w / 2, y + 22, f, Text1, Draw.TextAlign.Center);
        }

        private static void Ring(Graphics g, double cx, double cy, double r, double thick,
                                 double pct, Color c, string text)
        {
            Draw.StrokeCircle(g, cx, cy, r, Rail, thick);
            double p = Math.Max(0, Math.Min(100, pct));
            if (p > 0) Draw.Arc(g, cx, cy, r, -90, p * 3.6, c, thick);
            Font f = F.MonoFont(44, true);
            Draw.Text(g, text, cx, cy + 2, f, Text1, Draw.TextAlign.Center);
            Font s = F.SansFont(14, false);
            Draw.Text(g, "%", cx, cy + 34, s, Text3, Draw.TextAlign.Center);
        }

        /// <summary>进度条 + 内嵌水印配置（NanoMuse 招牌手法）</summary>
        private static void WmBar(Graphics g, double x, double y, double w, double h,
                                  double pct, string wm1, string wm2, Color c)
        {
            Draw.FillRound(g, x, y, w, h, h / 2, Rail);
            double p = Math.Max(0, Math.Min(100, pct));
            if (p > 0) Draw.FillRound(g, x, y, Math.Max(h, w * p / 100), h, h / 2, c);
            Font f = F.MonoFont(12, false);
            Draw.Text(g, wm1, x + 10, y + h / 2 + 0.5, f, Color.FromArgb(140, 255, 255, 255), Draw.TextAlign.Left);
            Draw.Text(g, wm2, x + w - 10, y + h / 2 + 0.5, f, Color.FromArgb(140, 255, 255, 255), Draw.TextAlign.Right);
        }
    }

    // ==================================================================
    // 主题 14：NanoMuse（大字号版）
    // ==================================================================
    public static class ThemeNanoMuse
    {
        private const int W = 1920, H = 462;
        private const int TopH = 56, BotH = 52, Pad = 16;
        private const int ColLW = 560, ColRW = 560;

        // 大字号刻度（对照原版：标签 12→24、键 13→26、值 19→38、fleet 值 34→72、环 76→132）
        private const double FLabel = 24, FKey = 26, FVal = 38, FBig = 72, FHuge = 132;

        public static void Render(Graphics g, State st, long now)
        {
            long q = (now / 500) * 500;
            Backdrop.Render(g, W, H, q);          // 程序化背景（含 dim）
            BgShapes(g);
            Particles(g, q);

            double bodyY = TopH, bodyH = H - TopH - BotH;
            double leftX = Pad;
            double midX = leftX + ColLW + Pad;
            double midW = W - ColLW - ColRW - Pad * 4.0;
            double rightX = midX + midW + Pad;

            TopBar(g, st);
            LeftColumn(g, leftX, ColLW, st, bodyY, bodyH);
            CenterHero(g, midX, midW, st, bodyY, bodyH);
            RightColumn(g, rightX, ColRW, st, bodyY);
            BottomBar(g, st);
            if (st != null) { /* 保持签名一致 */ }
        }

        private static void BgShapes(Graphics g)
        {
            double[][] shapes = new double[][]
            {
                new double[]{40,80,210,130}, new double[]{330,320,140,90},
                new double[]{1180,100,220,110}, new double[]{1500,290,160,120},
                new double[]{1720,80,170,150}, new double[]{860,340,180,80},
            };
            using (Pen p = new Pen(Color.FromArgb(66, Backdrop.Dim(Color.FromArgb(46, 159, 184), 1.0)), 1))
            {
                for (int i = 0; i < shapes.Length; i++)
                {
                    g.DrawRectangle(p, (float)shapes[i][0], (float)shapes[i][1],
                                       (float)shapes[i][2], (float)shapes[i][3]);
                }
            }
        }

        private static readonly Lcg Rnd2 = new Lcg(20261017);
        private static bool _pInit;
        private static readonly List<double[]> Parts = new List<double[]>();

        private static void Particles(Graphics g, long now)
        {
            if (!_pInit)
            {
                Rnd2.Reset(20261017);
                for (int i = 0; i < 6; i++)
                {
                    Parts.Add(new double[] { ColLW + Rnd2.Next() * (W - ColLW - ColRW),
                                             Rnd2.Next() * (H - TopH - BotH),
                                             3 + Rnd2.Next() * 5, 5 + Rnd2.Next() * 8,
                                             Rnd2.Next() * 6.28 });
                }
                _pInit = true;
            }
            double tSec = Math.Floor(now / 1500.0) * 1.5;   // 1.5s 步进（省 JPEG 编码）
            double bodyH = H - TopH - BotH;
            using (Pen p = new Pen(Color.FromArgb(51, Color.FromArgb(46, 159, 184)), 1.2f))
            {
                for (int i = 0; i < Parts.Count; i++)
                {
                    double[] pt = Parts[i];
                    double y = TopH + bodyH - ((pt[1] + tSec * pt[3]) % (bodyH + 20));
                    double x = Math.Round(pt[0] + Math.Sin(tSec * 0.5 + pt[4]) * 12);
                    g.DrawEllipse(p, (float)(x - pt[2]), (float)(y - pt[2]),
                                     (float)(pt[2] * 2), (float)(pt[2] * 2));
                }
            }
        }

        private static void TopBar(Graphics g, State st)
        {
            using (SolidBrush b = new SolidBrush(Color.FromArgb(148, Color.White)))
            {
                g.FillRectangle(b, 0, 0, W, TopH);
            }
            using (Pen p = new Pen(Color.FromArgb(0xB4, 0xCD, 0xE1), 1))
            {
                g.DrawLine(p, 0, TopH + 0.5f, W, TopH + 0.5f);
            }
            double ly = TopH / 2.0, lx = Pad + 14;
            Color cyan = Color.FromArgb(46, 159, 184);
            PointF[] dia = new PointF[]
            {
                new PointF((float)lx, (float)(ly - 12)), new PointF((float)(lx + 12), (float)ly),
                new PointF((float)lx, (float)(ly + 12)), new PointF((float)(lx - 12), (float)ly),
            };
            using (SolidBrush b = new SolidBrush(cyan)) { g.FillPolygon(b, dia); }

            Font bf = F.MonoFont(30, true);
            double bw = Draw.Tracked(g, "NANOMUSE", lx + 24, ly, bf, Color.FromArgb(0x1A, 0x2C, 0x3E), 6, Draw.TextAlign.Left);
            Font sf = F.SansFont(24, false);
            Draw.Text(g, "TROFEO 9.16", lx + 34 + bw, ly, sf, Color.FromArgb(0x80, 0x98, 0xB0), Draw.TextAlign.Left);

            DateTime d = DateTime.Now;
            Font df = F.SansFont(22, false);
            string[] wk = new string[] { "日", "一", "二", "三", "四", "五", "六" };
            Draw.Text(g, string.Format("{0:00}/{1:00} 周{2}", d.Month, d.Day, wk[(int)d.DayOfWeek]),
                      W - Pad - 168, ly + 2, df, Color.FromArgb(0x80, 0x98, 0xB0), Draw.TextAlign.Right);
            Font cf = F.MonoFont(38, true);
            Draw.Text(g, string.Format("{0:00}:{1:00}", d.Hour, d.Minute),
                      W - Pad - 236, ly, cf, Color.FromArgb(0x1A, 0x2C, 0x3E), Draw.TextAlign.Right);

            HostSnapshot hs = HostStats.Get(State.NowMs());
            Color dot = hs.Valid ? Color.FromArgb(0x20, 0xA8, 0x5A) : Color.FromArgb(0xD6, 0x3A, 0x57);
            Draw.FillCircle(g, W - Pad - 16, ly, 7, dot);
            Font of = F.MonoFont(22, false);
            Draw.Text(g, hs.Valid ? "ON" : "OFF", W - Pad - 34, ly, of, Color.FromArgb(0x4A, 0x64, 0x80), Draw.TextAlign.Right);
        }

        private static void BottomBar(Graphics g, State st)
        {
            double y0 = H - BotH;
            using (SolidBrush b = new SolidBrush(Color.FromArgb(148, Color.White)))
            {
                g.FillRectangle(b, 0, (float)y0, W, BotH);
            }
            using (Pen p = new Pen(Color.FromArgb(0xB4, 0xCD, 0xE1), 1))
            {
                g.DrawLine(p, 0, (float)(y0 + 0.5), W, (float)(y0 + 0.5));
            }
            double cy = y0 + BotH / 2.0;
            string[][] items = new string[][]
            {
                new string[]{ "余额", string.Format("¥{0:0.00}", st.Data.Balance.Total) },
                new string[]{ "TOKEN", ThemeAnimeBG.Fmt(st.Data.Tokens.TodayTotal) },
                new string[]{ "运行", Uptime(st.Data.System.UptimeSec) },
            };
            double cw = (W - Pad * 2.0) / items.Length;
            for (int i = 0; i < items.Length; i++)
            {
                double x = Pad + i * cw;
                Font lf = F.MonoFont(18, false);
                Draw.Tracked(g, items[i][0], x, cy - 12, lf, Color.FromArgb(0x80, 0x98, 0xB0), 3, Draw.TextAlign.Left);
                Font vf = F.MonoFont(30, true);
                Draw.Text(g, items[i][1], x, cy + 14, vf, Color.FromArgb(0x1A, 0x2C, 0x3E), Draw.TextAlign.Left);
                if (i > 0)
                {
                    using (Pen p = new Pen(Color.FromArgb(0xB4, 0xCD, 0xE1), 1))
                    {
                        g.DrawLine(p, (float)(x - Pad), (float)(y0 + 10), (float)(x - Pad), H - 10);
                    }
                }
            }
        }

        private static void LeftColumn(Graphics g, double x, double w, State st,
                                       double bodyY, double bodyH)
        {
            HostSnapshot hs = HostStats.Get(State.NowMs());
            double memPct = hs.MemTotalMB > 0 ? hs.MemUsedMB / hs.MemTotalMB * 100 : 0;

            // ★ 格高 92：实测 138 会让 SESSION 两行超出内容区底 114px
            double gw = (w - Pad) / 2.0, gh = 92, g0 = bodyY + 14;
            string[][] boxes = new string[][]
            {
                new string[]{ "CPU", string.Format("{0}%", (int)Math.Round(hs.CpuPct)) },
                new string[]{ "MEM", hs.MemTotalMB > 0 ? string.Format("{0}%", (int)Math.Round(memPct)) : "--" },
                new string[]{ "BAT", hs.BatteryPct >= 0 ? string.Format("{0}%", (int)hs.BatteryPct) : "--" },
                new string[]{ "TOKEN", ThemeAnimeBG.Fmt(st.Data.Tokens.TodayTotal) },
            };
            Color[] cols = new Color[]
            {
                Color.FromArgb(46, 159, 184), Color.FromArgb(62, 127, 184),
                hs.BatteryPct >= 0 && hs.BatteryPct < 20 ? Color.FromArgb(214, 58, 87) : Color.FromArgb(32, 168, 90),
                Color.FromArgb(217, 148, 0),
            };
            for (int i = 0; i < boxes.Length; i++)
            {
                double bx = x + (i % 2) * (gw + Pad);
                double by = g0 + (i / 2) * (gh + 10);
                BigTile(g, bx, by, gw, gh, boxes[i][0], boxes[i][1], cols[i]);
            }

            double dy = g0 + gh * 2 + 10 + 20;
            SectionLabel(g, x, dy, "SESSION");
            dy += 30;
            DetRow(g, x, w, dy, "项目", st.Data.Agent.Project, Color.FromArgb(0x1A, 0x2C, 0x3E));
            dy += 42;
            string act = st.Data.Agent.Activity;
            if (!string.IsNullOrEmpty(st.Data.Agent.Model))
            {
                string m = st.Data.Agent.Model;
                if (m.StartsWith("deepseek-")) m = m.Substring(9);
                act = act + " · " + m;
            }
            DetRow(g, x, w, dy, "状态", act, Color.FromArgb(46, 159, 184));
        }

        private static void BigTile(Graphics g, double x, double y, double w, double h,
                                    string label, string val, Color col)
        {
            Draw.FillRound(g, x, y, w, h, 14, Color.FromArgb(184, Color.White));
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 14, Color.FromArgb(0xB4, 0xCD, 0xE1), 1);
            Font lf = F.MonoFont(FLabel, false);
            Draw.Tracked(g, label, x + 18, y + 22, lf, Color.FromArgb(0x80, 0x98, 0xB0), 5, Draw.TextAlign.Left);
            Font vf = F.MonoFont(FBig, true);
            string shown = Draw.Fit(g, val, vf, w - 40);
            Draw.Text(g, shown, x + 18, y + h - 40, vf, col, Draw.TextAlign.Left);
        }

        private static void CenterHero(Graphics g, double x, double w, State st,
                                       double bodyY, double bodyH)
        {
            HostSnapshot hs = HostStats.Get(State.NowMs());
            double memPct = hs.MemTotalMB > 0 ? hs.MemUsedMB / hs.MemTotalMB * 100 : 0;
            double health = hs.CpuPct + memPct; int n = 2;
            if (hs.BatteryPct >= 0) { health += (100 - hs.BatteryPct); n++; }
            health /= n;

            double cx = x + w / 2, cy = bodyY + bodyH / 2 - 6, R = 132;
            Draw.StrokeCircle(g, cx, cy, R, Color.FromArgb(0xCF, 0xDE, 0xEB), 24);
            double p = Math.Max(0, Math.Min(100, health));
            if (p > 0)
            {
                Draw.Arc(g, cx, cy, R, -90, p * 3.6,
                    health > 75 ? Color.FromArgb(214, 58, 87)
                    : (health > 50 ? Color.FromArgb(217, 148, 0) : Color.FromArgb(32, 168, 90)), 24);
            }
            Font hf = F.MonoFont(FHuge, true);
            Draw.Text(g, ((int)Math.Round(health)).ToString(), cx, cy, hf, Color.FromArgb(0x1A, 0x2C, 0x3E), Draw.TextAlign.Center);
            Font lf = F.SansFont(28, false);
            Draw.Text(g, "HEALTH", cx, cy + 92, lf, Color.FromArgb(0x80, 0x98, 0xB0), Draw.TextAlign.Center);
        }

        private static void RightColumn(Graphics g, double x, double w, State st, double bodyY)
        {
            SectionLabel(g, x, bodyY + 16, "PRINTER");
            double ppct = st.Data.Printer != null && st.Data.Printer.Percent >= 0
                ? st.Data.Printer.Percent : 0;
            double cx = x + w / 2, cy = bodyY + 156, R = 92;
            Draw.StrokeCircle(g, cx, cy, R, Color.FromArgb(0xCF, 0xDE, 0xEB), 20);
            if (ppct > 0) Draw.Arc(g, cx, cy, R, -90, ppct * 3.6, Color.FromArgb(46, 159, 184), 20);
            Font vf = F.MonoFont(84, true);
            Draw.Text(g, ((int)Math.Round(ppct)).ToString(), cx, cy - 6, vf, Color.FromArgb(0x1A, 0x2C, 0x3E), Draw.TextAlign.Center);
            Font pf = F.SansFont(44, true);
            Draw.Text(g, st.Data.Printer != null ? st.Data.Printer.StateLabel : "--",
                      cx, bodyY + 288, pf, Color.FromArgb(0x1A, 0x2C, 0x3E), Draw.TextAlign.Center);
            Font sf = F.MonoFont(28, false);
            string lr = st.Data.Printer != null && st.Data.Printer.Layer >= 0
                ? string.Format("层 {0}{1}", (int)st.Data.Printer.Layer,
                    st.Data.Printer.TotalLayer > 0 ? " / " + ((int)st.Data.Printer.TotalLayer).ToString() : "")
                : "--";
            Draw.Text(g, lr, cx, bodyY + 332, sf, Color.FromArgb(0x4A, 0x64, 0x80), Draw.TextAlign.Center);
        }

        private static void SectionLabel(Graphics g, double x, double y, string text)
        {
            Font f = F.MonoFont(FLabel, false);
            double w = Draw.Tracked(g, text, x, y, f, Color.FromArgb(0x80, 0x98, 0xB0), 5, Draw.TextAlign.Left);
            using (Pen p = new Pen(Color.FromArgb(0xB4, 0xCD, 0xE1), 1))
            {
                g.DrawLine(p, (float)(x + w + 12), (float)(y + 0.5), (float)(x + w + 150), (float)(y + 0.5));
            }
        }

        /// <summary>NanoMuse 的 `.det-row`：键 + 纯色分隔线 + 值右对齐</summary>
        private static void DetRow(Graphics g, double x, double w, double y,
                                   string key, string val, Color vc)
        {
            Font kf = F.MonoFont(FKey, false);
            Draw.Text(g, key, x, y, kf, Color.FromArgb(0x80, 0x98, 0xB0), Draw.TextAlign.Left);
            double kw = Draw.Measure(g, key, kf);
            Font vf = F.MonoFont(FVal, true);
            string shown = Draw.Fit(g, val, vf, w - kw - 30);
            double vw = Draw.Measure(g, shown, vf);
            double lx = x + kw + 12, lw = w - kw - vw - 28;
            if (lw > 10)
            {
                using (Pen p = new Pen(Color.FromArgb(56, Color.FromArgb(148, 163, 184)), 1))
                {
                    g.DrawLine(p, (float)lx, (float)(y + 0.5), (float)(lx + lw), (float)(y + 0.5));
                }
            }
            Draw.Text(g, shown, x + w, y, vf, vc, Draw.TextAlign.Right);
        }

        private static string Uptime(double sec)
        {
            double d = Math.Floor(sec / 86400), hh = Math.Floor((sec % 86400) / 3600);
            return string.Format("{0}d{1}h", (int)d, (int)hh);
        }
    }

    // ==================================================================
    // 主题 15：trofeo-lcd（复刻 haven80/trofeo-lcd-rs）
    // ==================================================================
    public static class ThemeTrofeoRust
    {
        private const int W = 1920, H = 462;
        private const int Side = 20, Gap = 16;

        /// <summary>4:2:0 预补偿：通道压进 [0x18,0xE8]，青色系抬 R（该屏实测纯青会被吃掉）</summary>
        private static Color Precomp(int r, int gg, int b)
        {
            int rr = Math.Min(0xE8, Math.Max(0x18, r));
            int g2 = Math.Min(0xE8, Math.Max(0x18, gg));
            int b2 = Math.Min(0xE8, Math.Max(0x18, b));
            if (rr < 0x60 && g2 > 0xB0 && b2 > 0x90) rr = Math.Min(0xE8, rr + 0x38);
            return Color.FromArgb(rr, g2, b2);
        }

        /// <summary>12 套调色板（RGB 逐字节照抄它 `effect.rs:78-100`）</summary>
        private static readonly int[][][] Palettes = new int[][][]
        {
            // pastel
            new int[][]{ new int[]{0xFF,0xB3,0xBA}, new int[]{0xFF,0xDF,0xBA}, new int[]{0xFF,0xFF,0xBA},
                         new int[]{0xBA,0xFF,0xC9}, new int[]{0xBA,0xE1,0xFF}, new int[]{0xDA,0xC4,0xFF} },
            // fluo
            new int[][]{ new int[]{0xFF,0x00,0x80}, new int[]{0xFF,0xF0,0x00}, new int[]{0x00,0xFF,0x78},
                         new int[]{0x00,0xC8,0xFF}, new int[]{0x96,0x00,0xFF} },
            // neon
            new int[][]{ new int[]{0xFF,0x00,0xC8}, new int[]{0x6E,0x00,0xFF},
                         new int[]{0x00,0x8C,0xFF}, new int[]{0x00,0xFF,0xDC} },
            // candy
            new int[][]{ new int[]{0xFF,0x8A,0xC8}, new int[]{0xFF,0xC8,0xE8}, new int[]{0x9A,0xE6,0xFF},
                         new int[]{0xB4,0xFF,0xDC}, new int[]{0xD8,0xA8,0xFF} },
            // sunset
            new int[][]{ new int[]{0x3A,0x10,0x70}, new int[]{0xC8,0x20,0x80}, new int[]{0xFF,0x60,0x30},
                         new int[]{0xFF,0xC0,0x50}, new int[]{0xB0,0x20,0x90} },
            // ocean
            new int[][]{ new int[]{0x00,0x20,0x70}, new int[]{0x00,0x78,0xD0},
                         new int[]{0x00,0xC8,0xD0}, new int[]{0x20,0x50,0xB0} },
            // aurora
            new int[][]{ new int[]{0x00,0x30,0x40}, new int[]{0x00,0xC0,0x80}, new int[]{0x60,0xFF,0xB0},
                         new int[]{0x70,0x40,0xD0}, new int[]{0x10,0x20,0x70} },
            // fire
            new int[][]{ new int[]{0x30,0x00,0x00}, new int[]{0xC0,0x20,0x00}, new int[]{0xFF,0x80,0x00},
                         new int[]{0xFF,0xD0,0x40}, new int[]{0x80,0x10,0x00} },
            // forest
            new int[][]{ new int[]{0x00,0x30,0x18}, new int[]{0x10,0x80,0x40},
                         new int[]{0x90,0xD0,0x50}, new int[]{0x00,0x50,0x40} },
            // ice
            new int[][]{ new int[]{0x30,0x50,0xB0}, new int[]{0x70,0xB0,0xFF},
                         new int[]{0xD0,0xF4,0xFF}, new int[]{0x60,0x90,0xE0} },
            // mono
            new int[][]{ new int[]{0x20,0x24,0x30}, new int[]{0xB8,0xC0,0xD0}, new int[]{0x50,0x58,0x68} },
        };

        private static readonly string[] PaletteNames = new string[]
        { "pastel", "fluo", "neon", "candy", "sunset", "ocean", "aurora", "fire", "forest", "ice", "mono" };

        /// <summary>13 个版面（照它 `LayoutDef` 的 rows of (widget, span) 结构）</summary>
        private class Layout
        {
            public string Name;
            public int Cols;
            public string[][] Rows;
            public int[][] Spans;
        }

        private static readonly Layout[] Layouts = new Layout[]
        {
            Mk("cpu-gpu", 2, new string[][]{ new string[]{"cpu","mem"}, new string[]{"clock","net"} },
                            new int[][]{ new int[]{1,1}, new int[]{1,1} }),
            Mk("temps", 2, new string[][]{ new string[]{"cpu","mem"} }, new int[][]{ new int[]{1,1} }),
            Mk("overview", 4, new string[][]{ new string[]{"cpu","mem","bat","clock"} }, new int[][]{ new int[]{1,1,1,1} }),
            Mk("grid6", 3, new string[][]{ new string[]{"cpu","mem","bat"}, new string[]{"clock","net","disk"} },
                           new int[][]{ new int[]{1,1,1}, new int[]{1,1,1} }),
            Mk("clock-center", 4, new string[][]{ new string[]{"cpu","clock","mem"} }, new int[][]{ new int[]{1,2,1} }),
            Mk("io", 3, new string[][]{ new string[]{"net","disk","uptime"} }, new int[][]{ new int[]{1,1,1} }),
            Mk("music", 3, new string[][]{ new string[]{"clock","net"} }, new int[][]{ new int[]{2,1} }),
            Mk("gaming", 4, new string[][]{ new string[]{"bat","cpu","mem","uptime"} }, new int[][]{ new int[]{1,1,1,1} }),
            Mk("cpu", 1, new string[][]{ new string[]{"cpu"} }, new int[][]{ new int[]{1} }),
            Mk("gpu", 1, new string[][]{ new string[]{"mem"} }, new int[][]{ new int[]{1} }),
            Mk("weather", 1, new string[][]{ new string[]{"disk","clock"} }, new int[][]{ new int[]{1,1} }),
            Mk("news", 1, new string[][]{ new string[]{"net"} }, new int[][]{ new int[]{1} }),
            Mk("default", 1, new string[][]{ new string[]{"cpu","clock","net"} }, new int[][]{ new int[]{1,1,1} }),
        };

        private static Layout Mk(string name, int cols, string[][] rows, int[][] spans)
        {
            Layout l = new Layout();
            l.Name = name; l.Cols = cols; l.Rows = rows; l.Spans = spans;
            return l;
        }

        public static void Render(Graphics g, State st, long now)
        {
            // 版面每 20 秒换、调色板每 30 秒换（与 ArkTS 侧同周期）
            int li = (int)((now / 20000) % Layouts.Length);
            int pi = (int)((now / 30000) % Palettes.Length);
            Layout def = Layouts[li];
            int[][] pal = Palettes[pi];

            Backdrop.Render(g, W, H, now);

            double usableW = W - Side * 2.0;
            int nrows = def.Rows.Length;
            double unit = Math.Floor((usableW - Gap * (def.Cols - 1)) / def.Cols);
            double ch = Math.Floor((H - Side * 2.0 - Gap * (nrows - 1)) / nrows);

            for (int ri = 0; ri < nrows; ri++)
            {
                int col = 0;
                string[] row = def.Rows[ri];
                int[] spans = def.Spans[ri];
                for (int ci = 0; ci < row.Length; ci++)
                {
                    int span = spans[ci];
                    double cw = unit * span + Gap * (span - 1);
                    double cx = Side + col * (unit + Gap);
                    double cy = Side + ri * (ch + Gap);
                    Cell(g, cx, cy, cw, ch, row[ci], st, pal, ri * 3 + ci, now);
                    col += span;
                }
            }

            Font sf = F.MonoFont(13, false);
            Draw.Text(g, string.Format("layout={0}   palette={1}   {2}",
                def.Name, PaletteNames[pi], Backdrop.StatusLine()),
                Side + 4, Side - 8, sf, Col(pal, 1), Draw.TextAlign.Left);
        }

        private static Color Col(int[][] pal, int i)
        {
            int n = pal.Length;
            int[] c = pal[((i % n) + n) % n];
            return Precomp(c[0], c[1], c[2]);
        }

        private static void Cell(Graphics g, double x, double y, double w, double h,
                                 string widget, State st, int[][] pal, int seed, long now)
        {
            HostSnapshot hs = HostStats.Get(now);
            string label = "", val = "", sub = "";
            double pct = -1;
            int accent = 0;

            if (widget == "cpu")
            {
                label = "CPU"; val = string.Format("{0}%", (int)Math.Round(hs.CpuPct));
                sub = string.Format("{0} cores", hs.Cores); pct = hs.CpuPct; accent = 1;
            }
            else if (widget == "mem")
            {
                label = "RAM";
                double mp = hs.MemTotalMB > 0 ? hs.MemUsedMB / hs.MemTotalMB * 100 : 0;
                val = hs.MemTotalMB > 0 ? string.Format("{0}%", (int)Math.Round(mp)) : "--";
                sub = hs.MemTotalMB > 0 ? string.Format("{0:0.0}/{1:0.0} GB", hs.MemUsedMB / 1024, hs.MemTotalMB / 1024) : "";
                pct = hs.MemTotalMB > 0 ? mp : -1; accent = 2;
            }
            else if (widget == "bat")
            {
                label = "BATTERY";
                val = hs.BatteryPct >= 0 ? string.Format("{0}%", (int)hs.BatteryPct) : "--";
                sub = hs.Charging ? "charging" : (hs.BatteryPct >= 0 ? "on battery" : "no battery");
                pct = hs.BatteryPct; accent = 3;
            }
            else if (widget == "clock")
            {
                DateTime d = DateTime.Now;
                label = "CLOCK"; val = string.Format("{0:00}:{1:00}", d.Hour, d.Minute);
                string[] wk = new string[] { "日", "一", "二", "三", "四", "五", "六" };
                sub = string.Format("{0:00}/{1:00} 周{2}", d.Month, d.Day, wk[(int)d.DayOfWeek]); accent = 0;
            }
            else if (widget == "net")
            {
                label = "NETWORK"; val = Rate(hs.NetRxKBs);
                sub = string.Format("↓{0}  ↑{1}", Rate(hs.NetRxKBs), Rate(hs.NetTxKBs)); accent = 1;
            }
            else if (widget == "disk")
            {
                label = "DISK"; val = string.Format("{0}%", (int)Math.Round(hs.DiskUsedPct));
                sub = hs.DiskTotalGB > 0 ? string.Format("{0:0} GB total", hs.DiskTotalGB) : "";
                pct = hs.DiskUsedPct; accent = 2;
            }
            else if (widget == "uptime")
            {
                label = "SYSTEM"; val = string.Format("{0}", hs.Cores); sub = "cpu cores"; accent = 3;
            }

            Panel(g, x, y, w, h, label, val, sub, pct,
                  Col(pal, accent), Col(pal, accent), 1.0, seed);
        }

        private static string Rate(double kbs)
        {
            if (kbs < 0.05) return "idle";
            if (kbs < 1024) return string.Format("{0:0.0} KB/s", kbs);
            return string.Format("{0:0.0} MB/s", kbs / 1024);
        }

        private static void Panel(Graphics g, double x, double y, double w, double h,
                                  string label, string val, string sub, double pct,
                                  Color color, Color prevColor, double fade, int seed)
        {
            Draw.FillRound(g, x, y, w, h, 8, Color.FromArgb(184, 14, 14, 22));   // 0.72 半透明
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 8, Color.FromArgb(0x2A, 0x2A, 0x38), 1);
            using (SolidBrush b = new SolidBrush(Color.FromArgb(230, color)))
            {
                g.FillRectangle(b, (float)(x + 1), (float)(y + 10), 4, (float)(h - 20));
            }

            Font lf = F.MonoFont(14, false);
            Draw.Text(g, label, x + 18, y + 24, lf, Color.FromArgb(0x7A, 0x80, 0x90), Draw.TextAlign.Left);

            // 大字值：按面板高度自动缩字号
            bool isTime = val.IndexOf(':') > 0;
            double size = Math.Min(h * 0.52, isTime ? 96 : 82);
            if (size < 20) size = 20;
            Font vf = F.MonoFont(size, true);
            while (size > 20 && Draw.Measure(g, val, vf) > w - 36)
            {
                size -= 2;
                vf = F.MonoFont(size, true);
            }
            Draw.Text(g, val, x + 18, y + h * 0.58, vf, color, Draw.TextAlign.Left);

            if (!string.IsNullOrEmpty(sub))
            {
                Font sf = F.MonoFont(14, false);
                Draw.Text(g, Draw.Fit(g, sub, sf, w - 36), x + 18, y + h - 22, sf,
                          Color.FromArgb(0x6A, 0x70, 0x80), Draw.TextAlign.Left);
            }

            if (pct >= 0)
            {
                double bh = 8, by = y + h - 14, bw = w - 36;
                Draw.FillRound(g, x + 18, by, bw, bh, bh / 2, Color.FromArgb(0x22, 0x22, 0x2C));
                double p = Math.Max(0, Math.Min(100, pct));
                if (p > 0) Draw.FillRound(g, x + 18, by, Math.Max(bh, bw * p / 100), bh, bh / 2, color);
                // 峰值帽（借它 spectrum 的 peaks 语义）
                double peak = Math.Min(100, p + 4 + (seed % 5));
                using (SolidBrush b = new SolidBrush(Color.FromArgb(140, 255, 255, 255)))
                {
                    g.FillRectangle(b, (float)(x + 18 + bw * peak / 100 - 1), (float)(by - 2), 2, (float)(bh + 4));
                }
            }
        }
    }
}
