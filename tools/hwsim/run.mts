// run.mts — 用真实 LcdUsb.ets 源码 + 仿真 LY 设备，离线验证整条 USB 链路
//
// 覆盖：设备枚举 → 授权 → 连接 → 配置 → 断言点 → 握手 → 分块 → 推帧 → ACK → 掉线
// 其中"推帧"是完整往返：把推出去的字节按 LY 分块规范重新解析，要求还原出与输入
// 逐字节相同的 JPEG。解码器在本文件里独立实现（不复用被测代码），否则等于自证。
import { usbManager, sim, makeLcdDevice, makeHandshakeResponse, makeAck,
  FakeDevice } from './FakeKits.ts';
import { LcdUsb } from './LcdUsb.ts';
import { logs } from './Logger.ts';

const results: string[] = [];
let pass = 0, fail = 0;

function check(name: string, ok: boolean, detail: string): void {
  if (ok) { pass++; results.push(`✅ ${name.padEnd(30)} ${detail}`); }
  else { fail++; results.push(`❌ ${name.padEnd(30)} ${detail}`); }
}

function pseudoJpeg(n: number): Uint8Array {
  const a = new Uint8Array(n);
  for (let i = 0; i < n; i++) { a[i] = (i * 37 + 11) & 0xFF; }
  a[0] = 0xFF; a[1] = 0xD8;                   // 像 JPEG 的起始
  a[n - 2] = 0xFF; a[n - 1] = 0xD9;
  return a;
}

/** 独立实现的 LY 分块解码器：从推给设备的字节还原 JPEG */
function decodeChunks(buf: Uint8Array): {
  jpeg: Uint8Array; total: number; numChunks: number; cmd: number;
  paddedChunks: number; indexOk: boolean; magic: number;
} {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const magic = buf[0] * 256 + buf[1];
  const total = dv.getUint32(2, true);
  const cmd = buf[8];
  const numChunks = dv.getUint16(9, true);
  const paddedChunks = Math.floor(buf.length / 512);
  const out = new Uint8Array(total);
  let indexOk = true;
  for (let i = 0; i < numChunks; i++) {
    const off = i * 512;
    const len = dv.getUint16(off + 6, true);
    const idx = dv.getUint16(off + 11, true);
    if (idx !== i) { indexOk = false; }
    const start = i * 496;
    out.set(buf.subarray(off + 16, off + 16 + len), start);
  }
  return { jpeg: out, total, numChunks, cmd, paddedChunks, indexOk, magic };
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) { return false; }
  for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
  return true;
}

