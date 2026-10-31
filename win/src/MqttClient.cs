using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

namespace DshLcd
{
    /// <summary>
    /// 零依赖 MQTT 3.1.1 客户端（TLS/TCP），用于拓竹云端 broker。
    ///
    /// ★ 2026-10-15 新增：把本机 `bambu-monitor`（Node 服务，`lib/mqtt.mjs`）的能力
    ///   移植进 C# 程序自身 —— 这样 dshlcd **不再依赖 Node 与外部取数服务**，
    ///   直接连 `cn.mqtt.bambulab.com:8883` 订阅打印机上报。
    ///
    /// 逐条对齐 Node 原实现（`lib/mqtt.mjs`，274 行）：
    ///   · 报文类型常量、剩余长度变字节编码、UTF-8 长度前缀串 —— 完全一致
    ///   · CONNECT：`MQTT` + 版本 4 + clean-session + 用户名/密码
    ///   · 收包循环：按需从缓冲区切出完整包（**粘包/拆包都处理**）
    ///   · PUBLISH：QoS>0 时回 PUBACK
    ///   · SUBSCRIBE：带 packetId，等 SUBACK（超时 10 秒）
    ///   · PINGREQ：keepalive/2 间隔；连续 2 次无 PINGRESP 判定连接失效
    ///   · PUBLISH 发报文（QoS 1）
    ///
    /// ⚠️ C# 5 约束：不能用 async/await。内部用独立线程 + 阻塞读，
    ///    调用方通过事件回调拿到消息（回调在**接收线程**上执行，要快）。
    /// </summary>
    public class MqttClient
    {
        // ---------- 报文类型（对应 Node 的 PKT）----------
        private const byte PKT_CONNECT = 0x10;
        private const byte PKT_CONNACK = 0x20;
        private const byte PKT_PUBLISH = 0x30;
        private const byte PKT_PUBACK = 0x40;
        private const byte PKT_SUBSCRIBE = 0x82;
        private const byte PKT_SUBACK = 0x90;
        private const byte PKT_PINGREQ = 0xc0;
        private const byte PKT_PINGRESP = 0xd0;
        private const byte PKT_DISCONNECT = 0xe0;

        private readonly string _host;
        private readonly int _port;
        private readonly string _clientId;
        private readonly string _username;
        private readonly string _password;
        private readonly int _keepaliveSec;
        private readonly bool _rejectUnauthorized;

        private TcpClient _tcp;
        private SslStream _ssl;
        private Thread _rxThread;
        /// <summary>
        /// 接收线程引用。★ 2026-10-15：用来**防死锁**。
        /// 事件的回调（Connected/Message/Closed）都在接收线程上执行；
        /// 若回调里调用 Subscribe（要等 SUBACK），而 SUBACK 必须由**同一个接收线程**读出来，
        /// 就会永久阻塞 —— 实测症状：日志停在"MQTT 已连接"，永远等不到"订阅成功"。
        /// </summary>
        private volatile bool _closed;
        private volatile bool _connected;
        private int _pendingPings;
        private int _packetId = 1;

        /// <summary>订阅等待表：packetId → 结果（-1 表示还未回来）</summary>
        private readonly Dictionary<int, int> _subAcks = new Dictionary<int, int>();
        private readonly object _lock = new object();

        /// <summary>已连接（CONNACK 成功）</summary>
        public event Action Connected;
        /// <summary>连接被拒（含原因）</summary>
        public event Action<string> ConnectError;
        /// <summary>收到 PUBLISH：topic, payload</summary>
        public event Action<string, string> Message;
        /// <summary>连接关闭：wasConnected</summary>
        public event Action<bool> Closed;

        /// <summary>
        /// 包级追踪开关（默认关，正常运行不刷屏）。
        /// ★ 2026-10-15 加：排查"订阅超时"时，需要知道**每一个字节的收发**，
        ///   否则只能靠猜。自检程序会打开它；主程序启动加 `--mqtt-debug` 也会打开。
        /// </summary>
        public static bool Diagnostic;

        /// <summary>接收线程还活着吗（Run() 进入时置 true，退出时置 false）</summary>
        private volatile bool _rxAlive;

