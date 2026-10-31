/**
 * ThemeSnake.ets —— 自走贪吃蛇（**移植自 ESP32-C3 bambu-zh 的 snake_logic / snake_ui**）
 *
 * 参考实现：
 *   ~/Documents/拓竹P2S开发/bambu-zh/src/snake_logic.cpp
 *   ~/Documents/拓竹P2S开发/bambu-zh/src/snake_ui.cpp
 *
 * 之所以照搬它的设计而不是自己再写一套，是因为它的几个细节更对：
 *   1. **环形缓冲**：`body[(headIdx + i) % CELLS]` 是第 i 节（0=头）。
 *      前进时 `headIdx = (headIdx + CELLS - 1) % CELLS` 再写新头 ——
 *      所有节的下标自动整体挪一位，尾巴**自然掉落**；吃到食物只 `length++`，
 *      尾巴就留住了 → 生长。不需要 unshift/pop（省 O(n)）。
 *   2. **尾巴格可以进**：不吃食物时尾巴这一步会让开，所以碰撞判定要 `ignoreTail=true`，
 *      否则贴着尾巴转弯会被判自杀。
 *   3. **禁反向**：与 `pending`（排队方向）比较，而不是与当前方向比较 ——
 *      同一 tick 内连按两次也能都生效。
 *   4. **速度递增**：`tickMs = max(70, 170 - 8*score)`，吃得越多走得越快。
 *   5. **自动驾驶**：先试"朝食物那根轴"，不行再按 {当前方向, 右转, 左转, 目标} 找一个
 *      下一步不会死的 —— 比洪泛填充便宜（这块屏只有 20×20）。
 *   6. **食物放置**：先随机试 200 次，失败再线性扫；铺满时用 0xFFFF 表示"没有食物"。
 *
 * 坐标系：本文件内全部是**格子坐标**，绘制时再换算到传入的像素矩形。
 */

/** 默认棋盘（打印机格用；Dotii 页与全屏主题各自指定大棋盘） */
const DEF_COLS: number = 15;
const DEF_ROWS: number = 10;

/** 方向（与源实现一致：0=上 1=右 2=下 3=左） */
const DIR_UP: number = 0;
const DIR_RIGHT: number = 1;
const DIR_DOWN: number = 2;
const DIR_LEFT: number = 3;

/** 状态 */
const ST_IDLE: number = 0;
const ST_RUNNING: number = 1;
const ST_OVER: number = 2;

/** 步进结果 */
const STEP_MOVED: number = 0;
const STEP_ATE: number = 1;
const STEP_DIED: number = 2;

/** 死亡后多久重开（源实现：演示 1500ms；这里只做演示，取 1500） */
const RESTART_MS: number = 1500;

/** xorshift32 状态（源实现：一次播种，全局复用） */
let snkRng: number = 0x9E3779B9;

function snkSeed(seed: number): void {
  snkRng = (seed !== 0) ? (seed >>> 0) : 0x9E3779B9;
}

/** xorshift32：小、确定、够用（源实现同款） */
function snkRandom(bound: number): number {
  snkRng = (snkRng ^ (snkRng << 13)) >>> 0;
  snkRng = (snkRng ^ (snkRng >>> 17)) >>> 0;
  snkRng = (snkRng ^ (snkRng << 5)) >>> 0;
  return bound > 0 ? (snkRng % bound) : 0;
}

export class SnakeState {
  /** 环形缓冲：body[(headIdx + i) % cells] 是第 i 节，i=0 是头 */
  body: number[] = [];
  /** 头在环形缓冲里的下标 */
  headIdx: number = 0;
  /** 当前长度（节数） */
  length: number = 3;
  /** 当前方向 */
  dir: number = DIR_RIGHT;
  /** 排队方向（== dir 表示没排队） */
  pending: number = DIR_RIGHT;
  /** 食物所在格；0xFFFF = 没有（铺满了） */
  food: number = 0xFFFF;
  /** 吃到几个 */
  score: number = 0;
  /** ST_IDLE / ST_RUNNING / ST_OVER */
  state: number = ST_RUNNING;
  /** 距上次吃到食物走了几步（驱动速度递增） */
  stepsSinceFood: number = 0;

  /** 已推进的步数（进内容签名用） */
  tick: number = 0;
  /** 上次推进的时间戳 */
  at: number = 0;
  /** 死亡后重开的时刻（0 = 未死亡） */
  deadUntil: number = 0;
  /** 累计死亡次数 */
  deaths: number = 0;

  /** 棋盘列数 */
  cols: number = DEF_COLS;
  /** 棋盘行数 */
  rows: number = DEF_ROWS;
}

