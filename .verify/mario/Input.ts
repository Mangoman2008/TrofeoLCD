/**
 * Input.ets —— 输入管理（TrofeoLCD 移植版）
 *
 * 原项目用真实键盘/触摸；这块 USB 副屏是**输出-only**，没有输入设备。
 * 所以保留与原来**完全相同的对外接口**（virtualDown/virtualUp/isHeld/isPressed/
 * endFrame/releaseAll），由马里奥演示版自己"按"这些虚拟键 —— 也就是自动驾驶。
 *
 * ★ 刻意去掉了原来的 `KeyCode` / `@kit.InputKit` 依赖：副屏永远收不到键盘事件，
 *   留着只会多一个无用的系统 kit 依赖。
 */

import { GameAction } from './Types.ts';

export class InputManager {
  /** 当前按住的（持续） */
  private held: Set<GameAction> = new Set<GameAction>();
  /** 本帧刚按下的（边沿） */
  private pressed: Set<GameAction> = new Set<GameAction>();

  constructor() {
    this.held = new Set<GameAction>();
    this.pressed = new Set<GameAction>();
  }

  /** 按下（相当于手指落下/键按下） */
  virtualDown(action: GameAction): void {
    if (!this.held.has(action)) {
      this.pressed.add(action);
    }
    this.held.add(action);
  }

  /** 松开 */
  virtualUp(action: GameAction): void {
    this.held.delete(action);
  }

  /** 是否持续按住 */
  isHeld(action: GameAction): boolean {
    return this.held.has(action);
  }

  /** 是否**本帧刚**按下（边沿触发） */
  isPressed(action: GameAction): boolean {
    return this.pressed.has(action);
  }

  /** 每帧末尾清空边沿状态（必须由驱动方调用） */
  endFrame(): void {
    this.pressed.clear();
  }

  /** 全部松开（暂停/切换界面时用） */
  releaseAll(): void {
    this.held.clear();
    this.pressed.clear();
  }
}
