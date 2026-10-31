// Logger.ts — 桩：把日志收集起来供测试断言
export const logs: string[] = [];
export class Logger {
  static i(m: string): void { logs.push('I ' + m); }
  static w(m: string): void { logs.push('W ' + m); }
  static e(m: string): void { logs.push('E ' + m); }
}
