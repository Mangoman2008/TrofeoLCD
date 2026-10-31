/**
 * ThemePages.cs — 主题 3「分页屏」（C# 5 移植版）
 *
 * 逐值移植自 `entry/src/main/ets/render/ThemePages.ets`（522 行）。
 *
 * ## 版面
 *   顶部状态栏（时钟 / 日期 / 当前页名 / 摘要 / 右侧 USB·桥·VM·电量状态点）
 *   内容区（整页切换）：
 *     页 0 拓竹打印机 —— 三栏：状态+大百分比+进度条 / 当前作业+温度 / AMS 耗材托盘
 *     页 1 DeepSeek 余额 —— 左：余额+燃烧+还能用+余额曲线；右：今日 TOKEN+速率曲线
 *     页 2 DSH 会话 —— 左：项目/模型/状态/工具/最后一句；右：待办
 *     页 3 系统状态 —— 三栏：CPU 曲线 / 内存曲线 / **本屏自身**（推帧·错误·耗时）
 *   底部：4 个页面指示点 + `N/4 · 每 10 秒自动翻页`
 *
 * ## 三处 C# 数据差异（都如实处理，不编数据）
 *   · 没有 `monitorMode`/`monitorError`（监控未登录态）→ 用 `State`+`Connected` 表达
 *   · 没有 `focus` 段（专注计时）→ 不画那一行
 *   · 没有 `skippedFrames`（C# 帧循环是同步的，没有背压跳帧）→ 显示 0 并在注释里说明
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Collections.Generic;
using System.Drawing;

namespace DshLcd
{
    public static class ThemePages
    {
        public const int PageCount = 4;

        private const double W = 1920;
        private const double H = 462;
        private const double M = 14;
        private const double BarH = 46;
        private const double FootH = 34;

        public static string PageName(int p)
        {
            if (p == 0) return "拓竹打印机";
            if (p == 1) return "DeepSeek 余额";
            if (p == 2) return "DSH 会话";
            return "系统状态";
        }

        public static void Render(Graphics g, State st, History hist, int page)
        {
            Telemetry t = (st == null) ? null : st.Data;
            Background(g);

            double contentY = M + BarH + 8;
            double contentH = H - contentY - FootH - M;

            StatusBar(g, t, page);

            // ---------- 内容区：一页一页 ----------
            int pg = ((page % PageCount) + PageCount) % PageCount;
            if (pg == 0)
            {
                BambuPage(g, M, contentY, W - M * 2, contentH, (t == null) ? null : t.Printer);
            }
            else if (pg == 1)
            {
                BalancePage(g, M, contentY, W - M * 2, contentH, t, hist);
            }
            else if (pg == 2)
            {
                DshPage(g, M, contentY, W - M * 2, contentH, t);
            }
            else
            {
                SystemPage(g, M, contentY, W - M * 2, contentH, t, hist);
            }

            // ---------- 底部：页面指示点 ----------
            double dotY = H - M - FootH / 2;
            const double gap = 16;
            double totalW = PageCount * gap * 2;
            double dx = (W - totalW) / 2;
            for (int i = 0; i < PageCount; i++)
            {
                bool on = (i == pg);
                Draw.FillCircle(g, dx + gap / 2, dotY, on ? 7 : 4.5,
                                on ? C.Cyan : Color.FromArgb((int)(0.8 * 255), C.TextD));
                dx += gap * 2;
            }
            Font nf = F.MonoFont(12, false);
            Draw.Text(g, (pg + 1).ToString() + "/" + PageCount + " · 每 10 秒自动翻页（可在应用里锁定）",
                      W / 2, H - M - 22, nf, C.TextD, Draw.TextAlign.Center);
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

        private static void Card(Graphics g, double x, double y, double w, double h)
        {
            Draw.FillRound(g, x, y, w, h, 12, C.Panel);
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 12, C.Border, 1);
        }

        /// <summary>顶部状态栏：时钟 / 日期 / 页名 / 摘要 / 右侧状态点</summary>
        private static void StatusBar(Graphics g, Telemetry t, int page)
        {
            Draw.FillRound(g, M, M, W - M * 2, BarH, 10, Color.FromArgb((int)(0.92 * 255), C.Panel));
            Draw.StrokeRound(g, M + 0.5, M + 0.5, W - M * 2 - 1, BarH - 1, 10, C.Border, 1);

            DateTime d = DateTime.Now;
            double cy = M + BarH / 2;
            Font cf = F.MonoFont(18, true);
            Draw.Text(g, Pad2(d.Hour) + ":" + Pad2(d.Minute), M + 20, cy, cf, C.TextW, Draw.TextAlign.Left);
            Font df = F.SansFont(14, false);
            string[] wk = new string[] { "日", "一", "二", "三", "四", "五", "六" };
            Draw.Text(g, (d.Month).ToString() + "月" + d.Day.ToString() + "日 周" + wk[(int)d.DayOfWeek],
                      M + 20 + 52, cy, df, C.TextS, Draw.TextAlign.Left);

            // 中间：当前页名 + 摘要
            Font pf = F.SansFont(17, true);
            Draw.Text(g, PageName(page), W / 2 - 120, cy, pf, C.Cyan, Draw.TextAlign.Center);
            string sm = SummaryText(t);
            Font sf = F.SansFont(14, false);
            // 摘要按可用宽度截断：右侧还有状态点，过长会与它们压印
            if (sm.Length > 0) sm = Draw.Fit(g, sm, sf, 640);
            Draw.Text(g, sm.Length > 0 ? sm : "（等一句话摘要）", W / 2 - 10, cy, sf,
                      sm.Length > 0 ? C.TextW : C.TextD, Draw.TextAlign.Left);

            // 右侧：USB / 桥 / VM / 电量
            double bAge = FrameStats.BridgeAgeSec;
            bool usbOk = FrameStats.UsbOpen;
            bool brOk = bAge >= 0 && bAge < 5;
            bool vmOk = FrameStats.JpegBytes > 0;
            SystemInfo sys = (t == null) ? null : t.System;
            List<string> chips = new List<string>();
            List<Color> cols = new List<Color>();
            chips.Add("USB " + (usbOk ? "●" : "○")); cols.Add(usbOk ? C.Green : C.Red);
            chips.Add("桥 " + (brOk ? "●" : "○")); cols.Add(brOk ? C.Green : C.Orange);
            chips.Add("VM " + (vmOk ? "●" : "○")); cols.Add(vmOk ? C.Green : C.Orange);
            if (sys != null && sys.Battery >= 0)
            {
                chips.Add("电 " + sys.Battery.ToString("0") + "%");
                cols.Add(sys.Battery < 20 ? C.Red : C.Green);
            }
            Font chf = F.SansFont(14, false);
            double cx = W - M - 20;
            for (int i = chips.Count - 1; i >= 0; i--)
            {
                Draw.Text(g, chips[i], cx, cy, chf, cols[i], Draw.TextAlign.Right);
                cx -= Draw.Measure(g, chips[i], chf) + 22;
            }
        }

        // ---------------- 页 0：拓竹打印机 ----------------

        private static void BambuPage(Graphics g, double x, double y, double w, double h, PrinterInfo p)
        {
            double cw = (w - 24) / 3;
            if (p == null)
            {
                Card(g, x, y, w, h);
                Font f = F.SansFont(18, false);
                Draw.Text(g, "未接打印机监控（桥端 --printer <url>）", x + w / 2, y + h / 2, f,
                          C.TextD, Draw.TextAlign.Center);
                return;
            }

            // ArkTS 用 monitorMode/monitorError 判"监控未登录"；C# 侧没有这两个字段
            // → 用 State + Connected 表达同一语义（未连接且拿不到百分比）
            bool perr = (p.State == null || p.State.Length == 0 || p.State == "UNKNOWN")
                        && p.Percent < 0 && p.Connected.HasValue && !p.Connected.Value;
            if (perr)
            {
                Card(g, x, y, w, h);
                Font ef = F.SansFont(20, true);
                Draw.Text(g, "打印机监控未登录", x + 28, y + 52, ef, C.Red, Draw.TextAlign.Left);
                Font nf = F.SansFont(14, false);
                Draw.Text(g, "桥端未提供有效的打印机状态", x + 28, y + 104, nf, C.TextS, Draw.TextAlign.Left);
                return;
            }

            bool running = p.State == "RUNNING";
            Color accent = running ? C.Purple : (p.State == "OFFLINE" ? C.Red : C.Green);

            // ---- 左栏：状态 + 大百分比 + 进度条 ----
            Card(g, x, y, cw, h);
            Draw.FillRound(g, x + 16, y + 1, cw - 32, 3, 1.5,
                           Color.FromArgb((int)(0.8 * 255), accent));
            Font lf = F.SansFont(14, false);
            Font sf = F.SansFont(16, true);
            Font vf = F.MonoFont(34, true);
            Draw.Text(g, "拓竹 P2S", x + 20, y + 30, lf, C.TextS, Draw.TextAlign.Left);
            string lab = (p.StateLabel != null && p.StateLabel.Length > 0) ? p.StateLabel
                       : (p.State == null ? "" : p.State);
            Draw.Text(g, lab, x + 20, y + 66, sf, accent, Draw.TextAlign.Left);
            Draw.Text(g, p.Percent >= 0 ? p.Percent.ToString() + "%" : "—",
                      x + 20, y + 140, vf, C.TextW, Draw.TextAlign.Left);

            Draw.FillRound(g, x + 20, y + 190, cw - 40, 12, 6, C.BarBg);
            if (p.Percent > 0)
            {
                Draw.FillRound(g, x + 20, y + 190,
                               Math.Max(12, (cw - 40) * Math.Min(100, p.Percent) / 100.0), 12, 6, accent);
            }
            Font lf2 = F.MonoFont(14, false);
            string layerTxt = p.Layer >= 0
                ? p.Layer.ToString() + "/" + (p.TotalLayer > 0 ? p.TotalLayer.ToString() : "?") + " 层"
                : "—";
            Draw.Text(g, layerTxt, x + 20, y + 226, lf2, C.TextL, Draw.TextAlign.Left);

            // ---- 中栏：作业 + 温度 ----
            double mx = x + cw + 12;
            Card(g, mx, y, cw, h);
            Draw.Text(g, "当前作业", mx + 20, y + 30, lf, C.TextS, Draw.TextAlign.Left);
            Font jf = F.SansFont(17, true);
            string job = (p.JobName != null && p.JobName.Length > 0) ? p.JobName : "（无作业）";
            Draw.Text(g, Draw.Fit(g, job, jf, cw - 40), mx + 20, y + 74, jf, C.TextW, Draw.TextAlign.Left);
            Font tf = F.MonoFont(16, true);
            Draw.Text(g, "喷 " + (p.NozzleTemp >= 0 ? p.NozzleTemp.ToString() + "°" : "—"),
                      mx + 20, y + 126, tf, C.Orange, Draw.TextAlign.Left);
            Draw.Text(g, "床 " + (p.BedTemp >= 0 ? p.BedTemp.ToString() + "°" : "—"),
                      mx + 20, y + 172, tf, C.Orange, Draw.TextAlign.Left);
            Draw.Text(g, "腔 " + (p.ChamberTemp >= 0 ? p.ChamberTemp.ToString() + "°" : "—"),
                      mx + 20, y + 218, tf, C.TextL, Draw.TextAlign.Left);

            // ---- 右栏：AMS 托盘（色块 + 类型 + 余量）----
            double rx = x + (cw + 12) * 2;
            Card(g, rx, y, cw, h);
            Draw.Text(g, "AMS 耗材", rx + 20, y + 30, lf, C.TextS, Draw.TextAlign.Left);
            List<PrinterTray> trays = p.Trays;
            if (trays == null) trays = new List<PrinterTray>();
            double ty = y + 76;
            int lim = Math.Min(3, trays.Count);
            for (int i = 0; i < lim; i++)
            {
                PrinterTray tr = trays[i];
                bool isNow = (tr.Index == p.TrayNow);
                Color tc = ParseHex(tr.Color, C.BarBg);
                Draw.FillRound(g, rx + 20, ty - 12, 26, 26, 6, tc);
                if (isNow)
                {
                    Draw.StrokeRound(g, rx + 19, ty - 13, 28, 28, 7, C.TextW, 2);
                }
                Font trf = F.SansFont(15, false);
                string remain = tr.Remain >= 0 ? "  " + tr.Remain.ToString() + "%" : "";
                Draw.Text(g, (tr.Type != null && tr.Type.Length > 0 ? tr.Type : "?") + remain,
                          rx + 58, ty, trf, isNow ? C.TextW : C.TextS, Draw.TextAlign.Left);
                ty += 42;
            }
            if (trays.Count == 0)
            {
                Draw.Text(g, "无 AMS 数据", rx + 20, y + 80, lf, C.TextD, Draw.TextAlign.Left);
            }

        }

        // ---------------- 页 1：DeepSeek 余额 ----------------

        private static void BalancePage(Graphics g, double x, double y, double w, double h,
                                        Telemetry t, History hist)
        {
            double cw = (w - 12) / 2;
            BalanceInfo bal = (t == null) ? null : t.Balance;
            TokenInfo tk = (t == null) ? null : t.Tokens;
            double total = (bal == null) ? -1 : bal.Total;
            Color col = total < 0 ? C.TextD
                      : (total < 5 ? C.Red : (total < 20 ? C.Orange : C.Green));

            // ---- 左：余额 + 燃烧 + 还能用 + 曲线 ----
            Card(g, x, y, cw, h);
            Font lf = F.SansFont(15, false);
            Font vf = F.MonoFont(34, true);
            Draw.Text(g, "账户余额（云端实时）", x + 24, y + 34, lf, C.TextS, Draw.TextAlign.Left);
            string cur = (bal != null && bal.Currency == "USD") ? "$" : "¥";
            Draw.Text(g, total < 0 ? "—" : cur + total.ToString("0.00"),
                      x + 24, y + 96, vf, col, Draw.TextAlign.Left);
            double perH = (bal == null) ? -1 : bal.PerHour;
            double eta = (bal == null) ? -1 : bal.EtaHours;
            Draw.Text(g, "燃烧 " + (perH > 0 ? perH.ToString("0.00") + " 元/时" : "攒采样中"),
                      x + 24, y + 156, lf, C.TextL, Draw.TextAlign.Left);
            Draw.Text(g, "还能用 " + (eta > 0
                        ? (eta >= 24 ? (eta / 24).ToString("0.0") + " 天" : eta.ToString("0.0") + " 时")
                        : "—"),
                      x + 320, y + 156, lf, C.TextL, Draw.TextAlign.Left);
            double gh = h - 210;
            if (gh > 20)
            {
                Draw.Sparkline(g, (hist == null) ? null : hist.Balance, History.CAP,
                               x + 24, y + 190, cw - 48, gh, col, true, true);
            }

            // ---- 右：今日 token + token 速率曲线 ----
            double rx = x + cw + 12;
            Card(g, rx, y, cw, h);
            Draw.Text(g, "今日 TOKEN", rx + 24, y + 34, lf, C.TextS, Draw.TextAlign.Left);
            Font bf = F.MonoFont(40, true);
            Draw.Text(g, FmtTokens(tk == null ? 0 : tk.TodayTotal), rx + 24, y + 104, bf,
                      C.TextW, Draw.TextAlign.Left);
            // C# 侧没有 tokensPerMin → 不显示速率行（曲线仍是真实序列）
            Draw.Text(g, "速率（桥端未提供）", rx + 24, y + 176, lf, C.TextD, Draw.TextAlign.Left);
            double gh2 = h - 220;
            if (gh2 > 20)
            {
                using (Pen p = new Pen(Color.FromArgb((int)(0.9 * 255), C.Border), 1))
                {
                    for (int i = 1; i <= 2; i++)
                    {
                        double ly = (y + 200) + gh2 * i / 3.0;
                        g.DrawLine(p, (float)(rx + 24), (float)ly, (float)(rx + cw - 24), (float)ly);
                    }
                }
                Draw.Sparkline(g, (hist == null) ? null : hist.Tokens, History.CAP,
                               rx + 24, y + 200, cw - 48, gh2, C.Cyan, true, true);
            }

        }

        // ---------------- 页 2：DSH 会话 ----------------

        private static void DshPage(Graphics g, double x, double y, double w, double h, Telemetry t)
        {
            AgentInfo ag = (t == null) ? null : t.Agent;
            string state = (ag == null || ag.State == null) ? "unknown" : ag.State;
            Color accent = state == "busy" ? C.Deepseek : (state == "idle" ? C.Green : C.TextS);
            double lw = Math.Floor(w * 0.62);
            double rw = w - lw - 12;

            // ---- 左：项目 / 模型 / 状态 / 工具 / 最后一句 ----
            Card(g, x, y, lw, h);
            Draw.FillRound(g, x + 16, y + 1, lw - 32, 3, 1.5,
                           Color.FromArgb((int)(0.8 * 255), accent));
            Font lf = F.SansFont(14, false);
            Draw.Text(g, "项目", x + 24, y + 32, lf, C.TextS, Draw.TextAlign.Left);
            Font pf = F.SansFont(24, true);
            Draw.Text(g, Draw.Fit(g, (ag == null || ag.Project == null) ? "—" : ag.Project, pf, lw - 60),
                      x + 24, y + 78, pf, C.TextW, Draw.TextAlign.Left);
            Draw.Text(g, "模型 " + ((ag == null || ag.Model == null) ? "—" : ag.Model),
                      x + 24, y + 132, lf, C.TextS, Draw.TextAlign.Left);
            Font stf = F.SansFont(18, true);
            string label = state == "busy" ? "● 工作中"
                         : (state == "idle" ? "○ 空闲" : "○ " + state);
            Draw.Text(g, label, x + 24, y + 186, stf, accent, Draw.TextAlign.Left);
            if (ag != null && ag.Tool != null && ag.Tool.Length > 0)
            {
                Font tlf = F.MonoFont(15, false);
                Draw.Text(g, "工具 " + ag.Tool, x + 300, y + 186, tlf, C.Cyan, Draw.TextAlign.Left);
            }
            // 最后一句（C# 侧没有 summary 段 → 直接用 lastText）
            string txt = (ag == null || ag.LastText == null) ? "" : ag.LastText;
            List<string> lines = Wrap(g, txt, lf, lw - 48, 2);
            double ly = y + 222;
            for (int i = 0; i < lines.Count; i++)
            {
                Draw.Text(g, lines[i], x + 24, ly, lf, C.TextL, Draw.TextAlign.Left);
                ly += 30;
            }
            // C# 侧没有 focus 段 → 不画专注那一行

            // ---- 右：待办 ----
            double rxx = x + lw + 12;
            Card(g, rxx, y, rw, h);
            Draw.Text(g, "待办", rxx + 20, y + 30, lf, C.TextS, Draw.TextAlign.Left);
            List<TodoItem> todos = (t == null || t.Todos == null) ? new List<TodoItem>() : t.Todos;
            double ty = y + 70;
            int lim = Math.Min(4, todos.Count);
            for (int i = 0; i < lim; i++)
            {
                TodoItem td = todos[i];
                bool done = td.Status == "completed";
                Draw.Text(g, done ? "✓" : "○", rxx + 20, ty, lf, done ? C.Green : C.TextL,
                          Draw.TextAlign.Left);
                string itemLabel = (td.Content != null && td.Content.Length > 0) ? td.Content : "—";
                Draw.Text(g, Draw.Fit(g, itemLabel, lf, rw - 80), rxx + 46, ty, lf,
                          done ? C.TextD : C.TextS, Draw.TextAlign.Left);
                ty += 34;
            }
            if (todos.Count == 0)
            {
                Draw.Text(g, "暂无待办", rxx + 20, y + 76, lf, C.TextD, Draw.TextAlign.Left);
            }
        }

        // ---------------- 页 3：系统 ----------------

        private static void SystemPage(Graphics g, double x, double y, double w, double h,
                                       Telemetry t, History hist)
        {
            double cw = (w - 24) / 3;
            SystemInfo sys = (t == null) ? null : t.System;
            double cpu = (sys == null) ? 0 : sys.Cpu;
            double memPct = (sys != null && sys.MemTotal > 0) ? sys.MemUsed / sys.MemTotal * 100 : 0;
            Series sc = (hist == null) ? null : hist.Cpu;
            Series sm = (hist == null) ? null : hist.Mem;

            MetricCard(g, x, y, cw, h, "CPU", cpu.ToString("0") + "%", C.Green, sc, "负载走势");
            MetricCard(g, x + cw + 12, y, cw, h, "内存", memPct.ToString("0") + "%", C.Cyan, sm,
                       (sys != null && sys.MemTotal > 0)
                       ? (sys.MemUsed / 1024.0).ToString("0.0") + " / "
                         + (sys.MemTotal / 1024.0).ToString("0.0") + " GB"
                       : "—");

            // ---- 第三栏：本屏自身（推帧 / 错误 / 耗时）----
            double rx = x + (cw + 12) * 2;
            Card(g, rx, y, cw, h);
            Font lf = F.SansFont(14, false);
            Draw.Text(g, "本屏", rx + 20, y + 30, lf, C.TextS, Draw.TextAlign.Left);
            Font rf = F.MonoFont(15, false);
            string[] rows = new string[]
            {
                "推帧 " + FrameStats.Sent.ToString(),
                "错误 " + FrameStats.Errors.ToString(),
                // C# 帧循环是同步的（无背压跳帧路径）→ 恒为 0，如实显示
                "跳帧 0",
                "渲染 " + FrameStats.RenderMs.ToString("0") + "ms",
                "编码 " + FrameStats.EncodeMs.ToString("0") + "ms",
                "推送 " + FrameStats.PushMs.ToString("0") + "ms",
            };
            double ry = y + 72;
            for (int i = 0; i < rows.Length; i++)
            {
                Draw.Text(g, rows[i], rx + 20, ry, rf, (i % 2 == 0) ? C.TextW : C.TextL,
                          Draw.TextAlign.Left);
                ry += 30;
            }

        }

        private static void MetricCard(Graphics g, double x, double y, double w, double h,
                                       string title, string value, Color color,
                                       Series s, string sub)
        {
            Card(g, x, y, w, h);
            Font lf = F.SansFont(14, false);
            Font vf = F.MonoFont(34, true);
            Font sf = F.SansFont(13, false);
            Draw.Text(g, title, x + 20, y + 32, lf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, value, x + 20, y + 84, vf, color, Draw.TextAlign.Left);
            if (sub != null) Draw.Text(g, sub, x + w - 20, y + 32, sf, C.TextD, Draw.TextAlign.Right);

            double gh = h - 140;
            if (gh > 20)
            {
                using (Pen p = new Pen(Color.FromArgb((int)(0.9 * 255), C.Border), 1))
                {
                    for (int i = 1; i <= 2; i++)
                    {
                        double ly = (y + 120) + gh * i / 3.0;
                        g.DrawLine(p, (float)(x + 20), (float)ly, (float)(x + w - 20), (float)ly);
                    }
                }
                Draw.Sparkline(g, s, History.CAP, x + 20, y + 120, w - 40, gh, color, true, true);
            }

        }

        // ---------------- 小工具 ----------------

        /// <summary>简易折行（按**字符**切，与 ArkTS 的 `ThemePages.wrap` 同做法）</summary>
        private static List<string> Wrap(Graphics g, string text, Font font, double maxW, int maxLines)
        {
            List<string> outList = new List<string>();
            if (text == null) return outList;
            string cur = "";
            for (int i = 0; i < text.Length; i++)
            {
                string next = cur + text[i];
                if (Draw.Measure(g, next, font) > maxW && cur.Length > 0)
                {
                    outList.Add(cur);
                    cur = text[i].ToString();
                    if (outList.Count >= maxLines) return outList;
                }
                else
                {
                    cur = next;
                }
            }
            if (cur.Length > 0 && outList.Count < maxLines) outList.Add(cur);
            return outList;
        }

        /// <summary>`#RRGGBB` → Color；非法时用 fallback</summary>
        private static Color ParseHex(string hex, Color fallback)
        {
            if (hex == null || hex.Length < 6) return fallback;
            try
            {
                string h = hex[0] == '#' ? hex.Substring(1) : hex;
                if (h.Length < 6) return fallback;
                int r = Convert.ToInt32(h.Substring(0, 2), 16);
                int gg = Convert.ToInt32(h.Substring(2, 2), 16);
                int b = Convert.ToInt32(h.Substring(4, 2), 16);
                return Color.FromArgb(r, gg, b);
            }
            catch (Exception) { return fallback; }
        }

        private static string SummaryText(Telemetry t)
        {
            if (t == null || t.Agent == null || t.Agent.LastText == null) return "";
            return t.Agent.LastText.Replace("\n", " ");
        }

        private static string Pad2(int n) { return (n < 10 ? "0" : "") + n.ToString(); }

        private static string FmtTokens(double n)
        {
            if (n >= 100000000) return (n / 100000000).ToString("0.00") + "亿";
            if (n >= 10000) return (n / 10000).ToString("0.0") + "万";
            return ((long)Math.Round(n)).ToString();
        }
    }
}
