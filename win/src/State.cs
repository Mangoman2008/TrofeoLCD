using System;
using System.Collections.Generic;
using System.Globalization;

namespace DshLcd
{
    public class TodoItem
    {
        public string Content = "";
        public string Status = "pending";
    }

    public class AgentInfo
    {
        public string State = "unknown";        // idle | busy | waiting | unknown
        public string Activity = "空闲";
        public string Tool = "";
        public string LastText = "";
        public string Project = "（未知项目）";
        public string SessionId;                // 可选：null 表示桥端没给
        public string Model;
        public string Provider;
        public double? Turn;
        public double? Step;
    }

    /// <summary>
    /// 数据桥的事件流（桥端保留最近 12 条）。
    /// ★ Windows 版原先**完全没解析**它 —— 桥一直在发 `events: [{t,k,s}]`，
    ///   而 C# 侧既没类也没解析，于是主题 1「诊断终端」的事件流永远是空的。
    ///   本次移植主题 1 时补齐（字段对齐 ArkTS Types.ets 的 BridgeEvent）。
    /// </summary>
    public class BridgeEvent
    {
        /// <summary>时刻字符串 HH:MM:SS</summary>
        public string T = "";
        /// <summary>类型：info | busy | tool | todo | err | print …（决定着色）</summary>
        public string K = "info";
        /// <summary>内容</summary>
        public string S = "";
    }

    public class TokenInfo
    {
        public double TodayInput;
        public double TodayOutput;
        public double TodayTotal;
        public double ContextUsed;
        public double ContextWindow;
        public double? SessionTotal;
        public double? CostUsd;
        public double? CacheHitRate;
    }

    public class SystemInfo
    {
        public double Cpu;
        public double Cores;
        public double MemUsed;      // MB
        public double MemTotal;     // MB
        public double Load1;
        public double Load5;
        public double Load15;
        public double UptimeSec;
        public string Host = "localhost";
        public double CpuTemp = -1;
        /// <summary>
        /// CPU 标称主频（MHz）。**Windows 版新增** —— 主题 7（TRCC 官方风）要用它。
        /// 来源：注册表 `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0\~MHz`
        /// （标称值，不是实时值；Windows 没有无依赖的实时频率读数）。-1 = 取不到。
        /// </summary>
        public double CpuFreqMhz = -1;
        /// <summary>电量百分比 0..100（-1 = 无电池/取不到）。与 ArkTS 的 SystemInfo.battery 同义</summary>
        public double Battery = -1;
        /// <summary>是否在充电（本机采集给）</summary>
        public bool Charging;
    }

    public class WeatherInfo
    {
        public string Text = "";
        public double? TempC;
    }

    public class LyricsInfo
    {
        public string Line = "";
        public string Artist;
        public string Title;
    }

    /// <summary>
    /// DeepSeek 账户余额 —— 字段与鸿蒙版 Types.ets 的 BalanceInfo 一一对应。
    ///
    /// ★ 这是 Windows 版**原先完全缺失**的一块：桥端一直在发 `balance`
    ///   （`{ currency, total, granted, toppedUp, available, error, perHour, etaHours }`），
    ///   而 C# 侧既没有这个类、也没解析它，于是仪表盘上从来没有余额。
    ///   本次移植主题 11~15 时发现并补上。
    /// </summary>
    public class BalanceInfo
    {
        public string Currency = "CNY";
        /// <summary>总余额（-1 = 取不到）</summary>
        public double Total = -1;
        public double Granted = -1;
        public double ToppedUp = -1;
        public bool? Available;
        /// <summary>桥端取数失败的原因（空串 = 正常）</summary>
        public string Error = "";
        /// <summary>每小时烧多少钱（-1 = 采样跨度不够，算不出来）</summary>
        public double PerHour = -1;
        /// <summary>按当前速率还能用多少小时（-1 = 算不出来）</summary>
        public double EtaHours = -1;
    }

    /// <summary>一盒耗材（AMS 托盘或外挂料盘）——对齐 Normalize.ets 的 PrinterTray</summary>
    public class PrinterTray
    {
        public int Index = -1;
        public string Type = "";
        public string Color;        // #RRGGBB，非法时为 null
        public int Remain = -1;     // 0..100，-1 表示未知
    }