export class ThemeSnake {
  static readonly COLS: number = DEF_COLS;
  static readonly ROWS: number = DEF_ROWS;

  // ---------------- 格坐标 helpers（源实现 snkCell/snkCol/snkRow）----------------

  static cellOf(st: SnakeState, col: number, row: number): number {
    return row * st.cols + col;
  }

  static colOf(st: SnakeState, cell: number): number {
    return cell % st.cols;
  }

  static rowOf(st: SnakeState, cell: number): number {
    return Math.floor(cell / st.cols);
  }

  /** 第 i 节的格子下标（i=0 是头） */
  static segCell(st: SnakeState, i: number): number {
    const cells: number = st.cols * st.rows;
    if (cells <= 0 || st.body.length !== cells) {
      return -1;
    }
    return st.body[(st.headIdx + i) % cells];
  }

  /** 该格是否被蛇身占用（ignoreTail=true 时忽略尾巴，因为尾巴这一步会让开） */
  static occupied(st: SnakeState, cell: number, ignoreTail: boolean): boolean {
    const cells: number = st.cols * st.rows;
    let n: number = st.length;
    if (ignoreTail && n > 0) {
      n--;
    }
    for (let i = 0; i < n; i++) {
      if (st.body[(st.headIdx + i) % cells] === cell) {
        return true;
      }
    }
    return false;
  }

  /** 放食物：先随机试 200 次，失败再线性扫；铺满则 0xFFFF */
  private static placeFood(st: SnakeState): void {
    const cells: number = st.cols * st.rows;
    for (let attempt = 0; attempt < 200; attempt++) {
      const cell: number = snkRandom(cells);
      if (!ThemeSnake.occupied(st, cell, false)) {
        st.food = cell;
        return;
      }
    }
    for (let cell = 0; cell < cells; cell++) {
      if (!ThemeSnake.occupied(st, cell, false)) {
        st.food = cell;
        return;
      }
    }
    st.food = 0xFFFF;
  }

  /** 新开一局（长度 3，头朝右，摆在中间行） */
  static reset(st: SnakeState, nowMs: number, cols: number = DEF_COLS,
               rows: number = DEF_ROWS): void {
    st.cols = cols > 3 ? cols : DEF_COLS;
    st.rows = rows > 3 ? rows : DEF_ROWS;
    const cells: number = st.cols * st.rows;
    st.body = new Array<number>(cells);
    for (let i = 0; i < cells; i++) {
      st.body[i] = 0;
    }
    snkSeed((nowMs ^ 0x5A5A5A5A) >>> 0);

    st.headIdx = 0;
    st.length = 3;
    st.dir = DIR_RIGHT;
    st.pending = DIR_RIGHT;
    st.score = 0;
    st.state = ST_RUNNING;
    st.stepsSinceFood = 0;
    st.food = 0xFFFF;
    st.tick = 0;
    st.at = nowMs;
    st.deadUntil = 0;

    const row: number = Math.floor(st.rows / 2);
    const col: number = Math.floor(st.cols / 2);
    st.body[0] = ThemeSnake.cellOf(st, col, row);
    st.body[1] = ThemeSnake.cellOf(st, col - 1, row);
    st.body[2] = ThemeSnake.cellOf(st, col - 2, row);
    ThemeSnake.placeFood(st);
  }

  /** 排队一个方向；反向被忽略；与 pending 比较（源实现的关键细节） */
  static turn(st: SnakeState, dir: number): void {
    if (dir > DIR_LEFT) {
      return;
    }
    if (st.state !== ST_RUNNING) {
      return;
    }
    const against: number = (st.pending + 2) & 3;
    if (dir === against) {
      return;
    }
    st.pending = dir;
  }

  /** 前进一格。返回 STEP_MOVED / STEP_ATE / STEP_DIED */
  static advance(st: SnakeState): number {
    if (st.state !== ST_RUNNING) {
      return STEP_MOVED;
    }
    st.dir = st.pending;
    const cells: number = st.cols * st.rows;
    const head: number = st.body[st.headIdx];
    let col: number = ThemeSnake.colOf(st, head);
    let row: number = ThemeSnake.rowOf(st, head);
    if (st.dir === DIR_UP) {
      row--;
    } else if (st.dir === DIR_RIGHT) {
      col++;
    } else if (st.dir === DIR_DOWN) {
      row++;
    } else {
      col--;
    }
    if (col < 0 || col >= st.cols || row < 0 || row >= st.rows) {
      st.state = ST_OVER;
      return STEP_DIED;
    }

    const next: number = ThemeSnake.cellOf(st, col, row);
    const eat: boolean = (next === st.food);
    // 不吃食物时尾巴会让开，所以判定碰撞要 ignoreTail
    if (ThemeSnake.occupied(st, next, !eat)) {
      st.state = ST_OVER;
      return STEP_DIED;
    }

    st.headIdx = (st.headIdx + cells - 1) % cells;
    st.body[st.headIdx] = next;

    if (eat) {
      if (st.length < cells) {
        st.length++;
      }
      st.score++;
      st.stepsSinceFood = 0;
      ThemeSnake.placeFood(st);
      return STEP_ATE;
    }
    st.stepsSinceFood++;
    return STEP_MOVED;
  }

