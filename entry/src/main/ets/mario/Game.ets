import { TILE, GRAVITY, MAX_FALL, JUMP_VEL, JUMP_CUT, WALK_SPEED, RUN_SPEED, ACCEL, AIR_ACCEL, FRICTION,
  COYOTE_TIME, JUMP_BUFFER_TIME, MAX_JUMPS, LEVEL_ROWS, MAX_LIVES, TOTAL_LEVELS,
  TileId, GameScreen, GameAction, ThemeId, CloudPos, HillPos,
  CharacterId, CHARACTER_NAMES, CHARACTER_STATS } from './Types';
import { InputManager } from './Input';
import { SoundManager } from './Audio';
import { LevelData, buildLevel, buildBonusRoom, PipeWarp } from './Levels';
import { Player, Goomba, Fish, CoinPickup, Mushroom, Particle, Popup } from './Entities';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x4D42;
const TAG: string = 'MarioGame';

/**
 * 角色配色（沿用上一版的可爱方块风格）
 */
export interface CharColors {
  cap: string;
  capDark: string;
  skin: string;
  hair: string;
  shirt: string;
  body: string;
  shoe: string;
}

const MARIO_COLORS: CharColors = {
  cap: '#E03020', capDark: '#C02018', skin: '#FFC894', hair: '#6B3A1F',
  shirt: '#E03020', body: '#3A5BD0', shoe: '#7A4A1B'
};

const PEACH_COLORS: CharColors = {
  cap: '#FFD700', capDark: '#E8A800', skin: '#FFD9C0', hair: '#F8D060',
  shirt: '#F8A0C0', body: '#F8A0C0', shoe: '#E870A0'
};

const BOWSER_COLORS: CharColors = {
  cap: '#1E8A30', capDark: '#146020', skin: '#F8D878', hair: '#E83000',
  shirt: '#E83000', body: '#1E8A30', shoe: '#F8F0E0'
};

function charColorsOf(ch: number): CharColors {
  if (ch === CharacterId.PEACH) {
    return PEACH_COLORS;
  }
  if (ch === CharacterId.BOWSER) {
    return BOWSER_COLORS;
  }
  return MARIO_COLORS;
}

/**
 * 超级玛丽游戏引擎：状态机、物理、碰撞、敌人 AI、计分与渲染。
 */
/** hazardAhead() 的返回值 */
export const HAZARD_PIT: number = 1;
export const HAZARD_WALL: number = 2;
export const HAZARD_ENEMY: number = 3;

export class SuperMarioGame {
  /**
   * 演示模式：**无限命**（本移植版新增）。
   * true 时死亡不会扣命、也不会进 GAME_OVER，而是立刻在检查点重生，
   * 且**分数不清零** —— 副屏上的屏保不该老是"游戏结束"重头再来。
   */
  demoInfiniteLives: boolean = false;

  input: InputManager;
  sound: SoundManager;
  level: LevelData;
  player: Player = new Player();
  goombas: Goomba[] = [];
  fish: Fish[] = [];
  pickups: CoinPickup[] = [];
  mushrooms: Mushroom[] = [];
  particles: Particle[] = [];
  popups: Popup[] = [];
  clouds: CloudPos[] = [];
  hills: HillPos[] = [];
  cameraX: number = 0;
  cameraY: number = 0;
  screenW: number = 0;
  screenH: number = 0;
  screen: GameScreen = GameScreen.TITLE;
  score: number = 0;
  coinCount: number = 0;
  lives: number = 3;
  levelTime: number = 300;
  levelIndex: number = 0;
  respawnX: number = 0;
  respawnY: number = 0;
  checkpointIdx: number = 0;
  bumpTiles: Map<number, number> = new Map();
  globalT: number = 0;
  charSel: number = 0;
  bubbleT: number = 0;
  // 奖励关（水管）状态
  subActive: boolean = false;
  subLevel: LevelData | null = null;
  parentLevel: LevelData | null = null;
  returnCol: number = 0;
  savedGoombas: Goomba[] = [];
  savedFish: Fish[] = [];
  savedPickups: CoinPickup[] = [];
  savedMushrooms: Mushroom[] = [];
  savedParticles: Particle[] = [];
  savedPopups: Popup[] = [];

  constructor(input: InputManager, sound: SoundManager, w: number, h: number) {
    this.input = input;
    this.sound = sound;
    this.screenW = w;
    this.screenH = h;
    this.level = buildLevel(0);
    this.respawnX = this.level.spawnX;
    this.respawnY = this.level.spawnY;
    this.makeBackground();
  }

  // ============ 对外接口 ============

  /**
   * 演示版自动驾驶用：**前方是否危险**（该跳了）。
   * 本移植版新增 —— 副屏没有输入设备，只能靠游戏自己判断什么时候跳。
   *
   * 判据三条（任一成立就跳）：
   *   ① 前方 14px 处脚下没有实心方块 → 是坑
   *   ② 前方 14px 处身体高度是实心 → 是墙/水管
   *   ③ 前方 56px 内有板栗仔，且高度相近
   */
  hazardAhead(): number {
    if (this.player === undefined || this.player === null) {
      return 0;
    }
    const p = this.player;
    // 坑/墙提前 44px（≈3 格）；敌人提前 26px —— 更近才起跳，落点正好在它头上（踩）
    const colPit: number = Math.floor((p.x + p.w + 44) / TILE);
    const colWall: number = Math.floor((p.x + p.w + 20) / TILE);
    const rowFoot: number = Math.floor((p.y + p.h + 2) / TILE);
    // ① 脚下没有地 → 坑
    let ground: boolean = false;
    for (let r = rowFoot; r <= rowFoot + 1; r++) {
      if (SuperMarioGame.solidAt(this.level.tileAt(colPit, r))) {
        ground = true;
        break;
      }
    }
    if (!ground) {
      return HAZARD_PIT;
    }
    // ② 身体高度处是实心 → 墙/水管
    const rowMid: number = Math.floor((p.y + p.h * 0.5) / TILE);
    if (SuperMarioGame.solidAt(this.level.tileAt(colWall, rowMid))) {
      return HAZARD_WALL;
    }
    // ③ 前方有敌人 → **踩它**
    for (let i = 0; i < this.goombas.length; i++) {
      const g = this.goombas[i];
      const dx: number = g.x - p.x;
      if (dx > 0 && dx < 26 && Math.abs(g.y - p.y) < 48) {
        return HAZARD_ENEMY;
      }
    }
    return 0;
  }

  /**
   * 演示自动驾驶传感器（移植版新增）：一次给全，省得调用方反复问。
   * @returns [onGround(0/1), 前方地面剩余px, 前方坑宽(格), 最近正前方敌人距离px, 敌人与我在同一高度(0/1)]
   */
  demoSense(): number[] {
    const p = this.player;
    const rowFoot: number = Math.floor((p.y + p.h + 2) / TILE);
    const startCol: number = Math.floor((p.x + p.w) / TILE);
    // 前方连续有多少列还有地面
    let groundCols: number = 0;
    while (groundCols < 6) {
      const c: number = startCol + groundCols;
      let solid: boolean = false;
      for (let r = rowFoot; r <= rowFoot + 1; r++) {
        if (SuperMarioGame.solidAt(this.level.tileAt(c, r))) {
          solid = true;
          break;
        }
      }
      if (!solid) {
        break;
      }
      groundCols++;
    }
    const pitDist: number = groundCols * TILE - ((p.x + p.w) % TILE);
    // 坑有多宽（连续没有地的列数）
    let gapCols: number = 0;
    if (groundCols < 6) {
      let c2: number = startCol + groundCols;
      while (gapCols < 8) {
        let solid2: boolean = false;
        for (let r = rowFoot; r <= rowFoot + 2; r++) {
          if (SuperMarioGame.solidAt(this.level.tileAt(c2 + gapCols, r))) {
            solid2 = true;
            break;
          }
        }
        if (solid2) {
          break;
        }
        gapCols++;
      }
    }
    // 正前方的敌人
    let ed: number = 9999;
    let sameRow: number = 0;
    for (let i = 0; i < this.goombas.length; i++) {
      const g = this.goombas[i];
      const dx: number = g.x - p.x;
      if (dx > -6 && dx < 140 && dx < ed) {
        ed = dx;
        sameRow = (Math.abs(g.y - p.y) < 44) ? 1 : 0;
      }
    }
    // 前方墙壁（水管/砖块/台阶）：身体高度上第一处实心离我多少 px
    let wallDist: number = 9999;
    const rowMid2: number = Math.floor((p.y + p.h * 0.45) / TILE);
    const rowLow: number = Math.floor((p.y + p.h - 4) / TILE);
    for (let c = startCol; c <= startCol + 3; c++) {
      let solid3: boolean = false;
      for (let r = rowMid2; r <= rowLow; r++) {
        if (SuperMarioGame.solidAt(this.level.tileAt(c, r))) {
          solid3 = true;
          break;
        }
      }
      if (solid3) {
        wallDist = c * TILE - (p.x + p.w);
        break;
      }
    }
    return [p.onGround ? 1 : 0, pitDist, gapCols, ed, sameRow, wallDist];
  }

  /**
   * 诊断用：打印玩家周围的地形（3 列 × 5 行 tile id）。
   * 用来定位"卡住"到底是被什么挡住的。
   */
  terrainInfo(): string {
    const p = this.player;
    const c0: number = Math.floor(p.x / TILE);
    const r0: number = Math.floor(p.y / TILE);
    let out: string = '';
    for (let r = r0 - 1; r <= r0 + 3; r++) {
      out += `r${r}:`;
      for (let c = c0 - 1; c <= c0 + 3; c++) {
        out += ` ${this.level.tileAt(c, r)}`;
      }
      out += '|';
    }
    return out;
  }

  /** 当前关卡是不是水下关（自动驾驶要区别对待） */
  isWaterLevel(): boolean {
    return this.level.theme === ThemeId.UNDERWATER;
  }