    /// <summary>
    /// 打印机（拓竹）状态 —— 字段与鸿蒙版 Types.ets 的 PrinterInfo 一一对应，
    /// 桥端（--printer）从 bambu-monitor 的 /api/state 压平后发过来。
    /// </summary>
    public class PrinterInfo
    {
        public string State = "UNKNOWN";
        public string StateLabel = "未知";
        /// <summary>
        /// 监控服务的状态（`monitorMode`）：`'error'` 表示**凭据有问题、需要重新登录**。
        /// ★ 2026-10-15 补：ArkTS 侧一直有这个字段（`Types.ets:121`），桥也一直在发
        ///   （`dsh-bridge.mjs` 的 printer.monitorMode），**只有 C# 这边漏了** ——
        ///   结果 Dotii 的 Bambu 页只能显示"离线"，无法区分
        ///   「打印机离线」和「监控未登录」（用户会以为是自己打印机的问题）。
        /// </summary>
        public string MonitorMode = "";
        /// <summary>监控服务的最后一次错误（`monitorError`），非空同样表示需要重新登录</summary>
        public string MonitorError = "";
        public bool? Connected;
        public bool? Online;
        public string Model = "";
        public string JobName = "";
        public int Percent = -1;
        public int Layer = -1;
        public int TotalLayer = -1;
        public int RemainingSec = -1;
        public int ElapsedSec = -1;
        public string Eta = "";
        public int NozzleTemp = -1;
        public int NozzleTarget = -1;
        public int BedTemp = -1;
        public int BedTarget = -1;
        public int ChamberTemp = -1;
        public string Wifi = "";
        public int CoolingFan = -1;
        public int HeatbreakFan = -1;
        public int SpeedLevel = -1;
        public long PrintError;
        public int HmsCount;
        public string HmsCode = "";
        public int TrayNow = -1;
        public System.Collections.Generic.List<PrinterTray> Trays = new System.Collections.Generic.List<PrinterTray>();
    }

    public class Telemetry
    {
        public double? Ts;
        public AgentInfo Agent;
        public List<TodoItem> Todos = new List<TodoItem>();
        public TokenInfo Tokens;
        public SystemInfo System;
        public WeatherInfo Weather;
        public LyricsInfo Lyrics;
        public PrinterInfo Printer;
        /// <summary>DeepSeek 余额（桥端 balance 段）</summary>
        public BalanceInfo Balance;
        /// <summary>事件流（桥端最近 12 条）</summary>
        public List<BridgeEvent> Events = new List<BridgeEvent>();
    }

    /// <summary>
    /// 遥测归一化 —— 与鸿蒙版 common/Normalize.ets 一一对应。
    ///
    /// 为什么必须在 C# 侧照抄一遍：UDP 收到的是 JSON，字段类型完全不可信。
    /// 桥端把 cpu 发成 "52" 之类的变化如果直接进渲染，异常会发生在帧循环里，
    /// 表现就是"一直不出画面"且极难定位。所有外部输入只走这一个入口。
    /// </summary>
    public class State
    {
        public const int MaxTodos = 64;
        public const int MaxText = 2000;

        public Telemetry Data = new Telemetry();
        public long LastRxTs;                       // 毫秒时间戳（Environment.TickCount 基准）
        public int Packets;
        public string LastError = "";

        /// <summary>最近 10 秒内收到过包</summary>
        public bool Fresh { get { return LastRxTs != 0 && (NowMs() - LastRxTs) < 10000; } }

        public double AgeSec()
        {
            if (LastRxTs == 0) return -1;
            return Math.Floor((NowMs() - LastRxTs) / 1000.0);
        }

        public static long NowMs()
        {
            return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
        }

        // ---------- 基础类型收敛 ----------

        public static double Num(JsonValue v, double def)
        {
            if (v == null) return def;
            if (v.IsNum) return IsFinite(v.N) ? v.N : def;
            if (v.IsStr)
            {
                double d;
                if (double.TryParse(v.S, NumberStyles.Float, CultureInfo.InvariantCulture, out d) && IsFinite(d)) return d;
            }
            return def;
        }

        public static string Str(JsonValue v, string def, int max)
        {
            if (v == null || !v.IsStr) return def;
            string s = v.S ?? "";
            return s.Length <= max ? s : s.Substring(0, max);
        }

        public static double? OptNum(JsonValue v)
        {
            if (v == null) return null;
            if (v.IsNum) return IsFinite(v.N) ? (double?)v.N : null;
            if (v.IsStr)
            {
                double d;
                if (double.TryParse(v.S, NumberStyles.Float, CultureInfo.InvariantCulture, out d) && IsFinite(d)) return d;
            }
            return null;
        }

