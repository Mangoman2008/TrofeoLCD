/**
 * SelfTest.ets — 协议层已知答案自检（KAT）
 *
 * 目的：真机第一次运行时就能判断"代码是否正确"，而不是靠猜。
 * 期望值由独立的 Python 参考实现（tools/ly_reference.py，严格照
 * thermalright-trcc-linux 的 ly_lcd.py 语义重写）算出，因此这组自检
 * 是拿 ArkTS 实现去对齐参考实现，而不是自己和自己比。
 *
 * 全部为纯计算，不碰 USB，因此可以在没有屏幕的情况下跑。
 */
import { LyProtocol, parseJpegSize, encodeRotation, pmToFbl,
  JpegInfo, PID_LY } from './LyProtocol.ts';
import { pickBulkEndpoints, ep, itf } from './EndpointPick.ts';
import { CalibState, CalibStep, calibrate, nextQuality, VP_MAX_W, VP_MAX_H,
  MAX_CALIB_ATTEMPTS } from '../service/CanvasCalib.ts';
import { normalizePrinter, MAX_TRAYS, normalizeTelemetry, normalizeTodos, MAX_TODOS } from '../common/Normalize.ts';
import { pickSystem } from '../common/SystemMerge.ts';
import { Dashboard } from '../render/Dashboard.ts';
import { randomExpr, DOTII_EXPR_NAMES } from '../render/ThemeDotii.ts';
import { ThemeSnake, SnakeState } from '../render/ThemeSnake.ts';
import { BG_STYLE_NAMES, bgStyleFromName } from '../render/Backdrop.ts';
import type { SystemInfo } from '../common/Types.ts';
import { FrameTickInput, NightWindow, UsbAttemptState, nextFrameInterval,
  shouldAttemptUsbOpen, noteOpenFailure, noteOpenSuccess, armManualRetry,
  INTERVAL_BUSY, INTERVAL_IDLE, INTERVAL_NIGHT, INTERVAL_ERROR,
  USB_RETRY_MS } from '../service/SchedulePolicy.ts';

// ---- 由 tools/ly_reference.py 生成的期望值 ----
const KAT_LEN: number = 1000;
const KAT_FRAME_LEN: number = 2048;
const KAT_FNV: number = 3811976977;
const KAT_CHUNKS: number = 3;
const KAT_PADDED: number = 4;
const KAT_SEG_COUNT: number = 1;
const KAT_SEG_FIRST: number = 2048;

export class TestItem {
  name: string;
  ok: boolean;
  detail: string;

  constructor(name: string, ok: boolean, detail: string) {
    this.name = name;
    this.ok = ok;
    this.detail = detail;
  }
}

/** 确定性伪 JPEG（与参考实现同构） */
function katInput(n: number): Uint8Array {
  const a = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    a[i] = (i * 37 + 11) & 0xFF;
  }
  return a;
}