async function main(): Promise<void> {
  // ---------- S1 无设备 ----------
  sim.reset();
  check('S1 无设备: findDevice', LcdUsb.findDevice() === null, '返回 null');
  const s1 = new LcdUsb();
  check('S1 无设备: open', (await s1.open()) === null, '返回 null 且不抛异常');

  // ---------- S2 授权被拒 ----------
  sim.reset();
  sim.devices = [makeLcdDevice()];
  sim.grantRight = false;
  const s2 = new LcdUsb();
  const s2info = await s2.open();
  check('S2 授权被拒: open', s2info === null, '返回 null');
  check('S2 授权被拒: 未连接', sim.claimed.length === 0 && !sim.pipeOpen,
    `claim=${sim.claimed.length} pipe=${sim.pipeOpen}`);

  // ---------- S3 握手成功 ----------
  sim.reset();
  sim.devices = [makeLcdDevice(0x5408)];
  sim.inResponses = [makeHandshakeResponse(1, 4)];   // PM=65 SUB=5（真机实测值）
  const s3 = new LcdUsb();
  const info = await s3.open();
  check('S3 握手成功: 设备信息',
    // 高度期望 462 不是 480：462 vs 480 的分歧已实测拍板"维持 462"
    // （Bug修复清单-20261014.md §175：480 反而更糊）—— 解析器按 462 返回是对的，
    // 这里旧期望 480 是陈旧值，2026-10-31 修正。
    info !== null && info.pm === 65 && info.sub === 5 && info.fbl === 192
    && info.width === 1920 && info.height === 462 && info.rotateDeg === 180,
    info === null ? 'null' : info.toString());
  const hs = sim.writes[0];
  check('S3 握手包',
    hs !== undefined && hs.data.length === 2048 && hs.data[0] === 0x02
    && hs.data[1] === 0xFF && hs.data[8] === 0x01 && hs.addr === 0x09,
    hs === undefined ? '无写出' : `len=${hs.data.length} addr=0x${hs.addr.toString(16)} ` +
      `[0]=${hs.data[0].toString(16)} [8]=${hs.data[8].toString(16)}`);
  check('S3 断言点选择', sim.claimed.length === 1 && sim.claimed[0] === 1
    && s3.endpointSummary.includes('0x9') && s3.endpointSummary.includes('0x81'),
    `claim=${JSON.stringify(sim.claimed)} ${s3.endpointSummary}`);
  check('S3 描述符 dump', s3.deviceDump.length >= 6,
    `${s3.deviceDump.length} 行（含 config/iface/ep）`);

  // ---------- S4 推帧往返回忆 ----------
  const jpeg = pseudoJpeg(1200);
  const before = sim.writes.length;
  sim.inResponses = [makeAck()];
  const ok4 = await s3.sendJpeg(jpeg);
  const frameWrites = sim.writes.slice(before);
  let segOk = true, segDetail = '';
  for (let i = 0; i < frameWrites.length; i++) {
    const isLast = i === frameWrites.length - 1;
    const expect = isLast ? Math.min(2048, 2048) : 4096;
    if (frameWrites[i].data.length !== expect) { segOk = false; }
    if (frameWrites[i].addr !== 0x09) { segOk = false; }
    segDetail += `${frameWrites[i].data.length} `;
  }
  let joined = new Uint8Array(0);
  {
    let n = 0;
    for (const w of frameWrites) { n += w.data.length; }
    joined = new Uint8Array(n);
    let off = 0;
    for (const w of frameWrites) { joined.set(w.data, off); off += w.data.length; }
  }
  const dec = decodeChunks(joined);
  check('S4 推帧往返: 字节一致', ok4 && sameBytes(dec.jpeg, jpeg),
    `输入 ${jpeg.length}B → 解码 ${dec.jpeg.length}B`);
  check('S4 分块头', dec.magic === 0x01FF && dec.cmd === 1 && dec.indexOk
    && dec.total === jpeg.length,
    `magic=${dec.magic.toString(16)} cmd=${dec.cmd} total=${dec.total} 序号连续=${dec.indexOk}`);
  check('S4 4 的倍数补齐', dec.paddedChunks % 4 === 0,
    `numChunks=${dec.numChunks} 补齐后=${dec.paddedChunks}`);
  check('S4 写分段(4096/尾包)', segOk, `各段=[${segDetail.trim()}]`);
  check('S4 ACK 已读取', sim.inResponses.length === 0 && s3.lastAck.includes('B/'),
    s3.lastAck);

  // ---------- S5 大帧（600KB）----------
  const big = pseudoJpeg(600000);
  const before5 = sim.writes.length;
  sim.inResponses = [makeAck()];
  const ok5 = await s3.sendJpeg(big);
  const w5 = sim.writes.slice(before5);
  let j5 = new Uint8Array(0);
  {
    let n = 0;
    for (const w of w5) { n += w.data.length; }
    j5 = new Uint8Array(n);
    let off = 0;
    for (const w of w5) { j5.set(w.data, off); off += w.data.length; }
  }
  const dec5 = decodeChunks(j5);
  check('S5 大帧往返(600KB)', ok5 && sameBytes(dec5.jpeg, big),
    `${big.length}B → ${dec5.paddedChunks} 块 / ${w5.length} 次写出`);

  // ---------- S6 OUT 失败返回 -1 ----------
  sim.failOut = true;
  const ok6 = await s3.sendJpeg(pseudoJpeg(500));
  check('S6 OUT 失败(-1) 判定', ok6 === false && !s3.isOpen
    && sim.closeCalls > 0,
    `sendJpeg=${ok6} isOpen=${s3.isOpen} closePipe=${sim.closeCalls}`);
  check('S6 记录了失败日志', logs.some((l) => l.startsWith('E ') && l.includes('推帧失败')),
    logs.filter((l) => l.includes('推帧失败')).slice(-1)[0] ?? '（无）');
  sim.failOut = false;

  // ---------- S7 重新打开后再测 IN 失败 ----------
  sim.reset();
  sim.devices = [makeLcdDevice()];
  sim.inResponses = [makeHandshakeResponse(1, 4), makeAck()];
  const s7 = new LcdUsb();
  await s7.open();
  sim.failIn = true;
  const ok7 = await s7.sendJpeg(pseudoJpeg(800));
  check('S7 ACK 读取失败不致命', ok7 === true && s7.lastAck.includes('传输失败(-1)'),
    `sendJpeg=${ok7} ack=${s7.lastAck}`);

  // ---------- S8 LY1(0x5409) ----------
  sim.reset();
  sim.devices = [makeLcdDevice(0x5409)];
  sim.inResponses = [makeHandshakeResponse(1, 4), makeAck()];
  const s8 = new LcdUsb();
  await s8.open();
  const before8 = sim.writes.length;
  const c8 = await s8.sendJpeg(pseudoJpeg(1000));
  let j8 = new Uint8Array(0);
  {
    let n = 0;
    for (let i = before8; i < sim.writes.length; i++) { n += sim.writes[i].data.length; }
    j8 = new Uint8Array(n);
    let off = 0;
    for (let i = before8; i < sim.writes.length; i++) {
      j8.set(sim.writes[i].data, off); off += sim.writes[i].data.length;
    }
  }
  const dec8 = decodeChunks(j8);
  check('S8 LY1 变体不补齐', c8 && dec8.cmd === 2 && dec8.paddedChunks === dec8.numChunks,
    `cmd=${dec8.cmd} numChunks=${dec8.numChunks} 补齐后=${dec8.paddedChunks}`);

  // ---------- S9 握手坏响应 ----------
  sim.reset();
  sim.devices = [makeLcdDevice()];
  const bad = makeHandshakeResponse(1, 4);
  bad[8] = 0x00;
  sim.inResponses = [bad];
  const s9 = new LcdUsb();
  check('S9 握手坏响应被拒', (await s9.open()) === null, '返回 null');

  // ---------- S10 未打开时推帧 ----------
  sim.reset();
  const s10 = new LcdUsb();
  check('S10 未打开推帧安全', (await s10.sendJpeg(pseudoJpeg(300))) === false,
    '返回 false 不抛异常');

  for (const r of results) { console.log(r); }
  console.log(`\nUSB 层测试 ${pass}/${pass + fail} ${fail === 0 ? '通过' : '失败'}`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('测试自身异常:', e);
  process.exit(2);
});
