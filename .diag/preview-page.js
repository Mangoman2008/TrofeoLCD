
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