        public static string OptStr(JsonValue v, int max)
        {
            if (v == null || !v.IsStr) return null;
            string s = v.S ?? "";
            return s.Length <= max ? s : s.Substring(0, max);
        }

        private static bool IsFinite(double d)
        {
            return !double.IsNaN(d) && !double.IsInfinity(d);
        }

        private static readonly string[] ValidStatus = new string[] { "pending", "in_progress", "completed" };
        private static readonly string[] ValidState = new string[] { "idle", "busy", "waiting", "unknown" };

        // ---------- 各段归一化 ----------

        public static List<TodoItem> NormalizeTodos(JsonValue v)
        {
            List<TodoItem> outList = new List<TodoItem>();
            if (v == null || !v.IsArr) return outList;
            int lim = Math.Min(v.Count, MaxTodos);
            for (int i = 0; i < lim; i++)
            {
                JsonValue item = v.At(i);
                if (item == null || item.IsNull) continue;
                string content = Str(item.Get("content"), "", 200);
                if (content.Length == 0) continue;
                string status = Str(item.Get("status"), "pending", 20);
                if (Array.IndexOf(ValidStatus, status) < 0) status = "pending";
                TodoItem t = new TodoItem();
                t.Content = content;
                t.Status = status;
                outList.Add(t);
            }
            return outList;
        }

        public static AgentInfo NormalizeAgent(JsonValue v)
        {
            if (v == null || v.IsNull || !v.IsObj) return null;
            AgentInfo a = new AgentInfo();
            string state = Str(v.Get("state"), "unknown", 20);
            if (Array.IndexOf(ValidState, state) < 0) state = "unknown";
            a.State = state;
            a.Activity = Str(v.Get("activity"), "空闲", 120);
            a.Tool = Str(v.Get("tool"), "", 60);
            a.LastText = Str(v.Get("lastText"), "", MaxText);
            a.Project = Str(v.Get("project"), "（未知项目）", 120);
            a.SessionId = OptStr(v.Get("sessionId"), 120);
            a.Model = OptStr(v.Get("model"), 80);
            a.Provider = OptStr(v.Get("provider"), 80);
            a.Turn = OptNum(v.Get("turn"));
            a.Step = OptNum(v.Get("step"));
            return a;
        }

        /// <summary>事件流归一化（对齐 Normalize.ets 的 normalizeEvents）。桥端最多 12 条。</summary>
        public static List<BridgeEvent> NormalizeEvents(JsonValue v)
        {
            List<BridgeEvent> outList = new List<BridgeEvent>();
            // 注意：JsonValue 的属性是 `IsArr`（不是 IsArray），照 NormalizeTodos 的写法
            if (v == null || !v.IsArr) return outList;
            int n = Math.Min(v.Count, 64);            // 上限防护（桥端是 12，这里放宽）
            for (int i = 0; i < n; i++)
            {
                JsonValue e = v.At(i);
                if (e == null || e.IsNull || !e.IsObj) continue;
                BridgeEvent be = new BridgeEvent();
                be.T = Str(e.Get("t"), "", 16);
                string k = Str(e.Get("k"), "info", 16);
                be.K = k.Length > 0 ? k : "info";
                be.S = Str(e.Get("s"), "", 200);
                outList.Add(be);
            }
            return outList;
        }

        /// <summary>余额归一化（对齐 Normalize.ets 的 normalizeBalance）。取不到时 Total = -1。</summary>
        public static BalanceInfo NormalizeBalance(JsonValue v)
        {
            BalanceInfo b = new BalanceInfo();
            if (v == null || v.IsNull || !v.IsObj)
            {
                b.Error = "无数据";
                return b;
            }
            string cur = Str(v.Get("currency"), "CNY", 8);
            if (!string.IsNullOrEmpty(cur)) b.Currency = cur;
            double? total = OptNum(v.Get("total"));
            b.Total = total.HasValue ? total.Value : -1;
            double? granted = OptNum(v.Get("granted"));
            b.Granted = granted.HasValue ? granted.Value : -1;
            double? topped = OptNum(v.Get("toppedUp"));
            b.ToppedUp = topped.HasValue ? topped.Value : -1;
            JsonValue av = v.Get("available");
            if (av != null && !av.IsNull) b.Available = av.B;
            string err = Str(v.Get("error"), "", 200);
            b.Error = err;
            double? ph = OptNum(v.Get("perHour"));
            b.PerHour = ph.HasValue ? ph.Value : -1;
            double? eh = OptNum(v.Get("etaHours"));
            b.EtaHours = eh.HasValue ? eh.Value : -1;
            return b;
        }

