/**
 * FrameServer.ets — 把「当前推给 LCD 的那一帧」通过 localhost HTTP 暴露出来
 *
 * 为什么需要：本沙箱读不到系统 hilog（`hilog` 无输出），所以应用跑起来后
 * 我无法直接看它的日志。这个只监听 127.0.0.1 的小服务让验证可以自证：
 *
 *   curl -s http://127.0.0.1:54546/frame.jpg -o frame.jpg   # 拿当前帧
 *   curl -s http://127.0.0.1:54546/status                   # 拿状态 JSON
 *
 * 于是"应用是否在跑""画布是否真的渲染成 1920x462""JPEG 有没有超 650KB"
 * 这些都能在没接屏幕的情况下被外部检查。
 *
 * 全程 try/catch：任何失败都不能影响帧循环。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

export const FRAME_PORT: number = 54546;

export class FrameServer {
  private server: socket.TCPSocketServer | null = null;
  private jpeg: Uint8Array | null = null;
  private frames: number = 0;
  private lastFrameMs: number = 0;
  private listening: boolean = false;
  private encoder = util.TextEncoder.create('utf-8');
  /** 由 LcdService 注入的数据提供者（诊断通道） */
  statusProvider: (() => string) | null = null;
  diagProvider: (() => string) | null = null;
  probeProvider: (() => Promise<string>) | null = null;
  /** /set?vertical=1 之类的远程设置入口（仅本地回环） */
  setProvider: ((query: string) => string) | null = null;

  get isListening(): boolean {
    return this.listening;
  }

  get frameCount(): number {
    return this.frames;
  }

  get lastFrameAgeMs(): number {
    return this.lastFrameMs === 0 ? -1 : (Date.now() - this.lastFrameMs);
  }

  get url(): string {
    return `http://127.0.0.1:${FRAME_PORT}/frame.jpg`;
  }

  /** 更新当前帧（由帧循环每帧调用） */
  setFrame(jpeg: Uint8Array): void {
    this.jpeg = jpeg;
    this.frames++;
    this.lastFrameMs = Date.now();
  }

  /** 供 /status 使用的短摘要 */
  private statusJson(): string {
    if (this.statusProvider !== null) {
      return this.statusProvider();
    }
    return `{"frameCount":${this.frames},"frameAgeMs":${this.lastFrameAgeMs}}`;
  }

  async start(): Promise<boolean> {
    if (this.server !== null) {
      return true;
    }
    try {
      const s = socket.constructTCPSocketServerInstance();
      s.on('connect', (conn: socket.TCPSocketConnection) => {
        this.serve(conn);
      });
      s.on('error', (err: BusinessError) => {
        Logger.w(`[FrameServer] 错误: ${err.code} ${err.message}`);
      });
      await s.listen({ address: '127.0.0.1', port: FRAME_PORT, family: 1 });
      this.server = s;
      this.listening = true;
      Logger.i(`[FrameServer] 已监听 ${this.url}`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`[FrameServer] 启动失败: ${err.code} ${err.message}`);
      this.server = null;
      this.listening = false;
      return false;
    }
  }

  /** 处理一次请求：/status 返回 JSON，其余返回当前帧 JPEG */

  // >>> WEB-PREVIEW (由 tools/make_web.py 从 web/preview.html 生成，勿手改) >>>
  private readonly previewHtmlText: string = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=5,user-scalable=yes">