        public bool IsConnected { get { return _connected; } }

        /// <summary>
        /// 连接是否已终结（本方主动关，**或**接收线程已退出）。
        /// ★ 2026-10-15 关键修复：重连循环原来只看 `IsClosedByUs()`，
        ///   而对端（broker）主动断开时那个条件是 false → 等待循环**永远不退出**，
        ///   也就永远不会重连（程序看起来还在跑，但数据永远不再更新）。
        /// </summary>
        public bool IsDead { get { return _closed || !_rxAlive; } }
        /// <summary>是否已被本方 Close()（区别于被对端断开）—— 重连循环靠它判断该不该退出</summary>
        public bool IsClosedByUs() { return _closed; }
        public string Host { get { return _host; } }
        public int Port { get { return _port; } }

        public MqttClient(string host, int port, string clientId, string username,
                          string password, int keepaliveSec, bool rejectUnauthorized)
        {
            _host = host;
            _port = port;
            _clientId = clientId;
            _username = username;
            _password = password;
            _keepaliveSec = keepaliveSec <= 0 ? 30 : keepaliveSec;
            _rejectUnauthorized = rejectUnauthorized;
        }

        // ================= 连接 =================

        /// <summary>异步发起连接（内部起接收线程，立即返回）</summary>
        /// <summary>
        /// 发起连接。★ 防重复：已经连接/正在连接时直接返回。
        /// 否则会起**两个接收线程抢同一个 socket**（字节互相抢，包会被拆开丢弃）。
        /// </summary>
        public void Connect()
        {
            if (_rxAlive && !_closed) return;
            if (_rxThread != null && _rxThread.IsAlive && !_closed)
            {
                Log.W("MQTT 已在连接中，忽略重复的 Connect()");
                return;
            }
            _closed = false;
            _rxAlive = true;
            Thread t = new Thread(new ThreadStart(Run));
            t.IsBackground = true;
            t.Name = "mqtt";
            _rxThread = t;
            t.Start();
        }

        private void Run()
        {
            _rxAlive = true;
            try
            {
                Log.W("MQTT 连接 {0}:{1} ...", _host, _port);
                _tcp = new TcpClient();
                _tcp.NoDelay = true;
                _tcp.Connect(_host, _port);

                _ssl = new SslStream(_tcp.GetStream(), false, new RemoteCertificateValidationCallback(ValidateCert));
                _ssl.AuthenticateAsClient(_host, null, SslProtocols.Tls12, false);

                SendConnect();
                RxLoop();
            }
            catch (Exception ex)
            {
                if (!_closed)
                {
                    Log.Err("MQTT 套接字错误: {0}", ex.Message);
                    FireClosed();
                }
            }
        }

        /// <summary>证书校验：默认要求有效；`--bambu-insecure` 时全部放行（自签代理场景）</summary>
        private bool ValidateCert(object sender, X509Certificate cert, X509Chain chain,
                                  SslPolicyErrors errors)
        {
            if (errors == SslPolicyErrors.None) return true;
            if (!_rejectUnauthorized)
            {
                Log.W("MQTT 证书校验失败但已放行（insecure）: {0}", errors);
                return true;
            }
            Log.Err("MQTT 证书校验失败: {0}", errors);
            return false;
        }

        // ================= 发报文 =================

        /// <summary>MQTT 剩余长度：7 位一组，最高位表示还有后续（对齐 Node encodeRemainingLength）</summary>
        private static byte[] EncodeRemainingLength(int len)
        {
            List<byte> outp = new List<byte>();
            do
            {
                int digit = len % 128;
                len = len / 128;
                if (len > 0) digit |= 0x80;
                outp.Add((byte)digit);
            } while (len > 0);
            return outp.ToArray();
        }

        /// <summary>UTF-8 字符串加 2 字节大端长度前缀（MQTT 的"UTF-8 编码字符串"）</summary>
        private static byte[] Utf8LenPrefixed(string s)
        {
            byte[] raw = Encoding.UTF8.GetBytes(s == null ? "" : s);
            byte[] outp = new byte[2 + raw.Length];
            outp[0] = (byte)(raw.Length >> 8);
            outp[1] = (byte)(raw.Length & 0xff);
            Buffer.BlockCopy(raw, 0, outp, 2, raw.Length);
            return outp;
        }

