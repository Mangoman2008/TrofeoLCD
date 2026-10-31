using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace DshLcd
{
    /// <summary>
    /// 拓竹打印机状态机 —— 把原始 MQTT report 归一化成 <see cref="PrinterInfo"/>。
    ///
    /// ★ 2026-10-15 新增。移植自 Node 的 `bambu-monitor/lib/state.mjs`（278 行），
    ///   目的是让 dshlcd 自己就能取到打印机数据，不再依赖本机的 bambu-monitor 服务。
    ///
    /// ## 关键设计：压平后复用 NormalizePrinter
    /// Node 那边 `snapshot()` 产出的是**嵌套**结构（temps/progress/ams/errors…），
    /// 而本工程已有的 `State.NormalizePrinter` 吃的是**扁平**结构 ——
    /// 也就是 `dsh-bridge.mjs` 的 `mapBambuState()` 产出的那种（`nozzleTemp`、
    /// `percent`、`monitorMode` …）。
    ///
    ///   所以这里的做法是：**先按桥的规则把原始报文压平成同构 JSON，
    ///   再交给 `State.NormalizePrinter`**。
    ///   好处是钳制范围、白名单、字段名规则**只有一份实现**（在 State.cs 里），
    ///   两条取数路径（桥 / 本机 MQTT）不可能漂移。
    ///
    /// ## 线程
    /// 由 <see cref="MqttClient"/> 的接收线程调用 <see cref="Feed"/>，
    /// 外部读 <see cref="Snapshot"/>。都用锁保护。
    /// </summary>
    public class BambuState
    {
        /// <summary>离线判定阈值（毫秒）：超过这么久没收到上报就判离线</summary>
        public const int DefaultOfflineTimeoutMs = 90000;

        // ---------- 原始字段 → 中文状态（对齐 state.mjs 的 STATE_LABELS）----------
        private static readonly Dictionary<string, string> StateLabels = new Dictionary<string, string>
        {
            { "IDLE", "空闲" }, { "PREPARE", "准备中" }, { "RUNNING", "打印中" },
            { "PAUSE", "已暂停" }, { "FINISH", "已完成" }, { "FAILED", "失败" },
            { "STUCK", "卡住" }, { "OFFLINE", "离线" }, { "UNKNOWN", "未知" },
        };

        private readonly object _lock = new object();

        // ---------- 内部状态（对齐 state.mjs 的字段）----------
        private JsonValue _raw;                 // 最近一次原始 print 对象
        private long _lastReportMs;             // 最近一次收到 report（0 = 从未）
        private bool _hasReport;
        private bool _mqttConnected;
        private bool _online;                   // 打印机是否在线
        private string _state = "UNKNOWN";
        private bool _printStartSet;
        private long _printStartMs;
        private long _lastProgressEventMs;
        private double _lastPercent = -1;
        private bool _offlineWarned;
        private string _lastAmsKey = "";

        /// <summary>连接信息（供 /diag 与 Dotii 的"监控未登录"判定）</summary>
        public string MonitorMode = "not-configured";   // not-configured | discovering | running | error
        public string MonitorError = "";
        public string Region = "";
        public string DeviceId = "";
        public string DeviceName = "";
        public string DeviceModel = "";
        public string MqttUsername = "";

        /// <summary>事件回调（状态变化/进度/AMS 变化/上下线），在接收线程上调用，实现要快</summary>
        public Action<string, string> OnEvent;

        // ================= 外部读 =================

        /// <summary>
        /// 产出当前 <see cref="PrinterInfo"/>。
        /// 未配置凭据 / 还没收到任何上报时返回 null（显示层会照常画"离线"）。
        /// </summary>
        public PrinterInfo Snapshot()
        {
            JsonValue flat;
            lock (_lock)
            {
                if (_raw == null) return null;
                flat = BuildFlatJson();
            }
            // NormalizePrinter 是纯函数（不碰共享状态），放在锁外做，缩短持锁时间
            return State.NormalizePrinter(flat);
        }

        /// <summary>距上次上报多少毫秒（-1 = 从未收到）</summary>
        public double ReportAgeMs()
        {
            lock (_lock)
            {
                if (!_hasReport) return -1;
                return DateTime.Now.Ticks / TimeSpan.TicksPerMillisecond - _lastReportMs;
            }
        }

        /// <summary>
        /// 累计收到的报文条数。
        /// ★ 由 BambuState 自己维护（而不是让调用方各自数）——
        ///   自检程序与主程序都可以用它判断“到底有没有收到数据”。
        /// </summary>
        public int Reports;

        /// <summary>MQTT 是否已连上云端</summary>
        public bool MqttConnected { get { lock (_lock) { return _mqttConnected; } } }

        /// <summary>打印机是否在线（收到过上报且未超时）</summary>
        public bool PrinterOnline { get { lock (_lock) { return _online; } } }

        /// <summary>当前状态码（IDLE/RUNNING/…）</summary>
        public string StateCode { get { lock (_lock) { return _state; } } }

        /// <summary>最近一次原始报文（只读用途，如 /diag 排障）</summary>
        public string RawJsonPreview(int maxLen)
        {
            lock (_lock)
            {
                if (_raw == null) return "";
                string s = _raw.ToJson();
                return s.Length <= maxLen ? s : s.Substring(0, maxLen) + "…";
            }
        }

        // ================= 外部写 =================

        /// <summary>MQTT 连上（对齐 state.mjs markConnected）</summary>
        public void MarkConnected()
        {
            lock (_lock)
            {
                _mqttConnected = true;
                MonitorMode = "running";
                MonitorError = "";
            }
        }

        /// <summary>
        /// MQTT 断开（对齐 markDisconnected）：把打印机判为离线。
        /// 之前是在线的话产生一条"打印机离线"事件。
        /// </summary>
        public void MarkDisconnected(string reason)
        {
            bool wasOnline;
            lock (_lock)
            {
                _mqttConnected = false;
                wasOnline = _online;
                _online = false;
            }
            if (wasOnline)
            {
                Emit("printer_offline", "打印机离线（" + (string.IsNullOrEmpty(reason) ? "MQTT 断开" : reason) + "）");
            }
        }

        /// <summary>
        /// 长时间无数据 → 判离线（对齐 checkStale）。
        /// 由定时器调用；只在**首次**超时时产生事件（`offlineWarned` 护栏）。
        /// </summary>
        public void CheckStale(int timeoutMs)
        {
            bool fire = false;
            lock (_lock)
            {
                if (!_online || !_hasReport || _offlineWarned) return;
                long nowMs = DateTime.Now.Ticks / TimeSpan.TicksPerMillisecond;
                if (nowMs - _lastReportMs > timeoutMs)
                {
                    _offlineWarned = true;
                    _online = false;
                    fire = true;
                }
            }
            if (fire)
            {
                Emit("printer_offline", "打印机离线（" + (timeoutMs / 1000) + " 秒无数据）");
            }
        }

        /// <summary>
        /// 喂入一条 MQTT report 的 JSON（对齐 state.mjs feed）。
        /// 返回本次产生的事件条数（0 = 无事件）。
        /// </summary>
        public int Feed(string jsonText)
        {
            JsonValue root = JsonValue.Parse(jsonText);
            if (root == null || !root.IsObj) return 0;
            JsonValue p = root.Get("print");
            if (p == null || !p.IsObj) return 0;

            List<string[]> evs = new List<string[]>();
            string newState;
            double? percent;

            lock (_lock)
            {
                _raw = p;
                _lastReportMs = DateTime.Now.Ticks / TimeSpan.TicksPerMillisecond;
                _hasReport = true;
                Reports++;

                // 上线事件（只在从 false/null 变成在线时发一次）
                if (!_online)
                {
                    bool wasOffline = _offlineWarned || _online == false;
                    _online = true;
                    _offlineWarned = false;
                    if (_state != "UNKNOWN" || wasOffline) { /* 首次静默，恢复时提示 */ }
                    if (wasOffline) evs.Add(new string[] { "printer_online", "打印机恢复在线" });
                }

                string gcode = Str(p.Get("gcode_state")).ToUpperInvariant();
                string prevState = _state;
                newState = GcodeToState(gcode, _state);
                _state = newState;

                // 打印计时（对齐 state.mjs：RUNNING 起算，离开 RUNNING/PAUSE 清空）
                if (newState == "RUNNING" && !_printStartSet)
                {
                    _printStartSet = true;
                    _printStartMs = _lastReportMs;
                }
                if (newState != "RUNNING" && newState != "PAUSE")
                {
                    _printStartSet = false;
                }

                percent = NumOrNull(p.Get("mc_percent"));

                // ---- 状态转换事件 ----
                if (prevState != newState)
                {
                    string[] tr = TransitionEvent(prevState, newState, p);
                    if (tr != null) evs.Add(tr);
                    else evs.Add(new string[] { "state_change",
                        "状态变化: " + Label(prevState) + " → " + Label(newState) });
                }

                // ---- 进度事件（对齐 state.mjs：>=1% 且距上次 >=30 秒）----
                if (newState == "RUNNING" && percent.HasValue)
                {
                    bool changed = Math.Abs(percent.Value - _lastPercent) >= 1;
                    bool enoughTime = _lastReportMs - _lastProgressEventMs >= 30000;
                    if (changed && enoughTime)
                    {
                        _lastProgressEventMs = _lastReportMs;
                        double? rem = NumOrNull(p.Get("mc_remaining_time"));
                        string msg = "打印进度 " + ((int)Math.Round(percent.Value)) + "%";
                        if (rem.HasValue) msg += "，剩余 " + FmtDuration(rem.Value);
                        evs.Add(new string[] { "progress", msg });
                    }
                    _lastPercent = percent.Value;
                }

                // ---- AMS 变化 ----
                string amsKey = AmsKey(p);
                if (!string.IsNullOrEmpty(amsKey) && amsKey != _lastAmsKey)
                {
                    _lastAmsKey = amsKey;
                    evs.Add(new string[] { "ams_changed", "AMS 耗材状态变化" });
                }
            }

            for (int i = 0; i < evs.Count; i++) Emit(evs[i][0], evs[i][1]);
            return evs.Count;
        }

        // ================= 压平：原始报文 → 桥格式 JSON =================

        /// <summary>
        /// 把原始 print 对象压平成 `dsh-bridge.mjs` 的 `mapBambuState()` 同构 JSON。
        /// **调用方必须已持有 _lock。**
        /// </summary>
        private JsonValue BuildFlatJson()
        {
            JsonValue p = _raw;
            JsonValue o = JsonValue.NewObj();

            // 监控服务状态（本机直连时没有"监控服务"，用 MQTT 连接状态代替）
            PutStr(o, "monitorMode", MonitorMode == null ? "" : MonitorMode);
            PutStr(o, "monitorError", MonitorError == null ? "" : MonitorError);

            string state = _state;
            PutStr(o, "state", state);
            PutStr(o, "stateLabel", Label(state));
            PutBool(o, "connected", _mqttConnected);
            PutBool(o, "online", _online);

            // model：桥用 dev.name + nozzleDiameter + nozzleType 拼
            // ★ 设备名为空时退回序列号。实测这台 P2S 的 `dev_name` 是空的，
            //   直接用 DeviceName 会得到 "0.4mm HS01"（看不出是哪台机）。
            //   桥端 mapBambuState 用的是 `dev.name || dev_id`，这里对齐。
            string model = !string.IsNullOrEmpty(DeviceName) ? DeviceName : DeviceId;
            JsonValue nd = p.Get("nozzle_diameter");
            if (nd != null && !nd.IsNull)
            {
                model = (model.Length > 0 ? model + " " : "") + Str(nd) + "mm";
            }
            JsonValue nt = p.Get("nozzle_type");
            if (nt != null && !nt.IsNull)
            {
                model = (model.Length > 0 ? model + " " : "") + Str(nt);
            }
            PutStr(o, "model", model);

            // 任务名：桥取 subtask_name，退回 gcode_file
            string job = Str(p.Get("subtask_name"));
            if (job.Length == 0) job = Str(p.Get("gcode_file"));
            PutStr(o, "jobName", job);

            // 进度
            PutNumOrNeg(o, "percent", NumOrNull(p.Get("mc_percent")));
            PutIntOrNeg(o, "layer", IntOrNull(p.Get("layer_num")));
            PutIntOrNeg(o, "totalLayer", IntOrNull(p.Get("total_layer_num")));
            double? remSec = NumOrNull(p.Get("mc_remaining_time"));
            PutIntOrNeg(o, "remainingSec", remSec.HasValue ? (int?)remSec.Value : null);
            if (_printStartSet)
            {
                long elapsed = (_lastReportMs - _printStartMs) / 1000;
                PutIntOrNeg(o, "elapsedSec", (int)elapsed);
            }
            else
            {
                PutIntOrNeg(o, "elapsedSec", null);
            }
            // eta：桥给的是 "HH:MM" 字符串；RUNNING 且有剩余时间才算
            if (state == "RUNNING" && remSec.HasValue && remSec.Value > 0)
            {
                DateTime eta = DateTime.Now.AddSeconds(remSec.Value);
                PutStr(o, "eta", eta.Hour.ToString("00", CultureInfo.InvariantCulture)
                    + ":" + eta.Minute.ToString("00", CultureInfo.InvariantCulture));
            }
            else
            {
                PutStr(o, "eta", "");
            }

            // 温度
            PutIntOrNeg(o, "nozzleTemp", IntOrNull(p.Get("nozzle_temper")));
            PutIntOrNeg(o, "nozzleTarget", IntOrNull(p.Get("nozzle_target_temper")));
            PutIntOrNeg(o, "bedTemp", IntOrNull(p.Get("bed_temper")));
            PutIntOrNeg(o, "bedTarget", IntOrNull(p.Get("bed_target_temper")));
            PutIntOrNeg(o, "chamberTemp", IntOrNull(p.Get("chamber_temper")));

            // 其它
            JsonValue wifi = p.Get("wifi_signal");
            PutStr(o, "wifi", (wifi == null || wifi.IsNull) ? "" : Str(wifi));
            PutIntOrNeg(o, "coolingFan", NumStrToInt(p.Get("cooling_fan_speed")));
            PutIntOrNeg(o, "heatbreakFan", NumStrToInt(p.Get("heatbreak_fan_speed")));
            PutIntOrNeg(o, "speedLevel", IntOrNull(p.Get("spd_lvl")));
            PutNumOrNeg(o, "printError", NumOrNull(p.Get("print_error")));

            // HMS 告警：只取条数与第一条短码（对齐 state.mjs 的 hms 数组）
            JsonValue hms = p.Get("hms");
            JsonValue hmsArr = JsonValue.NewArr();
            if (hms != null && hms.IsArr)
            {
                for (int i = 0; i < hms.Count; i++)
                {
                    JsonValue h = hms.At(i);
                    if (h == null || !h.IsObj) continue;
                    JsonValue item = JsonValue.NewObj();
                    PutStr(item, "code", Str(h.Get("code")));
                    hmsArr.Arr.Add(item);
                }
            }
            o.Obj["hms"] = hmsArr;

            // AMS：多单元托盘拉平（对齐 mapBambuState 的托盘编号规则）
            JsonValue ams = p.Get("ams");
            JsonValue trays = JsonValue.NewArr();
            int trayNo = 0;
            if (ams != null && ams.IsObj)
            {
                JsonValue units = ams.Get("ams");
                if (units != null && units.IsArr)
                {
                    for (int ui = 0; ui < units.Count; ui++)
                    {
                        JsonValue u = units.At(ui);
                        if (u == null || !u.IsObj) continue;
                        JsonValue tl = u.Get("tray");
                        if (tl == null || !tl.IsArr) continue;
                        for (int ti = 0; ti < tl.Count; ti++)
                        {
                            JsonValue t = tl.At(ti);
                            if (t == null || !t.IsObj) continue;
                            string type = Str(t.Get("tray_type"));
                            if (type.Length == 0 || type == "Empty") continue;
                            trayNo++;
                            trays.Arr.Add(TrayJson(trayNo, type, t.Get("tray_color"), t.Get("remain")));
                        }
                    }
                }
                // 外挂料盘 vt_tray
                JsonValue vt = ams.Get("vt_tray");
                if (vt != null && vt.IsObj)
                {
                    string vtType = Str(vt.Get("tray_type"));
                    if (vtType.Length > 0 && vtType != "Empty")
                    {
                        trayNo++;
                        trays.Arr.Add(TrayJson(trayNo, vtType, vt.Get("tray_color"), vt.Get("remain")));
                    }
                }
                // tray_now 的 哨兵值：拓竰用 **255** 表示“未选料盘”。
                // ★ 2026-10-15 实测：原始报文里是字符串 "255"。
                //   不能直接交给 NormalizePrinter —— 它的 ClampInt 是**钳到边界**（-1..99），
                //   255 会变成 99（一个看上去合法但错误的料盘号）。
                //   这里按设备语义先判掉，不写该键 → 层层用默认值 -1。
                int? trayNowRaw = IntOrNull(ams.Get("tray_now"));
                if (trayNowRaw.HasValue && (trayNowRaw.Value < 0 || trayNowRaw.Value > 99))
                {
                    trayNowRaw = null;      // 未选 / 超出可能范围
                }
                PutIntOrNeg(o, "trayNow", trayNowRaw);
            }
            else
            {
                PutIntOrNeg(o, "trayNow", null);
            }
            o.Obj["trays"] = trays;

            return o;
        }

        private static JsonValue TrayJson(int index, string type, JsonValue color, JsonValue remain)
        {
            JsonValue t = JsonValue.NewObj();
            PutIntOrNeg(t, "index", index);
            PutStr(t, "type", type);
            // 颜色：拓竹给的是 8 位 RGBA 十六进制（如 "FF0000FF"）；
            // NormalizePrinter 的 NormColor 只认 #RRGGBB，所以先转成 CSS 形式
            t.Obj["color"] = JsonValue.NewStr(TrayColorToCss(color));
            PutIntOrNeg(t, "remain", NumStrToInt(remain));
            return t;
        }

        /// <summary>8 位 RGBA / 6 位 RGB / 3 位 十六进制 → "#RRGGBB"；非法返回空串</summary>
        public static string TrayColorToCss(JsonValue v)
        {
            if (v == null || v.IsNull) return "";
            string hex = Str(v).Trim();
            if (hex.Length >= 8) hex = hex.Substring(0, 6);      // 去掉 alpha
            if (hex.Length == 6 && IsHex(hex)) return "#" + hex;
            if (hex.Length == 8 && IsHex(hex)) return "#" + hex.Substring(2);   // ARGB
            if (hex.Length == 3 && IsHex(hex)) return "#" + hex;
            return "";
        }

        private static bool IsHex(string s)
        {
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
                if (!ok) return false;
            }
            return true;
        }

        // ================= 小工具 =================

        private static void PutStr(JsonValue o, string k, string v)
        {
            o.Obj[k] = JsonValue.NewStr(v == null ? "" : v);
        }

        private static void PutBool(JsonValue o, string k, bool v)
        {
            o.Obj[k] = JsonValue.NewBool(v);
        }

        /// <summary>写入数字；null 时**不写这个键**（让 NormalizePrinter 用它自己的默认值）</summary>
        private static void PutNumOrNeg(JsonValue o, string k, double? v)
        {
            if (v.HasValue) o.Obj[k] = JsonValue.NewNum(v.Value);
        }

        private static void PutIntOrNeg(JsonValue o, string k, int? v)
        {
            if (v.HasValue) o.Obj[k] = JsonValue.NewNum(v.Value);
        }

        /// <summary>取字段的字符串形式（数字也转成字符串，对齐 JS 的 String(v)）</summary>
        private static string Str(JsonValue v)
        {
            if (v == null || v.IsNull) return "";
            if (v.IsStr) return v.S == null ? "" : v.S;
            if (v.IsNum) return v.N.ToString(CultureInfo.InvariantCulture);
            if (v.IsBool) return v.B ? "true" : "false";
            return "";
        }

        private static double? NumOrNull(JsonValue v)
        {
            if (v == null || v.IsNull) return null;
            if (v.IsNum) return v.N;
            if (v.IsStr)
            {
                double d;
                if (double.TryParse(v.S, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return d;
            }
            return null;
        }

        private static int? IntOrNull(JsonValue v)
        {
            double? d = NumOrNull(v);
            return d.HasValue ? (int?)Math.Round(d.Value) : null;
        }

        /// <summary>
        /// 拓竹的 fan 速度是**字符串**（"0"/"15"），要单独转。
        /// 转换失败返回 null（让上层用它自己的默认值 -1）。
        /// </summary>
        private static int? NumStrToInt(JsonValue v)
        {
            return IntOrNull(v);
        }

        private static string Label(string state)
        {
            string s;
            return (state != null && StateLabels.TryGetValue(state, out s)) ? s : (state == null ? "未知" : state);
        }

        /// <summary>gcode_state → 统一状态码（对齐 state.mjs 的 _mapState）</summary>
        private static string GcodeToState(string gcode, string fallback)
        {
            if (string.IsNullOrEmpty(gcode)) return fallback;
            if (gcode == "IDLE") return "IDLE";
            if (gcode == "PREPARE" || gcode == "PREPARING") return "PREPARE";
            if (gcode == "RUNNING") return "RUNNING";
            if (gcode == "PAUSE" || gcode == "PAUSED") return "PAUSE";
            if (gcode == "FINISH" || gcode == "FINISHED" || gcode == "COMPLETE") return "FINISH";
            if (gcode == "FAILED" || gcode == "ERROR") return "FAILED";
            if (gcode == "STUCK") return "STUCK";
            return fallback;
        }

        /// <summary>状态转换的特殊文案（对齐 state.mjs 的 _stateTransitionEvent）</summary>
        private static string[] TransitionEvent(string prev, string cur, JsonValue p)
        {
            if (cur == "RUNNING")
            {
                if (prev == "PAUSE") return new string[] { "print_resumed", "打印已恢复" };
                if (prev != "RUNNING")
                {
                    string name = Str(p.Get("subtask_name"));
                    if (name.Length == 0) name = "未知文件";
                    return new string[] { "print_started", "开始打印: " + name };
                }
                return null;
            }
            if (cur == "FINISH") return new string[] { "print_finished", "打印完成" };
            if (cur == "FAILED") return new string[] { "print_failed", "打印失败（请检查打印机）" };
            if (cur == "PAUSE")
            {
                if (prev == "RUNNING") return new string[] { "print_paused", "打印已暂停" };
                return new string[] { "state_change", "打印机暂停" };
            }
            return null;
        }

        /// <summary>AMS 指纹（对齐 state.mjs 的 _amsKey）：用来判"耗材状态变了"</summary>
        private static string AmsKey(JsonValue p)
        {
            try
            {
                JsonValue ams = p.Get("ams");
                if (ams == null || !ams.IsObj) return "";
                JsonValue units = ams.Get("ams");
                if (units == null || !units.IsArr) return "";
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < units.Count; i++)
                {
                    JsonValue u = units.At(i);
                    if (u == null || !u.IsObj) continue;
                    sb.Append(Str(u.Get("id"))).Append('|').Append(Str(u.Get("humidity_raw"))).Append('|');
                    JsonValue tl = u.Get("tray");
                    if (tl != null && tl.IsArr)
                    {
                        for (int j = 0; j < tl.Count; j++)
                        {
                            JsonValue t = tl.At(j);
                            if (t == null || !t.IsObj) continue;
                            sb.Append(Str(t.Get("id"))).Append(',')
                              .Append(Str(t.Get("tray_type"))).Append(',')
                              .Append(Str(t.Get("tray_color"))).Append(',')
                              .Append(Str(t.Get("remain"))).Append(';');
                        }
                    }
                    sb.Append('#');
                }
                return sb.ToString();
            }
            catch (Exception)
            {
                return "";
            }
        }

        /// <summary>时长文案（对齐 util.mjs 的 fmtDuration）</summary>
        public static string FmtDuration(double sec)
        {
            if (sec < 0 || double.IsNaN(sec) || double.IsInfinity(sec)) return "—";
            int s = (int)Math.Round(sec);
            int h = s / 3600;
            int m = (s % 3600) / 60;
            int ss = s % 60;
            if (h > 0) return h + " 小时 " + m.ToString("00") + " 分";
            if (m > 0) return m + " 分 " + ss.ToString("00") + " 秒";
            return ss + " 秒";
        }

        private void Emit(string type, string message)
        {
            Action<string, string> h = OnEvent;
            if (h != null)
            {
                try { h(type, message); }
                catch (Exception) { /* 事件回调不该影响取数 */ }
            }
        }
    }
}