<title>Trofeo Vision 9.16 · 副屏预览</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%232E4054'/%3E%3Crect x='7' y='24' width='50' height='18' rx='4' fill='%23070A0E' stroke='%235A6674' stroke-width='1.5'/%3E%3Ccircle cx='14' cy='33' r='2.4' fill='%233FB950'/%3E%3Crect x='20' y='34' width='3.6' height='5' rx='1.4' fill='%23C9D1D9'/%3E%3Crect x='25.4' y='30' width='3.6' height='9' rx='1.4' fill='%23C9D1D9'/%3E%3Crect x='30.8' y='27' width='3.6' height='12' rx='1.4' fill='%233FB950'/%3E%3Crect x='36.2' y='32' width='3.6' height='7' rx='1.4' fill='%23C9D1D9'/%3E%3Crect x='41.6' y='29' width='3.6' height='10' rx='1.4' fill='%23C9D1D9'/%3E%3Crect x='28' y='42' width='8' height='5' fill='%2336404C'/%3E%3Crect x='20' y='47' width='24' height='4' rx='2' fill='%23546170'/%3E%3C/svg%3E">
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0D1117;color:#C9D1D9;font:15px/1.6 "HarmonyOS Sans SC","Microsoft YaHei",system-ui,sans-serif}
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
<span class="dot" id="dot"></span><h1>Trofeo Vision</h1><span class="sub mono">9.16 LCD</span>
<span class="pill" id="pill">连接中…</span><span class="spacer"></span>
<button id="bV">竖屏布局</button><button id="bR">180°旋转</button><button id="bN">夜间熄屏</button><button id="bF">立即刷新</button>
</header>
<div class="bar"><span class="lab">区域</span>
<button data-r="all" class="on">全图</button>
<button data-r="vm">VM 画面</button>
<button data-r="pr">打印机</button>
<button data-r="dsh">DSH 会话</button>
<button data-r="sys">系统</button>
<button data-r="use">用量与时钟</button></div>
<div class="bar"><span class="lab">缩放</span>
<button id="minus">－</button><button id="bfit">适应</button><button id="plus">＋</button>
<input id="zs" type="range" min="10" max="300" step="5" value="100"><span class="mono" id="pct">—</span></div>
<div class="bar"><span class="lab">平移</span>
<span class="lab mono">左右</span><input id="px" type="range" min="0" max="1000" value="500">
<span class="lab mono">上下</span><input id="py" type="range" min="0" max="1000" value="500"></div>
<div id="wrap"><img id="shot" alt="frame"></div>
<div class="meta" id="meta">加载中…</div>
<div class="meta" id="meta2"></div>
<div class="bar"><button id="bD">诊断 JSON</button><span class="lab" id="hint">每 0.4s 刷新 · 显示的就是推给屏的那一帧</span></div>
<pre id="diag" class="hide">加载中…</pre>
<script>
var FW=1920,FH=462,scale=1,rot180=false,vertical=false,night=false,lastStat=0;
var shot=document.getElementById('shot'),wrap=document.getElementById('wrap');
var pct=document.getElementById('pct'),meta=document.getElementById('meta'),meta2=document.getElementById('meta2'),diag=document.getElementById('diag');
var pill=document.getElementById('pill'),dot=document.getElementById('dot'),hint=document.getElementById('hint');
var zs=document.getElementById('zs'),pxs=document.getElementById('px'),pys=document.getElementById('py');
var R={all:[0,0,1920,462],vm:[1450,14,456,434],pr:[1450,314,456,152],
       dsh:[298,14,843,434],sys:[14,14,274,434],use:[1152,14,274,434]};
