import { Chrome } from './Chrome.ts';
/**
 * ThemePong.ets —— 主题 4「打砖块」（B 线：源固件 clock_pong 的 1:1 复刻）
 *
 * 来源（逐条照抄，不改设计）：
 *   ~/Documents/拓竹P2S开发/bambu-zh/src/clock_pong.cpp      ← 物理、绘制顺序、砖色
 *   ~/Documents/拓竹P2S开发/bambu-zh/include/layout_368x448.h ← 版面常量（BOARD_IS_AMOLED18 档）
 *   ~/Documents/Dotii-368x448/dotii-ui-sim.html:215 ringSVG / :297 bambuHTML ← 页面框架
 *
 * 源画布 368×448，本屏 1920×462 → 中间那块 448 高正好放得下：
 *   因 462 − 448 = 14，所以整体取 **448×448 的画布，四周各留 7 行黑边**，
 *   源版面一个像素不缩（地板坐标 462 会伸到画布外 → 按设计压到 446，见 kPaddleY）。
 *   居中偏移 ox = (1920 − 368) / 2 = 776，oy = 7。
 *
 * ★ 关键设计：**渲染是纯函数 + 确定性随机**（state.rand 是自己实现的 LCG，不用 Math.random）。
 *   所以同一份 state 重复渲染逐像素一致，可以用假时钟离线跑几千帧做断言（见 tools/pong_check.mjs）。
 */

/** 源版面常量（layout_368x448.h:410-427，AMOLED18 档） */
const kCanvasW: number = 368;      // 源画布宽
const kCanvasH: number = 448;      // 源画布高
const kBrickRows: number = 5;      // LY_ARK_BRICK_ROWS
const kBrickCols: number = 9;      // LY_ARK_COLS
const kBrickW: number = 36;        // LY_ARK_BRICK_W
const kBrickH: number = 17;        // LY_ARK_BRICK_H
const kBrickGap: number = 2;       // LY_ARK_BRICK_GAP
const kBrickStartX: number = 5;    // LY_ARK_START_X
const kBrickStartY: number = 40;   // LY_ARK_START_Y
const kPaddleW: number = 72;       // LY_ARK_PADDLE_W
const kTimeY: number = 204;        // LY_ARK_TIME_Y
const kDateY: number = 10;         // LY_ARK_DATE_Y
const kDigitW: number = 44;        // LY_ARK_DIGIT_W
const kDigitH: number = 68;        // LY_ARK_DIGIT_H
const kColonW: number = 16;        // LY_ARK_COLON_W
const kDateClrW: number = 256;     // LY_ARK_DATE_CLR_W

/**
 * 地板/挡板 Y。源值 430 是给 448 高画的，但挡板厚 5 → 430+5 = 435，
 * 而我们只有 448 高、还要给底部留出边距，所以压到 430 原值不动
 * （430 + 5 = 435 ≤ 448，够用；用户若是要改，改这一行即可）。
 */
const kPaddleY: number = 430;

/** 玩法常量（clock_pong.cpp:36-80，AMOLED18 档） */
const kBallSize: number = 20;        // ARK_BALL_SIZE（240 基准 4px 的 5 倍）
const kPaddleH: number = 5;          // ARK_PADDLE_H
const kBallSpeed: number = 12.0;     // px/tick
const kPaddleSpeed: number = 14;     // px/tick
const kTickMs: number = 20;          // ARK_UPDATE_MS ≈ 50fps
const kPaddleJitterDeg: number = 4.0;
const kStickyJitterDeg: number = 10.0;
const kStickyMs: number = 120;
const kStickyTrigger: number = 4;
const kResetAfterMisses: number = 20;

/**
 * 砖色（clock_pong.cpp:93-99，行序 红/橙/黄/绿/蓝）。
 *
 * ★ 已做 JPEG 4:2:0 预补偿：固件原值是纯 RGB565（#FF0000 / #FFA500 / #FFFF00 /
 *   #00FF00 / #0000FF），但本机编码器是 4:2:0 色度抽样 —— 实测**纯蓝解码后几乎归零**
 *   （屏上蓝砖像素 0）、纯绿掉一半。所以这里与 ThemeFwSim 的砖色**保持同一套补偿值**，
 *   否则同一种玩法在两个主题里颜色不一致。
 *   固件原值 → 补偿后：红 #F01010 / 橙 #F0A018 / 黄 #F0E828 / 绿 #20E020 / 蓝 #3A55E0
 */