        public static TokenInfo NormalizeTokens(JsonValue v)
        {
            if (v == null || v.IsNull || !v.IsObj) return null;
            TokenInfo t = new TokenInfo();
            t.TodayInput = Num(v.Get("todayInput"), 0);
            t.TodayOutput = Num(v.Get("todayOutput"), 0);
            double? total = OptNum(v.Get("todayTotal"));
            t.TodayTotal = total.HasValue ? total.Value : (t.TodayInput + t.TodayOutput);
            t.SessionTotal = OptNum(v.Get("sessionTotal"));
            t.ContextUsed = Num(v.Get("contextUsed"), 0);
            t.ContextWindow = Num(v.Get("contextWindow"), 0);
            t.CostUsd = OptNum(v.Get("costUsd"));
            t.CacheHitRate = OptNum(v.Get("cacheHitRate"));
            // 负数没有意义，钳到 0
            if (t.TodayInput < 0) t.TodayInput = 0;
            if (t.TodayOutput < 0) t.TodayOutput = 0;
            if (t.ContextUsed < 0) t.ContextUsed = 0;
            if (t.TodayTotal < 0) t.TodayTotal = 0;
            return t;
        }

        public static SystemInfo NormalizeSystem(JsonValue v)
        {
            if (v == null || v.IsNull || !v.IsObj) return null;
            SystemInfo s = new SystemInfo();
            s.Cpu = Math.Max(0, Math.Min(100, Num(v.Get("cpu"), 0)));
            s.Cores = Math.Max(0, Math.Round(Num(v.Get("cores"), 0)));
            s.MemUsed = Math.Max(0, Num(v.Get("memUsed"), 0));
            s.MemTotal = Math.Max(0, Num(v.Get("memTotal"), 0));
            s.Load1 = Num(v.Get("load1"), 0);
            s.Load5 = Num(v.Get("load5"), 0);
            s.Load15 = Num(v.Get("load15"), 0);
            s.UptimeSec = Math.Max(0, Num(v.Get("uptimeSec"), 0));
            s.Host = Str(v.Get("host"), "localhost", 120);
            s.CpuTemp = Num(v.Get("cpuTemp"), -1);
            // 钳到 -1..100：桥端不该发这个字段，但真发了也不能画出越界的百分比
            s.Battery = Math.Max(-1, Math.Min(100, Math.Round(Num(v.Get("battery"), -1))));
            JsonValue chg = v.Get("charging");
            s.Charging = chg != null && chg.IsBool && chg.B;
            return s;
        }

        /// <summary>
        /// 选一份系统数据来渲染 —— 与 ArkTS 的 LocalSys.pickSystem() 同一条规则：
        /// 桥端新鲜就用桥端（它代表 DSH 所在机器的真实负载），否则退回本机；
        /// **但电量是本机属性**（桥端 JSON 里没有这一项），所以不管用哪一份，都要把本机读数补上，
        /// 否则"电量"这一行只在桥端断流时才出现（桥端正常跑着反而看不到电量）。
        /// </summary>
        public static SystemInfo PickSystem(SystemInfo bridge, bool bridgeFresh, SystemInfo local)
        {
            SystemInfo b = (bridgeFresh && bridge != null) ? bridge : local;
            if (b == null)
            {
                return null;
            }
            if (b.Battery < 0 && local != null)
            {
                b.Battery = local.Battery;
                b.Charging = local.Charging;
            }
            return b;
        }

        public static WeatherInfo NormalizeWeather(JsonValue v)
        {
            if (v == null || v.IsNull || !v.IsObj) return null;
            string text = Str(v.Get("text"), "", 60);
            if (text.Length == 0) return null;
            WeatherInfo w = new WeatherInfo();
            w.Text = text;
            w.TempC = OptNum(v.Get("tempC"));
            return w;
        }

        public static LyricsInfo NormalizeLyrics(JsonValue v)
        {
            if (v == null || v.IsNull || !v.IsObj) return null;
            string line = Str(v.Get("line"), "", 200);
            if (line.Length == 0) return null;
            LyricsInfo l = new LyricsInfo();
            l.Line = line;
            l.Artist = OptStr(v.Get("artist"), 80);
            l.Title = OptStr(v.Get("title"), 80);
            return l;
        }

