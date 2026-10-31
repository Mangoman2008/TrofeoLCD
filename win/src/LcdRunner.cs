using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Text;
using System.Threading;

namespace DshLcd
{
    /// <summary>运行参数（命令行 + /set 都能改）</summary>
    public class Settings
    {
        public bool Vertical;
        /// <summary>
        /// 整帧旋转 180°。默认 false —— 同型号开源驱动在真机上验证过
        /// "按握手自动旋转"的启发式不可靠（PM=65/SUB=3 开 180° 反而倒），改为纯手动开关。
        /// </summary>
        public bool Rotate180 = false;
        /// <summary>用户是否显式指定过 rotate180（指定了就不被握手结果覆盖）</summary>
        public bool Rotate180Forced;
        public bool NightEnabled;
        /// <summary>0 = 按 agent 状态自适应</summary>
        public int ForcedIntervalMs;
        /// <summary>
        /// 当前主题号（对齐 ArkTS 的 theme 0..15）。
        /// 0 = 仪表盘（老版式，默认）；11~15 为本次移植的二次元系列。
        /// 未移植的主题在 Themes.Dispatch 里**诚实回落**到仪表盘，不画空白。
        /// </summary>
        public int Theme;
        /// <summary>
        /// 极速模式（对齐 ArkTS 的 burst）：把帧间隔改成"减去本帧耗时"。
        /// ArkTS 侧实测 5.06 → 15.1fps（同机同主题）。
        /// </summary>
        public bool Burst;
        /// <summary>打印机格显示内容：printer（真打印机卡）/ v6（Dotii 在最右）/ v4 / dotii</summary>
        public string PrinterCell = "printer";
        public int HttpPort = MiniHttp.DefaultPort;
        public int UdpPort = TelemetryReceiver.DefaultPort;
        public bool UdpAny;
        public string VmUrl;
        public int VmIntervalMs = 1000;
        public bool NoUsb;
        public bool NoHttp;
        public int Pid;                       // 0 = LY/LY1 都收
        public string LogPath;
        public int MaxWidth = 1920;
        public int MaxHeight = 462;   // 9.16 帧高

        /// <summary>
        /// 拓竹云取数：本进程内直连 MQTT，**不依赖 Node 的 bambu-monitor**。
        /// ★ 2026-10-15 新增。`BambuConfigPath` 为空时按 BambuConfig.ResolvePath 的规则查找。
        /// </summary>
        public bool BambuEnabled = true;
        public string BambuConfigPath;
    }

    /// <summary>
    /// 主运行器：遥测 → 渲染 → 编码 → 推屏，外加诊断/预览服务。
    /// 结构照搬鸿蒙版 LcdService 的帧循环（自适应帧率、USB 退避、画质阶梯都一样）。
    /// </summary>
    public class LcdRunner
    {
        private readonly Settings _cfg;
        private readonly State _st = new State();

        private TelemetryReceiver _udp;
        private VmSource _vm;
        private MiniHttp _http;
        private WinUsb.LyDevice _dev;
        private readonly Schedule.UsbAttemptState _usb = new Schedule.UsbAttemptState();
        private readonly Schedule.NightWindow _nightWin = new Schedule.NightWindow(18, 30, 9, 0);

        private Thread _loop;
        private volatile bool _running;

        /// <summary>
        /// 拓竹打印机取数（本进程内 MQTT）。★ 2026-10-15 新增：
        /// 让程序自己从拓竹云拿打印机数据，不再依赖本机的 bambu-monitor 服务与桥。
        /// </summary>
        private BambuPrinter _bambu;
        private BambuConfig _bambuCfg;

        private Bitmap _canvas;
        private readonly object _frameGate = new object();
        private byte[] _jpeg;
        /// <summary>
        /// 主题 6 的固件界面定点覆盖（-1 = 按 4 屏轮播）。
        /// 用户 2026-10-14 定这块屏只需要 4 个界面，其余界面代码保留但需 `/set?fws=N` 定点查看。
        /// </summary>
        public static int FwSimOverride = -1;
        /// <summary>趋势曲线采样（主题 2/3 用）</summary>
        private readonly History _hist = new History();
        private int _jpgW, _jpgH;

        private DeviceInfo _info;
        private long _frames, _sent, _errors;
        private double _renderMs, _encodeMs, _pushMs, _quality = 0.9;
        private string _ack = "（尚未推帧）";
        private bool _lastErrored;

        private Bitmap _scaled;
        private bool _sizeWarned;
        private SystemInfo _localSys;
        private long _localSysAt;

        public LcdRunner(Settings cfg)
        {
            _cfg = cfg;
        }

        public State Telemetry { get { return _st; } }

        /// <summary>运行配置（GUI 直接改 Vertical / Rotate180 / NightEnabled 等开关）</summary>
        public Settings Config { get { return _cfg; } }

        /// <summary>界面上的「连接屏幕」按钮：清掉退避状态，让它立刻重试</summary>
        public void ArmUsbRetry()
        {
            Schedule.NoteOpenSuccess(_usb);
            Log.W("已重新允许自动连接屏幕");
        }