const kBrickColors: string[] = ['#F01010', '#F0A018', '#F0E828', '#20E020', '#3A55E0'];

/** 时间总宽 = 4×44 + 16 = 192（clock_pong.cpp:32） */
const kTimeTotalW: number = 4 * kDigitW + kColonW;

export class PongState {
  /** 已推进的 tick 数（每 tick = kTickMs） */
  tick: number = 0;
  /** 确定性随机种子（LCG 状态） */
  rand: number = 12345;
  /** 砖块存活表 [row][col] */
  bricks: boolean[][] = [];
  ballX: number = 0;
  ballY: number = 0;
  ballVX: number = 0;
  ballVY: number = 0;
  ballActive: boolean = false;
  stuck: boolean = false;
  stickyHit: number = 0.5;
  stickyUntilTick: number = 0;
  paddleX: number = kCanvasW / 2;
  misses: number = 0;
  /** 左侧栏用的战况统计 */
  bricksBroken: number = 0;
  paddleHits: number = 0;
  bestCombo: number = 0;
  /** 当前连击（碰挡板清零，砸砖 +1） */
  combo: number = 0;
  /** 重开次数（空挡 20 次或砖清空） */
  resets: number = 0;
  /** 展示用时间（源：分钟跳字那套，这里用真实时钟驱动） */
  hour: number = 0;
  minute: number = 0;
  second: number = 0;
  use24h: boolean = true;
  dateText: string = '';
}

// ---------------------------------------------------------------------------
// 确定性随机（LCG，Numerical Recipes 参数）—— 不用 Math.random，保证可复现
// ---------------------------------------------------------------------------
function rnd(st: PongState): number {
  st.rand = (st.rand * 1664525 + 1013904223) % 4294967296;
  return st.rand / 4294967296;
}

/** 等价 Arduino random(max)：[0, max) 整数 */
function randInt(st: PongState, max: number): number {
  return Math.floor(rnd(st) * max) % max;
}

/** 等价 Arduino random(min, max)：[min, max) 整数 */
function randRange(st: PongState, min: number, max: number): number {
  return min + randInt(st, max - min);
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : (v > hi ? hi : v);
}

// ---------------------------------------------------------------------------
// 状态构建
// ---------------------------------------------------------------------------

/** 新建一局（源 initBricks() + spawnBall()，clock_pong.cpp:249-259 / 330-335） */
export function pongInit(seed: number): PongState {
  const st = new PongState();
  st.rand = (Math.abs(Math.floor(seed)) % 4294967295) + 1;
  st.tick = 0;
  st.paddleX = kCanvasW / 2;
  st.misses = 0;
  st.bricks = [];
  for (let r = 0; r < kBrickRows; r++) {
    const row: boolean[] = [];
    for (let c = 0; c < kBrickCols; c++) {
      row.push(true);
    }
    st.bricks.push(row);
  }
  pongSpawnBall(st);
  return st;
}

/** 铺满砖块（源 initBricks，clock_pong.cpp:249-259） */
function resetBricks(st: PongState): void {
  for (let r = 0; r < kBrickRows; r++) {
    for (let c = 0; c < kBrickCols; c++) {
      st.bricks[r][c] = true;
    }
  }
}

/** 从挡板发射（源 launchBallFromPaddle，clock_pong.cpp:289-308） */
function launch(st: PongState, hit: number, jitterDeg: number): void {
  const h = clamp(hit, 0.08, 0.92);
  st.ballX = st.paddleX - kPaddleW / 2 + h * kPaddleW - kBallSize / 2;
  st.ballY = kPaddleY - kBallSize;

  let angleDeg = 150.0 - h * 120.0 + jitterDeg;
  angleDeg = clamp(angleDeg, 30.0, 150.0);
  const angle = angleDeg * Math.PI / 180.0;

  st.ballVX = kBallSpeed * Math.cos(angle);
  st.ballVY = -kBallSpeed * Math.sin(angle);
  if (Math.abs(st.ballVX) < 1.2) {
    st.ballVX = st.ballVX >= 0 ? 1.2 : -1.2;
  }
  if (Math.abs(st.ballVY) < 1.0) {
    st.ballVY = -1.5;
  }
  st.ballActive = true;
  st.stuck = false;
  st.stickyUntilTick = 0;
}

