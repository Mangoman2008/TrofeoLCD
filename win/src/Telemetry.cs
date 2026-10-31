using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace DshLcd
{
    /// <summary>
    /// UDP 遥测接收（默认 127.0.0.1:54545）。
    /// 与鸿蒙版同协议：桥端（bridge/dsh-bridge.mjs）每个周期把一个完整 JSON 快照发过来。
    /// Windows 版额外支持 --udp-any：桥端跑在别的机器上时监听 0.0.0.0。
    /// </summary>
    public class TelemetryReceiver
    {
        public const int DefaultPort = 54545;

        private readonly State _state;
        private UdpClient _udp;
        private Thread _thread;
        private volatile bool _running;
        private int _boundPort;
        private bool _anyAddress;

        public TelemetryReceiver(State state, int port, bool anyAddress)
        {
            _state = state;
            _boundPort = port;
            _anyAddress = anyAddress;
        }

        public bool Running { get { return _running; } }
        public int Port { get { return _boundPort; } }
        public string BindDesc { get { return (_anyAddress ? "0.0.0.0:" : "127.0.0.1:") + _boundPort; } }

        public bool Start()
        {
            try
            {
                IPEndPoint ep = new IPEndPoint(_anyAddress ? IPAddress.Any : IPAddress.Loopback, _boundPort);
                _udp = new UdpClient();
                _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                _udp.Client.Bind(ep);
                _udp.Client.ReceiveTimeout = 1000;
                _running = true;
                _thread = new Thread(new ThreadStart(Loop));
                _thread.IsBackground = true;
                _thread.Name = "udp-telemetry";
                _thread.Start();
                Log.W("UDP 遥测已监听 {0}", BindDesc);
                return true;
            }
            catch (Exception ex)
            {
                Log.Err("UDP 监听失败（{0}）：{1}", BindDesc, ex.Message);
                _running = false;
                return false;
            }
        }

        private void Loop()
        {
            IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
            while (_running)
            {
                try
                {
                    byte[] data = _udp.Receive(ref remote);
                    if (data == null || data.Length == 0) continue;
                    string text = Encoding.UTF8.GetString(data);
                    if (!_state.ApplyText(text))
                    {
                        Log.Err("遥测包解析失败（{0} 字节，来自 {1}）", data.Length, remote);
                    }
                }
                catch (SocketException se)
                {
                    // 超时是正常的（1 秒），其余才值得记
                    if (se.SocketErrorCode != SocketError.TimedOut && _running)
                    {
                        Log.Err("UDP 接收异常：{0}", se.Message);
                        Thread.Sleep(200);
                    }
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
                catch (Exception ex)
                {
                    if (_running) Log.Err("UDP 循环异常：{0}", ex.Message);
                    Thread.Sleep(200);
                }
            }
        }

        public void Stop()
        {
            _running = false;
            try { if (_udp != null) _udp.Close(); } catch (Exception) { }
            try { if (_thread != null) _thread.Join(1500); } catch (Exception) { }
        }
    }
}