  /** 诊断用：把传感器值拼成字符串 */
  senseInfo(): string {
    const s: number[] = this.demoSense();
    return `onG=${s[0]} pit=${s[1]} gap=${s[2]} enemy=${s[3]} same=${s[4]} wall=${s.length > 5 ? s[5] : -1}`;
  }

  /** 兼容旧调用：前方有没有危险 */
  dangerAhead(): boolean {
    return this.hazardAhead() !== 0;
  }

  /** 玩家当前矩形是否与实心 tile 重叠（演示助推用） */
  static playerHitsSolid(level: LevelData, p: Player): boolean {
    const c0: number = Math.floor(p.x / TILE);
    const c1: number = Math.floor((p.x + p.w - 1) / TILE);
    const r0: number = Math.floor(p.y / TILE);
    const r1: number = Math.floor((p.y + p.h - 1) / TILE);
    for (let c = c0; c <= c1; c++) {
      for (let r = r0; r <= r1; r++) {
        if (level.solidAt(c, r)) {
          return true;
        }
      }
    }
    return false;
  }

  /** 该 tile 是不是实心（坑/墙判定用） */
  private static solidAt(t: number): boolean {
    return t === TileId.GROUND || t === TileId.STONE || t === TileId.BRICK
      || t === TileId.QUESTION || t === TileId.USED
      || t === TileId.PIPE_TL || t === TileId.PIPE_TR
      || t === TileId.PIPE_L || t === TileId.PIPE_R
      || t === TileId.QUESTION_POWER;
  }

  /** 诊断用：玩家世界坐标（本移植版新增，只读） */
  playerPos(): number[] {
    return [this.player.x, this.player.y, this.player.w, this.player.h, this.cameraX,
      this.cameraY, this.dbgDraw, this.dbgSkip, this.player.invincible, this.globalT,
      this.score, this.lives, this.coinCount, this.goombas.length,
      this.demoDeaths, this.lastDeathX, (this.lastDeathCause === 'PIT') ? 1 : 0, this.demoRescues,
      this.levelIndex, this.demoAssists];
  }

  getScreenName(): string {
    switch (this.screen) {
      case GameScreen.TITLE:
        return 'title';
      case GameScreen.CHARACTER_SELECT:
        return 'charselect';
      case GameScreen.PLAYING:
        return 'playing';
      case GameScreen.PAUSED:
        return 'paused';
      case GameScreen.GAME_OVER:
        return 'over';
      case GameScreen.WIN:
        return 'win';
    }
    return 'title';
  }

  setMuted(m: boolean): void {
    this.sound.setMuted(m);
  }

  togglePause(): void {
    if (this.screen === GameScreen.PLAYING) {
      this.screen = GameScreen.PAUSED;
      this.input.releaseAll();
    } else if (this.screen === GameScreen.PAUSED) {
      this.screen = GameScreen.PLAYING;
    }
  }

  pauseIfPlaying(): void {
    if (this.screen === GameScreen.PLAYING) {
      this.screen = GameScreen.PAUSED;
      this.input.releaseAll();
    }
  }

  onCanvasTouch(): void {
    if (this.screen === GameScreen.TITLE) {
      this.screen = GameScreen.CHARACTER_SELECT;
      this.sound.play('coin');
    } else if (this.screen === GameScreen.CHARACTER_SELECT) {
      this.startGame(this.charSel);
    } else if (this.screen === GameScreen.GAME_OVER) {
      this.startGame(this.player.character);
    } else if (this.screen === GameScreen.WIN) {
      this.nextLevelOrTitle();
    }
  }

  releaseAudio(): void {
    this.sound.release();
  }

  // ============ 状态切换 ============

  private startGame(character: number): void {
    this.score = 0;
    this.coinCount = 0;
    this.lives = 3;
    this.player.character = character;
    this.levelIndex = 0;
    this.startLevel(0);
  }

  private nextLevelOrTitle(): void {
    if (this.levelIndex < TOTAL_LEVELS - 1) {
      this.startLevel(this.levelIndex + 1);
    } else {
      // 通关全部 4 大世界
      this.screen = GameScreen.TITLE;
    }
  }

  private startLevel(index: number): void {
    this.levelIndex = index;
    this.level = buildLevel(index);
    this.makeBackground();
    this.levelTime = 300;
    this.checkpointIdx = 0;
    this.respawnX = this.level.spawnX;
    this.respawnY = this.level.spawnY;
    this.subActive = false;
    this.subLevel = null;
    this.parentLevel = null;
    this.spawnEnemies();
    this.player.reset(this.level.spawnX, this.level.spawnY);
    this.player.invincible = 1.0;
    // ★ 换关必须重置这些演示用计数：
    //   否则 stuckBestX 还留着上一关的推进位置（例如 3849），
    //   新关一开始就被判"卡住" → 每 8 秒跳一关（实测踩到）。
    this.progressBestX = 0;
    this.rescuesSinceProgress = 0;
    this.assistsSinceProgress = 0;
    this.lastSafeX = 0;
    this.pickups = [];
    this.mushrooms = [];
    this.particles = [];
    this.popups = [];
    this.bumpTiles.clear();
    this.cameraX = Math.max(0, this.player.x - this.screenW * 0.38);
    this.cameraY = Math.max(0, this.player.y - this.screenH * 0.55);
    this.screen = GameScreen.PLAYING;
  }

  private spawnEnemies(): void {
    this.goombas = [];
    this.fish = [];
    const isWater = this.level.theme === ThemeId.UNDERWATER;
    for (let i = 0; i < this.level.enemySpawns.length; i++) {
      const sp = this.level.enemySpawns[i];
      const dir = (i % 2 === 0) ? -1 : 1;
      if (isWater) {
        const y = (sp.row + 1) * TILE - 30 - (i % 3) * 46;
        this.fish.push(new Fish(sp.col * TILE, y, dir));
      } else {
        this.goombas.push(new Goomba(sp.col * TILE, (sp.row + 1) * TILE - 28, dir));
      }
    }
  }

  private respawnPlayer(): void {
    if (this.demoInfiniteLives) {
      // 演示模式：不扣命、不进 GAME_OVER；分数保留，立刻重生
      this.lives = 3;
    } else {
      this.lives--;
      if (this.lives < 0) {
        this.screen = GameScreen.GAME_OVER;
        this.sound.play('gameover');
        return;
      }
    }
    const cpX = (this.checkpointIdx > 0) ? this.level.checkpoints[this.checkpointIdx - 1] : this.level.spawnX;
    this.respawnX = cpX;
    this.respawnY = this.level.spawnY;
    this.player.reset(this.respawnX, this.respawnY);
    this.player.invincible = 1.5;
    this.levelTime = 300;
    this.spawnEnemies();
    this.pickups = [];
    this.mushrooms = [];
    this.particles = [];
    this.popups = [];
    this.cameraX = Math.max(0, this.player.x - this.screenW * 0.38);
  }

  private makeBackground(): void {
    this.clouds = [];
    this.hills = [];
    const w = this.level.width();
    let x = 60;
    while (x < w - 80) {
      this.clouds.push({ x: x, y: 50 + (x % 3) * 22, s: 0.8 + (x % 5) * 0.15 });
      x += 210 + (x % 4) * 55;
    }
    x = 120;
    while (x < w - 120) {
      this.hills.push({ x: x, s: 1.0 + (x % 4) * 0.25 });
      x += 260 + (x % 5) * 60;
    }
  }

  // ============ 主循环 ============

  update(dt: number): void {
    this.globalT += dt;
    switch (this.screen) {
      case GameScreen.TITLE:
        this.updateTitle();
        break;
      case GameScreen.CHARACTER_SELECT:
        this.updateCharSelect();
        break;
      case GameScreen.PLAYING:
        this.updatePlaying(dt);
        break;
      case GameScreen.PAUSED:
        this.updatePaused();
        break;
      case GameScreen.GAME_OVER:
        this.updateOver();
        break;
      case GameScreen.WIN:
        this.updateWin();
        break;
    }
  }

  private updateTitle(): void {
    if (this.input.isPressed(GameAction.START)) {
      this.screen = GameScreen.CHARACTER_SELECT;
      this.sound.play('coin');
    }
  }

  private updateCharSelect(): void {
    if (this.input.isPressed(GameAction.LEFT)) {
      this.charSel = (this.charSel + 2) % 3;
      this.sound.play('coin');
    }
    if (this.input.isPressed(GameAction.RIGHT)) {
      this.charSel = (this.charSel + 1) % 3;
      this.sound.play('coin');
    }
    if (this.input.isPressed(GameAction.START) || this.input.isPressed(GameAction.JUMP)) {
      this.startGame(this.charSel);
    }
  }

  private updatePaused(): void {
    if (this.input.isPressed(GameAction.START) || this.input.isPressed(GameAction.PAUSE)) {
      this.screen = GameScreen.PLAYING;
    }
  }

  private updateOver(): void {
    if (this.input.isPressed(GameAction.START)) {
      this.startGame(this.player.character);
    }
  }

  private updateWin(): void {
    if (this.input.isPressed(GameAction.START)) {
      this.nextLevelOrTitle();
    }
  }