        private static byte[] Concat(params byte[][] parts)
        {
            int n = 0;
            for (int i = 0; i < parts.Length; i++) n += parts[i].Length;
            byte[] outp = new byte[n];
            int off = 0;
            for (int i = 0; i < parts.Length; i++)
            {
                Buffer.BlockCopy(parts[i], 0, outp, off, parts[i].Length);
                off += parts[i].Length;
            }
            return outp;
        }

        private void SendConnect()
        {
            byte flags = 0x02;                       // clean session
            List<byte[]> parts = new List<byte[]>();
            parts.Add(Utf8LenPrefixed(_clientId));
            if (_username != null)
            {
                flags |= 0x80;                       // 有用户名
                parts.Add(Utf8LenPrefixed(_username));
                flags |= 0x40;                       // 有密码
                parts.Add(Utf8LenPrefixed(_password == null ? "" : _password));
            }
            byte[] payload = Concat(parts.ToArray());

            byte[] vh = Concat(Utf8LenPrefixed("MQTT"),
                               new byte[] { 0x04, flags },
                               new byte[] { (byte)(_keepaliveSec / 256), (byte)(_keepaliveSec % 256) });
            byte[] remaining = Concat(vh, payload);
            WritePacket(PKT_CONNECT, remaining);
        }

        private void WritePacket(byte type, byte[] body)
        {
            try
            {
                SslStream s = _ssl;
                if (s == null || _closed) return;
                byte[] header = Concat(new byte[] { type }, EncodeRemainingLength(body.Length));
                byte[] whole = Concat(header, body);
                lock (_lock) { s.Write(whole, 0, whole.Length); s.Flush(); }
                if (Diagnostic) Log.W("[mqtt] 发送包 type=0x{0:X2} 共 {1} 字节", type, whole.Length);
            }
            catch (Exception ex)
            {
                if (!_closed) Log.Err("MQTT 发送失败: {0}", ex.Message);
            }
        }

        // ================= 收包 =================

