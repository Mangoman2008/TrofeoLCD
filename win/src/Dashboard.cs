/**
 * Dashboard.cs — 1920x462 / 462x1920 仪表盘渲染（C# + System.Drawing 移植版）
 *
 * 逐行移植自鸿蒙版 entry/src/main/ets/render/Dashboard.ets（ArkTS 画布版）：
 * 坐标、字号、圆角、间距、文案、颜色全部照抄，只把 CanvasRenderingContext2D
 * 的调用翻成 GDI+（FillPath / DrawString / DrawArc / DrawImage）。
 * 坐标 1:1 就是设备像素（鸿蒙版已做过标定，ArkTS 里的数字直接用）。
 *
 * 布局（5 列网格，列宽 274.4，间距 10，边距 14）：
 *   [0] 系统监控   [1-3] DSH 会话状态（三倍宽主面板）   [4] 用量 + 时钟
 *   右侧 480 宽留给 VM 监视画面
 * 竖装布局：逻辑空间 462×1920（调用方已整体旋转 90°，这里只在逻辑坐标里画）。
 *
 * 与 ArkTS 版唯一的契约差异（本版签名没有 FrameStats）：
 *   ArkTS 的 render()/usagePanel()/usagePanelV() 额外收一个 FrameStats（USB 链路、
 *   JPEG 尺寸、分段耗时）。本版契约是 (g, st, vm, vmAgeMs, vmErr, now)，没有它，
 *   所以面板底部那几行自检文字用 State 能给出的等价信息顶替：
 *     左行「USB ● N帧 …ms」 → 「数据 ● N 包」（Fresh 为绿，否则「数据 ○ 未连接」）
 *     右行「桥 ● Ns / 桥 ○」 → 原样保留，N 取 st.AgeSec()
 *     竖屏 y+318 的「r/e/pms」 → 「N 包」
 *   位置、字号、颜色、排序全部不动，其余每一行都与 ArkTS 一致。
 *
 * 编译约束：.NET Framework 的 csc —— C# 5 语法上限（无字符串插值、无 ?.、无
 * 表达式体成员、无元组、无自动属性初始化器），中文源码存 UTF-8 + /codepage:65001。
 * 资源约定：Font 走 Theme.cs 的静态缓存（不 Dispose）；每帧临时创建的
 * Brush/Pen/GraphicsPath 一律 using 释放，避免句柄泄漏。
 */
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;

namespace DshLcd
{
    public static class Dashboard
    {
        private const double W = L.Width;
        private const double H = L.Height;

        private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        /// <summary>
        /// 滚动留言条（对齐 ArkTS 的 `LcdService.feedLines` / `feedAt`）。
        /// ArkTS 侧由服务维护：摘要/最后一句一变就 push 一条，最多保留 12 条。
        /// C# 侧在这里按内容变化累积（同一份语义，只是存放位置不同）。
        /// </summary>
        private static readonly List<string> FeedLines = new List<string>();
        private static long FeedAtMs;
        private static string FeedLastKey = "";

        /// <summary>留言条里现有的条数（供主题按需读取，最多 12）</summary>
        public static int FeedCount { get { return FeedLines.Count; } }

        /// <summary>
        /// 取留言条里**倒数第 offset 条**（offset=0 是最新的一条）。
        /// 用"倒数"而不是正数下标，是为了让调用方不必知道总条数就能取"最新 N 条"。
        /// </summary>
        public static string FeedLineAt(int offset)
        {
            int idx = FeedLines.Count - 1 - offset;
            if (idx < 0 || idx >= FeedLines.Count) return null;
            return FeedLines[idx];
        }

        /// <summary>把一条内容推进滚动留言条（去重；最多留 12 条）。由帧循环调用</summary>
        public static void PushFeed(string text)
        {
            if (text == null) return;
            string t = text.Trim();
            if (t.Length == 0 || t == FeedLastKey) return;
            FeedLastKey = t;
            FeedLines.Add(t);
            while (FeedLines.Count > 12) FeedLines.RemoveAt(0);
            FeedAtMs = State.NowMs();
        }

        /// <summary>文本水平对齐（对应 canvas 的 textAlign）</summary>
        private enum Align { Left = 0, Center = 1, Right = 2 }

        // ==================================================================
        //  入口
        // ==================================================================

        /// <summary>1920×462 横向布局。调用方可直接拿 1920×462 的 Bitmap 画。</summary>
        /// <param name="printerCell">
        /// 打印机格档位（对齐 ArkTS 的 printerCell）：
        ///   "printer" = 标准（打印机卡在右列 VM 下方，老版式）
        ///   "v6"      = **定稿版面**（用户 2026-10-14 选定）：Dotii 在最右、
        ///               VM 保持原大小贴着 Dotii、USAGE 不变、缺口从 DSH 扣
        ///   "v4"      = USAGE 右移、DSH 吃中间空白、Dotii 在第四格
        ///   "dotii"   = VM 进第四格、Dotii 进第五格
        /// </param>
        public static void RenderHorizontal(Graphics g, State st, Bitmap vm,
                                            double vmAgeMs, string vmErr, DateTime now,
                                            string printerCell)
        {
            if (g == null)
            {
                return;
            }
            Telemetry t = DataOf(st);
            GraphicsState gs = g.Save();
            try
            {
                Setup(g);
                Background(g);                       // 自己画满整帧渐变，不依赖调用方

                double ph = L.PanelHeight;
                double py = L.PanelY;
                string pc = (printerCell == null) ? "printer" : printerCell.ToLowerInvariant();

                if (pc == "v6")
                {
                    // ============ v6 定稿版面（用户选定）============
                    // 逐值对齐 ArkTS ThemeDotiiCell 的 FINAL_* 常量。
                    SystemPanel(g, L.Margin, py, L.PanelWidth, ph, t.System);
                    AgentPanel(g, L.PanelX(1), py, L.FinalDshW, ph, t, st, now);
                    UsagePanel(g, L.FinalUsageX, py, L.FinalUsageW, ph, t, st, now);
                    VmPanel(g, L.FinalVmX, py + 46, L.FinalVmW, ph - 46, vm, vmAgeMs, vmErr);
                    // Dotii 格（最右）：真正的 Dotii 分页屏渲染（对齐 ArkTS ThemeDotiiCell）
                    ThemeDotii.RenderCell(g, DotiiState.FromState(st),
                                          L.FinalDotiiX, py, L.FinalDotiiW, ph, State.NowMs());
                }
                else if (pc == "borrowed")
                {
                    // ============ 借位档（主题 9「打印机位 Dotii」）============
                    // 逐值对齐 ArkTS `ThemeDotiiCell` 的 CELL_X/CELL_W/USAGE_X：
                    //   SYSTEM 14(274.4) │ DSH 余下(427) │ USAGE 721(300) │ Dotii 1031(409)
                    //   + margin 14×2 + gap 10×3 = 1859 ✅
                    // 注意：**原始打印机格只有 274.4 宽，装不下 409 的 Dotii** ——
                    //   所以这一档必须借位（从 DSH 挪宽度），这是 ArkTS 侧确认过的结论。
                    SystemPanel(g, L.Margin, py, L.PanelWidth, ph, t.System);
                    double dshW = L.UsageBorrowX - L.Gap - L.PanelX(1);
                    AgentPanel(g, L.PanelX(1), py, dshW, ph, t, st, now);
                    UsagePanel(g, L.UsageBorrowX, py, L.UsageBorrowW, ph, t, st, now);
                    ThemeDotii.RenderCell(g, DotiiState.FromState(st),
                                          L.CellBorrowX, py, L.CellBorrowW, ph, State.NowMs());
                    // VM 与打印机卡仍在右列（与主题 0 同）
                    if (st.Data.Printer != null)
                    {
                        VmPanel(g, L.VmX, L.VmY, L.VmW, L.VmHSplit, vm, vmAgeMs, vmErr);
                        PrinterPanel(g, L.VmX, L.PrY, L.VmW, L.PrH, st.Data.Printer);
                    }
                    else
                    {
                        VmPanel(g, L.VmX, L.VmY, L.VmW, L.VmH, vm, vmAgeMs, vmErr);
                    }
                }
                else if (pc == "v4")
                {
                    // v4：USAGE 右移到 Dotii 左边，DSH 吃掉中间那段空白
                    SystemPanel(g, L.Margin, py, L.PanelWidth, ph, t.System);
                    AgentPanel(g, L.PanelX(1), py, L.V4DshW, ph, t, st, now);
                    UsagePanel(g, L.V4UsageX, py, L.V4UsageW, ph, t, st, now);
                    ThemeDotii.RenderCell(g, DotiiState.FromState(st),
                                          L.PanelX(4), py, L.PanelWidth, ph, State.NowMs());
                    if (st.Data.Printer != null)
                    {
                        VmPanel(g, L.VmX, L.VmY, L.VmW, L.VmHSplit, vm, vmAgeMs, vmErr);
                        PrinterPanel(g, L.VmX, L.PrY, L.VmW, L.PrH, st.Data.Printer);
                    }
                    else
                    {
                        VmPanel(g, L.VmX, L.VmY, L.VmW, L.VmH, vm, vmAgeMs, vmErr);
                    }
                }
                else
                {
                    // 标准版面（也是 dotii 档的默认；dotii 档的"VM 进第四格"待移植）
                    double pw = L.PanelWidth;
                    SystemPanel(g, L.PanelX(0), py, pw, ph, t.System);
                    double agentX = L.PanelX(1);
                    double agentW = pw * 3 + L.Gap * 2;
                    AgentPanel(g, agentX, py, agentW, ph, t, st, now);
                    UsagePanel(g, L.PanelX(4), py, pw, ph, t, st, now);

                    // 右侧 480×480：VM 监视画面（来自 livepad 的 /vm/frame.jpg）
                    // 有打印机数据时右侧一列拆两块（VM 缩到接近 3:2，下面给拓竹卡片）；
                    // 没有打印机数据就不拆，保持整列 VM —— 与鸿蒙版 Dashboard.ets 同逻辑
                    if (st.Data.Printer != null)
                    {
                        VmPanel(g, L.VmX, L.VmY, L.VmW, L.VmHSplit, vm, vmAgeMs, vmErr);
                        PrinterPanel(g, L.VmX, L.PrY, L.VmW, L.PrH, st.Data.Printer);
                    }
                    else
                    {
                        VmPanel(g, L.VmX, L.VmY, L.VmW, L.VmH, vm, vmAgeMs, vmErr);
                    }
                }
            }
            finally
            {
                g.Restore(gs);
            }
        }

