/**
 * Toasts.ets —— 事件弹窗（屏上大字提示 3~4 秒）与专注计时
 *
 * 两个都是"随时间变化的纯策略"，所以放在同一个文件里离线自检：
 *   ToastPolicy：从"上一帧 → 这一帧"的变化里决定要不要弹一条、弹什么
 *   FocusTimer ：从 busy/idle 的变化里累计"已专注多久 / 完成几个番茄"
 */
import type { Telemetry } from './Types';

/** 一条弹窗 */
export interface Toast {
  text: string;
  /** ok=绿色完成 · warn=橙色提醒 · err=红色错误 · info=蓝色信息 */
  kind: string;
  until: number;
}

export class ToastPolicy {
  /** 弹窗停留时长 */
  static readonly HOLD_MS: number = 4000;

  /**
   * 判断这次变化要不要弹窗。prev 为 null 表示"应用刚启动"（不弹，避免开机刷屏）。
   * 规则（都要求真变化，不是每帧都弹）：
   *   · 上一帧 busy → 这一帧 idle/waiting：任务告一段落 → 「完成」
   *   · 错误文本出现/变化                    → 「错误」红色
   *   · 待办完成数增加                        → 「待办 ✓ n/m」
   *   · 待办总数增加                          → 「新增待办 n 条」
   *   · 余额从 >=5 掉到 <5                    → 「余额不足」
   *   · 当前工具变化（仅在 busy 且距上次弹窗 >8s）→ 「运行 <工具>」
   */
  static pick(prev: Telemetry | null, cur: Telemetry, now: number,
              lastTool: string, lastToastAt: number): Toast | null {
    const mk = (text: string, kind: string): Toast => ({ text, kind, until: now + ToastPolicy.HOLD_MS });

    if (prev !== null) {
      const wasBusy = prev.agent !== undefined && prev.agent.state === 'busy';
      const isIdle = cur.agent === undefined || cur.agent.state !== 'busy';
      if (wasBusy && isIdle) {
        return mk('任务完成', 'ok');
      }

      const prevErr = prev.balance !== undefined && prev.balance.error !== undefined
        ? prev.balance.error : '';
      const curErr = cur.balance !== undefined && cur.balance.error !== undefined
        ? cur.balance.error : '';
      if (curErr.length > 0 && curErr !== prevErr) {
        return mk(`取数失败：${curErr}`, 'err');
      }

      const pd = ToastPolicy.done(prev);
      const cd = ToastPolicy.done(cur);
      if (cd > pd) {
        return mk(`待办完成 ${cd}/${ToastPolicy.total(cur)}`, 'ok');
      }
      if (ToastPolicy.total(cur) > ToastPolicy.total(prev)) {
        return mk(`新增待办 ${ToastPolicy.total(cur)} 条`, 'info');
      }

      const pb = prev.balance !== undefined && prev.balance.total !== undefined ? prev.balance.total : -1;
      const cb = cur.balance !== undefined && cur.balance.total !== undefined ? cur.balance.total : -1;
      if (pb >= 5 && cb >= 0 && cb < 5) {
        return mk(`余额不足 ${cb.toFixed(2)}`, 'err');
      }

      const tool = cur.agent !== undefined && cur.agent.tool !== undefined ? cur.agent.tool : '';
      if (tool.length > 0 && tool !== lastTool && now - lastToastAt > 8000) {
        return mk(`运行 ${tool}`, 'info');
      }
    }
    return null;
  }

  private static done(t: Telemetry): number {
    const arr = t.todos;
    if (arr === undefined) {
      return 0;
    }
    let n = 0;
    for (const x of arr) {
      if (x.status === 'completed') {
        n++;
      }
    }
    return n;
  }

  private static total(t: Telemetry): number {
    return t.todos === undefined ? 0 : t.todos.length;
  }
}

/** 专注计时：busy 期间累计时长，切成 idle 记一个"番茄"（时长达到阈值才算） */
export class FocusTimer {
  /** 一个番茄的最短时长（分钟），低于这个数不算完成 */
  static readonly MIN_MIN: number = 10;

  /** 当前这段专注的开始时间（0 = 没有在专注） */
  startedAt: number = 0;
  /** 当前这段已经累计的毫秒（暂停时保留） */
  private accumulated: number = 0;
  /** 今天完成的番茄数 */
  pomodoros: number = 0;

  /** 走一个 tick。返回是否发生了变化（用于决定要不要重绘） */
  tick(now: number, busy: boolean): boolean {
    if (busy) {
      if (this.startedAt === 0) {
        this.startedAt = now;
        return true;
      }
      return false;
    }
    if (this.startedAt !== 0) {
      const focusedMs = now - this.startedAt;
      const back = this.accumulated;
      this.accumulated = 0;
      this.startedAt = 0;
      if (focusedMs >= FocusTimer.MIN_MIN * 60000) {
        this.pomodoros++;
      }
      return focusedMs !== 0 || back !== 0;
    }
    return false;
  }

  /** 当前正在专注的时长（毫秒）；没在专注返回 0 */
  elapsedMs(now: number): number {
    if (this.startedAt === 0) {
      return 0;
    }
    return Math.max(0, now - this.startedAt);
  }

  /** 显示用：mm:ss（超过一小时显示 h:mm:ss） */
  static fmt(ms: number): string {
    const s = Math.floor(ms / 1000);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const ss = s % 60;
    const p2 = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return h > 0 ? `${h}:${p2(m)}:${p2(ss)}` : `${p2(m)}:${p2(ss)}`;
  }
}