        /// <summary>界面上的「断开屏幕」按钮</summary>
        public void CloseUsbNow()
        {
            CloseUsb();
            Log.W("已断开屏幕（仍在预览渲染）");
        }

        public bool NightOn { get { return IsNight(); } }

        /// <summary>界面上的"VM 监视地址"应用按钮：立刻生效，不用重启</summary>
        public void SetVmUrl(string url)
        {
            _cfg.VmUrl = url == null ? "" : url.Trim();
            if (_vm != null) _vm.SetUrl(_cfg.VmUrl);
        }

        public string VmSummary { get { return _vm == null ? "未启动" : _vm.Summary(); } }
        public string NightWindowText { get { return "18:30-09:00"; } }
        public bool UsbOpen { get { return _dev != null && _dev.Opened; } }

        /// <summary>
        /// 主题被外部改掉时的通知（`/set?theme=N`）。
        /// 界面挂上它来刷新主题按钮高亮 —— 否则用户从网页改了主题，
        /// 界面里亮着的还是旧按钮，看着像"没生效"。
        /// </summary>
        public event Action ThemeChanged;

        /// <summary>本实例是否真的抢到了 HTTP 端口（没抢到就不能做自测，见 Program.HttpSelfTest）</summary>
        public bool HttpRunning { get { return _http != null && _http.Running; } }
        public DeviceInfo Info { get { return _info; } }

        // ---------- 启动/停止 ----------

        public bool Start()
        {
            _running = true;

            // 载入内置图片背景（找不到就静默跳过；程序化特效 none/plasma/aurora/lava/waves 仍可用）
            // 文件位置见 Backdrop.LoadImageFrom 的注释；与 exe 同级或 assets/ 下都认。
            if (Backdrop.LoadImageFrom(Program.ExeDir()))
            {
                Log.W("内置背景图已载入（bg_sample.jpg）");
            }
            // 主题 7（TRCC 官方风）的 5 张官方卡片层图；找不到就退回自绘卡片
            int trccLayers = ThemeTrcc.LoadCardLayers(Program.ExeDir());
            if (trccLayers > 0)
            {
                Log.W("TRCC 官方卡片层已载入 {0}/5", trccLayers);
            }

            _udp = new TelemetryReceiver(_st, _cfg.UdpPort, _cfg.UdpAny);
            _udp.Start();

            // 启动即跑一次协议自检（纯计算，不碰 USB）：鸿蒙版在 LcdService.start() 里也这么做，
            // 这样 /diag 两边都有"协议自检 N/M"可看，出问题不用另外跑 --selftest。
            try { SelfTest.Run(); } catch (Exception ex) { Log.Err("自检异常：{0}", ex.Message); }

            _vm = new VmSource(_cfg.VmUrl);
            _vm.IntervalMs = _cfg.VmIntervalMs;
            _vm.Start();

            // 拓竹打印机取数：本进程内直连拓竹云 MQTT（不再依赖 Node 的 bambu-monitor）
            // 没配凭据就静默跳过（打印机只是不显示，不该影响 DSH 面板其它部分）
            if (_cfg.BambuEnabled)
            {
                try
                {
                    string cfgPath = _cfg.BambuConfigPath;
                    if (string.IsNullOrEmpty(cfgPath)) cfgPath = BambuConfig.ResolvePath(Program.ExeDir());
                    _bambuCfg = BambuConfig.Load(cfgPath);
                    _bambu = new BambuPrinter(_bambuCfg);
                    _bambu.OnEvent = delegate (string type, string msg)
                    {
                        // 只记日志。**故意不塞进 `_st.Data.Events`** —— 桥每个遥测包都会
                        // 整包替换事件流（NormalizeEvents），本地塞进去的会被下一次包冲掉，
                        // 反而造成事件闪烁。打印机状态本身在打印机卡片 / Dotii 的 Bambu 页显示。
                        Log.W("[打印机] {0}", msg);
                    };
                    if (_bambu.Start())
                    {
                        Log.W("拓竹取数已启动（配置 {0}，区域 {1}）", _bambuCfg.Path, _bambuCfg.Region);
                    }
                }
                catch (Exception ex)
                {
                    Log.Err("拓竹取数启动异常：{0}", ex.Message);
                }
            }

            if (!_cfg.NoHttp)
            {
                _http = new MiniHttp(_cfg.HttpPort);
                _http.GetFrame = GetJpeg;
                _http.GetStatus = StatusJson;
                _http.GetDiag = DiagJson;
                _http.OnSet = ApplySet;
                _http.OnProbe = delegate() { return WinUsb.ProbeReport(); };
                _http.Start();
            }

            _loop = new Thread(new ThreadStart(Loop));
            _loop.IsBackground = false;
            _loop.Name = "frame-loop";
            _loop.Start();
            return true;
        }

