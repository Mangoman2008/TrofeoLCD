using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Threading;

namespace DshLcd
{
    /// <summary>
    /// VM 监视画面源：定时 HTTP 抓一张 JPEG（livepad 的 /vm/frame.jpg）并解码成位图。
    ///
    /// 线程安全做法：抓取线程在锁外解码成临时 Bitmap，再进锁把它画进一块**持久缓冲**；
    /// 渲染线程在同一把锁里画面板。这样渲染方拿到的位图永远有效，
    /// 也不会出现"渲染到一半图被 Dispose"的经典崩溃。
    /// </summary>
    public class VmSource
    {
        public string Url;
        /// <summary>候选地址列表（界面里可以填多个，用逗号/空格分隔）：挨个试，谁能取到就用谁。
        /// 解决"地址随环境变"的问题：同一份配置在虚拟机里用 172.16.101.1、在局域网机器上用平板 IP。</summary>
        public System.Collections.Generic.List<string> Urls = new System.Collections.Generic.List<string>();
        public int ActiveIndex = -1;
        public int IntervalMs = 1000;
        public int TimeoutMs = 4000;

        private Bitmap _buf;
        private readonly object _gate = new object();
        private Thread _thread;
        private volatile bool _running;
        private long _atMs;
        private string _err = "";
        private int _frames;
        private int _errors;
        private long _lastFetchMs;
        private int _w, _h;          // 源图尺寸（对外报告用）
        private int _bw, _bh;        // 缓冲尺寸（已降采样）
        /// <summary>抓取时把源图降到这个长边上限：VM 帧是 1680x1120，
        /// 每帧缩放它要 60+ ms；降采样一次（每秒 1 次）后每帧只缩小小图。</summary>
        public int MaxSourceSide = 1100;

        public VmSource(string url)
        {
            Url = url;
        }

        public bool Enabled { get { return !string.IsNullOrEmpty(Url); } }
        public int Frames { get { return _frames; } }
        public int Errors { get { return _errors; } }
        public long LastFetchMs { get { return _lastFetchMs; } }
        public string LastError { get { return _err; } }
        /// <summary>距上次**成功**取帧的毫秒数；从未取到为 -1（界面与 /diag 用，和鸿蒙版语义一致）</summary>
        public long AgeMs { get { return _atMs == 0 ? -1 : State.NowMs() - _atMs; } }

        /// <summary>运行时换地址（界面上那个"VM 监视地址"输入框用的）：线程每轮都重读 Url</summary>
        public void SetUrl(string url)
        {
            string old = Url;
            Url = url == null ? "" : url.Trim();
            Urls = VmProbe.ParseList(Url);
            ActiveIndex = -1;
            _err = "";
            _errors = 0;
            Log.W("VM 监视地址：{0} -> {1}{2}", string.IsNullOrEmpty(old) ? "(空)" : old,
                string.IsNullOrEmpty(Url) ? "(已清空)" : Url,
                Urls.Count > 1 ? "（候选 " + Urls.Count + " 个，挨个试）" : "");
        }

        public void Start()
        {
            if (!Enabled) { Log.W("VM 画面：未配置（可在界面里填 VM 监视地址）"); return; }
            _running = true;
            _thread = new Thread(new ThreadStart(Loop));
            _thread.IsBackground = true;
            _thread.Name = "vm-source";
            _thread.Start();
            Log.W("VM 画面源：{0}（每 {1} ms）", Url, IntervalMs);
        }

        public void Stop()
        {
            _running = false;
            try { if (_thread != null) _thread.Join(1500); } catch (Exception) { }
            lock (_gate)
            {
                if (_buf != null) { try { _buf.Dispose(); } catch (Exception) { } _buf = null; }
            }
        }

