/**
 * ThemeDiag.cs — 主题 1「诊断终端」（C# 5 移植版）
 *
 * 逐值移植自 `entry/src/main/ets/render/ThemeDiag.ets`（323 行）。
 * 风格参考隔壁 DiPlay / CarPlay 诊断仪：不是"一眼扫全局"，而是**证据流**——
 * 顶部状态药丸 + 大段等宽日志流（按类型着色）+ 右侧紧凑指标 + 底部染色体检条。
 *
 * 版面（1920×462，横装）：
 *   ┌ 标题行：DSH 诊断终端 │ 状态药丸 │ 项目 · 模型 ──────────────┐
 *   │ 事件流（左侧，等宽，按类型着色，从底部往上排）        │ 指标栏 │
 *   └ 底部染色条：数据桥 / USB / VM 的体检 ────────────────┘
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 * ⚠️ `events` 数据在 C# 侧**原先完全没解析**（桥一直在发），本次移植时一并补齐
 *    （见 State.cs 的 BridgeEvent / NormalizeEvents）。
 */
using System;
using System.Collections.Generic;
using System.Drawing;

namespace DshLcd
{
    public static class ThemeDiag
    {
        private const double M = 14;          // 外边距
        private const double W = L.Width;
        private const double H = L.Height;
        private const double MetaH = 54;      // 顶部标题行
        private const double FootH = 40;      // 底部体检条
        private const double RightW = 520;    // 右侧指标栏