  private updatePlaying(dt: number): void {
    this.updateBumps(dt);
    this.levelTime -= dt;
    if (this.levelTime <= 0) {
      this.levelTime = 0;
      this.killPlayer();
    }

    if (this.player.dead) {
      this.updateDeath(dt);
      return;
    }

    if (this.input.isPressed(GameAction.PAUSE)) {
      this.screen = GameScreen.PAUSED;
      this.input.releaseAll();
      return;
    }

    // 进水管
    if (this.input.isPressed(GameAction.DOWN)) {
      if (this.tryEnterPipe()) {
        return;
      }
    }

    const isWater = this.level.theme === ThemeId.UNDERWATER;
    const stats = CHARACTER_STATS[this.player.character];
    const speedMul = stats[0];
    const jumpMul = stats[1];

    this.player.animT += dt;
    this.player.coyote = this.player.onGround ? COYOTE_TIME : Math.max(0, this.player.coyote - dt);
    // 跳跃缓冲：仅在“新按下”时刷新
    if (this.input.isPressed(GameAction.JUMP)) {
      this.player.jumpBuffer = JUMP_BUFFER_TIME;
    } else {
      this.player.jumpBuffer = Math.max(0, this.player.jumpBuffer - dt);
    }

    const left = this.input.isHeld(GameAction.LEFT);
    const right = this.input.isHeld(GameAction.RIGHT);
    const run = this.input.isHeld(GameAction.RUN);

    // 水平移动
    let target: number = 0;
    if (left && !right) {
      target = -1;
    } else if (right && !left) {
      target = 1;
    }
    const baseSpeed = run ? RUN_SPEED : WALK_SPEED;
    const maxSpeed = baseSpeed * speedMul * (isWater ? 0.85 : 1.0);
    if (target !== 0) {
      this.player.facing = target;
      const acc = (this.player.onGround || isWater) ? ACCEL : AIR_ACCEL;
      this.player.vx += target * acc * dt;
      if (target > 0 && this.player.vx > maxSpeed) {
        this.player.vx = maxSpeed;
      }
      if (target < 0 && this.player.vx < -maxSpeed) {
        this.player.vx = -maxSpeed;
      }
    } else {
      const f = (this.player.onGround || isWater) ? FRICTION : AIR_ACCEL * 0.5;
      if (this.player.vx > 0) {
        this.player.vx = Math.max(0, this.player.vx - f * dt);
      } else if (this.player.vx < 0) {
        this.player.vx = Math.min(0, this.player.vx + f * dt);
      }
    }

    if (isWater) {
      // 水下游泳：按住跳跃向上游
      this.player.vy += 700 * dt;
      if (this.input.isHeld(GameAction.JUMP)) {
        this.player.vy -= 1500 * dt;
      }
      this.player.vy = Math.max(-240, Math.min(240, this.player.vy));
      if (this.input.isPressed(GameAction.JUMP)) {
        this.sound.play('jump');
        this.spawnDust(this.player.x + this.player.w / 2, this.player.y + this.player.h, 2);
      }
    } else {
      // 起跳：地面跳（含土狼时间）或空中二段跳
      if (this.player.jumpBuffer > 0) {
        if (this.player.coyote > 0) {
          this.doJump(JUMP_VEL * jumpMul);
        } else if (this.player.jumps < MAX_JUMPS) {
          this.doJump(JUMP_VEL * 0.92 * jumpMul);
          this.spawnDust(this.player.x + this.player.w / 2, this.player.y + this.player.h, 6);
        }
      }
      // 可变跳跃高度
      if (!this.input.isHeld(GameAction.JUMP) && this.player.vy < -JUMP_CUT) {
        this.player.vy = -JUMP_CUT;
      }
      this.player.vy = Math.min(this.player.vy + GRAVITY * dt, MAX_FALL);
    }

    // 移动与碰撞
    this.player.x += this.player.vx * dt;
    this.collideX();
    this.player.y += this.player.vy * dt;
    this.collideY();

    // 世界左边界
    if (this.player.x < 0) {
      this.player.x = 0;
      this.player.vx = 0;
    }

    // 检查点
    if (this.checkpointIdx < this.level.checkpoints.length &&
      this.player.x > this.level.checkpoints[this.checkpointIdx]) {
      this.checkpointIdx++;
      this.addPopup(this.player.x, this.player.y - 24, 'CHECKPOINT', '#7CFC00');
    }

    // 记录"最后站稳的位置"（演示模式救回用）
    if (this.player.onGround && !this.player.dead) {
      this.lastSafeX = this.player.x;
      this.lastSafeY = this.player.y;
    }

    // ★ 演示模式：**卡住助推跳**。
    //   实测有几种台阶（上方还有砖块压着）用普通跳永远翻不过去，
    //   自动驾驶就会贴在那里反复跳。这里在"x 超过 1.2 秒没前进"时
    //   给一次**比普通跳更高**的上升速度，当作二段跳把它顶上去。
    if (this.demoInfiniteLives && !this.player.dead) {
      if (this.player.x > this.assistBestX + 4) {
        this.assistBestX = this.player.x;
        this.assistT = this.globalT;
      } else if (this.globalT - this.assistT > 3.0) {
        // ★ 最后一道保险：卡住 2.5 秒还没前进，就**小幅前推 + 轻抬**。
        //   为什么需要它：有些位置（台阶贴着水管、或头顶有砖块压着）用普通跳
        //   在物理上就过不去，自动驾驶会永远贴着跳。前推 24px、抬高 6px 在 3× 放大下
        //   几乎看不出来，但足以让它脱困继续跑。
        this.assistT = this.globalT;
        this.demoAssists++;
        this.assistsSinceProgress++;
        if (this.assistsSinceProgress >= 4) {
          this.assistsSinceProgress = 0;
          this.rescuesSinceProgress = 0;
          this.progressBestX = 0;
          this.nextLevelOrTitle();
          return;
        }
        const isWater: boolean = this.level.theme === ThemeId.UNDERWATER;
        // ① 先向前推 12px（只推一点点：24px 在 3× 放大下能看出"跳帧"）
        this.player.x += 12;
        // ② 推开后若**与实心格重叠**（高水管/台阶），一格一格往上抬到它顶上。
        //   原来只 +24 不给高度 → 在高水管前会直接推进管子内部，越卡越死（地宫关实测）。
        let guard: number = 0;
        while (guard < 12 && SuperMarioGame.playerHitsSolid(this.level, this.player)) {
          this.player.y -= TILE;
          guard++;
        }
        // ③ 水外给的是**一次普通起跳**的速度（不是瞬移抬高）：
        //   这样观感是"它自己跳了一下"，而不是"画面跳了一下"。
        //   水里**不能给向上冲量**，否则会一直往上飘（水下关实测）。
        this.player.vy = isWater ? 0 : -720;
      }
    }

    // ★ 演示模式：刷新"进度"，一旦真的往前走了 48px，就把救回/助推计数清零
    if (this.demoInfiniteLives && !this.player.dead) {
      if (this.player.x > this.progressBestX + 48) {
        this.progressBestX = this.player.x;
        this.rescuesSinceProgress = 0;
        this.assistsSinceProgress = 0;
      }
    }

    // 掉坑
    if (this.player.y > this.level.height() + 60) {
      if (this.demoInfiniteLives && this.lastSafeX > 0) {
        // ★ 演示模式：**救回最后站稳处**，不扣命。
        //   实测有个坑靠走速跳不过去，一局会在同一个坑里反复死 → 屏保看着很蠢。
        //   救回后再由自动驾驶"跑起来跳"（见 MarioDemo 里过坑按住 RUN）。
        // ★ 退后一段再冲：直接放回坑边会立刻再掉下去（实测救回次数一路涨）。
        //   退 56px 给一段助跑，配合"一直按住加速"就能真正把坑跳过去。
        const back: number = (this.lastSafeX > 56) ? 56 : 0;
        this.player.x = this.lastSafeX - back;
        this.player.y = this.lastSafeY;
        this.player.vx = 0;
        this.player.vy = 0;
        this.player.invincible = 1.0;
        this.demoRescues++;
        this.demoRescueCount++;
        this.rescuesSinceProgress++;
        // 同一个坑救回 3 次还没前进 → 判为"这个坑过不去"，直接换关
        if (this.rescuesSinceProgress >= 3) {
          this.rescuesSinceProgress = 0;
          this.assistsSinceProgress = 0;
          this.progressBestX = 0;
          this.nextLevelOrTitle();
          return;
        }
        return;
      }
      this.killPlayer();
      return;
    }

    // 旗杆（通关）
    if (this.level.hasFlag) {
      const flagX = this.level.flagCol * TILE + 4;
      if (this.player.x + this.player.w > flagX && this.player.x < flagX + 8) {
        this.screen = GameScreen.WIN;
        this.score += 2000;
        this.sound.play('win');
        this.vibrate(30);
        return;
      }
    }

    // 金币（瓦片）
    this.collectTileCoins();

    // 实体更新
    this.updatePickups(dt);
    this.updateMushrooms(dt);
    if (isWater) {
      this.updateFish(dt);
    } else {
      this.updateGoombas(dt);
    }
    this.updateParticles(dt);
    this.updatePopups(dt);

    if (this.player.invincible > 0) {
      this.player.invincible -= dt;
    }

    // 水下气泡
    if (isWater) {
      this.bubbleT += dt;
      if (this.bubbleT > 0.35) {
        this.bubbleT = 0;
        const bx = this.cameraX + (this.globalT * 97) % Math.max(1, this.screenW);
        this.particles.push(new Particle(bx, this.level.height() - 40, 0, -50, 5, 3, 1.6, 0));
      }
    }

    this.updateCamera();
  }

  private updateDeath(dt: number): void {
    this.player.vy = Math.min(this.player.vy + GRAVITY * dt, MAX_FALL);
    this.player.y += this.player.vy * dt;
    this.player.x += this.player.vx * dt;
    this.updateParticles(dt);
    this.updatePopups(dt);
    this.updateBumps(dt);
    if (this.player.y > this.level.height() + 200) {
      this.respawnPlayer();
    }
  }

  /** 诊断：死亡次数 / 最后死亡位置与原因（移植版新增） */
  demoDeaths: number = 0;
  /** 演示模式：最后站稳的位置（掉坑自动救回用） */
  private lastSafeX: number = 0;
  private lastSafeY: number = 0;
  /** 演示模式：自动救回次数 */
  demoRescues: number = 0;
  /** 连续救回计数（短时间内的），用来识别"这个坑过不去" */
  private rescueStreak: number = 0;
  private lastRescueT: number = -99;
  /**
   * 演示模式：**进度条机制**（统一管住所有"作弊"）。
   * 只要玩家比历史最远位置多前进 48px，就认为"有进展"，
   * 把救回/助推计数清零；否则累计，超过阈值就换关。
   * ★ 之前用"3 秒内的连击"判定，而实测循环周期是 3.8 秒 → 永远识别不到，
   *   结果救回 307 次 / 19 分钟（每 3.8 秒一次），画面一直在原地兜圈。
   */
  private progressBestX: number = 0;
  private rescuesSinceProgress: number = 0;
  private assistsSinceProgress: number = 0;
  /** 助推（卡住前推/抬顶）用的"最远位置 + 时间" */
  private assistBestX: number = 0;
  private assistT: number = 0;
  /** 助推跳次数（诊断） */
  demoAssists: number = 0;
  /** 救回次数（诊断） */
  demoRescueCount: number = 0;
  lastDeathX: number = 0;
  lastDeathCause: string = '';