        /// <summary>
        /// 462×1920 竖向布局：逻辑坐标 462 宽 × 1920 高。
        /// 调用方已经把 Graphics 旋转了 90°（只改变换，不改这里的坐标系），
        /// 这里只按 462×1920 的逻辑坐标画。
        /// </summary>
        public static void RenderVertical(Graphics g, State st, Bitmap vm,
                                          double vmAgeMs, string vmErr, DateTime now)
        {
            if (g == null)
            {
                return;
            }
            Telemetry t = DataOf(st);
            GraphicsState gs = g.Save();
            try
            {
                Setup(g);

                // 整帧背景（竖装的渐变方向与横屏一致：逻辑坐标 0 → V.height）
                using (LinearGradientBrush bg = new LinearGradientBrush(
                           new RectangleF(0f, 0f, (float)V.Width, (float)V.Height),
                           C.BgTop, C.BgBot, LinearGradientMode.Vertical))
                using (GraphicsPath p = Rect(0, 0, V.Width, V.Height))
                {
                    g.FillPath(bg, p);
                }

                double x = V.Margin;
                double w = V.InnerW();
                HeaderV(g, x, V.HdrY, w, V.HdrH, t, now);
                if (st.Data.Printer != null)
                {
                    VmPanel(g, x, V.VmY, w, V.VmHSplit, vm, vmAgeMs, vmErr);
                    PrinterPanel(g, x, V.PrY, w, V.PrH, st.Data.Printer);
                }
                else
                {
                    VmPanel(g, x, V.VmY, w, V.VmH, vm, vmAgeMs, vmErr);
                }
                SystemPanel(g, x, V.SysY, w, V.SysH, t.System);
                AgentPanelV(g, x, V.AgY, w, V.AgH, t, st, now);
                UsagePanelV(g, x, V.UsY, w, V.UsH, t, st, now);
            }
            finally
            {
                g.Restore(gs);
            }
        }

        // ==================================================================
        //  竖屏各段
        // ==================================================================

        /// <summary>竖屏顶部：大时钟 + 日期 + 天气/歌词</summary>
        private static void HeaderV(Graphics g, double x, double y, double w, double h,
                                    Telemetry t, DateTime now)
        {
            FillRounded(g, x, y, w, h, 14, C.Panel);
            StrokeRounded(g, x + 0.5, y + 0.5, w - 1, h - 1, 14, C.Border);

            string time = Pad2(now.Hour) + ":" + Pad2(now.Minute) + ":" + Pad2(now.Second);
            // ★ 2026-10-15：补上宽度自适应。ArkTS 这里是 `monoFit(..., w - 30)`
            //   （见 Dashboard.ets:241），而原来我直接 Mono 画 —— 46px 乘 F.Scale 后
            //   可能比顶栏还宽，被后面面板盖住。
            Mono(g, FitText(g, time, F.MonoFont(46, true), w - 30),
                x + w / 2, y + 40, 46, C.TextW, Align.Center, true);

            string[] week = new string[] { "日", "一", "二", "三", "四", "五", "六" };
            string dateStr = now.Year.ToString(Inv) + "-" + Pad2(now.Month) + "-" + Pad2(now.Day)
                + " 周" + week[(int)now.DayOfWeek];
            Label(g, dateStr, x + w / 2, y + 74, 16, C.TextS, Align.Center);

            WeatherInfo wx = t.Weather;
            string bottom = "";
            if (wx != null && wx.Text != null)
            {
                bottom = wx.Text + (wx.TempC.HasValue ? " " + Fixed(wx.TempC.Value, 0) + "°C" : "");
            }
            LyricsInfo lyr = t.Lyrics;
            if (lyr != null && lyr.Line != null && lyr.Line.Length > 0)
            {
                bottom = bottom.Length > 0 ? bottom + " · " + lyr.Line : lyr.Line;
            }
            if (bottom.Length > 0)
            {
                Label(g, FitText(g, bottom, F.SansFont(16, false), w - 44),
                    x + w / 2, y + 98, 16, C.Cyan, Align.Center);
            }
        }

