/**
 * SchedulePolicy.ets — 帧调度与重试策略（纯逻辑，可离线测试）
 *
 * 这些判断散在帧循环里时无法测试，而它们直接决定"画面会不会动"：
 *   - 自适应帧率（忙碌时高帧率让呼吸动画流畅，空闲时省电）
 *   - 夜间熄屏窗口（跨午夜的时间段判断，容易写错）
 *   - USB 打开失败的退避（被拒 2 次后停止自动重试，避免反复弹权限窗）
 *   - 推帧前的尺寸校准门槛
 */

/** 帧间隔（毫秒） */
export const INTERVAL_BUSY: number = 66;    // ~15fps
export const INTERVAL_IDLE: number = 500;   // 2fps
export const INTERVAL_NIGHT: number = 3000; // 夜间熄屏，只维持心跳
export const INTERVAL_ERROR: number = 1000; // 出错后重试
/**
 * 壁纸/二次元类主题（10~14）的帧间隔下限（ms）。
 *
 * ★ 2026-10-21（用户反馈"选 11/12/14 界面卡、13 还好"）：实测应用进程 CPU
 *   13 = 35.8%、12 = 42.0%、14 = 43.2%、11 = 45.8%。差别不在单帧成本，而在
 *   **推帧频率**：12 跑到 4.6~5.2fps，而 13 只有 3.1~3.2fps，多推近 50% 的帧
 *   → CPU 高 → 界面发涩。这些主题是静态壁纸+轻微飘动，**2.5fps 完全够看**。
 */
export const INTERVAL_WALLPAPER: number = 300;
export const USB_RETRY_MS: number = 5000;
export const USB_MAX_DENIED: number = 2;

export class NightWindow {
  startMin: number;
  endMin: number;

  constructor(startHour: number, startMinute: number, endHour: number, endMinute: number) {
    this.startMin = startHour * 60 + startMinute;
    this.endMin = endHour * 60 + endMinute;
  }

  /** 是否处于夜间窗口内（支持跨午夜，如 18:30 → 09:00） */
  contains(minuteOfDay: number): boolean {
    if (this.startMin === this.endMin) {
      return false;   // 空窗口
    }
    if (this.startMin < this.endMin) {
      return minuteOfDay >= this.startMin && minuteOfDay < this.endMin;
    }
    // 跨午夜
    return minuteOfDay >= this.startMin || minuteOfDay < this.endMin;
  }
}

export class FrameTickInput {
  /** 当前主题号（壁纸类主题要限帧，见 INTERVAL_WALLPAPER） */
  theme: number = 0;
  /** agent 状态：busy / waiting / idle / unknown */
  state: string = 'unknown';
  /** 是否处于夜间窗口且启用了熄屏 */
  night: boolean = false;
  /** 上一帧是否出错 */
  errored: boolean = false;
}

/** 下一帧间隔 */
export function nextFrameInterval(inp: FrameTickInput): number {
  // ★ 壁纸/二次元类主题（10~14）：给一个帧间隔下限。
  //   这些主题每帧都在动（星光/花瓣/气泡），内容签名每帧都变 → 永不跳过，
  //   CPU 随推帧频率线性上涨（实测 12 跑 5fps、CPU 42%；13 跑 3.2fps、CPU 36%）。
  //   它们是"静态壁纸 + 轻微飘动"，2.5fps 完全够看，还能把界面让给 UI。
  // 主题 18「天气」：地球自转 + 粒子 + 曲线高亮点都在动，4~5fps 才顺
  if (inp.theme === 18 && !inp.night) {
    return 150;   // ~3.5fps：地球自转与粒子才顺
  }
  if (inp.theme >= 10 && inp.theme <= 14 && !inp.night) {
    const base: number = nextFrameIntervalInner(inp);
    return base > INTERVAL_WALLPAPER ? base : INTERVAL_WALLPAPER;
  }
  return nextFrameIntervalInner(inp);
}

function nextFrameIntervalInner(inp: FrameTickInput): number {
  if (inp.night) {
    return INTERVAL_NIGHT;
  }
  if (inp.errored) {
    return INTERVAL_ERROR;
  }
  if (inp.state === 'busy' || inp.state === 'waiting') {
    return INTERVAL_BUSY;
  }
  return INTERVAL_IDLE;
}

export class UsbAttemptState {
  /** 连续被拒绝授权次数 */
  denied: number = 0;
  /** 是否允许自动重试（被拒多次后置 false，需用户手动点「连接屏幕」） */
  auto: boolean = true;
  lastAttemptMs: number = 0;
}

export class UsbAttemptDecision {
  attempt: boolean = false;
  reason: string = '';
  /** 需要用户手动触发（自动重试已被关闭） */
  needsManual: boolean = false;
}

/**
 * 是否应尝试打开 USB 设备。
 * @param st      当前退避状态
 * @param nowMs   当前时间
 * @param isOpen  设备是否已打开
 */
export function shouldAttemptUsbOpen(st: UsbAttemptState, nowMs: number,
                                     isOpen: boolean): UsbAttemptDecision {
  const d = new UsbAttemptDecision();
  if (isOpen) {
    d.reason = 'already open';
    return d;
  }
  if (!st.auto) {
    d.reason = 'auto retry disabled';
    d.needsManual = true;
    return d;
  }
  if (nowMs - st.lastAttemptMs < USB_RETRY_MS) {
    d.reason = 'backoff';
    return d;
  }
  d.attempt = true;
  d.reason = 'due';
  return d;
}

/** 记录一次失败：被拒达到上限就关闭自动重试 */
export function noteOpenFailure(st: UsbAttemptState, denied: boolean, nowMs: number): void {
  st.lastAttemptMs = nowMs;
  if (denied) {
    st.denied = st.denied + 1;
    if (st.denied >= USB_MAX_DENIED) {
      st.auto = false;
    }
  }
}

/** 记录一次成功：清空退避状态 */
export function noteOpenSuccess(st: UsbAttemptState): void {
  st.denied = 0;
  st.auto = true;
}

/** 用户手动点「连接屏幕」：重新允许自动重试 */
export function armManualRetry(st: UsbAttemptState): void {
  st.denied = 0;
  st.auto = true;
}