        public static void Render(Graphics g, State st)
        {
            // 底色（ArkTS 有 ex.bg 可作背景图，C# 侧主题 1 用纯渐变底）
            Background(g);

            Telemetry t = (st == null) ? null : st.Data;
            AgentInfo ag = (t == null) ? null : t.Agent;

            // ---------- 顶部标题行 ----------
            Font tf = F.SansFont(22, true);
            Draw.Text(g, "DSH 诊断终端", M, M + MetaH / 2, tf, C.TextW, Draw.TextAlign.Left);

            // 状态药丸（DiPlay 的 RUNNING 药丸同款：小字 + 底色）
            string state = (ag == null || ag.State == null) ? "unknown" : ag.State;
            string label = StateText(state);
            Font pf = F.MonoFont(16, false);
            double pw = Draw.Measure(g, label, pf) + 26;
            double px0 = M + 360;      // 标题 2.0× 后有 313px 宽，药丸往右让
            Color pillBg = state == "busy" ? C.Deepseek
                         : (state == "idle" ? Color.FromArgb(0x12, 0x30, 0x1C) : Color.FromArgb(0x2A, 0x2A, 0x33));
            Draw.FillRound(g, px0, M + MetaH / 2 - 13, pw, 26, 13, pillBg);
            Color pillFg = state == "busy" ? Color.White
                         : (state == "idle" ? C.Green : C.TextS);
            Draw.Text(g, label, px0 + pw / 2, M + MetaH / 2, pf, pillFg, Draw.TextAlign.Center);

            // 项目 · 模型（右侧等宽小字）
            string proj = (ag == null || ag.Project == null) ? "（未连接数据桥）" : ag.Project;
            string mdl = (ag == null || ag.Model == null) ? "" : " · " + ag.Model;
            Font mf = F.MonoFont(16, false);
            Draw.Text(g, proj + mdl, W - M, M + MetaH / 2, mf, C.TextS, Draw.TextAlign.Right);

            HLine(g, M, W - M, M + MetaH, C.Border);

            // ---------- 左侧：事件流 ----------
            List<BridgeEvent> events = (t == null || t.Events == null)
                ? new List<BridgeEvent>() : t.Events;
            const double lineH = 38;    // 用户反馈字太小：字号 13→16 后行距一起放大
            double top = M + MetaH + 56;
            double footTop = H - M - FootH;
            int maxLines = (int)Math.Floor((footTop - top) / lineH);

            if (events.Count == 0)
            {
                Font ef = F.MonoFont(16, false);
                Draw.Text(g, "（还没有事件：桥端会记录状态/工具/待办/打印机的变化）",
                          M, top + 18, ef, C.TextD, Draw.TextAlign.Left);
            }
            int showCount = Math.Min(events.Count, Math.Max(1, maxLines));
            int startIdx = events.Count - showCount;
            // 从底部往上排（终端习惯）：条数少时最新一条贴底，上面留白像"历史"，
            // 而不是"下面空一片"（ArkTS 侧第一版从顶部往下排，只有 4 条时下半屏全空）
            double areaH = footTop - top;
            double baseY = top + areaH - showCount * lineH + 8;
            for (int i = 0; i < showCount; i++)
            {
                BridgeEvent e = events[startIdx + i];
                double y = baseY + i * lineH;
                Font f16 = F.MonoFont(16, false);
                Draw.Text(g, e.T == null ? "" : e.T, M, y, f16, C.TextD, Draw.TextAlign.Left);
                Draw.Text(g, EventTag(e.K), M + 150, y, f16, EventColor(e.K), Draw.TextAlign.Left);
                bool newest = (i == showCount - 1);
                Draw.Text(g, e.S == null ? "" : e.S, M + 268, y, f16,
                          newest ? C.TextW : C.TextS, Draw.TextAlign.Left);
            }

            // ---------- 右侧：指标栏 ----------
            double rx = W - M - RightW;
            double ry = M + MetaH + 6;
            double rh = footTop - ry - 6;
            Draw.FillRound(g, rx, ry, RightW, rh, 10, C.Panel);
            Draw.StrokeRound(g, rx, ry, RightW, rh, 10, C.Border, 1);

            TokenInfo tk = (t == null) ? null : t.Tokens;
            BalanceInfo bal = (t == null) ? null : t.Balance;
            SystemInfo sys = (t == null) ? null : t.System;
            double my = M + MetaH + 32;

            my = Metric(g, rx, my, "CPU",
                string.Format("{0:0}%", sys == null ? 0 : sys.Cpu), C.Green);
            my = Metric(g, rx, my, "内存",
                (sys == null || sys.MemTotal <= 0) ? "—"
                : string.Format("{0:0.0} / {1:0.0} GB", sys.MemUsed / 1024.0, sys.MemTotal / 1024.0),
                C.TextW);
            my = Metric(g, rx, my, "今日 TOKEN",
                Tokens(tk == null ? 0 : tk.TodayTotal), C.TextW);
            double total = (bal == null) ? -1 : bal.Total;
            string cur = (bal != null && bal.Currency == "USD") ? "$" : "¥";
            my = Metric(g, rx, my, "余额",
                (bal == null || total < 0) ? "—" : cur + total.ToString("0.00"),
                total < 0 ? C.TextD : (total < 5 ? C.Red : (total < 20 ? C.Orange : C.Green)));
            double perH = (bal == null) ? -1 : bal.PerHour;
            my = Metric(g, rx, my, "燃烧",
                perH > 0 ? perH.ToString("0.00") + "/时" : "攒采样",
                perH > 0 ? C.Orange : C.TextD);
            double etaH = (bal == null) ? -1 : bal.EtaHours;
            my = Metric(g, rx, my, "还能用",
                etaH > 0 ? (etaH >= 24 ? (etaH / 24).ToString("0.0") + " 天" : etaH.ToString("0.0") + " 时") : "—",
                etaH > 24 ? C.Green : C.Orange);

            // 打印机（有数据才画）
            PrinterInfo pr = (t == null) ? null : t.Printer;
            if (pr != null)
            {
                // 注：ArkTS 的 PrinterInfo 有 monitorMode/monitorError（监控未登录态），
                // C# 侧**没有这两个字段** —— 所以改用现有字段表达同一语义：
                // 状态未知/离线且拿不到百分比，就按"未登录/不可用"处理。
                bool perr = (pr.State == null || pr.State.Length == 0 || pr.State == "UNKNOWN")
                    && pr.Percent < 0 && pr.Connected.HasValue && !pr.Connected.Value;
                string pst = pr.State == null ? "UNKNOWN" : pr.State;
                string pLab = perr ? "未登录"
                    : (pr.StateLabel != null && pr.StateLabel.Length > 0 ? pr.StateLabel : pst);
                string pVal = (!perr && pr.Percent >= 0)
                    ? pLab + " " + pr.Percent.ToString() + "%" : pLab;
                Color pCol = perr ? C.Red
                    : (pst == "RUNNING" ? C.Purple : (pst == "OFFLINE" ? C.Red : C.Green));
                my = Metric(g, rx, my, "打印机", pVal, pCol);
            }

            // 上下文条
            double cu = (tk == null) ? 0 : tk.ContextUsed;
            double cw = (tk == null) ? 0 : tk.ContextWindow;
            double cpct = cw > 0 ? (cu / cw * 100) : 0;
            Font kf = F.SansFont(13, false);
            Font vf = F.MonoFont(18, true);
            Draw.Text(g, "上下文", rx + 18, my, kf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, cw > 0 ? cpct.ToString("0.0") + "%" : "—",
                      rx + RightW - 18, my, vf, C.ByPercent(cpct), Draw.TextAlign.Right);

            Draw.FillRound(g, rx + 18, my + 28, RightW - 36, 10, 5, C.BarBg);
            if (cpct > 0)
            {
                Draw.FillRound(g, rx + 18, my + 28,
                               Math.Max(10, (RightW - 36) * cpct / 100), 10, 5, C.ByPercent(cpct));
            }

            // ---------- 底部：一行体检（染色） ----------
            double fy = H - M - FootH;
            bool usbOk = FrameStats.UsbOpen;
            double bAge = FrameStats.BridgeAgeSec;
            bool allOk = usbOk && bAge >= 0 && FrameStats.Errors == 0;
            Draw.FillRound(g, M, fy + 4, W - M * 2, FootH - 8, 8,
                allOk ? Color.FromArgb(0x0D, 0x28, 0x18) : Color.FromArgb(0x2A, 0x1F, 0x10));

            Font ff = F.MonoFont(16, false);
            string brTxt = bAge < 0 ? "数据桥 无数据"
                          : string.Format("数据桥 {0:0}s 前", bAge);
            double cy = fy + FootH / 2;
            Draw.Text(g, brTxt, M + 16, cy, ff, bAge >= 0 ? C.Green : C.Orange, Draw.TextAlign.Left);
            double brW = Draw.Measure(g, brTxt, ff);

            string usbTxt = usbOk
                ? string.Format("USB 已连接 · 已推 {0} 帧 · 错误 {1}", FrameStats.Sent, FrameStats.Errors)
                : "USB 未连接";
            // 按"测量宽度"依次排，避免长文本相互压（ArkTS 侧审计抓到过 51% 重叠）
            Draw.Text(g, usbTxt, M + 16 + brW + 40, cy, ff, usbOk ? C.Green : C.Red, Draw.TextAlign.Left);

            string vmTxt = FrameStats.JpegBytes > 0
                ? string.Format("{0:0.0}KB/帧", FrameStats.JpegBytes / 1024.0) : "无画面";
            Draw.Text(g, "帧 " + vmTxt, W - M - 16, cy, ff,
                      FrameStats.JpegBytes > 0 ? C.TextS : C.Orange, Draw.TextAlign.Right);
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

        private static void HLine(Graphics g, double x1, double x2, double y, Color c)
        {
            using (Pen p = new Pen(c, 1))
            {
                g.DrawLine(p, (float)x1, (float)y, (float)x2, (float)y);
            }
        }

        /// <summary>右侧指标的一行：左标签 + 右数值。返回下一行的 y</summary>
        private static double Metric(Graphics g, double rx, double y, string k, string v, Color col)
        {
            Font kf = F.SansFont(13, false);
            Font vf = F.MonoFont(18, true);
            Draw.Text(g, k, rx + 18, y, kf, C.TextS, Draw.TextAlign.Left);
            Draw.Text(g, v, rx + RightW - 18, y, vf, col, Draw.TextAlign.Right);

            return y + 34;
        }

        private static string StateText(string state)
        {
            if (state == "busy") return "● 工作中";
            if (state == "waiting") return "● 等待输入";
            if (state == "idle") return "○ 空闲";
            return "○ 未知";
        }

        private static Color EventColor(string k)
        {
            if (k == "err") return C.Red;
            if (k == "busy") return C.Deepseek;
            if (k == "idle") return C.Green;
            if (k == "tool") return C.Cyan;
            if (k == "todo") return C.Orange;
            if (k == "print") return C.Purple;
            return C.TextL;
        }

        private static string EventTag(string k)
        {
            if (k == "err") return "[错误]";
            if (k == "busy") return "[工作]";
            if (k == "idle") return "[空闲]";
            if (k == "tool") return "[工具]";
            if (k == "todo") return "[待办]";
            if (k == "print") return "[打印]";
            return "[信息]";
        }

        private static string Tokens(double n)
        {
            if (n >= 100000000) return (n / 100000000).ToString("0.00") + "亿";
            if (n >= 10000) return (n / 10000).ToString("0.0") + "万";
            return ((long)Math.Round(n)).ToString();
        }
    }
}