        public void Stop()
        {
            _running = false;
            try { if (_loop != null) _loop.Join(4000); } catch (Exception) { }
            if (_udp != null) _udp.Stop();
            if (_vm != null) _vm.Stop();
            if (_bambu != null) _bambu.Stop();
            if (_http != null) _http.Stop();
            CloseUsb();
            lock (_frameGate)
            {
                if (_canvas != null) { try { _canvas.Dispose(); } catch (Exception) { } _canvas = null; }
                if (_flat != null) { try { _flat.Dispose(); } catch (Exception) { } _flat = null; }
                if (_scaled != null) { try { _scaled.Dispose(); } catch (Exception) { } _scaled = null; }
            }
        }

        private void CloseUsb()
        {
            if (_dev != null)
            {
                try { _dev.Dispose(); } catch (Exception) { }
                _dev = null;
            }
        }

        // ---------- 帧循环 ----------

        private void Loop()
        {
            Log.W("帧循环启动（视口 {0}x{1}，{2}）", _cfg.MaxWidth, _cfg.MaxHeight,
                _cfg.Vertical ? "竖屏布局 462x1920" : "横向布局 1920x462");
            while (_running)
            {
                long t0 = State.NowMs();
                try
                {
                    Tick();
                    _lastErrored = false;
                }
                catch (Exception ex)
                {
                    _errors++;
                    _lastErrored = true;
                    Log.Err("帧循环异常：{0}", ex.Message);
                }

                int wait = _cfg.ForcedIntervalMs > 0
                    ? _cfg.ForcedIntervalMs
                    : Schedule.NextFrameInterval(new Schedule.FrameTickInput
                    {
                        StateStr = AgentState(),
                        Night = IsNight(),
                        Errored = _lastErrored,
                    });
                int used = (int)(State.NowMs() - t0);
                // ★ burst 语义对齐（2026-10-15）
                //   本版 C# 的帧循环**本来就**是"间隔扣除本帧耗时"（下面 `wait - used`），
                //   也就是 ArkTS 加了 `burst=1` 才有的行为；而 ArkTS 默认是"间隔另加在耗时之外"
                //   （实测 fps=8 时每帧 = 5+71+66+125 = 267ms → 只有 3.7fps，加 burst 后到 15.1fps）。
                //   为了**同一条命令在两个平台行为一致**，这里默认关闭 burst：
                //     burst=1 → sleep = wait - used（吞吐导向）
                //     burst=0 → sleep = wait      （与 ArkTS 默认一致）
                //   若测量出本平台编码很快、不需要节流，可显式开 burst=1。
                int sleep = _cfg.Burst ? (wait - used) : wait;
                if (sleep < 0) sleep = 0;
                while (sleep > 0 && _running)
                {
                    int slice = sleep > 50 ? 50 : sleep;
                    Thread.Sleep(slice);
                    sleep -= slice;
                }
            }
            Log.W("帧循环退出");
        }

        private string AgentState()
        {
            if (_st.Data == null || _st.Data.Agent == null) return "unknown";
            return string.IsNullOrEmpty(_st.Data.Agent.State) ? "unknown" : _st.Data.Agent.State;
        }

        private bool IsNight()
        {
            if (!_cfg.NightEnabled) return false;
            DateTime now = DateTime.Now;
            return _nightWin.Contains(now.Hour * 60 + now.Minute);
        }

        private void Tick()
        {
            long t0 = State.NowMs();

            // 本机系统数据：遥测不新鲜时用自己采的（Windows 上这份更真实）
            if (t0 - _localSysAt > 1000)
            {
                _localSys = SysMon.Sample();
                _localSysAt = t0;
            }
            // 与 ArkTS 的 LocalSys.pickSystem() 同一个函数语义（含"本机电量始终补上"）
            _st.Data.System = State.PickSystem(_st.Data.System, _st.Fresh, _localSys);

            // 打印机：**本机 MQTT 优先**（2026-10-15 新增）
            // 语义与 PickSystem 相反 —— 打印机数据是本进程直连拓竹云拿的，比桥转发的更新更权威；
            // 只有本机还没拿到数据时才用桥转发的那份（保持向后兼容：不配凭据时行为与以前一致）。
            if (_bambu != null)
            {
                PrinterInfo bp = _bambu.Snapshot();
                if (bp != null) _st.Data.Printer = bp;
            }

            RenderFrame();
            long t1 = State.NowMs();
            _renderMs = Ema(_renderMs, t1 - t0);

            byte[] jpg = EncodeFrame(t1);
            long t2 = State.NowMs();
            _encodeMs = Ema(_encodeMs, t2 - t1);
            _frames++;

            ServiceUsb();
            if (_dev != null && jpg != null)
            {
                int pid = _dev.Pid == Ly.PidLy1 ? Ly.PidLy1 : Ly.PidLy;
                string ack;
                bool ok = WinUsb.PushJpeg(_dev, jpg, pid, out ack);
                if (ok) _sent++; else _errors++;
                _ack = ack;
            }
            long t3 = State.NowMs();
            _pushMs = Ema(_pushMs, t3 - t2);
        }

