/**
 * ThemePong.cs — 主题 4「打砖块」（C# 5 移植版）
 *
 * 逐值移植自 `entry/src/main/ets/render/ThemePong.ets`（712 行）。
 * 来源是**源固件 `clock_pong.cpp` 的 1:1 复刻**：
 *   · 物理、绘制顺序、砖色照抄 `clock_pong.cpp`
 *   · 版面常量照抄 `layout_368x448.h`（`BOARD_IS_AMOLED18` 档）
 *
 * ## 关键设计：**渲染是纯函数 + 确定性随机**
 * `rand` 是自己实现的 **LCG**（Numerical Recipes 参数），不用 `Math.Random` ——
 * 所以同一份 state 重复推进逐像素一致，可以离线跑几千帧做断言。
 * C# 侧同样如此（`System.Random` **一次都没用**）。
 *
 * ## 版面
 * 源画布 368×448 → 本屏取 ×0.9333 = 343×418，居中（两侧各 758px 信息栏）：
 *   左栏：战况（得分/连击/击碎/回球/剩余/推帧）+ **砖块存活小地图**
 *   右栏：移植参数（球速/球径/砖块/周期/已运行）+ **砖色图例**
 *
 * ## JPEG 4:2:0 预补偿（照抄，别"改回原色"）
 * 源固件砖色是纯 RGB565（`#FF0000`/`#FFA500`/`#FFFF00`/`#00FF00`/`#0000FF`），
 * 但本机编码器是 4:2:0 色度抽样 —— 实测**纯蓝解码后几乎归零**、纯绿掉一半。
 * 所以用**与 `ThemeFwSim` 同一套补偿值**，否则同一种玩法在两个主题里颜色不一致。
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Drawing;

namespace DshLcd
{
    /// <summary>打砖块游戏状态（对齐 ArkTS 的 `PongState`）</summary>
    public class PongState
    {
        public int Tick;
        /// <summary>确定性随机种子（LCG 状态）</summary>
        public long Rand = 12345;
        /// <summary>砖块存活表 [row][col]</summary>
        public bool[][] Bricks = new bool[ThemePong.BrickRows][];
        public double BallX, BallY, BallVX, BallVY;
        public bool BallActive;
        public bool Stuck;
        public double StickyHit = 0.5;
        public int StickyUntilTick;
        public double PaddleX = ThemePong.CanvasW / 2.0;
        public int Misses;
        // 左栏战况
        public int BricksBroken;
        public int PaddleHits;
        public int BestCombo;
        /// <summary>当前连击（碰挡板清零，砸砖 +1）</summary>
        public int Combo;
        /// <summary>重开次数（空挡 20 次或砖清空）</summary>
        public int Resets;
        // 展示用时间
        public int Hour, Minute, Second;
        public string DateText = "";
    }

    public static class ThemePong
    {
        // ---- 源版面常量（layout_368x448.h:410-427，AMOLED18 档）----
        public const int CanvasW = 368;
        public const int CanvasH = 448;
        public const int BrickRows = 5;
        public const int BrickCols = 9;
        public const int BrickW = 36;
        public const int BrickH = 17;
        public const int BrickGap = 2;
        public const int BrickStartX = 5;
        public const int BrickStartY = 40;
        public const int PaddleW = 72;
        public const int TimeY = 204;
        public const int DateY = 10;
        public const int DigitW = 44;
        public const int DigitH = 68;
        public const int ColonW = 16;
        /// <summary>地板/挡板 Y（源 430；430+5=435 ≤ 448，够用）</summary>
        public const int PaddleY = 430;

        // ---- 玩法常量（clock_pong.cpp:36-80）----
        public const int BallSize = 20;
        public const int PaddleH = 5;
        public const double BallSpeed = 12.0;
        public const int PaddleSpeed = 14;
        public const int TickMs = 20;              // ≈50fps
        public const double PaddleJitterDeg = 4.0;
        public const double StickyJitterDeg = 10.0;
        public const int StickyMs = 120;
        public const int StickyTrigger = 4;
        public const int ResetAfterMisses = 20;

        /// <summary>
        /// 砖色（`clock_pong.cpp:93-99`，行序 红/橙/黄/绿/蓝），**已做 4:2:0 预补偿**。
        /// 固件原值 → 补偿后：红 `#F01010` / 橙 `#F0A018` / 黄 `#F0E828` / 绿 `#20E020` / 蓝 `#3A55E0`
        /// </summary>
        public static readonly Color[] BrickColors = new Color[]
        {
            Color.FromArgb(0xF0, 0x10, 0x10),
            Color.FromArgb(0xF0, 0xA0, 0x18),
            Color.FromArgb(0xF0, 0xE8, 0x28),
            Color.FromArgb(0x20, 0xE0, 0x20),
            Color.FromArgb(0x3A, 0x55, 0xE0),
        };

        /// <summary>时间总宽 = 4×44 + 16 = 192（`clock_pong.cpp:32`）</summary>
        public const int TimeTotalW = 4 * DigitW + ColonW;

        // ---- 缩放与偏移 ----
        // 用户 2026-10-14 定「保留源尺寸 + 两侧信息栏」（方案 B），
        // 但纯 1:1（0.5369）时游戏只占屏宽 10.3%、两侧栏各 831px，中间那块太小。
        // 折中取 0.9333：游戏区 343×418（占屏宽 17.9%），两侧栏各 758，三栏站得住，
        // 而 0.9333 仍接近 1:1（砖块 33.6px、球 ⌀18.7），源版面比例一点没变。
        public const double Scale = 0.9333;
        public const double DrawW = CanvasW * Scale;   // 343.5
        public const double DrawH = CanvasH * Scale;   // 418.1
        public const double M = 14;
        public const double PanelW = 758;

        public static int Ox() { return (int)Math.Round((1920 - DrawW) / 2); }
        public static int Oy() { return (int)Math.Round((462 - DrawH) / 2); }

        // ==================================================================
        // 确定性随机（LCG，Numerical Recipes 参数）—— 不用 System.Random
        // ==================================================================

        private static double Rnd(PongState st)
        {
            st.Rand = (st.Rand * 1664525 + 1013904223) % 4294967296L;
            return st.Rand / 4294967296.0;
        }

        /// <summary>等价 Arduino `random(max)`：[0, max) 整数</summary>
        private static int RandInt(PongState st, int max)
        {
            if (max <= 0) return 0;
            return (int)(Math.Floor(Rnd(st) * max)) % max;
        }

        /// <summary>等价 Arduino `random(min, max)`：[min, max) 整数</summary>
        private static int RandRange(PongState st, int min, int max)
        {
            return min + RandInt(st, max - min);
        }

        private static double Clamp(double v, double lo, double hi)
        {
            return v < lo ? lo : (v > hi ? hi : v);
        }

        // ==================================================================
        // 状态构建与推进
        // ==================================================================

        /// <summary>新建一局（源 `initBricks()` + `spawnBall()`）</summary>
        public static PongState Init(double seed)
        {
            PongState st = new PongState();
            st.Rand = (Math.Abs((long)Math.Floor(seed)) % 4294967295L) + 1;
            st.Tick = 0;
            st.PaddleX = CanvasW / 2.0;
            st.Misses = 0;
            for (int r = 0; r < BrickRows; r++)
            {
                st.Bricks[r] = new bool[BrickCols];
                for (int c = 0; c < BrickCols; c++) st.Bricks[r][c] = true;
            }
            SpawnBall(st);
            return st;
        }

        private static void ResetBricks(PongState st)
        {
            for (int r = 0; r < BrickRows; r++)
                for (int c = 0; c < BrickCols; c++)
                    st.Bricks[r][c] = true;
        }

        /// <summary>从挡板发射（源 `launchBallFromPaddle`）</summary>
        private static void Launch(PongState st, double hit, double jitterDeg)
        {
            double h = Clamp(hit, 0.08, 0.92);
            st.BallX = st.PaddleX - PaddleW / 2.0 + h * PaddleW - BallSize / 2.0;
            st.BallY = PaddleY - BallSize;

            double angleDeg = 150.0 - h * 120.0 + jitterDeg;
            angleDeg = Clamp(angleDeg, 30.0, 150.0);
            double angle = angleDeg * Math.PI / 180.0;

            st.BallVX = BallSpeed * Math.Cos(angle);
            st.BallVY = -BallSpeed * Math.Sin(angle);
            if (Math.Abs(st.BallVX) < 1.2) st.BallVX = st.BallVX >= 0 ? 1.2 : -1.2;
            if (Math.Abs(st.BallVY) < 1.0) st.BallVY = -1.5;
            st.BallActive = true;
            st.Stuck = false;
            st.StickyUntilTick = 0;
        }

        /// <summary>中点 + ±5° 随机重发（源 `spawnBall`）</summary>
        private static void SpawnBall(PongState st)
        {
            st.Stuck = false;
            st.StickyUntilTick = 0;
            Launch(st, 0.5, RandRange(st, -50, 51) / 10.0);
            st.Misses = 0;
        }

        /// <summary>连击容错：粘球辅助（源 `shouldUseStickyAssist`）</summary>
        private static bool UseSticky(PongState st)
        {
            if (st.Misses < StickyTrigger) return false;
            int chance = 15 + (st.Misses - StickyTrigger) * 10;
            if (chance > 70) chance = 70;
            return RandInt(st, 100) < chance;
        }

        /// <summary>把球粘到挡板上（源 `stickBallToPaddle`）</summary>
        private static void Stick(PongState st, double hit)
        {
            double off = RandRange(st, -18, 19) / 100.0;
            st.StickyHit = Clamp(hit + off, 0.18, 0.82);
            st.Stuck = true;
            st.StickyUntilTick = st.Tick + (int)Math.Round(StickyMs / (double)TickMs);
            st.BallActive = true;
            st.BallVX = 0;
            st.BallVY = 0;
            st.BallX = st.PaddleX - PaddleW / 2.0 + st.StickyHit * PaddleW - BallSize / 2.0;
            st.BallY = PaddleY - BallSize;
        }

        /// <summary>砖块碰撞（源 `checkBrickCollision`）</summary>
        private static bool CheckBricks(PongState st)
        {
            double bx = Math.Floor(st.BallX);
            double by = Math.Floor(st.BallY);
            bool hitX = false, hitY = false, hit = false;
            for (int r = 0; r < BrickRows; r++)
            {
                for (int c = 0; c < BrickCols; c++)
                {
                    if (!st.Bricks[r][c]) continue;
                    double rx = BrickStartX + c * (BrickW + BrickGap);
                    double ry = BrickStartY + r * (BrickH + BrickGap);
                    if (bx + BallSize > rx && bx < rx + BrickW
                        && by + BallSize > ry && by < ry + BrickH)
                    {
                        st.Bricks[r][c] = false;
                        st.BricksBroken++;
                        st.Combo++;
                        if (st.Combo > st.BestCombo) st.BestCombo = st.Combo;
                        double oL = (bx + BallSize) - rx;
                        double oR = (rx + BrickW) - bx;
                        double oT = (by + BallSize) - ry;
                        double oB = (ry + BrickH) - by;
                        if (Math.Min(oL, oR) < Math.Min(oT, oB)) hitX = true;
                        else hitY = true;
                        hit = true;
                    }
                }
            }
            if (hitX) st.BallVX = -st.BallVX;
            if (hitY) st.BallVY = -st.BallVY;
            if (hit)
            {
                // 把球推出砖区，避免下一帧重复碰撞（源 468-472）
                st.BallX += st.BallVX;
                st.BallY += st.BallVY;
                st.Misses = 0;
            }
            return hit;
        }

        public static int BricksLeft(PongState st)
        {
            int n = 0;
            for (int r = 0; r < BrickRows; r++)
                for (int c = 0; c < BrickCols; c++)
                    if (st.Bricks[r][c]) n++;
            return n;
        }

        /// <summary>挡板追踪（源 `updatePaddle`）</summary>
        private static void UpdatePaddle(PongState st)
        {
            if (st.Stuck) return;
            double target;
            if (st.BallActive && st.BallVY > 0) target = Math.Floor(st.BallX + BallSize / 2.0);
            else target = Math.Floor(CanvasW / 2.0);
            double diff = target - st.PaddleX;
            if (Math.Abs(diff) > 2)
            {
                double step = Math.Min(PaddleSpeed, Math.Abs(diff));
                st.PaddleX += diff > 0 ? step : -step;
            }
            st.PaddleX = Clamp(st.PaddleX, PaddleW / 2.0, CanvasW - PaddleW / 2.0);
        }

        /// <summary>球的物理（源 `updateBallPhysics`）</summary>
        private static void UpdateBall(PongState st)
        {
            if (!st.BallActive) return;
            if (st.Stuck)
            {
                st.BallX = st.PaddleX - PaddleW / 2.0 + st.StickyHit * PaddleW - BallSize / 2.0;
                st.BallY = PaddleY - BallSize;
                if (st.Tick >= st.StickyUntilTick)
                {
                    int lim = (int)Math.Round(StickyJitterDeg * 10);
                    double jitter = RandRange(st, -lim, lim + 1) / 10.0;
                    Launch(st, st.StickyHit, jitter);
                }
                return;
            }

            st.BallX += st.BallVX;
            st.BallY += st.BallVY;

            if (st.BallX <= 0) { st.BallX = 0; st.BallVX = Math.Abs(st.BallVX); }
            if (st.BallX >= CanvasW - BallSize)
            {
                st.BallX = CanvasW - BallSize;
                st.BallVX = -Math.Abs(st.BallVX);
            }
            if (st.BallY <= 0) { st.BallY = 0; st.BallVY = Math.Abs(st.BallVY); }

            // 挡板碰撞
            if (st.BallVY > 0 && st.BallY + BallSize >= PaddleY && st.BallY < PaddleY + PaddleH)
            {
                double pL = st.PaddleX - PaddleW / 2.0;
                double pR = st.PaddleX + PaddleW / 2.0;
                if (st.BallX + BallSize >= pL && st.BallX <= pR)
                {
                    double hit = (st.BallX + BallSize / 2.0 - pL) / PaddleW;
                    st.Misses++;
                    st.PaddleHits++;
                    st.Combo = 0;
                    if (UseSticky(st))
                    {
                        Stick(st, hit);
                    }
                    else
                    {
                        int lim = (int)Math.Round(PaddleJitterDeg * 10);
                        double jitter = RandRange(st, -lim, lim + 1) / 10.0;
                        Launch(st, hit, jitter);
                    }
                    if (st.Misses >= ResetAfterMisses)
                    {
                        st.Misses = 0;
                        st.Resets++;
                        ResetBricks(st);
                    }
                }
            }

            if (st.BallY > CanvasH) SpawnBall(st);
            CheckBricks(st);
            if (BricksLeft(st) <= 0)
            {
                st.Resets++;
                ResetBricks(st);
            }
        }

        /// <summary>推进一个 tick（≈20ms）</summary>
        public static void Tick1(PongState st)
        {
            st.Tick++;
            UpdateBall(st);
            UpdatePaddle(st);
        }

        /// <summary>
        /// 按真实经过时间推进（帧循环每帧调一次）。
        /// 单帧最多补 8 个 tick（160ms），**防止卡顿后球瞬移穿过砖块**。
        /// </summary>
        public static void Advance(PongState st, double dtMs)
        {
            int need = (int)Math.Min(Math.Floor(dtMs / TickMs), 8);
            for (int i = 0; i < need; i++) Tick1(st);
        }

        // ==================================================================
        // 渲染
        // ==================================================================

        /// <summary>数字 x 坐标（源 `digitX`）</summary>
        private static double DigitX(int i)
        {
            double startX = (CanvasW - TimeTotalW) / 2.0;
            if (i < 2) return startX + i * DigitW;
            if (i == 2) return startX + 2 * DigitW;
            return startX + 2 * DigitW + ColonW + (i - 3) * DigitW;
        }

        public static void Render(Graphics g, PongState st, double fps, double renderMs)
        {
            int X = Ox(), Y = Oy();

            // 整屏底：与源一致（黑）
            Draw.FillRect(g, 0, 0, 1920, 462, Color.Black);

            LeftPanel(g, st, fps, renderMs);
            RightPanel(g, st);

            // 游戏区外框（让中间那块"是个窗口"而不是浮在黑里）
            using (Pen p = new Pen(Color.FromArgb(0x26, 0x2A, 0x3A), 2))
            {
                g.DrawRectangle(p, (float)(X - 8), (float)(Y - 6),
                                (float)(DrawW + 16), (float)(DrawH + 12));
            }

            // 游戏本身用**一次缩放变换**画：源坐标（368×448）→ 游戏区（343×418）。
            // 变换只在这里生效，所以下面的绘制代码与源固件一一对应，不必逐点乘系数。
            // 用 Save/Restore（与 ThemeMac / ThemeCyber 一致）而不是手动读写 g.Transform ——
            // 后者要求 GDI+ 返回内部矩阵的副本，语义上更脆。
            System.Drawing.Drawing2D.GraphicsState gs = g.Save();
            try
            {
                g.TranslateTransform(X, Y);
                g.ScaleTransform((float)Scale, (float)Scale);

                // ---------- 砖块（源 drawAllBricks / drawBrick）----------
                for (int r = 0; r < BrickRows; r++)
                {
                    for (int c = 0; c < BrickCols; c++)
                    {
                        if (!st.Bricks[r][c]) continue;
                        double x = BrickStartX + c * (BrickW + BrickGap);
                        double y = BrickStartY + r * (BrickH + BrickGap);
                        Draw.FillRect(g, x, y, BrickW, BrickH, BrickColors[r % BrickColors.Length]);
                        // 顶边 1px 白、底边 1px 黑（源的立体感）
                        Draw.FillRect(g, x, y, BrickW, 1, Color.White);
                        Draw.FillRect(g, x, y + BrickH - 1, BrickW, 1, Color.Black);
                    }
                }

                // ---------- 球（源 drawBall：白色实心圆 ⌀20）----------
                if (st.BallActive)
                {
                    Draw.FillCircle(g, st.BallX + BallSize / 2.0, st.BallY + BallSize / 2.0,
                                    BallSize / 2.0, Color.White);
                }

                // ---------- 挡板（源 drawPaddle）----------
                // ⚠️ JPEG 4:2:0 预补偿：固件原值是纯青 #00FFFF，实测解码后青/绿几乎归零
                //    （本仓库主题 6/7 都记过这条）→ 用补偿值 #30D8E0，否则挡板会"看不见"。
                double px = Math.Round(st.PaddleX - PaddleW / 2.0);
                Draw.FillRect(g, px, PaddleY, PaddleW, PaddleH, Color.FromArgb(0x30, 0xD8, 0xE0));
                Draw.FillRect(g, px, PaddleY, PaddleW, 1, Color.White);

                // ---------- 日期（源：居中，Font 2）----------
                if (st.DateText != null && st.DateText.Length > 0)
                {
                    Font df = F.MonoFont(20, false);
                    Draw.Text(g, st.DateText, CanvasW / 2.0, DateY + 8, df,
                              Color.FromArgb(0xE6, 0xED, 0xF3), Draw.TextAlign.Center);
                }

                // ---------- 时间（源 drawTime：数码字，冒号闪）----------
                bool showColon = (State.NowMs() % 1000) < 500;
                string hh = Pad2(st.Hour);
                string ampm = "";
                // C# 侧沿用 24 小时制（ArkTS 的 is24h 由配置传入，C# 无此开关）
                string mm = Pad2(st.Minute);
                string[] digits = new string[]
                { hh.Substring(0, 1), hh.Substring(1, 1), showColon ? ":" : " ", mm.Substring(0, 1), mm.Substring(1, 1) };

                // 比例缩放：让每个字符的**步进宽度正好等于 DigitW**，
                // 这样数字既占满源版面格子（44px），又绝不会互相压字。
                const double baseSize = 92;
                Font probe = F.MonoFont(baseSize, true);
                double adv = Draw.Measure(g, "0", probe);
                double fitSize = adv > 0 ? Math.Floor(baseSize * DigitW / adv) : baseSize;
                Font tf = F.MonoFont(fitSize, true);

                for (int i = 0; i < 5; i++)
                {
                    double x = DigitX(i);
                    if (i == 2)
                    {
                        // 冒号：居中方块，省掉字体依赖
                        if (showColon)
                        {
                            Draw.FillRect(g, x + 4, TimeY + 14, 8, 8, Color.White);
                            Draw.FillRect(g, x + 4, TimeY + 44, 8, 8, Color.White);
                        }
                        continue;
                    }
                    // 左对齐 + 步进宽度卡死 → 数码字落在源版面格子里
                    Draw.Text(g, digits[i], x, TimeY + DigitH / 2.0, tf, Color.White, Draw.TextAlign.Left);
                }

                if (ampm.Length > 0)
                {
                    Font af = F.MonoFont(20, false);
                    Draw.Text(g, ampm, DigitX(4) + DigitW + 4, TimeY + DigitH - 12, af,
                              Color.FromArgb(0x8E, 0x9B, 0x97), Draw.TextAlign.Left);
                }
            }
            finally
            {
                g.Restore(gs);
            }
        }

        // -----------------------------------------------------------------
        //  两侧信息栏
        // -----------------------------------------------------------------

        /// <summary>一张栏底（圆角 + 描边 + 顶部强调条）</summary>
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
            Font lf = F.SansFont(22, false);
            Font vf = F.MonoFont(32, true);
            Draw.Text(g, label, x, y, lf, Color.FromArgb(0x8C, 0x94, 0xA8), Draw.TextAlign.Left);
            Draw.Text(g, value, x + w, y, vf, color, Draw.TextAlign.Right);

        }

        /// <summary>左栏：战况 + 砖块存活小地图</summary>
        private static void LeftPanel(Graphics g, PongState st, double fps, double renderMs)
        {
            double x = M, y = M, w = PanelW, h = 462 - M * 2;
            PanelBox(g, x, y, w, h, Color.FromArgb(0x22, 0xD3, 0xEE));

            Font tf = F.SansFont(30, true);
            Draw.Text(g, "打砖块", x + 34, y + 40, tf, Color.FromArgb(0x22, 0xD3, 0xEE), Draw.TextAlign.Left);
            Font sf = F.SansFont(20, false);
            string sub = (st.DateText != null && st.DateText.Length > 0)
                ? st.DateText + " · 源固件 clock_pong 复刻 368×448"
                : "源固件 clock_pong 复刻 · 368×448";
            Draw.Text(g, sub, x + 34, y + 68, sf, Color.FromArgb(0x8C, 0x94, 0xA8), Draw.TextAlign.Left);

            double inner = x + 34, innerW = w - 68;
            int score = st.BricksBroken * 12 + st.BestCombo * 5;
            StatRow(g, inner, innerW, y + 122, "得分", score.ToString(),
                    Color.FromArgb(0xE6, 0xEB, 0xF5));
            StatRow(g, inner, innerW, y + 166, "连击 / 最高",
                    st.Combo.ToString() + " / " + st.BestCombo.ToString(),
                    Color.FromArgb(0xFB, 0xBF, 0x24));
            StatRow(g, inner, innerW, y + 210, "击碎砖块", st.BricksBroken.ToString(),
                    Color.FromArgb(0x34, 0xD3, 0x99));
            StatRow(g, inner, innerW, y + 254, "回球次数", st.PaddleHits.ToString(),
                    Color.FromArgb(0xE6, 0xEB, 0xF5));
            StatRow(g, inner, innerW, y + 298, "剩余砖块",
                    BricksLeft(st).ToString() + "/" + (BrickRows * BrickCols).ToString(),
                    Color.FromArgb(0x8C, 0x94, 0xA8));
            StatRow(g, inner, innerW, y + 342, "推帧 / 渲染",
                    fps.ToString("0.0") + "fps / " + renderMs.ToString("0") + "ms",
                    fps >= 20 ? Color.FromArgb(0x34, 0xD3, 0x99) : Color.FromArgb(0xFB, 0xBF, 0x24));

            // 砖块小地图（源 9×5 的存活表，一眼看出打掉哪些）
            Draw.Text(g, "砖块存活图", inner, y + 392, sf,
                      Color.FromArgb(0x64, 0x6C, 0x82), Draw.TextAlign.Left);
            double mw = innerW / BrickCols;
            const double mh = 14;
            double my = y + 410;
            for (int r = 0; r < BrickRows; r++)
            {
                for (int c = 0; c < BrickCols; c++)
                {
                    Color bc = st.Bricks[r][c] ? BrickColors[r % BrickColors.Length]
                                               : Color.FromArgb(0x1E, 0x22, 0x30);
                    Draw.FillRect(g, inner + c * mw + 1, my + r * (mh + 4), mw - 2, mh, bc);
                }
            }
        }

        /// <summary>右栏：源参数 + 砖色图例</summary>
        private static void RightPanel(Graphics g, PongState st)
        {
            double x = 1920 - M - PanelW, y = M, w = PanelW, h = 462 - M * 2;
            PanelBox(g, x, y, w, h, Color.FromArgb(0x00, 0xAE, 0x42));

            Font tf = F.SansFont(30, true);
            Draw.Text(g, "移植参数", x + 34, y + 40, tf, Color.FromArgb(0x34, 0xD3, 0x99), Draw.TextAlign.Left);
            Font sf = F.SansFont(20, false);
            Draw.Text(g, "所有数字取自源文件，未改设计", x + 34, y + 68, sf,
                      Color.FromArgb(0x8C, 0x94, 0xA8), Draw.TextAlign.Left);

            double inner = x + 34, innerW = w - 68;
            Color white = Color.FromArgb(0xE6, 0xEB, 0xF5);
            Color grey = Color.FromArgb(0x8C, 0x94, 0xA8);
            StatRow(g, inner, innerW, y + 122, "球速 / 挡板",
                    BallSpeed.ToString("0.#") + " / " + PaddleSpeed.ToString(), white);
            StatRow(g, inner, innerW, y + 166, "球径 / 挡板厚",
                    BallSize.ToString() + " / " + PaddleH.ToString(), white);
            StatRow(g, inner, innerW, y + 210, "砖块 / 间距",
                    BrickW.ToString() + "×" + BrickH.ToString() + " / " + BrickGap.ToString(), white);
            StatRow(g, inner, innerW, y + 254, "砖块阵列",
                    BrickCols.ToString() + "×" + BrickRows.ToString(), white);
            StatRow(g, inner, innerW, y + 298, "物理周期",
                    TickMs.ToString() + "ms（" + (int)Math.Round(1000.0 / TickMs) + "Hz）", white);
            StatRow(g, inner, innerW, y + 342, "已运行 / 重开",
                    (st.Tick * TickMs / 1000).ToString() + "s / " + st.Resets.ToString(), grey);

            // 砖色图例（5 行对应 5 行砖）
            Draw.Text(g, "砖色 · 行序", inner, y + 392, sf, Color.FromArgb(0x64, 0x6C, 0x82),
                      Draw.TextAlign.Left);
            double ly = y + 424;
            double cellW = innerW / BrickRows;
            for (int r = 0; r < BrickRows; r++)
            {
                double cx = inner + r * cellW;
                Draw.FillRect(g, cx, ly - 9, 26, 18, BrickColors[r % BrickColors.Length]);
                Draw.Text(g, (r + 1).ToString(), cx + 34, ly, sf, grey, Draw.TextAlign.Left);
            }
        }

        public static string Pad2(int n) { return (n < 10 ? "0" : "") + n.ToString(); }
    }
}