  private killPlayer(): void {
    if (this.player.dead) {
      return;
    }
    this.demoDeaths++;
    this.lastDeathX = Math.round(this.player.x);
    this.lastDeathCause = (this.player.y > this.level.height() - 24) ? 'PIT' : 'HIT';
    this.player.dead = true;
    this.sound.play('die');
    this.vibrate(40);
    if (this.player.y < this.level.height()) {
      this.player.vy = -620;
      this.player.vx = 0;
    }
  }

  /**
   * 执行一次起跳（地面跳或二段跳）
   */
  private doJump(v: number): void {
    this.player.vy = -v;
    this.player.onGround = false;
    this.player.coyote = 0;
    this.player.jumpBuffer = 0;
    this.player.jumps++;
    this.sound.play('jump');
    this.vibrate(20);
  }

  // ============ 水管 ============

  /**
   * 玩家脚下水管序号（站在可进入水管的顶部），否则 -1
   */
  private standingPipeIndex(): number {
    const p = this.player;
    if (!p.onGround) {
      return -1;
    }
    const feetRow = Math.floor((p.y + p.h) / TILE);
    for (let i = 0; i < this.level.enterPipes.length; i++) {
      const w = this.level.enterPipes[i];
      const rimRow = LEVEL_ROWS - 2 - w.h;
      if (feetRow === rimRow) {
        const x0 = w.col * TILE;
        if (p.x + p.w > x0 + 2 && p.x < x0 + TILE * 2 - 2) {
          return i;
        }
      }
    }
    return -1;
  }

  /**
   * 尝试进入水管，返回是否触发
   */
  private tryEnterPipe(): boolean {
    const idx = this.standingPipeIndex();
    if (idx < 0) {
      return false;
    }
    const warp = this.level.enterPipes[idx];
    if (warp.kind === 1) {
      this.sound.play('pipe');
      this.startLevel(this.levelIndex + 1);
    } else if (warp.kind === 0) {
      this.enterSub(warp);
    } else {
      this.exitSub();
    }
    return true;
  }

  /**
   * 进入水管奖励关
   */
  private enterSub(warp: PipeWarp): void {
    this.parentLevel = this.level;
    this.returnCol = warp.exitCol;
    this.savedGoombas = this.goombas;
    this.savedFish = this.fish;
    this.savedPickups = this.pickups;
    this.savedMushrooms = this.mushrooms;
    this.savedParticles = this.particles;
    this.savedPopups = this.popups;
    this.subLevel = buildBonusRoom();
    this.level = this.subLevel;
    this.subActive = true;
    this.sound.play('pipe');
    this.vibrate(25);
    this.spawnEnemies();
    this.pickups = [];
    this.mushrooms = [];
    this.particles = [];
    this.popups = [];
    this.checkpointIdx = 0;
    this.levelTime = 300;
    this.player.reset(this.level.spawnX, this.level.spawnY);
    this.cameraX = 0;
    this.cameraY = Math.max(0, this.level.height() - this.screenH);
  }

  /**
   * 从奖励关水管返回主关卡
   */
  private exitSub(): void {
    if (this.parentLevel === null) {
      return;
    }
    this.level = this.parentLevel;
    this.subActive = false;
    this.subLevel = null;
    this.parentLevel = null;
    this.goombas = this.savedGoombas;
    this.fish = this.savedFish;
    this.pickups = this.savedPickups;
    this.mushrooms = this.savedMushrooms;
    this.particles = this.savedParticles;
    this.popups = this.savedPopups;
    this.sound.play('pipe');
    this.vibrate(25);
    this.player.reset(this.returnCol * TILE, this.level.spawnY);
    this.player.invincible = 1.0;
    this.levelTime = 300;
    this.cameraX = Math.max(0, this.player.x - this.screenW * 0.38);
  }

  // ============ 碰撞 ============

  private collideX(): void {
    const top = Math.floor(this.player.y / TILE);
    const bottom = Math.floor((this.player.y + this.player.h - 0.001) / TILE);
    if (this.player.vx > 0) {
      const col = Math.floor((this.player.x + this.player.w) / TILE);
      for (let r = top; r <= bottom; r++) {
        if (this.level.solidAt(col, r)) {
          this.player.x = col * TILE - this.player.w;
          this.player.vx = 0;
          break;
        }
      }
    } else if (this.player.vx < 0) {
      const col = Math.floor(this.player.x / TILE);
      for (let r = top; r <= bottom; r++) {
        if (this.level.solidAt(col, r)) {
          this.player.x = (col + 1) * TILE;
          this.player.vx = 0;
          break;
        }
      }
    }
  }

  private collideY(): void {
    const left = Math.floor(this.player.x / TILE);
    const right = Math.floor((this.player.x + this.player.w - 0.001) / TILE);
    let grounded = false;
    if (this.player.vy >= 0) {
      const row = Math.floor((this.player.y + this.player.h) / TILE);
      for (let c = left; c <= right; c++) {
        if (this.level.solidAt(c, row)) {
          this.player.y = row * TILE - this.player.h;
          this.player.vy = 0;
          grounded = true;
          break;
        }
      }
    } else {
      const row = Math.floor(this.player.y / TILE);
      for (let c = left; c <= right; c++) {
        if (this.level.solidAt(c, row)) {
          this.player.y = (row + 1) * TILE;
          this.player.vy = 0;
          this.bumpTile(c, row);
        }
      }
    }
    this.player.onGround = grounded;
    if (grounded) {
      this.player.jumps = 0; // 落地后重置连跳次数
    }
  }

  /**
   * 顶砖块
   */
  private bumpTile(col: number, row: number): void {
    const t = this.level.tileAt(col, row);
    const cx = col * TILE + TILE / 2;
    const cy = row * TILE + TILE / 2;
    if (t === TileId.QUESTION || t === TileId.QUESTION_POWER) {
      this.level.tiles[row][col] = TileId.USED;
      this.setBump(col, row);
      if (t === TileId.QUESTION) {
        this.pickups.push(new CoinPickup(cx, row * TILE));
      } else {
        this.mushrooms.push(new Mushroom(cx, row * TILE - 8));
      }
      this.sound.play('bump');
    } else if (t === TileId.BRICK) {
      if (this.player.big) {
        // 大玛丽可以顶碎砖块
        this.level.tiles[row][col] = TileId.EMPTY;
        this.breakBrick(cx, cy);
        this.score += 50;
        this.addPopup(cx, cy - TILE, '+50', '#FFFFFF');
        hilog.info(DOMAIN, TAG, '顶碎砖块: 列=%{public}d 行=%{public}d', col, row);
      } else {
        // 小玛丽只能顶动砖块
        this.setBump(col, row);
        hilog.info(DOMAIN, TAG, '顶动砖块(小玛丽): 列=%{public}d 行=%{public}d', col, row);
      }
      this.sound.play('bump');
    } else {
      this.setBump(col, row);
      this.sound.play('bump');
    }
    this.vibrate(25); // 撞击物品震动
  }

  private breakBrick(cx: number, cy: number): void {
    this.particles.push(new Particle(cx - 12, cy - 12, -160, -300, 12, 0, 1.0, GRAVITY));
    this.particles.push(new Particle(cx + 12, cy - 12, 160, -300, 12, 0, 1.0, GRAVITY));
    this.particles.push(new Particle(cx - 12, cy + 6, -140, -220, 12, 0, 0.9, GRAVITY));
    this.particles.push(new Particle(cx + 12, cy + 6, 140, -220, 12, 0, 0.9, GRAVITY));
    this.vibrate(30);
  }

  private setBump(col: number, row: number): void {
    this.bumpTiles.set(col * 1000 + row, 0.16);
  }

  private updateBumps(dt: number): void {
    if (this.bumpTiles.size === 0) {
      return;
    }
    const expired: number[] = [];
    this.bumpTiles.forEach((v: number, k: number) => {
      const nv = v - dt;
      if (nv <= 0) {
        expired.push(k);
      } else {
        this.bumpTiles.set(k, nv);
      }
    });
    for (let i = 0; i < expired.length; i++) {
      this.bumpTiles.delete(expired[i]);
    }
  }

  private bumpOffset(col: number, row: number): number {
    const v = this.bumpTiles.get(col * 1000 + row);
    if (v === undefined) {
      return 0;
    }
    const p = 1 - v / 0.16;
    return -Math.sin(p * Math.PI) * 10;
  }

  // ============ 收集与实体 ============

  private collectTileCoins(): void {
    const left = Math.floor(this.player.x / TILE);
    const right = Math.floor((this.player.x + this.player.w - 0.001) / TILE);
    const top = Math.floor(this.player.y / TILE);
    const bottom = Math.floor((this.player.y + this.player.h - 0.001) / TILE);
    for (let r = top; r <= bottom; r++) {
      for (let c = left; c <= right; c++) {
        if (this.level.tileAt(c, r) === TileId.COIN) {
          this.level.tiles[r][c] = TileId.EMPTY;
          this.addCoin(c * TILE + TILE / 2, r * TILE + TILE / 2);
        }
      }
    }
  }

  private addCoin(x: number, y: number): void {
    this.coinCount++;
    this.score += 200;
    this.sound.play('coin');
    this.vibrate(15);
    this.addPopup(x, y - 20, '+200', '#FFD700');
    this.spawnSparkle(x, y, 6);
    if (this.coinCount >= 100) {
      this.coinCount -= 100;
      this.lives = Math.min(this.lives + 1, MAX_LIVES);
      this.addPopup(x, y - 44, '1UP!', '#7CFC00');
      this.sound.play('1up');
    }
  }

