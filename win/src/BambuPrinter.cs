using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;

namespace DshLcd
{
    /// <summary>
    /// 拓竹打印机取数编排：配置 → 云端发现设备 → MQTT 连接 → 订阅上报 → 定时 pushall →
    /// 断线重连 → 离线判定。整个能力在**本进程内**完成，不依赖 Node / 外部监控服务。
    ///
    /// ★ 2026-10-15 新增。对应 Node 的 `bambu-monitor/server.mjs` 里
    ///   `startMonitor()` + `_startMqtt()` + `startTimers()` 三块的职责。
    ///
    /// ## 线程模型
    /// 一个后台线程（`bambu`）跑主状态机：
    ///   · 发现设备（阻塞 HTTPS，最长 15 秒 × 区域数）
    ///   · 建 MQTT（自己的接收线程在 <see cref="MqttClient"/> 里）
    ///   · 之后每秒：检查离线、按间隔发 pushall、连接断了就退避重连
    ///
    /// ## 与桥的关系（重要）
    /// 本类**只接管打印机字段**。DSH 的 agent/token/事件等仍来自数据桥（UDP）。
    /// 两者可同时工作：<see cref="LcdRunner"/> 用本类的快照覆写 `Telemetry.Printer`。
    /// </summary>
    public class BambuPrinter
    {
        private readonly BambuConfig _cfg;
        private readonly BambuState _state = new BambuState();
        private Thread _thread;
        private volatile bool _running;
        private long _lastPushAllMs;
        private int _reconnectDelayMs = 3000;
        private MqttClient _mqtt;
        private string _serial = "";

        /// <summary>状态事件回调（上线/下线/开始打印/完成…），在取数线程上调用</summary>
        public Action<string, string> OnEvent;

        public BambuPrinter(BambuConfig cfg)
        {
            _cfg = cfg;
            _state.OnEvent = delegate (string t, string m)
            {
                Action<string, string> h = OnEvent;
                if (h != null) h(t, m);
            };
        }

        public BambuState State { get { return _state; } }

        /// <summary>当前打印机快照（没数据时返回 null）</summary>
        public PrinterInfo Snapshot() { return _state.Snapshot(); }

        /// <summary>是否在跑</summary>
        public bool Running { get { return _running; } }

        // ================= 启停 =================

        /// <summary>
        /// 启动。没有可用凭据时**不报错、直接返回 false**（打印机只是不显示，
        /// 不该影响 DSH 面板的其它部分）。
        /// </summary>
        public bool Start()
        {
            if (_running) return true;
            if (!_cfg.HasCredential)
            {
                _state.MonitorMode = "not-configured";
                Log.W("拓竹取数未启用：没有配置凭据（{0} 里填 token 或 cookie）", _cfg.Path);
                return false;
            }
            _running = true;
            _thread = new Thread(new ThreadStart(Run));
            _thread.IsBackground = true;
            _thread.Name = "bambu";
            _thread.Start();
            return true;
        }

        public void Stop()
        {
            _running = false;
            MqttClient m = _mqtt;
            if (m != null)
            {
                try { m.Close(); } catch (Exception) { }
            }
            _state.MarkDisconnected("程序退出");
        }

        // ================= 主循环 =================

