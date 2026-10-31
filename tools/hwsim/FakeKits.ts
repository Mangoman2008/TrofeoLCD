// FakeKits.ts — 假的 usbManager（用于在电脑上运行真实 LcdUsb.ets 源码）
//
// 只实现 @kit.BasicServicesKit 里被 LcdUsb 用到的那部分，语义严格照 SDK 文档：
//   · 失败时 bulkTransfer 返回 -1（不是抛异常）
//   · claimInterface / setConfiguration / releaseInterface / closePipe 返回 0
//   · connectDevice 在无权限时抛 code 14400001

export class BusinessError extends Error {
  code: number = 0;
}

export class FakeEndpoint {
  address: number; type: number; maxPacketSize: number; interval: number = 0;
  direction: number; number: number; interfaceId: number; attributes: number = 2;
  constructor(address: number, type: number, maxPacketSize: number, interfaceId: number) {
    this.address = address; this.type = type; this.maxPacketSize = maxPacketSize;
    this.interfaceId = interfaceId; this.number = address & 0x0f;
    this.direction = (address & 0x80) === 0 ? 0 : 0x80;
  }
}

export class FakeInterface {
  id: number; protocol: number = 0; clazz: number; subClass: number = 0;
  alternateSetting: number = 0; name: string = '';
  endpoints: FakeEndpoint[] = [];
  constructor(id: number, clazz: number, eps: FakeEndpoint[]) {
    this.id = id; this.clazz = clazz; this.endpoints = eps;
  }
}

export class FakeConfig {
  id: number = 1; attributes: number = 0; maxPower: number = 0; name: string = '';
  isRemoteWakeup: boolean = false; isSelfPowered: boolean = false;
  interfaces: FakeInterface[] = [];
  constructor(ifaces: FakeInterface[]) { this.interfaces = ifaces; }
}

export class FakeDevice {
  busNum: number = 1; devAddress: number = 3; serial: string = 'SN-TEST';
  name: string = 'device-1-3'; manufacturerName: string = 'Thermalright';
  productName: string = 'Trofeo Vision 9.16 LCD'; version: string = '1.0';
  vendorId: number = 0x0416; productId: number = 0x5408;
  clazz: number = 0; subClass: number = 0; protocol: number = 0;
  configs: FakeConfig[] = [];
  constructor(cfgs: FakeConfig[]) { this.configs = cfgs; }
}

/** 模拟的 LY 面板：记录所有 OUT 写出，并按脚本返回 IN 数据 */
export const sim = {
  devices: [] as FakeDevice[],
  rights: new Set<string>(),
  grantRight: true,
  failOut: false,
  failIn: false,
  claimed: [] as number[],
  releaseCalls: 0,
  closeCalls: 0,
  pipeOpen: false,
  /** 按顺序返回给 IN 读取的数据 */
  inResponses: [] as Uint8Array[],
  /** 所有 OUT 写出的原始数据（带端点地址） */
  writes: [] as { addr: number; data: Uint8Array }[],
  reset(): void {
    this.devices = []; this.rights.clear(); this.grantRight = true;
    this.failOut = false; this.failIn = false; this.claimed = [];
    this.releaseCalls = 0; this.closeCalls = 0; this.pipeOpen = false;
    this.inResponses = []; this.writes = [];
  },
  /** 把所有 OUT 写出拼起来 */
  outBytes(): Uint8Array {
    let n = 0;
    for (const w of this.writes) { n += w.data.length; }
    const out = new Uint8Array(n);
    let off = 0;
    for (const w of this.writes) { out.set(w.data, off); off += w.data.length; }
    return out;
  },
};

export const usbManager = {
  getDevices(): FakeDevice[] { return sim.devices; },
  hasRight(name: string): boolean { return sim.rights.has(name); },
  async requestRight(name: string): Promise<boolean> {
    if (!sim.grantRight) { return false; }
    sim.rights.add(name);
    return true;
  },
  connectDevice(dev: FakeDevice): { busNum: number; devAddress: number } {
    if (!sim.rights.has(dev.name)) {
      const e = new BusinessError('Access right denied. Call requestRight first.');
      e.code = 14400001;
      throw e;
    }
    sim.pipeOpen = true;
    return { busNum: dev.busNum, devAddress: dev.devAddress };
  },
  setConfiguration(_pipe: Object, _cfg: Object): number { return 0; },
  claimInterface(_pipe: Object, itf: FakeInterface, _force?: boolean): number {
    sim.claimed.push(itf.id);
    return 0;
  },
  releaseInterface(_pipe: Object, _itf: Object): number { sim.releaseCalls++; return 0; },
  closePipe(_pipe: Object): number { sim.closeCalls++; sim.pipeOpen = false; return 0; },
  async bulkTransfer(_pipe: Object, ep: FakeEndpoint, buf: Uint8Array,
                     _timeout?: number): Promise<number> {
    const isOut = (ep.address & 0x80) === 0;
    if (isOut) {
      if (sim.failOut) { return -1; }          // 文档：失败返回 -1
      sim.writes.push({ addr: ep.address, data: new Uint8Array(buf) });
      return buf.length;
    }
    if (sim.failIn) { return -1; }
    const next = sim.inResponses.shift();
    if (next === undefined) { return 0; }
    const n = Math.min(next.length, buf.length);
    buf.set(next.subarray(0, n), 0);
    return n;
  },
};

/** 构造一台长成 Trofeo Vision 样子的设备：HID + 厂商自定义(bulk) + 存储 */
export function makeLcdDevice(pid: number = 0x5408): FakeDevice {
  const hid = new FakeInterface(0, 3, [new FakeEndpoint(0x81, 3, 64, 0)]);
  const vendor = new FakeInterface(1, 255, [
    new FakeEndpoint(0x09, 2, 512, 1),
    new FakeEndpoint(0x81, 2, 512, 1),
  ]);
  const msc = new FakeInterface(2, 8, [
    new FakeEndpoint(0x02, 2, 512, 2),
    new FakeEndpoint(0x82, 2, 512, 2),
  ]);
  const dev = new FakeDevice([new FakeConfig([hid, vendor, msc])]);
  dev.productId = pid;
  return dev;
}

/** 构造握手响应：resp[0]=3 resp[1]=0xFF resp[8]=1，PM=65 SUB=5 */
export function makeHandshakeResponse(pmRaw: number = 1, subRaw: number = 4): Uint8Array {
  const r = new Uint8Array(512);
  r[0] = 0x03; r[1] = 0xFF; r[8] = 0x01;
  r[20] = pmRaw; r[22] = subRaw;
  return r;
}

/** 构造 ACK（内容无意义，只要长度对） */
export function makeAck(): Uint8Array {
  const a = new Uint8Array(512);
  a[0] = 0xAA; a[1] = 0xBB;
  return a;
}