/** 中点 + ±5° 随机重发（源 spawnBall，clock_pong.cpp:330-335） */
function pongSpawnBall(st: PongState): void {
  st.stuck = false;
  st.stickyUntilTick = 0;
  launch(st, 0.5, randRange(st, -50, 51) / 10.0);
  st.misses = 0;
}

/** 连击容错：粘球辅助（源 shouldUseStickyAssist，clock_pong.cpp:310-315） */
function useSticky(st: PongState): boolean {
  if (st.misses < kStickyTrigger) {
    return false;
  }
  let chance = 15 + (st.misses - kStickyTrigger) * 10;
  if (chance > 70) {
    chance = 70;
  }
  return randInt(st, 100) < chance;
}

/** 把球粘到挡板上（源 stickBallToPaddle，clock_pong.cpp:317-328） */
function stick(st: PongState, hit: number): void {
  const off = randRange(st, -18, 19) / 100.0;
  st.stickyHit = clamp(hit + off, 0.18, 0.82);
  st.stuck = true;
  st.stickyUntilTick = st.tick + Math.round(kStickyMs / kTickMs);
  st.ballActive = true;
  st.ballVX = 0;
  st.ballVY = 0;
  st.ballX = st.paddleX - kPaddleW / 2 + st.stickyHit * kPaddleW - kBallSize / 2;
  st.ballY = kPaddleY - kBallSize;
}

/** 砖块碰撞（源 checkBrickCollision，clock_pong.cpp:442-474） */
function checkBricks(st: PongState): boolean {
  const bx = Math.floor(st.ballX);
  const by = Math.floor(st.ballY);
  let hitX = false;
  let hitY = false;
  let hit = false;
  for (let r = 0; r < kBrickRows; r++) {
    for (let c = 0; c < kBrickCols; c++) {
      if (!st.bricks[r][c]) {
        continue;
      }
      const rx = kBrickStartX + c * (kBrickW + kBrickGap);
      const ry = kBrickStartY + r * (kBrickH + kBrickGap);
      if (bx + kBallSize > rx && bx < rx + kBrickW && by + kBallSize > ry && by < ry + kBrickH) {
        st.bricks[r][c] = false;
        st.bricksBroken++;
        st.combo++;
        if (st.combo > st.bestCombo) {
          st.bestCombo = st.combo;
        }
        const oL = (bx + kBallSize) - rx;
        const oR = (rx + kBrickW) - bx;
        const oT = (by + kBallSize) - ry;
        const oB = (ry + kBrickH) - by;
        if (Math.min(oL, oR) < Math.min(oT, oB)) {
          hitX = true;
        } else {
          hitY = true;
        }
        hit = true;
      }
    }
  }
  if (hitX) {
    st.ballVX = -st.ballVX;
  }
  if (hitY) {
    st.ballVY = -st.ballVY;
  }
  if (hit) {
    // 把球推出砖区，避免下一帧重复碰撞（源 468-472）
    st.ballX += st.ballVX;
    st.ballY += st.ballVY;
    st.misses = 0;
  }
  return hit;
}

function bricksLeft(st: PongState): number {
  let n = 0;
  for (let r = 0; r < kBrickRows; r++) {
    for (let c = 0; c < kBrickCols; c++) {
      if (st.bricks[r][c]) {
        n++;
      }
    }
  }
  return n;
}

/** 挡板追踪（源 updatePaddle，clock_pong.cpp:420-439） */
function updatePaddle(st: PongState): void {
  if (st.stuck) {
    return;
  }
  let target: number;
  if (st.ballActive && st.ballVY > 0) {
    target = Math.floor(st.ballX + kBallSize / 2);
  } else {
    target = Math.floor(kCanvasW / 2);
  }
  const diff = target - st.paddleX;
  if (Math.abs(diff) > 2) {
    const step = Math.min(kPaddleSpeed, Math.abs(diff));
    st.paddleX += diff > 0 ? step : -step;
  }
  st.paddleX = clamp(st.paddleX, kPaddleW / 2, kCanvasW - kPaddleW / 2);
}