        public const int MaxTrays = 8;

        private static readonly string[] ValidPrinterState = new string[]
        { "IDLE", "PREPARE", "RUNNING", "PAUSE", "FINISH", "FAILED", "STUCK", "OFFLINE", "UNKNOWN" };

        public static string PrinterStateLabel(string state)
        {
            if (state == "IDLE") return "空闲";
            if (state == "PREPARE") return "准备中";
            if (state == "RUNNING") return "打印中";
            if (state == "PAUSE") return "已暂停";
            if (state == "FINISH") return "已完成";
            if (state == "FAILED") return "失败";
            if (state == "STUCK") return "卡住";
            if (state == "OFFLINE") return "离线";
            return "未知";
        }

        private static int ClampInt(JsonValue v, int lo, int hi, int def)
        {
            double? n = OptNum(v);
            if (!n.HasValue) return def;
            double r = Math.Round(n.Value);
            if (r < lo) return lo;
            if (r > hi) return hi;
            return (int)r;
        }

        /// <summary>颜色统一成 #RRGGBB（拓竹给 8 位 RRGGBBAA，也可能带 #），非法返回 null</summary>
        private static string NormColor(JsonValue v)
        {
            string s = OptStr(v, 16);
            if (s == null) return null;
            string t = s.Trim();
            if (t.StartsWith("#")) t = t.Substring(1);
            if (t.Length < 6) return null;
            t = t.Substring(0, 6).ToUpperInvariant();
            for (int i = 0; i < 6; i++)
            {
                char c = t[i];
                bool hex = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F');
                if (!hex) return null;
            }
            return "#" + t;
        }

        public static System.Collections.Generic.List<PrinterTray> NormalizeTrays(JsonValue v)
        {
            System.Collections.Generic.List<PrinterTray> outList = new System.Collections.Generic.List<PrinterTray>();
            if (v == null || !v.IsArr) return outList;
            int lim = Math.Min(v.Count, MaxTrays);
            for (int i = 0; i < lim; i++)
            {
                JsonValue item = v.At(i);
                if (item == null || item.IsNull || !item.IsObj) continue;
                string type = Str(item.Get("type"), "", 16);
                // 空槽（Empty）不值得占位置
                if (type.Length == 0 || type == "Empty") continue;
                PrinterTray t = new PrinterTray();
                t.Index = ClampInt(item.Get("index"), 0, 99, outList.Count + 1);
                t.Type = type;
                t.Color = NormColor(item.Get("color"));
                t.Remain = ClampInt(item.Get("remain"), 0, 100, -1);
                outList.Add(t);
            }
            return outList;
        }

