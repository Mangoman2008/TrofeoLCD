/**
 * RuntimeCheck.ets —— **运行时自检**（区别于 usb/SelfTest.ets 的协议 KAT）
 *
 * ## 两者分工
 * | | 查什么 | 何时能发现问题 |
 * |---|---|---|
 * | `SelfTest.ets`（协议 KAT） | **代码对不对**：握手包字节、分块流哈希、JPEG 上限、端点挑选… 期望值由独立的 `tools/ly_reference.py` 算出 | 纯计算，开机就能跑，不需要屏幕 |
 * | `RuntimeCheck`（本文件） | **链路通不通**：USB 有没有连上、推帧有没有成功、数据桥有没有在推、画面源有没有帧、本机采集有没有拿到数 | 只有真机跑起来才知道 |
 *
 * ## 为什么要有它
 * 排障时最常见的困惑是"**界面看着正常，但屏幕没画面**"或者"**数据停在几分钟前**"。
 * 这些都没有异常日志可查（`sent` 在涨、`usbOpenCount` 恒为 1）。
 * 把关键链路逐项打分并显示在界面上，就能一眼看出**断在哪一环**。
 *
 * 全部只读现有状态，不做任何副作用；由 LcdService 定时调用。
 */
import { TestItem } from '../usb/SelfTest';

/** 运行时自检需要的外部读数（由 LcdService 填进来，避免本模块反向依赖它） */
export interface RuntimeSnapshot {
  /** 协议 KAT 是否全部通过 */
  katPass: boolean;
  katSummary: string;
  /** USB */
  usbOpen: boolean;
  usbLabel: string;
  /** 推帧 */
  sent: number;
  errors: number;
  lastAck: string;
  /**
   * 距**上次成功推帧**过了多少秒；-1 = 从未成功推过。
   *
   * ★ 为什么必须按新鲜度判断（2026-10-16 审计）：
   *   原来这一项用 `sent > 0` 判定 —— 但 sent 是**累计值**，
   *   推帧停了一小时它依然 > 0 → 体检继续报"通过"，而屏上早已不动。
   *   这正是本文件开头警告过的那类"健康表撒谎"，必须按时间窗判断。
   */
  pushAgeSec: number;
  /** 数据桥（UDP 遥测） */
  bridgeListening: boolean;
  bridgeAgeSec: number;
  bridgePackets: number;
  bridgeError: string;
  /** 最近一个包的 source 标识（谁在供数）；空串表示对方没带这个字段 */
  bridgeSource: string;

  /**
   * 明文快照探测（决定"App 能不能直接读文件取数"）。
   * 这是为了回答一个**必须实测**的问题：App 沙箱能不能读 `~/.dsh/` 下的文件。
   * 读得到 → 可以让 App 直接读快照，不再依赖 UDP；读不到 → 改走 HTTP。
   */
  snapshotPath: string;
  snapshotOk: boolean;
  snapshotNote: string;
  /** 画面源（VM 抓帧） */
  vmFrames: number;
  vmErr: string;
  /** 本机采集 */
  hostValid: boolean;
  hostCpuPct: number;
  hostMemUsedMB: number;
  hostMemTotalMB: number;
}

/** 数据桥超过这么久没收到包就判为"没在推"（App 侧新鲜度是 10s，这里留余量） */
const BRIDGE_STALE_SEC: number = 15;

/** 超过这么久没有成功推帧就判为"停更"（USB 屏离线时会走到这里） */
const PUSH_STALE_SEC: number = 10;