        private void RxLoop()
        {
            // ★ 2026-10-15 重写缓冲区管理。两个原来的问题：
            //   ① **性能**：每切一个包都 `acc.ToArray()`（全量拷贝）+ `new MemoryStream()`
            //      + BlockCopy。broker 每秒推多条，其中一条实测 **7421 字节**，
            //      在接收线程上持续产生垃圾（这线程还要跑 HandlePacket）。
            //   ② **缓冲太小会死循环**：原来读缓冲固定 8192，而一个 MQTT 包
            //      （PUBLISH 的 body 就是整个 print 对象）实测已达 7421 字节。
            //      一旦单包 > 8192，compact 后的可用空间仍装不下一个包 →
            //      `while` 永远凑不齐 → **无限循环**。
            //
            //   现在：缓冲区自动增长（够放一个整包为止）+ 只移动未消费的残余，
            //   不做任何全量拷贝。
            byte[] acc = new byte[65536];
            int accLen = 0;

            // 心跳线程：keepalive/2 秒一次，连续 2 次没 PINGRESP 就断开
            int pingMs = Math.Max(5, _keepaliveSec / 2) * 1000;
            Thread ping = new Thread(delegate ()
            {
                while (!_closed)
                {
                    Thread.Sleep(pingMs);
                    if (_closed || !_connected) continue;
                    if (_pendingPings >= 2)
                    {
                        Log.W("MQTT PING 无响应，判定连接失效");
                        Close();
                        return;
                    }
                    _pendingPings++;
                    WritePacket(PKT_PINGREQ, new byte[0]);
                }
            });
            ping.IsBackground = true;
            ping.Name = "mqtt-ping";
            ping.Start();

            try
            {
                while (!_closed)
                {
                    // 先腾地方：把未消费的残余移到数组头部
                    if (accLen > 0 && accLen == acc.Length)
                    {
                        int leftoverStart, leftoverLen;
                        if (TryFindFirstPacket(acc, accLen, out leftoverStart, out leftoverLen))
                        {
                            // 有完整包却还占满整个缓冲 → 缓冲不够大，扩容
                            int newSize = acc.Length * 2;
                            if (newSize < accLen + 65536) newSize = accLen + 65536;
                            Log.W("MQTT 接收缓冲不足（已用 {0} 字节），扩容到 {1}", acc.Length, newSize);
                            byte[] bigger = new byte[newSize];
                            Buffer.BlockCopy(acc, 0, bigger, 0, accLen);
                            acc = bigger;
                        }
                        else
                        {
                            // 没有完整包：把残余搬到头部，腾出后半空间
                            Buffer.BlockCopy(acc, leftoverStart, acc, 0, leftoverLen);
                            accLen = leftoverLen;
                        }
                    }

                    int n = (_ssl != null) ? _ssl.Read(acc, accLen, acc.Length - accLen) : 0;
                    if (n <= 0)
                    {
                        Log.W("MQTT 接收流结束（Read 返回 {0}）", n);
                        break;
                    }
                    if (Diagnostic) Log.W("[mqtt] Read {0} 字节（缓冲 {1} -> {2}）", n, accLen, accLen + n);
                    accLen += n;

                    // 缓冲区里能切出几个完整包就处理几个（粘包）
                    int off = 0;
                    for (; ; )
                    {
                        byte type, flags;
                        byte[] body;
                        int consumed;
                        if (!TryParsePacketAt(acc, off, accLen, out type, out flags, out body, out consumed)) break;
                        if (Diagnostic) Log.W("[mqtt] 切出包 type=0x{0:X2} body={1} 字节 consumed={2}",
                                              type, body == null ? 0 : body.Length, consumed);
                        off += consumed;
                        HandlePacket(type, flags, body);
                    }

                    // 把未消费的残余搬回数组头部，供下一轮拼接
                    if (off > 0)
                    {
                        int rest = accLen - off;
                        if (rest > 0) Buffer.BlockCopy(acc, off, acc, 0, rest);
                        accLen = rest;
                    }
                }
            }
            catch (Exception ex)
            {
                if (!_closed) Log.Err("MQTT 接收异常: {0}", ex.Message);
            }
            finally
            {
                FireClosed();
            }
        }

        /// <summary>
        /// 在 `[0, len)` 里找**第一个完整包**的位置与长度。
        /// 只用于"缓冲区满了但里面有完整包"的扩容判断，不做拷贝。
        /// 找不到完整包时返回 false，并把 `start=0, len=len`（即整块都是残余）。
        /// </summary>
        private static bool TryFindFirstPacket(byte[] buf, int len, out int start, out int pktLen)
        {
            start = 0; pktLen = len;
            if (len < 2) return false;
            int pos = 1, rem = 0, mul = 1;
            bool done = false;
            for (int i = 0; i < 4; i++)
            {
                if (pos >= len) return false;
                byte digit = buf[pos++];
                rem += (digit & 0x7f) * mul;
                mul *= 128;
                if ((digit & 0x80) == 0) { done = true; break; }
            }
            if (!done) return false;
            int total = pos + rem;
            if (len < total) return false;
            start = 0; pktLen = total;
            return true;
        }

        /// <summary>
        /// 从 <paramref name="buf"/> 的 <paramref name="off"/> 处尝试切一个包。
        /// 与旧版（已删除的 `TryParsePacket`）同一套逻辑，只是多了起始偏移、
        /// 并用 <paramref name="len"/> 表示"有效数据到哪"（避免每次拷贝）。
        /// </summary>
        private static bool TryParsePacketAt(byte[] buf, int off, int len,
                                             out byte type, out byte flags,
                                             out byte[] body, out int consumed)
        {
            type = 0; flags = 0; body = null; consumed = 0;
            if (len - off < 2) return false;

            byte first = buf[off];
            int remLen = 0, multiplier = 1, pos = off + 1;
            bool done = false;
            for (int i = 0; i < 4; i++)
            {
                if (pos >= len) return false;          // 长度字段还没收全
                byte digit = buf[pos++];
                remLen += (digit & 0x7f) * multiplier;
                multiplier *= 128;
                if ((digit & 0x80) == 0) { done = true; break; }
            }
            if (!done) return false;                   // 非法长度字段
            int total = pos + remLen;
            if (len < total) return false;              // 包体还没收全

            type = (byte)(first & 0xf0);
            flags = (byte)(first & 0x0f);
            body = new byte[remLen];
            Buffer.BlockCopy(buf, pos, body, 0, remLen);
            consumed = total - off;
            return true;
        }


