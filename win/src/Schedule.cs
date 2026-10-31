using System;

namespace DshLcd
{
    /// <summary>
    /// 帧调度与重试策略 —— 与鸿蒙版 service/SchedulePolicy.ets 一一对应。
    /// 这些判断决定"画面会不会动"，所以参数必须两边一致。
    /// </summary>
    public static class Schedule
    {
        public const int IntervalBusy = 66;     // ~15fps
        public const int IntervalIdle = 500;    // 2fps
        public const int IntervalNight = 3000;  // 夜间只维持心跳
        public const int IntervalError = 1000;
        public const int UsbRetryMs = 5000;
        public const int UsbMaxDenied = 2;

        public class NightWindow
        {
            public int StartMin;
            public int EndMin;

            public NightWindow(int startHour, int startMinute, int endHour, int endMinute)
            {
                StartMin = startHour * 60 + startMinute;
                EndMin = endHour * 60 + endMinute;
            }

            /// <summary>是否在窗口内（支持跨午夜，如 18:30 → 09:00）</summary>
            public bool Contains(int minuteOfDay)
            {
                if (StartMin == EndMin) return false;
                if (StartMin < EndMin) return minuteOfDay >= StartMin && minuteOfDay < EndMin;
                return minuteOfDay >= StartMin || minuteOfDay < EndMin;
            }
        }

        public class FrameTickInput
        {
            public string StateStr = "unknown";
            public bool Night;
            public bool Errored;
        }

        public static int NextFrameInterval(FrameTickInput inp)
        {
            if (inp.Night) return IntervalNight;
            if (inp.Errored) return IntervalError;
            if (inp.StateStr == "busy" || inp.StateStr == "waiting") return IntervalBusy;
            return IntervalIdle;
        }

        public class UsbAttemptState
        {
            public int Denied;
            public bool Auto = true;
            public long LastAttemptMs;
        }

        public class UsbAttemptDecision
        {
            public bool Attempt;
            public string Reason = "";
            public bool NeedsManual;
        }

        public static UsbAttemptDecision ShouldAttemptUsbOpen(UsbAttemptState st, long nowMs, bool isOpen)
        {
            UsbAttemptDecision d = new UsbAttemptDecision();
            if (isOpen) { d.Reason = "already open"; return d; }
            if (!st.Auto) { d.Reason = "auto retry disabled"; d.NeedsManual = true; return d; }
            if (nowMs - st.LastAttemptMs < UsbRetryMs) { d.Reason = "backoff"; return d; }
            d.Attempt = true;
            d.Reason = "due";
            return d;
        }

        public static void NoteOpenFailure(UsbAttemptState st, bool denied, long nowMs)
        {
            st.LastAttemptMs = nowMs;
            if (denied)
            {
                st.Denied++;
                if (st.Denied >= UsbMaxDenied) st.Auto = false;
            }
        }

        public static void NoteOpenSuccess(UsbAttemptState st)
        {
            st.Denied = 0;
            st.Auto = true;
        }

        /// <summary>调度策略自检（与鸿蒙版 SelfTest.ets 的对应用例同构）</summary>
        public static int RunTests(Action<string, bool, string> check, Action<string, long, long> eq)
        {
            int fails = 0;
            try
            {
                NightWindow w = new NightWindow(18, 30, 9, 0);
                check("夜间窗口 18:30→09:00 含 20:00", w.Contains(20 * 60), "");
                check("夜间窗口含 00:30（跨午夜）", w.Contains(30), "");
                check("夜间窗口含 08:59", w.Contains(8 * 60 + 59), "");
                check("夜间窗口不含 09:00", !w.Contains(9 * 60), "");
                check("夜间窗口不含 12:00", !w.Contains(12 * 60), "");
                check("夜间窗口不含 18:29", !w.Contains(18 * 60 + 29), "");
                NightWindow empty = new NightWindow(3, 0, 3, 0);
                check("空窗口（起止相同）不含任何时间", !empty.Contains(3 * 60), "");

                FrameTickInput n = new FrameTickInput(); n.Night = true;
                eq("夜间间隔=3000", NextFrameInterval(n), IntervalNight);
                FrameTickInput e = new FrameTickInput(); e.Errored = true;
                eq("出错间隔=1000", NextFrameInterval(e), IntervalError);
                FrameTickInput b = new FrameTickInput(); b.StateStr = "busy";
                eq("忙时间隔=66", NextFrameInterval(b), IntervalBusy);
                FrameTickInput wa = new FrameTickInput(); wa.StateStr = "waiting";
                eq("等待也算忙=66", NextFrameInterval(wa), IntervalBusy);
                FrameTickInput i = new FrameTickInput(); i.StateStr = "idle";
                eq("空闲间隔=500", NextFrameInterval(i), IntervalIdle);
                FrameTickInput u = new FrameTickInput(); u.StateStr = "whatever";
                eq("未知状态按空闲=500", NextFrameInterval(u), IntervalIdle);
                FrameTickInput pri = new FrameTickInput(); pri.Night = true; pri.Errored = true; pri.StateStr = "busy";
                eq("夜间优先级最高=3000", NextFrameInterval(pri), IntervalNight);

                UsbAttemptState st = new UsbAttemptState();
                check("已打开时不再尝试", !ShouldAttemptUsbOpen(st, 100000, true).Attempt, "");
                check("首次应尝试打开", ShouldAttemptUsbOpen(st, 100000, false).Attempt, "");
                NoteOpenFailure(st, false, 100000);
                check("刚失败后进入退避", !ShouldAttemptUsbOpen(st, 101000, false).Attempt, "");
                check("超过 5 秒后重试", ShouldAttemptUsbOpen(st, 106000, false).Attempt, "");
                NoteOpenFailure(st, true, 106000);
                check("被拒 1 次仍自动重试", st.Auto, "");
                NoteOpenFailure(st, true, 112000);
                check("被拒 2 次后关闭自动重试", !st.Auto, "");
                check("关闭后需人工确认", ShouldAttemptUsbOpen(st, 999999, false).NeedsManual, "");
                NoteOpenSuccess(st);
                check("成功打开后清空退避", st.Auto && st.Denied == 0, "");
            }
            catch (Exception ex)
            {
                check("调度策略自检异常：" + ex.Message, false, "");
                fails++;
            }
            return fails;
        }
    }
}
