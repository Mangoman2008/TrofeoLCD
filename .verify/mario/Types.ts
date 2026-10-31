/**
 * 超级玛丽 - 通用类型与游戏常量
 */

// 瓦片尺寸（vp）
export const TILE: number = 32;
// 物理常量
export const GRAVITY: number = 2400;          // 重力加速度 vp/s^2
export const MAX_FALL: number = 1000;         // 最大下落速度
export const JUMP_VEL: number = 720;          // 起跳速度
export const JUMP_CUT: number = 240;          // 松开跳跃键后的截断速度
// ★ 2026-10-21 按用户要求调回接近原版（注意本工程 TILE=32）：
//   原来奔跑时大跳水平距离 = 0.6s × 330 = 198px = **6.2 格**，比原版(~5 格)远。
//   现在 260px/s → 156px = 4.9 格；行走 150 → 90px = 2.8 格。
export const WALK_SPEED: number = 150;        // 行走速度
export const RUN_SPEED: number = 260;         // 奔跑速度
export const ACCEL: number = 2600;            // 地面加速度
export const AIR_ACCEL: number = 1700;        // 空中加速度
export const FRICTION: number = 2800;         // 地面摩擦
export const COYOTE_TIME: number = 0.09;      // 土狼时间（离开平台后仍可起跳）
export const JUMP_BUFFER_TIME: number = 0.12; // 跳跃缓冲（提前按跳跃键）
export const MAX_JUMPS: number = 2;           // 最大连跳次数（1 次地面跳 + 1 次空中二段跳）
export const ENEMY_SPEED: number = 42;        // 敌人移动速度
// 尺寸
export const PLAYER_W: number = 26;
export const PLAYER_H: number = 32;
export const GOOMBA_W: number = 30;
export const GOOMBA_H: number = 28;
export const LEVEL_ROWS: number = 15;         // 关卡行数
export const MAX_LIVES: number = 99;

/**
 * 瓦片类型
 */
export const TileId = {
  EMPTY: 0,
  GROUND: 1,
  STONE: 2,
  BRICK: 3,
  QUESTION: 4,
  USED: 5,
  PIPE_TL: 6,
  PIPE_TR: 7,
  PIPE_L: 8,
  PIPE_R: 9,
  COIN: 10,
  QUESTION_POWER: 11,
} as const;
export type TileId = typeof TileId[keyof typeof TileId];

/**
 * 游戏画面状态
 */
export const GameScreen = {
  TITLE: 0,
  CHARACTER_SELECT: 1,
  PLAYING: 2,
  PAUSED: 3,
  GAME_OVER: 4,
  WIN: 5,
} as const;
export type GameScreen = typeof GameScreen[keyof typeof GameScreen];

/**
 * 玩家操作动作
 */
export const GameAction = {
  LEFT: 0,
  RIGHT: 1,
  JUMP: 2,
  RUN: 3,
  START: 4,
  PAUSE: 5,
  DOWN: 6,
} as const;
export type GameAction = typeof GameAction[keyof typeof GameAction];

/**
 * 关卡主题
 */
export const ThemeId = {
  OVERWORLD: 0,
  UNDERGROUND: 1,
  UNDERWATER: 2,
  CASTLE: 3,
} as const;
export type ThemeId = typeof ThemeId[keyof typeof ThemeId];

/**
 * 可选角色
 */
export const CharacterId = {
  MARIO: 0,
  PEACH: 1,
  BOWSER: 2,
} as const;
export type CharacterId = typeof CharacterId[keyof typeof CharacterId];

/**
 * 角色名称
 */
export const CHARACTER_NAMES: string[] = ['马里奥', '公主', '酷霸王'];

/**
 * 角色属性：[移动速度倍率, 跳跃倍率]
 */
export const CHARACTER_STATS: number[][] = [
  [1.0, 1.0],   // 马里奥：均衡
  [0.92, 1.12], // 公主：稍慢但跳更高
  [1.12, 0.85]  // 酷霸王：更快但跳得矮
];

/**
 * 总关卡数：4 大世界 × 4 关
 */
export const TOTAL_LEVELS: number = 16;

/**
 * 背景云朵
 */
export interface CloudPos {
  x: number;
  y: number;
  s: number;
}

/**
 * 背景山丘
 */
export interface HillPos {
  x: number;
  s: number;
}