        private void Loop()
        {
            while (_running)
            {
                long t0 = State.NowMs();
                if (Urls.Count > 1)
                {
                    // 多候选：从上次成功的那个开始轮着试
                    int start = ActiveIndex < 0 ? 0 : ActiveIndex;
                    int bytes; long ms; string err;
                    string hit = null;
                    for (int k = 0; k < Urls.Count; k++)
                    {
                        int idx = (start + k) % Urls.Count;
                        if (VmProbe.TryFetch(Urls[idx], out bytes, out ms, out err))
                        {
                            hit = Urls[idx];
                            ActiveIndex = idx;
                            break;
                        }
                    }
                    if (hit == null)
                    {
                        _errors++;
                        _err = "候选地址都取不到（" + Urls.Count + " 个）";
                        for (int i = 0; i < 5 && _running; i++) Thread.Sleep(200);
                        continue;
                    }
                    Url = hit;
                }
                if (!Enabled)
                {
                    // 地址被清空：静置等待，不要每轮都抛"无效 URI"刷屏
                    for (int i = 0; i < 5 && _running; i++) Thread.Sleep(200);
                    continue;
                }
                try
                {
                    byte[] data = Fetch();
                    _lastFetchMs = State.NowMs() - t0;
                    if (data != null && data.Length > 0)
                    {
                        using (MemoryStream ms = new MemoryStream(data))
                        {
                            // 用临时 Bitmap 持有解码结果，锁外做，避免拖住渲染
                            using (Bitmap tmp = new Bitmap(ms))
                            {
                                int tw = tmp.Width, th = tmp.Height;
                                int longSide = Math.Max(tw, th);
                                if (longSide > MaxSourceSide && longSide > 0)
                                {
                                    double k = MaxSourceSide / (double)longSide;
                                    tw = Math.Max(1, (int)Math.Round(tw * k));
                                    th = Math.Max(1, (int)Math.Round(th * k));
                                }
                                lock (_gate)
                                {
                                    if (_buf == null || _buf.Width != tw || _buf.Height != th)
                                    {
                                        if (_buf != null) { try { _buf.Dispose(); } catch (Exception) { } }
                                        _buf = new Bitmap(tw, th, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                                    }
                                    using (Graphics g = Graphics.FromImage(_buf))
                                    {
                                        g.CompositingMode = CompositingMode.SourceCopy;
                                        g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                                        g.DrawImage(tmp, 0, 0, tw, th);
                                    }
                                    _w = tmp.Width; _h = tmp.Height;
                                    _bw = tw; _bh = th;
                                }
                            }
                        }
                        _atMs = State.NowMs();
                        _frames++;
                        _err = "";
                    }
                }
                catch (Exception ex)
                {
                    _errors++;
                    _err = ex.Message;
                    if (_errors <= 3 || _errors % 30 == 0)
                    {
                        Log.Err("VM 画面抓取失败（第 {0} 次）：{1}", _errors, ex.Message);
                    }
                }

                int wait = IntervalMs - (int)(State.NowMs() - t0);
                if (wait < 200) wait = 200;
                for (int i = 0; i < wait && _running; i += 100) Thread.Sleep(100);
            }
        }

        private byte[] Fetch()
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(Url);
            req.Timeout = TimeoutMs;
            req.ReadWriteTimeout = TimeoutMs;
            req.Method = "GET";
            req.Proxy = null;
            req.KeepAlive = false;
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            {
                using (Stream s = resp.GetResponseStream())
                {
                    using (MemoryStream ms = new MemoryStream())
                    {
                        byte[] buf = new byte[64 * 1024];
                        int n;
                        while ((n = s.Read(buf, 0, buf.Length)) > 0) ms.Write(buf, 0, n);
                        return ms.ToArray();
                    }
                }
            }
        }

        /// <summary>在锁内把当前画面交给渲染回调（没有画面时传 null）</summary>
        /// <summary>界面用的单行摘要</summary>
        public string Summary()
        {
            lock (_gate)
            {
                if (!Enabled) return "未配置地址（面板显示占位）";
                if (_frames == 0) return _errors > 0 ? ("抓不到：" + _err) : "连接中…";
                string which = Urls.Count > 1 ? ("（候选 " + (ActiveIndex + 1) + "/" + Urls.Count + "）") : "";
                // 年龄要显示出来：只写"12 帧"看不出画面是不是已经停了（鸿蒙版同样会显示）
                long age = _atMs == 0 ? -1 : State.NowMs() - _atMs;
                return string.Format("{0} 帧 · {1} · {2}x{3} · 抓取 {4}ms · 错误 {5}{6}",
                    _frames, age < 0 ? "刚刚" : ((age / 1000.0).ToString("0.0") + "s 前"),
                    _w, _h, _lastFetchMs, _errors, which);
            }
        }

        public void Render(Action<Bitmap, double, string> draw)
        {
            lock (_gate)
            {
                double age = _atMs == 0 ? -1 : (State.NowMs() - _atMs);
                string err = _err;
                if (!Enabled) err = "未配置 VM 画面地址";
                draw(_buf, age, err);
            }
        }

        public string Describe()
        {
            lock (_gate)
            {
                return string.Format("url={0} 帧={1} 错误={2} 源尺寸={3}x{4} 缓冲={5}x{6} 抓取={7}ms 最后一次错误={8}",
                    string.IsNullOrEmpty(Url) ? "(无)" : Url, _frames, _errors, _w, _h, _bw, _bh, _lastFetchMs,
                    string.IsNullOrEmpty(_err) ? "(无)" : _err);
            }
        }
    }
}