/** 球的物理（源 updateBallPhysics，clock_pong.cpp:477-527） */
function updateBall(st: PongState): void {
  if (!st.ballActive) {
    return;
  }
  if (st.stuck) {
    st.ballX = st.paddleX - kPaddleW / 2 + st.stickyHit * kPaddleW - kBallSize / 2;
    st.ballY = kPaddleY - kBallSize;
    if (st.tick >= st.stickyUntilTick) {
      const jitter = randRange(st, -Math.round(kStickyJitterDeg * 10),
        Math.round(kStickyJitterDeg * 10) + 1) / 10.0;
      launch(st, st.stickyHit, jitter);
    }
    return;
  }

  st.ballX += st.ballVX;
  st.ballY += st.ballVY;

  if (st.ballX <= 0) {
    st.ballX = 0;
    st.ballVX = Math.abs(st.ballVX);
  }
  if (st.ballX >= kCanvasW - kBallSize) {
    st.ballX = kCanvasW - kBallSize;
    st.ballVX = -Math.abs(st.ballVX);
  }
  if (st.ballY <= 0) {
    st.ballY = 0;
    st.ballVY = Math.abs(st.ballVY);
  }

  // 挡板碰撞
  if (st.ballVY > 0 && st.ballY + kBallSize >= kPaddleY && st.ballY < kPaddleY + kPaddleH) {
    const pL = st.paddleX - kPaddleW / 2;
    const pR = st.paddleX + kPaddleW / 2;
    if (st.ballX + kBallSize >= pL && st.ballX <= pR) {
      const hit = (st.ballX + kBallSize / 2.0 - pL) / kPaddleW;
      st.misses++;
      st.paddleHits++;
      st.combo = 0;
      if (useSticky(st)) {
        stick(st, hit);
      } else {
        const jitter = randRange(st, -Math.round(kPaddleJitterDeg * 10),
          Math.round(kPaddleJitterDeg * 10) + 1) / 10.0;
        launch(st, hit, jitter);
      }
      if (st.misses >= kResetAfterMisses) {
        st.misses = 0;
        st.resets++;
        resetBricks(st);
      }
    }
  }

  if (st.ballY > kCanvasH) {
    pongSpawnBall(st);
  }
  checkBricks(st);
  if (bricksLeft(st) <= 0) {
    st.resets++;
    resetBricks(st);
  }
}

/** 推进一个 tick（≈20ms） */
export function pongTick(st: PongState): void {
  st.tick++;
  updateBall(st);
  updatePaddle(st);
}

/**
 * 按真实经过时间推进（LcdService 每帧调一次）。
 * 单帧最多补 8 个 tick（160ms），防止卡顿后球瞬移穿过砖块。
 */
