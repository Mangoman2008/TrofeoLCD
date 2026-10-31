/**
 * ThemeTrcc.cs — 主题 7「官方浅色风」（C# 5 移植版）
 *
 * 逐值移植自 `entry/src/main/ets/render/ThemeTrcc.ets`（208 行）。
 * 复刻 Thermalright 官方 `theme1920462.7z` 里那套 1920×462 浅色主题。
 *
 * ## 官方设计（从 `Theme.png` 识图量出的像素坐标）
 * ```
 *  ┌───────────┐                              ┌───────────┐
 *  │ 左卡       │        17:03（≈100px）       │ 右卡       │
 *  │ (140,50)  │        中心 (960,133)         │ (1420,50) │
 *  │ 355×360   │   星期六 2025/05/17（居中）    │ 355×360   │
 *  └───────────┘                              └───────────┘
 * ```
 * 圆角 ≈20px、柔和投影；**浅色底 + 纯文字排版，没有圆环/曲线** ——
 * 与本项目其它主题（深色霓虹 + 环形）风格正好相反。
 *
 * ## 5 套配色是**闭环**轮换
 * `#96FFA8`（薄荷绿）· `#EEF7A3`（淡黄绿）· `#FF9855`（橙）· `#FF7070`（珊瑚）· `#4BE6E9`（青）
 * **每套的背景色 = 上一套的卡片色**（`cardColor(idx) = COLORS[(idx+1)%5]`）。
 *
 * ## 官方素材是两层（ArkTS 侧实测的结论）
 *   `00.png` = 纯背景色（整幅不透明）
 *   `01.png` = 卡片叠加层（背景透明 + 卡片/投影）
 * 工程里存的是 `01.png`（卡片层）。所以**先铺官方背景色、再叠卡片层**，
 * 就得到与官方完全一致的合成结果。本版同法。
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Drawing;

namespace DshLcd
{
    /// <summary>TRCC 主题状态（由帧循环每帧填真实数据）</summary>
    public class TrccState
    {
        /// <summary>配色索引 0..4；-1 = 自动轮换（30 秒一套）</summary>
        public int Palette = -1;
        public int Hour;
        public int Minute;
        public string DateText = "";
        // 左卡：CPU
        public double CpuTemp = -1;
        public double CpuLoadPct = -1;
        public double CpuFreqMhz = -1;
        // 右卡：第二项指标（这台机器没有独立 GPU，用 DeepSeek token 速率顶上）
        public string GpuLabel = "GPU";
        public double GpuTemp = -1;
        public double GpuLoadPct = -1;
        public double GpuFreqMhz = -1;
        public double Scale = 1.0;
    }

    public static class ThemeTrcc
    {
        /// <summary>官方 5 套配色（下表是"背景色"，卡片色取下一位 —— 闭环）</summary>
        public static readonly Color[] Colors = new Color[]
        {
            Color.FromArgb(0x96, 0xFF, 0xA8),   // 薄荷绿
            Color.FromArgb(0xEE, 0xF7, 0xA3),   // 淡黄绿
            Color.FromArgb(0xFF, 0x98, 0x55),   // 橙
            Color.FromArgb(0xFF, 0x70, 0x70),   // 珊瑚
            Color.FromArgb(0x4B, 0xE6, 0xE9),   // 青
        };
        public const int ThemeCount = 5;

        // 版面（像素，取自官方 Theme.png 的量测值）
        private const double CardXL = 140;
        private const double CardXR = 1420;
        private const double CardY = 50;
        private const double CardW = 355;
        private const double CardH = 360;
        private const double CardR = 20;
        private const double ClockCY = 133;
        private const double ClockSize = 100;
        private const double DateCY = 232;
        private const double RowTitle = 96;
        private const double RowMain = 205;
        private const double RowSub = 315;

        /// <summary>官方卡片层图（5 套，1920×462 RGBA）。由帧循环启动时载入</summary>
        public static readonly Bitmap[] CardLayers = new Bitmap[ThemeCount];

        /// <summary>当前套的卡片色（闭环：卡片色 = 下一套的背景色）</summary>
        public static Color CardColor(int idx)
        {
            int n = ThemeCount;
            return Colors[((idx + 1) % n + n) % n];
        }

        /// <summary>从磁盘载入 5 张官方卡片层图（找不到就退回自绘卡片，不报错）</summary>
        public static int LoadCardLayers(string exeDir)
        {
            int ok = 0;
            for (int i = 0; i < ThemeCount; i++)
            {
                if (CardLayers[i] != null) { ok++; continue; }
                string hit = Backdrop.FindNear(exeDir, "trcc_official_" + (i + 1).ToString() + ".png");
                if (hit != null)
                {
                    try
                    {
                        // 用 FileStream 读并脱离流，避免长期占用文件句柄
                        using (System.IO.FileStream fs = new System.IO.FileStream(
                                   hit, System.IO.FileMode.Open, System.IO.FileAccess.Read))
                        {
                            Image img = Image.FromStream(fs);
                            CardLayers[i] = new Bitmap(img);
                            img.Dispose();
                            ok++;
                        }
                    }
                    catch (Exception) { }
                }
            }
            return ok;
        }

        public static void Render(Graphics g, TrccState st)
        {
            int n = ThemeCount;
            int idx = ((st.Palette % n) + n) % n;
            Color bg = Colors[idx];
            Color card = CardColor(idx);
            double s = st.Scale > 0 ? st.Scale : 1;

            Bitmap layer = (idx >= 0 && idx < CardLayers.Length) ? CardLayers[idx] : null;
            Draw.FillRect(g, 0, 0, 1920, 462, bg);       // 先铺官方背景色
            if (layer != null)
            {
                g.DrawImage(layer, 0, 0, 1920, 462);     // 再叠卡片层（自带透明度）
            }
            else
            {
                // 底图没载入（或载入失败）时的兜底：按官方配色自绘卡片
                CardShadow(g, CardXL, CardY, CardW, CardH, CardR);
                CardShadow(g, CardXR, CardY, CardW, CardH, CardR);
                Draw.FillRound(g, CardXL, CardY, CardW, CardH, CardR, card);
                Draw.FillRound(g, CardXR, CardY, CardW, CardH, CardR, card);
            }

            // 卡片内文字：官方卡片上是**接近纯黑的深色**（用灰会显得虚、与官方差距明显）
            Color ink = Color.FromArgb(0x10, 0x10, 0x10);
            // 每行都传**拼好的字符串**，避免"温度"和"速率"共用一套单位拼法
            CardText(g, CardXL, CardW, "CPU",
                st.CpuTemp >= 0 ? st.CpuTemp.ToString("0") + "°C" : "--",
                st.CpuLoadPct >= 0 ? st.CpuLoadPct.ToString("0") + "%" : "--",
                st.CpuFreqMhz > 0 ? ((long)st.CpuFreqMhz).ToString() + "MHz" : "--", ink);
            CardText(g, CardXR, CardW, st.GpuLabel,
                st.GpuTemp >= 0 ? st.GpuTemp.ToString("0") + "/min" : "--",
                st.GpuLoadPct >= 0 ? "今日 " + ((long)st.GpuLoadPct).ToString() : "",
                st.GpuFreqMhz > 0 ? ((long)st.GpuFreqMhz).ToString() + "MHz" : "--", ink);

            // 居中大时间（官方 ≈100px、中心 y=133）+ 日期行
            // 官方大时间是**灰色 #808080**（这个是对的，别改成黑）
            Font cf = F.SansFont(Math.Round(ClockSize * s), true);
            Draw.Text(g, Pad2(st.Hour) + ":" + Pad2(st.Minute), 960, ClockCY * s,
                      cf, Color.FromArgb(0x80, 0x80, 0x80), Draw.TextAlign.Center);
            if (st.DateText != null && st.DateText.Length > 0)
            {
                Font df = F.SansFont(Math.Round(34 * s), true);
                Draw.Text(g, st.DateText, 960, DateCY * s, df,
                          Color.FromArgb(0x4A, 0x4A, 0x4A), Draw.TextAlign.Center);
            }
        }

        /// <summary>卡片内三行文字：标题 / 主数值（两个数并排）/ 次数值</summary>
        private static void CardText(Graphics g, double x, double w, string title,
                                     string main1, string main2, string sub, Color ink)
        {
            // 字号按官方原图量测：标题≈80px、主数值≈100px、次数值≈80px
            Font f80 = F.SansFont(80, true);
            Draw.Text(g, title, x + w / 2, RowTitle, f80, ink, Draw.TextAlign.Center);

            // ★ 主数值那一行是**两个数并排**（官方：`50℃  1%`）。两串字各自量宽、
            //   按总宽居中排，而不是写死 ±62/+78 的偏移 —— 写死会在数字变长时压在一起
            //   （ArkTS 侧实测 `50°C` 与 `1%` 叠了 28%），也会在只显示一个值时偏到一边。
            Font f100 = F.SansFont(100, true);
            if (main2 != null && main2.Length > 0)
            {
                double w1 = Draw.Measure(g, main1, f100);
                double w2 = Draw.Measure(g, main2, f100);
                const double gap = 30;
                double total = w1 + w2 + gap;
                double cx = x + w / 2 - total / 2;
                Draw.Text(g, main1, cx, RowMain, f100, ink, Draw.TextAlign.Left);
                Draw.Text(g, main2, cx + w1 + gap, RowMain, f100, ink, Draw.TextAlign.Left);
            }
            else
            {
                Draw.Text(g, main1, x + w / 2, RowMain, f100, ink, Draw.TextAlign.Center);
            }
            Draw.Text(g, sub, x + w / 2, RowSub, f80, ink, Draw.TextAlign.Center);

        }

        /// <summary>柔和投影：在卡片位置偏移几像素画几层低透明深色（近似模糊）</summary>
        private static void CardShadow(Graphics g, double x, double y,
                                       double w, double h, double r)
        {
            for (int i = 3; i >= 1; i--)
            {
                Draw.FillRound(g, x + i, y + i + 2, w, h, r,
                               Color.FromArgb((int)(0.06 * i * 255), 0, 0, 0));
            }
        }

        private static string Pad2(int v)
        {
            return (v < 10 ? "0" : "") + v.ToString();
        }
    }
}