        private void Run()
        {
            try
            {
                Bootstrap();
            }
            catch (Exception ex)
            {
                _state.MonitorMode = "error";
                _state.MonitorError = ex.Message;
                Log.Err("拓竹取数启动失败: {0}", ex.Message);
            }

            long lastStaleCheck = 0;
            while (_running)
            {
                try
                {
                    long now = DateTime.Now.Ticks / TimeSpan.TicksPerMillisecond;

                    // 离线判定（对齐 Node：每 15 秒查一次）
                    if (now - lastStaleCheck >= 15000)
                    {
                        lastStaleCheck = now;
                        _state.CheckStale(_cfg.OfflineTimeoutMs);
                    }

                    MqttClient m = _mqtt;
                    if (m != null && m.IsConnected && _serial.Length > 0)
                    {
                        // 定时 pushall：逼打印机上报全量状态（对齐 Node 的 pushallIntervalMs）
                        if (now - _lastPushAllMs >= _cfg.PushallIntervalMs)
                        {
                            _lastPushAllMs = now;
                            try
                            {
                                m.Publish("device/" + _serial + "/request",
                                          "{\"pushing\":{\"command\":\"pushall\"}}", 1);
                            }
                            catch (Exception ex)
                            {
                                Log.W("pushall 发送失败: {0}", ex.Message);
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Log.W("拓竹取数循环异常: {0}", ex.Message);
                }
                Thread.Sleep(1000);
            }
        }

        /// <summary>发现设备并建立 MQTT（对齐 Node 的 startMonitor）</summary>
        private void Bootstrap()
        {
            _state.MonitorMode = "discovering";
            string token = _cfg.ResolveToken();
            Log.W("拓竹凭据来源: {0}  token={1}",
                  _cfg.CredentialSource(), BambuConfig.Mask(token));

            string err;
            BambuDiscovery found = BambuCloud.Discover(token, _cfg.Region, _cfg.Cookie,
                                                       _cfg.Serial, _cfg.DeviceName, out err);
            if (found == null)
            {
                _state.MonitorMode = "error";
                _state.MonitorError = err == null ? "无法验证 token" : err;
                Log.Err("拓竹云端发现失败: {0}", _state.MonitorError);
                return;
            }

            _state.Region = found.Region;

            // 选设备（对齐 Node：serial 优先 → 在线优先 → 第一台）
            BambuDevice dev = null;
            if (!string.IsNullOrEmpty(_cfg.Serial))
            {
                for (int i = 0; i < found.Devices.Count; i++)
                {
                    if (found.Devices[i].DevId == _cfg.Serial) { dev = found.Devices[i]; break; }
                }
                if (dev == null) Log.W("配置的序列号 {0} 不在账号设备列表里，自动选择", _cfg.Serial);
            }
            if (dev == null)
            {
                for (int i = 0; i < found.Devices.Count; i++)
                {
                    if (found.Devices[i].Online) { dev = found.Devices[i]; break; }
                }
            }
            if (dev == null && found.Devices.Count > 0) dev = found.Devices[0];
            if (dev == null)
            {
                _state.MonitorMode = "error";
                _state.MonitorError = "账号下没有绑定打印机";
                Log.Err("{0}", _state.MonitorError);
                return;
            }

            _serial = dev.DevId;
            _state.DeviceId = dev.DevId;
            _state.DeviceName = string.IsNullOrEmpty(dev.DevName) ? dev.DevId : dev.DevName;
            _state.DeviceModel = dev.ProductName;
            if (string.IsNullOrEmpty(_cfg.Serial))
            {
                _cfg.Serial = dev.DevId;
                if (_cfg.Save()) Log.W("已自动保存打印机序列号: {0}", dev.DevId);
            }
            Log.W("拓竹设备: {0} ({1}) 型号={2} 在线={3}",
                  _state.DeviceName, dev.DevId, _state.DeviceModel, dev.Online ? "是" : "否");

            // MQTT 用户名：优先 u_<uid>（来自 preference 接口）
            string mqttUser = found.Username;
            if (string.IsNullOrEmpty(mqttUser)) mqttUser = token;   // 退化用 token（对齐 Node）
            _state.MqttUsername = mqttUser;

            string broker = BambuCloud.MqttHost(found.Region);
            Log.W("MQTT 认证: broker={0} username={1}", broker, BambuConfig.Mask(mqttUser));

            while (_running)
            {
                ConnectAndServe(broker, mqttUser, token);
                if (!_running) break;

                // 指数退避重连（对齐 Node：3 秒起，翻倍，上限 30 秒）
                Log.W("{0} 秒后重连…", _reconnectDelayMs / 1000);
                int waited = 0;
                while (_running && waited < _reconnectDelayMs) { Thread.Sleep(250); waited += 250; }
                _reconnectDelayMs = Math.Min(_reconnectDelayMs * 2, 30000);
            }
        }

        /// <summary>
        /// 建一条 MQTT 连接并服务到断开（阻塞）。
        /// 对齐 Node `_startMqtt`：连上后订阅 `device/<sn>/report`，随即发一次 pushall。
        /// </summary>
        private void ConnectAndServe(string broker, string username, string token)
        {
            // clientId 要唯一，否则同名连接会被 broker 踢掉
            string clientId = "dshlcd-" + Guid.NewGuid().ToString("N").Substring(0, 10);

            MqttClient m = new MqttClient(broker, 8883, clientId, username, token,
                                          30, !_cfg.Insecure);
            _mqtt = m;

            m.Connected += delegate
            {
                _reconnectDelayMs = 3000;          // 连上就重置退避
                _state.MarkConnected();
                Log.W("已连接 {0}，订阅 device/{1}/report", broker, _serial);

                // ★ 2026-10-15 关键修复：**订阅必须放到独立线程**。
                //   Connected 事件是在 MQTT 接收线程上触发的（HandlePacket 的 CONNACK 分支），
                //   而 Subscribe 要阻塞等 SUBACK —— SUBACK 只能由**同一个接收线程**读出来。
                //   直接在回调里 Subscribe 会形成自锁：接收线程等 SUBACK，而没人能读它。
                //   实测症状就是这个：日志停在"MQTT 已连接"，永远不出现"订阅成功"。
                Thread sub = new Thread(delegate ()
                {
                    try
                    {
                        if (m.Subscribe("device/" + _serial + "/report", 0, 10000, 3))
                        {
                            Log.W("订阅成功，请求全量状态 (pushall)");
                            m.Publish("device/" + _serial + "/request",
                                      "{\"pushing\":{\"command\":\"pushall\"}}", 1);
                            _lastPushAllMs = DateTime.Now.Ticks / TimeSpan.TicksPerMillisecond;
                        }
                        else
                        {
                            Log.Err("订阅 device/{0}/report 失败（将等下一轮重连）", _serial);
                        }
                    }
                    catch (Exception ex)
                    {
                        Log.Err("订阅线程异常: {0}", ex.Message);
                    }
                });
                sub.IsBackground = true;
                sub.Name = "mqtt-sub";
                sub.Start();
            };

            m.ConnectError += delegate (string msg)
            {
                _state.MonitorMode = "error";
                _state.MonitorError = msg;
                Log.Err("MQTT 连接失败: {0}（用户名 {1}）", msg, BambuConfig.Mask(username));
            };

            m.Message += delegate (string topic, string payload)
            {
                try
                {
                    _state.Feed(payload);
                }
                catch (Exception ex)
                {
                    Log.W("打印机报文解析失败: {0}", ex.Message);
                }
            };

            m.Closed += delegate (bool wasConnected)
            {
                _state.MarkDisconnected(wasConnected ? "MQTT 断开" : "连接未建立");
            };

            m.Connect();

            // 阻塞在这里，直到连接结束或要求停止。
            // ★ 必须用 IsDead（本方关 **或** 接收线程退出），
            //   只看 IsClosedByUs() 会在 broker 主动断开时死循环 → 永不重连。
            while (_running && !m.IsDead)
            {
                Thread.Sleep(500);
            }
            try { m.Close(); } catch (Exception) { }
            _mqtt = null;
        }
    }
}
