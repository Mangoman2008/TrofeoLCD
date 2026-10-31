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
export enum TileId {
  EMPTY = 0,
  GROUND = 1,        // 地面（草地）
  STONE = 2,         // 石块（阶梯）
  BRICK = 3,         // 砖块（可顶碎）
  QUESTION = 4,      // 问号块（出金币）
  USED = 5,          // 已使用的问号块
  PIPE_TL = 6,       // 管道左上
  PIPE_TR = 7,       // 管道右上
  PIPE_L = 8,        // 管道左身
  PIPE_R = 9,        // 管道右身
  COIN = 10,         // 漂浮金币（可收集）
  QUESTION_POWER = 11 // 问号块（出蘑菇，1UP）
}

/**
 * 游戏画面状态
 */
export enum GameScreen {
  TITLE = 0,          // 标题
  CHARACTER_SELECT = 1, // 人物选择
  PLAYING = 2,        // 游戏中
  PAUSED = 3,         // 暂停
  GAME_OVER = 4,      // 游戏结束
  WIN = 5             // 通关
}

/**
 * 玩家操作动作
 */
export enum GameAction {
  LEFT = 0,
  RIGHT = 1,
  JUMP = 2,
  RUN = 3,
  START = 4,  // 开始 / 确认
  PAUSE = 5,  // 暂停
  DOWN = 6    // 下蹲 / 进水管
}

/**
 * 关卡主题
 */
export enum ThemeId {
  OVERWORLD = 0,    // 地面世界
  UNDERGROUND = 1,  // 地下世界
  UNDERWATER = 2,   // 水下世界
  CASTLE = 3        // 城堡
}

/**
 * 可选角色
 */
export enum CharacterId {
  MARIO = 0,
  PEACH = 1,
  BOWSER = 2
}

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
