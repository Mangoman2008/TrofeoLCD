/**
 * MarioDemo.ets —— 超级玛丽演示版（VM 面板 / 全屏主题共用）
 *
 * 来源：本机 `~/WorkBuddy/SuperMario`（ArkTS 版超级玛丽，16 关）。
 * 那边是给手机/PC 用键盘或虚拟键玩的；这块 USB 副屏是**输出-only**，
 * 没有输入设备，所以这里做**自动驾驶**。
 *
 * ── 自动驾驶策略 ──────────────────────────────────────────
 *   · 坑 / 墙：满高度跳（按住 JUMP 约 0.25s）
 *   · **敌人：矮跳去踩**（只按约 0.07s，靠 JUMP_CUT 压低弧线，落点正好在它头上）
 *   · 卡住超过 1.2s：补一次满高度跳
 *   判断依据是 `Game.hazardAhead()`（移植版新增），它区分 坑/墙/敌人。
 *
 * ── 视口 ────────────────────────────────────────────────
 *   `draw()` 支持传入逻辑视口尺寸。这块屏是 1920×462（4.16:1），
 *   用 **640×154** 的逻辑视口 + **×3 整数放大**就能铺满且**零拉伸、零黑边** ——
 *   游戏本来就把 (w,h) 当"可视世界范围"，所以它只是看到了更宽的一条关卡切片。
 */

import { SuperMarioGame, HAZARD_ENEMY, HAZARD_PIT, HAZARD_WALL } from './Game.ts';
import { InputManager } from './Input.ts';
import { SoundManager } from './Audio.ts';
import { GameAction } from './Types.ts';

/** 默认逻辑视口（喂给 VM 面板时用，NES 比例） */
const VIEW_W: number = 320;
const VIEW_H: number = 240;
/** 单帧最大步进（秒） */
const MAX_DT: number = 0.25;
/** 物理子步（秒）：屏幕只有 ~4fps，必须细分才能正确判断与碰撞 */
const SUB_DT: number = 1 / 60;
/**
 * 时间缩放：游戏按真实 60fps 设计，而这块屏只有 ~5fps ——
 * 一次跳跃 0.6s 只显示约 3 帧，看起来"又快又远"（用户反馈）。
 * 放慢到 0.6× 后，一次跳跃跨 ~5 帧，观感接近原版的从容感。
 * 注意：物理是 dt 驱动的，缩放只改观感节奏，不改"每格多少像素"的比例。
 */
const TIME_SCALE: number = 0.6;
/** 点按"开始"的间隔 */
const TAP_START_MS: number = 800;
/** 卡住多久补跳一次 */
const STUCK_JUMP_MS: number = 1200;
/** x 多久没前进就判定为"卡住"（门槛更低、更积极） */
const PROGRESS_STALL_MS: number = 260;
/** 连续跳跃的最小间隔（防止每帧都起跳把动作糊在一起） */
const JUMP_COOLDOWN_MS: number = 240;
/** 水下：多久给一次上浮（太密会一直飘到天花板） */
const WATER_HOP_MS: number = 900;

/**
 * 满高度跳按住的子步数。
 * ★ 必须覆盖**整个上升段**：v=720 / g=2400 → 到顶点要 0.3s。
 *   原来只按 15 步（0.25s）就松手，触发 JUMP_CUT 把高度砍掉一截，
 *   实测后果是翻不过 3 格高的水管（越顶时间不够往前挪）。
 *   22 步 ≈ 0.37s > 0.3s → 全程不 cut，能到最高点。
 */
const JUMP_STEPS_FULL: number = 32;   // 0.53s 墙面时间 × TIME_SCALE 0.6 ≈ 0.32s 游戏时间 > 上升 0.29s
/** 踩敌人的矮跳（4 × 1/60 ≈ 0.067s，靠 JUMP_CUT 压成小跳） */
const JUMP_STEPS_HOP: number = 4;

export class MarioDemo {
  private game: SuperMarioGame | null = null;
  private input: InputManager = new InputManager();
  private sound: SoundManager = new SoundManager();
  private lastMs: number = 0;
  private startTapAt: number = 0;
  private jumpTapAt: number = 0;
  /** 本帧还要按住 JUMP 的子步数 */
  private jumpStepsLeft: number = 0;
  /** 上次"有进展"的 x（用于识别卡在台阶/水管前） */
  private lastProgX: number = -1;
  private lastProgAt: number = 0;
  /** 已推进帧数（进内容签名用） */
  frame: number = 0;

  screen(): string {
    return this.game === null ? 'none' : this.game.getScreenName();
  }

