using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace DshLcd
{
    /// <summary>
    /// 诊断 + 网页预览服务（默认 0.0.0.0:54546，与鸿蒙版端口一致）。
    ///
    /// 用裸 TcpListener 而不是 HttpListener：后者在非管理员下需要 urlacl，
    /// 绿色单文件程序不该要求用户先跑一条 netsh。这里只需要支持 GET/POST 与
    /// 几个小接口，自己写解析反而更可控。
    /// </summary>
    public class MiniHttp
    {
        public const int DefaultPort = 54546;

        /// <summary>
        /// 实际监听端口。
        /// ★ 不能是 readonly —— 端口被占时 Start() 会自动往后找一个可用端口并写回这里
        ///   （原来是 readonly，编译报 CS0191：无法对只读字段赋值）。
        ///   /diag 的 httpPort 读的就是它，所以回退后必须能被改写。
        /// </summary>
        private int _port;
        private TcpListener _listener;
        private Thread _thread;
        private volatile bool _running;
        private int _requests;

        /// <summary>当前帧 JPEG（可能为 null）</summary>
        public Func<byte[]> GetFrame;
        /// <summary>/status</summary>
        public Func<string> GetStatus;
        /// <summary>/diag</summary>
        public Func<string> GetDiag;
        /// <summary>/set?query → 返回 JSON</summary>
        public Func<Dictionary<string, string>, string> OnSet;
        /// <summary>/probe</summary>
        public Func<string> OnProbe;

        /// <summary>用户配置的端口（用于和"实际绑定成功的端口"对比，便于日志提示）</summary>
        private int _cfgPort;

        public MiniHttp(int port)
        {
            _port = port;
            _cfgPort = port;
        }

        public int Port { get { return _port; } }
        public int Requests { get { return _requests; } }
        public bool Running { get { return _running; } }

        public bool Start()
        {
            // ★ 2026-10-15：端口被占时**自动往后找一个可用端口**，而不是直接失败。
            //
            //   踩坑经过：用户机器上有个残留实例占着 54546，本程序只打了一行
            //   "HTTP 监听 54546 失败" 就继续跑了 —— 结果程序一切正常、屏也在推帧，
            //   但 /diag 永远读不到（curl 报 connection refused）。
            //   用户因此以为程序坏了，白排查了好几轮。
            //
            //   现在的行为：从配置端口起往后试 10 个，成功就用那个，
            //   并把**实际端口**记在 _port 里（/diag 的 httpPort 读的就是它）。
            Exception last = null;
            for (int tryPort = _port; tryPort < _port + 10; tryPort++)
            {
                try
                {
                    // ★ 2026-10-15（代码审查【中-7】）：原来绑 `IPAddress.Any`，而 `/set`
                    //   没有任何鉴权 —— 局域网内任何主机都能改 vertical/rotate180/night/interval/
                    //   arm/usb/vm，其中 `interval` 还没有下限，足以把帧循环拖死或灌爆 USB 端点。
                    //   ArkTS 侧只绑回环（bridge/FrameServer.ets），这里对齐。
                    //   若确实需要远程访问，请显式加开关与令牌，不要默默监听全网卡。
                    _listener = new TcpListener(IPAddress.Loopback, tryPort);
                    _listener.Start();
                    _port = tryPort;
                    _running = true;
                    _thread = new Thread(new ThreadStart(Loop));
                    _thread.IsBackground = true;
                    _thread.Name = "http";
                    _thread.Start();
                    if (_port != _cfgPort)
                    {
                        Log.W("HTTP 服务已启动：http://127.0.0.1:{0}/  （⚠️ 配置端口 {1} 被占用，已自动改用 {0}）",
                              _port, _cfgPort);
                    }
                    else
                    {
                        Log.W("HTTP 服务已启动：http://127.0.0.1:{0}/  （预览页 /preview，诊断 /diag）", _port);
                    }
                    return true;
                }
                catch (Exception ex)
                {
                    last = ex;
                    try { if (_listener != null) _listener.Stop(); } catch (Exception) { }
                    _listener = null;
                }
            }
            Log.Err("HTTP 监听失败（{0}..{1} 都被占用）：{2}",
                    _cfgPort, _cfgPort + 9, last == null ? "未知" : last.Message);
            return false;
        }

        public void Stop()
        {
            _running = false;
            try { if (_listener != null) _listener.Stop(); } catch (Exception) { }
            try { if (_thread != null) _thread.Join(1500); } catch (Exception) { }
        }

        private void Loop()
        {
            while (_running)
            {
                TcpClient client = null;
                try
                {
                    client = _listener.AcceptTcpClient();
                }
                catch (Exception)
                {
                    if (!_running) return;
                    Thread.Sleep(50);
                    continue;
                }
                ThreadPool.QueueUserWorkItem(new WaitCallback(Handle), client);
            }
        }

        private void Handle(object stateObj)
        {
            TcpClient client = (TcpClient)stateObj;
            try
            {
                client.NoDelay = true;
                using (NetworkStream ns = client.GetStream())
                {
                    client.ReceiveTimeout = 5000;
                    client.SendTimeout = 8000;

                    string requestLine = ReadLine(ns);
                    if (string.IsNullOrEmpty(requestLine)) return;

                    // 吃掉请求头
                    while (true)
                    {
                        string h = ReadLine(ns);
                        if (string.IsNullOrEmpty(h)) break;
                    }

                    string[] parts = requestLine.Split(' ');
                    if (parts.Length < 2) return;
                    string method = parts[0].ToUpperInvariant();
                    string target = parts[1];
                    string path = target;
                    string query = "";
                    int q = target.IndexOf('?');
                    if (q >= 0)
                    {
                        path = target.Substring(0, q);
                        query = target.Substring(q + 1);
                    }

                    _requests++;
                    Route(ns, method, path, query);
                }
            }
            catch (Exception ex)
            {
                Log.Err("HTTP 处理异常：{0}", ex.Message);
            }
            finally
            {
                try { client.Close(); } catch (Exception) { }
            }
        }

        private static string ReadLine(NetworkStream ns)
        {
            StringBuilder sb = new StringBuilder();
            int b;
            while ((b = ns.ReadByte()) > 0)
            {
                if (b == '\n') break;
                if (b != '\r') sb.Append((char)b);
                if (sb.Length > 4096) break;
            }
            return sb.ToString();
        }

        private void Route(NetworkStream ns, string method, string path, string query)
        {
            if (path == "/" || path == "/preview" || path == "/index.html")
            {
                SendText(ns, 200, "text/html; charset=utf-8", PreviewPage());
                return;
            }
            if (path == "/frame.jpg" || path == "/frame")
            {
                byte[] jpg = GetFrame == null ? null : GetFrame();
                if (jpg == null || jpg.Length == 0)
                {
                    SendText(ns, 503, "text/plain; charset=utf-8", "还没有画面");
                    return;
                }
                SendBytes(ns, 200, "image/jpeg", jpg);
                return;
            }
            if (path == "/status")
            {
                SendText(ns, 200, "application/json; charset=utf-8", GetStatus == null ? "{}" : GetStatus());
                return;
            }
            if (path == "/diag")
            {
                SendText(ns, 200, "application/json; charset=utf-8", GetDiag == null ? "{}" : GetDiag());
                return;
            }
            if (path == "/probe")
            {
                string r = OnProbe == null ? "unsupported" : OnProbe();
                SendText(ns, 200, "text/plain; charset=utf-8", r);
                return;
            }
            if (path == "/set")
            {
                if (method != "POST" && method != "GET")
                {
                    SendText(ns, 405, "text/plain; charset=utf-8", "只支持 GET/POST");
                    return;
                }
                Dictionary<string, string> args = ParseQuery(query);
                string json = OnSet == null ? "{\"error\":\"unsupported\"}" : OnSet(args);
                SendText(ns, 200, "application/json; charset=utf-8", json);
                return;
            }
            SendText(ns, 404, "text/plain; charset=utf-8", "没有这个路径：" + path);
        }

        public static Dictionary<string, string> ParseQuery(string query)
        {
            Dictionary<string, string> d = new Dictionary<string, string>();
            if (string.IsNullOrEmpty(query)) return d;
            string[] pairs = query.Split('&');
            for (int i = 0; i < pairs.Length; i++)
            {
                if (pairs[i].Length == 0) continue;
                int eq = pairs[i].IndexOf('=');
                string k = eq < 0 ? pairs[i] : pairs[i].Substring(0, eq);
                string v = eq < 0 ? "" : pairs[i].Substring(eq + 1);
                d[Uri.UnescapeDataString(k)] = Uri.UnescapeDataString(v).Replace("+", " ");
            }
            return d;
        }

        private static void SendBytes(NetworkStream ns, int code, string ctype, byte[] body)
        {
            StringBuilder head = new StringBuilder();
            head.Append("HTTP/1.1 ").Append(code).Append(" ").Append(code == 200 ? "OK" : "ERR").Append("\r\n");
            head.Append("Content-Type: ").Append(ctype).Append("\r\n");
            head.Append("Content-Length: ").Append(body.Length).Append("\r\n");
            head.Append("Cache-Control: no-store\r\n");
            head.Append("Access-Control-Allow-Origin: *\r\n");
            head.Append("Connection: close\r\n\r\n");
            byte[] hb = Encoding.ASCII.GetBytes(head.ToString());
            ns.Write(hb, 0, hb.Length);
            ns.Write(body, 0, body.Length);
            ns.Flush();
        }

        private static void SendText(NetworkStream ns, int code, string ctype, string text)
        {
            SendBytes(ns, code, ctype, Encoding.UTF8.GetBytes(text ?? ""));
        }

        // >>> WEB-PREVIEW (由 tools/make_web.py 从 web/preview.html 生成，勿手改) >>>
        private const string PreviewHtml = @"<!DOCTYPE html><html lang=""zh-CN""><head><meta charset=""utf-8"">
<meta name=""viewport"" content=""width=device-width,initial-scale=1,maximum-scale=5,user-scalable=yes"">
<title>Trofeo Vision 9.16 · 副屏预览</title>
<link rel=""icon"" href=""data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%232E4054'/%3E%3Crect x='7' y='24' width='50' height='18' rx='4' fill='%23070A0E' stroke='%235A6674' stroke-width='1.5'/%3E%3Ccircle cx='14' cy='33' r='2.4' fill='%233FB950'/%3E%3Crect x='20' y='34' width='3.6' height='5' rx='1.4' fill='%23C9D1D9'/%3E%3Crect x='25.4' y='30' width='3.6' height='9' rx='1.4' fill='%23C9D1D9'/%3E%3Crect x='30.8' y='27' width='3.6' height='12' rx='1.4' fill='%233FB950'/%3E%3Crect x='36.2' y='32' width='3.6' height='7' rx='1.4' fill='%23C9D1D9'/%3E%3Crect x='41.6' y='29' width='3.6' height='10' rx='1.4' fill='%23C9D1D9'/%3E%3Crect x='28' y='42' width='8' height='5' fill='%2336404C'/%3E%3Crect x='20' y='47' width='24' height='4' rx='2' fill='%23546170'/%3E%3C/svg%3E"">
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0D1117;color:#C9D1D9;font:15px/1.6 ""HarmonyOS Sans SC"",""Microsoft YaHei"",system-ui,sans-serif}
header{display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:10px 12px;background:#161B22;border-bottom:1px solid #21262D}
h1{font-size:18px;margin:0;color:#E6EDF3}
.sub{font-size:12px;color:#7D8590;margin-right:4px}
.dot{width:8px;height:8px;border-radius:4px;background:#8B949E;flex:0 0 auto}
.pill{font:12px ui-monospace,Consolas,monospace;padding:3px 8px;border-radius:6px;background:#21262D;border:1px solid #30363D;color:#8B949E}
.spacer{flex:1 1 auto}
button{background:#21262D;color:#C9D1D9;border:1px solid #30363D;border-radius:8px;padding:7px 12px;font:inherit;font-size:14px;cursor:pointer}
button:hover{background:#30363D}
button.on{background:#238636;border-color:#238636;color:#fff}
.bar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:8px 12px 0}
.lab{font-size:12px;color:#7D8590;min-width:28px}
.mono{font-family:ui-monospace,Consolas,monospace}
input[type=range]{flex:1 1 140px;min-width:120px;accent-color:#238636}
#wrap{overflow:auto;-webkit-overflow-scrolling:touch;background:#010409;margin:10px 12px;border:1px solid #21262D;border-radius:10px;height:46vh;min-height:220px}
#shot{display:block;transform-origin:0 0;image-rendering:auto}
.meta{padding:2px 14px 0;font-size:12.5px;color:#8B949E;line-height:1.9}
.meta b{color:#E6EDF3;font-weight:600}
.meta .mono{color:#C9D1D9}
.err{color:#F85149}
.ok{color:#3FB950}
.warn{color:#D29922}
pre{margin:10px 12px 20px;padding:10px;background:#161B22;border:1px solid #21262D;border-radius:10px;overflow:auto;max-height:34vh;font:12px ui-monospace,Consolas,monospace;color:#8B949E}
.hide{display:none}
</style></head><body>
<header>
<span class=""dot"" id=""dot""></span><h1>Trofeo Vision</h1><span class=""sub mono"">9.16 LCD</span>
<span class=""pill"" id=""pill"">连接中…</span><span class=""spacer""></span>
<button id=""bV"">竖屏布局</button><button id=""bR"">180°旋转</button><button id=""bN"">夜间熄屏</button><button id=""bF"">立即刷新</button>
</header>
<div class=""bar""><span class=""lab"">区域</span>
<button data-r=""all"" class=""on"">全图</button>
<button data-r=""vm"">VM 画面</button>
<button data-r=""pr"">打印机</button>
<button data-r=""dsh"">DSH 会话</button>
<button data-r=""sys"">系统</button>
<button data-r=""use"">用量与时钟</button></div>
<div class=""bar""><span class=""lab"">缩放</span>
<button id=""minus"">－</button><button id=""bfit"">适应</button><button id=""plus"">＋</button>
<input id=""zs"" type=""range"" min=""10"" max=""300"" step=""5"" value=""100""><span class=""mono"" id=""pct"">—</span></div>
<div class=""bar""><span class=""lab"">平移</span>
<span class=""lab mono"">左右</span><input id=""px"" type=""range"" min=""0"" max=""1000"" value=""500"">
<span class=""lab mono"">上下</span><input id=""py"" type=""range"" min=""0"" max=""1000"" value=""500""></div>
<div id=""wrap""><img id=""shot"" alt=""frame""></div>
<div class=""meta"" id=""meta"">加载中…</div>
<div class=""meta"" id=""meta2""></div>
<div class=""bar""><button id=""bD"">诊断 JSON</button><span class=""lab"" id=""hint"">每 0.4s 刷新 · 显示的就是推给屏的那一帧</span></div>
<pre id=""diag"" class=""hide"">加载中…</pre>
<script>
var FW=1920,FH=462,scale=1,rot180=false,vertical=false,night=false,lastStat=0;
var shot=document.getElementById('shot'),wrap=document.getElementById('wrap');
var pct=document.getElementById('pct'),meta=document.getElementById('meta'),meta2=document.getElementById('meta2'),diag=document.getElementById('diag');
var pill=document.getElementById('pill'),dot=document.getElementById('dot'),hint=document.getElementById('hint');
var zs=document.getElementById('zs'),pxs=document.getElementById('px'),pys=document.getElementById('py');
var R={all:[0,0,1920,462],vm:[1450,14,456,434],pr:[1450,314,456,152],
       dsh:[298,14,843,434],sys:[14,14,274,434],use:[1152,14,274,434]};
function g(v,fb){return (v===undefined||v===null||v==='')?(fb===undefined?'—':fb):v;}
function sb(v){return v?'<b class=""ok"">已连接</b>':'未连接';}
function setScale(sc){scale=Math.max(0.1,Math.min(3,sc));
  shot.style.width=(FW*scale)+'px';shot.style.height=(FH*scale)+'px';
  pct.textContent=Math.round(scale*100)+'%';zs.value=Math.round(scale*100);}
function apply(){setScale(scale);
  shot.style.transform=rot180?'rotate(180deg) translate(-100%,-100%)':'none';
  pan();}
function pan(){var mw=Math.max(1,wrap.scrollWidth-wrap.clientWidth),mh=Math.max(1,wrap.scrollHeight-wrap.clientHeight);
  wrap.scrollLeft=(rot180?1000-pxs.value:pxs.value)*mw/1000;
  wrap.scrollTop=(rot180?1000-pys.value:pys.value)*mh/1000;}
function focus(name){var r=R[name]||R.all;
  var fitW=(wrap.clientWidth-24)/r[2],fitH=(wrap.clientHeight-24)/r[3];
  setScale(Math.min(fitW,fitH));
  var dx=rot180?(FW-r[0]-r[2]):r[0],dy=rot180?(FH-r[1]-r[3]):r[1];
  wrap.scrollLeft=dx*scale+r[2]*scale/2-wrap.clientWidth/2;
  wrap.scrollTop=dy*scale+r[3]*scale/2-wrap.clientHeight/2;
  var bs=document.querySelectorAll('[data-r]');
  for(var i=0;i<bs.length;i++){bs[i].className=(bs[i].getAttribute('data-r')===name)?'on':'';}
  var mw=wrap.scrollWidth-wrap.clientWidth,mh=wrap.scrollHeight-wrap.clientHeight;
  pxs.value=mw>1?Math.round(wrap.scrollLeft*1000/mw):500;
  pys.value=mh>1?Math.round(wrap.scrollTop*1000/mh):500;}
document.getElementById('minus').onclick=function(){setScale(scale/1.25);pan();};
document.getElementById('plus').onclick=function(){setScale(scale*1.25);pan();};
document.getElementById('bfit').onclick=function(){focus('all');};
zs.oninput=function(){setScale(zs.value/100);pan();};
pxs.oninput=pan;pys.oninput=pan;
var bs=document.querySelectorAll('[data-r]');
for(var i=0;i<bs.length;i++){bs[i].onclick=function(){focus(this.getAttribute('data-r'));};}
document.getElementById('bD').onclick=function(){diag.className=diag.className==='hide'?'':'hide';};
function setQ(q){return fetch('/set?'+q).then(function(r){return r.json();}).then(function(){poll();});}
document.getElementById('bV').onclick=function(){setQ('vertical='+(vertical?0:1));};
document.getElementById('bR').onclick=function(){setQ('rotate180='+(rot180?0:1));};
document.getElementById('bN').onclick=function(){night=!night;setQ('night='+(night?0:1));};
document.getElementById('bF').onclick=function(){tick(true);};
function mark(flag,el){el.className=flag?'on':'';}
function vmLine(d){
  var e=d.vmErr||'';
  if(e){return '<span class=""err"">取帧失败 '+e+'</span>';}
  var f=d.vmFrames;
  if(f===undefined){return '<span class=""mono"">—</span>';}
  if(f>0&&d.vmAgeMs>=0){return '<b class=""ok"">'+f+'</b> 帧 · <span class=""mono"">'+(d.vmAgeMs/1000).toFixed(1)+'s 前</span>';}
  return '<span class=""warn"">尚未取到画面（轮询中）</span>';}
function tick(force){
  var now=new Date().getTime();
  if(force||now-lastStat>900){
    lastStat=now;
    fetch('/status').then(function(r){return r.json();}).then(function(s){
      rot180=!!s.rotate180;vertical=!!s.vertical;
      if(s.night!==undefined){night=!!s.night;document.getElementById('bN').className='';}
      apply();
      mark(vertical,document.getElementById('bV'));mark(rot180,document.getElementById('bR'));
      mark(night,document.getElementById('bN'));
      dot.style.background=s.usbOpen?'#3FB950':'#8B949E';
      pill.textContent=s.usbOpen?('USB 已连接'+(s.device?(' '+s.device):'')):(vertical?'竖屏':'未推帧（预览模式）');
      pill.style.color=s.usbOpen?'#3FB950':'#8B949E';
      meta.innerHTML='<b>'+g(s.jpegW,0)+'×'+g(s.jpegH,0)+'</b> · '+Math.round(g(s.jpegBytes,0)/1024)+'KB'
        +' · 推帧 <b>'+g(s.sent,0)+'</b> · 错误 '+g(s.errors,0)
        +' · USB '+sb(s.usbOpen)
        +' · 数据桥 '+(s.bridgeAgeSec<0?'<span class=""warn"">无数据</span>':('<span class=""mono"">'+s.bridgeAgeSec+'s 前</span>'))
        +' · 本机帧 <span class=""mono"">'+g(s.frames,0)+'</span>'
        +'<br>'+g(s.state)+' · 设备 '+g(s.device)+' · ACK '+g(s.ack)
        + (s.vmUrl?(' · VM 地址 <span class=""mono"">'+s.vmUrl+'</span>'):'');
    }).catch(function(){pill.textContent='连不上服务';pill.style.color='#F85149';dot.style.background='#F85149';});
  }
  fetch('/diag').then(function(r){return r.json();}).then(function(d){
    diag.textContent=JSON.stringify(d,null,1);
    var extra='';
    if(d.renderMs!==undefined){extra+=' · 渲染 <span class=""mono"">'+d.renderMs+'ms</span> · 编码 <span class=""mono"">'+g(d.encodeMs)+'ms</span>'
      +' · 推送 <span class=""mono"">'+g(d.pushMs)+'ms</span> · 质量 <span class=""mono"">'+g(d.quality)+'</span>';}
    if(d.selfTest&&d.selfTest!=='未运行'){extra+=' · 协议自检 <b class=""'+(d.selfTestAllPass?'ok':'err')+'"">'+d.selfTest+'</b>';}
    meta2.innerHTML='远程取帧：'+vmLine(d)+extra;
  }).catch(function(){});
  shot.src='/frame.jpg?t='+new Date().getTime();
}
window.addEventListener('resize',function(){pan();});
shot.onload=function(){hint.textContent='每 0.4s 刷新 · 显示的就是推给屏的那一帧 · '+shot.naturalWidth+'×'+shot.naturalHeight;};
focus('all');
tick(true);
setInterval(tick,400);
</script></body></html>
";
        // <<< WEB-PREVIEW <<<

        /// <summary>网页预览页（内容由工具生成，见 PreviewHtml）</summary>
        private string PreviewPage()
        {
            return PreviewHtml;
        }
    }
}