/** FNV-1a 32 位 */
function fnv1a32(data: Uint8Array): number {
  let h = 2166136261;
  for (let i = 0; i < data.length; i++) {
    h = h ^ data[i];
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

/** 构造一个最小 JPEG：FFD8 + SOF0，声明 1920x480 */
function katJpeg(w: number, h: number): Uint8Array {
  const a = new Uint8Array(12);
  a[0] = 0xFF;
  a[1] = 0xD8;
  a[2] = 0xFF;
  a[3] = 0xC0;
  a[4] = 0x00;
  a[5] = 0x11;         // 段长 17
  a[6] = 0x08;         // 精度
  a[7] = (h >> 8) & 0xFF;
  a[8] = h & 0xFF;
  a[9] = (w >> 8) & 0xFF;
  a[10] = w & 0xFF;
  a[11] = 0x00;
  return a;
}

export class SelfTest {
  static run(): TestItem[] {
    const items: TestItem[] = [];

    /**
     * 0) 单帧 JPEG 上限必须与 C# 侧、以及厂商/开源驱动的实测值一致。
     *
     * ★ 为什么专门给它一条断言：这个常量**曾经与 C# 侧不一致**（ArkTS 650000 / C# 450000），
     *   而后果极隐蔽 —— 450~650KB 的帧应用侧认为"没超限、不用降质"，照常推送，
     *   固件直接忽略：`sent` 正常增长、`sendJpeg` 返回 true、`/diag` 全绿，屏上却是旧画面。
     *   审查（2026-10-15）指出：C# 自检里有这条断言、**ArkTS 自检里没有**，
     *   所以"38/38 通过"从来没覆盖它。现在补上。
     */
    const jpegLimit = LyProtocol.maxJpegSize();
    items.push(new TestItem('JPEG 上限=450000', jpegLimit === 450000,
      `实测 ${jpegLimit}（期望 450000；依据：厂商 dll 的 max_frame_bytes / trofeo-lcd 的 MAX_FRAME_BYTES / 真机 ~570KB 被忽略）`));

    // 1) 分块流字节级一致（FNV-1a）
    const payload = katInput(KAT_LEN);
    const frame = LyProtocol.buildChunkStream(payload, PID_LY);
    const hash = fnv1a32(frame);
    items.push(new TestItem('分块流哈希', hash === KAT_FNV,
      `len=${frame.length}(期望${KAT_FRAME_LEN}) fnv=${hash}(期望${KAT_FNV})`));

    // 2) 块头字段与补齐
    const view = new DataView(frame.buffer);
    const total = view.getUint32(2, true);
    const len0 = view.getUint16(6, true);
    const cmd0 = frame[8];
    const cnt = view.getUint16(9, true);
    const idx0 = view.getUint16(11, true);
    const magicOk = frame[0] === 0x01 && frame[1] === 0xFF;
    const tailOff = 2 * 512;
    const lenTail = view.getUint16(tailOff + 6, true);
    const idxTail = view.getUint16(tailOff + 11, true);
    const headOk = magicOk && total === KAT_LEN && len0 === 496 && cmd0 === 0x01
      && cnt === KAT_CHUNKS && idx0 === 0;
    items.push(new TestItem('块头字段', headOk,
      `magic=${magicOk} total=${total} len0=${len0} cmd=${cmd0} count=${cnt} idx0=${idx0}`));
    items.push(new TestItem('尾块与补齐', lenTail === (KAT_LEN % 496) && idxTail === 2
      && frame.length === KAT_PADDED * 512,
      `尾块len=${lenTail}(期望${KAT_LEN % 496}) 尾idx=${idxTail} 补齐后=${frame.length / 512}块`));

    // 3) 写分段（4096 一次，尾包 min(2048,剩余)）
    const segs = LyProtocol.writeChunks(frame, PID_LY);
    let segOk = segs.length === KAT_SEG_COUNT;
    if (segOk) {
      segOk = segs[0].length === KAT_SEG_FIRST;
    }
    let segInfo = '';
    for (const s of segs) {
      segInfo += `${s.length} `;
    }
    items.push(new TestItem('USB 写分段', segOk,
      `段数=${segs.length}(期望${KAT_SEG_COUNT}) 各段=[${segInfo}]`));

    // 4) 握手解析：真机 9.16 的 resp[20]=1, resp[22]=4 -> PM=65 SUB=5
    const resp = new Uint8Array(512);
    resp[0] = 0x03;
    resp[1] = 0xFF;
    resp[8] = 0x01;
    resp[20] = 1;
    resp[22] = 4;
    const info = LyProtocol.parseHandshakeResponse(resp, PID_LY);
    let hsOk = false;
    let hsDetail = '解析返回 null';
    if (info !== null) {
      hsOk = info.pm === 65 && info.sub === 5 && info.fbl === 192
        && info.width === 1920 && info.height === 462 && info.rotateDeg === 180;
      hsDetail = info.toString();
    }
    items.push(new TestItem('握手解析(PM65/SUB5)', hsOk, hsDetail));

    // 5) 握手校验必须拒绝坏响应
    const bad = new Uint8Array(512);
    bad[0] = 0x03;
    bad[1] = 0xFF;
    bad[8] = 0x00;
    items.push(new TestItem('握手校验拒绝坏响应',
      LyProtocol.parseHandshakeResponse(bad, PID_LY) === null, 'resp[8]=0 应返回 null'));

    // 6) LY1 变体：cmd=0x02 且不补齐
    const ly1 = LyProtocol.buildChunkStream(payload, 0x5409);
    const ly1Cmd = ly1[8];
    items.push(new TestItem('LY1 变体',
      ly1Cmd === 0x02 && ly1.length === KAT_CHUNKS * 512,
      `cmd=${ly1Cmd}(期望2) 长度=${ly1.length}(期望${KAT_CHUNKS * 512})`));

    // 7) 旋转规则
    // 注意：旋转只在 encodeRotation 这一层被验证；实际推帧已不再按握手自动旋转
    const rotOk = encodeRotation(1920, 462, 5) === 180
      && encodeRotation(1920, 462, 5) === 180
      && encodeRotation(1920, 462, 3) === 0
      && encodeRotation(1920, 440, 2) === 0
      && encodeRotation(1280, 480, 2) === 90
      && encodeRotation(1280, 480, 1) === 0;
    items.push(new TestItem('旋转规则', rotOk,
      `1920x480/SUB5=${encodeRotation(1920, 480, 5)}° 1280x480/SUB2=${encodeRotation(1280, 480, 2)}°`));

    // 8) JPEG 尺寸解析（画布自校正依赖它）
    const jp = katJpeg(1920, 480);
    const jinfo: JpegInfo = parseJpegSize(jp);
    items.push(new TestItem('JPEG 尺寸解析',
      jinfo.valid && jinfo.width === 1920 && jinfo.height === 480,
      `${jinfo.width}x${jinfo.height} valid=${jinfo.valid}`));

    // 9) pm_to_fbl 覆写表
    const fblOk = pmToFbl(65) === 192 && pmToFbl(68) === 192
      && pmToFbl(69) === 192 && pmToFbl(64) === 114 && pmToFbl(70) === 70;
    items.push(new TestItem('PM→FBL 覆写表', fblOk,
      `65→${pmToFbl(65)} 68→${pmToFbl(68)} 64→${pmToFbl(64)} 70→${pmToFbl(70)}`));

    // ---- 端点发现（选错端点 = 黑屏，故重点测）----

    // 真实 9.16 的形态：一个 HID 接口 + 一个厂商自定义(bulk)接口 + 一个存储接口
    const hid = itf(0, 3, [ep(0x81, 3, 64)]);
    const vendor = itf(1, 255, [ep(0x09, 2, 512), ep(0x81, 2, 512)]);
    const msc = itf(2, 8, [ep(0x02, 2, 512), ep(0x82, 2, 512)]);
    const real = pickBulkEndpoints([hid, vendor, msc]);
    items.push(new TestItem('端点发现(真实形态)',
      real.ok && real.ifaceId === 1 && real.ifaceClazz === 255
      && real.outAddress === 0x09 && real.inAddress === 0x81
      && real.outMaxPacket === 512,
      real.summary()));

    // 优先级：即使厂商自定义接口排在后面，也应优先于前面的普通接口
    const priority = pickBulkEndpoints([hid, msc, vendor]);
    items.push(new TestItem('端点发现(vendor优先)',
      priority.ok && priority.ifaceClazz === 255 && priority.ifaceId === 1
      && priority.outAddress === 0x09,
      priority.summary()));

    // 确实没有厂商自定义接口时，才取第一个双向接口（下标 1，其 id=2）
    const noVendor = pickBulkEndpoints([hid, msc]);
    items.push(new TestItem('端点发现(无vendor)',
      noVendor.ok && noVendor.ifaceIndex === 1 && noVendor.ifaceId === 2
      && noVendor.outAddress === 0x02 && noVendor.inAddress === 0x82,
      noVendor.summary()));

    // 只有 OUT：必须判为不可用
    const onlyOut = pickBulkEndpoints([itf(0, 255, [ep(0x09, 2, 512)])]);
    items.push(new TestItem('端点发现(缺IN)',
      !onlyOut.ok && onlyOut.reason.indexOf('IN') >= 0,
      onlyOut.summary()));

    // 没有 bulk：必须判为不可用且不选接口
    const noBulk = pickBulkEndpoints([itf(0, 3, [ep(0x81, 3, 64)]),
      itf(1, 8, [ep(0x02, 1, 64)])]);
    items.push(new TestItem('端点发现(无bulk)',
      !noBulk.ok && noBulk.ifaceIndex < 0, noBulk.summary()));

    // 厂商自定义接口只单向、但另一接口双向 -> 应按规则 2 回退
    const vendorOutOnly = itf(0, 255, [ep(0x09, 2, 512)]);
    const fallback = pickBulkEndpoints([vendorOutOnly, itf(1, 8, [ep(0x02, 2, 512), ep(0x82, 2, 512)])]);
    items.push(new TestItem('端点发现(回退)',
      fallback.ok && fallback.ifaceId === 1, fallback.summary()));

    // ---- 画布尺寸自校正（出错 = 永远不出画面）----

    // 密度恰好为 1.5 时首帧即收敛
    const c1 = new CalibState(1280, 320);
    const s1 = calibrate(c1, 1920, 480, 1920, 480);
    items.push(new TestItem('校准(密度1.5首帧收敛)',
      s1.action === 'ready' && c1.calibrated && c1.vpW === 1280,
      `${s1.action} vp=${c1.vpW}x${c1.vpH}`));

    // 密度 2.0：1280x320vp -> 2560x640px，应修正为 960x240vp，下一帧收敛
    const c2 = new CalibState(1280, 320);
    const s2a = calibrate(c2, 1920, 480, 2560, 640);
    const s2b = calibrate(c2, 1920, 480, 1920, 480);
    items.push(new TestItem('校准(密度2.0两帧收敛)',
      s2a.action === 'resize' && Math.abs(c2.vpW - 960) < 0.01
      && Math.abs(c2.vpH - 240) < 0.01 && s2b.action === 'ready',
      `${s2a.note} -> ${s2b.action}`));

    // 密度 1.0：1280x320px 偏小，应放大到 1920x480vp
    const c3 = new CalibState(1280, 320);
    const s3a = calibrate(c3, 1920, 480, 1280, 320);
    const s3b = calibrate(c3, 1920, 480, 1920, 480);
    items.push(new TestItem('校准(密度1.0两帧收敛)',
      s3a.action === 'resize' && c3.vpW === 1920 && c3.vpH === 480
      && s3b.action === 'ready',
      `${s3a.note} -> ${s3b.action}`));

    // 无效测量（0 / NaN）不能改变状态
    const c4 = new CalibState(1280, 320);
    const s4a = calibrate(c4, 1920, 480, 0, 0);
    const s4b = calibrate(c4, 1920, 480, Number.NaN, 480);
    items.push(new TestItem('校准(无效测量跳过)',
      s4a.action === 'invalid' && s4b.action === 'invalid'
      && c4.vpW === 1280 && c4.vpH === 320 && !c4.calibrated,
      `${s4a.note} / ${s4b.note}`));

    // 异常测量值必须被钳制，不能让组件尺寸失控
    const c5 = new CalibState(1280, 320);
    const s5 = calibrate(c5, 1920, 480, 100, 25);
    items.push(new TestItem('校准(异常值钳制)',
      s5.action === 'resize' && c5.vpW <= VP_MAX_W && c5.vpH <= VP_MAX_H,
      `vp=${c5.vpW}x${c5.vpH} (上限 ${VP_MAX_W}x${VP_MAX_H})`));

    // 换设备（PM=68 -> 1280x480）时目标变小也应能收敛
    const c6 = new CalibState(854, 320);
    const s6 = calibrate(c6, 1280, 480, 1280, 480);
    items.push(new TestItem('校准(目标1280x480)',
      s6.action === 'ready' && c6.vpW === 854, `${s6.action} vp=${c6.vpW}`));

    // 兜底：反复不收敛时必须放弃精确校准，按当前尺寸出画面（否则永远黑屏）
    const c7 = new CalibState(1280, 320);
    let forced: CalibStep | null = null;
    let resizeCount = 0;
    for (let i = 0; i < MAX_CALIB_ATTEMPTS + 2; i++) {
      const stp = calibrate(c7, 1920, 480, 999, 999);   // 永远不匹配
      if (stp.action === 'resize') {
        resizeCount++;
      }
      if (stp.action === 'forced') {
        forced = stp;
        break;
      }
    }
    items.push(new TestItem('校准(不收敛兜底)',
      forced !== null && c7.calibrated && resizeCount === MAX_CALIB_ATTEMPTS - 1,
      forced !== null ? forced.note : '未触发兜底'));

    // 兜底后再匹配上，应恢复正常精度（attempts 复位）
    const c8 = new CalibState(1280, 320);
    calibrate(c8, 1920, 480, 999, 999);
    calibrate(c8, 1920, 480, 999, 999);
    const okStep = calibrate(c8, 1920, 480, 1920, 480);
    items.push(new TestItem('校准(恢复精确)',
      okStep.action === 'ready' && c8.attempts === 0,
      `${okStep.action} attempts=${c8.attempts}`));

    // 降质序列：0.9 -> 0.75 -> 0.6 -> 0.45 -> 0.4(下限)
    const q1 = nextQuality(0.9);
    const q2 = nextQuality(q1);
    const q3 = nextQuality(q2);
    items.push(new TestItem('JPEG 降质序列',
      Math.abs(q1 - 0.75) < 1e-9 && Math.abs(q3 - 0.45) < 1e-9
      && nextQuality(0.4) === 0.4 && nextQuality(0.42) === 0.4,
      `0.9->${q1}->${q2}->${q3} 下限=${nextQuality(0.45)}`));

    // ---- 遥测归一化（桥端字段类型不可信）----

    // 载荷用 JSON.parse 构造：ArkTS 禁止嵌套对象字面量 as Object，
    // 而且这样更贴近真实输入路径（UDP 收到的就是 JSON 文本）

    // 字符串数字必须被正确转换，否则渲染会 toFixed 抛异常
    const n1 = normalizeTelemetry(JSON.parse(
      '{"system":{"cpu":"52.5","cores":"16","memUsed":"2048","memTotal":"8192"},'
      + '"tokens":{"todayTotal":"1000","contextUsed":"350","contextWindow":"1000"},'
      + '"agent":{"turn":"7","step":"3"}}') as Object);
    items.push(new TestItem('归一化(字符串数字)',
      n1.system?.cpu === 52.5 && n1.system?.cores === 16
      && n1.tokens?.todayTotal === 1000 && n1.agent?.turn === 7,
      `cpu=${n1.system?.cpu} total=${n1.tokens?.todayTotal} turn=${n1.agent?.turn}`));

    // 越界与负数钳制
    const n2 = normalizeTelemetry(JSON.parse(
      '{"system":{"cpu":150,"memUsed":-5},"tokens":{"contextUsed":-1,"todayInput":-100}}') as Object);
    items.push(new TestItem('归一化(越界钳制)',
      n2.system?.cpu === 100 && n2.system?.memUsed === 0
      && n2.tokens?.contextUsed === 0 && n2.tokens?.todayInput === 0,
      `cpu=${n2.system?.cpu} memUsed=${n2.system?.memUsed}`));

    // 电量：-1 表示"没有电池"，越界要钳到 -1..100（不是 0）；charging 是布尔
    // （与 win/src/SelfTest.cs 的电量用例同构）
    const b1 = normalizeTelemetry(JSON.parse(
      '{"system":{"battery":150,"charging":true}}') as Object);
    const b2 = normalizeTelemetry(JSON.parse('{"system":{"battery":-5}}') as Object);
    const b3 = normalizeTelemetry(JSON.parse('{"system":{"cpu":1}}') as Object);
    items.push(new TestItem('归一化(电量)',
      b1.system?.battery === 100 && b1.system?.charging === true
      && b2.system?.battery === -1 && b3.system?.battery === -1,
      `150→${b1.system?.battery} charging=${b1.system?.charging} `
      + `-5→${b2.system?.battery} 缺省→${b3.system?.battery}`));

    // 合并规则：桥端新鲜也要补本机电量；桥端自己有电量则以桥端为准
    const localSys: SystemInfo = { cpu: 1, battery: 88, charging: true };
    const bridgeSys: SystemInfo = { cpu: 10, battery: -1 };
    const merged = pickSystem(bridgeSys, true, localSys);
    const merged2 = pickSystem({ cpu: 10, battery: 42 } as SystemInfo, true, localSys);
    const merged3 = pickSystem(undefined, false, localSys);
    items.push(new TestItem('系统数据合并(本机电量)',
      merged.cpu === 10 && merged.battery === 88 && merged.charging === true
      && merged2.battery === 42 && merged3.battery === 88,
      `桥端 cpu=${merged.cpu} 电量=${merged.battery} · 桥端自带=${merged2.battery} · 断流用本机=${merged3.battery}`));

    // null 与无法解析的字符串都回退默认，且不得抛异常
    const n2b = normalizeTelemetry(JSON.parse(
      '{"system":{"cpu":null,"host":42},"tokens":{"todayTotal":"abc"}}') as Object);
    items.push(new TestItem('归一化(null/无法解析)',
      n2b.system?.cpu === 0 && n2b.system?.host === 'localhost'
      && n2b.tokens?.todayTotal === 0,
      `cpu=${n2b.system?.cpu} host=${n2b.system?.host} total=${n2b.tokens?.todayTotal}`));

    // 完全垃圾输入不得抛异常
    let junkOk = true;
    try {
      normalizeTelemetry(JSON.parse('42') as Object);
      normalizeTelemetry(JSON.parse('"hello"') as Object);
      normalizeTelemetry(JSON.parse('null') as Object);
      normalizeTelemetry(JSON.parse('[]') as Object);
      normalizeTelemetry(undefined);
      normalizeTelemetry(JSON.parse('{"agent":123,"todos":"x","tokens":[],"system":null}') as Object);
    } catch (e) {
      junkOk = false;
    }
    items.push(new TestItem('归一化(垃圾输入不抛异常)', junkOk, '数字/字符串/null/数组/类型错位'));

    // 待办：非数组 -> []，缺 content 跳过，非法 status 归为 pending，超长截断
    let manyJson = '[';
    for (let i = 0; i < 200; i++) {
      if (i > 0) {
        manyJson += ',';
      }
      manyJson += `{"content":"任务${i}","status":"${i % 2 === 0 ? 'completed' : '完成'}"}`;
    }
    manyJson += ',{"status":"pending"}]';
    const td = normalizeTodos(JSON.parse(manyJson) as Object);
    const tdBad = normalizeTodos(JSON.parse('"nope"') as Object);
    items.push(new TestItem('归一化(待办)',
      td.length === MAX_TODOS && tdBad.length === 0
      && td[1].status === 'pending' && td[0].status === 'completed',
      `200+1 条 -> ${td.length} 条（上限 ${MAX_TODOS}）；非数组 -> ${tdBad.length} 条`));

    // 超长字符串截断
    let long = '';
    for (let i = 0; i < 5000; i++) {
      long += 'x';
    }
    const n3 = normalizeTelemetry(JSON.parse(`{"agent":{"lastText":"${long}"}}`) as Object);
    items.push(new TestItem('归一化(超长文本截断)',
      n3.agent?.lastText !== undefined && n3.agent.lastText.length === 2000,
      `5000 字符 -> ${n3.agent?.lastText?.length} 字符`));

    // ---- 待办轮播：取模循环 ----
    // 一屏 2 条、共 4 条 → 节拍 0/1/2/3 依次从 0/1/2/3 开始，第 4 拍回到 0；
    // 条数不超过一屏时不轮播（一直 0）
    const cr0 = Dashboard.carouselSlice(4, 2, 0);
    const cr1 = Dashboard.carouselSlice(4, 2, 1);
    const cr3 = Dashboard.carouselSlice(4, 2, 3);
    const cr4 = Dashboard.carouselSlice(4, 2, 4);
    const crFlat = Dashboard.carouselSlice(2, 2, 7);
    items.push(new TestItem('待办轮播(取模循环)',
      cr0 === 0 && cr1 === 1 && cr3 === 3 && cr4 === 0 && crFlat === 0,
      `tick0→${cr0} tick1→${cr1} tick3→${cr3} tick4→${cr4}（回到 0）· 不超一屏→${crFlat}`));

    // ---- 打印机（拓竹）归一化 ----

    // 完整的一包：类型全对，应当原样收下
    const p1 = normalizePrinter(JSON.parse(
      '{"state":"RUNNING","stateLabel":"打印中","connected":true,"online":true,'
      + '"jobName":"benchy.gcode","percent":42,"layer":120,"totalLayer":300,'
      + '"remainingSec":3720,"eta":"14:35","nozzleTemp":219.6,"nozzleTarget":220,'
      + '"bedTemp":60,"bedTarget":60,"chamberTemp":34,"wifi":"-52","coolingFan":80,'
      + '"heatbreakFan":60,"speedLevel":2,"printError":0,"trayNow":1,'
      + '"trays":[{"index":1,"type":"PLA","color":"FF0000FF","remain":80},'
      + '{"index":2,"type":"PETG","color":"#00FF00","remain":55}]}') as Object);
    items.push(new TestItem('打印机(完整包)',
      p1 !== undefined && p1.state === 'RUNNING' && p1.percent === 42 && p1.layer === 120
      && p1.totalLayer === 300 && p1.nozzleTemp === 220 && p1.bedTemp === 60
      && p1.trays !== undefined && p1.trays.length === 2
      && p1.trays[0].color === '#FF0000' && p1.trays[1].color === '#00FF00',
      `state=${p1?.state} pct=${p1?.percent} 喷嘴=${p1?.nozzleTemp} 托盘色=${p1?.trays?.[0].color}/${p1?.trays?.[1].color}`));

    // 字符串数字 / 越界 / 缺失都必须被收敛，不能抛异常
    const p2 = normalizePrinter(JSON.parse(
      '{"state":"weird","percent":"abc","layer":"-5","nozzleTemp":999,"bedTemp":-3,'
      + '"coolingFan":250,"speedLevel":99,"hms":"notarray"}') as Object);
    items.push(new TestItem('打印机(类型不可信)',
      p2 !== undefined && p2.state === 'UNKNOWN' && p2.stateLabel === '未知'
      && p2.percent === -1 && p2.layer === 0 && p2.nozzleTemp === 400 && p2.bedTemp === -1
      && p2.coolingFan === 100 && p2.speedLevel === 4 && p2.hmsCount === 0,
      `state=${p2?.state}/${p2?.stateLabel} pct=${p2?.percent} 层=${p2?.layer} 喷嘴=${p2?.nozzleTemp} 风扇=${p2?.coolingFan} 速度=${p2?.speedLevel}`));

    // 空槽要丢掉；托盘数量有上限；颜色非法时不显示色块
    const manyTrays = '{"index":1,"type":"PLA","color":"zzzzzz","remain":10},';
    let trayJson = '[';
    for (let i = 0; i < 12; i++) {
      trayJson += `{"index":${i + 1},"type":"PLA","remain":${i * 5}},`;
    }
    trayJson += '{"index":99,"type":"Empty","remain":0}]';
    const p3 = normalizePrinter(JSON.parse(
      `{"state":"IDLE","trays":${trayJson}}`) as Object);
    items.push(new TestItem('打印机(托盘上限与空槽过滤)',
      p3 !== undefined && p3.trays !== undefined && p3.trays.length === MAX_TRAYS,
      `托盘数=${p3?.trays?.length}（上限 ${MAX_TRAYS}，Empty 已过滤）`));

    const p4 = normalizePrinter(JSON.parse(
      `{"state":"IDLE","trays":[${manyTrays}{"index":2,"type":"PETG","color":"00FF00FF","remain":50}]}`) as Object);
    items.push(new TestItem('打印机(非法颜色不画色块)',
      p4 !== undefined && p4.trays !== undefined && p4.trays.length === 2
      && p4.trays[0].color === undefined && p4.trays[1].color === '#00FF00',
      `第一盘 color=${p4?.trays?.[0].color} 第二盘 color=${p4?.trays?.[1].color}`));

    // HMS 告警：只要条数与第一条短码
    const p5 = normalizePrinter(JSON.parse(
      '{"state":"FAILED","printError":83951617,"hms":[{"code":"0300_0100_0001_0001"},{"code":"x"}]}') as Object);
    items.push(new TestItem('打印机(HMS 条数与短码)',
      p5 !== undefined && p5.hmsCount === 2 && p5.hmsCode === '0300_0100_0001_0001'
      && p5.printError === 83951617,
      `hms=${p5?.hmsCount} code=${p5?.hmsCode} err=${p5?.printError}`));

    // 没有打印机数据时必须返回 undefined —— 面板据此决定要不要拆栏
    const p6 = normalizePrinter(undefined);
    // ArkTS 不允许 `null as Object`，走真实入口的 null 分支更贴近实际
    const p7 = normalizeTelemetry(JSON.parse('{"printer":null}') as Object).printer;
    const p8 = normalizeTelemetry(JSON.parse('{"system":{"cpu":1}}') as Object);
    items.push(new TestItem('打印机(无数据 -> undefined)',
      p6 === undefined && p7 === undefined && p8.printer === undefined,
      `undefined/null/缺字段 都不产生卡片`));

    // 超长文本必须被截断，且离线标志要能被识别
    const p9 = normalizePrinter(JSON.parse(
      `{"state":"OFFLINE","online":false,"jobName":"${'x'.repeat(500)}","model":"${'y'.repeat(200)}"}`) as Object);
    items.push(new TestItem('打印机(超长截断 + 离线)',
      p9 !== undefined && p9.online === false && p9.state === 'OFFLINE'
      && (p9.jobName ?? '').length === 120 && (p9.model ?? '').length === 60,
      `jobName ${(p9?.jobName ?? '').length} 字 / model ${(p9?.model ?? '').length} 字`));

    // 主入口要把 printer 段接上（别只是写了个函数没接线）
    const p10 = normalizeTelemetry(JSON.parse(
      '{"printer":{"state":"RUNNING","percent":7}}') as Object);
    items.push(new TestItem('打印机(主入口接线)',
      p10.printer !== undefined && p10.printer.percent === 7,
      `printer.percent=${p10.printer?.percent}`));

    // ---- 帧调度 / 夜间窗口 / USB 退避 ----

    const iv = (state: string, night: boolean, errored: boolean): number => {
      const i = new FrameTickInput();
      i.state = state;
      i.night = night;
      i.errored = errored;
      return nextFrameInterval(i);
    };
    items.push(new TestItem('帧率决策',
      iv('busy', false, false) === INTERVAL_BUSY
      && iv('waiting', false, false) === INTERVAL_BUSY
      && iv('idle', false, false) === INTERVAL_IDLE
      && iv('unknown', false, false) === INTERVAL_IDLE
      && iv('busy', false, true) === INTERVAL_ERROR
      && iv('busy', true, false) === INTERVAL_NIGHT,
      `busy=${iv('busy', false, false)} idle=${iv('idle', false, false)} `
      + `night=${iv('busy', true, false)} err=${iv('busy', false, true)}`));

    // 跨午夜窗口 18:30 → 09:00
    const nw = new NightWindow(18, 30, 9, 0);
    const at = (h: number, m: number): boolean => nw.contains(h * 60 + m);
    items.push(new TestItem('夜间窗口(跨午夜)',
      at(19, 0) && at(0, 0) && at(3, 30) && at(8, 59) && !at(9, 0)
      && !at(18, 29) && !at(12, 0),
      `19:00=${at(19, 0)} 03:30=${at(3, 30)} 08:59=${at(8, 59)} `
      + `09:00=${at(9, 0)} 12:00=${at(12, 0)}`));

    const nw2 = new NightWindow(9, 0, 18, 0);
    items.push(new TestItem('夜间窗口(同日)',
      nw2.contains(10 * 60) && nw2.contains(17 * 60 + 59) && !nw2.contains(8 * 60 + 59)
      && !nw2.contains(18 * 60),
      '09:00-18:00'));

    const nw3 = new NightWindow(12, 0, 12, 0);
    items.push(new TestItem('夜间窗口(空窗口)',
      !nw3.contains(12 * 60) && !nw3.contains(0), 'start==end 应为空'));

    // USB 退避
    const st = new UsbAttemptState();
    st.lastAttemptMs = 1000;
    const d1 = shouldAttemptUsbOpen(st, 1000 + USB_RETRY_MS - 1, false);
    const d2 = shouldAttemptUsbOpen(st, 1000 + USB_RETRY_MS, false);
    const d3 = shouldAttemptUsbOpen(st, 99999, true);
    items.push(new TestItem('USB 退避(间隔)',
      !d1.attempt && d2.attempt && !d3.attempt,
      `间隔内=${d1.attempt} 到期=${d2.attempt} 已打开=${d3.attempt}`));

    const st2 = new UsbAttemptState();
    noteOpenFailure(st2, true, 5000);
    const after1 = st2.auto;
    noteOpenFailure(st2, true, 9000);
    const after2 = st2.auto;
    const d4 = shouldAttemptUsbOpen(st2, 99999, false);
    armManualRetry(st2);
    const d5 = shouldAttemptUsbOpen(st2, 99999, false);
    noteOpenSuccess(st2);
    items.push(new TestItem('USB 退避(被拒停止)',
      after1 && !after2 && d4.needsManual && !d4.attempt && d5.attempt
      && st2.denied === 0 && st2.auto,
      `拒1次后auto=${after1} 拒2次后auto=${after2} 手动重试=${d5.attempt}`));

    // 非授权类失败不累加 denied
    const st3 = new UsbAttemptState();
    noteOpenFailure(st3, false, 1000);
    noteOpenFailure(st3, false, 2000);
    noteOpenFailure(st3, false, 3000);
    items.push(new TestItem('USB 退避(非授权失败)',
      st3.auto && st3.denied === 0, `denied=${st3.denied} auto=${st3.auto}`));

    // ---- Dotii 表情随机（用户 2026-10-16 要求：随机、不关联其他动作或结果）----
    // 起因：原来 `(expr+1)%8` 顺序轮播，看着像"按顺序播一遍"。
    // 这条自检保证：取值合法、且**与当前不同**（连出同一个会像卡住）。
    {
      const n = DOTII_EXPR_NAMES.length;
      let okRange = n > 0;
      let okDiff = true;
      // 每个当前值都试多次，覆盖随机性；Math.random 的边界（0 与接近 1）也一并覆盖
      for (let cur = 0; cur < n; cur++) {
        for (let k = 0; k < 40; k++) {
          const v = randomExpr(cur);
          if (!(v >= 0 && v < n && Number.isInteger(v))) {
            okRange = false;
          }
          if (v === cur) {
            okDiff = false;
          }
        }
      }
      items.push(new TestItem('Dotii 表情随机·取值合法', okRange,
        `每值 40 次采样均落在 0..${n - 1}`));
      items.push(new TestItem('Dotii 表情随机·不与当前重复', okDiff,
        n <= 1 ? '表情只有 1 个，跳过' : `每值 40 次采样都 != 当前值`));
    }

    // ── 自走贪吃蛇：跑 600 步，全程必须留在棋盘内、身体不重叠 ──
    {
      const st = new SnakeState();
      let t0 = 1000000;
      ThemeSnake.reset(st, t0);
      let ok = true;
      let steps = 0;
      let minLen = 999;
      const boardCells = st.cols * st.rows;
      for (let i = 0; i < 600; i++) {
        t0 += 200;
        ThemeSnake.step(st, t0);
        steps++;
        if (st.length < minLen) {
          minLen = st.length;
        }
        // ★ 环形缓冲：第 i 节要用 segCell() 取，body[] 是固定长度的环
        for (let k = 0; k < st.length; k++) {
          const c = ThemeSnake.segCell(st, k);
          if (c < 0 || c >= boardCells) {
            ok = false;
            break;
          }
        }
        for (let a = 0; a < st.length && ok; a++) {
          for (let b = a + 1; b < st.length; b++) {
            if (ThemeSnake.segCell(st, a) === ThemeSnake.segCell(st, b)) {
              ok = false;
              break;
            }
          }
        }
        if (!ok) {
          break;
        }
      }
      items.push(new TestItem('自走贪吃蛇·600 步不出界不自撞', ok,
        ok ? `跑完 ${steps} 步，长度 ${minLen}..${st.length}，最快 ${ThemeSnake.tickMs(st)}ms/步`
           : `第 ${steps} 步出现越界/自重叠`));
    }

    // ── 背景风格名表：每个名字都要能反查回自己的序号（防止加样式时错位）──
    {
      let ok2 = true;
      const bad: string[] = [];
      for (let i = 0; i < BG_STYLE_NAMES.length; i++) {
        const back = bgStyleFromName(BG_STYLE_NAMES[i]) as number;
        if (back !== i) {
          ok2 = false;
          bad.push(`${BG_STYLE_NAMES[i]}->${back}(应为${i})`);
        }
      }
      items.push(new TestItem('背景风格名表·正反查一致', ok2,
        ok2 ? `${BG_STYLE_NAMES.length} 种：${BG_STYLE_NAMES.join('/')}` : bad.join(' ')));
    }

    return items;
  }
  /** "自检 N/N 通过" 或列出失败项 */
  static summary(items: TestItem[]): string {
    let pass = 0;
    const fails: string[] = [];
    for (const it of items) {
      if (it.ok) {
        pass++;
      } else {
        fails.push(`${it.name}(${it.detail})`);
      }
    }
    if (fails.length === 0) {
      return `自检 ${pass}/${items.length} 通过`;
    }
    return `自检 ${pass}/${items.length} 失败: ${fails[0]}`;
  }

  static allPass(items: TestItem[]): boolean {
    for (const it of items) {
      if (!it.ok) {
        return false;
      }
    }
    return true;
  }
}