  /** 诊断用：玩家/相机/绘制计数 */
  playerInfo(): string {
    if (this.game === null) {
      return '';
    }
    const a: number[] = this.game.playerPos();
    return `p=(${a[0].toFixed(0)},${a[1].toFixed(0)}) cam=(${a[4].toFixed(0)},${a[5].toFixed(0)})` +
      ` draw=${a[6]} skip=${a[7]} t=${a[9].toFixed(0)}s` +
      ` score=${a[10]} lives=${a[11]} coins=${a[12]} goom=${a[13]}` +
      ` 死${a[14]} 救回${a[17]} 第${a[18]}关 助推${a[19]} ||${this.game.terrainInfo()}`;
  }

  private ensure(nowMs: number, viewW: number, viewH: number): SuperMarioGame {
    if (this.game === null) {
      this.game = new SuperMarioGame(this.input, this.sound, viewW, viewH);
      // 副屏演示：无限命（死了立刻重生、分数不清零）
      this.game.demoInfiniteLives = true;
      this.lastMs = nowMs;
    }
    return this.game;
  }

  /** 推进一帧（内部按 60Hz 分步；画面仍是一帧一次） */
  step(nowMs: number, viewW: number = VIEW_W, viewH: number = VIEW_H): void {
    const game: SuperMarioGame = this.ensure(nowMs, viewW, viewH);
    let dt: number = (nowMs - this.lastMs) / 1000;
    if (dt <= 0 || dt > MAX_DT) {
      dt = (dt > MAX_DT) ? MAX_DT : SUB_DT;
    }
    this.lastMs = nowMs;

    // ★ 这里**不能**把 jumpStepsLeft 清零（曾经有这一行，是个真 bug）：
    //   一帧只有约 15 个子步（0.25s），而满高度跳需要按住 0.37s，
    //   每帧清零就等于永远按不到 0.37s → JUMP_CUT 一直生效 → 翻不过 3 格高的水管。
    //   让它自然递减到 0，按键状态就能跨帧延续。
    let acc: number = dt;
    let guard: number = 0;
    while (acc > 0.0001 && guard < 40) {
      const h: number = (acc > SUB_DT) ? SUB_DT : acc;
      acc -= h;
      guard++;
      this.autopilot(game, nowMs);
      game.update(h * TIME_SCALE);
      this.input.endFrame();
    }
    this.frame++;
  }

