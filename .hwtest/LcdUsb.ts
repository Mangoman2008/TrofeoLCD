/**
 * LcdUsb.ets — 通过 @ohos.usbManager 驱动利民 Trofeo Vision 9.16 LCD
 *
 * 鸿蒙上无法用 usbfs ioctl（SELinux 拒绝 ioctl，实测 open 成功但 control
 * transfer 报 EACCES），USB DDK 又需要系统级权限 ohos.permission.ACCESS_DDK_USB，
 * 所以必须走应用层系统 USB 服务：
 *   getDevices -> requestRight -> connectDevice -> claimInterface -> bulkTransfer
 *
 * 端点选择逻辑抽到 EndpointPick.ets（纯函数，可离线测试）；本文件负责把它与
 * usbManager 的真实对象对上，并在连接时把完整描述符树写进日志，便于真机排障。
 */
import { usbManager } from './FakeKits.ts';
import { BusinessError } from './FakeKits.ts';
import { LyProtocol, DeviceInfo, PID_LY, PID_LY1, VENDOR_ID } from './LyProtocol.ts';
import { EndpointPick, pickBulkEndpoints, ep, itf } from './EndpointPick.ts';
// 这两个是纯类型：必须 import type，否则 Node 类型剥离后会当成值导入
import type { ItfDesc, EpDesc } from './EndpointPick.ts';
import { Logger } from './Logger.ts';

/** usbManager 对象引用（与 ItfDesc[] 同下标） */
class ItfRef {
  itf: usbManager.USBInterface;
  cfg: usbManager.USBConfiguration;
  eps: usbManager.USBEndpoint[];

  constructor(itf_: usbManager.USBInterface, cfg_: usbManager.USBConfiguration,
              eps_: usbManager.USBEndpoint[]) {
    this.itf = itf_;
    this.cfg = cfg_;
    this.eps = eps_;
  }
}

export class LcdUsb {
  private pipe: usbManager.USBDevicePipe | null = null;
  private device: usbManager.USBDevice | null = null;
  private info: DeviceInfo | null = null;
  private opened: boolean = false;
  /**
   * 进行中的打开操作（审计 U1：并发保护）。
   *
   * 原来只有 `opened` 一个保护，而它要**握手成功后**才置位 ——
   * 中间有 `ensureRight`（权限弹窗可数秒）、`connectDevice`、`claimInterface`、
   * `handshake` 多个 await 点。调用侧有 5 处互不互斥的 await 调用，
   * 并发进来就会各自 `connectDevice` → 后一个覆盖 `this.pipe` →
   * **前一个 pipe 永不 closePipe、接口永不 release**，
   * 正是本文件注释里描述过的"反复失败后再也连不上，只能拔插"。
   * 现在：并发调用共享同一次打开。
   */
  private opening: Promise<DeviceInfo | null> | null = null;

  /**
   * 在途写入次数（审计 U7：close() 不能撕断在途传输）。
   * 分批发写时一次 dispatch 会同时挂多个 bulkTransfer，
   * 中途 closePipe 会把分块流撕开 → 花屏。
   */
  private pendingWrites: number = 0;
  /** 是否正在关闭（置位后拒绝新的写入） */
  private closing: boolean = false;
  /** 因 close 在途而延后的真正释放（待 pendingWrites 归零后执行） */
  private closeDeferred: boolean = false;
  /**
   * 本进程内 USB **成功打开**的累计次数（排障用）。
   * 用途：用户反馈"屏上老闪一下开机画面" —— 若这个数字随时间快速增长，
   * 说明屏/链路被反复重新初始化（每次 open 都会重握手）；若它不增长，
   * 那闪烁来自别处（例如屏端固件自身或背光）。
   */
  static openCount: number = 0;
  /** 接口被系统占用（claimInterface != 0）：软件解不开，需拔插 USB */
  claimBlocked: boolean = false;
  /** 诊断：USB 复位尝试次数（claim 失败后自动复位） */
  static resetTries: number = 0;
  /** 诊断：bulkTransfer 短写次数（短写会让分块流缺字节 → 屏花屏/停更，且旧代码不报错） */
  static shortWrites: number = 0;

  private refs: ItfRef[] = [];
  private pick: EndpointPick = new EndpointPick();
  private outEp: usbManager.USBEndpoint | null = null;
  private inEp: usbManager.USBEndpoint | null = null;
  private iface: usbManager.USBInterface | null = null;
  private cfg: usbManager.USBConfiguration | null = null;

