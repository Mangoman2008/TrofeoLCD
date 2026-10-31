import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x544C; // 'TL'
const TAG: string = 'TrofeoLCD';

export class Logger {
  static i(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  static w(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  }

  static e(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }

  /**
   * 把任意异常安全地转成一行文本。
   *
   * ★ 为什么不能直接用 `JSON.stringify(e)`（2026-10-16 审计）：
   *   - 异常对象可能含**循环引用** → `JSON.stringify` 会**抛出 TypeError**；
   *   - 而它常被用在 `catch` 里，于是"兜底代码自己再抛一次"，
   *     调用方后续的恢复动作（重排定时器、回滚资源）全部执行不到。
   *   - 帧循环就是这么写的：catch 里 stringify 一旦抛，`setTimeout(tick, 1000)`
   *     永远走不到 → 帧循环**永久停止且无法自愈**（屏从此不动，且没有任何报错）。
   *
   * 优先取 Error.message；否则尝试 JSON；再不行退回 String()。
   * 全程 try/catch，**保证不抛**。
   */
  static safe(e: Object): string {
    if (e === null || e === undefined) {
      return '(空)';
    }
    const anyE = e as Record<string, Object>;
    const msg = anyE['message'];
    if (typeof msg === 'string' && (msg as string).length > 0) {
      const code = anyE['code'];
      return typeof code === 'number' ? `${code as number} ${msg as string}` : (msg as string);
    }
    try {
      const j = JSON.stringify(e);
      if (typeof j === 'string' && j.length > 0) {
        return j.length > 300 ? `${j.substring(0, 300)}…` : j;
      }
    } catch (e2) {
      // 循环引用等：忽略，走下面的 String()
    }
    try {
      return String(e);
    } catch (e3) {
      return '(无法序列化的异常)';
    }
  }
}
