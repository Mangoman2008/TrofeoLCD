/**
 * TelemetryBridge.ets — 接收 shell 侧数据桥推送的遥测 JSON（UDP 回环）
 *
 * shell 侧：node bridge/dsh-bridge.mjs  ->  udp://127.0.0.1:54545
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { BalanceInfo, Telemetry, TelemetryState } from '../common/Types';
import { normalizeTelemetry } from '../common/Normalize';
import { Logger } from '../common/Logger';

export const BRIDGE_PORT: number = 54545;

export class TelemetryBridge {
  private udp: socket.UDPSocket | null = null;
  private decoder = util.TextDecoder.create('utf-8');
  readonly state: TelemetryState = new TelemetryState();
  private listening: boolean = false;

  /**
   * 上一份"好值"缓存（按顶层字段）。
   *
   * ★★ 为什么必须缓存（2026-10-15 实测故障）★★
   *   原来是 `this.state.data = normalizeTelemetry(parsed)` —— **整份替换**，
   *   而 `normalizeTelemetry` 对载荷里**缺失**的字段返回 `undefined`。
   *
   *   当**两个源**同时在推时（本环境实测：外部 node 桥 + 进程内 DSH 插件），
   *   高频的那个会把低频那个的字段**抹掉**：
   *     · 插件每秒推，但不含 balance / printer / weather
   *     · 外部桥推这些，但频率低（balance 600s、printer 5s）
   *   → 插件的包一来，balance/printer 立刻变 undefined，
   *     用户看到的就是「Dotii 数据（余额/打印机）不显示了」。
   *
   *   修法：只把**载荷里真有**的字段写进 state.data；缺失的沿用上一份好值。
   */
  private lastGood: Map<string, Object> = new Map<string, Object>();

  /** sk- key 回调（由 LcdService 挂上；载荷里带了 deepseekKey 时触发一次） */
  OnKey?: (o: Record<string, Object>) => void;

  /**
   * App **自己直连**取到的余额（由 LcdService 写入）。
   * mergeInto 会优先用它，所以任何来源的对象替换都不会把它冲掉 ——
   * 这修掉了"屏上余额闪一下又不见"的竞态。
   */
  DirectBalance?: BalanceInfo;

  /**
   * App **自己直连**本机 bambu-monitor 取到的打印机状态（由 LcdService 写入）。
   * 与 DirectBalance 同一套优先级：直连值优先，任何来源的对象替换都冲不掉。
   */
  DirectPrinter?: Object;

  get isListening(): boolean {
    return this.listening;
  }

  async start(): Promise<boolean> {
    if (this.udp !== null) {
      return true;
    }
    try {
      const s = socket.constructUDPSocketInstance();
      await s.bind({ address: '127.0.0.1', port: BRIDGE_PORT, family: 1 });

      s.on('message', (info: socket.SocketMessageInfo) => {
        this.onMessage(info);
      });
      s.on('error', (err: BusinessError) => {
        // 实测会收到 code=0 / message=undefined 的零星 error 事件（启动时出现过 1 次），
        // 之后照常收包、socket 也没断，属于系统侧通知而不是故障。这种不写进
        // state.lastError（否则它会一直挂在那里直到下一条消息），也不记 E 级——
        // 否则每次启动日志里都有一条看着像失败的红色记录，排障时非常误导。
        const code = (err === undefined || err === null) ? -1 : err.code;
        const msg = (err === undefined || err === null || err.message === undefined)
          ? '（无描述）' : err.message;
        if (code === 0) {
          Logger.w(`数据桥 socket 通知（可忽略，socket 仍可用）: ${code} ${msg}`);
          return;
        }
        this.state.lastError = `${code} ${msg}`;
        Logger.e(`数据桥 socket 错误: ${this.state.lastError}`);
      });
      this.udp = s;
      this.listening = true;
      Logger.i(`数据桥已监听 127.0.0.1:${BRIDGE_PORT}`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.state.lastError = `${err.code} ${err.message}`;
      Logger.e(`数据桥绑定失败: ${this.state.lastError}`);
      this.udp = null;
      this.listening = false;
      return false;
    }
  }

  private onMessage(info: socket.SocketMessageInfo): void {
    try {
      const u8 = new Uint8Array(info.message);
      const text = this.decoder.decodeToString(u8);
      // 归一化：JSON 字段类型不可信，一个字符串数字就会让渲染抛异常
      const parsed = JSON.parse(text) as Object;
      // ★ 按字段合并（不是整份替换）——见 lastGood 的说明。
      //   多源并存时，缺失的字段沿用上一份好值，避免高频源把低频源的字段抹成 undefined。
      this.mergeInto(parsed);
      this.state.lastRxTs = Date.now();
      this.state.packets++;
      this.state.lastError = '';
      // 记下供数方（载荷里的 source 字段；外部 node 桥不发这个字段 → 留空）
      const src = (parsed as Record<string, Object>)['source'];
      this.state.lastSource = (typeof src === 'string') ? src : '';
      // ★ 顺带递 sk- key：余额要能在 DSH 不跑时继续刷新，
      //   App 自己取不到 key（读不了 ~/.dsh），所以由来源递一次并落盘。
      if (this.OnKey !== undefined) {
        this.OnKey(parsed as Record<string, Object>);
      }
    } catch (e) {
      this.state.lastError = `解析失败: ${Logger.safe(e)}`;
      Logger.w(`数据桥报文解析失败`);
    }
  }

  /**
   * 把新载荷**按字段**合并进 state.data。
   *
   * 规则（简单且安全）：
   *   · 载荷里**有**的顶层字段 → 用归一化后的新值
   *   · 载荷里**没有**的 → 沿用 `lastGood` 里上一份非空值
   *   · 新值是 undefined 时不覆盖缓存（保留好值）
   *
   * 只做顶层粒度：不做深层合并，避免复杂度和新的边界 bug。
   */
  /**
   * 把一份载荷按字段合并进 state。
   *
   * ★ 改成 public：**HTTP 快照**也要走同一条合并路径。
   *   实测发现 App 读不了 `~/.dsh/` 里的快照文件（错误码 13900001，沙箱访问控制），
   *   于是快照改为插件用 HTTP 提供（`http://127.0.0.1:54548/snapshot.json`），
   *   由 LcdService 取到后调用这里 —— 这样 UDP 与 HTTP 两条来源共用同一套
   *   "按字段合并 + lastGood 缓存"逻辑，不会互相覆盖。
   */
  mergeInto(raw: Object): void {
    const incoming: Telemetry = normalizeTelemetry(raw);
    const r = raw as Record<string, Object>;
    const next: Telemetry = {};
    // ★ `balance` **不在**合并列表里：余额改由 App 自己直连 DeepSeek API 取
    //   （用户要求"DSH 不跑时余额也要正常"）。若让快照的余额覆盖，
    //   DSH 一停就会把 App 自己取到的余额顶掉 —— 那正是要避免的。
    //   `printer` 同理：App 自己直连本机 8790（不依赖 DSH）。
    const keys: string[] = ['ts', 'agent', 'todos', 'tokens', 'system', 'weather',
      'lyrics', 'events', 'summary', 'health'];
    for (const k of keys) {
      const fresh = (r[k] !== undefined && r[k] !== null);
      let v: Object | undefined = undefined;
      if (fresh) {
        v = (incoming as Record<string, Object>)[k];
      }
      if (v === undefined) {
        // 载荷没带这个字段（或归一化后为空）→ 用上一份好值
        v = this.lastGood.get(k);
      } else {
        this.lastGood.set(k, v);
      }
      if (v !== undefined) {
        (next as Record<string, Object>)[k] = v;
      }
    }
    // ★ 余额特殊处理（**根因修复**，不再靠"每轮重贴"去追竞态）：
    //   本函数每次都会用新对象替换整份 `state.data`，而余额不在合并列表里 →
    //   新对象里没有余额 → **表现就是屏上余额"闪一下又不见了"**
    //   （publishBalance 刚贴上，紧接着一次 merge 就把它冲掉）。
    //   这里在原子上决定余额：App 直连值优先 → 载荷里的值 → lastGood 缓存。
    const incomingBal = (r['balance'] !== undefined && r['balance'] !== null)
      ? (incoming as Record<string, Object>)['balance'] : undefined;
    if (incomingBal !== undefined) {
      this.lastGood.set('balance', incomingBal);
    }
    let finalBal: Object | undefined;
    if (this.DirectBalance !== undefined) {
      finalBal = this.DirectBalance;            // App 自己取的优先（DSH 不跑也有效）
    } else if (incomingBal !== undefined) {
      finalBal = incomingBal;
    } else {
      finalBal = this.lastGood.get('balance');
    }
    if (finalBal !== undefined) {
      (next as Record<string, Object>)['balance'] = finalBal;
    }
    // 打印机同理：App 直连值优先 → 载荷值 → lastGood 缓存。
    // （之前"排除 printer"但 App 侧还没接直连，导致打印机数据两条路都断 —— 已修）
    const incomingPrn = (r['printer'] !== undefined && r['printer'] !== null)
      ? (incoming as Record<string, Object>)['printer'] : undefined;
    if (incomingPrn !== undefined) {
      this.lastGood.set('printer', incomingPrn);
    }
    let finalPrn: Object | undefined;
    if (this.DirectPrinter !== undefined) {
      finalPrn = this.DirectPrinter;
    } else if (incomingPrn !== undefined) {
      finalPrn = incomingPrn;
    } else {
      finalPrn = this.lastGood.get('printer');
    }
    if (finalPrn !== undefined) {
      (next as Record<string, Object>)['printer'] = finalPrn;
    }
    this.state.data = next;
  }

  stop(): void {
    if (this.udp !== null) {
      try {
        this.udp.off('message');
        this.udp.close();
      } catch (e) {
        // ignore
      }
      this.udp = null;
    }
    this.listening = false;
  }

  /**
   * 重新绑定 UDP socket（自愈）。
   *
   * 起因：实测出现过「桥在正常每秒推包、但屏幕数据停在几分钟前」——
   * 收到过一次 `code=0` 的 socket error 通知之后就不再收包了，而桥那边毫无异常。
   * 这时唯一有效的恢复动作就是关掉再绑一次（以前只能重启应用）。
   * 调用方：LcdService 的看门狗 —— 数据超时太久就调这里一次（带节流）。
   */
  async rebind(): Promise<boolean> {
    Logger.w('数据桥长时间收不到包，重新绑定 socket');
    this.stop();
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 300);
    });
    return this.start();
  }
}
