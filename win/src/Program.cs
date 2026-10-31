using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace DshLcd
{
    /// <summary>
    /// dshlcd —— 利民 Trofeo Vision 9.16 LCD 的 Windows 绿色版控制端（单文件 exe）。
    ///
    /// 编译：C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe（C# 5 语法上限）
    /// 运行：winexe，无控制台窗口；日志默认写 exe 同目录 dshlcd.log，加 --console 可看实时输出。
    /// </summary>
    public static class Program
    {
        [DllImport("kernel32.dll")]
        private static extern bool AllocConsole();

        [DllImport("kernel32.dll")]
        private static extern bool SetConsoleOutputCP(uint cp);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        /// <summary>
        /// 弹窗提示。winexe 双击后本来就什么都不显示，一旦启动失败用户会以为"没反应"，
        /// 所以任何致命错误都要弹出来（这是本程序唯一的可见失败通道）。
        /// </summary>
        public static void Popup(string text, string caption)
        {
            // 有控制台就只打印：弹框是模态的，会阻塞进程（自动化测试里直接卡死过一次），
            // 只在「没有可见输出通道」（--hidden）时才弹。
            if (_console)
            {
                Log.W("[提示] {0} —— {1}", caption, text.Replace("\n", " "));
                return;
            }
            try { MessageBoxW(IntPtr.Zero, text, caption, 0x00000040u /* MB_ICONINFORMATION */); }
            catch (Exception) { }
        }

        public static string Version { get { return BuildInfo.Version; } }

        private static bool _console;

        // ---------- 参数解析 ----------

        private class Args
        {
            public List<string> Flags = new List<string>();
            public Dictionary<string, string> Opts = new Dictionary<string, string>();

            public bool Has(string f) { return Flags.Contains(f); }

            public string Get(string name, string def)
            {
                string v;
                return Opts.TryGetValue(name, out v) ? v : def;
            }

            public int GetInt(string name, int def)
            {
                string v = Get(name, null);
                int n;
                if (v != null && int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) return n;
                return def;
            }

            public bool GetBool(string name, bool def)
            {
                string v = Get(name, null);
                if (v == null) return def;
                v = v.ToLowerInvariant();
                if (v == "1" || v == "true" || v == "on" || v == "yes") return true;
                if (v == "0" || v == "false" || v == "off" || v == "no") return false;
                return def;
            }
        }

        private static Args Parse(string[] args)
        {
            Args a = new Args();
            for (int i = 0; i < args.Length; i++)
            {
                string s = args[i];
                if (!s.StartsWith("--") && !s.StartsWith("-")) { a.Flags.Add(s); continue; }
                string name = s.TrimStart('-');
                int eq = name.IndexOf('=');
                if (eq >= 0)
                {
                    a.Opts[name.Substring(0, eq)] = name.Substring(eq + 1);
                    continue;
                }
                // 后面跟的如果不是选项，就当它的值
                if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
                {
                    a.Opts[name] = args[i + 1];
                    i++;
                }
                else
                {
                    a.Flags.Add(name);
                }
            }
            return a;
        }

        public static string ExeDir()
        {
            try
            {
                string p = System.Reflection.Assembly.GetExecutingAssembly().Location;
                if (!string.IsNullOrEmpty(p)) return Path.GetDirectoryName(p);
            }
            catch (Exception) { }
            return Directory.GetCurrentDirectory();
        }

        // ---------- 同目录 ini 配置（绿色单文件不该逼用户每次敲一长串参数） ----------

        /// <summary>读 exe 同目录的 dshlcd.ini（key=value，# 或 ; 开头是注释）</summary>
        public static Dictionary<string, string> LoadIni(string dir)
        {
            Dictionary<string, string> d = new Dictionary<string, string>();
            try
            {
                string path = Path.Combine(dir, "dshlcd.ini");
                if (!File.Exists(path)) return d;
                string[] lines = File.ReadAllLines(path, Encoding.UTF8);
                for (int i = 0; i < lines.Length; i++)
                {
                    string line = lines[i].Trim();
                    if (line.Length == 0 || line[0] == '#' || line[0] == ';' || line[0] == '[') continue;
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    string k = line.Substring(0, eq).Trim().TrimStart('-');
                    string v = line.Substring(eq + 1).Trim();
                    int hash = v.IndexOf('#');                 // 行尾注释
                    if (hash > 0) v = v.Substring(0, hash).Trim();
                    if (v.Length > 0) d[k] = v;
                }
                if (d.Count > 0) Log.W("已读入 dshlcd.ini（{0} 项）", d.Count);
            }
            catch (Exception ex)
            {
                Log.Err("读 dshlcd.ini 失败：{0}", ex.Message);
            }
            return d;
        }

        /// <summary>把 ini 合并进参数（命令行优先）</summary>
        private static void MergeIni(Args a, string dir)
        {
            Dictionary<string, string> ini = LoadIni(dir);
            foreach (KeyValuePair<string, string> kv in ini)
            {
                if (a.Opts.ContainsKey(kv.Key) || a.Flags.Contains(kv.Key)) continue;
                string v = kv.Value.ToLowerInvariant();
                if (v == "1" || v == "true" || v == "on" || v == "yes") a.Flags.Add(kv.Key);
                else if (v == "0" || v == "false" || v == "off" || v == "no")
                {
                    if (kv.Key == "no-usb" || kv.Key == "no-http" || kv.Key == "night" || kv.Key == "vertical" || kv.Key == "udp-any")
                    {
                        a.Opts[kv.Key] = "0";
                    }
                }
                else a.Opts[kv.Key] = kv.Value;
            }
        }

        /// <summary>把一项写回 dshlcd.ini（保留原有注释与顺序；键不存在则追加）</summary>
        public static void SaveIniValue(string key, string value)
        {
            try
            {
                string path = Path.Combine(ExeDir(), "dshlcd.ini");
                List<string> lines = new List<string>();
                if (File.Exists(path)) lines.AddRange(File.ReadAllLines(path, Encoding.UTF8));
                bool done = false;
                for (int i = 0; i < lines.Count; i++)
                {
                    string t = lines[i].TrimStart();
                    if (t.StartsWith("#") || t.StartsWith(";") || t.StartsWith("[")) continue;
                    int eq = t.IndexOf('=');
                    if (eq <= 0) continue;
                    if (string.Equals(t.Substring(0, eq).Trim().TrimStart('-'), key, StringComparison.OrdinalIgnoreCase))
                    {
                        lines[i] = key + " = " + value;
                        done = true;
                        break;
                    }
                }
                if (!done) lines.Add(key + " = " + value);
                File.WriteAllLines(path, lines.ToArray(), new UTF8Encoding(false));
                Log.W("已写入配置：{0} = {1}（{2}）", key, value, path);
            }
            catch (Exception ex)
            {
                Log.Err("写配置失败（{0} = {1}）：{2}", key, value, ex.Message);
            }
        }

        public static void WriteIniTemplate(string path)
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# dshlcd.ini —— 放在 dshlcd.exe 同目录即可生效（命令行参数优先）");
            sb.AppendLine("# 常用项：");
            sb.AppendLine("");
            sb.AppendLine("# 竖装布局（内容旋转 90°，逻辑 462x1920）");
            sb.AppendLine("vertical = 0");
            sb.AppendLine("");
            sb.AppendLine("# 横装且屏幕倒装时转 180°；留空表示按握手结果自动决定");
            sb.AppendLine("# rotate180 = 1");
            sb.AppendLine("");
            sb.AppendLine("# 夜间窗口 18:30-09:00 降帧到 3 秒一帧（墙上的屏晚上别闪）");
            sb.AppendLine("night = 0");
            sb.AppendLine("");
            sb.AppendLine("# 固定帧间隔（毫秒），注释掉 = 按 agent 状态自适应 66/500ms");
            sb.AppendLine("# interval = 100");
            sb.AppendLine("");
            sb.AppendLine("# VM 监视画面源（livepad 的取帧接口；不填则面板显示占位）");
            sb.AppendLine("# vm-url = http://172.16.101.1:8787/vm/frame.jpg");
            sb.AppendLine("# vm-interval = 1000");
            sb.AppendLine("");
            sb.AppendLine("# 遥测：桥端跑在**别的机器**上时必须是 1（监听 0.0.0.0:54545）");
            sb.AppendLine("# ★ 默认开：本工程的实际用法就是「桥在鸿蒙主机、LCD 挂在 Windows VM 上」，");
            sb.AppendLine("#   不开的话程序只绑 127.0.0.1，收不到跨机遥测（用户反馈「桥连上了没数据」）。");
            sb.AppendLine("#   只有「桥和本程序在同一台机器」时才需要改成 0（绑回环更安全）。");
            sb.AppendLine("udp-any = 1");
            sb.AppendLine("udp-port = 54545");
            sb.AppendLine("");
            sb.AppendLine("# 预览/诊断网页端口（浏览器打开 http://127.0.0.1:54546/ ）");
            sb.AppendLine("http-port = 54546");
            sb.AppendLine("");
            sb.AppendLine("# 只出预览不推屏（调试用）");
            sb.AppendLine("no-usb = 0");
            sb.AppendLine("");
            sb.AppendLine("# 屏型号：0x5408 = LY（9.16 寸），0x5409 = LY1");
            sb.AppendLine("# pid = 0x5408");
            File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
            Log.W("已写出配置模板：{0}", path);
        }

        // ---------- 入口 ----------

        /// <summary>
        /// 单实例互斥体。★ 2026-10-15 新增。
        ///
        /// 为什么必须要有：今天一天里，**三个看起来毫不相关的故障**根因都是"多个实例同时在跑"：
        ///   1. **USB 被占** —— 第二个实例 `libusb_open` 返回 -3（拒绝访问），日志含糊地说
        ///      "设备被别的进程占用"，谁也不会想到是它自己的另一个副本
        ///   2. **UDP 抢包** —— 两个实例都绑 54545（`SO_REUSEADDR` 允许），但每个包只投给其中一个，
        ///      于是后启动的那个"桥连上了却没有数据"
        ///   3. **HTTP 端口冲突** —— 第二个实例 54546 绑不上，只打一行错就继续跑，
        ///      `/diag` 永远读不到，用户以为程序坏了
        /// 加互斥体后第二次启动会直接提示并退出，不再产生这些假象。
        /// </summary>
        private static System.Threading.Mutex _single;

        public static int Main(string[] args)
        {
            // 单实例检查（用 Local\ 前缀：只限当前会话，多用户/终端服务下互不干扰）
            bool createdNew;
            try
            {
                _single = new System.Threading.Mutex(true, @"Local\dshlcd-single-instance", out createdNew);
            }
            catch (Exception)
            {
                createdNew = true;      // 拿不到互斥体也不该拦住启动
            }
            if (!createdNew)
            {
                string msg = "dshlcd 已经在运行了（同一个实例不能用两个）。\n\n"
                    + "同时开两个会造成：USB 被占用、UDP 遥测收不到、HTTP 端口冲突。\n"
                    + "请先用任务管理器结束已有的 dshlcd.exe，或者用命令行：\n"
                    + "    taskkill /IM dshlcd.exe /F\n";
                try { System.Windows.Forms.MessageBox.Show(msg, "dshlcd", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Warning); }
                catch (Exception) { }
                return 2;
            }

            Args a = Parse(args);
            MergeIni(a, ExeDir());                      // exe 同目录 dshlcd.ini 先落地，命令行优先
            // 默认开图形界面（对齐鸿蒙版那种"能看画面、能切横竖屏"的操作面）。
            // 想要原来的控制台模式加 --console；想要纯后台静默加 --hidden。
            bool wantGui = !a.Has("console") && !a.Has("c") && !a.Has("hidden")
                && !a.Has("no-gui") && !a.Has("q");
            _console = !a.Has("hidden") && !a.Has("q") && !a.Has("no-gui");
            if (_console)
            {
                AllocConsole();
                try { SetConsoleOutputCP(65001); } catch (Exception) { }
            }

            string logPath = a.Get("log", null);
            if (string.IsNullOrEmpty(logPath)) logPath = Path.Combine(ExeDir(), "dshlcd.log");
            Log.Open(logPath);

            Log.W("dshlcd {0}  构建：{1}", Version, BuildInfo.Stamp);
            Log.W("exe   : {0}", System.Reflection.Assembly.GetExecutingAssembly().Location);
            Log.W("日志  : {0}", logPath);
            Log.W("系统  : {0}  64位进程={1}  CPU 核数={2}", Environment.OSVersion.VersionString,
                Environment.Is64BitProcess, Environment.ProcessorCount);

            try
            {
                if (a.Has("selftest") || a.Has("t"))
                {
                    int fails = SelfTest.Run();
                    Log.W(fails == 0 ? "自检全部通过" : string.Format("自检有 {0} 项失败", fails));
                    return fails == 0 ? 0 : 1;
                }

                if (a.Has("vm-probe"))
                {
                    List<string> cands = VmProbe.ParseList(a.Get("vm-probe", ""));
                    cands.AddRange(VmProbe.DefaultCandidates(VmProbe.DefaultPort));
                    if (a.Opts.ContainsKey("vm-url")) cands.InsertRange(0, VmProbe.ParseList(a.Get("vm-url", "")));
                    bool scan = !a.Has("no-scan");
                    string report;
                    string hit = VmProbe.Probe(cands, scan, out report);
                    Log.W(report);
                    Log.W(hit == null ? "结论：没找到可用的 VM 监视地址" : "结论：可用地址 = " + hit);
                    if (hit != null) SaveIniValue("vm-url", hit);
                    Log.W("探测结束");
                    return hit == null ? 1 : 0;
                }

                if (a.Has("doctor"))
                {
                    return Doctor(a);
                }

                if (a.Has("write-ini"))
                {
                    WriteIniTemplate(Path.Combine(ExeDir(), "dshlcd.ini"));
                    return 0;
                }

                if (a.Has("probe"))
                {
                    WinUsb.ProbeReport();
                    Log.W("探测结束");
                    return 0;
                }

                if (a.Has("help") || a.Has("h"))
                {
                    Usage();
                    return 0;
                }

                Settings cfg = BuildSettings(a);
                if (cfg == null) { Usage(); return 2; }

                if (a.Has("gui-shot") || a.Opts.ContainsKey("gui-shot"))
                {
                    // 必须在 BuildSettings 之后：这里要用 cfg
                    return RunGuiShot(cfg, a.Get("gui-shot", "gui.png"), a.GetInt("seconds", 6));
                }

                if (a.Has("first-contact"))
                {
                    // 必须在 BuildSettings 之后（要用 cfg）
                    return FirstContact(cfg, a.GetInt("seconds", 3));
                }

                if (a.Has("render"))
                {
                    return RenderOnce(cfg, a.Get("render", "frame.jpg"));
                }

                if (a.Has("demo"))
                {
                    return RunDemo(cfg, a);
                }

                if (wantGui && !a.Has("gui-shot") && !a.Opts.ContainsKey("gui-shot"))
                {
                    return RunGui(cfg);
                }

                return RunForever(cfg);
            }
            catch (Exception ex)
            {
                Log.Err("未捕获异常：{0}", ex.ToString());
                Popup("dshlcd 启动失败，已记录到日志：\n" + ex.Message
                    + "\n\n日志：" + logPath, "dshlcd 启动失败");
                return 3;
            }
        }

        private static Settings BuildSettings(Args a)
        {
            Settings cfg = new Settings();
            cfg.Vertical = a.Has("vertical") || a.GetBool("vertical", false);
            if (a.Opts.ContainsKey("rotate180"))
            {
                cfg.Rotate180 = a.GetBool("rotate180", true);
                cfg.Rotate180Forced = true;
            }
            cfg.NightEnabled = a.Has("night") || a.GetBool("night", false);
            cfg.ForcedIntervalMs = a.GetInt("interval", 0);

            // ---- 主题 / 版面 / 背景 / 极速（本轮新增；与 /set 的同名键对应）----
            // ★ 必须在 BuildSettings 里读 ini 合并后的 Args —— 否则 Gui 里 SaveIniValue
            //   存下来的选择**下次启动读不回来**（这是"存了不生效"的典型成因）。
            cfg.Theme = Themes.Clamp(a.GetInt("theme", 0));
            cfg.Burst = a.Has("burst") || a.GetBool("burst", false);
            string pc = a.Get("printer-cell", "printer");
            if (pc != null)
            {
                string pcl = pc.Trim().ToLowerInvariant();
                if (pcl == "printer" || pcl == "v6" || pcl == "v4" || pcl == "dotii")
                {
                    cfg.PrinterCell = pcl;
                }
            }
            string bgs = a.Get("bg-style", "");
            if (!string.IsNullOrEmpty(bgs))
            {
                Backdrop.Current = Backdrop.FromName(bgs);
            }
            cfg.HttpPort = a.GetInt("http-port", MiniHttp.DefaultPort);
            cfg.UdpPort = a.GetInt("udp-port", TelemetryReceiver.DefaultPort);
            cfg.UdpAny = a.Has("udp-any") || a.GetBool("udp-any", false);
            string vmUrl = a.Get("vm-url", "");
            // "none"/"-" 表示明确不要 VM 画面：命令行优先于 ini，
            // 这样验证脚本不必去改/删 exe 同目录的 ini（实测主机侧改名对
            // 运行中的客户机不可见，只有写入才会立刻生效）
            cfg.VmUrl = (vmUrl == "none" || vmUrl == "-") ? "" : vmUrl;
            cfg.VmIntervalMs = a.GetInt("vm-interval", 1000);
            cfg.NoUsb = a.Has("no-usb") || a.GetBool("no-usb", false);
            cfg.NoHttp = a.Has("no-http") || a.GetBool("no-http", false);
            // 拓竹云取数（本进程内直连 MQTT）。默认开；--no-bambu 关掉；
            // --bambu-config <路径> 指定凭据文件（默认见 BambuConfig.ResolvePath）
            cfg.BambuEnabled = !a.Has("no-bambu") && !a.GetBool("no-bambu", false);
            cfg.BambuConfigPath = a.Get("bambu-config", null);
            // MQTT 包级追踪（排查连接/订阅问题时用）。
            // 输出量很大（每个包一行），所以默认关。
            MqttClient.Diagnostic = a.Has("mqtt-debug") || a.GetBool("mqtt-debug", false);
            cfg.LogPath = a.Get("log", null);
            string pid = a.Get("pid", null);
            if (!string.IsNullOrEmpty(pid))
            {
                int p;
                if (pid.StartsWith("0x")) int.TryParse(pid.Substring(2), NumberStyles.HexNumber, null, out p);
                else int.TryParse(pid, out p);
                cfg.Pid = p;
            }
            return cfg;
        }

        private static int RenderOnce(Settings cfg, string outPath)
        {
            Log.W("单帧渲染模式：{0}（{1}）", outPath, cfg.Vertical ? "竖屏 462x1920" : "横向 1920x462");
            LcdRunner r = new LcdRunner(cfg);
            byte[] jpg = r.RenderOnce();
            if (jpg == null || jpg.Length == 0)
            {
                Log.Err("渲染失败：没有产生 JPEG");
                return 1;
            }
            string full = Path.IsPathRooted(outPath) ? outPath : Path.Combine(ExeDir(), outPath);
            File.WriteAllBytes(full, jpg);
            int w, h;
            Ly.ParseJpegSize(jpg, out w, out h);
            Log.W("已写出 {0}：{1} 字节，JPEG {2}x{3}，编码 {4} ms", full, jpg.Length, w, h, Math.Round(r.EncodeMs, 1));
            DumpBandStats(jpg);
            return 0;
        }

        /// <summary>
        /// 分区像素统计：把帧分成若干竖条，统计每条的"非背景色像素数"，
        /// 用来在没有眼睛的情况下确认"每个面板都真的画了东西"。
        /// </summary>
        public static void DumpBandStats(byte[] jpeg)
        {
            try
            {
                using (MemoryStream ms = new MemoryStream(jpeg))
                using (Bitmap bmp = new Bitmap(ms))
                {
                    int W = bmp.Width, H = bmp.Height;
                    // 一定要走 LockBits：GetPixel 是逐点跨托管边界往返，
                    // 1920x462 上按 8 带采样要 180 万次调用，能拖十几秒
                    // （实测把整个演示卡住、日志被提前读走、端口还被占着）。
                    System.Drawing.Imaging.BitmapData bd = bmp.LockBits(
                        new Rectangle(0, 0, W, H), System.Drawing.Imaging.ImageLockMode.ReadOnly,
                        System.Drawing.Imaging.PixelFormat.Format24bppRgb);
                    try
                    {
                        int stride = bd.Stride;
                        byte[] buf = new byte[stride * H];
                        System.Runtime.InteropServices.Marshal.Copy(bd.Scan0, buf, 0, buf.Length);

                        int bands = 8;
                        int bw = W / bands;
                        Log.W("分区像素统计（{0}x{1}，按 {2} 条竖带）:", W, H, bands);
                        for (int b = 0; b < bands; b++)
                        {
                            int x0 = b * bw;
                            int x1 = (b == bands - 1) ? W : x0 + bw;
                            int nonBg = 0, total = 0;
                            long sumR = 0, sumG = 0, sumB = 0;
                            for (int y = 0; y < H; y += 2)
                            {
                                int row = y * stride;
                                for (int x = x0; x < x1; x += 2)
                                {
                                    int o = row + x * 3;
                                    int bb = buf[o], gg = buf[o + 1], rr = buf[o + 2];
                                    total++;
                                    sumR += rr; sumG += gg; sumB += bb;
                                    if (rr > 24 || gg > 26 || bb > 40) nonBg++;
                                }
                            }
                            double pct = total == 0 ? 0 : nonBg * 100.0 / total;
                            Log.W("  x{0,4}-{1,4}: 非背景 {2,5} / {3,5} ({4,5:F1}%)  平均色 #{5:X2}{6:X2}{7:X2}",
                                x0, x1, nonBg, total, pct,
                                total == 0 ? 0 : (int)(sumR / total), total == 0 ? 0 : (int)(sumG / total),
                                total == 0 ? 0 : (int)(sumB / total));
                        }
                    }
                    finally
                    {
                        bmp.UnlockBits(bd);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Err("分区统计失败：{0}", ex.Message);
            }
        }

        // ---------- 演示模式（合成遥测，验证整条链路） ----------

        private static int RunDemo(Settings cfg, Args a)
        {
            int seconds = a.GetInt("seconds", 8);
            string outFrame = a.Get("out-frame", null);
            bool selfHttp = !a.Has("no-self-http");
            if (!a.Opts.ContainsKey("no-usb")) cfg.NoUsb = true;   // 演示默认不碰 USB

            Log.W("演示模式：合成遥测 + 完整渲染/编码链路，跑 {0} 秒", seconds);
            LcdRunner r = new LcdRunner(cfg);
            r.Start();

            Thread feeder = new Thread(delegate()
            {
                int n = 0;
                while (n < seconds * 4)
                {
                    r.Telemetry.ApplyText(DemoTelemetryJson(n));
                    n++;
                    Thread.Sleep(250);
                }
            });
            feeder.IsBackground = true;
            feeder.Start();

            if (selfHttp)
            {
                Thread.Sleep(1500);
                if (r.HttpRunning)
                {
                    HttpSelfTest(cfg.HttpPort);
                }
                else
                {
                    // 端口被别人占了（比如同一目录里还有另一个实例）：
                    // 这时去打 127.0.0.1:54546 会打到**别人**身上，把别人的配置改掉
                    // —— 子代理实测踩到过（?vertical=0 关掉了另一个实例的竖屏）。
                    Log.W("跳过 HTTP 自测：本实例没抢到 {0} 端口（避免误改另一个实例的配置）", cfg.HttpPort);
                }
            }

            long t0 = State.NowMs();
            while (State.NowMs() - t0 < seconds * 1000L)
            {
                Thread.Sleep(200);
            }

            byte[] jpg = r.GetJpeg();
            int w = 0, h = 0;
            if (jpg != null) Ly.ParseJpegSize(jpg, out w, out h);
            Log.W("演示结果：帧数={0} 已推={1} 错误={2} JPEG={3}x{4} {5} 字节 编码质量={6}",
                r.Frames, r.Sent, r.Errors, w, h, jpg == null ? 0 : jpg.Length, r.Quality);
            Log.W("耗时统计：渲染 {0} ms / 编码 {1} ms / 推帧 {2} ms",
                Math.Round(r.RenderMs, 2), Math.Round(r.EncodeMs, 2), Math.Round(r.PushMs, 2));
            Log.W("遥测：收到 {0} 包，最近错误={1}", r.Telemetry.Packets,
                string.IsNullOrEmpty(r.Telemetry.LastError) ? "(无)" : r.Telemetry.LastError);
            Log.W("/diag = {0}", r.DiagJson());

            // 先把图落盘再做像素统计：统计很慢（且是给人看的），
            // 落盘早一步，外部脚本就不必等它。
            if (!string.IsNullOrEmpty(outFrame))
            {
                string full = Path.IsPathRooted(outFrame) ? outFrame : Path.Combine(ExeDir(), outFrame);
                File.WriteAllBytes(full, jpg);
                Log.W("已写出 {0}（{1} 字节）", full, jpg.Length);
            }
            if (jpg != null) DumpBandStats(jpg);
            Log.W("演示结束");

            r.Stop();
            return 0;
        }

        /// <summary>在进程内自测自己的 HTTP 接口（跨机器验证 VM 服务是否真的可用）</summary>
        private static string HttpGet(string url)
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Timeout = 5000;
            req.Proxy = null;
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            using (Stream s = resp.GetResponseStream())
            using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
            {
                return sr.ReadToEnd();
            }
        }

        private static void HttpSelfTest(int port)
        {
            string[] paths = new string[]
            {
                "/status", "/diag", "/frame.jpg", "/set?vertical=1", "/set?vertical=0",
                "/", "/preview", "/probe", "/nope"
            };
            // 自测会调 /set 验证接口，但那是**改配置**的接口：测完必须还原，
            // 否则 --vertical 1 的演示会被自测打回横屏（子代理实测踩到过）
            bool verticalBefore = false;
            try
            {
                string diag = HttpGet("http://127.0.0.1:" + port + "/diag");
                verticalBefore = diag.IndexOf("\"vertical\":true") >= 0;
            }
            catch (Exception) { }

            Log.W("──── HTTP 自测（127.0.0.1:{0}）────", port);
            for (int i = 0; i < paths.Length; i++)
            {
                try
                {
                    HttpWebRequest req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + paths[i]);
                    req.Timeout = 5000;
                    req.Proxy = null;
                    using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                    using (Stream s = resp.GetResponseStream())
                    using (MemoryStream ms = new MemoryStream())
                    {
                        byte[] buf = new byte[16384];
                        int n;
                        while ((n = s.Read(buf, 0, buf.Length)) > 0) ms.Write(buf, 0, n);
                        byte[] body = ms.ToArray();
                        string preview = "";
                        if (paths[i] != "/frame.jpg" && body.Length > 0)
                        {
                            preview = Encoding.UTF8.GetString(body, 0, Math.Min(body.Length, 220)).Replace("\r", " ").Replace("\n", " ");
                        }
                        Log.W("  {0,-22} -> HTTP {1} {2} 字节 {3}", paths[i], (int)resp.StatusCode, body.Length, preview);
                    }
                }
                catch (WebException we)
                {
                    Log.Err("  {0,-22} -> 异常 {1}", paths[i], we.Message);
                }
                catch (Exception ex)
                {
                    Log.Err("  {0,-22} -> 异常 {1}", paths[i], ex.Message);
                }
            }

            // 还原自测期间被改掉的配置
            try
            {
                HttpGet("http://127.0.0.1:" + port + "/set?vertical=" + (verticalBefore ? "1" : "0"));
                Log.W("  （已还原 vertical={0}）", verticalBefore ? 1 : 0);
            }
            catch (Exception) { }
        }

        /// <summary>合成遥测（JSON 文本走真实的解析/归一化路径，别绕过它）</summary>
        private static string DemoTelemetryJson(int n)
        {
            string[] states = new string[] { "busy", "busy", "waiting", "idle" };
            string state = states[n % states.Length];
            string[] acts = new string[] { "Thinking…", "Running bash…", "Reading files…", "空闲" };
            string act = acts[n % acts.Length];
            long inTok = 12000 + n * 137;
            long outTok = 3400 + n * 29;
            string[] todoS = new string[] { "completed", "completed", "in_progress", "pending", "pending" };
            StringBuilder sb = new StringBuilder();
            sb.Append("{");
            sb.Append("\"ts\":").Append(State.NowMs()).Append(",");
            sb.Append("\"agent\":{\"state\":\"").Append(state).Append("\",\"activity\":\"").Append(act)
              .Append("\",\"tool\":\"bash\",\"project\":\"TrofeoLCD 副屏工程\",\"model\":\"deepseek-v4-flash\",")
              .Append("\"provider\":\"deepseek\",\"turn\":").Append(1 + n / 4).Append(",\"step\":").Append(n % 7 + 1)
              .Append(",\"lastText\":\"正在把渲染器移植到 Windows\"},");
            sb.Append("\"tokens\":{\"todayInput\":").Append(inTok).Append(",\"todayOutput\":").Append(outTok)
              .Append(",\"sessionTotal\":").Append(inTok + outTok).Append(",\"contextUsed\":").Append(48000 + n * 900)
              .Append(",\"contextWindow\":200000,\"costUsd\":").Append((0.42 + n * 0.001).ToString("0.###", CultureInfo.InvariantCulture))
              .Append(",\"cacheHitRate\":0.71},");
            sb.Append("\"todos\":[");
            for (int i = 0; i < todoS.Length; i++)
            {
                if (i > 0) sb.Append(",");
                sb.Append("{\"content\":\"任务 ").Append(i + 1).Append("：移植/验证第 ").Append(i + 1)
                  .Append(" 块\",\"status\":\"").Append(todoS[i]).Append("\"}");
            }
            sb.Append("],");
            sb.Append("\"system\":{\"cpu\":").Append(20 + (n % 5) * 12).Append(",\"cores\":8,\"memUsed\":")
              .Append(4200 + (n % 9) * 40).Append(",\"memTotal\":8192,\"load1\":1.2,\"uptimeSec\":7200,")
              .Append("\"host\":\"WIN11-ARM64-VM\",\"cpuTemp\":-1},");
            sb.Append("\"weather\":{\"text\":\"多云\",\"tempC\":21},");
            sb.Append("\"lyrics\":{\"line\":\"副屏也要有副屏的样子\",\"artist\":\"Desktop\",\"title\":\"LCD 9.16\"},");
            // 打印机段：四种状态轮流出现，面板的每个分支都能被跑到
            string pstate = (n % 40 < 30) ? "RUNNING" : ((n % 40 < 34) ? "PAUSE" : ((n % 40 < 37) ? "IDLE" : "FAILED"));
            int pct2 = 30 + (n % 60);
            sb.Append("\"printer\":{\"state\":\"").Append(pstate).Append("\",\"stateLabel\":\"")
              .Append(pstate == "RUNNING" ? "打印中" : (pstate == "PAUSE" ? "已暂停" : (pstate == "IDLE" ? "空闲" : "失败")))
              .Append("\",\"connected\":true,\"online\":true,\"model\":\"P2S 0.4mm\",\"jobName\":\"BambuHelper_panel_test.gcode.3mf\",")
              .Append("\"percent\":").Append(pct2).Append(",\"layer\":").Append(pct2 * 3).Append(",\"totalLayer\":300,")
              .Append("\"remainingSec\":").Append(Math.Max(0, (100 - pct2) * 42)).Append(",\"eta\":\"14:35\",")
              .Append("\"nozzleTemp\":219,\"nozzleTarget\":220,\"bedTemp\":60,\"bedTarget\":60,\"chamberTemp\":34,")
              .Append("\"wifi\":\"-52\",\"coolingFan\":80,\"heatbreakFan\":60,\"speedLevel\":2,\"trayNow\":1,")
              .Append(pstate == "FAILED" ? "\"printError\":83951617,\"hms\":[{\"code\":\"0300_0100_0001_0001\"},{\"code\":\"x\"}]," : "\"printError\":0,\"hms\":[],")
              .Append("\"trays\":[{\"index\":1,\"type\":\"PLA\",\"color\":\"FF3B30FF\",\"remain\":78},")
              .Append("{\"index\":2,\"type\":\"PETG\",\"color\":\"34C759FF\",\"remain\":46},")
              .Append("{\"index\":3,\"type\":\"ABS\",\"color\":\"0A84FFFF\",\"remain\":91},")
              .Append("{\"index\":4,\"type\":\"TPU\",\"color\":\"FFCC00FF\",\"remain\":12}]}");
            sb.Append("}");
            return sb.ToString();
        }

        // ---------- 正式运行 ----------

        private static int RunForever(Settings cfg)
        {
            Log.W("正式运行：竖屏={0} rotate180={1} 夜间={2} VM={3} USB={4} HTTP={5}",
                cfg.Vertical, cfg.Rotate180, cfg.NightEnabled,
                string.IsNullOrEmpty(cfg.VmUrl) ? "(无)" : cfg.VmUrl,
                cfg.NoUsb ? "关闭" : "开启", cfg.NoHttp ? "关闭" : cfg.HttpPort.ToString());
            LcdRunner r = new LcdRunner(cfg);
            r.Start();
            Log.W("按 Ctrl+C 退出（后台运行时直接结束进程）");

            // 标准输入关闭（winexe）时只靠信号退出
            ManualResetEvent stop = new ManualResetEvent(false);
            Console.CancelKeyPress += delegate(object s, ConsoleCancelEventArgs e)
            {
                e.Cancel = true;
                stop.Set();
            };
            try
            {
                while (!stop.WaitOne(1000))
                {
                    // 每 30 秒打一条心跳，方便看日志判断"是不是真在跑"
                    if (r.Frames % 1 == 0 && r.Frames > 0 && r.Frames % 60 == 0)
                    {
                        // 只在帧数变化时打印（避免刷屏）
                    }
                }
            }
            catch (Exception) { }
            r.Stop();
            return 0;
        }

        /// <summary>
        /// 环境自检：把"为什么没反应/跑不起来"需要的信息一次问清楚。
        /// 输出的第一句就是结论，用户可以直接照做或把日志发出来。
        /// </summary>
        private static int Doctor(Args a)
        {
            StringBuilder sb = new StringBuilder();
            string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
            sb.AppendLine("== dshlcd 环境自检 ==");
            sb.AppendLine("时间      : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("exe       : " + exe);
            sb.AppendLine("日志      : " + Log.Path);
            sb.AppendLine("系统      : " + Environment.OSVersion.VersionString);
            sb.AppendLine("进程位数  : " + (Environment.Is64BitProcess ? "64 位" : "32 位"));
            sb.AppendLine("操作系统位: " + (Environment.Is64BitOperatingSystem ? "64 位" : "32 位"));
            sb.AppendLine("CPU 核数  : " + Environment.ProcessorCount);
            sb.AppendLine("CLR 版本  : " + Environment.Version.ToString());
            sb.AppendLine("PE 架构   : " + (Environment.Is64BitProcess ? "当前以 64 位 CLR 运行" : "当前以 32 位 CLR 运行"));

            // 日志目录可写？（拷到只读位置时这是最常见的"静默失败"）
            bool logWritable = false;
            try
            {
                string dir = ExeDir();
                string probe = Path.Combine(dir, ".dshlcd-write-test");
                File.WriteAllText(probe, "ok");
                File.Delete(probe);
                logWritable = true;
            }
            catch (Exception) { }
            sb.AppendLine("exe 目录可写 : " + (logWritable ? "是" : "否 —— 日志会写到 %TEMP%"));

            // 端口占用
            sb.AppendLine("UDP " + TelemetryReceiver.DefaultPort + " : " + (PortFree(true, TelemetryReceiver.DefaultPort) ? "空闲" : "被占用"));
            sb.AppendLine("HTTP " + MiniHttp.DefaultPort + " : " + (PortFree(false, MiniHttp.DefaultPort) ? "空闲" : "被占用"));

            // 屏幕
            sb.AppendLine("USB       : " + WinUsb.ProbeReport().Trim().Replace("\r\n", " / ").Replace("\n", " / "));

            sb.AppendLine();
            sb.AppendLine("== 结论 ==");
            sb.AppendLine("· 若「双击没反应」：本程序默认是控制台程序，双击应弹出一个黑窗口并持续打印状态；");
            sb.AppendLine("  如果连黑窗口都没有，说明被系统拦了（SmartScreen/杀软）或不是本文件。");
            sb.AppendLine("· 若「未找到 LY 屏」：属正常（没有插屏），预览页仍可用。");
            sb.AppendLine("· 若端口被占用：加 --http-port 54547 --udp-port 54546 换端口。");

            Log.W(sb.ToString());
            Popup("自检完成，结论已写入日志：\n" + Log.Path
                + "\n\n若双击没反应，请把这个日志发我。", "dshlcd 自检完成");
            return 0;
        }

        private static bool PortFree(bool udp, int port)
        {
            try
            {
                if (udp)
                {
                    System.Net.Sockets.UdpClient u = new System.Net.Sockets.UdpClient();
                    u.Client.SetSocketOption(System.Net.Sockets.SocketOptionLevel.Socket,
                        System.Net.Sockets.SocketOptionName.ReuseAddress, false);
                    u.Client.Bind(new System.Net.IPEndPoint(System.Net.IPAddress.Loopback, port));
                    u.Close();
                    return true;
                }
                System.Net.Sockets.TcpListener t = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
                t.Start();
                t.Stop();
                return true;
            }
            catch (Exception) { return false; }
        }

        /// <summary>
        /// 首次连接自检（插上屏第一件事就跑它）：
        /// 枚举 → 打开 → 握手（打印 PM/SUB/FBL/分辨率/旋转）→ 推测试帧 → 读 ACK → 报耗时。
        /// 每一步失败都给出下一步该怎么办。
        /// </summary>
        private static int FirstContact(Settings cfg, int seconds)
        {
            Log.W("===== 首次连接自检 =====");
            string probe = WinUsb.ProbeReport();
            WinUsb.LyDevice dev = WinUsb.Open(Ly.VendorId, cfg.Pid);
            if (dev == null)
            {
                Log.Err("第 1 步失败：没打开设备。检查：①屏插上了吗 ②设备管理器里是不是 WinUSB/通用串行总线设备（不是 HID 键盘）③VID/PID 是否 0x0416:0x5408");
                Log.W("探测结果：{0}", probe.Trim());
                return 1;
            }
            Log.W("第 1 步 OK：打开成功（{0}）", dev.HardwareId);
            int pidHint = dev.Pid == Ly.PidLy1 ? Ly.PidLy1 : Ly.PidLy;
            DeviceInfo info = WinUsb.Handshake(dev, pidHint);
            if (info == null)
            {
                Log.Err("第 2 步失败：握手没通过。可能原因：①PID 猜错（改 --pid 0x5409 试 LY1）②端点选错（见上面日志的 OUT 管道）③设备需要先发别的初始化包");
                dev.Dispose();
                return 2;
            }
            Log.W("第 2 步 OK：{0}", info.ToString());
            Log.W("  → 如果 Width/Height 与 1920x462 不同，程序会自动缩放适配（已实现）");

            LcdRunner r = new LcdRunner(cfg);
            r.Start();
            Thread.Sleep(Math.Max(1500, seconds * 1000));
            byte[] jpg = r.GetJpeg();
            if (jpg == null)
            {
                Log.Err("第 3 步失败：本地没渲染出帧（看上面日志）");
                r.Stop(); dev.Dispose();
                return 3;
            }
            Log.W("第 3 步：本地帧就绪 {0} 字节，开始推给屏…", jpg.Length);
            string ack;
            bool ok = WinUsb.PushJpeg(dev, jpg, pidHint, out ack);
            Log.W(ok ? "第 4 步 OK：{0}" : "第 4 步失败：{0}", ack);
            Log.W("耗时：渲染 {0}ms 编码 {1}ms", Math.Round(r.RenderMs, 1), Math.Round(r.EncodeMs, 1));
            Log.W(ok
                ? "结论：链路通了，接下来直接跑 dshlcd.exe 即可（屏幕应已显示刚才那一帧）"
                : "结论：写管道通了但流程不对，把本日志发我");
            r.Stop();
            dev.Dispose();
            return ok ? 0 : 4;
        }

        /// <summary>正式运行 + 图形界面</summary>
        private static int RunGui(Settings cfg)
        {
            Log.W("启动图形界面（无界面模式：--console 或 --hidden）");
            LcdRunner r = new LcdRunner(cfg);
            r.Start();
            GuiForm f = new GuiForm(r);
            System.Windows.Forms.Application.Run(f);
            r.Stop();
            Log.W("界面已关闭，进程退出");
            return 0;
        }

        /// <summary>
        /// 跑界面若干秒后自动截图并退出 —— 给"没有眼睛"的自动化验证用
        /// （在虚拟机上确认界面真的画出来了，而不是只编译通过）。
        /// </summary>
        private static int RunGuiShot(Settings cfg, string outPath, int seconds)
        {
            Log.W("图形界面快照模式：跑 {0} 秒后写 {1}", seconds, outPath);
            LcdRunner r = new LcdRunner(cfg);
            r.Start();
            GuiForm f = new GuiForm(r);
            // 注意：本文件 using 了 System.Threading，Timer 会解析成 Threading.Timer，
            // 所以这里必须全限定成 WinForms 的那个（它才有 Tick 事件）
            System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
            t.Interval = Math.Max(1500, seconds * 1000);
            t.Tick += delegate(object s, EventArgs e)
            {
                t.Stop();
                f.Shot(outPath);
                System.Windows.Forms.Application.Exit();
            };
            t.Start();
            System.Windows.Forms.Application.Run(f);
            r.Stop();
            Log.W("快照模式结束");
            return 0;
        }

        private static void Usage()
        {
            Log.W("");
            Log.W("dshlcd.exe —— 利民 Trofeo Vision 9.16 LCD 控制端（Windows 绿色版）");
            Log.W("");
            Log.W("用法：dshlcd.exe [模式] [选项]");
            Log.W("");
            Log.W("模式：");
            Log.W("  --selftest                跑协议/调度/归一化自检（结果写进日志）");
            Log.W("  --first-contact           首次连接自检：打开→握手→推一帧→读 ACK（插上屏先跑这个）");
            Log.W("  --probe                   列出 USB 设备并尝试打开 LY 屏（无屏也能跑，用于验证枚举）");
            Log.W("  --render <文件.jpg>       用本机系统数据渲染一帧并写文件（不推屏）");
            Log.W("  --demo                    合成遥测跑完整链路，默认 8 秒后退出（自带 HTTP 自测）");
            Log.W("  （不加模式）              正式运行：遥测 → 渲染 → 推屏 + 网页预览");
            Log.W("");
            Log.W("选项：");
            Log.W("  --vertical 0|1            竖装布局（内容旋转 90°，逻辑 462x1920）");
            Log.W("  --rotate180 0|1           内容再转 180°（横装时屏幕倒装用；默认按握手结果）");
            Log.W("  --night 0|1               夜间窗口 18:30-09:00 降帧到 3 秒一帧");
            Log.W("  --interval <ms>           固定帧间隔（0=按 agent 状态自适应 66/500ms）");
            Log.W("  --vm-url <url>            VM 画面源，例如 http://172.16.101.1:8787/vm/frame.jpg");
            Log.W("                           传 none 可显式关闭（覆盖 ini 里的设置）");
            Log.W("  --vm-interval <ms>        VM 画面抓取间隔（默认 1000）");
            Log.W("  --http-port <n>           预览/诊断端口（默认 54546，0 表示关闭）");
            Log.W("  --udp-port <n>            遥测端口（默认 54545）");
            Log.W("  --udp-any                 遥测监听 0.0.0.0（桥端在别的机器上时用）");
            Log.W("  --no-usb                  只出预览，不推屏");
            Log.W("  --no-http                 不开预览服务");
            Log.W("  --pid 0x5408              指定 PID（默认 LY 0x5408，0x5409 是 LY1）");
            Log.W("  --no-bambu                关掉拓竹云取数（默认开，没配凭据时自动跳过）");
            Log.W("  --bambu-config <文件>     拓竹凭据 JSON 路径（默认 %ProgramData%\\dshlcd\\bambu.json）");
            Log.W("  --mqtt-debug              打印 MQTT 包级追踪（排查连接/订阅问题）");
            Log.W("  --seconds <n>             演示模式跑多久");
            Log.W("  --out-frame <文件.jpg>    演示模式把最后一帧写出来");
            Log.W("  --doctor                  自检运行环境（系统/架构/端口/屏幕/权限）并给出结论");
            Log.W("  版本                      日志首行会打印 版本号 + 构建时间 + 源码指纹，便于确认跑的是哪一份");
            Log.W("  --vm-probe [地址...]      探测 VM 监视地址（候选 + 扫本网段 8787），找到就写回 ini");
            Log.W("                            VM 地址随环境变：虚拟机内用 172.16.101.1，局域网机器用平板 IP");
            Log.W("  --hidden                  不显示任何窗口（纯后台静默运行）");
            Log.W("  --console                 用控制台模式（不弹图形界面）");
            Log.W("  --gui-shot <文件.png>     开界面跑几秒后截图退出（自动化验证用）");
            Log.W("  --write-ini               在 exe 同目录生成 dshlcd.ini 配置模板");
            Log.W("  --console                 附加控制台窗口看日志");
            Log.W("  --log <文件>              指定日志文件（默认 exe 同目录 dshlcd.log）");
            Log.W("");
        }
    }
}
