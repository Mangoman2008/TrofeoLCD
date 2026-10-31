/**
 * ThemeCore.cs — 主题调度与共享绘制工具（C# 5 移植版）
 *
 * 逐行对照鸿蒙版移植：
 *   - 调度框架等价于 `LcdService.ets` 里那条 `this.theme === N` 的 if-else 长链
 *   - 共享工具等价于 `Dashboard.ets` 的 drawShrink / fitText / 逐字字距 / 胶囊标题
 *   - Backdrop 等价于 `render/Backdrop.ets`（trofeo-lcd-rs 的 background_effect）
 *   - HostStats 等价于 `service/HostStats.ets`（纯本机数据，不走数据桥）
 *
 * ⚠️ **语言上限：C# 5**（.NET Framework 4 的 csc，构建 VM 上只有这个）。
 * 因此本文件严格禁用：
 *   字符串插值 `$"..."`、空传播 `?.`、表达式体成员 `=> x;`、`out var`、元组、
 *   `nameof`、默认参数以外的 C# 6+ 特性。全部用 `string.Format` 与显式 if。
 */
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace DshLcd
{
    /// <summary>主题渲染器的签名。与 ArkTS 各 Theme*.render 的参数对齐（FrameStats 本版没有）。</summary>
    public delegate void ThemeRenderer(Graphics g, State st, Bitmap vm, double vmAgeMs,
                                       string vmErr, long now);

    /// <summary>
    /// 打砖块状态的**只读快照**（主题 6 的"时钟·打砖块"屏要用它那三个实时量）。
    /// 做成独立的小类而不是直接把 `PongState` 传出去 —— 快照一旦取出就不再变动，
    /// 避免两个主题同时持有可变状态而产生难查的耦合。
    /// </summary>
    public class PongSnapshot
    {
        public double BallX = -1;
        public double BallY = -1;
        public double PaddleX = 184;
        public bool[][] Bricks;
    }

    /// <summary>
    /// 打砖块（主题 4）的状态持有器。
    ///
    /// ★ 为什么需要它：`ThemePong` 的渲染是**纯函数**（同一份 state 逐像素一致），
    ///   而游戏状态必须**跨帧保持**（球会动）。ArkTS 侧由 `LcdService` 持有 `pongState`
    ///   并在每帧调 `pongAdvance`；C# 侧的 `Dispatch` 是无状态的静态调用，
    ///   所以在这里放一个持有器，语义与 ArkTS 的拥有者一致。
    ///
    /// 单线程访问：只在帧循环里被 `Dispatch` 调用，无需加锁。
    /// </summary>
    public static class PongHolder
    {
        private static PongState _st;
        private static long _lastMs;
        private static double _lastFps;

        public static PongState State()
        {
            if (_st == null)
            {
                // 种子用启动时刻，每台机器/每次启动的开局不同（与 ArkTS 的 seed 语义一致）
                _st = ThemePong.Init(DshLcd.State.NowMs() % 100000);
                _lastMs = DshLcd.State.NowMs();
            }
            return _st;
        }

        /// <summary>按真实经过时间推进（单帧最多补 8 tick，防卡顿后穿砖）</summary>
        public static void Advance(long nowMs)
        {
            PongState st = State();
            if (_lastMs == 0) { _lastMs = nowMs; return; }
            double dt = nowMs - _lastMs;
            _lastMs = nowMs;
            if (dt <= 0) return;
            // 帧率（供左栏显示，便于判断球为什么"跳"）
            _lastFps = dt > 0 ? (1000.0 / dt) : 0;
            ThemePong.Advance(st, dt);
        }

        public static double LastFps() { return _lastFps; }

        /// <summary>取当前状态的只读快照（供主题 6 的"时钟·打砖块"屏复用同一场游戏）</summary>
        public static PongSnapshot Snapshot()
        {
            PongState s = State();
            PongSnapshot snap = new PongSnapshot();
            snap.BallX = s.BallActive ? s.BallX : -1;
            snap.BallY = s.BallY;
            snap.PaddleX = s.PaddleX;
            snap.Bricks = s.Bricks;
            return snap;
        }

        /// <summary>重开一局（留给 /set 或界面按钮调用）</summary>
        public static void Reset()
        {
            _st = ThemePong.Init(DshLcd.State.NowMs() % 100000);
            _lastMs = DshLcd.State.NowMs();
        }
    }

    /// <summary>
    /// 运行统计的**全局只读快照**（对齐 ArkTS 的 `FrameStats`）。
    ///
    /// ★ 为什么不把 FrameStats 加进渲染签名：ArkTS 的每个 Theme.render 都多收一个
    ///   `fs: FrameStats`，但 C# 侧的渲染链是 `LcdRunner → Themes.Dispatch → Dashboard/Theme*`，
    ///   为了主题 1 的**页脚一行**去改整条签名（含 Dashboard 的 4 个入口）不值当。
    ///   改为由帧循环每帧写一次这个小快照，主题按需读。
    /// </summary>
    public static class FrameStats
    {
        public static bool UsbOpen;
        public static long Sent;
        public static long Errors;
        /// <summary>距上次收到遥测的秒数（-1 = 从没收到）</summary>
        public static double BridgeAgeSec = -1;
        /// <summary>一帧 JPEG 的字节数（0 = 还没编过）</summary>
        public static int JpegBytes;
        public static int JpegW;
        public static int JpegH;
        /// <summary>本帧各阶段耗时（毫秒）—— 主题 3 的"本屏"栏显示它们</summary>
        public static double RenderMs;
        public static double EncodeMs;
        public static double PushMs;
        /// <summary>因背压跳过的帧数</summary>
        public static long SkippedFrames;
    }

    /// <summary>主题档位（对齐 ArkTS 的 theme 0..15）</summary>
    public static class Themes
    {
        public const int Count = 16;

        public const int Dashboard = 0;
        public const int Diag = 1;
        public const int Wall = 2;
        public const int Pages = 3;
        public const int Pong = 4;
        public const int Dotii = 5;
        public const int FwSim = 6;
        public const int Trcc = 7;
        public const int Mac = 8;
        public const int DotiiInPrinter = 9;   // 借位档：打印机格让给 Dotii
        public const int AnimeCyber = 10;
        public const int AnimeWall = 11;
        public const int AnimeFree = 12;
        public const int AnimeHud = 13;        // 明亮二次元 HUD（唯一浅色主题）
        public const int NanoMuse = 14;
        public const int TrofeoRust = 15;      // 复刻 trofeo-lcd-rs

        private static readonly string[] Names = new string[]
        {
            "仪表盘", "诊断终端", "监控墙", "分页屏", "打砖块", "Dotii",
            "固件仿真", "官方浅色", "MacTR", "打印机位 Dotii",
            "赛博二次元", "二次元壁纸", "二次元·无框", "明亮二次元HUD", "NanoMuse", "trofeo-lcd"
        };

        public static string Name(int theme)
        {
            if (theme < 0 || theme >= Names.Length) return "未知";
            return Names[theme];
        }

        /// <summary>把 /set?theme=N 的入参收敛到合法范围（对齐 ArkTS 的 `(n>=0 && n<=15) ? n : 0`）</summary>
        public static int Clamp(double n)
        {
            int v = (int)Math.Round(n);
            if (v < 0 || v >= Count) return 0;
            return v;
        }

        /// <summary>
        /// 主题调度。等价于 ArkTS `LcdService` 里那条 if-else 链。
        /// 每个主题的实现文件见 win/src/Theme*.cs；**未实现的先回落到仪表盘**，
        /// 并在返回值里说明，避免"设了主题却什么都不画"。
        /// </summary>
        public static string Dispatch(Graphics g, int theme, State st, Bitmap vm,
                                      double vmAgeMs, string vmErr, long now,
                                      bool vertical, string printerCell,
                                      History hist)
        {
            // hist 供主题 2/3 画趋势曲线（它们的签名需要它）；未移植的主题忽略它
            if (hist == null) { /* 主题 0/1/5/7~15 不需要曲线数据 */ }
            // ★ 时间类型换算：`Dispatch` 的 now 是 **epoch 毫秒（long）**（14 个主题都用这个量纲，
            //   它们要算动画相位、按毫秒取模），而 `Dashboard` 的两个入口收的是 `DateTime`
            //   （仪表盘要取 now.Hour / now.Minute 做时钟显示）。
            //   所以在调用 Dashboard 前换算一次，而不是把参数类型改来改去。
            DateTime wall = DateTime.Now;
            // 竖装只支持仪表盘（ArkTS 侧 HORIZONTAL_ONLY 也是这个语义：
            // 主题 6/7 等在竖装下会自动回落到主题 0）
            if (vertical)
            {
                DshLcd.Dashboard.RenderVertical(g, st, vm, vmAgeMs, vmErr, wall);
                return "vertical";
            }
            // 主题 0（仪表盘）走 printerCell 档位（v6/v4/printer）—— ArkTS 侧也是这个分工：
            // 「打印机格显示什么」只在主题 0 下有意义。
            string pc = (printerCell == null) ? "printer" : printerCell;
            // 主题 9「打印机位 Dotii」= 借位档（ArkTS 里 `cellLayout=1`）
            if (theme == Themes.DotiiInPrinter)
            {
                pc = "borrowed";
            }

            switch (theme)
            {
                case Themes.FwSim:
                    {
                        // 主题 6「固件仿真屏」：ESP32-S3 固件 UI 复刻（18 屏里 4 屏全保真）
                        FwSimState fs = FwSimState.FromState(st, PongHolder.Snapshot());
                        DshLcd.FwSim.ApplyOverride(fs, LcdRunner.FwSimOverride);
                        DshLcd.FwSim.Render(g, fs, now);
                        return DshLcd.FwSim.IsPorted(fs.Screen) ? "fwsim" : "fwsim-placeholder";
                    }
                case Themes.Pong:
                    // 主题 4「打砖块」：状态由 PongHolder 跨帧保持，按真实经过时间推进
                    PongHolder.Advance(now);
                    ThemePong.Render(g, PongHolder.State(), PongHolder.LastFps(),
                                     FrameStats.RenderMs);
                    return "pong";
                case Themes.Pages:
                    // 主题 3「分页屏」：4 个子页每 10 秒自动翻页（C# 侧暂无锁定开关）
                    ThemePages.Render(g, st, hist, (int)((now / 10000) % ThemePages.PageCount));
                    return "pages";
                case Themes.Wall:
                    // 主题 2「监控墙」：趋势曲线 + 健康灯 + 还能用多久
                    ThemeWall.Render(g, st, hist);
                    return "wall";
                case Themes.AnimeCyber:
                    // 主题 10「赛博二次元」：霓虹青紫 + 扫描线 + 故障色差 + 片假名装饰
                    ThemeCyber.Render(g, st, now);
                    return "anime-cyber";
                case Themes.DotiiInPrinter:
                    // 主题 9「打印机位 Dotii」：借位档 —— Dotii 进打印机位（409 宽），
                    // DSH 吃掉让出的宽度、USAGE 右移。几何见 L.CellBorrow* 的注释。
                    DshLcd.Dashboard.RenderHorizontal(g, st, vm, vmAgeMs, vmErr, wall, "borrowed");
                    return "dotii-in-printer";
                case Themes.Mac:
                    // 主题 8「MacTR 五格」：与主题 0 同几何、换 MacTR 的视觉语言
                    ThemeMac.Render(g, st);
                    return "mac";
                case Themes.Trcc:
                    // 主题 7「官方浅色风」：复刻 Thermalright 官方 1920×462 主题
                    ThemeTrcc.Render(g, TrccStateFrom(st, now));
                    return "trcc";
                case Themes.Diag:
                    // 主题 1「诊断终端」：事件流 + 指标栏 + 体检条
                    ThemeDiag.Render(g, st);
                    return "diag";
                case Themes.Dotii:
                    // 主题 5「Dotii 分页屏」整屏版
                    ThemeDotii.Render(g, DotiiState.FromState(st), now);
                    return "dotii";
                case Themes.AnimeWall:
                    ThemeAnimeBG.Render(g, st, now);
                    return "anime-wall";
                case Themes.AnimeFree:
                    ThemeAnimeFree.Render(g, st, now);
                    return "anime-free";
                case Themes.AnimeHud:
                    ThemeAnimeHUD.Render(g, st, now);
                    return "anime-hud";
                case Themes.NanoMuse:
                    ThemeNanoMuse.Render(g, st, now);
                    return "nanomuse";
                case Themes.TrofeoRust:
                    ThemeTrofeoRust.Render(g, st, now);
                    return "trofeo-lcd";
                default:
                    // 主题 0 与其余未移植主题都走仪表盘；printerCell 决定它的格子排法
                    DshLcd.Dashboard.RenderHorizontal(g, st, vm, vmAgeMs, vmErr, wall, pc);
                    return (theme == Themes.Dashboard) ? "dashboard" : "fallback-dashboard";
            }
        }
    /// <summary>
    /// 由遥测 + 本机采集构造 TRCC 主题状态。
    /// 对齐 ArkTS `LcdService` 里填 `trccState` 的那段（含"本机没有独立 GPU"的处理）。
    /// </summary>
    public static TrccState TrccStateFrom(State st, long now)
    {
            TrccState tc = new TrccState();
            // 配色：默认 -1 = 30 秒自动轮换（ArkTS 侧同语义）
            tc.Palette = (int)((now / 30000) % ThemeTrcc.ThemeCount);
            DateTime d = DateTime.Now;
            tc.Hour = d.Hour;
            tc.Minute = d.Minute;
            string[] wk = new string[] { "日", "一", "二", "三", "四", "五", "六" };
            tc.DateText = string.Format("{0} {1}/{2:00}/{3:00}",
                "星期" + wk[(int)d.DayOfWeek], d.Year, d.Month, d.Day);
            tc.Scale = 1.0;
            if (st == null || st.Data == null) return tc;

            SystemInfo sys = st.Data.System;
            if (sys != null)
            {
                tc.CpuTemp = sys.CpuTemp;          // Windows 无无依赖读数 → -1，面板显示 "--"
                tc.CpuLoadPct = sys.Cpu;
                tc.CpuFreqMhz = sys.CpuFreqMhz;
            }

            // 右卡：这台机器没有独立 GPU，用**真实的 token 速率**顶上
            // （ArkTS 侧同做法："宁换内容也不编 GPU 数值"）
            // ⚠️ ArkTS 侧用 `t.health.tokensPerMin`（每秒 token 速率），
            //    但 **C# 的 Telemetry 没有 health 段** → 改用现有数据表达同一语义：
            //    主数值位放"今日 token 的万位"、次数值位放本机 CPU 占用。
            tc.GpuLabel = "TOKEN";
            TokenInfo tk = st.Data.Tokens;
            double today = (tk == null) ? -1 : tk.TodayTotal;
            tc.GpuTemp = today;                                 // 主数值位（显示为 "N/min" 语义位）
            tc.GpuLoadPct = today >= 0 ? Math.Round(today) : -1;
            tc.GpuFreqMhz = sys == null ? -1 : sys.CpuFreqMhz;  // 次数值位复用频率行
            return tc;
        }
    }

    /// <summary>
    /// 绘制工具集：等价于 ArkTS `Dashboard.ets` 里的那几个文字/形状辅助。
    /// **所有主题共用**，避免每个主题各写一份导致几何算法不一致（ArkTS 侧就踩过这个坑）。
    /// </summary>
    public static class Draw
    {
        /// 注意：名字**不能**叫 Align —— Dashboard.cs 里已有一个 private enum Align，
        /// 同名会在同一命名空间里产生冲突（本仓库的静态自审工具抓到了这个）。
        public enum TextAlign { Left, Center, Right }

        // ---------------- 圆角矩形 ----------------

        public static GraphicsPath RoundRect(double x, double y, double w, double h, double r)
        {
            GraphicsPath p = new GraphicsPath();
            double rr = Math.Min(r, Math.Min(w / 2, h / 2));
            if (rr <= 0.01)
            {
                p.AddRectangle(new RectangleF((float)x, (float)y, (float)w, (float)h));
                return p;
            }
            float f = (float)rr;
            p.AddArc((float)x, (float)y, f * 2, f * 2, 180, 90);
            p.AddArc((float)(x + w - f * 2), (float)y, f * 2, f * 2, 270, 90);
            p.AddArc((float)(x + w - f * 2), (float)(y + h - f * 2), f * 2, f * 2, 0, 90);
            p.AddArc((float)x, (float)(y + h - f * 2), f * 2, f * 2, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static void FillRound(Graphics g, double x, double y, double w, double h,
                                     double r, Color c)
        {
            using (GraphicsPath p = RoundRect(x, y, w, h, r))
            using (SolidBrush b = new SolidBrush(c))
            {
                g.FillPath(b, p);
            }
        }

        public static void StrokeRound(Graphics g, double x, double y, double w, double h,
                                       double r, Color c, double width)
        {
            using (GraphicsPath p = RoundRect(x, y, w, h, r))
            using (Pen pen = new Pen(c, (float)width))
            {
                g.DrawPath(pen, p);
            }
        }

        public static void FillCircle(Graphics g, double cx, double cy, double r, Color c)
        {
            using (SolidBrush b = new SolidBrush(c))
            {
                g.FillEllipse(b, (float)(cx - r), (float)(cy - r),
                              (float)(r * 2), (float)(r * 2));
            }
        }

        public static void StrokeCircle(Graphics g, double cx, double cy, double r,
                                        Color c, double width)
        {
            using (Pen pen = new Pen(c, (float)width))
            {
                g.DrawEllipse(pen, (float)(cx - r), (float)(cy - r),
                              (float)(r * 2), (float)(r * 2));
            }
        }

        /// <summary>
        /// 圆弧（进度环用）。
        ///
        /// ⚠️ 角度换算的坑：ArkTS 侧用 canvas 的 `ctx.arc(cx,cy,r,start,end)`，
        /// 角度是**弧度、0 = 3 点方向、顺时针为正**；
        /// GDI+ 的 `DrawArc` 用的是**度、0 = 3 点方向、顺时针为正**，语义一致，
        /// 但两个平台的 y 轴都向下，所以"从 -90° 起"在两边都表示 12 点方向 —— 这里保持同一约定。
        /// </summary>
        /// <param name="startDeg">起始角（度，-90 = 12 点方向）</param>
        /// <param name="sweepDeg">扫过角（度，正 = 顺时针）</param>
        public static void Arc(Graphics g, double cx, double cy, double r,
                               double startDeg, double sweepDeg, Color c, double width)
        {
            if (Math.Abs(sweepDeg) < 0.01) return;
            using (Pen pen = new Pen(c, (float)width))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                g.DrawArc(pen, (float)(cx - r), (float)(cy - r),
                          (float)(r * 2), (float)(r * 2),
                          (float)startDeg, (float)sweepDeg);
            }
        }

        /// <summary>直线（分隔线等）</summary>
        public static void Line(Graphics g, double x1, double y1, double x2, double y2,
                                Color c, double width)
        {
            using (Pen p = new Pen(c, (float)width))
            {
                g.DrawLine(p, (float)x1, (float)y1, (float)x2, (float)y2);
            }
        }

        /// <summary>填充矩形（半透明底色、进度条轨道等）</summary>
        public static void FillRect(Graphics g, double x, double y, double w, double h, Color c)
        {
            using (SolidBrush b = new SolidBrush(c))
            {
                g.FillRectangle(b, (float)x, (float)y, (float)w, (float)h);
            }
        }

        /// <summary>
        /// 趋势曲线（对齐 ArkTS `Chrome.sparkline`）。
        ///
        /// 两个关键语义：
        ///   · **样本不足时从右边对齐**（新数据始终贴右），读起来像"直播"而不是"被拉伸"
        ///   · **断点（-1）会断开折线**（`PointY` 返回 -1 时 `started=false`，下一段重新 moveTo）
        ///     —— 这正是我修了 `Series.Push` 保留 -1 的原因
        /// </summary>
        public static void Sparkline(Graphics g, Series s, int cap,
                                     double x, double y, double w, double h,
                                     Color color, bool fill, bool dot)
        {
            if (s == null || s.Length == 0) return;
            double max = s.ScaleMax();
            int n = s.Length;
            int denom = (cap - 1 > 0) ? cap - 1 : 1;
            double x0 = x + w * (1 - (n - 1) / (double)denom);
            double step = w / denom;

            List<PointF> seg = new List<PointF>();
            List<List<PointF>> segs = new List<List<PointF>>();
            for (int i = 0; i < n; i++)
            {
                double py = s.PointY(i, y, h, max);
                if (py < 0)
                {
                    if (seg.Count > 0) { segs.Add(seg); seg = new List<PointF>(); }
                    continue;
                }
                seg.Add(new PointF((float)(x0 + i * step), (float)py));
            }
            if (seg.Count > 0) segs.Add(seg);
            if (segs.Count == 0) return;

            // 折线
            using (Pen pen = new Pen(color, 2))
            {
                for (int k = 0; k < segs.Count; k++)
                {
                    if (segs[k].Count < 2) continue;
                    g.DrawLines(pen, segs[k].ToArray());
                }
            }

            // 曲线下方渐变填充（0.28 → 0.02）
            if (fill)
            {
                for (int k = 0; k < segs.Count; k++)
                {
                    List<PointF> pts = segs[k];
                    if (pts.Count < 2) continue;
                    PointF[] poly = new PointF[pts.Count + 2];
                    for (int i = 0; i < pts.Count; i++) poly[i] = pts[i];
                    poly[pts.Count] = new PointF(pts[pts.Count - 1].X, (float)(y + h));
                    poly[pts.Count + 1] = new PointF(pts[0].X, (float)(y + h));
                    using (LinearGradientBrush br = new LinearGradientBrush(
                               new RectangleF((float)x, (float)y, (float)Math.Max(1, w), (float)Math.Max(1, h)),
                               Color.FromArgb((int)(0.28 * 255), color),
                               Color.FromArgb((int)(0.02 * 255), color),
                               LinearGradientMode.Vertical))
                    {
                        g.FillPolygon(br, poly);
                    }
                }
            }

            // 末端圆点（只画最后一段的末端）
            if (dot)
            {
                List<PointF> last = segs[segs.Count - 1];
                if (last.Count > 0)
                {
                    PointF e = last[last.Count - 1];
                    Draw.FillCircle(g, e.X, e.Y, 3.5, color);
                }
            }
        }

        // ---------------- 文字 ----------------

        /// <summary>
        /// 单行文字。等价于 canvas 的 textAlign + textBaseline(middle)。
        /// 与 Dashboard.TextAt 同样的做法：自己量宽度算左边界，再交给 DrawString。
        /// </summary>
        public static void Text(Graphics g, string text, double x, double y, Font font,
                                Color color, TextAlign align)
        {
            if (string.IsNullOrEmpty(text) || font == null) return;
            double w = g.MeasureString(text, font, int.MaxValue,
                         StringFormat.GenericTypographic).Width;
            double left = x;
            if (align == TextAlign.Center) left = x - w / 2;
            else if (align == TextAlign.Right) left = x - w;

            using (SolidBrush b = new SolidBrush(color))
            using (StringFormat sf = new StringFormat(StringFormat.GenericTypographic))
            {
                sf.FormatFlags |= StringFormatFlags.NoWrap;
                g.DrawString(text, font, b,
                    new RectangleF((float)left, (float)(y - 200),
                                   (float)(w + 8), 400), sf);
            }
        }

        /// <summary>量文字宽度（与 Text 用同一个 Typographic 度量，保证一致）</summary>
        public static double Measure(Graphics g, string text, Font font)
        {
            if (string.IsNullOrEmpty(text) || font == null) return 0;
            return g.MeasureString(text, font, int.MaxValue,
                       StringFormat.GenericTypographic).Width;
        }

        /// <summary>
        /// 按可用宽度**自动缩小字号**（ArkTS `Dashboard.drawShrink` 的等价物）。
        ///
        /// 起因（ArkTS 侧实测）：项目名 `WorkBuddy` 被截成 `WorkB...` 丢了信息，
        /// 改为"缩小字号直到放得下"，缩到下限仍放不下才截断。
        /// 返回实际使用的字号。
        /// </summary>
        public static double ShrinkText(Graphics g, string text, double x, double y,
                                        FontFamily family, bool bold, double startSize,
                                        double minSize, double maxW, Color color,
                                        Draw.TextAlign align)
        {
            double size = startSize;
            Font font = new Font(family, (float)(size * F.Scale), bold ? FontStyle.Bold : FontStyle.Regular,
                                 GraphicsUnit.Pixel);
            while (size > minSize && Measure(g, text, font) > maxW)
            {
                size -= 1;
                font = new Font(family, (float)(size * F.Scale),
                                bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
            }
            string shown = text;
            if (Measure(g, text, font) > maxW) shown = Fit(g, text, font, maxW);
            Text(g, shown, x, y, font, color, align);
            return size;
        }

        /// <summary>截断加省略号（ArkTS `Dashboard.fitText`）</summary>
        public static string Fit(Graphics g, string text, Font font, double maxW)
        {
            if (string.IsNullOrEmpty(text) || font == null) return text;
            if (Measure(g, text, font) <= maxW) return text;
            string t = text;
            while (t.Length > 1 && Measure(g, t + "…", font) > maxW)
            {
                t = t.Substring(0, t.Length - 1);
            }
            return t + "…";
        }

        /// <summary>
        /// 带字距的文字（ArkTS 侧用逐字 fillText 实现，因为 Canvas 没有 letterSpacing）。
        /// NanoMuse 的 `.fleet-lbl` 就是 9px + letter-spacing 2.5px，这里照做。
        /// 返回实际占用宽度。
        /// </summary>
        public static double Tracked(Graphics g, string s, double x, double y, Font font,
                                     Color color, double spacing, TextAlign align)
        {
            if (string.IsNullOrEmpty(s)) return 0;
            double total = -spacing;
            for (int i = 0; i < s.Length; i++)
            {
                total += Measure(g, s.Substring(i, 1), font) + spacing;
            }
            double cx = x;
            if (align == TextAlign.Center) cx = x - total / 2;
            else if (align == TextAlign.Right) cx = x - total;
            for (int i = 0; i < s.Length; i++)
            {
                string ch = s.Substring(i, 1);
                Text(g, ch, cx, y, font, color, TextAlign.Left);
                cx += Measure(g, ch, font) + spacing;
            }
            return total;
        }

        /// <summary>字距文字的宽度（不绘制）</summary>
        public static double TrackedWidth(Graphics g, string s, Font font, double spacing)
        {
            if (string.IsNullOrEmpty(s)) return 0;
            double total = -spacing;
            for (int i = 0; i < s.Length; i++)
            {
                total += Measure(g, s.Substring(i, 1), font) + spacing;
            }
            return total;
        }

        /// <summary>
        /// 胶囊标题（ArkTS `Dashboard.panel` 的版本，用户 2026-10-14 选定）。
        /// 底色 18% + 2px 描边 + 全圆角；标题**水平居中**（用户要求"搞到居中"）。
        /// </summary>
        public static void CapsuleTitle(Graphics g, double panelX, double panelW, double panelY,
                                        string title, Color pill)
        {
            Font font = F.SansFont(19, true);
            double tw = Measure(g, title, font);
            double pillH = 30;
            double pillX = panelX + (panelW - (tw + 26)) / 2;
            double pillY = panelY + 16;

            Color fill = Color.FromArgb((int)(255 * 0.18), pill);
            FillRound(g, pillX, pillY, tw + 26, pillH, pillH / 2, fill);
            StrokeRound(g, pillX + 1, pillY + 1, tw + 24, pillH - 2, (pillH - 2) / 2, pill, 2);
            Text(g, title, pillX + 13, pillY + pillH / 2 + 1, font, pill, TextAlign.Left);
        }
    }

    /// <summary>
    /// 程序化动画背景 —— 等价于 ArkTS `render/Backdrop.ets`，
    /// 复刻 trofeo-lcd-rs 的 `background_effect = plasma | aurora | lava | waves`
    /// 与 `--background-dim`（默认 40）。
    ///
    /// 关键语义（照抄自它 `effect.rs` 的 `dim()` 测试断言）：
    /// **压暗是保饱和的** —— 往黑靠的同时把比例拉回来，避免亮色压暗后变成灰。
    /// </summary>
    public static class Backdrop
    {
        public enum Style { None = 0, Plasma = 1, Aurora = 2, Lava = 3, Waves = 4, Image = 5 }

        public static Style Current = Style.Plasma;
        public static double DimPct = 40;
        public static double Speed = 1.0;
        public static Bitmap Image;              // 由 LcdRunner 从资源目录载入后注入

        /// <summary>渲染块边长（px）。16 → 120×29=3480 块；块状化对低频图案几乎无损</summary>
        private const int Block = 16;
        private const int FxStepMs = 250;

        public static readonly string[] StyleNames = new string[]
        { "none", "plasma", "aurora", "lava", "waves", "image" };

        public static Style FromName(string n)
        {
            if (string.IsNullOrEmpty(n)) return Style.None;
            n = n.Trim().ToLowerInvariant();
            for (int i = 0; i < StyleNames.Length; i++)
            {
                if (StyleNames[i] == n) return (Style)i;
            }
            return Style.None;
        }

        /// <summary>保饱和压暗（对应它 `effect.rs` 的 dim）</summary>
        public static Color Dim(Color c, double k)
        {
            const double SatKeep = 0.35;
            double w = (1 - k) * SatKeep;
            int r = Clamp255((c.R + (255 - c.R) * w) * k);
            int gg = Clamp255((c.G + (255 - c.G) * w) * k);
            int b = Clamp255((c.B + (255 - c.B) * w) * k);
            return Color.FromArgb(r, gg, b);
        }

        private static int Clamp255(double v)
        {
            if (v < 0) return 0;
            if (v > 255) return 255;
            return (int)Math.Round(v);
        }

        /// <summary>每种风格的 底/中/高 三色（已做 4:2:0 预补偿，避开纯青绿）</summary>
        private static Color[] Ramp(Style s)
        {
            switch (s)
            {
                case Style.Plasma:
                    return new Color[] { Color.FromArgb(16, 10, 46), Color.FromArgb(110, 40, 170), Color.FromArgb(70, 200, 220) };
                case Style.Aurora:
                    return new Color[] { Color.FromArgb(6, 20, 34), Color.FromArgb(30, 150, 130), Color.FromArgb(150, 240, 190) };
                case Style.Lava:
                    return new Color[] { Color.FromArgb(24, 6, 4), Color.FromArgb(200, 60, 16), Color.FromArgb(250, 190, 60) };
                case Style.Waves:
                    return new Color[] { Color.FromArgb(8, 16, 40), Color.FromArgb(40, 110, 190), Color.FromArgb(130, 210, 240) };
                default:
                    return new Color[] { Color.FromArgb(10, 10, 16), Color.FromArgb(10, 10, 16), Color.FromArgb(10, 10, 16) };
            }
        }

        public static void Render(Graphics g, int w, int h, long now)
        {
            if (Current == Style.None)
            {
                using (SolidBrush b = new SolidBrush(Color.FromArgb(10, 10, 16)))
                {
                    g.FillRectangle(b, 0, 0, w, h);
                }
                return;
            }
            if (Current == Style.Image)
            {
                if (Image != null)
                {
                    g.DrawImage(Image, 0, 0, w, h);
                    double kk = Math.Max(0, Math.Min(100, DimPct)) / 100.0;
                    if (kk > 0.01)
                    {
                        using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(kk * 255), 0, 0, 0)))
                        {
                            g.FillRectangle(b, 0, 0, w, h);
                        }
                    }
                }
                else
                {
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(10, 10, 16)))
                    {
                        g.FillRectangle(b, 0, 0, w, h);
                    }
                }
                return;
            }

            double t = (now / FxStepMs) * (FxStepMs / 1000.0) * Speed;
            Color[] pal = Ramp(Current);
            double k = 1 - Math.Max(0, Math.Min(100, DimPct)) / 100.0;

            using (SolidBrush brush = new SolidBrush(Color.Black))
            {
                for (int by = 0; by < h; by += Block)
                {
                    for (int bx = 0; bx < w; bx += Block)
                    {
                        double v = Field(Current, (double)bx / w, (double)by / h, t);
                        Color c = Ramp3(pal, v);
                        brush.Color = Dim(c, k);
                        g.FillRectangle(brush, bx, by, Block, Block);
                    }
                }
            }
        }

        private static Color Ramp3(Color[] p, double v)
        {
            double x = Math.Max(0, Math.Min(1, v));
            if (x < 0.5)
            {
                double u = x * 2;
                return Color.FromArgb(
                    Lerp(p[0].R, p[1].R, u), Lerp(p[0].G, p[1].G, u), Lerp(p[0].B, p[1].B, u));
            }
            double u2 = (x - 0.5) * 2;
            return Color.FromArgb(
                Lerp(p[1].R, p[2].R, u2), Lerp(p[1].G, p[2].G, u2), Lerp(p[1].B, p[2].B, u2));
        }

        private static int Lerp(int a, int b, double u)
        {
            return Clamp255(a + (b - a) * u);
        }

        /// <summary>特效场（0..1）。四种都是低频函数组合 —— 这正是能块状化的原因</summary>
        private static double Field(Style s, double u, double v, double t)
        {
            if (s == Style.Plasma)
            {
                double a = Math.Sin(u * 6.0 + t * 0.7);
                double b = Math.Sin(v * 8.0 - t * 0.5);
                double c = Math.Sin((u + v) * 5.0 + t * 0.9);
                double dx = u - 0.5, dy = v - 0.5;
                double d = Math.Sin(Math.Sqrt(dx * dx + dy * dy) * 14 - t * 1.1);
                return (a + b + c + d) / 8 + 0.5;
            }
            if (s == Style.Aurora)
            {
                double curtain = Math.Sin(u * 12 + Math.Sin(u * 3 + t * 0.4) * 2.2 + t * 0.6);
                double vert = 1 - v;
                double sway = Math.Sin(v * 4 - t * 0.8) * 0.15;
                return Math.Max(0, Math.Min(1, (curtain * 0.5 + 0.5) * 0.65 + vert * 0.35 + sway));
            }
            if (s == Style.Lava)
            {
                double blob = Math.Sin(u * 7 + t * 0.5) * Math.Sin(v * 5 - t * 0.7);
                double heat = Math.Pow(1 - v, 1.6);
                return Math.Max(0, Math.Min(1, heat * 0.75 + (blob * 0.5 + 0.5) * 0.35));
            }
            double band = Math.Sin(v * 14 + Math.Sin(u * 4 + t * 0.8) * 1.8 + t * 0.9);
            double slow = Math.Sin(u * 2.5 - t * 0.3) * 0.2;
            return Math.Max(0, Math.Min(1, band * 0.4 + 0.5 + slow));
        }

        /// <summary>
        /// 从磁盘载入图片背景。**找不到就静默跳过**（背景仍在，只是退回程序化特效）。
        ///
        /// 文件位置（按优先级，都可选）：
        ///   1. `&lt;exe目录&gt;/bg_sample.jpg`        ← 与 exe 同级（绿色版惯例）
        ///   2. `&lt;exe目录&gt;/assets/bg_sample.jpg` ← 本仓库的发布布局（见 win/assets/）
        ///   3. `&lt;exe目录&gt;/resources/bg_sample.jpg`
        ///   4. 当前工作目录下的同名文件
        ///
        /// ★ 图片来源：trofeo-lcd-rs 仓库的 `img/sample_background.jpg`（1920×1080），
        ///   居中裁成 1920×462 存为 22KB 的 JPEG。**不预压暗** —— 压暗交给 `DimPct`
        ///   （ArkTS 侧踩过"预压一次又叠一次 = 压两次，暗到看不见"的坑）。
        /// </summary>
        /// <summary>
        /// 在 exe 目录及其**向上最多 2 级父目录**里找一个文件。
        ///
        /// ★ 为什么需要向上找：本工程的构建脚本把 exe 输出到 `out\` 子目录
        ///   （`build.cmd` 的 `set OUT=%HERE%out`），而图片素材放在工程根目录。
        ///   用户也常把 exe 单独拷到别处。只找"exe 同级"会让**主题 7 与背景图模式看不到图**，
        ///   而失败是静默的（退回程序化配色），排查起来很费时间 —— 所以在源头堵掉。
        /// </summary>
        public static string FindNear(string exeDir, string fileName)
        {
            try
            {
                string dir = exeDir;
                for (int up = 0; up <= 2 && !string.IsNullOrEmpty(dir); up++)
                {
                    string[] sub = new string[] { "", "assets", "resources" };
                    for (int i = 0; i < sub.Length; i++)
                    {
                        string p = sub[i].Length == 0
                            ? System.IO.Path.Combine(dir, fileName)
                            : System.IO.Path.Combine(System.IO.Path.Combine(dir, sub[i]), fileName);
                        if (System.IO.File.Exists(p)) return p;
                    }
                    System.IO.DirectoryInfo parent = System.IO.Directory.GetParent(dir);
                    if (parent == null) break;
                    dir = parent.FullName;
                }
                string cwd = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), fileName);
                if (System.IO.File.Exists(cwd)) return cwd;
            }
            catch (Exception) { }
            return null;
        }

        public static bool LoadImageFrom(string exeDir)
        {
            try
            {
                string hit = FindNear(exeDir, "bg_sample.jpg");
                if (hit != null)
                {
                    // 用 FileStream 读，避免 Image.FromFile 长期占用文件句柄
                    using (System.IO.FileStream fs = new System.IO.FileStream(
                               hit, System.IO.FileMode.Open, System.IO.FileAccess.Read))
                    {
                        System.Drawing.Image img = System.Drawing.Image.FromStream(fs);
                        Bitmap bmp = new Bitmap(img);     // 脱离流，之后可安全关闭
                        img.Dispose();
                        Image = bmp;
                        return true;
                    }
                }
            }
            catch (Exception)
            {
                // 载入失败不致命：Background 会退回程序化特效
            }
            return false;
        }

        public static string StatusLine()
        {
            int i = (int)Current;
            string n = (i >= 0 && i < StyleNames.Length) ? StyleNames[i] : "?";
            if (Current == Style.None) return "背景 关";
            return string.Format("背景 {0} · 压暗 {1}%", n, (int)DimPct);
        }
    }

    /// <summary>
    /// 纯本机数据采集 —— 等价于 ArkTS `service/HostStats.ets`（**不经过数据桥**）。
    ///
    /// Windows 侧的采集能力比鸿蒙强（鸿蒙拿不到 GPU/温度/磁盘，见 HostStats.ets 的可用性表），
    /// 这里用 Win32 性能计数器与 WMI 补齐：CPU 占用、内存、网络速率、磁盘占用。
    /// </summary>
    public class HostSnapshot
    {
        public double CpuPct;
        public int Cores;
        public double MemUsedMB;
        public double MemTotalMB;
        public double BatteryPct = -1;
        public bool Charging;
        public double NetRxKBs;
        public double NetTxKBs;
        public double DiskUsedPct;
        public double DiskTotalGB;
        public bool Valid;
    }

    public static class HostStats
    {
        private static readonly HostSnapshot Snap = new HostSnapshot();
        private static long _lastMs;
        private static long _lastNetMs;
        private static long _lastRx = -1;
        private static long _lastTx = -1;
        private const int SampleMs = 2000;

        public static HostSnapshot Get(long now)
        {
            if (!Snap.Valid || now - _lastMs >= SampleMs)
            {
                Sample(now);
            }
            return Snap;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

        [DllImport("kernel32.dll")]
        private static extern void GetSystemTimes(out long idle, out long kernel, out long user);

        [DllImport("kernel32.dll")]
        private static extern uint GetTickCount();

        private static long _prevIdle, _prevKernel, _prevUser;

        private static void Sample(long now)
        {
            SampleCpu();
            SampleMem();
            SampleNet(now);
            SampleDisk();
            Snap.Valid = true;
            _lastMs = now;
        }

        private static void SampleCpu()
        {
            try
            {
                long idle, kernel, user;
                GetSystemTimes(out idle, out kernel, out user);
                if (_prevKernel != 0)
                {
                    long dIdle = idle - _prevIdle;
                    long dKernel = kernel - _prevKernel;
                    long dUser = user - _prevUser;
                    long total = dKernel + dUser;      // kernel 已含 idle
                    if (total > 0)
                    {
                        double busy = 1.0 - (double)dIdle / total;
                        Snap.CpuPct = Math.Max(0, Math.Min(100, busy * 100));
                    }
                }
                _prevIdle = idle; _prevKernel = kernel; _prevUser = user;
            }
            catch (Exception) { }
            if (Snap.Cores == 0) Snap.Cores = Environment.ProcessorCount;
        }

        private static void SampleMem()
        {
            try
            {
                MEMORYSTATUSEX m = new MEMORYSTATUSEX();
                m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
                if (GlobalMemoryStatusEx(ref m))
                {
                    Snap.MemTotalMB = m.ullTotalPhys / 1024.0 / 1024.0;
                    Snap.MemUsedMB = (m.ullTotalPhys - m.ullAvailPhys) / 1024.0 / 1024.0;
                }
            }
            catch (Exception) { }
        }

        /// <summary>网络速率：用 IP 全局统计接口的差值算 KB/s（对应 ArkTS 读 /proc/net/dev）</summary>
        private static void SampleNet(long now)
        {
            try
            {
                long rx, tx;
                if (!NetCounters.Read(out rx, out tx)) return;
                if (_lastRx >= 0 && now > _lastNetMs)
                {
                    double dtSec = (now - _lastNetMs) / 1000.0;
                    if (dtSec > 0.2)
                    {
                        Snap.NetRxKBs = Math.Max(0, (rx - _lastRx) / 1024.0 / dtSec);
                        Snap.NetTxKBs = Math.Max(0, (tx - _lastTx) / 1024.0 / dtSec);
                    }
                }
                _lastRx = rx; _lastTx = tx; _lastNetMs = now;
            }
            catch (Exception) { }
        }

        private static void SampleDisk()
        {
            try
            {
                System.IO.DriveInfo d = new System.IO.DriveInfo(System.IO.Path.GetPathRoot(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows)));
                if (d != null && d.IsReady && d.TotalSize > 0)
                {
                    Snap.DiskTotalGB = d.TotalSize / 1024.0 / 1024.0 / 1024.0;
                    double used = d.TotalSize - d.AvailableFreeSpace;
                    Snap.DiskUsedPct = used / d.TotalSize * 100.0;
                }
            }
            catch (Exception) { }
        }
    }

    /// <summary>
    /// 网络累计字节数（P/Invoke iphlpapi 的 GetIfTable）。
    /// 只统计"物理以太网/WiFi"接口，排除回环与隧道（与 ArkTS 侧排除 lo/dummy/vti 同义）。
    /// </summary>
    internal static class NetCounters
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct MIB_IFROW
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
            public char[] wszName;
            public uint dwIndex;
            public uint dwType;
            public uint dwMtu;
            public uint dwSpeed;
            public uint dwPhysAddrLen;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
            public byte[] bPhysAddr;
            public uint dwAdminStatus;
            public uint dwOperStatus;
            public uint dwLastChange;
            public uint dwInOctets;
            public uint dwInUcastPkts;
            public uint dwInNUcastPkts;
            public uint dwInDiscards;
            public uint dwInErrors;
            public uint dwInUnknownProtos;
            public uint dwOutOctets;
            public uint dwOutUcastPkts;
            public uint dwOutNUcastPkts;
            public uint dwOutDiscards;
            public uint dwOutErrors;
            public uint dwOutQLen;
            public uint dwDescrLen;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
            public char[] bDescr;
        }

        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetIfTable(IntPtr pIfTable, ref uint pdwSize, bool bOrder);

        // IF_TYPE 以太网=6，IEEE80211=71
        private const uint IF_TYPE_ETHERNET = 6;
        private const uint IF_TYPE_IEEE80211 = 71;

        public static bool Read(out long rx, out long tx)
        {
            rx = 0; tx = 0;
            try
            {
                uint size = 0;
                GetIfTable(IntPtr.Zero, ref size, false);
                if (size == 0) return false;
                IntPtr buf = Marshal.AllocHGlobal((int)size);
                try
                {
                    if (GetIfTable(buf, ref size, false) != 0) return false;
                    int rowSize = Marshal.SizeOf(typeof(MIB_IFROW));
                    int count = Marshal.ReadInt32(buf);              // 首 4 字节是表项数
                    IntPtr row = (IntPtr)((long)buf + 4);
                    for (int i = 0; i < count; i++)
                    {
                        MIB_IFROW r = (MIB_IFROW)Marshal.PtrToStructure(
                            (IntPtr)((long)row + i * rowSize), typeof(MIB_IFROW));
                        if (r.dwType == IF_TYPE_ETHERNET || r.dwType == IF_TYPE_IEEE80211)
                        {
                            rx += r.dwInOctets;
                            tx += r.dwOutOctets;
                        }
                    }
                    return count > 0;
                }
                finally
                {
                    Marshal.FreeHGlobal(buf);
                }
            }
            catch (Exception)
            {
                return false;
            }
        }
    }
}