  /** 完整描述符 dump（连接时写日志） */
  deviceDump: string[] = [];
  /** 最近一次推帧后设备应答的摘要（判断"到底推没推成功"的关键证据） */
  lastAck: string = '（尚未推帧）';

  get deviceInfo(): DeviceInfo | null {
    return this.info;
  }

  get isOpen(): boolean {
    return this.opened;
  }

  /** 端点选择摘要，界面上显示一行 */
  get endpointSummary(): string {
    return this.pick.summary();
  }

  get deviceLabel(): string {
    if (this.device === null) {
      return '未找到';
    }
    const d = this.device;
    return `${d.productName} (${d.vendorId.toString(16)}:${d.productId.toString(16)})`;
  }

  /** 扫描 0416:5408 / 0416:5409 */
  static findDevice(): usbManager.USBDevice | null {
    let list: usbManager.USBDevice[] = [];
    try {
      list = usbManager.getDevices();
    } catch (e) {
      Logger.e(`getDevices 失败: ${Logger.safe(e)}`);
      return null;
    }
    for (const d of list) {
      if (d.vendorId === VENDOR_ID && (d.productId === PID_LY || d.productId === PID_LY1)) {
        return d;
      }
    }
    return null;
  }

  /** 申请设备访问权限（首次使用会弹窗） */
  static async ensureRight(dev: usbManager.USBDevice): Promise<boolean> {
    try {
      if (usbManager.hasRight(dev.name)) {
        return true;
      }
      const ok = await usbManager.requestRight(dev.name);
      Logger.i(`requestRight: ${ok}`);
      return ok;
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`requestRight 失败: ${err.code} ${err.message}`);
      return false;
    }
  }

  /** 把 usbManager 的配置树拍平成 ItfDesc[]，同时记住真实对象引用 */
  private flatten(dev: usbManager.USBDevice): ItfDesc[] {
    const descs: ItfDesc[] = [];
    this.refs = [];
    for (const cfg of dev.configs) {
      for (const it of cfg.interfaces) {
        const epDescs: EpDesc[] = [];
        for (const e of it.endpoints) {
          epDescs.push(ep(e.address, e.type, e.maxPacketSize));
        }
        descs.push(itf(it.id, it.clazz, epDescs));
        this.refs.push(new ItfRef(it, cfg, it.endpoints));
      }
    }
    return descs;
  }

  /** 记录完整描述符树（真机排障的关键证据） */
  private describe(dev: usbManager.USBDevice): void {
    const lines: string[] = [];
    lines.push(`设备 ${dev.productName} | 厂商 ${dev.manufacturerName} | 序列号 ${dev.serial}`);
    lines.push(`VID:PID=${dev.vendorId.toString(16)}:${dev.productId.toString(16)} `
      + `bus=${dev.busNum} addr=${dev.devAddress} class=${dev.clazz} `
      + `sub=${dev.subClass} proto=${dev.protocol}`);
    for (let c = 0; c < dev.configs.length; c++) {
      const cfg = dev.configs[c];
      lines.push(`  config[${c}] id=${cfg.id} ifaces=${cfg.interfaces.length} `
        + `maxPower=${cfg.maxPower}`);
      for (let i = 0; i < cfg.interfaces.length; i++) {
        const it = cfg.interfaces[i];
        lines.push(`    iface[${i}] id=${it.id} class=${it.clazz} sub=${it.subClass} `
          + `proto=${it.protocol} alt=${it.alternateSetting} eps=${it.endpoints.length}`);
        for (let e = 0; e < it.endpoints.length; e++) {
          const epx = it.endpoints[e];
          lines.push(`      ep[${e}] addr=0x${epx.address.toString(16)} `
            + `type=${epx.type} dir=${(epx.address & 0x80) === 0 ? 'OUT' : 'IN'} `
            + `maxPacket=${epx.maxPacketSize} interval=${epx.interval}`);
        }
      }
    }
    this.deviceDump = lines;
    for (const l of lines) {
      Logger.i(`[USB] ${l}`);
    }
  }

  private pickEndpoints(dev: usbManager.USBDevice): boolean {
    const descs = this.flatten(dev);
    this.pick = pickBulkEndpoints(descs);
    Logger.i(`[USB] 端点选择: ${this.pick.summary()}`);

    const idx = this.pick.ifaceIndex;
    if (idx < 0 || idx >= this.refs.length) {
      return false;
    }
    const ref = this.refs[idx];
    this.iface = ref.itf;
    this.cfg = ref.cfg;
    this.outEp = this.pick.outIndex >= 0 ? ref.eps[this.pick.outIndex] : null;
    this.inEp = this.pick.inIndex >= 0 ? ref.eps[this.pick.inIndex] : null;
    return this.pick.ok;
  }

  /** 打开设备并完成 LY 握手，返回设备信息 */
  async open(): Promise<DeviceInfo | null> {
    if (this.opened) {
      return this.info;
    }
    // 并发保护：已有一次打开在进行中 → 直接复用它的结果（见 opening 字段注释）
    if (this.opening !== null) {
      return this.opening;
    }
    this.opening = this.doOpen();
    try {
      return await this.opening;
    } finally {
      this.opening = null;
    }
  }

  /** 真正的打开流程（由 open() 做并发保护后调用） */
  private async doOpen(): Promise<DeviceInfo | null> {
    if (this.opened) {
      return this.info;
    }
    const dev = LcdUsb.findDevice();
    if (dev === null) {
      Logger.w('未发现 0416:5408/5409 设备');
      return null;
    }
    this.device = dev;
    this.describe(dev);

    const granted = await LcdUsb.ensureRight(dev);
    if (!granted) {
      Logger.e('USB 权限被拒绝');
      return null;
    }

    if (!this.pickEndpoints(dev)) {
      Logger.e(`未找到可用 bulk 端点: ${this.pick.summary()}`);
      return null;
    }

    // ★ 连接前**重新取一次设备对象**。
    //   起因（实测日志）：`connectDevice 失败: Cannot read property busNum of undefined` ——
    //   前面 `await ensureRight(dev)` 是异步的（权限请求可能几百毫秒），这期间如果屏
    //   **重新枚举**（掉电复位 → 地址从 addr=2 变 addr=3），原先那个 dev 对象就失效了，
    //   传给 connectDevice 会读到 undefined 的 busNum。
    //   屏在供电不足时会周期性复位重枚举，所以这个竞态在实践中很容易命中。
    //   修正：连接前用最新列表里的对象；若列表里没有（空窗期）就直接返回，等下一轮重试。
    let fresh = LcdUsb.findDevice();
    if (fresh === null) {
      Logger.w('连接前设备已消失（正在重新枚举），等待下一轮重试');
      return null;
    }
    if (fresh.devAddress !== dev.devAddress) {
      Logger.w(`设备地址已变化 ${dev.devAddress} → ${fresh.devAddress}（重新枚举），改用新对象连接`);
      this.device = fresh;
      if (!this.pickEndpoints(fresh)) {
        Logger.e('新设备对象未找到可用 bulk 端点');
        return null;
      }
    }
    try {
      this.pipe = usbManager.connectDevice(fresh);
      Logger.i(`已连接 ${fresh.name}, pipe bus=${this.pipe.busNum} dev=${this.pipe.devAddress}`);
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`connectDevice 失败: ${err.code} ${err.message}`);
      this.pipe = null;
      return null;
    }

    if (this.cfg !== null) {
      try {
        usbManager.setConfiguration(this.pipe, this.cfg);
      } catch (e) {
        Logger.w(`setConfiguration 忽略: ${Logger.safe(e)}`);
      }
    }
    this.claimBlocked = false;
    if (this.iface !== null) {
      try {
        const r = usbManager.claimInterface(this.pipe, this.iface, true);
        // ★ 用 claimed 跟踪**最终**结果：下面"复位后重试"若成功，
        //   不能被原始的 r 覆盖（否则重试等于白做，还误报"接口被占用"）。
        let claimed: boolean = (r === 0);
        Logger.i(`claimInterface iface=${this.iface.id} ret=${r}`);

        // ★ claim 失败 → 先尝试**软件复位设备**再重试一次。
        //   起因（实测）：应用被强杀时来不及跑 close()，接口会留在 claimed 状态，
        //   之后每次都 claimInterface ret=-1，而且**拔插 USB 线也解不开**
        //   （设备端 USB 主机控制器仍持有那个接口引用）。
        //   SDK 提供 resetUsbDevice(pipe)（@since 20，本机 API 26）可以复位设备，
        //   让主机控制器释放接口 —— 此前代码完全没用过它，只把错误上报成文案。
        if (r !== 0) {
          LcdUsb.resetTries++;
          try {
            const rst = usbManager.resetUsbDevice(this.pipe);
            Logger.w(`claim 失败(ret=${r}) → resetUsbDevice=${rst}（第 ${LcdUsb.resetTries} 次）`);
            if (rst) {
              // 复位后重新 claim；成功则继续握手，失败就交给外层回滚+下一轮重试
              const r2 = usbManager.claimInterface(this.pipe, this.iface, true);
              Logger.i(`复位后重新 claimInterface ret=${r2}`);
              if (r2 === 0) {
                claimed = true;
              }
            }
          } catch (e) {
            Logger.w(`resetUsbDevice 异常: ${Logger.safe(e)}`);
          }
        }
        if (!claimed) {
          // ★ 这一条以前只写日志、没上报，导致屏不在线时 lastError 只显示"握手失败"，
          //   看不出真因。实测 ret=-1 的含义是**接口被内核/上一次会话占住**
          //   （应用被强杀时来不及跑 close() 就会这样），软件侧解不开，
          //   唯一恢复动作 = 拔插一次 USB 线。
          this.claimBlocked = true;
          Logger.e(`接口被占用 claimInterface ret=${r}（需要拔插 USB 线才能恢复）`);
        }
      } catch (e) {
        this.claimBlocked = true;
        Logger.w(`claimInterface 异常: ${Logger.safe(e)}`);
      }
    }

    const ok = await this.handshake();
    if (!ok) {
      // ★ 握手失败必须**回滚**：走到这里时 this.pipe 已被 connectDevice 赋值、
      //   接口也已 claimInterface。若不释放，下一次 open() 会在第 194 行直接
      //   覆盖旧句柄 → 旧 pipe 永不 closePipe、接口永久 claimed → 句柄/接口泄漏，
      //   表现为"反复失败后再也连不上，只能 force-stop 重开"（实测踩过）。
      Logger.w('握手失败，回滚 USB 句柄与接口');
      this.close();
      return null;
    }
    this.opened = true;
    LcdUsb.openCount++;
    Logger.i(`USB 已打开（本进程第 ${LcdUsb.openCount} 次）`);
    return this.info;
  }

  /** 发送 2048 字节握手包并解析响应 */
  private async handshake(): Promise<boolean> {
    if (this.pipe === null || this.outEp === null || this.inEp === null) {
      Logger.e('握手前缺少 pipe 或端点');
      return false;
    }
    const pid = this.device === null ? PID_LY : this.device.productId;
    try {
      const hs = LyProtocol.buildHandshake();
      let wrote = await usbManager.bulkTransfer(this.pipe, this.outEp, hs, 2000);
      if (wrote < 0) {
        // ★ 端点错误态**自愈**（2026-10-20 新增，来自一次真实事故）：
        //   现象是 `claimInterface ret=0`（成功）但**第一次 bulkTransfer 就返回 -1**，
        //   原因是同端点并发写把 OUT 端点打进错误态（实测 wbatch=12 就会触发）。
        //   原代码只在 claim 失败时才 resetUsbDevice，覆盖不到这条路径 →
        //   掉进这个状态就只能让用户拔插 USB 线。
        Logger.w(`握手写失败(${wrote}) → 尝试 resetUsbDevice 自愈`);
        try {
          const rst = usbManager.resetUsbDevice(this.pipe);
          Logger.w(`resetUsbDevice=${rst}`);
          if (rst) {
            try {
              usbManager.releaseInterface(this.pipe, this.iface);
            } catch (e2) {
              // ignore
            }
            const r2 = usbManager.claimInterface(this.pipe, this.iface, true);
            Logger.i(`自愈后重新 claimInterface ret=${r2}`);
            if (r2 === 0) {
              wrote = await usbManager.bulkTransfer(this.pipe, this.outEp, hs, 2000);
              Logger.i(`自愈后重试握手写 = ${wrote}`);
            }
          }
        } catch (e3) {
          Logger.w(`自愈过程异常: ${Logger.safe(e3)}`);
        }
      }
      // ★ 握手包也必须写满（审计 U2）：短写会让设备收到半个握手 → 无响应/错乱
      if (wrote >= 0 && wrote !== hs.length) {
        LcdUsb.shortWrites++;
        Logger.e(`握手短写 ${wrote}/${hs.length}`);
      }
      // bulkTransfer 失败时返回 -1（文档：驱动异常），不是抛异常 —— 必须显式检查
      if (wrote < 0) {
        Logger.e(`握手发送失败: bulkTransfer 返回 ${wrote}（-1 = 驱动异常，自愈也没救回来）`);
        return false;
      }
      Logger.i(`握手已发送 ${wrote} 字节`);

      const respBuf = new Uint8Array(512);
      const read = await usbManager.bulkTransfer(this.pipe, this.inEp, respBuf, 3000);
      if (read < 0) {
        Logger.e(`握手响应读取失败: bulkTransfer 返回 ${read}`);
        return false;
      }
      Logger.i(`握手响应 ${read} 字节, [0..8]=${LcdUsb.hex(respBuf, 9)}`);

      // ★ 必须**只把实际读到的字节**交给解析（审计 U6）：
      //   respBuf 是 512 字节全零缓冲，直接传整块会让 `resp.length < 37` 恒不成立，
      //   校验形同虚设。设备若只回 9~20 字节，resp[20]/resp[22] 取到 0 →
      //   会"成功"解析出编造的分辨率（1920x462），后续按错误尺寸推帧。
      //   截断后长度不足会正常返回 null → 判握手失败，不会带错误信息往下走。
      const info = LyProtocol.parseHandshakeResponse(respBuf.subarray(0, read), pid);
      if (info === null) {
        Logger.e('握手校验失败（resp[0]/[1]/[8] 不匹配）');
        return false;
      }
      this.info = info;
      Logger.i(`设备: ${info.toString()}`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`握手失败: ${err.code} ${err.message}`);
      return false;
    }
  }

  /**
   * 读取 512 字节 ACK。
   *
   * 面板每收完一帧会回一个应答；参考实现只记录它的长度与前 8 字节
   * （C# 侧等 100ms，超时也不报错）。这里把它记录下来供界面显示：
   * 屏幕黑屏时，「有没有 ACK / ACK 长什么样」是最直接的判断依据。
   */
  private async readAck(): Promise<void> {
    if (this.pipe === null || this.inEp === null) {
      return;
    }
    const t0 = Date.now();
    try {
      const buf = new Uint8Array(512);
      const n = await usbManager.bulkTransfer(this.pipe, this.inEp, buf, 500);
      const ms = Date.now() - t0;
      if (n < 0) {
        this.lastAck = `传输失败(-1)/${ms}ms`;
        return;
      }
      let head = '';
      const lim = Math.min(8, buf.length);
      for (let i = 0; i < lim; i++) {
        head += buf[i].toString(16).padStart(2, '0') + ' ';
      }
      this.lastAck = `${n}B/${ms}ms [${head.trim()}]`;
    } catch (e) {
      this.lastAck = `无应答(${Date.now() - t0}ms 超时)`;
    }
  }

  /**
   * 一帧内一次并发派发多少个 4KB 写（1 = 逐个 await，旧行为）。
   * 只影响主机侧调用节奏，**线上字节与分块格式一个字节都不变**。
   * 运行时：/set?wbatch=N
   */
  static writeBatch: number = 1;

  /**
   * ★ 并发写被实测判定为危险，默认关闭（=1 逐个 await）。
   *
   * 事故记录（2026-10-14）：把 writeBatch 设成 4 后，同一端点并发 bulkTransfer 会把
   * 分块流撕开 —— 屏花屏 → 卡在开机画面，应用侧 bulkTransfer 也开始返回 -1。
   * 原因：LY 协议要求 512B 分块**严格按序**送达，并发派发无法保证设备端看到的顺序；
   * 而且 HAL 对同端点的并发调用会互相阻塞（实测 push 从 34ms 涨到 1540ms）。
   * 结论：写必须严格串行。要做流水线只能"跨帧重叠"，不能"帧内并发"。
   */

  /** 推一帧 JPEG */
  async sendJpeg(jpeg: Uint8Array): Promise<boolean> {
    if (this.pipe === null || this.outEp === null) {
      return false;
    }
    const pid = this.device === null ? PID_LY : this.device.productId;
    try {
      const stream = LyProtocol.buildChunkStream(jpeg, pid);
      const writes = LyProtocol.writeChunks(stream, pid);
      // ★ 分批发写：单次 bulkTransfer 仍是 4096B（端点/ HAL 只认这个量级，实测 8KB 会把
      //   端点打进错误态），但**同一批内不逐个 await** —— 让 HAL 的每次写往返重叠起来。
      //   实测每次 4KB 写有约 5ms 固定开销，逐次 await 会把 11 次写串成 ~55ms；
      //   分批派发后这段开销可以互相盖住。批大小用 /set?wbatch=N 调（1 = 退回旧行为）。
      const batch = LcdUsb.writeBatch > 1 ? LcdUsb.writeBatch : 1;
      for (let i = 0; i < writes.length; i += batch) {
        // ★ 在途写入计数（审计 U7）：关闭请求要等在途写完，否则会撕开分块流。
        //   若已经开始关闭，直接放弃这一帧（下一轮会重连）。
        if (this.closing) {
          throw new Error('正在关闭 USB，放弃本帧');
        }
        const group: Promise<number>[] = [];
        const n0 = Math.min(i + batch, writes.length);
        this.pendingWrites += (n0 - i);
        for (let k = i; k < n0; k++) {
          group.push(usbManager.bulkTransfer(this.pipe, this.outEp, writes[k], 5000));
        }
        let results: number[] = [];
        try {
          results = await Promise.all(group);
        } finally {
          // 无论成功/失败/短写，都要把这一批的在途计数还回去
          for (let k = i; k < n0; k++) {
            this.noteWriteDone();
          }
        }
        for (let k = 0; k < results.length; k++) {
          const sent = results[k];
          const want = writes[i + k].length;
          if (sent < 0) {
            // 走到 catch 里统一做掉线处理
            throw new Error(`bulkTransfer 返回 ${sent}（-1 = 驱动异常）`);
          }
          // ★ **短写必须当错误**（审计 U2）：bulkTransfer 成功时可能只写入一部分
          //   （SDK 契约允许返回 <= 请求长度的字节数）。若静默接受，分块流中间就缺字节
          //   → 屏上一帧花屏/直接停更，而 sendJpeg 仍返回 true、/diag 全绿，
          //   属于"最难查"的那类故障。宁可判失败触发重连，也不要把字节流撕坏。
          if (sent !== want) {
            LcdUsb.shortWrites++;
            throw new Error(`bulkTransfer 短写 ${sent}/${want}（字节流被撕开，判为失败）`);
          }
        }
      }
      await this.readAck();
      return true;
    } catch (e) {
      const err = e as BusinessError;
      const msg = (err !== null && err.message !== undefined) ? err.message : `${e}`;
      Logger.e(`推帧失败: ${msg}`);
      // 传输出错视为设备掉线，等待重连
      this.close();
      return false;
    }
  }

  /**
   * 关闭并释放 USB。
   *
   * ★ 若有**在途写入**，先标记 deferred，等它们归零后再真正释放（审计 U7）：
   *   分批发写一次会挂多个 bulkTransfer，此时 closePipe 会把分块流撕开 → 花屏/停更。
   */
  close(): void {
    this.closing = true;
    if (this.pendingWrites > 0) {
      this.closeDeferred = true;
      Logger.w(`close() 延后：还有 ${this.pendingWrites} 个在途写入`);
      return;
    }
    this.releaseNow();
  }

  /**
   * 在途写入计数变化；归零且有待执行的 close 时，立即释放。
   */
  private noteWriteDone(): void {
    if (this.pendingWrites > 0) {
      this.pendingWrites--;
    }
    if (this.pendingWrites === 0 && this.closeDeferred) {
      this.closeDeferred = false;
      this.releaseNow();
    }
  }

  /** 立即释放句柄与接口（由 close() / noteWriteDone() 调用） */
  private releaseNow(): void {
    this.closing = false;
    if (this.pipe !== null) {
      try {
        if (this.iface !== null) {
          usbManager.releaseInterface(this.pipe, this.iface);
        }
      } catch (e) {
        // ignore
      }
      try {
        usbManager.closePipe(this.pipe);
      } catch (e) {
        // ignore
      }
    }
    this.pipe = null;
    this.opened = false;
    this.info = null;
    // ★ 同时清掉端点/接口/配置/描述符表：否则下一次 open() 会拿旧的 iface/端点
    //   去操作一个已经 closePipe 的 pipe（句柄悬空），或把旧 refs 混进新设备。
    this.iface = null;
    this.cfg = null;
    this.outEp = null;
    this.inEp = null;
    this.refs = [];
  }

  private static hex(a: Uint8Array, n: number): string {
    let s = '';
    const lim = Math.min(n, a.length);
    for (let i = 0; i < lim; i++) {
      s += a[i].toString(16).padStart(2, '0') + ' ';
    }
    return s;
  }
}