  /** 自动驾驶：该按什么 */
  private autopilot(game: SuperMarioGame, nowMs: number): void {
    this.input.virtualUp(GameAction.START);
    // JUMP 按"还要按住多少子步"来决定
    if (this.jumpStepsLeft > 0) {
      this.input.virtualDown(GameAction.JUMP);
      this.jumpStepsLeft--;
    } else {
      this.input.virtualUp(GameAction.JUMP);
    }

    const sc: string = game.getScreenName();
    if (sc === 'title' || sc === 'charselect' || sc === 'over' || sc === 'win') {
      this.input.virtualUp(GameAction.RIGHT);
      if (nowMs - this.startTapAt >= TAP_START_MS) {
        this.startTapAt = nowMs;
        this.input.virtualDown(GameAction.START);
      }
      return;
    }
    if (sc !== 'playing') {
      return;
    }

    this.input.virtualDown(GameAction.RIGHT);

    // ★ 水下关单独策略：这里"跳"等于**向上游**。
    //   如果沿用陆地的"落地就跳"，人会一路顶着天花板飘（实测"人都飘起来了，有点假"）。
    //   改成：偶尔给一次短促上浮，主要靠按住右键横着游。
    if (game.isWaterLevel()) {
      if (nowMs - this.jumpTapAt >= WATER_HOP_MS) {
        this.jumpTapAt = nowMs;
        this.jumpStepsLeft = JUMP_STEPS_HOP;
      }
      return;
    }

    // 已经在跳的过程中不要重复触发
    if (this.jumpStepsLeft > 0) {
      return;
    }

    // ★ 用传感器精确定时（实测：原来敌人 26px 才跳，人到跟前已经来不及，侧撞死）
    const s: number[] = game.demoSense();
    const onGround: boolean = s[0] === 1;
    const pitDist: number = s[1];     // 前方地面还剩多少 px
    const gap: number = s[2];         // 前方坑宽（格）
    const enemyDist: number = s[3];   // 正前方敌人距离 px
    const enemySameRow: boolean = s[4] === 1;
    const wallDist: number = (s.length > 5) ? s[5] : 9999;

    // 空中不跳（跳了也没用，浪费下一次）
    if (!onGround) {
      return;
    }
    // ★ 演示模式下**一直按住加速**：跑起来跳得更远、更容易越过水管和宽坑。
    //   （侧撞已经宽容化，跑快不会因为撞敌人而死）
    this.input.virtualDown(GameAction.RUN);
    if (gap > 0 && pitDist <= 26) {
      this.jumpTapAt = nowMs;
      this.jumpStepsLeft = JUMP_STEPS_FULL;
      return;
    }
    // ①b 墙壁/水管：一旦探到就立刻满跳（水管是硬障碍，等着不动只会卡住）
    if (wallDist <= 24) {
      this.jumpTapAt = nowMs;
      this.jumpStepsLeft = JUMP_STEPS_FULL;
      return;
    }
    // ② 敌人：提前 46px 起跳 —— 弧线顶点越过它、下落时正好落在它头上（踩）
    if (enemySameRow && enemyDist > 0 && enemyDist <= 46) {
      this.jumpTapAt = nowMs;
      this.jumpStepsLeft = JUMP_STEPS_HOP;
      return;
    }
    // ★ 不要连跳。实测连跳会把水平速度压在 1700（空中加速度）以下，
    //   而地面加速度是 2600 —— 连跳等于永远跑不满速、跳得短，
    //   结果频繁掉坑（19 分钟内被救回 307 次）。改成**只在需要时跳**，
    //   中间给他足够的地面时间把速度拉起来。
    // ③ 被台阶/水管卡住：x 连续 0.5s 没前进就再跳一次（比 1.2s 定时更积极）
    const px: number = this.game !== null ? this.game.playerPos()[0] : 0;
    if (px > this.lastProgX + 3) {
      this.lastProgX = px;
      this.lastProgAt = nowMs;
    } else if (nowMs - this.lastProgAt >= PROGRESS_STALL_MS) {
      this.lastProgAt = nowMs;
      this.jumpTapAt = nowMs;
      this.jumpStepsLeft = JUMP_STEPS_FULL;
      return;
    }
    // ④ 兜底：长时间没跳就补一跳
    if (nowMs - this.jumpTapAt >= STUCK_JUMP_MS) {
      this.jumpTapAt = nowMs;
      this.jumpStepsLeft = JUMP_STEPS_FULL;
    }
  }

  /**
   * 画到目标矩形。
   * @param viewW/viewH 逻辑视口（世界像素）。传入与目标矩形同比例的数值时，
   *                    就是**填满且零拉伸**；传默认 320×240 则两侧留黑边。
   */
  draw(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
       nowMs: number, viewW: number = VIEW_W, viewH: number = VIEW_H): void {
    const game: SuperMarioGame = this.ensure(nowMs, viewW, viewH);
    const k: number = Math.min(w / viewW, h / viewH);
    const dw: number = viewW * k;
    const dh: number = viewH * k;
    const ox: number = x + (w - dw) / 2;
    const oy: number = y + (h - dh) / 2;

    ctx.fillStyle = '#000000';
    ctx.fillRect(x, y, w, h);

    ctx.save();
    ctx.beginPath();
    ctx.rect(ox, oy, dw, dh);
    ctx.clip();
    ctx.translate(ox, oy);
    ctx.scale(k, k);
    game.render(ctx, viewW, viewH);
    ctx.restore();
  }

  /**
   * 全屏版：按屏幕真实比例算逻辑视口，**整数倍缩放**铺满（无黑边、无拉伸）。
   *
   * ★ 竖向能看到多少内容，完全由"缩放倍率"决定（视口必须满足 VH = VW×h/w）：
   *     ×3 → 640×154 → 竖向 **4.8 格**（TILE=32），太挤（用户反馈"竖向内容太少"）
   *     ×2 → 960×231 → 竖向 **7.2 格** ← 默认，内容多 50% 且仍是整数缩放
   *     ×1 → 1920×462 → 14.4 格，但玛丽只有 32px 高，太小
   *   用 /set?mview=N 切换。
   */
  static viewScale: number = 2;

  drawFullscreen(ctx: CanvasRenderingContext2D, w: number, h: number, nowMs: number): void {
    const k: number = (MarioDemo.viewScale >= 1 && MarioDemo.viewScale <= 4)
      ? Math.round(MarioDemo.viewScale) : 2;
    const viewW: number = Math.round(w / k);
    const viewH: number = Math.round(h / k);
    this.step(nowMs, viewW, viewH);
    this.draw(ctx, 0, 0, w, h, nowMs, viewW, viewH);
  }
}