        private static int ReadU16(byte[] b, int off)
        {
            return (b[off] << 8) | b[off + 1];
        }

        private void HandlePacket(byte type, byte flags, byte[] body)
        {
            switch (type)
            {
                case PKT_CONNACK:
                    {
                        byte rc = body.Length > 1 ? body[1] : (byte)255;
                        if (rc == 0)
                        {
                            _connected = true;
                            Log.W("MQTT 已连接（{0}）", _host);
                            Action h = Connected;
                            if (h != null) h();
                        }
                        else
                        {
                            string reason = ConnackReason(rc);
                            Log.Err("MQTT 连接被拒绝: {0}", reason);
                            Action<string> e = ConnectError;
                            if (e != null) e("CONNACK " + rc + ": " + reason);
                            Close();
                        }
                        break;
                    }

                case PKT_PUBLISH:
                    {
                        if (body.Length < 2) break;
                        int topicLen = ReadU16(body, 0);
                        int pos = 2;
                        if (pos + topicLen > body.Length) break;
                        string topic = Encoding.UTF8.GetString(body, pos, topicLen);
                        pos += topicLen;
                        int qos = (flags >> 1) & 0x03;
                        int packetId = 0;
                        if (qos > 0)
                        {
                            if (pos + 2 > body.Length) break;
                            packetId = ReadU16(body, pos);
                            pos += 2;
                        }
                        string payload = pos < body.Length
                            ? Encoding.UTF8.GetString(body, pos, body.Length - pos)
                            : "";
                        if (qos == 1) SendPuback(packetId);
                        Action<string, string> m = Message;
                        if (m != null) m(topic, payload);
                        break;
                    }

                case PKT_SUBACK:
                    {
                        // ★ 诊断日志：SUBACK 到底有没有收到（第一版实测"订阅超时"时无从判断）
                        Log.W("MQTT 收到 SUBACK：packetId={0} granted={1}（body {2} 字节）",
                              body.Length >= 2 ? ReadU16(body, 0) : -1,
                              body.Length >= 3 ? body[2].ToString() : "?",
                              body.Length);
                        if (body.Length < 3) break;
                        int packetId = ReadU16(body, 0);
                        lock (_lock)
                        {
                            if (_subAcks.ContainsKey(packetId)) _subAcks[packetId] = body[2];
                            else Log.W("SUBACK 的 packetId={0} 不在等待表里（等待表: {1}）",
                                       packetId, string.Join(",", SubAckKeys()));
                        }
                        break;
                    }

                case PKT_PINGRESP:
                    _pendingPings = 0;
                    break;

                case PKT_PUBACK:
                    break;

                default:
                    Log.W("未处理 MQTT 包类型 0x{0:X2}", type);
                    break;
            }
        }

        private static string ConnackReason(byte rc)
        {
            switch (rc)
            {
                case 1: return "协议版本不支持";
                case 2: return "标识符被拒绝";
                case 3: return "服务器不可用";
                case 4: return "用户名或密码错误";
                case 5: return "未授权";
                default: return "未知(" + rc + ")";
            }
        }

        private void SendPuback(int packetId)
        {
            WritePacket(PKT_PUBACK, new byte[] { (byte)(packetId >> 8), (byte)(packetId & 0xff) });
        }

        // ================= 订阅 / 发布 =================

        /// <summary>订阅主题；等 SUBACK，超时 10 秒返回 false</summary>
        public bool Subscribe(string topic, int qos, int timeoutMs)
        {
            return Subscribe(topic, qos, timeoutMs, 1);
        }

