/**
 * EndpointPick.ets — USB 端点/接口选择（纯逻辑，与 usbManager 解耦）
 *
 * 为什么单独抽出来：选错端点 = 屏幕全黑，而且现场很难判断。
 * 这里只依赖最小的描述结构，因此可以在电脑上（Node 类型剥离）用合成描述符
 * 做已知答案测试，见 SelfTest.ets。
 *
 * 选择规则（按优先级）：
 *   1. 优先「厂商自定义接口」（clazz === 255）且同时具备 bulk OUT/IN
 *   2. 否则第一个同时具备 bulk OUT/IN 的接口
 *   3. 再否则取含 bulk 端点的接口，但 ok=false 并给出原因
 */

/** 端点最小描述（type: 2 = bulk，即 USB bmAttributes & 0x3） */
export interface EpDesc {
  address: number;
  type: number;
  maxPacketSize: number;
}

/** 接口最小描述 */
export interface ItfDesc {
  id: number;
  clazz: number;
  alternateSetting: number;
  endpoints: EpDesc[];
}

/** 单个接口内的 bulk 端点下标 */
class BulkPair {
  outIdx: number = -1;
  inIdx: number = -1;

  get both(): boolean {
    return this.outIdx >= 0 && this.inIdx >= 0;
  }

  get any(): boolean {
    return this.outIdx >= 0 || this.inIdx >= 0;
  }
}

/** 端点选择结果 */
export class EndpointPick {
  ok: boolean = false;
  /** 接口在传入数组中的下标（-1 = 未选中） */
  ifaceIndex: number = -1;
  ifaceId: number = -1;
  ifaceClazz: number = -1;
  outIndex: number = -1;
  inIndex: number = -1;
  outAddress: number = 0;
  inAddress: number = 0;
  outMaxPacket: number = 0;
  reason: string = '';

  summary(): string {
    if (this.ifaceIndex < 0) {
      return `无可用端点（${this.reason}）`;
    }
    const hex = (v: number): string => `0x${v.toString(16)}`;
    let s = `iface${this.ifaceId}/class${this.ifaceClazz} `
      + `OUT=${hex(this.outAddress)} IN=${hex(this.inAddress)}`;
    if (!this.ok) {
      s += ` ⚠ ${this.reason}`;
    }
    return s;
  }
}

export function ep(address: number, type: number, maxPacketSize: number): EpDesc {
  const e: EpDesc = { address: address, type: type, maxPacketSize: maxPacketSize };
  return e;
}

export function itf(id: number, clazz: number, endpoints: EpDesc[]): ItfDesc {
  const i: ItfDesc = { id: id, clazz: clazz, alternateSetting: 0, endpoints: endpoints };
  return i;
}

const BULK: number = 2;

/** 在单个接口内定位 bulk OUT / IN */
function scanInterface(i: ItfDesc): BulkPair {
  const pair = new BulkPair();
  for (let k = 0; k < i.endpoints.length; k++) {
    const e = i.endpoints[k];
    if (e.type !== BULK) {
      continue;
    }
    const isOut = (e.address & 0x80) === 0;
    if (isOut) {
      if (pair.outIdx < 0) {
        pair.outIdx = k;
      }
    } else {
      if (pair.inIdx < 0) {
        pair.inIdx = k;
      }
    }
  }
  return pair;
}

function apply(res: EndpointPick, index: number, i: ItfDesc, pair: BulkPair): void {
  res.ifaceIndex = index;
  res.ifaceId = i.id;
  res.ifaceClazz = i.clazz;
  if (pair.outIdx >= 0) {
    res.outIndex = pair.outIdx;
    res.outAddress = i.endpoints[pair.outIdx].address;
    res.outMaxPacket = i.endpoints[pair.outIdx].maxPacketSize;
  }
  if (pair.inIdx >= 0) {
    res.inIndex = pair.inIdx;
    res.inAddress = i.endpoints[pair.inIdx].address;
  }
}

export function pickBulkEndpoints(ifaces: ItfDesc[]): EndpointPick {
  const res = new EndpointPick();

  // 1) 厂商自定义接口（class 255）且双向齐全
  for (let i = 0; i < ifaces.length; i++) {
    if (ifaces[i].clazz !== 255) {
      continue;
    }
    const pair = scanInterface(ifaces[i]);
    if (pair.both) {
      apply(res, i, ifaces[i], pair);
      res.ok = true;
      res.reason = 'vendor-specific(class 255)';
      return res;
    }
  }

  // 2) 任意接口，双向齐全
  for (let i = 0; i < ifaces.length; i++) {
    const pair = scanInterface(ifaces[i]);
    if (pair.both) {
      apply(res, i, ifaces[i], pair);
      res.ok = true;
      res.reason = 'first bidirectional';
      return res;
    }
  }

  // 3) 单向可用：地址仍返回，但标记为不可用
  for (let i = 0; i < ifaces.length; i++) {
    const pair = scanInterface(ifaces[i]);
    if (pair.any) {
      apply(res, i, ifaces[i], pair);
      res.ok = false;
      res.reason = pair.outIdx < 0 ? 'missing bulk OUT' : 'missing bulk IN';
      return res;
    }
  }

  res.reason = 'no bulk endpoint at all';
  return res;
}