  private updatePickups(dt: number): void {
    for (let i = this.pickups.length - 1; i >= 0; i--) {
      const c = this.pickups[i];
      c.t += dt;
      c.vy += GRAVITY * dt;
      c.y += c.vy * dt;
      if (c.y >= c.baseY + 8) {
        this.pickups.splice(i, 1);
        continue;
      }
      if (this.overlapEntity(this.player, c.x - 10, c.y - 10, 20, 20)) {
        this.addCoin(c.x, c.y);
        this.pickups.splice(i, 1);
      }
    }
  }

  private updateMushrooms(dt: number): void {
    for (let i = this.mushrooms.length - 1; i >= 0; i--) {
      const m = this.mushrooms[i];
      m.vy = Math.min(m.vy + GRAVITY * dt, MAX_FALL);
      m.x += m.vx * dt;
      const top = Math.floor(m.y / TILE);
      const bottom = Math.floor((m.y + m.h - 0.001) / TILE);
      if (m.vx > 0) {
        const col = Math.floor((m.x + m.w) / TILE);
        for (let r = top; r <= bottom; r++) {
          if (this.level.solidAt(col, r)) {
            m.x = col * TILE - m.w;
            m.vx = -m.vx;
            break;
          }
        }
      } else if (m.vx < 0) {
        const col = Math.floor(m.x / TILE);
        for (let r = top; r <= bottom; r++) {
          if (this.level.solidAt(col, r)) {
            m.x = (col + 1) * TILE;
            m.vx = -m.vx;
            break;
          }
        }
      }
      m.y += m.vy * dt;
      const row = Math.floor((m.y + m.h) / TILE);
      const lc = Math.floor(m.x / TILE);
      const rc = Math.floor((m.x + m.w - 0.001) / TILE);
      for (let c = lc; c <= rc; c++) {
        if (this.level.solidAt(c, row)) {
          m.y = row * TILE - m.h;
          m.vy = 0;
          break;
        }
      }
      if (m.y > this.level.height() + 60) {
        this.mushrooms.splice(i, 1);
        continue;
      }
      if (this.overlapEntity(this.player, m.x, m.y, m.w, m.h)) {
        if (!this.player.big) {
          // 吃蘑菇：变大
          this.player.big = true;
          this.player.h = 48;
          this.player.y -= 16; // 保持脚底位置
          this.score += 1000;
          this.sound.play('powerup');
          this.addPopup(m.x, m.y - 20, '变大!', '#7CFC00');
          this.vibrate(45); // 吃蘑菇震动
        } else {
          this.score += 500;
          this.addPopup(m.x, m.y - 20, '+500', '#FFD700');
          this.sound.play('coin');
        }
        this.spawnSparkle(m.x + m.w / 2, m.y + m.h / 2, 10);
        this.mushrooms.splice(i, 1);
      }
    }
  }

  private updateGoombas(dt: number): void {
    for (let i = this.goombas.length - 1; i >= 0; i--) {
      const g = this.goombas[i];
      g.walkT += dt;
      if (g.squashed) {
        g.squashTimer -= dt;
        if (g.squashTimer <= 0) {
          this.goombas.splice(i, 1);
        }
        continue;
      }
      g.vy = Math.min(g.vy + GRAVITY * dt, MAX_FALL);
      g.x += g.vx * dt;
      const top = Math.floor(g.y / TILE);
      const bottom = Math.floor((g.y + g.h - 0.001) / TILE);
      if (g.vx > 0) {
        const col = Math.floor((g.x + g.w) / TILE);
        for (let r = top; r <= bottom; r++) {
          if (this.level.solidAt(col, r)) {
            g.x = col * TILE - g.w;
            g.vx = -g.vx;
            break;
          }
        }
      } else if (g.vx < 0) {
        const col = Math.floor(g.x / TILE);
        for (let r = top; r <= bottom; r++) {
          if (this.level.solidAt(col, r)) {
            g.x = (col + 1) * TILE;
            g.vx = -g.vx;
            break;
          }
        }
      }
      g.y += g.vy * dt;
      const row = Math.floor((g.y + g.h) / TILE);
      const lc = Math.floor(g.x / TILE);
      const rc = Math.floor((g.x + g.w - 0.001) / TILE);
      for (let c = lc; c <= rc; c++) {
        if (this.level.solidAt(c, row)) {
          g.y = row * TILE - g.h;
          g.vy = 0;
          break;
        }
      }
      if (g.y > this.level.height() + 60) {
        this.goombas.splice(i, 1);
        continue;
      }
      if (this.overlapEntity(this.player, g.x, g.y, g.w, g.h)) {
        if (this.player.vy > 0 && this.player.y + this.player.h - g.y < 16) {
          g.squashed = true;
          g.squashTimer = 0.35;
          this.player.vy = -360;
          this.score += 100;
          this.sound.play('stomp');
          this.vibrate(20);
          this.addPopup(g.x, g.y - 12, '+100', '#FFFFFF');
          this.spawnDust(g.x + g.w / 2, g.y + g.h, 5);
        } else if (this.player.invincible <= 0) {
          if (this.demoInfiniteLives) {
            // ★ 演示模式：**侧撞也当踩**。
            //   屏保不该因为一次"贴边撞上"就死一次（用户反馈"死得太快、看着蠢"）。
            //   这里改成弹开 + 踩死 + 加 100 分，观感上像"硬顶过去"。
            g.squashed = true;
            g.squashTimer = 0.35;
            this.player.vy = -360;
            this.score += 100;
            this.addPopup(g.x, g.y - 12, '+100', '#FFFFFF');
            this.spawnDust(g.x + g.w / 2, g.y + g.h, 5);
          } else if (this.player.big) {
            this.shrinkPlayer();
          } else {
            this.killPlayer();
          }
        }
      }
    }
  }

  private updateFish(dt: number): void {
    for (let i = this.fish.length - 1; i >= 0; i--) {
      const f = this.fish[i];
      f.t += dt;
      f.x += f.vx * dt;
      const row = Math.floor((f.y + f.h / 2) / TILE);
      if (f.vx > 0) {
        const col = Math.floor((f.x + f.w) / TILE);
        if (this.level.solidAt(col, row)) {
          f.vx = -f.vx;
        }
      } else {
        const col = Math.floor(f.x / TILE);
        if (this.level.solidAt(col, row)) {
          f.vx = -f.vx;
        }
      }
      f.y = f.baseY + Math.sin(f.t * 2.2) * 22;
      if (f.x < this.cameraX - 80 || f.x > this.cameraX + this.screenW + 80) {
        continue;
      }
      if (this.overlapEntity(this.player, f.x, f.y, f.w, f.h)) {
        if (this.player.invincible <= 0) {
          if (this.player.big) {
            this.shrinkPlayer();
          } else {
            this.killPlayer();
          }
        }
      }
    }
  }

  private updateParticles(dt: number): void {
    for (let i = this.particles.length - 1; i >= 0; i--) {
      const p = this.particles[i];
      p.t += dt;
      if (p.kind !== 3) {
        p.vy += p.grav * dt;
      }
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      if (p.t >= p.life) {
        this.particles.splice(i, 1);
      }
    }
  }

  private updatePopups(dt: number): void {
    for (let i = this.popups.length - 1; i >= 0; i--) {
      const p = this.popups[i];
      p.t += dt;
      p.y -= 34 * dt;
      if (p.t >= p.life) {
        this.popups.splice(i, 1);
      }
    }
  }

  private updateCamera(): void {
    const tx = this.player.x - this.screenW * 0.38;
    const maxX = Math.max(0, this.level.width() - this.screenW);
    this.cameraX = Math.max(0, Math.min(tx, maxX));
    const ty = this.player.y - this.screenH * 0.55;
    const maxY = Math.max(0, this.level.height() - this.screenH);
    this.cameraY = Math.max(0, Math.min(ty, maxY));
  }

  private overlapEntity(a: Player, x: number, y: number, w: number, h: number): boolean {
    return a.x < x + w && a.x + a.w > x && a.y < y + h && a.y + a.h > y;
  }

  private spawnDust(x: number, y: number, n: number): void {
    for (let i = 0; i < n; i++) {
      const a = (i / n) * 6.28318;
      this.particles.push(new Particle(x, y, Math.cos(a) * 50, -40 - (i % 3) * 30, 5, 1, 0.35, 300));
    }
  }

  private spawnSparkle(x: number, y: number, n: number): void {
    for (let i = 0; i < n; i++) {
      const a = (i / n) * 6.28318;
      this.particles.push(new Particle(x, y, Math.cos(a) * 90, Math.sin(a) * 90, 4, 2, 0.45, 0));
    }
  }

  private addPopup(x: number, y: number, text: string, color: string): void {
    this.popups.push(new Popup(x, y, text, color));
  }

  private vibrate(ms: number): void {
    try {
      // 副屏没有马达：震动调用已移除（原实现 vibrator.startVibration）
    } catch (e) {
      // 不支持震动时静默忽略
    }
  }

  /**
   * 大玛丽被撞：缩小并短暂无敌（不损失生命）
   */
  private shrinkPlayer(): void {
    this.player.big = false;
    this.player.h = 32;
    this.player.y += 16; // 保持脚底位置
    this.player.invincible = 1.5;
    this.sound.play('bump');
    this.vibrate(30);
    this.addPopup(this.player.x, this.player.y - 20, '变小', '#FFFFFF');
    this.spawnDust(this.player.x + this.player.w / 2, this.player.y + this.player.h, 6);
  }

  // ============ 渲染（沿用上一版可爱方块风格 + 主题换色） ============

