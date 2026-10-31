using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace DshLcd
{
    /// <summary>
    /// VM 监视地址探测。
    ///
    /// 为什么要它：livepad 的地址**随"谁在问"而变**——
    ///   · 在 Windows 虚拟机里            → http://172.16.101.1:8787/vm/frame.jpg（宿主的内部网卡）
    ///   · 在平板本机（宿主自己）        → http://127.0.0.1:8787/vm/frame.jpg
    ///   · 在局域网里另一台机器（插屏的 PC）→ http://&lt;平板的局域网IP&gt;:8787/vm/frame.jpg
    /// 所以不能写死一个地址：这里给"候选列表 + 本网段扫描"两条路，
    /// 谁能取到帧就用谁，并把选中的那个写回 ini。
    /// </summary>
    public static class VmProbe
    {
        public const int DefaultPort = 8787;
        public const string FramePath = "/vm/frame.jpg";

        /// <summary>默认候选（按可能性排序）：本机 → 虚拟机内部看到的宿主 → 常见网关</summary>
        public static List<string> DefaultCandidates(int port)
        {
            List<string> list = new List<string>();
            list.Add("http://127.0.0.1:" + port + FramePath);
            list.Add("http://172.16.101.1:" + port + FramePath);      // 本项目的鸿蒙虚拟机网段
            list.Add("http://172.16.101.1:" + port + "/vm/frame.jpg");
            // 本机所在网段的 .1（很多场景下宿主就是网关）
            try
            {
                string local = LocalIPv4();
                if (local != null)
                {
                    string[] parts = local.Split('.');
                    if (parts.Length == 4)
                    {
                        list.Add("http://" + parts[0] + "." + parts[1] + "." + parts[2] + ".1:" + port + FramePath);
                    }
                }
            }
            catch (Exception) { }
            // 去重
            List<string> uniq = new List<string>();
            for (int i = 0; i < list.Count; i++)
            {
                if (!uniq.Contains(list[i])) uniq.Add(list[i]);
            }
            return uniq;
        }

        public static string LocalIPv4()
        {
            try
            {
                IPAddress[] all = Dns.GetHostAddresses(Dns.GetHostName());
                for (int i = 0; i < all.Length; i++)
                {
                    if (all[i].AddressFamily == AddressFamily.InterNetwork) return all[i].ToString();
                }
            }
            catch (Exception) { }
            return null;
        }

        /// <summary>试取一帧：成功返回 (帧字节数, 用时ms)，失败返回 (-1, 用时)</summary>
        public static bool TryFetch(string url, out int bytes, out long ms, out string err)
        {
            bytes = -1; ms = 0; err = "";
            long t0 = State.NowMs();
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = 2500;
                req.ReadWriteTimeout = 2500;
                req.Proxy = null;
                req.Method = "GET";
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                using (Stream s = resp.GetResponseStream())
                {
                    byte[] buf = new byte[8192];
                    int n = s.Read(buf, 0, buf.Length);
                    if (n <= 0) { err = "空响应"; ms = State.NowMs() - t0; return false; }
                    bytes = n;
                    ms = State.NowMs() - t0;
                    return true;
                }
            }
            catch (Exception ex)
            {
                err = ex.Message;
                ms = State.NowMs() - t0;
                return false;
            }
        }

        /// <summary>
        /// 扫本网段的 8787 端口，找出活着的 livepad。
        /// 只在"候选都不通"时才用（它要并发连 254 个地址，约 3-6 秒）。
        /// </summary>
        public static List<string> ScanLan(int port, int timeoutMs)
        {
            List<string> found = new List<string>();
            string local = LocalIPv4();
            if (local == null) return found;
            string[] parts = local.Split('.');
            if (parts.Length != 4) return found;
            string prefix = parts[0] + "." + parts[1] + "." + parts[2] + ".";

            List<Thread> threads = new List<Thread>();
            object gate = new object();
            for (int host = 1; host <= 254; host++)
            {
                int h = host;
                Thread t = new Thread(delegate()
                {
                    string ip = prefix + h;
                    if (ip == local) return;
                    try
                    {
                        using (TcpClient c = new TcpClient())
                        {
                            IAsyncResult ar = c.BeginConnect(ip, port, null, null);
                            if (ar.AsyncWaitHandle.WaitOne(timeoutMs) && c.Connected)
                            {
                                lock (gate) { found.Add("http://" + ip + ":" + port + FramePath); }
                            }
                        }
                    }
                    catch (Exception) { }
                });
                t.IsBackground = true;
                threads.Add(t);
                t.Start();
                // 限并发：每 48 个等一批，避免把系统句柄打满
                if (threads.Count >= 48)
                {
                    for (int i = 0; i < threads.Count; i++) threads[i].Join(timeoutMs + 500);
                    threads.Clear();
                }
            }
            for (int i = 0; i < threads.Count; i++) threads[i].Join(timeoutMs + 500);
            return found;
        }

        /// <summary>
        /// 完整探测：先逐个试候选，再（可选）扫本网段。
        /// 返回第一个能取到帧的地址；找不到返回 null。
        /// </summary>
        public static string Probe(List<string> candidates, bool scanLan, out string report)
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("== VM 监视地址探测 ==");
            sb.AppendLine("本机 IPv4：" + (LocalIPv4() == null ? "（取不到）" : LocalIPv4()));
            List<string> tried = new List<string>();
            if (candidates != null)
            {
                for (int i = 0; i < candidates.Count; i++)
                {
                    string u = candidates[i];
                    if (string.IsNullOrEmpty(u) || tried.Contains(u)) continue;
                    tried.Add(u);
                    int bytes; long ms; string err;
                    bool ok = TryFetch(u, out bytes, out ms, out err);
                    sb.AppendLine(string.Format("  {0,-52} {1}", u, ok ? ("✅ " + bytes + " 字节 / " + ms + "ms") : ("❌ " + err)));
                    if (ok)
                    {
                        report = sb.ToString();
                        return u;
                    }
                }
            }
            if (scanLan)
            {
                sb.AppendLine("候选都不通 → 扫本网段的 " + DefaultPort + " 端口（约 3-6 秒）…");
                List<string> hits = ScanLan(DefaultPort, 250);
                sb.AppendLine("  发现 " + hits.Count + " 个在监听的主机");
                for (int i = 0; i < hits.Count; i++)
                {
                    int bytes; long ms; string err;
                    bool ok = TryFetch(hits[i], out bytes, out ms, out err);
                    sb.AppendLine(string.Format("  {0,-52} {1}", hits[i], ok ? ("✅ " + bytes + " 字节 / " + ms + "ms") : ("❌ " + err)));
                    if (ok)
                    {
                        report = sb.ToString();
                        return hits[i];
                    }
                }
            }
            report = sb.ToString();
            return null;
        }

        /// <summary>
        /// 把用户填的一行文本拆成候选列表（支持逗号/分号/空格分隔）。
        ///
        /// 容错是重点——用户最想输的其实只是"IP"或"IP/vm"，所以要能自动补全：
        ///   172.16.101.1              → http://172.16.101.1:8787/vm/frame.jpg
        ///   172.16.101.1/vm           → http://172.16.101.1:8787/vm/frame.jpg
        ///   172.16.101.1/vm/          → 同上
        ///   192.168.11.120:8787/vm    → http://192.168.11.120:8787/vm/frame.jpg
        ///   http://host:9000          → http://host:9000/vm/frame.jpg
        ///   http://host:9000/vm/frame.jpg → 原样保留
        /// （之前只判断 "/vm/"，输入 "/vm" 会拼成 /vm/vm/frame.jpg，这是个真 bug。）
        /// </summary>
        public static List<string> ParseList(string text)
        {
            List<string> outList = new List<string>();
            if (string.IsNullOrEmpty(text)) return outList;
            string[] parts = text.Split(new char[] { ',', ';', ' ', '\r', '\n', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            for (int i = 0; i < parts.Length; i++)
            {
                string u = Normalize(parts[i]);
                if (u.Length > 0 && !outList.Contains(u)) outList.Add(u);
            }
            return outList;
        }

        /// <summary>把一条用户输入规范成完整的取帧地址</summary>
        public static string Normalize(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return "";
            string u = raw.Trim();
            if (u.Length == 0) return "";
            if (!u.StartsWith("http://") && !u.StartsWith("https://"))
            {
                u = "http://" + u;
            }
            // 拆出 host:port 与 path（同时把 ?查询串 单独摘出来，令牌 k=... 要保留）
            int qm = u.IndexOf('?');
            string query = qm >= 0 ? u.Substring(qm) : "";
            string bare = qm >= 0 ? u.Substring(0, qm) : u;
            int slash = bare.IndexOf('/', bare.IndexOf("//") + 2);
            string origin = slash < 0 ? bare : bare.Substring(0, slash);
            string path = slash < 0 ? "" : bare.Substring(slash);
            // 没写端口就补默认端口
            string hostPart = origin.Substring(origin.IndexOf("//") + 2);
            if (hostPart.IndexOf(':') < 0)
            {
                origin = origin + ":" + DefaultPort;
            }
            // 路径规范化
            string p = path.TrimEnd('/');
            if (p.Length == 0 || p == "/vm" || p == "/frame" || p == "/frame.jpg")
            {
                p = FramePath;
            }
            else if (p.EndsWith("/frame.jpg"))
            {
                // 已经是取帧地址，原样
            }
            else if (p.EndsWith("/vm"))
            {
                p = p + "/frame.jpg";
            }
            else
            {
                // 其它路径（例如用户直接给了 livepad 根路径）：补成取帧接口
                p = p + FramePath;
            }
            return origin + p + query;
        }
}}