        private static double Ema(double prev, double sample)
        {
            if (prev <= 0) return sample;
            return prev * 0.7 + sample * 0.3;
        }

        // ---------- 渲染 ----------

        private void RenderFrame()
        {
            if (_canvas == null)
            {
                _canvas = new Bitmap(_cfg.MaxWidth, _cfg.MaxHeight, PixelFormat.Format32bppArgb);
            }
            DateTime now = DateTime.Now;
            bool vert = _cfg.Vertical;
            int totalRot = vert ? 90 : (_cfg.Rotate180 ? 180 : 0);

            using (Graphics g = Graphics.FromImage(_canvas))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                // VM 画面每帧都要缩放绘制：高质量插值在 ARM64 虚拟机上要 ~100ms，
                // 换成双线性后肉眼无差别（画面本身只有 452x480 显示区），帧率却翻几倍
                g.InterpolationMode = InterpolationMode.Bilinear;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
                g.Clear(Color.FromArgb(255, 10, 12, 20));

                // 与鸿蒙版同一套变换组合：
                //   竖屏：translate(W,0) + rotate(90°)，此时 rotate180 不叠加（鸿蒙版就是这么做的，
                //         实测真机竖装下 90° 就是正立方向）
                //   横屏：rotate180 时 translate(W,H) + rotate(180°)
                if (totalRot == 90)
                {
                    g.TranslateTransform(_cfg.MaxWidth, 0);
                    g.RotateTransform(90);
                }
                else if (totalRot == 180)
                {
                    g.TranslateTransform(_cfg.MaxWidth, _cfg.MaxHeight);
                    g.RotateTransform(180);
                }
                else if (totalRot == 270)
                {
                    g.TranslateTransform(0, _cfg.MaxHeight);
                    g.RotateTransform(270);
                }

                // 采样历史曲线（主题 2 监控墙 / 主题 3 分页屏的曲线用它；每 2 秒一个点）
                {
                    SystemInfo sSys = (_st == null || _st.Data == null) ? null : _st.Data.System;
                    TokenInfo sTk = (_st == null || _st.Data == null) ? null : _st.Data.Tokens;
                    BalanceInfo sBal = (_st == null || _st.Data == null) ? null : _st.Data.Balance;
                    double cpuPct = (sSys == null) ? 0 : sSys.Cpu;
                    double memPct = (sSys != null && sSys.MemTotal > 0)
                        ? sSys.MemUsed / sSys.MemTotal * 100 : 0;
                    // C# 侧没有 tokensPerMin，用"今日 token 累计"的增量近似不了 → 记断点
                    double tpm = -1;
                    double balTotal = (sBal == null) ? -1 : sBal.Total;
                    _hist.Sample(State.NowMs(), cpuPct, memPct, tpm, balTotal);
                }

                // 刷新全局运行统计快照（主题 1 的页脚读它；见 FrameStats 的注释）
                FrameStats.UsbOpen = UsbOpen;
                FrameStats.Sent = _sent;
                FrameStats.Errors = _errors;
                FrameStats.BridgeAgeSec = (_st == null) ? -1 : _st.AgeSec();
                // _jpeg 是本帧的 JPEG 字节（字段名见 LcdRunner 顶部）
                if (_jpeg != null && _jpeg.Length > 0)
                {
                    FrameStats.JpegBytes = _jpeg.Length;
                }
                // 各阶段耗时（主题 3 的"本屏"栏用）。
                // ⚠️ `SkippedFrames` 在 C# 侧**恒为 0**：本版帧循环是**同步**的
                //    （渲染→编码→推送→睡，一路走完），不存在 ArkTS 那种"上一帧还在推就丢本帧"
                //    的背压路径。这是两版实现的结构差异，不是缺失 —— 故如实显示 0 而不是编个数。
                FrameStats.RenderMs = _renderMs;
                FrameStats.EncodeMs = _encodeMs;
                FrameStats.PushMs = _pushMs;

                // 维护滚动留言条：把 agent 的最后一句推进去（对齐 ArkTS 每帧 pushFeed 的做法）
                if (_st != null && _st.Data != null && _st.Data.Agent != null)
                {
                    Dashboard.PushFeed(_st.Data.Agent.LastText);
                }

                _vm.Render(delegate(Bitmap vm, double ageMs, string err)
                {
                    // ★ 2026-10-15：改走主题调度（等价 ArkTS `LcdService` 里那条 if-else 长链）。
                    //   原来只有竖/横两个渲染器，主题 11~15 移植了也永远跑不到；
                    //   现在 `/set?theme=N` 能真正切换，未移植的主题在 Dispatch 里诚实回落仪表盘。
                    Themes.Dispatch(g, _cfg.Theme, _st, vm, ageMs, err, DshLcd.State.NowMs(), vert, _cfg.PrinterCell, _hist);
                });
            }
        }

        private static ImageCodecInfo _jpegCodec;

