/**
 * Extras.ets —— 渲染层需要的"非遥测"附加数据
 *
 * 遥测（Telemetry）是桥发来的业务数据；这里放的是**应用侧自己算出来的**东西：
 * 历史曲线、当前弹窗、专注计时、背景图、一句话摘要。
 *
 * 单独一个文件是为了避免循环依赖：Dashboard / ThemeDiag / ThemeWall / LcdService
 * 都要用这个类型，但它不属于其中任何一个。
 */
import type { History } from './History.ts';
import type { FocusTimer, Toast } from './Toasts.ts';

export interface RenderExtras {
  /** 历史采样（CPU/内存/token 速率/余额曲线） */
  history: History;
  /** 当前弹窗（null = 不显示） */
  toast: Toast | null;
  /** 专注计时（番茄钟） */
  focus: FocusTimer;
  /** 背景图（桥端 --bg 提供的图；null = 用主题自带渐变） */
  bg: PixelMap | null;
  /** 一句话摘要（空串 = 没有） */
  summary: string;
  /**
   * DSH 面板底部"三行滚动留言条"的内容（旧→新）。
   * 由 LcdService 维护：每当摘要/最后一句发生变化就 push 一条，最多保留若干条。
   * 渲染时取最后 3 条，从上到下由暗到亮，新内容从下方"滚上来"。
   */
  feed: string[];
  /** 最近一次 push 的时间戳（ms），用于做上滚动画 */
  feedAt: number;
}