        /// <summary>竖屏 DSH 面板：单列堆叠（项目/状态/活动/最后一句/进度/待办）</summary>
        private static void AgentPanelV(Graphics g, double x, double y, double w, double h,
                                        Telemetry t, State st, DateTime now)
        {
            AgentInfo ag = AgentOf(t);
            string state = ag.State == null ? "unknown" : ag.State;
            Color accent = StateColor(state);
            Panel(g, x, y, w, h, C.Deepseek, "DEEPSEEK HARNESS",
                ag.Model == null ? "" : ag.Model);

            // 状态徽章（忙碌时呼吸）
            double alpha = 1.0;
            if (state == "busy")
            {
                double ph = (Ms(now) % 2400.0) / 2400.0;
                alpha = 0.55 + 0.45 * (0.5 + 0.5 * Math.Sin(ph * Math.PI * 2));
            }
            string badgeText = StateText(state);
            Font badgeFont = F.SansFont(18, true);
            double bw = Measure(g, badgeText, badgeFont) + 40;
            FillRounded(g, x + w - 18 - bw, y + 52, bw, 34, 17, WithAlpha(accent, alpha));
            TextAt(g, badgeText, x + w - 18 - bw / 2, y + 69, badgeFont, C.BadgeText, Align.Center);

            // 项目名：**自动缩字号**（对齐 ArkTS `Dashboard.drawShrink`）
            // ArkTS 侧实测：项目名 `WorkBuddy` 被截成 `WorkB...` 会丢信息，
            // 用户要求"缩小一点或者变两行" → 先缩到放得下，缩到下限仍放不下才截断加省略号。
            string project = ag.Project == null ? "（未连接数据桥）" : ag.Project;
            ShrinkMono(g, project, x + 22, y + 110, w - 44, 26, 15, C.TextW);

            // 活动行 + 工具
            Label(g, FitText(g, ag.Activity == null ? "等待数据…" : ag.Activity,
                    F.SansFont(22, false), w - 44),
                x + 22, y + 150, 22, accent, Align.Left);
            if (ag.Tool != null && ag.Tool.Length > 0)
            {
                string toolText = FitText(g, ag.Tool, F.MonoFont(16, false), w - 80);
                double tw = Measure(g, toolText, F.MonoFont(16, false)) + 24;
                FillRounded(g, x + 22, y + 172, tw, 28, 6, C.PanelHi);
                Mono(g, toolText, x + 34, y + 186, 16, C.Cyan, Align.Left, false);
            }

            // 最后一句（2 行）
            List<string> lines = Wrap(g, ag.LastText == null ? "" : ag.LastText,
                F.SansFont(17, false), w - 44, 2);
            double ly = y + 216;
            for (int i = 0; i < lines.Count; i++)
            {
                Label(g, lines[i], x + 22, ly, 17, C.TextS, Align.Left);
                ly += 24;
            }

            // 任务进度
            List<TodoItem> todos = t.Todos == null ? new List<TodoItem>() : t.Todos;
            int done = 0;
            for (int i = 0; i < todos.Count; i++)
            {
                if (todos[i].Status == "completed")
                {
                    done++;
                }
            }
            Label(g, "任务进度", x + 22, y + 300, 17, C.TextS, Align.Left);
            Mono(g, todos.Count > 0 ? done.ToString(Inv) + "/" + todos.Count.ToString(Inv) : "—",
                x + w - 22, y + 300, 26, C.TextW, Align.Right, true);

            double segY = y + 322;
            double segW = w - 44;
            if (todos.Count > 0)
            {
                double gap = 4;
                double itemW = (segW - gap * (todos.Count - 1)) / todos.Count;
                for (int i = 0; i < todos.Count; i++)
                {
                    double sx = x + 22 + i * (itemW + gap);
                    string stt = todos[i].Status == null ? "pending" : todos[i].Status;
                    Color col = C.BarBg;
                    if (stt == "completed")
                    {
                        col = C.Green;
                    }
                    else if (stt == "in_progress")
                    {
                        col = C.Deepseek;
                    }
                    FillRounded(g, sx, segY, Math.Max(3, itemW), 10, 5, col);
                }
            }
            else
            {
                Bar(g, x + 22, segY, segW, 10, 0, C.BarBg);
            }

            // 待办列表（最多 6 条，避免溢出）
            double ty = y + 356;
            int shown = Math.Min(todos.Count, 6);
            if (todos.Count == 0)
            {
                Label(g, "暂无待办（DSH 写入 todo/write 后显示）", x + 22, ty + 8, 16,
                    C.TextL, Align.Left);
            }
            for (int i = 0; i < shown; i++)
            {
                TodoItem td = todos[i];
                string stt = td.Status == null ? "pending" : td.Status;
                string glyph = "○";
                Color col = C.TextL;
                if (stt == "completed")
                {
                    glyph = "✓";
                    col = C.TextD;
                }
                else if (stt == "in_progress")
                {
                    glyph = "▶";
                    col = C.Cyan;
                }
                Label(g, glyph, x + 22, ty + 9, 17, col, Align.Left);
                List<string> one = Wrap(g, td.Content == null ? "" : td.Content,
                    F.SansFont(16, false), segW - 26, 1);
                Label(g, one.Count > 0 ? one[0] : "", x + 44, ty + 9, 16,
                    stt == "completed" ? C.TextD : C.TextS, Align.Left);
                ty += 30;
            }
        }

        /// <summary>竖屏用量面板（比横屏矮，布局重排）</summary>
        private static void UsagePanelV(Graphics g, double x, double y, double w, double h,
                                        Telemetry t, State st, DateTime now)
        {
            Panel(g, x, y, w, h, C.Cyan, "用量", "");
            TokenInfo tk = t.Tokens == null ? new TokenInfo() : t.Tokens;
            double inTok = tk.TodayInput;
            double outTok = tk.TodayOutput;
            double ctxUsed = tk.ContextUsed;
            double ctxWin = tk.ContextWindow;
            double cost = tk.CostUsd.HasValue ? tk.CostUsd.Value : -1;

            Label(g, "今日 TOKEN", x + 22, y + 68, 16, C.TextS, Align.Left);
            Mono(g, FitText(g, FmtTokens(tk.TodayTotal), F.MonoFont(30, true),
                    ValueMaxW(g, w, "今日 TOKEN", F.SansFont(16, false))),
                x + w - 22, y + 68, 30, C.TextW, Align.Right, true);
            Label(g, "↑ " + FmtTokens(inTok) + "  ↓ " + FmtTokens(outTok),
                x + w - 22, y + 98, 15, C.TextL, Align.Right);

            double cpct = ctxWin > 0 ? (ctxUsed / ctxWin * 100) : 0;
            Label(g, "上下文", x + 22, y + 130, 16, C.TextS, Align.Left);
            Mono(g, ctxWin > 0 ? Fixed(cpct, 1) + "%" : "—", x + w - 22, y + 130, 16,
                C.TextW, Align.Right, false);
            Bar(g, x + 22, y + 146, w - 44, 12, cpct, C.ByPercent(cpct));

            if (cost >= 0)
            {
                Label(g, "预估花费", x + 22, y + 180, 16, C.TextS, Align.Left);
                Mono(g, "$" + Fixed(cost, 3), x + w - 22, y + 180, 16, C.Orange,
                    Align.Right, false);
            }

            HLine(g, x + 22, x + w - 22, y + 204, C.Border);

            string time = Pad2(now.Hour) + ":" + Pad2(now.Minute);
            // ★ 2026-10-15：补宽度自适应（ArkTS 是 `monoFit(..., w - 30)`，见竖屏 usagePanelV），
            //   44px 乘 F.Scale 后可能超出面板宽度而被盖住。
            Mono(g, FitText(g, time, F.MonoFont(44, true), w - 30),
                x + w / 2, y + 244, 44, C.TextW, Align.Center, true);

            // ArkTS 这里画的是 FrameStats 的 USB / 桥 / 分段耗时；本版契约没有 FrameStats，
            // 用 State 的等价信息顶替（位置、字号、颜色、对齐完全一致）。
            Mono(g, LinkText(st), x + 22, y + 296, 13, LinkColor(st), Align.Left, false);
            Mono(g, BridgeText(st), x + w - 22, y + 296, 13, BridgeColor(st), Align.Right, false);
            // ArkTS 竖装这里画的是"渲染/编码/推送 ms"；本版契约没有 FrameStats，用帧数顶替
            // （位置、字号、颜色、对齐完全一致 —— 上一轮我误删了这行，审计立刻报 318 缺失）
            Mono(g, FrameCountText(st), x + w / 2, y + 318, 12, C.TextD, Align.Center, false);
        }

        /// <summary>
        /// VM 画面区域。
        /// VM 帧是 1680×1120（3:2），本区域接近正方形，所以按「等比放入」处理：
        /// 不裁切、不变形，上下自然留黑边。
        /// </summary>
        private static void VmPanel(Graphics g, double x, double y, double w, double h,
                                    Bitmap pm, double ageMs, string vmErr)
        {
            FillRounded(g, x, y, w, h, 14, C.Panel);
            StrokeRounded(g, x + 0.5, y + 0.5, w - 1, h - 1, 14, C.Border);

            Color accent = C.Cyan;
            // 与其它面板一致：胶囊居中标题（VM 面板不走 Panel()，单独画）
            Font vf = F.SansFont(19, true);
            string vTitle = "虚拟机";
            double vtw = g.MeasureString(vTitle, vf, int.MaxValue,
                             StringFormat.GenericTypographic).Width;
            double vPillH = 30;
            double vPillX = x + (w - (vtw + 26)) / 2;
            FillRounded(g, vPillX, y + 16, vtw + 26, vPillH, vPillH / 2, WithAlpha(accent, 0.18));
            StrokeRounded(g, vPillX + 1, y + 17, vtw + 24, vPillH - 2, (vPillH - 2) / 2, accent);
            TextAt(g, vTitle, vPillX + 13, y + 16 + vPillH / 2 + 1, vf, accent, Align.Left);

            string ageTxt = ageMs < 0 ? "无帧" : Fixed(ageMs / 1000.0, 1) + "s";
            Mono(g, ageTxt, x + w - 18, y + 31, 15, C.TextL, Align.Right, false);

            double top = y + 52;
            double innerH = h - 52 - 14;
            double innerW = w - 24;

            if (pm == null)
            {
                string err = vmErr == null ? "" : vmErr;
                Label(g, "等待 VM 画面…", x + w / 2, y + h / 2 - 12, 17, C.TextD, Align.Center);
                Label(g, err.Length > 0 ? err : "livepad 127.0.0.1:8787/vm/frame.jpg",
                    x + w / 2, y + h / 2 + 14, 13, C.TextD, Align.Center);
                return;
            }

            double iw = pm.Width;
            double ih = pm.Height;
            if (iw <= 0 || ih <= 0)
            {
                return;
            }
            double scale = Math.Min(innerW / iw, innerH / ih);
            double dw = iw * scale;
            double dh = ih * scale;
            double dx = x + (w - dw) / 2;
            double dy = top + (innerH - dh) / 2;
            try
            {
                // 插值/像素偏移**不在这里改**：调用方（LcdRunner.Render）已经显式设成
                // Bilinear + PixelOffsetMode.Half，理由写在那边（ARM64 上高质量插值每帧
                // 要 ~100ms，而显示区只有 452×480，肉眼无差别）。渲染器不该覆盖调用方的
                // 采样选择 —— 之前这里强制改成 HighQualityBicubic，把那个优化抵消掉了。
                RectangleF dest = new RectangleF((float)dx, (float)dy, (float)dw, (float)dh);
                g.DrawImage(pm, dest);
            }
            catch (Exception)
            {
                // 画失败不影响其它面板
            }
            // 画面外框，便于看出黑边范围
            using (Pen p = new Pen(C.Border, 1f))
            {
                g.DrawRectangle(p, (float)dx, (float)dy, (float)dw, (float)dh);
            }
        }