        private static ImageCodecInfo JpegCodec()
        {
            if (_jpegCodec != null) return _jpegCodec;
            ImageCodecInfo[] all = ImageCodecInfo.GetImageEncoders();
            for (int i = 0; i < all.Length; i++)
            {
                if (all[i].FormatID == ImageFormat.Jpeg.Guid) { _jpegCodec = all[i]; break; }
            }
            return _jpegCodec;
        }

        private Bitmap _flat;   // 不透明压平缓冲（JPEG 没有 alpha，必须先合成掉）

        /// <summary>
        /// 把画布压平到不透明位图上再编码。
        ///
        /// 为什么必须做：渲染器里只要有一处用 SourceCopy 填了"半透明白"，
        /// 画布上就会留下 alpha=0 / RGB=255 的像素；JPEG 存不下 alpha，
        /// 保存出来就是**一大片纯白**（实测踩到过：84k 像素的白块）。
        /// 先按 SourceOver 合成到不透明底上，alpha 就再也影响不了成品。
        /// </summary>
        private void Flatten()
        {
            if (_flat == null || _flat.Width != _canvas.Width || _flat.Height != _canvas.Height)
            {
                if (_flat != null) { try { _flat.Dispose(); } catch (Exception) { } }
                _flat = new Bitmap(_canvas.Width, _canvas.Height, PixelFormat.Format24bppRgb);
            }
            using (Graphics g = Graphics.FromImage(_flat))
            {
                g.CompositingMode = CompositingMode.SourceOver;
                g.Clear(Color.FromArgb(255, 10, 12, 20));
                g.DrawImageUnscaled(_canvas, 0, 0);
            }
        }

        private byte[] EncodeFrame(long t1)
        {
            // 画质阶梯与鸿蒙版一致：从 0.9 起，超 650KB 就降 0.15，下限 0.4
            double q = 0.9;
            byte[] bytes = null;
            Bitmap bmp;
            lock (_frameGate)
            {
                Flatten();
                bmp = _flat;
                // 真机分辨率可能与布局尺寸不同（实测参考实现里 FBL 192 有 1920x480 / 1920x462 / 1920x440
                // 三种说法）。这里按设备报告的实际尺寸整体缩放一次，
                // 宁可轻微纵向压扁，也不要"下半截被裁掉"。
                int dw = _cfg.MaxWidth, dh = _cfg.MaxHeight;
                if (_info != null && _info.Width > 0 && _info.Height > 0
                    && (_info.Width != dw || _info.Height != dh))
                {
                    if (_scaled == null || _scaled.Width != _info.Width || _scaled.Height != _info.Height)
                    {
                        if (_scaled != null) { try { _scaled.Dispose(); } catch (Exception) { } }
                        _scaled = new Bitmap(_info.Width, _info.Height, PixelFormat.Format24bppRgb);
                    }
                    using (Graphics sg = Graphics.FromImage(_scaled))
                    {
                        sg.InterpolationMode = InterpolationMode.Bilinear;
                        sg.DrawImage(bmp, 0, 0, _info.Width, _info.Height);
                    }
                    if (!_sizeWarned)
                    {
                        _sizeWarned = true;
                        Log.W("注意：设备报告 {0}x{1}，布局按 {2}x{3} 渲染后整体缩放适配",
                            _info.Width, _info.Height, dw, dh);
                    }
                    bmp = _scaled;
                }
                for (int i = 0; i < 8; i++)
                {
                    bytes = EncodeJpeg(bmp, q);
                    if (bytes.Length <= Ly.MaxJpegSize || q <= 0.4) break;
                    q = Math.Max(0.4, q - 0.15);
                }
                _quality = q;
                int w, h;
                if (Ly.ParseJpegSize(bytes, out w, out h)) { _jpgW = w; _jpgH = h; }
                _jpeg = bytes;
            }
            return bytes;
        }