function g(v,fb){return (v===undefined||v===null||v==='')?(fb===undefined?'—':fb):v;}
function sb(v){return v?'<b class="ok">已连接</b>':'未连接';}
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
  if(e){return '<span class="err">取帧失败 '+e+'</span>';}
  var f=d.vmFrames;
  if(f===undefined){return '<span class="mono">—</span>';}
  if(f>0&&d.vmAgeMs>=0){return '<b class="ok">'+f+'</b> 帧 · <span class="mono">'+(d.vmAgeMs/1000).toFixed(1)+'s 前</span>';}
  return '<span class="warn">尚未取到画面（轮询中）</span>';}
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
        +' · 数据桥 '+(s.bridgeAgeSec<0?'<span class="warn">无数据</span>':('<span class="mono">'+s.bridgeAgeSec+'s 前</span>'))
        +' · 本机帧 <span class="mono">'+g(s.frames,0)+'</span>'
        +'<br>'+g(s.state)+' · 设备 '+g(s.device)+' · ACK '+g(s.ack)
        + (s.vmUrl?(' · VM 地址 <span class="mono">'+s.vmUrl+'</span>'):'');
    }).catch(function(){pill.textContent='连不上服务';pill.style.color='#F85149';dot.style.background='#F85149';});
  }
  fetch('/diag').then(function(r){return r.json();}).then(function(d){
    diag.textContent=JSON.stringify(d,null,1);
    var extra='';
    if(d.renderMs!==undefined){extra+=' · 渲染 <span class="mono">'+d.renderMs+'ms</span> · 编码 <span class="mono">'+g(d.encodeMs)+'ms</span>'
      +' · 推送 <span class="mono">'+g(d.pushMs)+'ms</span> · 质量 <span class="mono">'+g(d.quality)+'</span>';}
    if(d.selfTest&&d.selfTest!=='未运行'){extra+=' · 协议自检 <b class="'+(d.selfTestAllPass?'ok':'err')+'">'+d.selfTest+'</b>';}
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
`;
  // <<< WEB-PREVIEW <<<

  /** 网页预览页 HTML（内容由工具生成，见 previewHtmlText） */
  private previewHtml(): string {
    return this.previewHtmlText;
  }

  private respondHtml(conn: socket.TCPSocketConnection, body: string): void {
    try {
      const head = `HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n`
        + `Content-Length: ${this.encoder.encodeInto(body).length}\r\n`
        + `Cache-Control: no-store\r\nConnection: close\r\n\r\n`;
      const combined = this.concat(this.encoder.encodeInto(head),
        this.encoder.encodeInto(body));
      const opts: socket.TCPSendOptions = { data: combined.buffer };
      conn.send(opts).then(() => {
        this.closeQuietly(conn);
      }).catch(() => {
        this.closeQuietly(conn);
      });
    } catch (e) {
      this.closeQuietly(conn);
    }
  }

  private serve(conn: socket.TCPSocketConnection): void {
    conn.on('message', (info: socket.SocketMessageInfo) => {
      let path = '';
      try {
        const text = util.TextDecoder.create('utf-8')
          .decodeToString(new Uint8Array(info.message));
        const line = text.split('\r\n')[0];
        const parts = line.split(' ');
        path = parts.length > 1 ? parts[1] : '';
      } catch (e) {
        path = '';
      }

      // 诊断通道：本沙箱读不到 hilog，外部靠这些端点取证据
      if (path.indexOf('/probe') === 0 && this.probeProvider !== null) {
        this.probeProvider().then((txt: string) => {
          this.respondText(conn, txt);
        }).catch(() => {
          this.respondText(conn, '{"error":"probe failed"}', 500);
        });
        return;
      }
      if (path.indexOf('/set') === 0 && this.setProvider !== null) {
        const q = path.indexOf('?') >= 0 ? path.substring(path.indexOf('?') + 1) : '';
        this.respondText(conn, this.setProvider(q));
        return;
      }
      if (path.indexOf('/diag') === 0 && this.diagProvider !== null) {
        this.respondText(conn, this.diagProvider());
        return;
      }
      if (path === '/' || path.indexOf('/preview') === 0) {
        this.respondHtml(conn, this.previewHtml());
        return;
      }
      if (path.indexOf('/status') === 0) {
        this.respondText(conn, this.statusJson());
        return;
      }
      if (this.jpeg === null) {
        this.respondText(conn, '{"error":"no frame yet"}', 503);
        return;
      }
      this.respondJpeg(conn, this.jpeg);
    });
    conn.on('error', (err: BusinessError) => {
      Logger.w(`[FrameServer] 连接错误: ${err.code}`);
    });
  }

  private respondText(conn: socket.TCPSocketConnection, body: string,
                      code: number = 200): void {
    try {
      const head = `HTTP/1.0 ${code} OK\r\nContent-Type: application/json; charset=utf-8\r\n`
        + `Content-Length: ${this.encoder.encodeInto(body).length}\r\n`
        + `Connection: close\r\n\r\n`;
      const combined = this.concat(this.encoder.encodeInto(head),
        this.encoder.encodeInto(body));
      const opts: socket.TCPSendOptions = { data: combined.buffer };
      conn.send(opts).then(() => {
        this.closeQuietly(conn);
      }).catch(() => {
        this.closeQuietly(conn);
      });
    } catch (e) {
      this.closeQuietly(conn);
    }
  }

  private respondJpeg(conn: socket.TCPSocketConnection, jpeg: Uint8Array): void {
    try {
      const head = `HTTP/1.0 200 OK\r\nContent-Type: image/jpeg\r\n`
        + `Content-Length: ${jpeg.length}\r\n`
        + `Cache-Control: no-store\r\nConnection: close\r\n\r\n`;
      const combined = this.concat(this.encoder.encodeInto(head), jpeg);
      const opts: socket.TCPSendOptions = { data: combined.buffer };
      conn.send(opts).then(() => {
        this.closeQuietly(conn);
      }).catch(() => {
        this.closeQuietly(conn);
      });
    } catch (e) {
      this.closeQuietly(conn);
    }
  }

  private concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  private closeQuietly(conn: socket.TCPSocketConnection): void {
    try {
      conn.off('message');
      conn.close();
    } catch (e) {
      // ignore
    }
  }

  stop(): void {
    if (this.server !== null) {
      try {
        this.server.off('connect');
        this.server.close();
      } catch (e) {
        // ignore
      }
      this.server = null;
    }
    this.listening = false;
  }
}
