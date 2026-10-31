// udp-listen.cjs — 独立验证"桥有没有真的发出 UDP 包"
// 用法（VM 里，先停掉 dshlcd 程序避免抢端口）：
//   "C:\Program Files\nodejs\node.exe" udp-listen.cjs
// 它绑 54545 收包并打印摘要。收到就说明桥没问题，问题在 C# 接收侧；
// 收不到就说明包没发出来（桥卡住了）。
const dgram = require('node:dgram');
const PORT = Number(process.argv[2] || 54545);
const sock = dgram.createSocket('udp4');
let n = 0, bytes = 0, first = null, last = null;
sock.on('message', (buf) => {
  n++; bytes += buf.length;
  if (n === 1) {
    first = Date.now();
    let keys = [];
    try { keys = Object.keys(JSON.parse(buf.toString('utf8'))); } catch (e) { keys = ['(JSON 解析失败)']; }
    console.log(`\n第 1 包到达: ${buf.length} 字节`);
    console.log('  JSON 顶层字段:', keys.join(', '));
    console.log('  前 300 字节:', buf.toString('utf8').slice(0, 300));
  }
  last = Date.now();
});
sock.on('error', (e) => { console.error('socket 错误:', e.message); process.exit(1); });
sock.bind(PORT, '127.0.0.1', () => {
  console.log(`已在 127.0.0.1:${PORT} 监听（Ctrl+C 退出）`);
  console.log('若 5 秒内没有包到达，说明桥没在发（或没在跑）');
});
setInterval(() => {
  const rate = last && n > 1 ? ((n - 1) * 1000 / (last - first)).toFixed(2) : '-';
  console.log(`\r[监听中] 收包 ${n} 个 · 共 ${bytes} 字节 · 速率 ${rate}/秒      `);
}, 1000);
