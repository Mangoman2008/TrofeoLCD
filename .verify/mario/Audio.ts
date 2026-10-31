/**
 * Audio.ets —— 声音管理（TrofeoLCD 移植版：**空实现**）
 *
 * 原项目用 media/fileIo/resourceManager 播 NES 音效；这块副屏的用途是
 * 状态屏 + 屏保，而且音频播放要额外权限与文件缓存目录 —— 演示版不需要声音。
 *
 * 保留与原来相同的类名与**被 Game 用到的全部方法**（setMuted / play / release /
 * preload），所以 Game.ets 一行都不用改。
 */

export class SoundManager {
  private muted: boolean = true;

  /** 兼容原签名：cacheDir 与 resourceManager 都不再使用 */
  constructor(cacheDir: string = '', resMgr?: Object) {
    this.muted = true;
  }

  setMuted(m: boolean): void {
    this.muted = m;
  }

  isMuted(): boolean {
    return this.muted;
  }

  /** 预加载：空实现 */
  preload(): void {
  }

  /** 播放某个音效：空实现（不需要声音） */
  play(name: string): void {
  }

  /** 释放资源：空实现 */
  release(): void {
  }
}