        /// <summary>
        /// 订阅主题（带重试）。SUBACK 偶尔丢失时重发，避免整条取数链路失效。
        /// </summary>
        public bool Subscribe(string topic, int qos, int timeoutMs, int attempts)
        {
            for (int i = 0; i < Math.Max(1, attempts); i++)
            {
                if (i > 0) Log.W("重试订阅（第 {0} 次）：{1}", i + 1, topic);
                if (SubscribeOnce(topic, qos, timeoutMs)) return true;
                if (_closed) return false;
            }
            return false;
        }

        private bool SubscribeOnce(string topic, int qos, int timeoutMs)
        {
            // ★ 死锁防线：绝不能在接收线程上阻塞等待 SUBACK —— SUBACK 只能由接收线程读出来。
            //   正确做法见 BambuPrinter：把订阅放到**独立的短命线程**里做。
            if (Thread.CurrentThread == _rxThread)
            {
                Log.Err("Subscribe 不能在 MQTT 接收线程上调用（会死锁），已拒绝：{0}", topic);
                return false;
            }
            int packetId;
            lock (_lock)
            {
                packetId = _packetId++;
                if (_packetId > 65535) _packetId = 1;
                _subAcks[packetId] = -1;
            }
            if (Diagnostic) Log.W("[mqtt] 已登记等待 packetId={0}（当前等待表: {1}）",
                                  packetId, string.Join(",", SubAckKeys()));
            byte[] body = Concat(new byte[] { (byte)(packetId >> 8), (byte)(packetId & 0xff) },
                                 Utf8LenPrefixed(topic),
                                 new byte[] { (byte)qos });
            Log.W("MQTT 发送 SUBSCRIBE：topic={0} packetId={1}（{2} 字节）", topic, packetId, body.Length);
            WritePacket(PKT_SUBSCRIBE, body);

            int waited = 0;
            while (waited < timeoutMs)
            {
                lock (_lock)
                {
                    if (_subAcks.ContainsKey(packetId) && _subAcks[packetId] != -1)
                    {
                        _subAcks.Remove(packetId);
                        return true;
                    }
                }
                Thread.Sleep(20);
                waited += 20;
                if (_closed) break;
            }
            lock (_lock) { _subAcks.Remove(packetId); }
            Log.Err("SUBSCRIBE {0} 超时", topic);
            return false;
        }

        /// <summary>等待表里的 packetId 列表（仅诊断日志用）</summary>
        private string[] SubAckKeys()
        {
            lock (_lock)
            {
                string[] ks = new string[_subAcks.Count];
                int i = 0;
                foreach (int k in _subAcks.Keys) ks[i++] = k.ToString();
                return ks;
            }
        }

        /// <summary>发布消息（qos 1）</summary>
        public void Publish(string topic, string payload, int qos)
        {
            byte[] data = Encoding.UTF8.GetBytes(payload == null ? "" : payload);
            byte[] body;
            if (qos > 0)
            {
                int packetId;
                lock (_lock)
                {
                    packetId = _packetId++;
                    if (_packetId > 65535) _packetId = 1;
                }
                body = Concat(Utf8LenPrefixed(topic),
                              new byte[] { (byte)(packetId >> 8), (byte)(packetId & 0xff) },
                              data);
            }
            else
            {
                body = Concat(Utf8LenPrefixed(topic), data);
            }
            WritePacket((byte)(PKT_PUBLISH | (qos << 1)), body);
        }

        // ================= 收尾 =================

        private void FireClosed()
        {
            _rxAlive = false;
            bool wasConnected = _connected;
            _connected = false;
            _pendingPings = 0;
            lock (_lock) { _subAcks.Clear(); }
            if (!_closed)
            {
                Log.W("MQTT 连接关闭");
                Action<bool> c = Closed;
                if (c != null) c(wasConnected);
            }
        }

        public void Close()
        {
            _closed = true;
            try { WritePacket(PKT_DISCONNECT, new byte[0]); } catch (Exception) { }
            try { if (_ssl != null) _ssl.Close(); } catch (Exception) { }
            try { if (_tcp != null) _tcp.Close(); } catch (Exception) { }
        }
    }
}
