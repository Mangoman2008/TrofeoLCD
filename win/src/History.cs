/**
 * History.cs — 采样历史（C# 5 移植版）
 *
 * 逐值移植自 `entry/src/main/ets/common/History.ets`（122 行）。
 *
 * ## 为什么需要它
 * 主题 2「监控墙」与主题 3「分页屏」都画**趋势曲线**（CPU / 内存 / token 速率 / 余额），
 * 而曲线数据来自**应用侧自己的采样**（不是桥发的瞬时值）——
 * **C# 侧原先完全没有这个能力**，所以这两个主题没法移植。
 * 本文件把 `History` 补齐，是那两个主题的共同前置。
 *
 * ## 设计要点（照搬 ArkTS）
 *   · 4 条序列，容量 90 点（`CAP`）
 *   · CPU / 内存用**固定纵轴 100**；token 速率与余额用**动态纵轴**（量级不固定）
 *   · 「断点」用 **-1** 表示（比如桥断了），绘制时跳过该段
 *   · 采样间隔 2 秒（`SAMPLE_MS`）—— 每个 tick 都记会太快填满缓冲、也看不出走势
 *
 * ⚠️ C# 5 语言上限：无字符串插值、无 `?.`、无表达式体成员、无 `out var`、无元组。
 */
using System;
using System.Collections.Generic;

namespace DshLcd
{
    /// <summary>一条采样序列（定容环形缓冲）</summary>
    public class Series
    {
        private readonly List<double> _buf = new List<double>();
        private readonly int _cap;
        /// <summary>纵轴上限（固定值；-1 = 用动态最大值）</summary>
        public readonly double FixedMax;

        public Series(int cap, double fixedMax)
        {
            _cap = cap > 0 ? cap : 1;
            FixedMax = fixedMax;
        }

        public Series(int cap) : this(cap, -1) { }

        /// <summary>
        /// 追加一个采样值。
        ///
        /// ★ 与 ArkTS 侧的一处**有意差异**：ArkTS 的 `push()` 把负数一律转 0：
        ///     `const x = isFinite(v) && v >= 0 ? v : 0;`
        ///   而 `pushGap()` 是 `push(-1)` —— 于是**断点语义整个失效**（断点被记成 0），
        ///   绘制时"桥断了"会画成"跌到 0 并保持"（本仓库代码审查报告【中-14】已记录）。
        ///   C# 侧这里**保留 -1** 作为断点标记，让 `PointY()` 能真的断开折线。
        ///   正常数据路径（v >= 0）行为完全一致，不影响任何主题的既有观感。
        /// </summary>
        public void Push(double v)
        {
            double x;
            if (v == -1) x = -1;                                  // 断点标记，保留
            else if (IsFinite(v) && v >= 0) x = v;
            else x = 0;                                           // 其余异常值按 0（与 ArkTS 同）
            _buf.Add(x);
            while (_buf.Count > _cap) _buf.RemoveAt(0);
        }

        /// <summary>采一次"未知"值（比如桥断了）—— 用 -1 表示断点，绘制时跳过</summary>
        public void PushGap() { Push(-1); }

        public int Length { get { return _buf.Count; } }

        public double At(int i)
        {
            return (i >= 0 && i < _buf.Count) ? _buf[i] : -1;
        }

        public double Last()
        {
            return _buf.Count > 0 ? _buf[_buf.Count - 1] : -1;
        }

        /// <summary>有效样本的最大值，至少 1（避免除零）</summary>
        public double MaxValid()
        {
            double m = 0;
            for (int i = 0; i < _buf.Count; i++)
            {
                if (_buf[i] > m) m = _buf[i];
            }
            return m > 0 ? m : 1;
        }

        /// <summary>纵轴上限：固定上限优先（CPU/内存用 100），否则用动态最大值</summary>
        public double ScaleMax()
        {
            return FixedMax > 0 ? FixedMax : MaxValid();
        }

        /// <summary>
        /// 把第 i 个采样点映射成画布 y（i 从 0 = 最旧）。
        /// **断点（-1）返回 -1**，调用方负责断开折线。
        /// </summary>
        public double PointY(int i, double y0, double h, double max)
        {
            double v = At(i);
            if (v < 0) return -1;
            double m = max > 0 ? max : 1;
            double r = Math.Max(0, Math.Min(1, v / m));
            return y0 + h - h * r;
        }

        /// <summary>采样点 x 坐标（按容量铺满，不足时也从左往右画，不拉伸）</summary>
        public double PointX(int i, double x0, double w, int cap)
        {
            double c = cap > 1 ? cap : 2;
            return x0 + w * (i / (c - 1));
        }

        private static bool IsFinite(double v)
        {
            return !double.IsNaN(v) && !double.IsInfinity(v);
        }
    }

    /// <summary>屏上要画的 4 条曲线（都按固定的采样上限建环形缓冲）</summary>
    public class History
    {
        /// <summary>采样上限：每 2 秒一个点，容量 90 ≈ 保持最近 3 分钟走势</summary>
        public const int CAP = 90;
        /// <summary>采样间隔（毫秒）</summary>
        public const long SAMPLE_MS = 2000;

        public readonly Series Cpu = new Series(CAP, 100);
        public readonly Series Mem = new Series(CAP, 100);
        /// <summary>token 速率（每分钟），量级不固定 → 动态纵轴</summary>
        public readonly Series Tokens = new Series(CAP);
        /// <summary>余额曲线（动态纵轴，用来画"钱在往下掉"）</summary>
        public readonly Series Balance = new Series(CAP);

        private long _lastAt;

        /// <summary>
        /// 每个 tick 调一次；到采样间隔才真的记一笔。返回是否真的采样了。
        /// </summary>
        public bool Sample(long now, double cpuPct, double memPct,
                           double tokensPerMin, double balanceTotal)
        {
            if (_lastAt != 0 && now - _lastAt < SAMPLE_MS) return false;
            _lastAt = now;
            Cpu.Push(cpuPct);
            Mem.Push(memPct);
            if (tokensPerMin >= 0) Tokens.Push(tokensPerMin); else Tokens.PushGap();
            if (balanceTotal >= 0) Balance.Push(balanceTotal); else Balance.PushGap();
            return true;
        }
    }
}