export class RuntimeCheck {
  /**
   * 跑一轮运行时自检。
   * 返回的 TestItem 与协议 KAT 同构，所以界面/日志可以复用同一套渲染。
   */
  static run(s: RuntimeSnapshot): TestItem[] {
    const items: TestItem[] = [];

    // 1) 协议 KAT（把已有结果带进来，让"体检表"自成一体）
    items.push(new TestItem('协议自检(KAT)', s.katPass, s.katSummary));

    // 2) USB 连接
    items.push(new TestItem(
      'USB 屏幕连接',
      s.usbOpen,
      s.usbOpen ? s.usbLabel : `${s.usbLabel || '未连接'}｜检查线缆与 WinUSB/libusb 绑定`
    ));

    // 3) 推帧：按**新鲜度**判，不能只看累计 sent。
    //    sent 是累计值，停推一小时它仍 > 0 → 旧判据会一直报"通过"（屏上却不动）。
    const pushFresh: boolean = s.pushAgeSec >= 0 && s.pushAgeSec <= PUSH_STALE_SEC;
    const pushOk: boolean = s.sent > 0 && pushFresh;
    items.push(new TestItem(
      '推帧到屏幕',
      pushOk,
      pushOk
        ? `累计 ${s.sent} 帧｜${s.pushAgeSec}s 前成功推帧｜错误 ${s.errors}${s.lastAck.length > 0 ? '｜' + s.lastAck : ''}`
        : (s.sent > 0
          ? `累计 ${s.sent} 帧，但已 ${s.pushAgeSec}s 没成功推帧（疑似停更）｜错误 ${s.errors}${s.lastAck.length > 0 ? '｜' + s.lastAck : ''}`
          : `一帧都没推成功｜错误 ${s.errors}${s.lastAck.length > 0 ? '｜' + s.lastAck : ''}`)
    ));

    // 4) 数据桥：优先看"有没有在推"（age），其次看累计包数
    const fresh: boolean = s.bridgeAgeSec >= 0 && s.bridgeAgeSec <= BRIDGE_STALE_SEC;
    const bridgeOk: boolean = s.bridgeListening && fresh;
    let bridgeDetail: string;
    if (!s.bridgeListening) {
      bridgeDetail = 'App 侧 UDP 未监听';
    } else if (s.bridgeAgeSec < 0) {
      bridgeDetail = '从未收到遥测｜数据桥没在推';
    } else if (fresh) {
      bridgeDetail = `${s.bridgeAgeSec}s 前收到｜累计 ${s.bridgePackets} 包`;
    } else {
      bridgeDetail = `已停 ${s.bridgeAgeSec}s｜累计 ${s.bridgePackets} 包`;
    }
    if (s.bridgeError.length > 0) {
      bridgeDetail += `｜错误 ${s.bridgeError}`;
    }
    if (s.bridgeSource.length > 0) {
      bridgeDetail += `｜源 ${s.bridgeSource}`;
    }
    items.push(new TestItem('数据桥遥测', bridgeOk, bridgeDetail));

    // 5) 画面源（VM 抓帧）：没配 VM 也算正常，只要不是"一直在错"
    const vmOk: boolean = s.vmFrames > 0 || s.vmErr.length === 0;
    items.push(new TestItem(
      '画面源(VM 抓帧)',
      vmOk,
      s.vmFrames > 0
        ? `已抓 ${s.vmFrames} 帧${s.vmErr.length > 0 ? '｜' + s.vmErr : ''}`
        : (s.vmErr.length > 0 ? s.vmErr : '未配置（不影响其他主题）')
    ));

    // 6) 明文快照可读性（App 沙箱能否读 ~/.dsh/）
    items.push(new TestItem(
      '快照文件可读',
      s.snapshotOk,
      s.snapshotNote.length > 0 ? s.snapshotNote : s.snapshotPath
    ));

    // 7) 本机采集
    items.push(new TestItem(
      '本机数据采集',
      s.hostValid,
      s.hostValid
        ? `CPU ${s.hostCpuPct.toFixed(1)}%｜内存 ${s.hostMemUsedMB}/${s.hostMemTotalMB} MB`
        : '未取到（HostStats 异常）'
    ));

    return items;
  }

  /**
   * 一句话总结：全绿 / N 项不通过（列出名字，方便贴群里）。
   *
   * ★ 判据数值不在这里：数据桥那项的明细由独立的 bridgeProbe() 提供
   *   （2026-10-31 审计 B7：这里原来有一段算了却从不使用的死循环）。
   */
  static summary(items: TestItem[]): string {
    let pass: number = 0;
    const fails: string[] = [];
    for (const it of items) {
      if (it.ok) {
        pass++;
      } else {
        fails.push(it.name);
      }
    }
    if (fails.length === 0) {
      return `全部通过（${pass}/${items.length}）`;
    }
    return `${items.length - fails.length}/${items.length} 通过｜待查：${fails.join('、')}`;
  }

  /** detail 里带判据数值的那一项（供日志用；summary 太短放不下） */
  static bridgeProbe(items: TestItem[]): string {
    for (const it of items) {
      if (it.name === '数据桥遥测') {
        return it.detail;
      }
    }
    return '';
  }
}
