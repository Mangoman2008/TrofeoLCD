/**
 * ThemeMac.cs — 主题 8「MacTR 五格」（C# 5 移植版）
 *
 * 逐值移植自 `entry/src/main/ets/render/ThemeMac.ets`（295 行）。
 * 来源：社区项目 **MacTR**（`beret21/MacTR`，macOS 版利民屏驱动）的设计令牌与绘制原语。
 *
 * ## 与主题 0 的关系
 * **几何完全一致**（margin 14 / gap 10 / 5 格 / 274.4×434）——所以这不是"新布局"，
 * 而是**同一套格子里换一套视觉语言**：
 *   · 面板圆角 **16**（主题 0 是 14）、描边 `#262A3A`
 *   · 强调色**顶条**：`x+2, y, w−4, 高 3px`、圆角 2
 *   · 顶条下方 **6 行 1px 渐隐光晕**（`alpha = 0.12 × (1 − i/6)`）
 *   · **弧表**：270° 扫角（135°→405°）、圆头端点、末端一个 `thickness/2` 的圆点
 *   · 阈值配色：`pct < 50 → green`、`< 75 → orange`、否则 `red`
 *   · 进度条圆角 = `h/2`、轨道 `#1E2230`
 *
 * ## 数据源全是本机真实项
 * CPU / 内存 / DSH token / SYSTEM / DSH 会话。
 * （MacTR 原版 5 格是 CPU/GPU/内存/磁盘/SYSTEM；本机没有独显、C# 也没有磁盘读数，
 *   所以第 2 格改成 token、第 4 格用运行时长 —— **宁可用真实数据换格子内容，也不编数值**。）
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace DshLcd
{
    public static class ThemeMac
    {
        // ---- MacTR 设计令牌（取自 DesignTokens.swift:11-41）----
        private static readonly Color BgTop = Color.FromArgb(0x0A, 0x0C, 0x14);
        private static readonly Color BgBot = Color.FromArgb(0x10, 0x12, 0x1C);
        private static readonly Color PanelC = Color.FromArgb(0x14, 0x17, 0x22);
        private static readonly Color BorderC = Color.FromArgb(0x26, 0x2A, 0x3A);
        private static readonly Color TextW = Color.FromArgb(0xE6, 0xEB, 0xF5);
        private static readonly Color TextS = Color.FromArgb(0x8C, 0x94, 0xA8);
        private static readonly Color TextL = Color.FromArgb(0x64, 0x6C, 0x82);
        private static readonly Color Blue = Color.FromArgb(0x42, 0x85, 0xF4);
        private static readonly Color Green = Color.FromArgb(0x34, 0xD3, 0x99);
        private static readonly Color Cyan = Color.FromArgb(0x22, 0xD3, 0xEE);
        private static readonly Color Magenta = Color.FromArgb(0xD9, 0x46, 0xEF);
        private static readonly Color Orange = Color.FromArgb(0xFB, 0xBF, 0x24);
        private static readonly Color Red = Color.FromArgb(0xEF, 0x44, 0x44);
        private static readonly Color BarBg = Color.FromArgb(0x1E, 0x22, 0x30);

        /// <summary>阈值配色（DesignTokens.swift:40-46）</summary>
        private static Color PctColor(double pct)
        {
            if (pct < 50) return Green;
            if (pct < 75) return Orange;
            return Red;
        }

        public static void Render(Graphics g, State st)
        {
            Background(g);

            Telemetry t = (st == null) ? null : st.Data;
            SystemInfo sys = (t == null) ? null : t.System;
            TokenInfo tk = (t == null) ? null : t.Tokens;
            AgentInfo ag = (t == null) ? null : t.Agent;

            double pw = L.PanelWidth;
            double ph = L.PanelHeight;
            double py = L.PanelY;
            double memUsed = (sys == null) ? 0 : sys.MemUsed;
            double memTotal = (sys == null) ? 0 : sys.MemTotal;
            double memPct = memTotal > 0 ? memUsed / memTotal * 100 : 0;
            double cpu = (sys == null) ? 0 : sys.Cpu;

            // ---- 第 1 格：CPU ----
            Panel(g, L.PanelX(0), py, pw, ph, Blue, "CPU");
            ArcGauge(g, L.PanelX(0) + pw / 2, py + 150, 70, 13, cpu, Blue);
            KV(g, L.PanelX(0) + 18, py + 268, "核心",
               sys == null ? "--" : ((long)sys.Cores).ToString(), TextW);
            KV(g, L.PanelX(0) + 18, py + 306, "负载",
               sys == null ? "--" : sys.Load1.ToString("0.00"), TextS);
            KV(g, L.PanelX(0) + 18, py + 344, "温度",
               (sys == null || sys.CpuTemp < 0) ? "--" : sys.CpuTemp.ToString("0") + "°C", Orange);

            // ---- 第 2 格：TOKEN（替代 MacTR 的 GPU 格；本机无独显，不编数据）----
            double today = (tk == null) ? 0 : tk.TodayTotal;
            double tpmPct = today > 0 ? Math.Min(100, today / 5000) : 0;   // 5000 tok 视作满格
            Panel(g, L.PanelX(1), py, pw, ph, Magenta, "TOKEN");
            ArcGauge(g, L.PanelX(1) + pw / 2, py + 150, 70, 13, tpmPct, Magenta);
            KV(g, L.PanelX(1) + 18, py + 268, "今日", FmtTokens(today), TextW);
            KV(g, L.PanelX(1) + 18, py + 306, "会话",
               (tk == null || !tk.SessionTotal.HasValue) ? "--" : FmtTokens(tk.SessionTotal.Value), TextS);
            KV(g, L.PanelX(1) + 18, py + 344, "上下文",
               tk == null ? "--" : ((long)tk.ContextUsed).ToString(), TextL);

            // ---- 第 3 格：内存 ----
            Panel(g, L.PanelX(2), py, pw, ph, Green, "内存");
            ArcGauge(g, L.PanelX(2) + pw / 2, py + 150, 70, 13, memPct, PctColor(memPct));
            KV(g, L.PanelX(2) + 18, py + 268, "已用",
               (memUsed / 1024.0).ToString("0.0") + " GB", TextW);
            KV(g, L.PanelX(2) + 18, py + 306, "总量",
               memTotal > 0 ? (memTotal / 1024.0).ToString("0.0") + " GB" : "--", TextS);
            Bar(g, L.PanelX(2) + 18, py + 348, pw - 36, 10, memPct, PctColor(memPct));

            // ---- 第 4 格：磁盘 → 运行时长（本机取不到磁盘读数，不编数值）----
            Panel(g, L.PanelX(3), py, pw, ph, Orange, "UPTIME");
            // 弧表按"当天已过比例"填，是真实值而不是占位
            DateTime now = DateTime.Now;
            double dayPct = (now.Hour * 3600 + now.Minute * 60 + now.Second) / 864.0;
            ArcGauge(g, L.PanelX(3) + pw / 2, py + 150, 70, 13, dayPct, Orange);
            KV(g, L.PanelX(3) + 18, py + 268, "开机",
               sys == null ? "--" : Uptime(sys.UptimeSec), TextW);
            KV(g, L.PanelX(3) + 18, py + 306, "主机",
               (sys == null || sys.Host == null) ? "--" : Fit(g, sys.Host, pw - 36), TextS);
            KV(g, L.PanelX(3) + 18, py + 344, "电量",
               (sys == null || sys.Battery < 0) ? "--" : ((long)sys.Battery).ToString() + "%", TextL);

            // ---- 第 5 格：SYSTEM / DSH 会话 ----
            string state = (ag == null || ag.State == null) ? "unknown" : ag.State;
            Panel(g, L.PanelX(4), py, pw, ph, Cyan, "SYSTEM");
            KV(g, L.PanelX(4) + 18, py + 110, "状态", StateText(state), Cyan);
            KV(g, L.PanelX(4) + 18, py + 158, "项目",
               (ag == null || ag.Project == null) ? "--" : Fit(g, ag.Project, pw - 36), TextW);
            KV(g, L.PanelX(4) + 18, py + 206, "活动",
               (ag == null || ag.Activity == null) ? "--" : Fit(g, ag.Activity, pw - 36), TextS);
            KV(g, L.PanelX(4) + 18, py + 254, "模型",
               (ag == null || ag.Model == null) ? "--" : Fit(g, ag.Model, pw - 36), TextL);
            KV(g, L.PanelX(4) + 18, py + 302, "桥龄",
               FrameStats.BridgeAgeSec < 0 ? "无数据"
               : FrameStats.BridgeAgeSec.ToString("0") + "s 前",
               FrameStats.BridgeAgeSec >= 0 ? Green : Orange);
        }

        private static void Background(Graphics g)
        {
            using (System.Drawing.Drawing2D.LinearGradientBrush bg =
                   new System.Drawing.Drawing2D.LinearGradientBrush(
                       new Rectangle(0, 0, (int)L.Width, (int)L.Height), BgTop, BgBot,
                       System.Drawing.Drawing2D.LinearGradientMode.Vertical))
            {
                g.FillRectangle(bg, 0, 0, (int)L.Width, (int)L.Height);
            }
        }

        /// <summary>
        /// 面板：圆角 16 + 描边 + **强调色顶条** + 顶条下方**6 行 1px 渐隐光晕** + 左上角标题。
        /// （这是 MacTR 的视觉语言，与主题 0 的"胶囊居中标题"刻意不同。）
        /// </summary>
        public static void Panel(Graphics g, double x, double y, double w, double h,
                                 Color accent, string title)
        {
            Draw.FillRound(g, x, y, w, h, 16, PanelC);
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 16, BorderC, 1);

            // 强调顶条（x+2, y, w−4, 3px, 圆角 2）
            Draw.FillRound(g, x + 2, y, w - 4, 3, 2, accent);
            // 顶条下方 6 行 1px 渐隐光晕（alpha = 0.12 × (1 − i/6)）
            for (int i = 0; i < 6; i++)
            {
                Draw.FillRect(g, x + 2, y + 3 + i, w - 4, 1,
                              Color.FromArgb((int)(0.12 * (1 - i / 6.0) * 255), accent));
            }

            Font tf = F.SansFont(26, true);
            Draw.Text(g, title, x + 16, y + 38, tf, accent, Draw.TextAlign.Left);
        }

        /// <summary>
        /// 弧表：270° 扫角（135°→405°，从左上沿顺时针到底部）、圆头端点、
        /// 末端一个 thickness/2 的圆点；中央大字数值 + 小号 %。
        /// </summary>
        public static void ArcGauge(Graphics g, double cx, double cy, double r,
                                    double thick, double pct, Color accent)
        {
            const double a0 = 135;
            const double sweep = 270;
            // 轨道
            using (Pen p = new Pen(BarBg, (float)thick))
            {
                p.StartCap = LineCap.Round;
                p.EndCap = LineCap.Round;
                g.DrawArc(p, (float)(cx - r), (float)(cy - r), (float)(r * 2), (float)(r * 2),
                          (float)a0, (float)sweep);
            }
            double pv = Math.Max(0, Math.Min(100, pct));
            double a1 = a0 + sweep * pv / 100;
            if (pv > 0)
            {
                using (Pen p = new Pen(accent, (float)thick))
                {
                    p.StartCap = LineCap.Round;
                    p.EndCap = LineCap.Round;
                    g.DrawArc(p, (float)(cx - r), (float)(cy - r), (float)(r * 2), (float)(r * 2),
                              (float)a0, (float)(sweep * pv / 100));
                }
                // 末端圆点（DrawingPrimitives.swift:72-111）
                double rad = a1 * Math.PI / 180.0;
                Draw.FillCircle(g, cx + r * Math.Cos(rad), cy + r * Math.Sin(rad), thick / 2, accent);
            }

            // 中央数值
            Font big = F.MonoFont(52, true);
            Draw.Text(g, ((long)Math.Round(pv)).ToString(), cx - 8, cy, big, TextW, Draw.TextAlign.Center);
            Font sf = F.MonoFont(24, true);
            Draw.Text(g, "%", cx + 34, cy + 8, sf, TextS, Draw.TextAlign.Center);
        }

        /// <summary>一行"标签 + 值"（左标签、右值，都在面板内）</summary>
        public static void KV(Graphics g, double x, double y, string label, string val, Color col)
        {
            Font lf = F.SansFont(15, false);
            Font vf = F.MonoFont(20, true);
            Draw.Text(g, label, x, y, lf, TextL, Draw.TextAlign.Left);
            Draw.Text(g, Draw.Fit(g, val, vf, L.PanelWidth - 120), x + L.PanelWidth - 36, y, vf,
                      col, Draw.TextAlign.Right);

        }

        /// <summary>进度条（圆角 = h/2，轨道 #1E2230）</summary>
        public static void Bar(Graphics g, double x, double y, double w, double h,
                               double pct, Color accent)
        {
            Draw.FillRound(g, x, y, w, h, h / 2, BarBg);
            double p = Math.Max(0, Math.Min(100, pct));
            if (p > 0)
            {
                Draw.FillRound(g, x, y, Math.Max(h, w * p / 100), h, h / 2, accent);
            }
        }

        private static string StateText(string state)
        {
            if (state == "busy") return "工作中";
            if (state == "waiting") return "等待输入";
            if (state == "idle") return "空闲";
            return "未知";
        }

        private static string Uptime(double sec)
        {
            double d = Math.Floor(sec / 86400);
            double hh = Math.Floor((sec % 86400) / 3600);
            double mm = Math.Floor((sec % 3600) / 60);
            if (d > 0) return string.Format("{0}d{1}h", (long)d, (long)hh);
            return string.Format("{0}h{1:00}m", (long)hh, (long)mm);
        }

        private static string FmtTokens(double n)
        {
            if (n >= 100000000) return (n / 100000000).ToString("0.00") + "亿";
            if (n >= 10000) return (n / 10000).ToString("0.0") + "万";
            return ((long)Math.Round(n)).ToString();
        }

        private static string Fit(Graphics g, string s, double maxW)
        {
            Font f = F.MonoFont(20, true);
            string r = Draw.Fit(g, s, f, maxW);
            return r;
        }
    }
}