  render(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    this.screenW = w;
    this.screenH = h;
    const theme = this.level.theme;

    // 天空（渐变，按主题配色）
    const sky = ctx.createLinearGradient(0, 0, 0, h);
    if (theme === ThemeId.UNDERGROUND) {
      sky.addColorStop(0, '#0B1026');
      sky.addColorStop(1, '#1B2440');
    } else if (theme === ThemeId.UNDERWATER) {
      sky.addColorStop(0, '#1A40E8');
      sky.addColorStop(1, '#4A6CF8');
    } else if (theme === ThemeId.CASTLE) {
      sky.addColorStop(0, '#141420');
      sky.addColorStop(1, '#1E1E2C');
    } else {
      sky.addColorStop(0, '#5AB9F0');
      sky.addColorStop(1, '#9AD9FF');
    }
    ctx.fillStyle = sky;
    ctx.fillRect(0, 0, w, h);

    // 背景装饰
    if (theme === ThemeId.OVERWORLD) {
      this.drawClouds(ctx, w);
      this.drawHills(ctx, w);
    } else if (theme === ThemeId.UNDERWATER) {
      this.drawSeaweed(ctx, w);
    } else if (theme === ThemeId.CASTLE) {
      this.drawCastleDecor(ctx, w);
    }

    ctx.save();
    ctx.translate(-this.cameraX, -this.cameraY);

    if (this.level.hasFlag) {
      this.drawFlag(ctx);
    }
    this.drawTiles(ctx);
    this.drawPickups(ctx);
    this.drawMushrooms(ctx);
    if (theme === ThemeId.UNDERWATER) {
      this.drawFishEntities(ctx);
    } else {
      this.drawGoombas(ctx);
    }
    this.drawPlayer(ctx);
    this.drawParticles(ctx);
    this.drawPopups(ctx);

    ctx.restore();

    // HUD
    if (this.screen === GameScreen.PLAYING || this.screen === GameScreen.PAUSED) {
      this.drawHud(ctx, w);
    }

    // 覆盖层
    if (this.screen === GameScreen.TITLE) {
      this.drawTitle(ctx, w, h);
    } else if (this.screen === GameScreen.CHARACTER_SELECT) {
      this.drawCharSelect(ctx, w, h);
    } else if (this.screen === GameScreen.PAUSED) {
      this.drawPaused(ctx, w, h);
    } else if (this.screen === GameScreen.GAME_OVER) {
      this.drawGameOver(ctx, w, h);
    } else if (this.screen === GameScreen.WIN) {
      this.drawWin(ctx, w, h);
    }
  }

  private drawClouds(ctx: CanvasRenderingContext2D, w: number): void {
    ctx.fillStyle = 'rgba(255,255,255,0.92)';
    for (let i = 0; i < this.clouds.length; i++) {
      const c = this.clouds[i];
      const sx = c.x - this.cameraX * 0.45;
      if (sx + 80 < 0 || sx - 80 > w) {
        continue;
      }
      const s = c.s;
      ctx.beginPath();
      ctx.arc(sx, c.y, 22 * s, 0, 6.28318);
      ctx.arc(sx + 24 * s, c.y - 8 * s, 18 * s, 0, 6.28318);
      ctx.arc(sx + 48 * s, c.y, 22 * s, 0, 6.28318);
      ctx.fill();
      ctx.fillRect(sx, c.y, 48 * s, 20 * s);
    }
  }

  private drawHills(ctx: CanvasRenderingContext2D, w: number): void {
    for (let i = 0; i < this.hills.length; i++) {
      const hi = this.hills[i];
      const sx = hi.x - this.cameraX * 0.6;
      if (sx + 200 < 0 || sx - 200 > w) {
        continue;
      }
      const s = hi.s;
      ctx.fillStyle = '#3FA34D';
      ctx.beginPath();
      ctx.arc(sx, this.screenH - 40 * s, 60 * s, 3.14159, 6.28318);
      ctx.fill();
      ctx.fillStyle = '#2E7D3A';
      ctx.fillRect(sx - 60 * s, this.screenH - 40 * s, 120 * s, 40 * s);
    }
  }

  private drawSeaweed(ctx: CanvasRenderingContext2D, w: number): void {
    ctx.fillStyle = '#0A8A4A';
    const step = 96;
    const off = Math.floor(this.cameraX / step) * step;
    for (let x = off - step; x < off + w + step; x += step) {
      const sway = Math.sin(this.globalT * 2 + x) * 6;
      ctx.fillRect(x - 8 + sway, this.screenH - 70, 10, 26);
      ctx.fillRect(x - 4 - sway, this.screenH - 54, 10, 18);
      ctx.fillRect(x + sway, this.screenH - 42, 10, 12);
    }
  }

  private drawCastleDecor(ctx: CanvasRenderingContext2D, w: number): void {
    ctx.fillStyle = '#1C1C26';
    const step = 72;
    const off = Math.floor(this.cameraX / step) * step;
    for (let x = off - step; x < off + w + step; x += step) {
      ctx.fillRect(x, 0, 30, this.screenH * 0.4);
    }
  }

  private drawFlag(ctx: CanvasRenderingContext2D): void {
    const px = this.level.flagCol * TILE + 4;
    const topY = this.level.flagTopRow * TILE;
    const baseY = (LEVEL_ROWS - 3) * TILE;
    ctx.fillStyle = '#E8E8E8';
    ctx.fillRect(px, topY, 4, baseY - topY);
    ctx.fillStyle = '#5A5A5A';
    ctx.fillRect(px + 1, topY, 1, baseY - topY);
    ctx.fillStyle = '#2ECC40';
    ctx.beginPath();
    ctx.moveTo(px + 4, topY + 4);
    ctx.lineTo(px + 40, topY + 16);
    ctx.lineTo(px + 4, topY + 28);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = '#7B8794';
    ctx.fillRect(px - 6, baseY, 16, 8);
  }

  private drawTiles(ctx: CanvasRenderingContext2D): void {
    const c0 = Math.max(0, Math.floor(this.cameraX / TILE) - 1);
    const c1 = Math.min(this.level.cols - 1, Math.ceil((this.cameraX + this.screenW) / TILE) + 1);
    const r0 = Math.max(0, Math.floor(this.cameraY / TILE) - 1);
    const r1 = Math.min(this.level.rows - 1, Math.ceil((this.cameraY + this.screenH) / TILE) + 1);
    for (let r = r0; r <= r1; r++) {
      for (let c = c0; c <= c1; c++) {
        const t = this.level.tiles[r][c];
        if (t === TileId.EMPTY) {
          continue;
        }
        const bump = this.bumpOffset(c, r);
        this.drawTile(ctx, t, c * TILE, r * TILE + bump);
      }
    }
  }

  private drawTile(ctx: CanvasRenderingContext2D, t: number, x: number, y: number): void {
    switch (t) {
      case TileId.GROUND:
        this.drawGround(ctx, x, y);
        break;
      case TileId.STONE:
        this.drawStone(ctx, x, y);
        break;
      case TileId.BRICK:
        this.drawBrick(ctx, x, y);
        break;
      case TileId.QUESTION:
        this.drawQuestion(ctx, x, y, '#E8A33D');
        break;
      case TileId.QUESTION_POWER:
        this.drawQuestion(ctx, x, y, '#F5B042');
        break;
      case TileId.USED:
        this.drawUsed(ctx, x, y);
        break;
      case TileId.PIPE_TL:
        this.drawPipeRim(ctx, x, y, true);
        break;
      case TileId.PIPE_TR:
        this.drawPipeRim(ctx, x, y, false);
        break;
      case TileId.PIPE_L:
        this.drawPipeBody(ctx, x, y, true);
        break;
      case TileId.PIPE_R:
        this.drawPipeBody(ctx, x, y, false);
        break;
      case TileId.COIN:
        this.drawCoin(ctx, x + TILE / 2, y + TILE / 2, 10);
        break;
    }
  }

  /**
   * 瓦片主题配色
   */
  private groundColors(): string[] {
    switch (this.level.theme) {
      case ThemeId.UNDERGROUND:
        return ['#5A6B8A', '#4A5A7A', '#3A4A6A', '#202030'];
      case ThemeId.UNDERWATER:
        return ['#D8A860', '#C89050', '#A07840', '#6B4A22'];
      case ThemeId.CASTLE:
        return ['#6A6A74', '#4A4A54', '#3A3A44', '#202028'];
    }
    return ['#C97B32', '#4CC23E', '#A05A1F', '#6B3A12'];
  }

  private brickColors(): string[] {
    switch (this.level.theme) {
      case ThemeId.UNDERGROUND:
        return ['#3A6BD0', '#5A8AF0', '#20306A'];
      case ThemeId.UNDERWATER:
        return ['#F8D878', '#F8E8A8', '#A08040'];
      case ThemeId.CASTLE:
        return ['#8A8A94', '#A8A8B2', '#50505A'];
    }
    return ['#C65A2A', '#E0804A', '#8A3A12'];
  }

  private stoneColors(): string[] {
    switch (this.level.theme) {
      case ThemeId.UNDERGROUND:
        return ['#6A7A9A', '#8A9ABA', '#4A5A7A', '#5A6A8A'];
      case ThemeId.UNDERWATER:
        return ['#C8C8A0', '#E8E8C0', '#888860', '#A8A880'];
      case ThemeId.CASTLE:
        return ['#9A9AA4', '#B8B8C2', '#5A5A64', '#7A7A84'];
    }
    return ['#9AA5B1', '#C9D2DA', '#66707B', '#7B8692'];
  }

  private drawGround(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    const c = this.groundColors();
    ctx.fillStyle = c[0];
    ctx.fillRect(x, y, TILE, TILE);
    ctx.fillStyle = c[1];
    ctx.fillRect(x, y, TILE, 9);
    ctx.fillStyle = c[2];
    ctx.fillRect(x, y + 9, TILE, 2);
    ctx.fillRect(x, y + 16, TILE, 3);
    ctx.fillRect(x + 6, y + 24, TILE - 12, 3);
    ctx.fillStyle = c[3];
    ctx.fillRect(x, y, 2, TILE);
    ctx.fillRect(x + TILE - 2, y, 2, TILE);
  }