  /** 当前步进间隔（ms）：170 起，每吃一个 -8，下限 70 */
  static tickMs(st: SnakeState): number {
    const ms: number = 170 - 8 * st.score;
    return ms < 70 ? 70 : ms;
  }

  /** 这一步走 dir 会不会死 */
  private static safeNext(st: SnakeState, dir: number): boolean {
    const head: number = st.body[st.headIdx];
    let col: number = ThemeSnake.colOf(st, head);
    let row: number = ThemeSnake.rowOf(st, head);
    if (dir === DIR_UP) {
      row--;
    } else if (dir === DIR_RIGHT) {
      col++;
    } else if (dir === DIR_DOWN) {
      row++;
    } else {
      col--;
    }
    if (col < 0 || col >= st.cols || row < 0 || row >= st.rows) {
      return false;
    }
    return !ThemeSnake.occupied(st, ThemeSnake.cellOf(st, col, row), true);
  }

  /** 自动驾驶方向（源实现 snkAutoDir）：先朝食物，再退化为"不死的方向" */
  static autoDir(st: SnakeState): number {
    const head: number = st.body[st.headIdx];
    const hc: number = ThemeSnake.colOf(st, head);
    const hr: number = ThemeSnake.rowOf(st, head);
    const against: number = (st.dir + 2) & 3;

    let want: number = st.dir;
    if (st.food !== 0xFFFF) {
      const fc: number = ThemeSnake.colOf(st, st.food);
      const fr: number = ThemeSnake.rowOf(st, st.food);
      if (fc < hc) {
        want = DIR_LEFT;
      } else if (fc > hc) {
        want = DIR_RIGHT;
      } else if (fr < hr) {
        want = DIR_UP;
      } else if (fr > hr) {
        want = DIR_DOWN;
      }
    }
    if (want !== against && ThemeSnake.safeNext(st, want)) {
      return want;
    }
    // 退化顺序：当前方向 → 右转 → 左转 → 目标方向
    const order: number[] = [st.dir, (st.dir + 1) & 3, (st.dir + 3) & 3, want];
    for (let i = 0; i < 4; i++) {
      const d: number = order[i];
      if (d === against) {
        continue;
      }
      if (ThemeSnake.safeNext(st, d)) {
        return d;
      }
    }
    return st.dir;
  }

  /**
   * 推进一帧（内部按 tickMs 节流，调用方每帧调即可）。
   * @returns 本帧画面是否需要刷新
   */
  static step(st: SnakeState, nowMs: number): boolean {
    if (st.body.length === 0) {
      ThemeSnake.reset(st, nowMs, st.cols, st.rows);
      return true;
    }
    // 死亡 → 停 RESTART_MS 后重开（源实现的做法）
    if (st.state === ST_OVER) {
      // ★ 兜底（2026-10-31 审计 B6）：deadUntil 没被 advance 置上（比如
      //   外部把 state 直接改成 ST_OVER）时，蛇会永远躺尸不复活。
      if (st.deadUntil <= 0) {
        st.deadUntil = nowMs + RESTART_MS;
      }
      if (nowMs >= st.deadUntil) {
        ThemeSnake.reset(st, nowMs, st.cols, st.rows);
        return true;
      }
      return false;
    }
    if (nowMs - st.at < ThemeSnake.tickMs(st)) {
      return false;
    }
    st.at = nowMs;
    st.tick++;

    ThemeSnake.turn(st, ThemeSnake.autoDir(st));
    const outcome: number = ThemeSnake.advance(st);
    if (outcome === STEP_DIED) {
      st.deaths++;
      st.deadUntil = nowMs + RESTART_MS;
    }
    return true;
  }