        // ==================================================================
        //  基础绘制
        // ==================================================================

        private static void Setup(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        }

        private static void Background(Graphics g)
        {
            using (LinearGradientBrush bg = new LinearGradientBrush(
                       new RectangleF(0f, 0f, (float)W, (float)H),
                       C.BgTop, C.BgBot, LinearGradientMode.Vertical))
            using (GraphicsPath p = Rect(0, 0, W, H))
            {
                g.FillPath(bg, p);
            }
        }

        /// <summary>圆角矩形路径（ArkTS 的 roundRect：四角半径 r，等价于画布上的二次曲线圆角）</summary>
        private static GraphicsPath RoundRect(double x, double y, double w, double h, double r)
        {
            GraphicsPath p = new GraphicsPath();
            if (w <= 0 || h <= 0)
            {
                return p;
            }
            double max = Math.Min(w, h) / 2;
            if (r > max)
            {
                r = max;
            }
            if (r < 0)
            {
                r = 0;
            }
            float d = (float)(r * 2);
            if (d < 0.5f)
            {
                p.AddRectangle(new RectangleF((float)x, (float)y, (float)w, (float)h));
                return p;
            }
            p.AddArc((float)x, (float)y, d, d, 180, 90);
            p.AddArc((float)(x + w - d), (float)y, d, d, 270, 90);
            p.AddArc((float)(x + w - d), (float)(y + h - d), d, d, 0, 90);
            p.AddArc((float)x, (float)(y + h - d), d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        private static GraphicsPath Rect(double x, double y, double w, double h)
        {
            GraphicsPath p = new GraphicsPath();
            p.AddRectangle(new RectangleF((float)x, (float)y, (float)w, (float)h));
            return p;
        }

        private static void FillRounded(Graphics g, double x, double y, double w, double h,
                                        double r, Color c)
        {
            using (GraphicsPath p = RoundRect(x, y, w, h, r))
            using (SolidBrush b = new SolidBrush(c))
            {
                g.FillPath(b, p);
            }
        }

        private static void StrokeRounded(Graphics g, double x, double y, double w, double h,
                                          double r, Color c)
        {
            using (GraphicsPath p = RoundRect(x, y, w, h, r))
            using (Pen pen = new Pen(c, 1f))
            {
                g.DrawPath(pen, p);
            }
        }

        /// <summary>1px 水平分隔线（ArkTS 的 moveTo/lineTo + stroke）</summary>
        private static void HLine(Graphics g, double x1, double x2, double y, Color c)
        {
            using (Pen pen = new Pen(c, 1f))
            {
                g.DrawLine(pen, (float)x1, (float)y, (float)x2, (float)y);
            }
        }

        /// <summary>圆弧描边（ArkTS 的 ctx.arc + stroke）；角度是度，0° 在 3 点方向、顺时针为正</summary>
        private static void Ring(Graphics g, double cx, double cy, double r, double width,
                                 double startDeg, double sweepDeg, Color c)
        {
            if (sweepDeg <= 0)
            {
                return;
            }
            using (Pen pen = new Pen(c, (float)width))
            {
                pen.StartCap = LineCap.Flat;
                pen.EndCap = LineCap.Flat;
                RectangleF rect = new RectangleF((float)(cx - r), (float)(cy - r),
                    (float)(2 * r), (float)(2 * r));
                g.DrawArc(pen, rect, (float)startDeg, (float)sweepDeg);
            }
        }

        /// <summary>
        /// 面板外框（ArkTS 的 panel()）：底色 + 1px 边框 + 左侧强调条 + 标题 + 右侧小字。
        /// right 传 null 表示不画（对应 ArkTS 的 undefined）。
        /// </summary>
        // ---------- 打印机卡片（拓竹）—— 对齐 Dashboard.ets 的 printerPanel ----------

        private static Color PrinterAccent(string state)
        {
            if (state == "RUNNING") return C.Green;
            if (state == "PAUSE") return C.Orange;
            if (state == "PREPARE") return C.Blue;
            if (state == "FINISH") return C.Cyan;
            if (state == "FAILED" || state == "STUCK") return C.Red;
            if (state == "IDLE") return C.TextS;
            return C.TextD;
        }

        /// <summary>剩余时长：1h20m / 35m / 40s</summary>
        private static string FmtDuration(int sec)
        {
            if (sec < 0) return "—";
            int hh = sec / 3600;
            int mm = (sec % 3600) / 60;
            if (hh > 0) return hh.ToString(Inv) + "h" + (mm < 10 ? "0" : "") + mm.ToString(Inv) + "m";
            if (mm > 0) return mm.ToString(Inv) + "m";
            return sec.ToString(Inv) + "s";
        }

        /// <summary>画一个"喷 220→220°"式的温度块，返回下一个块的起始 x</summary>
        private static double PrinterTemp(Graphics g, double x, double y, string tag, int cur, int target)
        {
            string curTxt = cur >= 0 ? Math.Round((double)cur).ToString(Inv) + "°" : "—";
            string txt = (target >= 0 && target != cur)
                ? tag + " " + curTxt + "→" + Math.Round((double)target).ToString(Inv) + "°"
                : tag + " " + curTxt;
            Mono(g, txt, x, y, 13, cur >= 0 ? C.TextS : C.TextD, Align.Left, false);
            Font f = F.MonoFont(13, false);
            SizeF sz = g.MeasureString(txt, f, new PointF(0f, 0f), FmtBox);
            return x + sz.Width + 14;
        }

        /// <summary>右侧 AMS 托盘列：色块 + 材料 + 剩余，当前进料那个用亮边</summary>
        private static void PrinterTrays(Graphics g, double x, double y, double h, PrinterInfo p)
        {
            Label(g, p.Trays.Count > 0 ? "AMS" : "耗材", x, y + h * 0.16, 11, C.TextS, Align.Left);
            double ty = y + h * P.TrayTop;
            int lim = Math.Min(p.Trays.Count, P.TrayMax);
            for (int i = 0; i < lim; i++)
            {
                PrinterTray tr = p.Trays[i];
                bool isNow = p.TrayNow >= 0 && tr.Index == p.TrayNow;
                Color chip = tr.Color != null ? C.Hex(tr.Color) : C.BarBg;
                FillRounded(g, x, ty - 6, 13, 13, 3, chip);
                StrokeRounded(g, x + 0.5, ty - 5.5, 12, 12, 3, isNow ? C.TextW : C.Border);
                string txt = tr.Type + (tr.Remain >= 0 ? " " + tr.Remain.ToString(Inv) + "%" : "");
                Label(g, FitText(g, txt, F.SansFont(13, false), P.TrayColW - 24),
                    x + 20, ty, 13, isNow ? C.TextW : C.TextS, Align.Left);
                ty += h * P.TrayPitch;
            }
            if (p.Trays.Count > P.TrayMax)
            {
                Label(g, "+" + (p.Trays.Count - P.TrayMax).ToString(Inv) + " 盘", x, ty, 12, C.TextL, Align.Left);
            }
        }

        /// <summary>打印机卡片：状态 / 进度 / 温度 / AMS（只在遥测带 printer 段时出现）</summary>
        private static void PrinterPanel(Graphics g, double x, double y, double w, double h, PrinterInfo p)
        {
            string state = p.State != null ? p.State : "UNKNOWN";
            bool offline = state == "OFFLINE" || (p.Online.HasValue && !p.Online.Value);
            Color accent = PrinterAccent(state);
            Panel(g, x, y, w, h, accent, "打印机", "");

            double leftW = w - P.TrayColW - P.Pad * 2 - 12;
            double lx = x + P.Pad;
            double lr = lx + leftW;

            string stateTxt = (p.StateLabel != null && p.StateLabel.Length > 0) ? p.StateLabel : State.PrinterStateLabel(state);
            Label(g, stateTxt, lr, P.Row(y, h, P.RTitle), 17, offline ? C.TextD : accent, Align.Right);

            string pctTxt = p.Percent >= 0 ? p.Percent.ToString(Inv) + "%" : "—";
            double pctY = P.Row(y, h, P.RPct);
            Mono(g, pctTxt, lx, pctY, 30, offline ? C.TextL : C.TextW, Align.Left, true);
            Font big = F.MonoFont(30, true);
            SizeF sz = g.MeasureString(pctTxt, big, new PointF(0f, 0f), FmtBox);
            if (p.Layer >= 0)
            {
                string layerTxt = p.Layer.ToString(Inv) + (p.TotalLayer > 0 ? "/" + p.TotalLayer.ToString(Inv) : "") + " 层";
                Mono(g, layerTxt, lx + sz.Width + 14, pctY, 15, C.TextL, Align.Left, false);
            }
            if (p.RemainingSec >= 0)
            {
                string eta = (p.Eta != null && p.Eta.Length > 0) ? " · " + p.Eta : "";
                Label(g, "剩 " + FmtDuration(p.RemainingSec) + eta, lr, pctY, 15, C.TextS, Align.Right);
            }

            Bar(g, lx, P.Row(y, h, P.RBar) - 6, leftW, 12, p.Percent >= 0 ? p.Percent : 0, accent);

            double jobY = P.Row(y, h, P.RJob);
            if (p.HmsCount > 0)
            {
                string code = (p.HmsCode != null && p.HmsCode.Length > 0) ? " · " + p.HmsCode : "";
                Label(g, FitText(g, "⚠ HMS " + p.HmsCount.ToString(Inv) + " 条" + code, F.SansFont(14, false), leftW),
                    lx, jobY, 14, C.Red, Align.Left);
            }
            else if (p.PrintError > 0)
            {
                Label(g, FitText(g, "⚠ 打印错误码 " + p.PrintError.ToString(Inv), F.SansFont(14, false), leftW),
                    lx, jobY, 14, C.Red, Align.Left);
            }
            else if (p.JobName != null && p.JobName.Length > 0)
            {
                Label(g, FitText(g, p.JobName, F.SansFont(14, false), leftW), lx, jobY, 14, C.TextL, Align.Left);
            }
            else
            {
                Label(g, offline ? "打印机不在线" : "待机中", lx, jobY, 14, C.TextD, Align.Left);
            }

            double ty = P.Row(y, h, P.RTemps);
            double tx = PrinterTemp(g, lx, ty, "喷", p.NozzleTemp, p.NozzleTarget);
            tx = PrinterTemp(g, tx, ty, "床", p.BedTemp, p.BedTarget);
            if (p.ChamberTemp >= 0)
            {
                PrinterTemp(g, tx, ty, "腔", p.ChamberTemp, -1);
            }
            if (p.CoolingFan >= 0 || p.SpeedLevel >= 0)
            {
                string parts = "";
                if (p.CoolingFan >= 0) parts += "风" + p.CoolingFan.ToString(Inv) + "%";
                if (p.SpeedLevel >= 0) parts += (parts.Length > 0 ? " " : "") + "速" + p.SpeedLevel.ToString(Inv);
                Mono(g, parts, lr, ty, 13, C.TextL, Align.Right, false);
            }

            PrinterTrays(g, x + w - P.TrayColW - 10, y, h, p);
        }

        /// <summary>
        /// 面板：圆角底 + 描边 + **胶囊居中标题**。
        ///
        /// ★ 2026-10-15 对齐 ArkTS（用户 2026-10-14 的原话："系统，DSH 会话这几个搞到居中
        ///   会不会好看点"）：标题从"左侧 4px 强调条 + 裸文字"改成**胶囊包裹 + 水平居中**。
        ///   原来那条强调条也去掉了 —— 胶囊本身已起强调作用，两者并存太花。
        /// </summary>
        private static void Panel(Graphics g, double x, double y, double w, double h,
                                  Color accent, string title, string right)
        {
            FillRounded(g, x, y, w, h, 14, C.Panel);
            StrokeRounded(g, x + 0.5, y + 0.5, w - 1, h - 1, 14, C.Border);

            // 胶囊标题（底色 18% + 2px 描边 + 全圆角 + 水平居中）
            Font tf = F.SansFont(19, true);
            double tw = g.MeasureString(title, tf, int.MaxValue,
                            StringFormat.GenericTypographic).Width;
            double pillH = 30;
            double pillX = x + (w - (tw + 26)) / 2;
            double pillY = y + 16;
            FillRounded(g, pillX, pillY, tw + 26, pillH, pillH / 2, WithAlpha(accent, 0.18));
            StrokeRounded(g, pillX + 1, pillY + 1, tw + 24, pillH - 2, (pillH - 2) / 2, accent);
            TextAt(g, title, pillX + 13, pillY + pillH / 2 + 1, tf, accent, Align.Left);

            if (right != null)
            {
                Mono(g, right, x + w - 18, y + 31, 16, C.TextL, Align.Right, false);
            }
        }

        /// <summary>ArkTS 的 label()：sans-serif 常规字重，垂直居中</summary>
        private static void Label(Graphics g, string text, double x, double y, double size,
                                  Color color, Align align)
        {
            TextAt(g, text, x, y, F.SansFont(size, false), color, align);
        }

        /// <summary>ArkTS 的 mono()：monospace，weight 由调用方给 bold/normal</summary>
        private static void Mono(Graphics g, string text, double x, double y, double size,
                                 Color color, Align align, bool bold)
        {
            TextAt(g, text, x, y, F.MonoFont(size, bold), color, align);
        }

        /// <summary>
        /// 单行文字：等价于 canvas 的 textAlign(left|center|right) + textBaseline(middle)。
        /// GDI+ 的 PointF 重载会把对齐算在一个"刚好包住文字"的矩形里（等于没对齐），
        /// 所以这里自己量宽度算左边界，再用一个足够大的矩形交给 DrawString 垂直居中。
        /// </summary>
        private static void TextAt(Graphics g, string text, double x, double y, Font font,
                                   Color color, Align align)
        {
            if (string.IsNullOrEmpty(text) || font == null)
            {
                return;
            }
            double w = Measure(g, text, font);
            double left = x;
            if (align == Align.Center)
            {
                left = x - w / 2;
            }
            else if (align == Align.Right)
            {
                left = x - w;
            }
            float boxW = (float)(w + 16);
            float boxH = (float)(font.Height * 3);
            RectangleF box = new RectangleF((float)left, (float)(y - font.Height * 1.5), boxW, boxH);
            using (SolidBrush b = new SolidBrush(color))
            {
                g.DrawString(text, font, b, box, FmtBox);
            }
        }

        private static readonly StringFormat FmtBox = MakeFmt();

        private static StringFormat MakeFmt()
        {
            StringFormat f = new StringFormat(StringFormat.GenericTypographic);
            f.Alignment = StringAlignment.Near;
            f.LineAlignment = StringAlignment.Center;
            f.Trimming = StringTrimming.None;
            f.FormatFlags = f.FormatFlags | StringFormatFlags.NoWrap | StringFormatFlags.NoClip;
            return f;
        }

        /// <summary>量文本宽度（对应 ctx.measureText().width）</summary>
        private static double Measure(Graphics g, string text, Font font)
        {
            if (string.IsNullOrEmpty(text) || font == null)
            {
                return 0;
            }
            SizeF s = g.MeasureString(text, font, new PointF(0f, 0f), FmtBox);
            return s.Width;
        }

        /// <summary>
        /// 等宽大字**自动缩字号**（对齐 ArkTS `Dashboard.drawShrink`）。
        /// 从 startSize 逐 1 往下试到 minSize；到下限仍放不下才截断加省略号。
        /// 返回实际使用的字号。
        /// </summary>
        private static double ShrinkMono(Graphics g, string text, double x, double y,
                                         double maxW, double startSize, double minSize,
                                         Color color)
        {
            double size = startSize;
            Font font = F.MonoFont(size, true);
            while (size > minSize && Measure(g, text, font) > maxW)
            {
                size -= 1;
                font = F.MonoFont(size, true);
            }
            string shown = Measure(g, text, font) > maxW ? FitText(g, text, font, maxW) : text;
            TextAt(g, shown, x, y, font, color, Align.Left);
            return size;
        }

        /// <summary>单行截断：超出 maxW 就裁掉并加省略号（防止长项目名/主机名撑破面板）</summary>
        private static string FitText(Graphics g, string text, Font font, double maxW)
        {
            if (text == null)
            {
                text = "";
            }
            if (text.Length == 0 || Measure(g, text, font) <= maxW)
            {
                return text;
            }
            int lo = 0;
            int hi = text.Length;
            while (lo < hi)
            {
                int mid = (int)Math.Floor((lo + hi + 1) / 2.0);
                if (Measure(g, text.Substring(0, mid) + "…", font) <= maxW)
                {
                    lo = mid;
                }
                else
                {
                    hi = mid - 1;
                }
            }
            return text.Substring(0, lo) + "…";
        }

        /// <summary>
        /// 右侧数值的安全宽度：面板内宽减去左侧标签宽度与间隔。
        /// 面板变窄后（274px），长数值必须截断，否则会压到标签上。
        /// </summary>
        private static double ValueMaxW(Graphics g, double panelW, string labelText, Font labelFont)
        {
            double labW = Measure(g, labelText, labelFont);
            double avail = panelW - 44 - labW - 10;
            return avail > 60 ? avail : 60;
        }

        /// <summary>按宽度折行（支持中英文混排）</summary>
        private static List<string> Wrap(Graphics g, string text, Font font, double maxW, int maxLines)
        {
            List<string> lines = new List<string>();
            if (text == null)
            {
                text = "";
            }
            string cur = "";
            bool truncated = false;
            for (int i = 0; i < text.Length; i++)
            {
                char ch = text[i];
                if (ch == '\n')
                {
                    lines.Add(cur);
                    cur = "";
                    if (lines.Count >= maxLines)
                    {
                        truncated = i < text.Length - 1;
                        break;
                    }
                    continue;
                }
                string test = cur + ch;
                if (Measure(g, test, font) > maxW && cur.Length > 0)
                {
                    lines.Add(cur);
                    cur = ch.ToString();
                    if (lines.Count >= maxLines)
                    {
                        truncated = true;
                        cur = "";
                        break;
                    }
                }
                else
                {
                    cur = test;
                }
            }
            if (cur.Length > 0 && lines.Count < maxLines)
            {
                lines.Add(cur);
            }
            if (truncated && lines.Count > 0)
            {
                string last = lines[lines.Count - 1];
                while (last.Length > 1 && Measure(g, last + "…", font) > maxW)
                {
                    last = last.Substring(0, last.Length - 1);
                }
                lines[lines.Count - 1] = last + "…";
            }
            return lines;
        }

        /// <summary>进度条（ArkTS 的 bar()）</summary>
        private static void Bar(Graphics g, double x, double y, double w, double h,
                                double pct, Color color)
        {
            FillRounded(g, x, y, w, h, h / 2, C.BarBg);
            double p = Math.Max(0, Math.Min(100, pct));
            if (p > 0)
            {
                FillRounded(g, x, y, Math.Max(h, w * p / 100), h, h / 2, color);
            }
        }

        // ---------- 面板 0：系统 ----------

        private static void SystemPanel(Graphics g, double x, double y, double w, double h,
                                        SystemInfo sys)
        {
            Panel(g, x, y, w, h, C.Blue, "系统", null);

            double cpu = sys == null ? 0 : sys.Cpu;
            double cores = sys == null ? 0 : sys.Cores;
            double memUsed = sys == null ? 0 : sys.MemUsed;
            double memTotal = sys == null ? 0 : sys.MemTotal;
            double load1 = sys == null ? 0 : sys.Load1;
            double load5 = sys == null ? 0 : sys.Load5;
            double load15 = sys == null ? 0 : sys.Load15;
            double temp = sys == null ? -1 : sys.CpuTemp;
            string host = sys == null || sys.Host == null ? "-" : sys.Host;
            double uptime = sys == null ? 0 : sys.UptimeSec;

            // CPU 圆环
            double cx = x + w / 2;
            double cy = y + 150;
            double r = 62;
            Ring(g, cx, cy, r, 14, 0, 360, C.BarBg);

            double pct = Math.Max(0, Math.Min(100, cpu));
            Ring(g, cx, cy, r, 14, -90, 360 * pct / 100, C.ByPercent(pct));

            // 字号放大后（F.Scale）这两行会挨上：数值上移 4、cores 下移 6（与 ArkTS 同款）
            Mono(g, Fixed(pct, 0) + "%", cx, cy - 10, 34, C.TextW, Align.Center, true);
            Label(g, cores > 0 ? Num(cores) + " cores" : "CPU", cx, cy + 30, 15, C.TextS,
                Align.Center);

            // 内存
            double memPct = memTotal > 0 ? (memUsed / memTotal * 100) : 0;
            // 竖装时这个面板只有 380 高（横装 452），而底部"主机名+运行时长"两行位置固定
            // （分隔线 y+h-62、文字 y+h-38），不整块上移的话"CPU 温度"行会压到主机名上
            // —— Windows 渲染实测 y=956..977 两行墨迹连成一片。横装 dy=0，布局不变。
            double dy = h >= 420 ? 0 : -34;

            Label(g, "内存", x + 22, y + 246 + dy, 17, C.TextS, Align.Left);
            string memTxt = Fixed(memUsed / 1024.0, 1) + " / " + Fixed(memTotal / 1024.0, 1) + " GB";
            Mono(g, FitText(g, memTxt, F.MonoFont(16, false),
                    ValueMaxW(g, w, "内存", F.SansFont(17, false))),
                x + w - 22, y + 246 + dy, 16, C.TextW, Align.Right, false);
            Bar(g, x + 22, y + 262 + dy, w - 44, 12, memPct, C.Green);

            // 负载
            Label(g, "负载", x + 22, y + 300 + dy, 17, C.TextS, Align.Left);
            string loadTxt = Fixed(load1, 2) + "  " + Fixed(load5, 2) + "  " + Fixed(load15, 2);
            Mono(g, FitText(g, loadTxt, F.MonoFont(16, false),
                    ValueMaxW(g, w, "负载", F.SansFont(17, false))),
                x + w - 22, y + 300 + dy, 16, C.TextW, Align.Right, false);

            // 温度（本机若不暴露 thermal_zone 则不显示）
            if (temp >= 0)
            {
                double ty = y + 334 + dy;
                Color tc = temp >= 85 ? C.Red : (temp >= 70 ? C.Orange : C.Cyan);
                Label(g, "CPU 温度", x + 22, ty, 17, C.TextS, Align.Left);
                Mono(g, FitText(g, Fixed(temp, 0) + "°C", F.MonoFont(16, false),
                        ValueMaxW(g, w, "CPU 温度", F.SansFont(17, false))),
                    x + w - 22, ty, 16, tc, Align.Right, false);
            }

            // 电量（本机采集才有；桥端数据没有这一项时不显示）
            // 与上面的"CPU 温度"共用 y+334+dy —— 面板高度不够再开一行（分隔线在 y+h-62）。
            // 实测两者不会同时出现：Windows 侧没有无依赖的温度读数（CpuTemp=-1），
            // 鸿蒙侧取不到 thermal_zone。与 ArkTS 的 systemPanel 同款。
            double batt = sys == null ? -1 : sys.Battery;
            if (batt >= 0)
            {
                double by = y + 334 + dy;
                Color bc = batt <= 20 ? C.Red : (batt <= 40 ? C.Orange : C.Green);
                Label(g, (sys != null && sys.Charging) ? "电量（充电中）" : "电量",
                    x + 22, by, 17, C.TextS, Align.Left);
                Mono(g, Fixed(batt, 0) + "%", x + w - 22, by, 16, bc, Align.Right, false);
            }

            // 主机名 + 运行时长
            HLine(g, x + 22, x + w - 22, y + h - 62, C.Border);

            double days = Math.Floor(uptime / 86400);
            double hrs = Math.Floor((uptime % 86400) / 3600);
            double mins = Math.Floor((uptime % 3600) / 60);
            string upText = "up " + Num(days) + "d " + Num(hrs) + "h " + Num(mins) + "m";
            double upW = Measure(g, upText, F.MonoFont(14, false));
            // 给右侧运行时长留出位置，主机名超长则截断
            Label(g, FitText(g, host, F.SansFont(16, false), w - 56 - upW),
                x + 22, y + h - 38, 16, C.TextS, Align.Left);
            Mono(g, upText, x + w - 22, y + h - 38, 14, C.TextL, Align.Right, false);
        }

        // ---------- 面板 1-3：DSH 会话 ----------

        private static void AgentPanel(Graphics g, double x, double y, double w, double h,
                                       Telemetry t, State st, DateTime now)
        {
            AgentInfo ag = AgentOf(t);
            string state = ag.State == null ? "unknown" : ag.State;
            Color accent = StateColor(state);
            Panel(g, x, y, w, h, C.Deepseek, "DEEPSEEK HARNESS",
                ag.Model == null ? "" : ag.Model);

            double leftW = Math.Floor((w - 60) * 0.5);
            double midX = x + leftW + 30;

            // ---- 状态徽章（忙碌时呼吸）----
            double alpha = 1.0;
            double ms = Ms(now);
            if (state == "busy")
            {
                double phase = (ms % 2400.0) / 2400.0;
                alpha = 0.55 + 0.45 * (0.5 + 0.5 * Math.Sin(phase * Math.PI * 2));
            }
            else if (state == "waiting")
            {
                double phase = (ms % 1000.0) / 1000.0;
                alpha = phase < 0.5 ? 1.0 : 0.35;
            }
            string badgeText = StateText(state);
            Font badgeFont = F.SansFont(18, true);
            double bw = Measure(g, badgeText, badgeFont) + 40;
            double bx = x + w - 18 - bw;
            double by = y + 52;
            FillRounded(g, bx, by, bw, 34, 17, WithAlpha(accent, alpha));
            TextAt(g, badgeText, bx + bw / 2, by + 17, badgeFont, C.BadgeText, Align.Center);

            // ---- 左列：项目 / 活动 / 最后一句 ----
            string project = ag.Project == null ? "（未连接数据桥）" : ag.Project;
            Font projFont = F.MonoFont(30, true);
            Mono(g, FitText(g, project, projFont, leftW - 20),
                x + 22, y + 72, 30, C.TextW, Align.Left, true);

            List<string> chips = new List<string>();
            if (ag.Provider != null && ag.Provider.Length > 0)
            {
                chips.Add(ag.Provider);
            }
            if (ag.Turn.HasValue)
            {
                chips.Add("turn " + Num(ag.Turn.Value));
            }
            if (ag.Step.HasValue)
            {
                chips.Add("step " + Num(ag.Step.Value));
            }
            double chipX = x + 22;
            double chipLimit = x + leftW + 8;   // 左列右缘，越过就会和右列标题撞上
            for (int i = 0; i < chips.Count; i++)
            {
                string c = chips[i];
                double cw = Measure(g, c, F.MonoFont(15, false)) + 20;
                if (chipX + cw > chipLimit)
                {
                    break;
                }
                FillRounded(g, chipX, y + 96, cw, 26, 13, C.PanelHi);
                Mono(g, c, chipX + cw / 2, y + 109, 15, C.TextS, Align.Center, false);
                chipX += cw + 8;
            }

            // 活动行
            string activity = ag.Activity == null ? "等待数据…" : ag.Activity;
            Label(g, FitText(g, activity, F.SansFont(22, false), leftW - 20),
                x + 22, y + 152, 22, accent, Align.Left);

            // 当前工具
            if (ag.Tool != null && ag.Tool.Length > 0)
            {
                string toolText = FitText(g, ag.Tool, F.MonoFont(16, false), leftW - 60);
                double tw = Measure(g, toolText, F.MonoFont(16, false)) + 24;
                FillRounded(g, x + 22, y + 176, tw, 28, 6, C.PanelHi);
                Mono(g, toolText, x + 34, y + 190, 16, C.Cyan, Align.Left, false);
            }

            // ---- 底部"三行滚动留言条"（对齐 ArkTS，用户 2026-10-14 要求）----
            // ArkTS 侧原实现是最多 2 行 18px 静态文字（3 行会压到底部分隔线，审计实测过）。
            // 现改为：字号 15px、行距 30 → 3 行放得下；内容取 feed 的最后 3 条，
            // **旧→新、由暗到亮**；新条目到达时整体从 +30px 缓动到 0（300ms）——
            // 就是用户要的"带点滚动感"。
            Font font = F.SansFont(15, false);
            List<string> feed = FeedLines;
            if (feed.Count == 0 && ag.LastText != null && ag.LastText.Length > 0)
            {
                feed = Wrap(g, ag.LastText, font, leftW - 20, 3);
            }
            double scrollOff = 0;
            if (FeedAtMs > 0)
            {
                double dt = State.NowMs() - FeedAtMs;
                if (dt < 300) scrollOff = 30 * (1 - dt / 300);
            }
            int show = Math.Min(3, feed.Count);
            int start = feed.Count - show;
            double feedTop = y + 268 + scrollOff;
            double[] alphas = new double[] { 0.42, 0.68, 1.0 };
            for (int i = 0; i < show; i++)
            {
                int idx = start + i;
                bool newest = (i == show - 1);
                Color col = WithAlpha(newest ? C.TextW : C.TextS, alphas[Math.Min(i, 2)]);
                Font ff = F.SansFont(15, false);
                TextAt(g, FitText(g, feed[idx], ff, leftW - 20), x + 22, feedTop + i * 30,
                       ff, col, Align.Left);
            }

            // 底部状态条
            HLine(g, x + 22, x + leftW + 8, y + h - 44, C.Border);
            string bridge = t.Agent == null ? "数据桥：无数据" : "数据桥：已连接";
            Label(g, bridge, x + 22, y + h - 24, 14, C.TextL, Align.Left);

            // ---- 右列：待办进度 + 列表 ----
            // 注意：右列整体从 y+104 起算，避开右上角的状态徽章（y+52..y+86），
            // 否则「N/M」进度数字会与徽章重叠（布局审计 layout_check.py 抓到的真问题）
            Label(g, "任务进度", midX, y + 104, 17, C.TextS, Align.Left);

            List<TodoItem> todos = t.Todos == null ? new List<TodoItem>() : t.Todos;
            int done = 0;
            for (int i = 0; i < todos.Count; i++)
            {
                if (todos[i].Status == "completed")
                {
                    done++;
                }
            }
            int total = todos.Count;
            string progText = total > 0 ? done.ToString(Inv) + "/" + total.ToString(Inv) : "—";
            Mono(g, progText, x + w - 22, y + 104, 30, C.TextW, Align.Right, true);

            // 分段进度条
            double segY = y + 124;
            double segW = w - (midX - x) - 22;
            if (total > 0)
            {
                double segGap = 4;
                double segItemW = (segW - segGap * (total - 1)) / total;
                for (int i = 0; i < total; i++)
                {
                    double sx = midX + i * (segItemW + segGap);
                    string stt = todos[i].Status == null ? "pending" : todos[i].Status;
                    Color col = C.BarBg;
                    if (stt == "completed")
                    {
                        col = C.Green;
                    }
                    else if (stt == "in_progress")
                    {
                        col = C.Deepseek;
                    }
                    FillRounded(g, sx, segY, Math.Max(3, segItemW), 10, 5, col);
                }
            }
            else
            {
                Bar(g, midX, segY, segW, 10, 0, C.BarBg);
            }

            // 待办列表
            double ty = y + 160;
            // 最多 8 条：再多会撞到底部分隔线（y+h-44）
            int shown = Math.Min(todos.Count, 8);
            if (todos.Count == 0)
            {
                Label(g, "暂无待办（DSH 写入 todo/write 事件后显示）", midX, ty + 8, 17,
                    C.TextL, Align.Left);
            }
            for (int i = 0; i < shown; i++)
            {
                TodoItem td = todos[i];
                string stt = td.Status == null ? "pending" : td.Status;
                string glyph = "○";
                Color col = C.TextL;
                if (stt == "completed")
                {
                    glyph = "✓";
                    col = C.TextD;
                }
                else if (stt == "in_progress")
                {
                    glyph = "▶";
                    col = C.Cyan;
                }
                Label(g, glyph, midX, ty + 9, 17, col, Align.Left);
                Font itemFont = F.SansFont(17, false);
                List<string> itemLines = Wrap(g, td.Content == null ? "" : td.Content,
                    itemFont, segW - 26, 1);
                Label(g, itemLines.Count > 0 ? itemLines[0] : "", midX + 22, ty + 9, 17,
                    stt == "completed" ? C.TextD : C.TextS, Align.Left);
                ty += 32;
            }
        }

        private static Color StateColor(string state)
        {
            if (state == "busy")
            {
                return C.Deepseek;
            }
            if (state == "waiting")
            {
                return C.Orange;
            }
            if (state == "idle")
            {
                return C.Green;
            }
            return C.TextL;
        }

        private static string StateText(string state)
        {
            if (state == "busy")
            {
                return "● 工作中";
            }
            if (state == "waiting")
            {
                return "◆ 等待输入";
            }
            if (state == "idle")
            {
                return "○ 空闲";
            }
            return "— 未知";
        }

        // ---------- 面板 4：用量 + 时钟 ----------

        private static void UsagePanel(Graphics g, double x, double y, double w, double h,
                                       Telemetry t, State st, DateTime now)
        {
            Panel(g, x, y, w, h, C.Cyan, "用量", null);

            TokenInfo tk = t.Tokens == null ? new TokenInfo() : t.Tokens;
            double todayTotal = tk.TodayTotal;
            double inTok = tk.TodayInput;
            double outTok = tk.TodayOutput;
            double ctxUsed = tk.ContextUsed;
            double ctxWin = tk.ContextWindow;
            double cost = tk.CostUsd.HasValue ? tk.CostUsd.Value : -1;

            Label(g, "今日 TOKEN", x + 22, y + 72, 16, C.TextS, Align.Left);
            Mono(g, FitText(g, FmtTokens(todayTotal), F.MonoFont(34, true),
                    ValueMaxW(g, w, "今日 TOKEN", F.SansFont(16, false))),
                x + w - 22, y + 72, 34, C.TextW, Align.Right, true);

            Label(g, "↑ " + FmtTokens(inTok) + "  ↓ " + FmtTokens(outTok),
                x + w - 22, y + 104, 15, C.TextL, Align.Right);

            // 上下文占用
            double cpct = ctxWin > 0 ? (ctxUsed / ctxWin * 100) : 0;
            Label(g, "上下文", x + 22, y + 140, 16, C.TextS, Align.Left);
            Mono(g, ctxWin > 0 ? Fixed(cpct, 1) + "%" : "—", x + w - 22, y + 140, 16,
                C.TextW, Align.Right, false);
            Bar(g, x + 22, y + 156, w - 44, 12, cpct, C.ByPercent(cpct));

            if (cost >= 0)
            {
                Label(g, "预估花费", x + 22, y + 194, 16, C.TextS, Align.Left);
                Mono(g, "$" + Fixed(cost, 3), x + w - 22, y + 194, 16, C.Orange,
                    Align.Right, false);
            }

            // 时钟 + 日期（对齐 ArkTS `usagePanel()` 1546-1553 行）
            //
            // ★ 2026-10-15 修正。原来这里写的是 `HH:MM:SS` + 52px + `yyyy-MM-dd` ——
            //   那是 ArkTS **竖屏版** `usagePanelV()` 的写法，我移植时抄错了分支。
            //   横屏版是：
            //     time    = `HH:mm`（**不含秒**），F.monoFont(28,'bold')，y+344
            //     dateStr = `M月D日 周X`（不是 yyyy-MM-dd），14px 次要字号，y+396
            //   用户反馈"日期的分钟后面有…、字体太大"，正是 52px 带秒的时钟撑爆了面板宽度。
            string time = Pad2(now.Hour) + ":" + Pad2(now.Minute);
            Mono(g, FitText(g, time, F.MonoFont(28, true), w - 44),
                x + w / 2, y + 344, 28, C.TextW, Align.Center, true);

            string[] week = new string[] { "日", "一", "二", "三", "四", "五", "六" };
            string dateStr = now.Month.ToString(Inv) + "月" + now.Day.ToString(Inv) + "日 周"
                + week[(int)now.DayOfWeek];
            Label(g, dateStr, x + w / 2, y + 396, 14, C.TextL, Align.Center);

            // ★ 2026-10-15 删除：原来这里还画了"天气"和"歌词"两行 ——
            //   但 ArkTS 的横屏 `usagePanel()` **没有**这两行（天气只在竖屏顶栏画，
            //   见 Dashboard.ets:229/248）。而且它们的位置（y+348 / y+382）
            //   正好和新对齐的时钟(y+344)/日期(y+396) 重叠，会糊成一团。

            // 底部：该屏的自检状态（ArkTS 版是 USB/桥/帧率/JPEG 尺寸，来自 FrameStats；
            // 本版契约没有 FrameStats，用 State 的等价信息顶替，位置字号颜色不变）
            HLine(g, x + 22, x + w - 22, y + h - 46, C.Border);

            Mono(g, LinkText(st), x + 22, y + h - 26, 13, LinkColor(st), Align.Left, false);
            Mono(g, BridgeText(st), x + w - 22, y + h - 26, 13, BridgeColor(st),
                Align.Right, false);
        }

        // ==================================================================
        //  FrameStats 槽位的等价替换（本版签名没有 FrameStats，见文件头说明）
        // ==================================================================

        private static string LinkText(State st)
        {
            if (st != null && st.Fresh)
            {
                return "数据 ● " + st.Packets.ToString(Inv) + " 包";
            }
            return "数据 ○ 未连接";
        }

        private static Color LinkColor(State st)
        {
            return st != null && st.Fresh ? C.Green : C.TextD;
        }

        private static string FrameCountText(State st)
        {
            int n = st == null ? 0 : st.Packets;
            return n.ToString(Inv) + " 包";
        }

        private static string BridgeText(State st)
        {
            double age = st == null ? -1 : st.AgeSec();
            if (age < 0)
            {
                return "桥 ○";
            }
            return "桥 ● " + Num(age) + "s";
        }

        private static Color BridgeColor(State st)
        {
            double age = st == null ? -1 : st.AgeSec();
            return age >= 0 && age < 10 ? C.Green : C.TextD;
        }

        // ==================================================================
        //  小工具
        // ==================================================================

        private static Telemetry DataOf(State st)
        {
            if (st == null || st.Data == null)
            {
                return new Telemetry();
            }
            return st.Data;
        }

        /// <summary>
        /// 取 agent 段：ArkTS 里是 `t.agent ?? {}`（整段缺失时字段全是 undefined），
        /// C# 的 AgentInfo 字段有非空默认值（"空闲" / "（未知项目）"），
        /// 所以整段缺失时要把字段显式清成 null，才能落到「（未连接数据桥）」「等待数据…」。
        /// </summary>
        private static AgentInfo AgentOf(Telemetry t)
        {
            if (t.Agent != null)
            {
                return t.Agent;
            }
            AgentInfo a = new AgentInfo();
            a.State = null;
            a.Activity = null;
            a.Tool = null;
            a.LastText = null;
            a.Project = null;
            a.SessionId = null;
            a.Model = null;
            a.Provider = null;
            a.Turn = null;
            a.Step = null;
            return a;
        }

        /// <summary>当天毫秒数（对应 ArkTS 的 Date.now() % N，只用于动画相位）</summary>
        private static double Ms(DateTime now)
        {
            return now.TimeOfDay.TotalMilliseconds;
        }

        /// <summary>给颜色叠加透明度（对应 canvas 的 globalAlpha）</summary>
        private static Color WithAlpha(Color c, double alpha)
        {
            if (alpha >= 1.0)
            {
                return c;
            }
            if (alpha < 0)
            {
                alpha = 0;
            }
            return Color.FromArgb((int)Math.Round(alpha * 255), c.R, c.G, c.B);
        }

        /// <summary>ArkTS 的 fmtTokens：≥1e8 → 亿（2 位小数），≥1e4 → 万（1 位小数），否则原样</summary>
        private static string FmtTokens(double n)
        {
            if (n >= 100000000)
            {
                return Fixed(n / 100000000.0, 2) + "亿";
            }
            if (n >= 10000)
            {
                return Fixed(n / 10000.0, 1) + "万";
            }
            return Num(n);
        }

        /// <summary>等价于 JS 的 toFixed(digits)</summary>
        private static string Fixed(double v, int digits)
        {
            if (double.IsNaN(v) || double.IsInfinity(v))
            {
                v = 0;
            }
            return v.ToString("F" + digits.ToString(Inv), Inv);
        }

        /// <summary>等价于 ArkTS 模板串里直接嵌一个 number（12.0 → "12"，12.5 → "12.5"）</summary>
        private static string Num(double v)
        {
            if (double.IsNaN(v) || double.IsInfinity(v))
            {
                return "0";
            }
            double r = Math.Round(v);
            if (Math.Abs(v - r) < 1e-9 && Math.Abs(r) < 1e15)
            {
                return ((long)r).ToString(Inv);
            }
            return v.ToString("0.####", Inv);
        }

        private static string Pad2(int n)
        {
            return n < 10 ? "0" + n.ToString(Inv) : n.ToString(Inv);
        }
    }
}
