/**
 * ThemeFwSim.cs — 主题 6「固件仿真屏」（C# 5 移植版）
 *
 * 对齐 `entry/src/main/ets/render/ThemeFwSim.ets`（1033 行）。
 *
 * ## 目的
 * 把 **ESP32-S3 那版固件的 UI** 搬到 1920×462 上做仿真显示。
 * 固件本体不支持 1920×462（源码里 grep 1920 = 0），所以只能把它的 UI **逐条抄过来重画**。
 * UI 是程序化绘制（不是位图），因此可以做到像素级忠实。
 *
 * ## 摆放
 * 与主题 4「打砖块」**同一块区域** —— 逻辑 343×418、屏幕居中；
 * 固件设计画布 **368×448**（`env:ws_amoled_18`）→ ×0.9333 后在区内居中；
 * 两侧沿用打砖块那套信息栏。
 *
 * ## ★ 范围决定：**4 屏全保真 + 其余诚实占位**
 * 用户 2026-10-14 明确定过这块屏**只需要 4 个界面**：
 *   **打印中(6) / 表情(16) / 打砖块时钟(8) / 余额(17)**
 * ArkTS 侧 18 屏全实现了（1033 行），但其中 14 屏（启动/配网/OTA/分屏/相机/电源确认/
 * 烘干/错误详情…）在真机上是一次性或异常态的界面，日常根本看不到。
 * 所以 C# 侧：**这 4 屏逐值移植**；其余 14 屏画一个**诚实的占位**（界面名 + 中文标签 +
 * "该界面未移植"），**不留空白**（空白会被误判成渲染 bug），并在 `/diag` 的标签里区分。
 *
 * ## 配色（`config.h:72-92` 的 RGB565 → hex，一条条换算过来的，**别"改回原色"**）
 * 全部做过 JPEG 4:2:0 预补偿：纯绿被压一半、**纯青/纯蓝几乎归零**。
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Drawing;

namespace DshLcd
{
    /// <summary>固件仿真状态（对齐 ArkTS 的 `FwSimState`）</summary>
    public class FwSimState
    {
        public int Screen = 6;              // 默认"打印中"
        public int Hour, Minute, Second;
        public string DateText = "";
        // 打印机
        public string PrState = "";
        public string PrModel = "";
        public string PrJob = "";
        public int PrPct = -1;
        public double PrNozzle = -1, PrBed = -1, PrChamber = -1;
        public int PrLayer = -1, PrTotalLayer = -1;
        public int PrRemainMin = -1;
        public int PrTrays;
        // 余额
        public string BalTotal = "--", BalGranted = "--", BalTopped = "--";
        public string BalStatus = "离线";
        // 连接
        public string WifiText = "未配置";
        // 表情
        public int Expr;
        /// <summary>时钟屏是否叠打砖块（源 `dispSettings.pongClock`）</summary>
        public bool PongClock = true;
        // 打砖块时钟的实时状态（由主题 4 那套物理搬过来）
        public double PongBallX = -1, PongBallY = -1;
        public double PongPaddleX = 184;
        public bool[][] PongBricks;

        public static FwSimState FromState(State st, PongSnapshot snap)
        {
            FwSimState f = new FwSimState();
            DateTime d = DateTime.Now;
            f.Hour = d.Hour; f.Minute = d.Minute; f.Second = d.Second;
            string[] wk = new string[] { "日", "一", "二", "三", "四", "五", "六" };
            f.DateText = string.Format("{0}月{1}日 周{2}", d.Month, d.Day, wk[(int)d.DayOfWeek]);
            // 默认按 4 屏轮播（每 12 秒）；`/set?fws=N` 可定点覆盖到任意界面（含未移植的）
            f.Screen = FwSim.Rotation[(int)((State.NowMs() / 12000) % FwSim.Rotation.Length)];

            if (st != null && st.Data != null)
            {
                PrinterInfo p = st.Data.Printer;
                if (p != null)
                {
                    f.PrState = p.State == null ? "" : p.State;
                    f.PrModel = "Bambu Lab P2S";
                    f.PrJob = p.JobName == null ? "" : p.JobName;
                    f.PrPct = p.Percent;
                    f.PrNozzle = p.NozzleTemp;
                    f.PrBed = p.BedTemp;
                    f.PrChamber = p.ChamberTemp;
                    f.PrLayer = p.Layer;
                    f.PrTotalLayer = p.TotalLayer;
                    f.PrRemainMin = p.RemainingSec > 0 ? p.RemainingSec / 60 : -1;
                    f.PrTrays = (p.Trays == null) ? 0 : p.Trays.Count;
                }
                BalanceInfo b = st.Data.Balance;
                if (b != null)
                {
                    f.BalTotal = b.Total >= 0 ? b.Total.ToString("0.00") : "--";
                    f.BalGranted = b.Granted >= 0 ? b.Granted.ToString("0.00") : "--";
                    f.BalTopped = b.ToppedUp >= 0 ? b.ToppedUp.ToString("0.00") : "--";
                    if (!string.IsNullOrEmpty(b.Error)) f.BalStatus = "获取失败";
                    else if (b.Available.HasValue && !b.Available.Value) f.BalStatus = "不可用";
                    else if (b.Total >= 0) f.BalStatus = "可用";
                }
                f.Expr = DotiiState.FromState(st).Expr;
            }

            // 打砖块时钟的三个实时量从主题 4 的物理状态搬过来（与 ArkTS 同做法）
            if (snap != null)
            {
                f.PongBallX = snap.BallX;
                f.PongBallY = snap.BallY;
                f.PongPaddleX = snap.PaddleX;
                f.PongBricks = snap.Bricks;
            }
            return f;
        }
    }

    public static class FwSim
    {
        // ---- 坐标与缩放 ----
        public const int FW_W = 368;          // 固件设计画布宽
        public const int FW_H = 448;          // 固件设计画布高
        public const double FW_SCALE = 0.9333;
        public const double AREA_W = 343;
        public const double AREA_H = 418;
        public static readonly double AREA_X = Math.Round((1920 - AREA_W) / 2);
        public static readonly double AREA_Y = Math.Round((462 - AREA_H) / 2);
        public static readonly double UI_X = AREA_X + (AREA_W - FW_W * FW_SCALE) / 2;
        public static readonly double UI_Y = AREA_Y + (AREA_H - FW_H * FW_SCALE) / 2;
        public const double PANEL_W = 758;

        // ---- 配色（config.h:72-92 的 RGB565 → hex，均已 4:2:0 预补偿）----
        public static readonly Color Bg = Color.FromArgb(0x00, 0x00, 0x00);
        public static readonly Color Card = Color.FromArgb(0x1E, 0x2A, 0x38);
        public static readonly Color Header = Color.FromArgb(0x18, 0x1C, 0x18);
        public static readonly Color Text = Color.FromArgb(0xFF, 0xFF, 0xFF);
        public static readonly Color Dim = Color.FromArgb(0xC5, 0xC2, 0xC5);
        public static readonly Color DarkTxt = Color.FromArgb(0x7B, 0x7D, 0x7B);
        public static readonly Color Green = Color.FromArgb(0x20, 0xE0, 0x20);
        public static readonly Color Orange = Color.FromArgb(0xF0, 0x88, 0x18);
        public static readonly Color Red = Color.FromArgb(0xF0, 0x10, 0x10);
        public static readonly Color Yellow = Color.FromArgb(0xF0, 0xE8, 0x28);
        public static readonly Color Gold = Color.FromArgb(0xF0, 0xCC, 0x20);
        public static readonly Color Track = Color.FromArgb(0x20, 0x26, 0x1F);
        public static readonly Color Cyan = Color.FromArgb(0x30, 0xD8, 0xE0);

        /// <summary>18 个界面（`display_ui.h:12-30` 的 enum 顺序，一字不差）</summary>
        public static readonly string[] Screens = new string[]
        {
            "splash", "ap_mode", "connecting_wifi", "wifi_connected", "connecting_mqtt",
            "idle", "printing", "finished", "clock", "off", "ota_update", "split",
            "camera", "power_confirm", "dry_peek", "hms", "face", "balance"
        };
        public static readonly string[] ScreenLabels = new string[]
        {
            "启动画面", "配网热点", "连接 WiFi", "WiFi 已连", "连接 MQTT",
            "空闲", "打印中", "完成", "时钟·打砖块", "息屏", "OTA 升级", "双机分屏",
            "相机画面", "电源确认", "烘干查看", "错误详情", "表情", "余额"
        };
        public const int ScreenCount = 18;

        /// <summary>用户指定的 4 个轮播界面（原始枚举号）</summary>
        public static readonly int[] Rotation = new int[] { 6, 16, 8, 17 };
        public static readonly string[] RotationLabels = new string[]
        { "打印中", "表情", "打砖块时钟", "余额" };

        /// <summary>打砖块砖色（`clock_pong.cpp:93-99`，与主题 4 同一套 4:2:0 预补偿值）</summary>
        public static readonly Color[] BrickColors = new Color[]
        {
            Color.FromArgb(0xF0, 0x10, 0x10), Color.FromArgb(0xF0, 0xA0, 0x18),
            Color.FromArgb(0xF0, 0xE8, 0x28), Color.FromArgb(0x20, 0xE0, 0x20),
            Color.FromArgb(0x3A, 0x55, 0xE0),
        };

        /// <summary>该界面是否已移植（供 `/diag` 与左栏如实标注）</summary>
        public static bool IsPorted(int screen)
        {
            return screen == 6 || screen == 8 || screen == 16 || screen == 17;
        }

        public static string RotationLabel(int screen)
        {
            for (int i = 0; i < Rotation.Length; i++)
            {
                if (Rotation[i] == screen) return RotationLabels[i];
            }
            int s = ((screen % ScreenCount) + ScreenCount) % ScreenCount;
            return ScreenLabels[s] + "（非轮播）";
        }

        private static string RotationPos(int screen)
        {
            for (int i = 0; i < Rotation.Length; i++)
            {
                if (Rotation[i] == screen) return (i + 1).ToString();
            }
            return "-";
        }

        // ==================================================================
        // 渲染
        // ==================================================================

        /// <summary>应用 `/set?fws=N` 的定点覆盖（-1 = 不动，按轮播）</summary>
        public static void ApplyOverride(FwSimState st, int over)
        {
            if (over < 0) return;
            st.Screen = ((over % ScreenCount) + ScreenCount) % ScreenCount;
        }

        public static void Render(Graphics g, FwSimState st, long nowMs)
        {
            Draw.FillRect(g, 0, 0, 1920, 462, Color.Black);
            LeftPanel(g, st);
            RightPanel(g, st);

            // 仿真窗口外框（与打砖块同一块区域，一眼看出是"屏中屏"）
            using (Pen p = new Pen(Color.FromArgb(0x26, 0x2A, 0x3A), 2))
            {
                g.DrawRectangle(p, (float)(UI_X - 8), (float)(UI_Y - 6),
                                (float)(FW_W * FW_SCALE + 16), (float)(FW_H * FW_SCALE + 12));
            }

            // ---- 固件 UI：一次缩放变换，之后所有坐标都按固件的 368×448 写 ----
            System.Drawing.Drawing2D.GraphicsState gs = g.Save();
            try
            {
                g.TranslateTransform((float)UI_X, (float)UI_Y);
                g.ScaleTransform((float)FW_SCALE, (float)FW_SCALE);

                // 固件每屏都是整屏黑底起手（CLR_BG）
                Draw.FillRect(g, 0, 0, FW_W, FW_H, Bg);

                int s = ((st.Screen % ScreenCount) + ScreenCount) % ScreenCount;
                switch (s)
                {
                    case 6: Printing(g, st); break;
                    case 8: Clock(g, st, nowMs); break;
                    case 16: Face(g, st, nowMs); break;
                    case 17: Balance(g, st); break;
                    default: Placeholder(g, s); break;
                }
            }
            finally
            {
                g.Restore(gs);
            }
        }

        // ======================= 固件界面（逐条照抄） =======================

        /// <summary>
        /// 时钟屏（`clock_mode.cpp:387 drawClock`）。
        /// 时间 HH:MM 居中（字模基准 32×48 + 冒号 12），下方日期，底部信息行。
        /// </summary>
        private static void Clock(Graphics g, FwSimState st, long nowMs)
        {
            // 源 clock_mode.cpp:38-56：SCREEN_W>=320 → autoSizeIndex=2 → scale 1.5（Medium）
            const double scale = 1.5;
            double digitW = Math.Floor(32 * scale);      // 48
            double digitH = Math.Floor(48 * scale);      // 72
            double colonW = Math.Floor(12 * scale);      // 18
            double blockW = 4 * digitW + colonW;         // 210
            double timeX0 = (FW_W - blockW) / 2;         // 79
            const double dateH = 24;
            const double gap = 14;
            double contentH = digitH + gap + dateH;
            double timeY = (FW_H - contentH) / 2;

            // 源 display_ui.cpp:6192-6194：SCREEN_CLOCK 时先 drawClock()，
            // 若 dispSettings.pongClock 为真则另外叠上砖块/球/挡板
            if (st.PongClock) ClockPong(g, st);

            string hh = Pad2(st.Hour);
            string mm = Pad2(st.Minute);
            bool colonOn = (nowMs % 1000) < 500;
            string[] glyphs = new string[]
            { hh.Substring(0, 1), hh.Substring(1, 1), ":", mm.Substring(0, 1), mm.Substring(1, 1) };

            // 数码字：步进严格等于 digitW（源是 7 段字模，这里用等宽粗体贴出同尺寸格子）
            const double baseSize = 96;
            Font probe = F.MonoFont(baseSize, true);
            double adv = Draw.Measure(g, "0", probe);
            double fit = adv > 0 ? Math.Floor(baseSize * digitW / adv) : baseSize;
            Font tf = F.MonoFont(fit, true);

            for (int i = 0; i < 5; i++)
            {
                double x;
                if (i == 0) x = timeX0;
                else if (i == 1) x = timeX0 + digitW;
                else if (i == 2) x = timeX0 + 2 * digitW;
                else x = timeX0 + 2 * digitW + colonW + (i - 3) * digitW;
                if (i == 2)
                {
                    if (colonOn)
                    {
                        double cw = Math.Max(6, Math.Floor(colonW * 0.45));
                        Draw.FillRect(g, x + (colonW - cw) / 2, timeY + Math.Floor(digitH * 0.18), cw, cw, Text);
                        Draw.FillRect(g, x + (colonW - cw) / 2, timeY + Math.Floor(digitH * 0.62), cw, cw, Text);
                    }
                    continue;
                }
                Draw.Text(g, glyphs[i], x, timeY + digitH / 2, tf, Text, Draw.TextAlign.Left);
            }

            // 日期（源居中在时间下方 gap 处）
            if (st.DateText != null && st.DateText.Length > 0)
            {
                Font df = F.SansFont(36, true);
                Draw.Text(g, st.DateText, FW_W / 2, timeY + digitH + gap + dateH / 2, df,
                          Dim, Draw.TextAlign.Center);
            }
            // 底部信息行（源 drawClockInfo：底边距 4）
            if (st.WifiText != null && st.WifiText.Length > 0)
            {
                Font wf = F.SansFont(28, true);
                Draw.Text(g, Draw.Fit(g, st.WifiText, wf, FW_W - 6), FW_W / 2, FW_H - 22, wf,
                          DarkTxt, Draw.TextAlign.Center);
            }
        }

        /// <summary>
        /// 打砖块时钟叠层（`clock_pong.cpp` 的配色与几何，版式按 368 档）。
        /// 与主题 4 **共用同一套物理常量**，区别只是这里数字更大（48×72 格）。
        /// </summary>
        private static void ClockPong(Graphics g, FwSimState st)
        {
            const int BrickRows = 5, BrickCols = 9;
            const int BrickW = 36, BrickH = 17, Gap = 2;
            const int StartX = 5, StartY = 40;
            const int PaddleY = 430, PaddleW = 72, PaddleH = 5, Ball = 20;

            bool[][] live = st.PongBricks;
            for (int r = 0; r < BrickRows; r++)
            {
                for (int c = 0; c < BrickCols; c++)
                {
                    bool alive = (live == null || live.Length <= r || live[r] == null
                                  || live[r].Length <= c) ? true : live[r][c];
                    if (!alive) continue;
                    double x = StartX + c * (BrickW + Gap);
                    double y = StartY + r * (BrickH + Gap);
                    Draw.FillRect(g, x, y, BrickW, BrickH, BrickColors[r % BrickColors.Length]);
                    Draw.FillRect(g, x, y, BrickW, 1, Color.White);
                    Draw.FillRect(g, x, y + BrickH - 1, BrickW, 1, Color.Black);
                }
            }
            // 球（源 drawBall：白色实心圆）
            if (st.PongBallX >= 0)
            {
                Draw.FillCircle(g, st.PongBallX + Ball / 2.0, st.PongBallY + Ball / 2.0,
                                Ball / 2.0, Color.White);
            }
            // 挡板（源 drawPaddle）。⚠️ 固件原值是纯青 #00FFFF，4:2:0 后几乎归零 → 用补偿值
            double px = Math.Round(st.PongPaddleX - PaddleW / 2.0);
            Draw.FillRect(g, px, PaddleY, PaddleW, PaddleH, Cyan);
            Draw.FillRect(g, px, PaddleY, PaddleW, 1, Color.White);
        }

        /// <summary>
        /// 打印中（`display_ui.cpp:6151 SCREEN_PRINTING`）。
        /// 版式（`layout_368x448.h`）：名字 y=42、状态徽标 y=72 高 28、
        /// 环内大百分比居中、ETA 区 y=362（文字 383）、文件名 y=410、底栏 y=424 高 24。
        /// </summary>
        private static void Printing(Graphics g, FwSimState st)
        {
            int pct = st.PrPct >= 0 ? st.PrPct : 0;
            Font nameFont = F.SansFont(34, true);
            Draw.Text(g, Draw.Fit(g, (st.PrModel != null && st.PrModel.Length > 0) ? st.PrModel
                      : "Bambu Lab P2S", nameFont, FW_W - 20),
                      FW_W / 2, 42, nameFont, Text, Draw.TextAlign.Center);

            string badge = st.PrState == "PAUSE" ? "已暂停"
                         : (st.PrState == "RUNNING" ? "打印中" : "空闲");
            Color badgeClr = st.PrState == "PAUSE" ? Yellow
                           : (st.PrState == "RUNNING" ? Green : DarkTxt);
            Font bf = F.SansFont(30, true);
            double bw = Draw.Measure(g, badge, bf) + 30;
            Draw.FillRound(g, (FW_W - bw) / 2, 72, bw, 28, 14, badgeClr);
            Draw.Text(g, badge, FW_W / 2, 86, bf, Bg, Draw.TextAlign.Center);

            // 中央进度环
            double cx = FW_W / 2, cy = 218, r = 96;
            using (Pen p = new Pen(Track, 16))
            {
                g.DrawArc(p, (float)(cx - r), (float)(cy - r), (float)(r * 2), (float)(r * 2), -90, 360);
            }
            if (pct > 0)
            {
                using (Pen p = new Pen(pct >= 95 ? Gold : Green, 16))
                {
                    g.DrawArc(p, (float)(cx - r), (float)(cy - r), (float)(r * 2), (float)(r * 2),
                              -90, (float)(360.0 * Math.Min(100, pct) / 100));
                }
            }
            Font pf = F.MonoFont(76, true);
            Draw.Text(g, pct.ToString(), cx - 18, cy - 6, pf, Text, Draw.TextAlign.Center);
            Font pcf = F.MonoFont(34, true);
            Draw.Text(g, "%", cx + 56, cy - 16, pcf, Dim, Draw.TextAlign.Center);

            // ETA 区（y=362，文字 383）：层数 + 剩余
            Font lf = F.MonoFont(28, true);
            string layer = st.PrLayer >= 0
                ? "层 " + st.PrLayer.ToString() + (st.PrTotalLayer > 0 ? "/" + st.PrTotalLayer.ToString() : "")
                : "层 --";
            Draw.Text(g, layer, 16, 383, lf, Dim, Draw.TextAlign.Left);
            Draw.Text(g, st.PrRemainMin >= 0 ? "剩 " + Hhmm2(st.PrRemainMin) : "剩 --",
                      FW_W - 16, 383, lf, Dim, Draw.TextAlign.Right);

            // 文件名（y=410，居中，两侧留 8）
            Font jf = F.SansFont(26, true);
            Draw.Text(g, Draw.Fit(g, (st.PrJob != null && st.PrJob.Length > 0) ? st.PrJob : "（无作业）",
                      jf, FW_W - 16), FW_W / 2, 410, jf, Text, Draw.TextAlign.Center);

            // 底栏（y=424 高 24）：左 WiFi、右 AMS 盘数
            Draw.FillRect(g, 0, 424, FW_W, 24, Header);
            Font bf2 = F.SansFont(22, true);
            Draw.Text(g, st.WifiText, 6, 436, bf2, Dim, Draw.TextAlign.Left);
            Draw.Text(g, "AMS " + st.PrTrays.ToString(), FW_W - 8, 436, bf2, Dim, Draw.TextAlign.Right);
        }

        /// <summary>表情屏（源部件表以 288 单位制给出，368 档 k≈1.28）</summary>
        private static void Face(Graphics g, FwSimState st, long nowMs)
        {
            double k = FW_W / 288.0;
            int p = (int)((nowMs % 2600) / 325) % 8;
            int ping = p < 4 ? p : 8 - p;
            double cx = FW_W / 2.0, cy = FW_H / 2.0;
            Color warm = Color.FromArgb(0xF4, 0xEA, 0xD2);

            int expr = ((st.Expr % 6) + 6) % 6;
            double eh = (p == 2 || p == 3) ? 7 : ((p == 1 || p == 4) ? 24 : 66);
            switch (expr)
            {
                case 0:   // idle_breath
                    Part(g, cx, cy, k, 52, 72 + ping * 3, -78, -30, warm);
                    Part(g, cx, cy, k, 52, 72 + ping * 3, 78, -30, warm);
                    Part(g, cx, cy, k, 56, 12, 0, 70, warm);
                    break;
                case 1:   // blink
                    Part(g, cx, cy, k, 58, eh, -78, -26, warm);
                    Part(g, cx, cy, k, 58, eh, 78, -26, warm);
                    Part(g, cx, cy, k, 56, 12, 0, 70, warm);
                    break;
                case 2:   // curious
                    Part(g, cx, cy, k, 62, 82, -76, -34, warm);
                    Part(g, cx, cy, k, 46, 62, 82, -26, warm);
                    Part(g, cx, cy, k, 20 + ping, 20 + ping, 8, 70, Color.FromArgb(0xF2, 0xC6, 0x6D));
                    break;
                case 3:   // sleepy_yawn
                    Part(g, cx, cy, k, 68, 10, -76, -18, warm);
                    Part(g, cx, cy, k, 68, 10, 76, -18, warm);
                    Part(g, cx, cy, k, 26 + ping * 3, 26 + ping * 3, 0, 72, Color.FromArgb(0xF2, 0xC6, 0x6D));
                    break;
                case 4:   // connecting
                    Part(g, cx, cy, k, 48, 64, -76, -28, Color.FromArgb(0x58, 0xC8, 0xC8));
                    Part(g, cx, cy, k, 48, 64, 76, -28, Color.FromArgb(0x58, 0xC8, 0xC8));
                    Part(g, cx, cy, k, 56, 12, 0, 70, warm);
                    break;
                default:  // working
                    Part(g, cx, cy, k, 48, 68, -86 + ping * 4, -30, warm);
                    Part(g, cx, cy, k, 48, 68, 70 + ping * 4, -30, warm);
                    Part(g, cx, cy, k, 62, 10, 0, 72, Color.FromArgb(0x58, 0xC8, 0xC8));
                    break;
            }
        }

        private static void Part(Graphics g, double cx, double cy, double k,
                                 double w, double h, double x, double y, Color c)
        {
            double W = w * 1.2 * k;
            double H = h * 1.2 * k;
            if (W <= 0 || H <= 0) return;
            Draw.FillRound(g, cx + x * 1.2 * k - W / 2, cy + y * 1.2 * k - H / 2,
                           W, H, Math.Min(W, H) / 2, c);
        }

        /// <summary>余额屏</summary>
        private static void Balance(Graphics g, FwSimState st)
        {
            Font tf = F.SansFont(32, true);
            Draw.Text(g, "DeepSeek 余额", FW_W / 2, 92, tf, Text, Draw.TextAlign.Center);
            Font vf = F.MonoFont(86, true);
            Draw.Text(g, st.BalTotal, FW_W / 2, 200, vf, Green, Draw.TextAlign.Center);
            Font sf = F.SansFont(26, true);
            Draw.Text(g, "赠送 " + st.BalGranted + " · 充值 " + st.BalTopped,
                      FW_W / 2, 272, sf, Dim, Draw.TextAlign.Center);

            // 状态徽标
            Color clr = st.BalStatus == "可用" ? Green
                      : (st.BalStatus == "预览数据" ? Yellow : DarkTxt);
            Font bf = F.SansFont(28, true);
            double w = Draw.Measure(g, st.BalStatus, bf) + 34;
            Draw.FillRound(g, (FW_W - w) / 2, 312, w, 40, 20, clr);
            Draw.Text(g, st.BalStatus, FW_W / 2, 332, bf, Bg, Draw.TextAlign.Center);

            Font nf = F.SansFont(22, true);
            Draw.Text(g, "几分钟前更新", FW_W / 2, 386, nf, DarkTxt, Draw.TextAlign.Center);
                   // sf 只在这里释放一次（第一版在状态徽标后又释放了一次 → use-after-dispose）
        }

        /// <summary>
        /// 未移植界面的**诚实占位**：画出界面名 + 中文标签 + 明确说明。
        /// 不留空白 —— 空白会被误判成渲染 bug（本仓库踩过这个坑）。
        /// </summary>
        private static void Placeholder(Graphics g, int screen)
        {
            int s = ((screen % ScreenCount) + ScreenCount) % ScreenCount;
            Font tf = F.SansFont(40, true);
            Draw.Text(g, ScreenLabels[s], FW_W / 2, FW_H / 2 - 40, tf, Dim, Draw.TextAlign.Center);
            Font nf = F.MonoFont(26, false);
            Draw.Text(g, Screens[s], FW_W / 2, FW_H / 2 + 10, nf, DarkTxt, Draw.TextAlign.Center);
            Font hf = F.SansFont(22, false);
            Draw.Text(g, "该界面未移植到 Windows 版", FW_W / 2, FW_H / 2 + 56, hf, DarkTxt,
                      Draw.TextAlign.Center);
            Draw.Text(g, "已移植：打印中 / 表情 / 打砖块时钟 / 余额", FW_W / 2, FW_H / 2 + 90, hf,
                      DarkTxt, Draw.TextAlign.Center);
        }

        // ======================= 两侧信息栏 =======================

        private static void PanelBox(Graphics g, double x, double y, double w, double h, Color accent)
        {
            Draw.FillRound(g, x, y, w, h, 14, C.Panel);
            Draw.StrokeRound(g, x + 0.5, y + 0.5, w - 1, h - 1, 14, C.Border, 1);
            Draw.FillRound(g, x + 16, y + 1, w - 32, 3, 1.5,
                           Color.FromArgb((int)(0.8 * 255), accent));
        }

        private static void StatRow(Graphics g, double x, double w, double y,
                                    string label, string value, Color color)
        {
            Font lf = F.SansFont(24, false);
            Font vf = F.MonoFont(26, true);
            Draw.Text(g, label, x, y, lf, Color.FromArgb(0x8C, 0x94, 0xA8), Draw.TextAlign.Left);
            Draw.Text(g, Draw.Fit(g, value, vf, w / 2), x + w, y, vf, color, Draw.TextAlign.Right);

        }

        private static void LeftPanel(Graphics g, FwSimState st)
        {
            double x = 14, y = 14, w = PANEL_W, h = 462 - 28;
            PanelBox(g, x, y, w, h, Cyan);
            Font tf = F.SansFont(40, true);
            Draw.Text(g, "固件仿真屏", x + 34, y + 44, tf, Cyan, Draw.TextAlign.Left);
            Font sf = F.SansFont(26, true);
            Draw.Text(g, "ESP32-S3 固件 UI · 按源码 1:1 抄绘", x + 34, y + 84, sf,
                      Color.FromArgb(0x8C, 0x94, 0xA8), Draw.TextAlign.Left);

            double inner = x + 34, innerW = w - 68;
            // ★ 与 ArkTS 的一处**有意差异**：本版只移植了 4 屏，所以这里如实标注
            //   "已移植 4/18"，而不是照抄"18 个界面"的说法（否则是误导）。
            string[][] rows = new string[][]
            {
                new string[]{"当前界面", RotationLabel(st.Screen)},
                new string[]{"轮播", RotationPos(st.Screen) + "/4 · 每 12 秒"},
                new string[]{"已移植", "4/18（其余为诚实占位）"},
                new string[]{"设计画布", FW_W + "×" + FW_H + " → ×" + FW_SCALE.ToString("0.####")},
                new string[]{"数据源", "本机遥测（打印机/余额）"},
            };
            double ry = y + 150;
            for (int i = 0; i < rows.Length; i++)
            {
                StatRow(g, inner, innerW, ry, rows[i][0], rows[i][1],
                        Color.FromArgb(0xE6, 0xEB, 0xF5));
                ry += 52;
            }
            Font nf = F.SansFont(26, true);
            Draw.Text(g, "来源：备份-阶段-20261009-0046/源码", inner, y + h - 30, nf,
                      Color.FromArgb(0x64, 0x6C, 0x82), Draw.TextAlign.Left);
        }

        private static void RightPanel(Graphics g, FwSimState st)
        {
            double x = 1920 - 14 - PANEL_W, y = 14, w = PANEL_W, h = 462 - 28;
            PanelBox(g, x, y, w, h, Color.FromArgb(0x00, 0xAE, 0x42));
            Font tf = F.SansFont(40, true);
            Draw.Text(g, "固件实时数据", x + 34, y + 44, tf,
                      Color.FromArgb(0x34, 0xD3, 0x99), Draw.TextAlign.Left);
            Font sf = F.SansFont(26, true);
            Draw.Text(g, "下面这些值就是固件那些屏在显示的东西", x + 34, y + 84, sf,
                      Color.FromArgb(0x8C, 0x94, 0xA8), Draw.TextAlign.Left);

            double inner = x + 34, innerW = w - 68;
            string[][] rows = new string[][]
            {
                new string[]{"打印机状态", st.PrState.Length > 0 ? st.PrState : "--"},
                new string[]{"进度 / 层", (st.PrPct >= 0 ? st.PrPct + "%" : "--") + " · "
                    + (st.PrLayer >= 0 ? st.PrLayer.ToString() : "--") + "/"
                    + (st.PrTotalLayer > 0 ? st.PrTotalLayer.ToString() : "--")},
                new string[]{"喷嘴 / 热床", (st.PrNozzle >= 0 ? st.PrNozzle.ToString("0") + "°" : "--")
                    + " / " + (st.PrBed >= 0 ? st.PrBed.ToString("0") + "°" : "--")},
                new string[]{"剩余", st.PrRemainMin >= 0 ? Hhmm2(st.PrRemainMin) : "--"},
                new string[]{"DeepSeek 余额", st.BalTotal + "（" + st.BalStatus + "）"},
                new string[]{"连接", st.WifiText},
            };
            double ry = y + 150;
            for (int i = 0; i < rows.Length; i++)
            {
                StatRow(g, inner, innerW, ry, rows[i][0], rows[i][1],
                        Color.FromArgb(0xE6, 0xEB, 0xF5));
                ry += 46;
            }
            Font nf = F.SansFont(24, true);
            Draw.Text(g, "切换界面：/set?fws=N（0..17）", inner, y + h - 30, nf,
                      Color.FromArgb(0x64, 0x6C, 0x82), Draw.TextAlign.Left);
        }

        // ---------------- 小工具 ----------------

        private static string Pad2(int n) { return (n < 10 ? "0" : "") + n.ToString(); }

        /// <summary>分钟数 → `HhMMm`（源 hhmm2）</summary>
        private static string Hhmm2(int min)
        {
            if (min < 0) return "--";
            return (min / 60).ToString() + "h" + (min % 60).ToString("00") + "m";
        }
    }
}
