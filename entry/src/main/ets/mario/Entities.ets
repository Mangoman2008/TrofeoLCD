import { PLAYER_W, PLAYER_H, GOOMBA_W, GOOMBA_H, ENEMY_SPEED } from './Types';

/**
 * 玩家
 */
export class Player {
  x: number = 0;
  y: number = 0;
  w: number = PLAYER_W;
  h: number = PLAYER_H;
  vx: number = 0;
  vy: number = 0;
  facing: number = 1;      // 1 右，-1 左
  onGround: boolean = false;
  coyote: number = 0;      // 土狼时间
  jumpBuffer: number = 0;  // 跳跃缓冲
  dead: boolean = false;
  invincible: number = 0;  // 无敌时间（重生/缩小保护）
  jumps: number = 0;       // 本段滞空已用跳跃次数（落地清零）
  big: boolean = false;    // 大玛丽状态（吃蘑菇变大）
  character: number = 0;   // 角色（马里奥/公主/酷霸王）
  animT: number = 0;       // 动画计时

  reset(x: number, y: number): void {
    this.x = x;
    this.y = y;
    this.w = PLAYER_W;
    this.h = PLAYER_H;
    this.vx = 0;
    this.vy = 0;
    this.facing = 1;
    this.onGround = false;
    this.coyote = 0;
    this.jumpBuffer = 0;
    this.dead = false;
    this.invincible = 0;
    this.jumps = 0;
    this.big = false;
    this.animT = 0;
  }
}

/**
 * 敌人：板栗仔（Goomba）
 */
export class Goomba {
  x: number = 0;
  y: number = 0;
  w: number = GOOMBA_W;
  h: number = GOOMBA_H;
  vx: number = -ENEMY_SPEED;
  vy: number = 0;
  squashed: boolean = false;
  squashTimer: number = 0;
  dead: boolean = false;
  walkT: number = 0;

  constructor(x: number, y: number, dir: number) {
    this.x = x;
    this.y = y;
    this.vx = dir * ENEMY_SPEED;
  }
}

/**
 * 顶出的金币（可收集）
 */
export class CoinPickup {
  x: number = 0;
  y: number = 0;
  baseY: number = 0;
  vy: number = -640;
  t: number = 0;
  alive: boolean = true;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
    this.baseY = y;
  }
}

/**
 * 蘑菇（1UP）
 */
export class Mushroom {
  x: number = 0;
  y: number = 0;
  w: number = 30;
  h: number = 28;
  vx: number = 70;
  vy: number = 0;
  alive: boolean = true;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

/**
 * 水下敌人：鱼
 */
export class Fish {
  x: number = 0;
  y: number = 0;
  baseY: number = 0;
  w: number = 30;
  h: number = 20;
  vx: number = 55;
  t: number = 0;

  constructor(x: number, y: number, dir: number) {
    this.x = x;
    this.y = y;
    this.baseY = y;
    this.vx = dir * 55;
  }
}

/**
 * 粒子：0 砖块碎片，1 灰尘，2 星光，3 气泡
 */
export class Particle {
  x: number = 0;
  y: number = 0;
  vx: number = 0;
  vy: number = 0;
  size: number = 6;
  kind: number = 0;
  t: number = 0;
  life: number = 0.6;
  grav: number = 0;

  constructor(x: number, y: number, vx: number, vy: number, size: number, kind: number, life: number, grav: number) {
    this.x = x;
    this.y = y;
    this.vx = vx;
    this.vy = vy;
    this.size = size;
    this.kind = kind;
    this.life = life;
    this.grav = grav;
  }
}

/**
 * 飘字（得分提示）
 */
export class Popup {
  x: number = 0;
  y: number = 0;
  text: string = '';
  t: number = 0;
  life: number = 0.9;
  color: string = '#FFFFFF';

  constructor(x: number, y: number, text: string, color: string) {
    this.x = x;
    this.y = y;
    this.text = text;
    this.color = color;
  }
}