        private static byte[] EncodeJpeg(Bitmap bmp, double quality)
        {
            using (MemoryStream ms = new MemoryStream())
            {
                EncoderParameters p = new EncoderParameters(1);
                p.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)Math.Round(quality * 100));
                bmp.Save(ms, JpegCodec(), p);
                return ms.ToArray();
            }
        }

        /// <summary>渲染并编码一帧（不推屏、不进循环）——给 --render / --demo 做离线验证</summary>
        public byte[] RenderOnce()
        {
            if (_localSys == null) _localSys = SysMon.Sample();
            if (!_st.Fresh) _st.Data.System = _localSys;
            RenderFrame();
            return EncodeFrame(State.NowMs());
        }

        /// <summary>当前帧 JPEG（诊断/预览接口读它）</summary>
        public byte[] GetJpeg()
        {
            lock (_frameGate)
            {
                return _jpeg;
            }
        }

        public double RenderMs { get { return _renderMs; } }
        public double EncodeMs { get { return _encodeMs; } }
        public double PushMs { get { return _pushMs; } }
        public double Quality { get { return _quality; } }
        public long Frames { get { return _frames; } }
        public long Sent { get { return _sent; } }
        public long Errors { get { return _errors; } }

        // ---------- USB ----------

        private void ServiceUsb()
        {
            if (_cfg.NoUsb) return;
            long now = State.NowMs();
            Schedule.UsbAttemptDecision d = Schedule.ShouldAttemptUsbOpen(_usb, now, UsbOpen);
            if (!d.Attempt)
            {
                if (d.NeedsManual && _frames % 300 == 0)
                {
                    Log.W("USB 自动重试已关闭（被拒 {0} 次），可在网页预览里点「连接屏幕」或调 /set?arm=1", _usb.Denied);
                }
                return;
            }

            CloseUsb();
            WinUsb.LyDevice dev = WinUsb.Open(Ly.VendorId, _cfg.Pid);
            if (dev == null)
            {
                Schedule.NoteOpenFailure(_usb, false, now);
                return;
            }
            int pidHint = dev.Pid == Ly.PidLy1 ? Ly.PidLy1 : Ly.PidLy;
            DeviceInfo info = WinUsb.Handshake(dev, pidHint);
            if (info == null)
            {
                dev.Dispose();
                Schedule.NoteOpenFailure(_usb, false, now);
                return;
            }
            _dev = dev;
            _info = info;
            Schedule.NoteOpenSuccess(_usb);
            // 旋转默认**跟随设备握手**（与鸿蒙版 rotMode=0 同义）：用户没在界面上显式设过
            // 就按设备报的角度来。真机实测（Trofeo Vision 9.16，PM=65 SUB=5）必须 180° 画面才是正的 ——
            // 之前照抄"某驱动把该字段固定为 false"导致默认值本身是错的、得手动打开才对。
            if (!_cfg.Rotate180Forced)
            {
                _cfg.Rotate180 = info.RotateDeg == 180;
                Log.W("设备报旋转 {0}° → 自动跟随（未手动指定）：{1}",
                    info.RotateDeg, _cfg.Rotate180 ? "180°" : "0°");
            }
            else
            {
                Log.W("旋转为手动指定：{0}°（设备报 {1}°）",
                    _cfg.Rotate180 ? 180 : 0, info.RotateDeg);
            }
            if (info.Width != _cfg.MaxWidth || info.Height != _cfg.MaxHeight)
            {
                Log.W("设备报告 {0}x{1}，将按此尺寸缩放适配（本版布局默认 {2}x{3}）",
                    info.Width, info.Height, _cfg.MaxWidth, _cfg.MaxHeight);
            }
            if (info.Width != _cfg.MaxWidth || info.Height != _cfg.MaxHeight)
            {
                Log.W("注意：设备报告 {0}x{1}，本程序按 {2}x{3} 渲染（不符时画面会错位）",
                    info.Width, info.Height, _cfg.MaxWidth, _cfg.MaxHeight);
            }
            Log.W("已连接屏幕：{0}（旋转 {1}°）", info.ToString(), _cfg.Rotate180 ? 180 : 0);
        }

        // ---------- 诊断接口 ----------

        private static void Add(JsonValue o, string k, string v) { o.Obj[k] = v == null ? new JsonValue() : JsonValue.NewStr(v); }
        private static void Add(JsonValue o, string k, double v) { o.Obj[k] = JsonValue.NewNum(v); }
        private static void Add(JsonValue o, string k, bool v) { o.Obj[k] = JsonValue.NewBool(v); }

        public string StatusJson()
        {
            JsonValue o = JsonValue.NewObj();
            Add(o, "state", AgentState());
            Add(o, "jpegW", _jpgW);
            Add(o, "jpegH", _jpgH);
            lock (_frameGate) { Add(o, "jpegBytes", _jpeg == null ? 0 : _jpeg.Length); }
            Add(o, "sent", _sent);
            Add(o, "errors", _errors);
            Add(o, "usbOpen", UsbOpen);
            Add(o, "bridgeAgeSec", _st.Fresh ? _st.AgeSec() : -1);
            Add(o, "device", _info == null ? "" : _info.ToString());
            Add(o, "ack", _ack);
            Add(o, "frames", _frames);
            Add(o, "rotate180", _cfg.Rotate180);
            Add(o, "rotMode", _cfg.Rotate180Forced ? (_cfg.Rotate180 ? 1 : 2) : 0);
            Add(o, "deviceRotDeg", _info == null ? -1 : _info.RotateDeg);
            Add(o, "vertical", _cfg.Vertical);
            Add(o, "night", IsNight());
            Add(o, "vmUrl", _cfg.VmUrl == null ? "" : _cfg.VmUrl);
            Add(o, "platform", "windows");
            return o.ToJson();
        }

        public string DiagJson()
        {
            JsonValue o = JsonValue.NewObj();
            Add(o, "state", AgentState());
            Add(o, "jpegW", _jpgW);
            Add(o, "jpegH", _jpgH);
            lock (_frameGate) { Add(o, "jpegBytes", _jpeg == null ? 0 : _jpeg.Length); }
            Add(o, "sent", _sent);
            Add(o, "errors", _errors);
            Add(o, "usbOpen", UsbOpen);
            Add(o, "bridgeAgeSec", _st.Fresh ? _st.AgeSec() : -1);
            Add(o, "device", _info == null ? "" : _info.ToString());
            Add(o, "ack", _ack);
            Add(o, "frames", _frames);
            Add(o, "rotate180", _cfg.Rotate180);
            Add(o, "rotMode", _cfg.Rotate180Forced ? (_cfg.Rotate180 ? 1 : 2) : 0);
            Add(o, "deviceRotDeg", _info == null ? -1 : _info.RotateDeg);
            Add(o, "vertical", _cfg.Vertical);
            Add(o, "night", IsNight());
            Add(o, "renderMs", Math.Round(_renderMs, 2));
            Add(o, "encodeMs", Math.Round(_encodeMs, 2));
            Add(o, "pushMs", Math.Round(_pushMs, 2));
            Add(o, "quality", _quality);
            Add(o, "telemetryPackets", _st.Packets);
            Add(o, "telemetryLastError", _st.LastError);
            Add(o, "udpBind", _udp == null ? "" : _udp.BindDesc);
            // ★ 报**实际绑定成功的端口**，不是配置值 —— MiniHttp 在端口被占时会自动往后找，
            //   报配置值会让 /diag 说一个根本没在监听的端口（今天误导排查的正是这个）。
            Add(o, "httpPort", _http != null ? _http.Port : _cfg.HttpPort);
            Add(o, "httpRequests", _http == null ? 0 : _http.Requests);
            Add(o, "vmFrames", _vm == null ? 0 : _vm.Frames);
            Add(o, "vmErrors", _vm == null ? 0 : _vm.Errors);
            // 原来是 _vm == null ? -1 : 0 的占位（永远 0），等于没有这个指标；
            // 现在给真实值，字段名与鸿蒙版 /diag 对齐（vmAgeMs / vmErr）
            Add(o, "vmAgeMs", _vm == null ? -1 : _vm.AgeMs);
            Add(o, "vmErr", _vm == null ? "" : _vm.LastError);
            Add(o, "vmUrl", _cfg.VmUrl == null ? "" : _cfg.VmUrl);
            Add(o, "vmInfo", _vm == null ? "" : _vm.Describe());
            Add(o, "vmSize", _vm == null ? "" : _vm.Describe());
            // ---- 拓竹打印机（本进程直连云端 MQTT；不依赖 Node 服务）----
            // mode: not-configured（没配凭据）/ discovering / running / error
            Add(o, "bambuMode", _bambu == null
                ? (_bambuCfg == null ? "off" : "not-configured")
                : (_bambu.State.MonitorMode == null ? "" : _bambu.State.MonitorMode));
            Add(o, "bambuError", _bambu == null ? "" : (_bambu.State.MonitorError == null ? "" : _bambu.State.MonitorError));
            Add(o, "bambuMqtt", _bambu != null && _bambu.State.MqttConnected);
            Add(o, "bambuOnline", _bambu != null && _bambu.State.PrinterOnline);
            Add(o, "bambuState", _bambu == null ? "" : _bambu.State.StateCode);
            Add(o, "bambuRegion", _bambu == null ? "" : _bambu.State.Region);
            Add(o, "bambuDevice", _bambu == null ? "" : _bambu.State.DeviceName);
            Add(o, "bambuModel", _bambu == null ? "" : _bambu.State.DeviceModel);
            // 距上次上报多少秒（-1 = 从未收到）—— 排查"打印机不更新"时先看它
            Add(o, "bambuReportAgeSec", _bambu == null ? -1
                : Math.Round(_bambu.State.ReportAgeMs() / 1000.0, 1));
            // 累计收到多少条报文（0 = 一条都没收到，说明订阅/网络有问题）
            Add(o, "bambuReports", _bambu == null ? 0 : (double)_bambu.State.Reports);
            Add(o, "bambuConfig", _bambuCfg == null ? "" : _bambuCfg.Path);
            Add(o, "selfTest", SelfTest.LastSummary);
            Add(o, "selfTestAllPass", SelfTest.LastTotal >= 0 && SelfTest.LastFails == 0);
            Add(o, "platform", "windows");
            Add(o, "localCpu", _localSys == null ? 0 : Math.Round(_localSys.Cpu, 1));
            Add(o, "localMemUsedMB", _localSys == null ? 0 : Math.Round(_localSys.MemUsed));
            Add(o, "localMemTotalMB", _localSys == null ? 0 : Math.Round(_localSys.MemTotal));
            Add(o, "usbDenied", _usb.Denied);
            Add(o, "usbAuto", _usb.Auto);
            Add(o, "serverTime", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            Add(o, "version", Program.Version);
            return o.ToJson();
        }

        public string ApplySet(Dictionary<string, string> args)
        {
            JsonValue o = JsonValue.NewObj();
            try
            {
                foreach (KeyValuePair<string, string> kv in args)
                {
                    bool on = kv.Value == "1" || kv.Value.ToLowerInvariant() == "true" || kv.Value.ToLowerInvariant() == "on";
                    if (kv.Key == "vertical") _cfg.Vertical = on;
                    else if (kv.Key == "rotate180") { _cfg.Rotate180 = on; _cfg.Rotate180Forced = true; }
                    else if (kv.Key == "night") _cfg.NightEnabled = on;
                    else if (kv.Key == "interval")
                    {
                        // ★ 2026-10-15（代码审查【中-7】）：原来直接把入参写进 ForcedIntervalMs，
                        //   **没有下限** —— 传 interval=1 会把帧循环压到 1ms，等于灌爆 USB 批量端点
                        //   （ArkTS 侧有 MIN_PUSH_INTERVAL_MS=120 的护栏，并有"端点进错误态、屏黑、
                        //   只能拔插"的实测事故记录）。这里补同样的下限。
                        int v;
                        if (int.TryParse(kv.Value, out v))
                        {
                            if (v > 0 && v < 120) v = 120;      // 下限 120ms ≈ 8fps
                            _cfg.ForcedIntervalMs = v;
                        }
                    }
                    else if (kv.Key == "arm") { Schedule.NoteOpenSuccess(_usb); Schedule.NoteOpenFailure(_usb, false, 0); Log.W("已重新允许自动连接屏幕"); }
                    else if (kv.Key == "usb") { _cfg.NoUsb = !on; if (!on) CloseUsb(); }
                    else if (kv.Key == "vm") { _cfg.VmIntervalMs = on ? 1000 : 60000; if (_vm != null) _vm.IntervalMs = _cfg.VmIntervalMs; }
                    else if (kv.Key == "theme")
                    {
                        // 对齐 ArkTS：`(n>=0 && n<=15) ? n : 0`
                        int th;
                        if (int.TryParse(kv.Value, out th)) _cfg.Theme = Themes.Clamp(th);
                        // 让界面上的主题按钮跟着高亮（否则 UI 里仍是旧按钮亮着 → 不一致）
                        if (ThemeChanged != null) ThemeChanged();
                    }
                    else if (kv.Key == "burst")
                    {
                        // 极速模式：帧间隔扣除本帧耗时（见 Settings.Burst 注释）
                        _cfg.Burst = on;
                    }
                    else if (kv.Key == "fws")
                    {
                        // 主题 6 的固件界面定点查看（N 是 display_ui.h 的原始枚举号 0..17）
                        int fs2;
                        if (int.TryParse(kv.Value, out fs2)) FwSimOverride = fs2;
                    }
                    else if (kv.Key == "fwsrot")
                    {
                        // 清掉定点覆盖，回到 4 屏轮播
                        FwSimOverride = -1;
                    }
                    else if (kv.Key == "printerCell")
                    {
                        // 打印机格档位：printer / v6 / v4 / dotii
                        string pc = kv.Value.ToLowerInvariant();
                        if (pc == "printer" || pc == "v6" || pc == "v4" || pc == "dotii")
                        {
                            _cfg.PrinterCell = pc;
                        }
                    }
                    else if (kv.Key == "background")
                    {
                        // 程序化背景：none / plasma / aurora / lava / waves / image
                        Backdrop.Current = Backdrop.FromName(kv.Value);
                    }
                    else if (kv.Key == "bgdim")
                    {
                        // 压暗 0..100（对应 trofeo-lcd-rs 的 --background-dim，默认 40）
                        double dv;
                        if (double.TryParse(kv.Value, System.Globalization.NumberStyles.Float,
                                System.Globalization.CultureInfo.InvariantCulture, out dv))
                        {
                            if (dv < 0) dv = 0;
                            if (dv > 100) dv = 100;
                            Backdrop.DimPct = dv;
                        }
                    }
                }
                Add(o, "ok", true);
            }
            catch (Exception ex)
            {
                Add(o, "ok", false);
                Add(o, "error", ex.Message);
            }
            Add(o, "vertical", _cfg.Vertical);
            Add(o, "rotate180", _cfg.Rotate180);
            Add(o, "night", IsNight());
            Add(o, "nightEnabled", _cfg.NightEnabled);
            Add(o, "interval", _cfg.ForcedIntervalMs);
            Add(o, "theme", _cfg.Theme);
            Add(o, "winW", GuiForm.WinW);
            Add(o, "winH", GuiForm.WinH);
            Add(o, "themeName", Themes.Name(_cfg.Theme));
            Add(o, "burst", _cfg.Burst);
            Add(o, "printerCell", _cfg.PrinterCell);
            Add(o, "bgStyle", Backdrop.StyleNames[(int)Backdrop.Current]);
            Add(o, "bgDim", (int)Backdrop.DimPct);
            Add(o, "jpegLimit", Ly.MaxJpegSize);
            Add(o, "noUsb", _cfg.NoUsb);
            Add(o, "vmIntervalMs", _cfg.VmIntervalMs);
            Log.W("收到 /set：{0}", o.ToJson());
            return o.ToJson();
        }
    }
}