  private drawStone(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    const c = this.stoneColors();
    ctx.fillStyle = c[0];
    ctx.fillRect(x, y, TILE, TILE);
    ctx.fillStyle = c[1];
    ctx.fillRect(x, y, TILE, 4);
    ctx.fillRect(x, y, 4, TILE);
    ctx.fillStyle = c[2];
    ctx.fillRect(x + TILE - 4, y, 4, TILE);
    ctx.fillRect(x, y + TILE - 4, TILE, 4);
    ctx.fillStyle = c[3];
    ctx.fillRect(x + 4, y + 4, TILE - 8, TILE - 8);
  }

  private drawBrick(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    const c = this.brickColors();
    ctx.fillStyle = c[0];
    ctx.fillRect(x, y, TILE, TILE);
    ctx.fillStyle = c[1];
    ctx.fillRect(x, y, TILE, 3);
    ctx.fillStyle = c[2];
    ctx.fillRect(x, y + 15, TILE, 2);
    ctx.fillRect(x + 10, y + 1, 2, 14);
    ctx.fillRect(x + 22, y + 17, 2, 15);
    ctx.fillRect(x, y + 17, 8, 2);
  }

  private drawQuestion(ctx: CanvasRenderingContext2D, x: number, y: number, base: string): void {
    ctx.fillStyle = base;
    ctx.fillRect(x, y, TILE, TILE);
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(x + 2, y + 2, TILE - 4, 3);
    ctx.fillRect(x + 2, y + 2, 3, TILE - 4);
    ctx.fillStyle = '#8A5A24';
    ctx.fillRect(x + 2, y + TILE - 5, TILE - 4, 3);
    ctx.fillRect(x + TILE - 5, y + 2, 3, TILE - 4);
    ctx.fillRect(x + 4, y + 4, 3, 3);
    ctx.fillRect(x + TILE - 7, y + 4, 3, 3);
    ctx.fillRect(x + 4, y + TILE - 7, 3, 3);
    ctx.fillRect(x + TILE - 7, y + TILE - 7, 3, 3);
    ctx.fillStyle = '#FFFFFF';
    ctx.font = 'bold 18px sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('?', x + TILE / 2, y + TILE / 2 + 1);
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
  }

  private drawUsed(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    ctx.fillStyle = '#9C4A1A';
    ctx.fillRect(x, y, TILE, TILE);
    ctx.fillStyle = '#7A3410';
    ctx.fillRect(x, y, TILE, 3);
    ctx.fillRect(x, y, 3, TILE);
    ctx.fillRect(x + TILE - 3, y, 3, TILE);
    ctx.fillRect(x, y + TILE - 3, TILE, 3);
    ctx.fillStyle = '#5A2408';
    ctx.fillRect(x + 5, y + 5, 4, 4);
    ctx.fillRect(x + TILE - 9, y + 5, 4, 4);
    ctx.fillRect(x + 5, y + TILE - 9, 4, 4);
    ctx.fillRect(x + TILE - 9, y + TILE - 9, 4, 4);
  }

  private drawPipeRim(ctx: CanvasRenderingContext2D, x: number, y: number, isLeft: boolean): void {
    ctx.fillStyle = '#155C29';
    ctx.fillRect(x, y + 12, TILE, 2);
    ctx.fillStyle = '#2FA14C';
    ctx.fillRect(x, y, TILE, 12);
    ctx.fillStyle = '#7BD88A';
    ctx.fillRect(x + (isLeft ? 3 : 16), y + 1, 6, 10);
  }

  private drawPipeBody(ctx: CanvasRenderingContext2D, x: number, y: number, isLeft: boolean): void {
    ctx.fillStyle = '#2FA14C';
    ctx.fillRect(x, y, TILE, TILE);
    ctx.fillStyle = '#7BD88A';
    ctx.fillRect(x + (isLeft ? 3 : 16), y, 6, TILE);
    ctx.fillStyle = '#155C29';
    ctx.fillRect(x + TILE - 4, y, 4, TILE);
  }

  private drawCoin(ctx: CanvasRenderingContext2D, cx: number, cy: number, r: number): void {
    const sq = Math.max(0.18, Math.abs(Math.cos(this.globalT * 6)));
    ctx.save();
    ctx.translate(cx, cy);
    ctx.scale(sq, 1);
    ctx.fillStyle = '#FFD700';
    ctx.beginPath();
    ctx.arc(0, 0, r, 0, 6.28318);
    ctx.fill();
    ctx.fillStyle = '#E8A33D';
    ctx.beginPath();
    ctx.arc(0, 0, r - 3, 0, 6.28318);
    ctx.fill();
    ctx.fillStyle = '#B8860B';
    ctx.beginPath();
    ctx.arc(0, 0, r - 6, 0, 6.28318);
    ctx.fill();
    ctx.restore();
    ctx.fillStyle = '#FFD8A0';
    ctx.fillRect(cx - 1, cy - r, 2, r * 2);
  }

  private drawPickups(ctx: CanvasRenderingContext2D): void {
    for (let i = 0; i < this.pickups.length; i++) {
      const c = this.pickups[i];
      this.drawCoin(ctx, c.x, c.y, 9);
    }
  }

  private drawMushrooms(ctx: CanvasRenderingContext2D): void {
    for (let i = 0; i < this.mushrooms.length; i++) {
      const m = this.mushrooms[i];
      ctx.fillStyle = '#E03020';
      ctx.beginPath();
      ctx.arc(m.x + m.w / 2, m.y + 10, 14, 3.14159, 6.28318);
      ctx.fill();
      ctx.fillRect(m.x + 1, m.y + 10, m.w - 2, 5);
      ctx.fillStyle = '#FFFFFF';
      ctx.fillRect(m.x + 6, m.y + 5, 5, 5);
      ctx.fillRect(m.x + 18, m.y + 8, 4, 4);
      ctx.fillStyle = '#F5E6C8';
      ctx.fillRect(m.x + 7, m.y + 15, 16, 10);
      ctx.fillStyle = '#222222';
      ctx.fillRect(m.x + 10, m.y + 17, 3, 4);
      ctx.fillRect(m.x + 18, m.y + 17, 3, 4);
    }
  }

  private drawGoombas(ctx: CanvasRenderingContext2D): void {
    for (let i = 0; i < this.goombas.length; i++) {
      const g = this.goombas[i];
      if (g.squashed) {
        ctx.fillStyle = '#7A3B12';
        ctx.fillRect(g.x, g.y + g.h - 8, g.w, 8);
        ctx.fillStyle = '#E8C9A0';
        ctx.fillRect(g.x + 3, g.y + g.h - 7, g.w - 6, 3);
      } else {
        const step = Math.sin(g.walkT * 12) * 2;
        ctx.fillStyle = '#3A1B08';
        ctx.fillRect(g.x + 2 + step, g.y + g.h - 5, 10, 5);
        ctx.fillRect(g.x + g.w - 12 - step, g.y + g.h - 5, 10, 5);
        ctx.fillStyle = '#7A3B12';
        ctx.beginPath();
        ctx.arc(g.x + g.w / 2, g.y + g.h - 4, 12, 3.14159, 6.28318);
        ctx.fill();
        ctx.fillRect(g.x + 2, g.y + g.h - 8, g.w - 4, 8);
        ctx.fillStyle = '#E8C9A0';
        ctx.fillRect(g.x + 3, g.y + g.h - 8, g.w - 6, 5);
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(g.x + 6, g.y + g.h - 7, 5, 5);
        ctx.fillRect(g.x + g.w - 11, g.y + g.h - 7, 5, 5);
        ctx.fillStyle = '#111111';
        ctx.fillRect(g.x + 9, g.y + g.h - 5, 2, 3);
        ctx.fillRect(g.x + g.w - 8, g.y + g.h - 5, 2, 3);
      }
    }
  }

  private drawFishEntities(ctx: CanvasRenderingContext2D): void {
    for (let i = 0; i < this.fish.length; i++) {
      const f = this.fish[i];
      ctx.save();
      ctx.translate(f.x + f.w / 2, f.y + f.h / 2);
      ctx.scale(f.vx < 0 ? -1 : 1, 1);
      ctx.fillStyle = '#F86820';
      ctx.beginPath();
      ctx.arc(0, 0, 13, 0, 6.28318);
      ctx.fill();
      ctx.fillStyle = '#F8A030';
      ctx.beginPath();
      ctx.moveTo(-10, -6);
      ctx.lineTo(-22, -14);
      ctx.lineTo(-20, 6);
      ctx.closePath();
      ctx.fill();
      ctx.fillStyle = '#FFFFFF';
      ctx.beginPath();
      ctx.arc(6, -4, 4, 0, 6.28318);
      ctx.fill();
      ctx.fillStyle = '#111111';
      ctx.beginPath();
      ctx.arc(7, -4, 2, 0, 6.28318);
      ctx.fill();
      ctx.restore();
    }
  }