  /**
   * 画到指定像素矩形里（**等比方格 + 居中**）。
   * 配色照搬源实现 snake_ui.cpp：黑底 / 深绿身 / 亮绿头 / 红食物。
   * 字号随格子尺寸缩放，所以小格子和全屏都好看。
   */
  static draw(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
              st: SnakeState, nowMs: number): void {
    const cells: number = st.cols * st.rows;
    // 源实现配色（snake_ui.cpp）
    const CLR_BG: string = '#000000';
    const CLR_BODY: string = '#00C000';
    const CLR_HEAD: string = '#00FF00';
    const CLR_FOOD: string = '#FF0000';
    const CLR_PANEL: string = '#202020';
    const CLR_TEXT: string = '#FFFFFF';

    ctx.fillStyle = CLR_BG;
    ctx.fillRect(x, y, w, h);

    if (st.body.length !== cells) {
      ThemeSnake.reset(st, nowMs, st.cols, st.rows);
    }

    const cs: number = Math.min(w / st.cols, h / st.rows);
    const bw: number = cs * st.cols;
    const bh: number = cs * st.rows;
    const ox: number = x + (w - bw) / 2;
    const oy: number = y + (h - bh) / 2;

    // 计分行：★ 做成**带底的状态条**，而不是悬在棋格上的一行小绿字。
    //   原来只有 max(11, cs*0.55) px（Dotii 里 11px），在 4.6" 屏上读不出字，
    //   远看就像"一条绿色的线"（用户反馈）。现在：深色底 + 字号下限 14 + 上边一条细分隔线。
    if (cs >= 11) {
      // ★ 记分牌：钉在**传入矩形的底边**（用户要求"放大一点、看得清"）。
      //   为什么不放在棋盘下方居中：Dotii 面板的页指示点也在那一带，
      //   条子加高到 30px 就会把页点套进去（实测）。钉到最底边 → 页点在它上方，互不干扰。
      const stripH: number = Math.max(24, cs * 1.35);
      const sf: number = Math.round(Math.max(17, cs * 0.85));
      const sy: number = y + h - stripH - 2;
      // ★ 不要那条 1px 绿边线（用户反馈"底部有残线"就是它）：
      //   深色底在黑棋格上几乎看不见，只剩一条绿线悬着，像残留。
      //   改用**能看见的深绿底**，让整条状态栏作为一个色块存在。
      ctx.fillStyle = 'rgba(0, 46, 26, 0.95)';
      ctx.fillRect(ox, sy, bw, stripH);
      // ★ 不要拆成"暗标签 + 亮数字"——实测排版会糊（用量测宽度拼位置，误差累积）。
      //   小屏上"两端对齐的两段短文本"最稳：左边 SCORE，右边 LEN。
      const pad2: number = Math.max(8, cs * 0.55);
      ctx.font = `bold ${sf}px monospace`;
      ctx.textBaseline = 'middle';
      ctx.fillStyle = '#C8FFE8';
      ctx.textAlign = 'left';
      ctx.fillText(`SCORE ${st.score}`, ox + pad2, sy + stripH / 2);
      ctx.textAlign = 'right';
      ctx.fillText(`LEN ${st.length}`, ox + bw - pad2, sy + stripH / 2);
    }

    // 网格（弱，只为看出格子）
    ctx.strokeStyle = 'rgba(0, 255, 128, 0.07)';
    ctx.lineWidth = 1;
    for (let c = 1; c < st.cols; c++) {
      ctx.beginPath();
      ctx.moveTo(ox + c * cs, oy);
      ctx.lineTo(ox + c * cs, oy + bh);
      ctx.stroke();
    }
    for (let r = 1; r < st.rows; r++) {
      ctx.beginPath();
      ctx.moveTo(ox, oy + r * cs);
      ctx.lineTo(ox + bw, oy + r * cs);
      ctx.stroke();
    }

    // ── 卡通化绘制（规格来自 ESP32-C3 项目那版）──
    //   基准：源实现里格子 12px，蛇身圆 r=5、尾巴 r=4、蛇头 r=7、食物是红苹果。
    //   这里所有半径都按 cs/12 缩放，所以格子大小和全屏都能用同一套画法。
    const K: number = cs / 12;

    const disc = (x: number, y: number, r: number, fill: string): void => {
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.fillStyle = fill;
      ctx.fill();
    };

    // 食物：红苹果（圆 + 白色高光 + 一小片绿叶）
    if (st.food !== 0xFFFF) {
      const fx = ox + (ThemeSnake.colOf(st, st.food) + 0.5) * cs;
      const fy = oy + (ThemeSnake.rowOf(st, st.food) + 0.5) * cs;
      ctx.globalAlpha = 0.82 + 0.18 * Math.sin(nowMs / 220);
      // 苹果本体
      disc(fx, fy + 0.5 * K, 4.6 * K, CLR_FOOD);
      // 白色高光（左上）
      disc(fx - 1.6 * K, fy - 1.2 * K, 1.5 * K, 'rgba(255,255,255,0.85)');
      // 绿叶：小椭圆，**必须留在格子内**（源实现踩过"叶子超出格子被残留成一条线"）
      ctx.beginPath();
      ctx.ellipse(fx + 1.4 * K, fy - 4.0 * K, 1.9 * K, 1.1 * K, -0.5, 0, Math.PI * 2);
      ctx.fillStyle = '#2ECC40';
      ctx.fill();
      ctx.globalAlpha = 1;
    }

    // 蛇身：圆珠串（尾巴是小一号的圆）
    for (let i = st.length - 1; i >= 1; i--) {
      const cell: number = ThemeSnake.segCell(st, i);
      if (cell < 0) {
        continue;
      }
      const cx = ox + (ThemeSnake.colOf(st, cell) + 0.5) * cs;
      const cy = oy + (ThemeSnake.rowOf(st, cell) + 0.5) * cs;
      const isTail: boolean = (i === st.length - 1);
      disc(cx, cy, (isTail ? 4.0 : 5.0) * K, CLR_BODY);
      // 每颗珠子加一点上缘高光，串起来更像珠子而不是色块
      disc(cx - 1.4 * K, cy - 1.6 * K, 1.5 * K, 'rgba(255,255,255,0.18)');
    }

    // 蛇头：大圆 + 一对眼睛（眼球朝向跟随前进方向）+ 高光 + 笑线
    {
      const headCell: number = ThemeSnake.segCell(st, 0);
      if (headCell >= 0) {
        const hx = ox + (ThemeSnake.colOf(st, headCell) + 0.5) * cs;
        const hy = oy + (ThemeSnake.rowOf(st, headCell) + 0.5) * cs;
        // 源实现：蛇头半径 7（会略微超格，所以整块是逐帧重绘的，不怕出格）
        const hr: number = 7.0 * K;
        disc(hx, hy, hr, CLR_HEAD);
        disc(hx - 2.0 * K, hy - 2.2 * K, 1.7 * K, 'rgba(255,255,255,0.30)');

        // 方向单位向量：0=上 1=右 2=下 3=左
        let dx: number = 0;
        let dy: number = 0;
        if (st.dir === 0) {
          dy = -1;
        } else if (st.dir === 1) {
          dx = 1;
        } else if (st.dir === 2) {
          dy = 1;
        } else {
          dx = -1;
        }
        // 垂直于前进方向的两个偏移 → 左右眼
        const px: number = -dy;
        const py: number = dx;
        for (let s = -1; s <= 1; s += 2) {
          const ex: number = hx + dx * 1.6 * K + px * s * 2.4 * K;
          const ey: number = hy + dy * 1.6 * K + py * s * 2.4 * K;
          // 白眼球
          disc(ex, ey, 2.3 * K, '#FFFFFF');
          // 黑瞳孔（再往前进方向偏一点，看起来在"看"）
          disc(ex + dx * 0.6 * K, ey + dy * 0.6 * K, 1.2 * K, '#101010');
        }
        // 笑线（只在够大的时候画，小格子里画了也看不清）
        if (cs >= 14) {
          ctx.beginPath();
          ctx.arc(hx + dx * 2.0 * K, hy + dy * 2.0 * K, 2.0 * K,
            0.15 * Math.PI, 0.85 * Math.PI);
          ctx.strokeStyle = 'rgba(0,64,0,0.75)';
          ctx.lineWidth = Math.max(1, 0.9 * K);
          ctx.stroke();
        }
      }
    }

    // 死亡：保留蛇身，盖一张紧凑的结果卡（源实现 paintOver）
    if (st.state === ST_OVER) {
      const cw = Math.min(bw * 0.86, cs * 9.5);
      const ch = Math.max(34, cs * 2.6);
      const cxp = ox + (bw - cw) / 2;
      const cyp = oy + (bh - ch) / 2;
      ctx.fillStyle = CLR_PANEL;
      ctx.fillRect(cxp, cyp, cw, ch);
      const f1 = Math.round(Math.max(14, cs * 1.05));
      const f2 = Math.round(Math.max(12, cs * 0.85));
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = CLR_TEXT;
      ctx.font = `bold ${f1}px monospace`;
      ctx.fillText('GAME OVER', cxp + cw / 2, cyp + ch * 0.34);
      ctx.font = `${f2}px monospace`;
      ctx.fillText(`SCORE ${st.score}`, cxp + cw / 2, cyp + ch * 0.72);
    }

  }
}