export function pongAdvance(st: PongState, dtMs: number): void {
  // ★ 上限从 8 放宽（审计 M12）：
  //   原来 8 tick 只为"防止长时间停顿后一次补太多"，但空闲档帧间隔是 500ms，
  //   8 tick 仅 160ms 游戏时间 → 打砖块只有 0.32× 速（慢动作）。
  //   现在 LcdService 会给打砖块临时压帧间隔到 66ms（≈3 tick/帧，速度正确），
  //   上限放到 32 tick（=640ms 游戏时间）作为**慢帧兜底**：
  //   即使某帧被拖到 500ms，也能按真实时间追平，不会退化成慢动作。
  //   dt 本身也做上限，避免长时间停顿（切主题/唤醒）后一次补上千步。
  const dtClamped = Math.max(0, Math.min(dtMs, 640));
  const need = Math.min(Math.floor(dtClamped / kTickMs), 32);
  for (let i = 0; i < need; i++) {
    pongTick(st);
  }
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

/** 数字 x 坐标（源 digitX，clock_pong.cpp:560-566） */
function digitX(i: number): number {
  const startX = (kCanvasW - kTimeTotalW) / 2;
  if (i < 2) {
    return startX + i * kDigitW;
  }
  if (i === 2) {
    return startX + 2 * kDigitW;
  }
  return startX + 2 * kDigitW + kColonW + (i - 3) * kDigitW;
}

/** 把源坐标平移到本屏：源画布 368×448 居中 */
/**
 * 游戏区缩放。
 *
 * 用户 2026-10-14 定「保留源尺寸 + 两侧信息栏」（方案 B），但纯 1:1（0.5369）时
 * 游戏只占屏宽 10.3%、两侧栏各 831px，中间那块显得太小。
 * 折中取 **0.9333 = (462 − 2×14) / 448 × 0.973** 中的「纵向撑满再留 16px 缝」：
 *   游戏区 343×418（占屏宽 17.9%），两侧栏各 758 —— 三栏终于站得住，
 *   而 0.9333 仍**接近 1:1**（砖块 33.6px、球 ⌀18.7），源版面比例一点没变。
 * 想回到纯 1:1：把 kScale 改成 1，再把 ox() 里的 kDrawW/kDrawH 换成 kCanvasW/kCanvasH。
 */
const kScale: number = 0.9333;
const kDrawW: number = kCanvasW * kScale;   // 343.5
const kDrawH: number = kCanvasH * kScale;   // 418.1

function ox(): number {
  return Math.round((1920 - kDrawW) / 2);
}
/** 游戏区上下留 16px 缝，整体竖向居中 */
function oy(): number {
  return Math.round((462 - kDrawH) / 2);
}

export class ThemePong {
  /** 主题名（App 里的按钮与 diag 用） */
  static readonly NAME: string = '打砖块';

  /** 画布逻辑尺寸（与 LyProtocol 的帧规格一致） */
  static readonly W: number = 1920;
  static readonly H: number = 462;
  /** 两侧信息栏宽度与边距（14 与其它主题一致） */
  static readonly M: number = 14;
  static readonly PANEL_W: number = 758;

  /**
   * 渲染一帧：中间是源固件的打砖块（368×448 原尺寸，不缩放），两侧是信息栏。
   *
   * 用户 2026-10-14 定：**保留源尺寸 + 两侧加信息栏**（方案 B）。
   * 源画布 368×448 在 1920×462 上只占 197.6×240.5 的屏像素（逻辑 368×448 × scaleX 0.5369），
   * 所以屏幕横向有近 1500px 是空的 —— 用两侧栏把它填成完整版面，游戏本身一个像素不缩。
   *
   * @param ctx     画布（逻辑坐标 1920×462）
   * @param st      游戏状态（调用方持有，每帧 pongAdvance 后传进来）
   * @param is24h   时间制式
   * @param fps     当前推帧速度（显示在左栏，便于判断球为什么"跳"）
   * @param renderMs 上帧渲染耗时
   */
  /**
   * 在**指定区域内**画游戏本体（砖块 / 球 / 挡板 / 格内时钟）。
   *
   * ★ 抽出来的目的：让打印机格的「打砖块槽」也能复用同一套画法，
   *   不必重抄一份几何（本项目已栽过两次「两套实现漂移」：
   *   printerSlot 与内容签名不一致、Dotii 页号漏出签名）。
   *
   * 坐标约定：调用方给出区域左上角与缩放 k，本方法内部做
   *   translate(ax, ay) + scale(k, k)，随后**按源坐标（368×448）绘制** ——
   *   所以下面每一行都与源固件 clock_pong.cpp 一一对应，不必逐点乘系数。
   *   游戏几何与物理常数因此**完全不用改**
   *   （用户要求：照搬源常数、保持 5 行 9 列）。
   */
  static drawGame(ctx: CanvasRenderingContext2D, st: PongState, is24h: boolean,
                          ax: number, ay: number, k: number): void {
    ctx.save();
    ctx.translate(ax, ay);
    ctx.scale(k, k);

        // ---------- 砖块（源 drawAllBricks / drawBrick，clock_pong.cpp:261-275）----------
        for (let r = 0; r < kBrickRows; r++) {
          for (let c = 0; c < kBrickCols; c++) {
            if (!st.bricks[r][c]) {
              continue;
            }
            const x = kBrickStartX + c * (kBrickW + kBrickGap);
            const y = kBrickStartY + r * (kBrickH + kBrickGap);
            ctx.fillStyle = kBrickColors[r % kBrickColors.length];
            ctx.fillRect(x, y, kBrickW, kBrickH);
            // 顶边 1px 白、底边 1px 黑（源的立体感）
            ctx.fillStyle = '#FFFFFF';
            ctx.fillRect(x, y, kBrickW, 1);
            ctx.fillStyle = '#000000';
            ctx.fillRect(x, y + kBrickH - 1, kBrickW, 1);
          }
        }

        // ---------- 球（源 drawBall，clock_pong.cpp:380-408：白色实心圆 ⌀20）----------
        if (st.ballActive) {
          ctx.beginPath();
          ctx.arc(st.ballX + kBallSize / 2, st.ballY + kBallSize / 2, kBallSize / 2, 0, Math.PI * 2);
          ctx.fillStyle = '#FFFFFF';
          ctx.fill();
        }

        // ---------- 挡板（源 drawPaddle，clock_pong.cpp:411-418：青条 + 顶边白线）----------
        const px = Math.round(st.paddleX - kPaddleW / 2);
        const py = kPaddleY;
        ctx.fillStyle = '#00FFFF';
        ctx.fillRect(px, py, kPaddleW, kPaddleH);
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(px, py, kPaddleW, 1);

        // ---------- 日期（源：居中，Font 2）----------
        if (st.dateText.length > 0) {
          ctx.textAlign = 'center';
          ctx.textBaseline = 'middle';
          ctx.fillStyle = '#E6EDF3';
          ctx.font = '20px monospace';
          ctx.fillText(st.dateText, kCanvasW / 2, kDateY + 8);
          ctx.textAlign = 'left';
        }

        // ---------- 时间（源 drawTime，clock_pong.cpp:568-666：Font 7 数码字，冒号闪）----------
        const showColon = (Date.now() % 1000) < 500;
        let hh: string;
        let ampm = '';
        if (is24h) {
          hh = ThemePong.pad2(st.hour);
        } else {
          const h12 = st.hour % 12 === 0 ? 12 : st.hour % 12;
          hh = ThemePong.pad2(h12);
          ampm = st.hour < 12 ? 'AM' : 'PM';
        }
        const digits: string[] = [hh.charAt(0), hh.charAt(1),
          showColon ? ':' : ' ', ThemePong.pad2(st.minute).charAt(0), ThemePong.pad2(st.minute).charAt(1)];

        // 比例缩放：让每个字符的**步进宽度正好等于 kDigitW**，
        // 这样数字既占满源版面格子（44px），又绝不会互相压字。
        const baseSize = 92;
        ctx.font = `bold ${baseSize}px monospace`;
        const adv = ctx.measureText('0').width;
        const fitSize = adv > 0 ? Math.floor(baseSize * kDigitW / adv) : baseSize;
        ctx.font = `bold ${fitSize}px monospace`;

        for (let i = 0; i < 5; i++) {
          const x = digitX(i);
          const y = kTimeY;
          if (i === 2) {
            // 冒号：居中方块，省掉字体依赖（源用 Font 7 的 ':'）
            if (showColon) {
              ctx.fillStyle = '#FFFFFF';
              ctx.fillRect(x + 4, y + 14, 8, 8);
              ctx.fillRect(x + 4, y + 44, 8, 8);
            }
            continue;
          }
          // 左对齐 + 步进宽度卡死 → 数码字落在源版面格子里
          ctx.textAlign = 'left';
          ctx.textBaseline = 'middle';
          ctx.fillStyle = '#FFFFFF';
          ctx.fillText(digits[i], x, y + kDigitH / 2);
        }
        ctx.textAlign = 'left';

        if (ampm.length > 0) {
          ctx.textAlign = 'left';
          ctx.fillStyle = '#8E9B97';
          ctx.font = '20px monospace';
          ctx.fillText(ampm, digitX(4) + kDigitW + 4, kTimeY + kDigitH - 12);
        }

        // 变换收尾（后面的东西一律回到屏幕坐标系）
    ctx.restore();
  }

  static render(ctx: CanvasRenderingContext2D, st: PongState, is24h: boolean,
                fps: number = 0, renderMs: number = 0,
                vig: number = 0, vigReach: number = 620,
                vigCorner: number = 0): void {
    const X = ox();
    const Y = oy();

    // 整屏底：与源一致（黑）
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, ThemePong.W, ThemePong.H);

    ThemePong.leftPanel(ctx, st, fps, renderMs);
    ThemePong.rightPanel(ctx, st);

    // 游戏区外框（让中间那块"是个窗口"而不是浮在黑里）
    ctx.strokeStyle = '#262A3A';
    ctx.lineWidth = 2;
    ctx.strokeRect(X - 8, Y - 6, kDrawW + 16, kDrawH + 12);

    // 游戏本身用**一次缩放变换**画：源坐标（368×448）→ 游戏区（343×418）。
    // 变换只在这里生效，所以下面的绘制代码与源固件一一对应，不必逐点乘系数。
    ThemePong.drawGame(ctx, st, is24h, X, Y, kScale);
    // 右下角漏光补偿（画在最上层，压暗那一角）
    Chrome.vignette(ctx, 1920, 462, vig, vigReach, vigCorner);
  }

  // -------------------------------------------------------------------------
  //  两侧信息栏
  // -------------------------------------------------------------------------

  /** 一张栏底（圆角 + 描边 + 顶部强调条），与其它主题的卡片语言一致 */
  private static panelBox(ctx: CanvasRenderingContext2D, x: number, y: number,
                          w: number, h: number, accent: string): void {
    ctx.fillStyle = '#141722';
    ThemePong.roundRect(ctx, x, y, w, h, 14);
    ctx.fill();
    ctx.strokeStyle = '#262A3A';
    ctx.lineWidth = 1;
    ThemePong.roundRect(ctx, x + 0.5, y + 0.5, w - 1, h - 1, 14);
    ctx.stroke();
    ctx.fillStyle = accent;
    ThemePong.roundRect(ctx, x + 18, y + 20, 4, 26, 2);
    ctx.fill();
  }

  private static roundRect(ctx: CanvasRenderingContext2D, x: number, y: number,
                           w: number, h: number, r: number): void {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  /** 一行"标签 + 等宽数值"，左右对齐 */
  private static statRow(ctx: CanvasRenderingContext2D, x: number, w: number, y: number,
                         label: string, value: string, color: string): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = '#8C94A8';
    ctx.font = '22px sans-serif';
    ctx.fillText(label, x, y);
    ctx.textAlign = 'right';
    ctx.fillStyle = color;
    ctx.font = 'bold 32px monospace';
    ctx.fillText(value, x + w, y);
    ctx.textAlign = 'left';
  }

  /** 左栏：战况（得分/连击/砖块/推帧）+ 砖块占位小地图 */
  private static leftPanel(ctx: CanvasRenderingContext2D, st: PongState,
                           fps: number, renderMs: number): void {
    const x = ThemePong.M;
    const y = ThemePong.M;
    const w = ThemePong.PANEL_W;
    const h = ThemePong.H - ThemePong.M * 2;
    ThemePong.panelBox(ctx, x, y, w, h, '#22D3EE');

    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#22D3EE';
    ctx.font = 'bold 30px sans-serif';
    ctx.fillText('打砖块', x + 34, y + 40);
    ctx.fillStyle = '#8C94A8';
    ctx.font = '20px sans-serif';
    const sub = st.dateText.length > 0
      ? `${st.dateText} · 源固件 clock_pong 复刻 368×448`
      : '源固件 clock_pong 复刻 · 368×448';
    ctx.fillText(sub, x + 34, y + 68);

    const inner = x + 34;
    const innerW = w - 68;
    const score = st.bricksBroken * 12 + st.bestCombo * 5;
    ThemePong.statRow(ctx, inner, innerW, y + 122, '得分', `${score}`, '#E6EBF5');
    ThemePong.statRow(ctx, inner, innerW, y + 166, '连击 / 最高', `${st.combo} / ${st.bestCombo}`, '#FBBF24');
    ThemePong.statRow(ctx, inner, innerW, y + 210, '击碎砖块', `${st.bricksBroken}`, '#34D399');
    ThemePong.statRow(ctx, inner, innerW, y + 254, '回球次数', `${st.paddleHits}`, '#E6EBF5');
    ThemePong.statRow(ctx, inner, innerW, y + 298, '剩余砖块', `${bricksLeft(st)}/${kBrickRows * kBrickCols}`, '#8C94A8');
    ThemePong.statRow(ctx, inner, innerW, y + 342, '推帧 / 渲染', `${fps.toFixed(1)}fps / ${renderMs.toFixed(0)}ms`,
      fps >= 20 ? '#34D399' : '#FBBF24');

    // 砖块小地图（源 9×5 的存活表，一眼看出打掉哪些）—— 放在最后一行的下面
    ctx.fillStyle = '#646C82';
    ctx.font = '20px sans-serif';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText('砖块存活图', inner, y + 392);
    const mw = innerW / kBrickCols;
    const mh = 14;
    const my = y + 410;
    for (let r = 0; r < kBrickRows; r++) {
      for (let c = 0; c < kBrickCols; c++) {
        ctx.fillStyle = st.bricks[r][c] ? kBrickColors[r % kBrickColors.length] : '#1E2230';
        ctx.fillRect(inner + c * mw + 1, my + r * (mh + 4), mw - 2, mh);
      }
    }
  }

  /** 右栏：源参数 + 砖色图例 + 时间 */
  private static rightPanel(ctx: CanvasRenderingContext2D, st: PongState): void {
    const x = ThemePong.W - ThemePong.M - ThemePong.PANEL_W;
    const y = ThemePong.M;
    const w = ThemePong.PANEL_W;
    const h = ThemePong.H - ThemePong.M * 2;
    ThemePong.panelBox(ctx, x, y, w, h, '#00AE42');

    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#34D399';
    ctx.font = 'bold 30px sans-serif';
    ctx.fillText('移植参数', x + 34, y + 40);
    ctx.fillStyle = '#8C94A8';
    ctx.font = '20px sans-serif';
    ctx.fillText('所有数字取自源文件，未改设计', x + 34, y + 68);

    const inner = x + 34;
    const innerW = w - 68;
    ThemePong.statRow(ctx, inner, innerW, y + 122, '球速 / 挡板', `${kBallSpeed} / ${kPaddleSpeed}`, '#E6EBF5');
    ThemePong.statRow(ctx, inner, innerW, y + 166, '球径 / 挡板厚', `${kBallSize} / ${kPaddleH}`, '#E6EBF5');
    ThemePong.statRow(ctx, inner, innerW, y + 210, '砖块 / 间距', `${kBrickW}×${kBrickH} / ${kBrickGap}`, '#E6EBF5');
    ThemePong.statRow(ctx, inner, innerW, y + 254, '砖块阵列', `${kBrickCols}×${kBrickRows}`, '#E6EBF5');
    ThemePong.statRow(ctx, inner, innerW, y + 298, '物理周期', `${kTickMs}ms（${Math.round(1000 / kTickMs)}Hz）`, '#E6EBF5');
    ThemePong.statRow(ctx, inner, innerW, y + 342, '已运行 / 重开',
      `${(st.tick * kTickMs / 1000).toFixed(0)}s / ${st.resets}`, '#8C94A8');

    // 砖色图例（5 行对应 5 行砖），放在最后一行下面，与上方文字留足 10px 以上
    ctx.fillStyle = '#646C82';
    ctx.font = '20px sans-serif';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText('砖色 · 行序', inner, y + 392);
    const ly = y + 424;
    const cellW = innerW / kBrickRows;
    for (let r = 0; r < kBrickRows; r++) {
      const cx = inner + r * cellW;
      ctx.fillStyle = kBrickColors[r % kBrickColors.length];
      ctx.fillRect(cx, ly - 9, 26, 18);
      ctx.fillStyle = '#8C94A8';
      ctx.textAlign = 'left';
      ctx.fillText(`${r + 1}`, cx + 34, ly);
    }
  }

  /** 两位补零（LcdService 组装日期串时也用） */
  static pad2(n: number): string {
    return (n < 10 ? '0' : '') + n;
  }
}