  /**
   * 绘制角色身体（脚底为原点，沿用上一版可爱方块风格，按角色换色）
   */
  private drawCharacterBody(ctx: CanvasRenderingContext2D, ch: number): void {
    const col = charColorsOf(ch);
    const isPeach = ch === CharacterId.PEACH;
    const isBowser = ch === CharacterId.BOWSER;
    // 腿
    ctx.fillStyle = col.body;
    ctx.fillRect(-8, -8, 7, 8);
    ctx.fillRect(1, -8, 7, 8);
    // 鞋
    ctx.fillStyle = col.shoe;
    ctx.fillRect(-9, -1, 9, 4);
    ctx.fillRect(0, -3, 9, 4);
    // 身体（背带裤/裙/龟壳）
    ctx.fillStyle = col.body;
    ctx.fillRect(-9, -20, 18, 12);
    // 上衣
    ctx.fillStyle = col.shirt;
    ctx.fillRect(-9, -14, 18, 4);
    // 背带（公主/酷霸王不画背带）
    if (!isPeach && !isBowser) {
      ctx.fillStyle = col.body;
      ctx.fillRect(-7, -20, 3, 12);
      ctx.fillRect(4, -20, 3, 12);
      ctx.fillStyle = '#FFD700';
      ctx.fillRect(-6, -19, 2, 2);
      ctx.fillRect(4, -19, 2, 2);
    }
    // 手臂
    ctx.fillStyle = col.shirt;
    ctx.fillRect(-11, -19, 4, 8);
    ctx.fillRect(7, -19, 4, 8);
    ctx.fillStyle = col.skin;
    ctx.fillRect(-11, -12, 4, 3);
    ctx.fillRect(7, -12, 4, 3);
    // 头
    ctx.fillStyle = col.skin;
    ctx.fillRect(-8, -31, 16, 11);
    // 帽子/皇冠/龟壳头
    ctx.fillStyle = col.cap;
    ctx.fillRect(-8, -32, 16, 5);
    ctx.fillRect(-8, -27, 16, 3);
    ctx.fillStyle = col.capDark;
    ctx.fillRect(6, -32, 3, 5);
    ctx.fillStyle = col.cap;
    ctx.fillRect(6, -26, 6, 3);
    if (isBowser) {
      // 尖角
      ctx.fillStyle = '#F8F0E0';
      ctx.fillRect(4, -34, 2, 3);
      ctx.fillRect(10, -34, 2, 3);
    }
    if (isPeach) {
      // 皇冠宝石
      ctx.fillStyle = '#E83000';
      ctx.fillRect(0, -34, 3, 3);
    }
    // 眼睛
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(3, -26, 4, 5);
    ctx.fillStyle = '#222222';
    ctx.fillRect(5, -24, 2, 3);
    // 胡子（公主不画）
    if (!isPeach) {
      ctx.fillStyle = col.hair;
      ctx.fillRect(-6, -22, 12, 2);
      ctx.fillRect(-4, -20, 10, 2);
    }
  }

  /** 诊断：drawPlayer 命中/被闪烁跳过的次数（移植版新增） */
  dbgDraw: number = 0;
  dbgSkip: number = 0;

  private drawPlayer(ctx: CanvasRenderingContext2D): void {
    this.dbgDraw++;
    const p = this.player;
    if (p.invincible > 0 && Math.floor(this.globalT * 12) % 2 === 0) {
      this.dbgSkip++;
      return; // 无敌闪烁
    }
    ctx.save();
    ctx.translate(p.x + p.w / 2, p.y + p.h);
    ctx.scale(p.facing, p.big ? 1.45 : 1); // 大角色：以脚底为原点整体拉高，脚始终着地
    this.drawCharacterBody(ctx, p.character);
    ctx.restore();
  }

  private drawParticles(ctx: CanvasRenderingContext2D): void {
    for (let i = 0; i < this.particles.length; i++) {
      const p = this.particles[i];
      ctx.globalAlpha = Math.max(0, 1 - p.t / p.life);
      if (p.kind === 0) {
        ctx.fillStyle = '#C84C0C';
        ctx.fillRect(p.x, p.y, p.size, p.size);
      } else if (p.kind === 1) {
        ctx.fillStyle = 'rgba(255,255,255,0.9)';
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.size, 0, 6.28318);
        ctx.fill();
      } else if (p.kind === 2) {
        ctx.fillStyle = '#FFD700';
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.size, 0, 6.28318);
        ctx.fill();
      } else {
        // 气泡
        ctx.strokeStyle = 'rgba(255,255,255,0.8)';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.size, 0, 6.28318);
        ctx.stroke();
      }
    }
    ctx.globalAlpha = 1;
  }

  private drawPopups(ctx: CanvasRenderingContext2D): void {
    for (let i = 0; i < this.popups.length; i++) {
      const p = this.popups[i];
      ctx.globalAlpha = Math.max(0, 1 - p.t / p.life);
      ctx.fillStyle = p.color;
      ctx.font = 'bold 14px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText(p.text, p.x, p.y);
      ctx.textAlign = 'left';
      ctx.globalAlpha = 1;
    }
  }

  private measure(ctx: CanvasRenderingContext2D, text: string): number {
    return ctx.measureText(text).width;
  }

  private drawHud(ctx: CanvasRenderingContext2D, w: number): void {
    ctx.font = 'bold 18px sans-serif';
    ctx.textBaseline = 'top';
    const world = Math.floor(this.levelIndex / 4) + 1;
    const stage = (this.levelIndex % 4) + 1;
    const line1 = 'WORLD ' + world + '-' + stage + '  ' + this.padScore(this.score);
    const line2 = 'COINS x' + this.pad2(this.coinCount) + '  LIVES ' + this.lives;
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(6, 7, this.measure(ctx, line1) + 14, 24);
    ctx.fillRect(6, 31, this.measure(ctx, line2) + 14, 24);
    ctx.fillStyle = '#FFFFFF';
    ctx.fillText(line1, 13, 8);
    ctx.fillText(line2, 13, 32);
    const t = Math.max(0, Math.ceil(this.levelTime));
    const ts = 'TIME ' + t;
    const tw = this.measure(ctx, ts) + 14;
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(w - tw - 8, 7, tw, 24);
    ctx.fillStyle = t <= 50 ? '#FF5555' : '#FFFFFF';
    ctx.fillText(ts, w - this.measure(ctx, ts) - 13, 8);
    ctx.textBaseline = 'alphabetic';
  }

  private padScore(v: number): string {
    let s = '' + v;
    while (s.length < 6) {
      s = '0' + s;
    }
    return s;
  }

  private pad2(v: number): string {
    let s = '' + v;
    while (s.length < 2) {
      s = '0' + s;
    }
    return s;
  }

  private drawTitle(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    ctx.fillStyle = 'rgba(0,0,0,0.35)';
    ctx.fillRect(0, 0, w, h);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 54px sans-serif';
    ctx.fillStyle = '#FFD700';
    ctx.fillText('SUPER MARIO', w / 2, h * 0.22);
    ctx.fillStyle = '#FF5A3C';
    ctx.font = 'bold 30px sans-serif';
    ctx.fillText('鸿蒙 ArkTS 版', w / 2, h * 0.22 + 48);
    ctx.fillStyle = '#FFFFFF';
    ctx.font = 'bold 20px sans-serif';
    ctx.fillText('按 Enter 开始 / 点击屏幕开始', w / 2, h * 0.5);
    ctx.font = '16px sans-serif';
    ctx.fillStyle = '#E8E8E8';
    ctx.fillText('← → / A D 移动    空格 / W / ↑ 跳跃（空中可二段跳）', w / 2, h * 0.5 + 34);
    ctx.fillText('Shift / X 加速    ↓ / S 进水管    P / Esc 暂停', w / 2, h * 0.5 + 58);
    ctx.fillStyle = '#7CFC00';
    ctx.fillText('手机端请使用屏幕左下十字键 / 右下动作键', w / 2, h * 0.5 + 92);
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
  }

  private drawCharSelect(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    ctx.fillStyle = '#1A2A5A';
    ctx.fillRect(0, 0, w, h);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 34px sans-serif';
    ctx.fillStyle = '#FFD700';
    ctx.fillText('选 择 角 色', w / 2, h * 0.14);
    for (let i = 0; i < 3; i++) {
      const cx = w / 2 + (i - 1) * (w * 0.22);
      const cy = h * 0.52;
      const sel = i === this.charSel;
      if (sel) {
        ctx.fillStyle = 'rgba(255,215,0,0.18)';
        ctx.fillRect(cx - 66, cy - 90, 132, 190);
        ctx.strokeStyle = '#FFD700';
        ctx.lineWidth = 4;
        ctx.strokeRect(cx - 66, cy - 90, 132, 190);
      }
      ctx.save();
      ctx.translate(cx, cy + 34);
      ctx.scale(1.5, 1.7);
      this.drawCharacterBody(ctx, i);
      ctx.restore();
      ctx.font = 'bold 20px sans-serif';
      ctx.fillStyle = sel ? '#FFD700' : '#FFFFFF';
      ctx.fillText(CHARACTER_NAMES[i], cx, cy + 70);
    }
    ctx.font = '18px sans-serif';
    ctx.fillStyle = '#E8E8E8';
    ctx.fillText('← → 选择    Enter / 空格 确认', w / 2, h * 0.86);
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
  }

  private drawPaused(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    ctx.fillStyle = 'rgba(0,0,0,0.5)';
    ctx.fillRect(0, 0, w, h);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 40px sans-serif';
    ctx.fillStyle = '#FFFFFF';
    ctx.fillText('暂 停', w / 2, h / 2 - 10);
    ctx.font = '18px sans-serif';
    ctx.fillText('P / Esc 或点击右上暂停按钮继续', w / 2, h / 2 + 30);
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
  }

  private drawGameOver(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    ctx.fillStyle = 'rgba(0,0,0,0.6)';
    ctx.fillRect(0, 0, w, h);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 46px sans-serif';
    ctx.fillStyle = '#FF5555';
    ctx.fillText('GAME OVER', w / 2, h * 0.4);
    ctx.font = '22px sans-serif';
    ctx.fillStyle = '#FFFFFF';
    ctx.fillText('最终得分  ' + this.score, w / 2, h * 0.4 + 46);
    ctx.fillText('按 Enter 或点击屏幕重新开始', w / 2, h * 0.6);
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
  }

  private drawWin(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(0, 0, w, h);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    const world = Math.floor(this.levelIndex / 4) + 1;
    const stage = (this.levelIndex % 4) + 1;
    ctx.font = 'bold 44px sans-serif';
    ctx.fillStyle = '#7CFC00';
    ctx.fillText('STAGE CLEAR!', w / 2, h * 0.35);
    ctx.font = '22px sans-serif';
    ctx.fillStyle = '#FFFFFF';
    ctx.fillText('世界 ' + world + '-' + stage + ' 过关   得分 ' + this.score + '   金币 x' + this.coinCount +
      '   生命 ' + this.lives, w / 2, h * 0.35 + 50);
    if (this.levelIndex < TOTAL_LEVELS - 1) {
      ctx.fillText('按 Enter 或点击屏幕进入下一关', w / 2, h * 0.6);
    } else {
      ctx.fillText('恭喜通关全部 4 大世界！按 Enter 返回主菜单', w / 2, h * 0.6);
    }
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
  }
}
