/**
 * ThemeWall.cs — 主题 2「监控墙」（C# 5 移植版）
 *
 * 逐值移植自 `entry/src/main/ets/render/ThemeWall.ets`（395 行）。
 *
 * ## 三个主题的分工
 *   主题 0 仪表盘   —— 一眼扫全局（环/条/大字）
 *   主题 1 诊断终端 —— 证据流（等宽日志）
 *   主题 2 监控墙   —— **趋势**：曲线 + 还能用多久 + 健康灯
 *
 * ## 版面
 *   顶部：标题 + 一句话摘要（按测量宽度截断，给右上健康灯留 ≈580px）+ 右上 4 个健康灯
 *   中部：4 张等宽卡（CPU 曲线 / 内存曲线 / TOKEN 速率曲线 / 打印机）
 *   底部：余额卡（占两卡宽，含余额曲线）+ 状态卡
 *
 * ## C# 侧的两处数据差异（都已如实处理，不编数据）
 *   · **没有 focus 段**（专注计时/番茄）→ 状态卡改显示"帧统计 + 桥龄"
 *   · **没有 tokensPerMin** → TOKEN 速率卡显示"今日累计"（曲线记断点，即不画假曲线）
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Drawing;

namespace DshLcd
{
    public static class ThemeWall
    {
        private const double W = 1920;
        private const double H = 462;
        private const double M = 14;

        public static void Render(Graphics g, State st, History hist)
        {
            Telemetry t = (st == null) ? null : st.Data;
            Background(g);

            // ---------- 顶部：标题 + 摘要 + 健康灯 ----------
            Font tf = F.SansFont(19, true);
            Draw.Text(g, "监控墙", M + 4, M + 26, tf, C.TextW, Draw.TextAlign.Left);

            string sm = SummaryText(st);
            Font sf = F.SansFont(14, false);
            // ★ 桥端摘要长度没有上限：过长会与右上健康灯压印/冲出画布。
            //   按实际测量宽度截断 —— 健康灯从右边排，左侧给它留出约 580px。
            double room = W - (M + 180) - 580;
            if (room > 40) sm = Draw.Fit(g, sm, sf, room);
            Draw.Text(g, sm, M + 180, M + 26, sf,
                      (sm != null && sm.Length > 0) ? C.Cyan : C.TextD, Draw.TextAlign.Left);

            // 健康灯（右上）：USB / 桥 / VM / 打印机
            double bAge = FrameStats.BridgeAgeSec;
            bool vmOk = FrameStats.JpegBytes > 0;
            bool prOk = (t != null && t.Printer != null && t.Printer.Connected.HasValue
                         && t.Printer.Connected.Value);
            string[] lights = new string[]
            {
                "USB " + (FrameStats.UsbOpen ? "●" : "○"),
                "桥 " + ((bAge >= 0 && bAge < 5) ? "●" : "○"),
                "VM " + (vmOk ? "●" : "○"),
                "打印 " + (prOk ? "●" : "○"),
            };
            Color[] cols = new Color[]
            {
                FrameStats.UsbOpen ? C.Green : C.Red,
                (bAge >= 0 && bAge < 5) ? C.Green : C.Orange,
                vmOk ? C.Green : C.Orange,
                prOk ? C.Green : C.TextD,
            };
            Font lf = F.SansFont(14, false);
            Font lmf = F.MonoFont(13, false);
            double lx = W - M - 4;
            for (int i = lights.Length - 1; i >= 0; i--)
            {
                Draw.Text(g, lights[i], lx, M + 26, lf, cols[i], Draw.TextAlign.Right);
                lx -= Draw.Measure(g, lights[i], lf) + 26;
            }


            // ---------- 中部：四张卡 ----------
            const double cardY = M + 56;
            const double cardH = 196;
            const double gap = 12;
            double cw = (W - M * 2 - gap * 3) / 4;

            SystemInfo sys = (t == null) ? null : t.System;
            TokenInfo tk = (t == null) ? null : t.Tokens;
            double cpuNow = (sys == null) ? 0 : sys.Cpu;
            double memPct = (sys != null && sys.MemTotal > 0) ? sys.MemUsed / sys.MemTotal * 100 : 0;
            string memTxt = (sys != null && sys.MemTotal > 0)
                ? (sys.MemUsed / 1024.0).ToString("0.0") + " / " + (sys.MemTotal / 1024.0).ToString("0.0") + " GB"
                : "—";
            double today = (tk == null) ? 0 : tk.TodayTotal;

            Series sc = (hist == null) ? new Series(History.CAP, 100) : hist.Cpu;
            Series sm2 = (hist == null) ? new Series(History.CAP, 100) : hist.Mem;
            Series stk = (hist == null) ? new Series(History.CAP) : hist.Tokens;
            Series sbal = (hist == null) ? new Series(History.CAP) : hist.Balance;

            ChartCard(g, M, cardY, cw, cardH, "CPU", cpuNow.ToString("0") + "%",
                      C.Green, sc, SpanText(sc.Length));
            ChartCard(g, M + cw + gap, cardY, cw, cardH, "内存", memPct.ToString("0") + "%",
                      C.Cyan, sm2, memTxt);
            // C# 侧没有 tokensPerMin → 主数值显示今日累计，曲线仍是真实的 tokens 序列
            ChartCard(g, M + (cw + gap) * 2, cardY, cw, cardH, "TOKEN",
                      FmtTokens(today), C.Deepseek, stk, "今日累计");
            PrinterCard(g, M + (cw + gap) * 3, cardY, cw, cardH,
                        (t == null) ? null : t.Printer);

            // ---------- 底部：余额卡（宽） + 状态卡 ----------
            double by = cardY + cardH + gap;
            double bh = H - M - by;
            double bw = cw * 2 + gap;
            BalanceCard(g, M, by, bw, bh, (t == null) ? null : t.Balance, sbal);
            StatusCard(g, M + bw + gap, by, cw, bh, bAge, vmOk);
        }

        private static void Background(Graphics g)
        {
            using (System.Drawing.Drawing2D.LinearGradientBrush bg =
                   new System.Drawing.Drawing2D.LinearGradientBrush(
                       new Rectangle(0, 0, (int)W, (int)H), C.BgTop, C.BgBot,
                       System.Drawing.Drawing2D.LinearGradientMode.Vertical))
            {
                g.FillRectangle(bg, 0, 0, (int)W, (int)H);
            }
        }

        /// <summary>卡底 + 描边 + 顶部一道主题色细高光（比纯描边更有"屏"的感觉）</summary>
        private static void Card(Graphics g, double x, double y, double w, double h)
        {
            Draw.FillRound(g, x, y, w, h, 12, C.Panel);
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 12, C.Border, 1);
        }

        /// <summary>一张曲线卡：标题 + 大数字 + 副标题（右上）+ 曲线 + 两条量程参照线</summary>
        private static void ChartCard(Graphics g, double x, double y, double w, double h,
                                      string title, string value, Color color,
                                      Series s, string sub)
        {
            Card(g, x, y, w, h);
            Draw.FillRound(g, x + 16, y + 1, w - 32, 2, 1,
                           Color.FromArgb((int)(0.75 * 255), color));

            Font lf = F.SansFont(14, false);
            Font vf = F.MonoFont(26, true);
            Font sf = F.SansFont(12, false);
            Draw.Text(g, title, x + 18, y + 28, lf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, value, x + 18, y + 72, vf, color, Draw.TextAlign.Left);
            if (sub != null) Draw.Text(g, sub, x + w - 18, y + 28, sf, C.TextD, Draw.TextAlign.Right);

            // 曲线（留出上下空隙，避免贴边）
            double gx = x + 18, gy = y + 104, gw = w - 36, gh = h - 104 - 20;
            // 两条横线，让曲线有"量程"参照
            using (Pen p = new Pen(Color.FromArgb((int)(0.9 * 255), C.Border), 1))
            {
                for (int i = 1; i <= 2; i++)
                {
                    double ly = gy + gh * i / 3.0;
                    g.DrawLine(p, (float)gx, (float)ly, (float)(gx + gw), (float)ly);
                }
            }
            Draw.Sparkline(g, s, History.CAP, gx, gy, gw, gh, color, true, true);

        }

        /// <summary>打印机卡：状态 + 进度 + 温度 + 层数（没接打印机时显示"未连接"，不留空洞）</summary>
        private static void PrinterCard(Graphics g, double x, double y, double w, double h,
                                        PrinterInfo p)
        {
            Card(g, x, y, w, h);
            Color accent = (p == null) ? C.TextD : C.Purple;
            Draw.FillRound(g, x + 16, y + 1, w - 32, 2, 1,
                           Color.FromArgb((int)(0.75 * 255), accent));

            Font lf = F.SansFont(14, false);
            Font vf = F.MonoFont(26, true);
            Font sf = F.SansFont(13, false);

            if (p == null)
            {
                Draw.Text(g, "打印机", x + 18, y + 28, lf, C.TextS, Draw.TextAlign.Left);
                Draw.Text(g, "未连接", x + 18, y + 72, vf, C.TextD, Draw.TextAlign.Left);
                Draw.Text(g, "桥端开启拓竹监控后显示", x + 18, y + 110, sf, C.TextD, Draw.TextAlign.Left);

                return;
            }

            string stLabel = (p.StateLabel != null && p.StateLabel.Length > 0) ? p.StateLabel
                           : (p.State != null && p.State.Length > 0 ? p.State : "未知");
            Draw.Text(g, "打印机", x + 18, y + 28, lf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, p.Percent >= 0 ? p.Percent.ToString() + "%" : "--",
                      x + 18, y + 72, vf, accent, Draw.TextAlign.Left);
            Draw.Text(g, Draw.Fit(g, stLabel, sf, w - 36), x + w - 18, y + 28, sf,
                      C.TextS, Draw.TextAlign.Right);

            // 进度条
            double barW = w - 36;
            Draw.FillRound(g, x + 18, y + 104, barW, 12, 6, C.BarBg);
            if (p.Percent > 0)
            {
                Draw.FillRound(g, x + 18, y + 104,
                               Math.Max(12, barW * Math.Min(100, p.Percent) / 100.0), 12, 6, accent);
            }

            // 温度 / 层数（拿不到就 "--"）
            string nozzle = p.NozzleTemp >= 0 ? p.NozzleTemp.ToString() + "°C" : "--";
            string bed = p.BedTemp >= 0 ? p.BedTemp.ToString() + "°C" : "--";
            string layer = p.Layer >= 0
                ? p.Layer.ToString() + (p.TotalLayer > 0 ? "/" + p.TotalLayer.ToString() : "")
                : "--";
            Draw.Text(g, "喷嘴 " + nozzle, x + 18, y + 146, sf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, "热床 " + bed, x + 18 + barW / 2, y + 146, sf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, "层 " + layer, x + 18, y + 172, sf, C.TextD, Draw.TextAlign.Left);
            if (p.RemainingSec > 0)
            {
                string remain = string.Format("{0}h{1:00}m", p.RemainingSec / 3600,
                                              (p.RemainingSec % 3600) / 60);
                Draw.Text(g, "剩余 " + remain, x + w - 18, y + 172, sf, C.TextS, Draw.TextAlign.Right);
            }

        }

        /// <summary>余额卡：大金额（按额度变色）+ 燃烧速率 + 还能用 + 余额曲线（占右半张卡）</summary>
        private static void BalanceCard(Graphics g, double x, double y, double w, double h,
                                        BalanceInfo bal, Series s)
        {
            Card(g, x, y, w, h);
            double total = (bal == null) ? -1 : bal.Total;
            string cur = (bal != null && bal.Currency == "USD") ? "$" : "¥";
            Color col = total < 0 ? C.TextD
                      : (total < 5 ? C.Red : (total < 20 ? C.Orange : C.Green));

            Font lf = F.SansFont(14, false);
            Font vf = F.MonoFont(28, true);
            Font sf = F.SansFont(13, false);
            Font svf = F.MonoFont(15, true);

            Draw.Text(g, "DeepSeek 余额", x + 18, y + 26, lf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, total < 0 ? "—" : cur + total.ToString("0.00"),
                      x + 18, y + 86, vf, col, Draw.TextAlign.Left);

            double perH = (bal == null) ? -1 : bal.PerHour;
            double eta = (bal == null) ? -1 : bal.EtaHours;
            Draw.Text(g, "燃烧速率", x + 300, y + 34, sf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, perH > 0 ? perH.ToString("0.00") + "/时" : "攒采样中",
                      x + 300, y + 74, svf, perH > 0 ? C.Orange : C.TextD, Draw.TextAlign.Left);
            Draw.Text(g, "还能用", x + 470, y + 34, sf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, eta > 0 ? FmtEta(eta) : "—", x + 470, y + 74, svf,
                      eta > 0 ? (eta > 24 ? C.Green : C.Orange) : C.TextD, Draw.TextAlign.Left);

            // 余额曲线（占右半张卡）
            double gx = x + w * 0.52, gw = w * 0.44, gy = y + 22, gh = h - 44;
            using (Pen p = new Pen(Color.FromArgb((int)(0.9 * 255), C.Border), 1))
            {
                for (int i = 1; i <= 2; i++)
                {
                    double ly = gy + gh * i / 3.0;
                    g.DrawLine(p, (float)gx, (float)ly, (float)(gx + gw), (float)ly);
                }
            }
            Draw.Sparkline(g, s, History.CAP, gx, gy, gw, gh, col, true, true);

        }

        /// <summary>
        /// 状态卡。ArkTS 版这里显示**专注计时 + 番茄**，但 C# 侧**没有 focus 段**
        /// → 改为显示帧统计与桥龄（真实数据，不编造专注状态）。
        /// </summary>
        private static void StatusCard(Graphics g, double x, double y, double w, double h,
                                       double bAge, bool vmOk)
        {
            Card(g, x, y, w, h);
            Font lf = F.SansFont(14, false);
            Font vf = F.MonoFont(28, true);
            Font sf = F.SansFont(13, false);
            Font svf = F.MonoFont(15, true);

            Draw.Text(g, "运行状态", x + 18, y + 26, lf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, FrameStats.Sent.ToString(), x + 18, y + 86, vf,
                      FrameStats.UsbOpen ? C.Green : C.TextD, Draw.TextAlign.Left);

            Draw.Text(g, "已推帧", x + 240, y + 34, sf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, "错误 " + FrameStats.Errors.ToString(), x + 240, y + 74, svf,
                      FrameStats.Errors == 0 ? C.Green : C.Red, Draw.TextAlign.Left);

            string vmTxt = vmOk ? "VM 有画面" : "VM 无画面";
            string brTxt = bAge < 0 ? "桥 无数据" : bAge.ToString("0") + "s 前";
            Draw.Text(g, vmTxt + " · " + brTxt + " · 帧 " + (FrameStats.JpegBytes / 1024) + "KB",
                      x + 18, y + h - 22, sf, C.TextD, Draw.TextAlign.Left);

        }

        // ---------- 小工具 ----------

        private static string SummaryText(State st)
        {
            // C# 侧没有 summary 段 → 用 agent 的最后一句兜底（仍是真实数据）
            if (st == null || st.Data == null || st.Data.Agent == null) return "";
            string s = st.Data.Agent.LastText;
            if (s == null) return "";
            return s.Replace("\n", " ");
        }

        private static string FmtTokens(double n)
        {
            if (n >= 100000000) return (n / 100000000).ToString("0.00") + "亿";
            if (n >= 10000) return (n / 10000).ToString("0.0") + "万";
            return ((long)Math.Round(n)).ToString();
        }

        private static string FmtEta(double hours)
        {
            if (hours >= 24) return (hours / 24).ToString("0.0") + " 天";
            return hours.ToString("0.0") + " 时";
        }

        /// <summary>曲线覆盖的时间跨度（采样间隔 2 秒）</summary>
        private static string SpanText(int samples)
        {
            int sec = samples * 2;
            if (sec >= 60) return "跨度 " + (int)Math.Round(sec / 60.0) + " 分钟";
            return "跨度 " + sec + " 秒";
        }
    }
}