        /// <summary>
        /// 打印机状态归一化（对齐 Normalize.ets 的 normalizePrinter）。
        /// 返回 null = 没有打印机数据 → 渲染器不拆栏、退回整高 VM 面板。
        /// </summary>
        public static PrinterInfo NormalizePrinter(JsonValue v)
        {
            if (v == null || v.IsNull || !v.IsObj) return null;
            PrinterInfo p = new PrinterInfo();

            string state = Str(v.Get("state"), "UNKNOWN", 20).ToUpperInvariant();
            if (Array.IndexOf(ValidPrinterState, state) < 0) state = "UNKNOWN";
            p.State = state;
            p.StateLabel = Str(v.Get("stateLabel"), PrinterStateLabel(state), 20);
            // ★ 2026-10-15：与 ArkTS Normalize.ets:318-319 对齐
            p.MonitorMode = Str(v.Get("monitorMode"), "", 16);
            p.MonitorError = Str(v.Get("monitorError"), "", 96);

            JsonValue conn = v.Get("connected");
            if (conn != null && conn.IsBool) p.Connected = conn.B;
            JsonValue on = v.Get("online");
            if (on != null && on.IsBool) p.Online = on.B;

            p.Model = Str(v.Get("model"), "", 60);
            p.JobName = Str(v.Get("jobName"), "", 120);
            p.Eta = Str(v.Get("eta"), "", 10);
            p.Wifi = Str(v.Get("wifi"), "", 16);
            p.Percent = ClampInt(v.Get("percent"), 0, 100, -1);
            p.Layer = ClampInt(v.Get("layer"), 0, 100000, -1);
            p.TotalLayer = ClampInt(v.Get("totalLayer"), 0, 100000, -1);
            p.RemainingSec = ClampInt(v.Get("remainingSec"), 0, 864000, -1);
            p.ElapsedSec = ClampInt(v.Get("elapsedSec"), 0, 864000, -1);
            p.NozzleTemp = ClampInt(v.Get("nozzleTemp"), -1, 400, -1);
            p.NozzleTarget = ClampInt(v.Get("nozzleTarget"), -1, 400, -1);
            p.BedTemp = ClampInt(v.Get("bedTemp"), -1, 200, -1);
            p.BedTarget = ClampInt(v.Get("bedTarget"), -1, 200, -1);
            p.ChamberTemp = ClampInt(v.Get("chamberTemp"), -1, 100, -1);
            p.CoolingFan = ClampInt(v.Get("coolingFan"), -1, 100, -1);
            p.HeatbreakFan = ClampInt(v.Get("heatbreakFan"), -1, 100, -1);
            p.SpeedLevel = ClampInt(v.Get("speedLevel"), 0, 4, -1);
            p.TrayNow = ClampInt(v.Get("trayNow"), -1, 99, -1);

            // 拓竹 print_error 是 32 位码（实测 83951617 这种 8 位数），别用小上限截掉
            double? pn = OptNum(v.Get("printError"));
            p.PrintError = pn.HasValue ? (long)Math.Max(0, Math.Min(4294967295.0, Math.Round(pn.Value))) : 0;

            JsonValue hms = v.Get("hms");
            if (hms != null && hms.IsArr)
            {
                p.HmsCount = hms.Count;
                if (p.HmsCount > 0)
                {
                    JsonValue first = hms.At(0);
                    if (first != null && first.IsObj) p.HmsCode = Str(first.Get("code"), "", 40);
                }
            }
            p.Trays = NormalizeTrays(v.Get("trays"));
            return p;
        }

        public static Telemetry NormalizeTelemetry(JsonValue raw)
        {
            Telemetry t = new Telemetry();
            if (raw == null || raw.IsNull || !raw.IsObj) return t;
            t.Ts = OptNum(raw.Get("ts"));
            t.Agent = NormalizeAgent(raw.Get("agent"));
            t.Todos = NormalizeTodos(raw.Get("todos"));
            t.Tokens = NormalizeTokens(raw.Get("tokens"));
            t.System = NormalizeSystem(raw.Get("system"));
            t.Weather = NormalizeWeather(raw.Get("weather"));
            t.Lyrics = NormalizeLyrics(raw.Get("lyrics"));
            t.Printer = NormalizePrinter(raw.Get("printer"));
            t.Balance = NormalizeBalance(raw.Get("balance"));
            t.Events = NormalizeEvents(raw.Get("events"));
            return t;
        }

        /// <summary>上一次 state 变化日志的时间（诊断用，见 ApplyText）</summary>
        private long _lastStateLogTs;

        /// <summary>收到一个 UDP JSON 包：解析 → 归一化 → 落地。与鸿蒙版 LcdService 同语义（整包替换）。</summary>
        public bool ApplyText(string json)
        {
            JsonValue v = JsonValue.Parse(json);
            if (v == null || !v.IsObj)
            {
                LastError = "坏 JSON";
                return false;
            }
            Telemetry prev = Data;
            Data = NormalizeTelemetry(v);
            LastRxTs = NowMs();
            Packets++;
            LastError = "";

            // ★ 2026-10-15 诊断：state 值**只在变化时**打一行。
            //   排查"屏幕上的数据一跳一跳"时必须知道**程序到底收到了什么** ——
            //   桥侧已实测完全稳定（25 秒 25 包、state 全 busy、零坏包），
            //   所以要么这里收到的在变，要么渲染侧在变。不打这一行就只能靠猜。
            string st = (Data == null || Data.Agent == null) ? "<null>" : Data.Agent.State;
            string pv = (prev == null || prev.Agent == null) ? "<none>" : prev.Agent.State;
            if (st != pv)
            {
                double bid = (Data == null || Data.Balance == null) ? -1 : Data.Balance.Total;
                Log.W("遥测 state 变化：{0} -> {1}（第 {2} 包，余额={3}，间隔 {4}ms）",
                      pv, st, Packets, bid, LastRxTs - _lastStateLogTs);
                _lastStateLogTs = LastRxTs;
            }
            return true;
        }
    }
}
