import { TILE, LEVEL_ROWS, TileId, ThemeId } from './Types';

/**
 * 敌人出生点
 */
export interface EnemySpawn {
  col: number;
  row: number;
}

/**
 * 可进入的水管
 */
export interface PipeWarp {
  col: number;      // 水管左列
  h: number;        // 水管高度
  kind: number;     // 0=进入奖励关, 1=进入下一关, 2=退出奖励关返回
  exitCol: number;  // kind=0 时返回主关卡的列
}

/**
 * 关卡数据：瓦片网格 + 出生点 + 检查点 + 旗杆 + 水管
 */
export class LevelData {
  cols: number = 0;
  rows: number = LEVEL_ROWS;
  tiles: number[][] = [];
  theme: number = ThemeId.OVERWORLD;
  spawnX: number = 64;
  spawnY: number = 0;
  flagCol: number = 110;
  flagTopRow: number = 2;
  hasFlag: boolean = true; // 是否有终点旗杆（水管关卡型为 false）
  enemySpawns: EnemySpawn[] = [];
  checkpoints: number[] = [];
  enterPipes: PipeWarp[] = []; // 可进入的水管

  constructor(cols: number) {
    this.cols = cols;
    for (let r = 0; r < this.rows; r++) {
      const row: number[] = [];
      for (let c = 0; c < cols; c++) {
        row.push(TileId.EMPTY);
      }
      this.tiles.push(row);
    }
  }

  tileAt(col: number, row: number): number {
    if (col < 0 || col >= this.cols || row < 0 || row >= this.rows) {
      return TileId.EMPTY;
    }
    return this.tiles[row][col];
  }

  solidAt(col: number, row: number): boolean {
    return isSolidTile(this.tileAt(col, row));
  }

  width(): number {
    return this.cols * TILE;
  }

  height(): number {
    return this.rows * TILE;
  }
}

/**
 * 是否为实心瓦片
 */
export function isSolidTile(t: number): boolean {
  return t === TileId.GROUND || t === TileId.STONE || t === TileId.BRICK ||
    t === TileId.QUESTION || t === TileId.USED || t === TileId.QUESTION_POWER ||
    t === TileId.PIPE_TL || t === TileId.PIPE_TR || t === TileId.PIPE_L || t === TileId.PIPE_R;
}

function groundY(): number {
  return (LEVEL_ROWS - 2) * TILE;
}

function putGround(lv: LevelData, c0: number, c1: number): void {
  for (let c = c0; c <= c1; c++) {
    lv.tiles[LEVEL_ROWS - 2][c] = TileId.GROUND;
    lv.tiles[LEVEL_ROWS - 1][c] = TileId.GROUND;
  }
}

function putBrick(lv: LevelData, c: number, r: number): void {
  lv.tiles[r][c] = TileId.BRICK;
}

function putQuestion(lv: LevelData, c: number, r: number): void {
  lv.tiles[r][c] = TileId.QUESTION;
}

function putPowerQuestion(lv: LevelData, c: number, r: number): void {
  lv.tiles[r][c] = TileId.QUESTION_POWER;
}

function putCoinTile(lv: LevelData, c: number, r: number): void {
  lv.tiles[r][c] = TileId.COIN;
}

function putStone(lv: LevelData, c: number, r: number): void {
  lv.tiles[r][c] = TileId.STONE;
}

/**
 * 放置管道：c 为左列，h 为高度（行数），管道宽 2 格
 */
function putPipe(lv: LevelData, c: number, h: number): void {
  const rimRow = LEVEL_ROWS - 2 - h;
  lv.tiles[rimRow][c] = TileId.PIPE_TL;
  lv.tiles[rimRow][c + 1] = TileId.PIPE_TR;
  for (let r = rimRow + 1; r <= LEVEL_ROWS - 3; r++) {
    lv.tiles[r][c] = TileId.PIPE_L;
    lv.tiles[r][c + 1] = TileId.PIPE_R;
  }
}

function putEnemy(lv: LevelData, col: number): void {
  lv.enemySpawns.push({ col: col, row: LEVEL_ROWS - 3 });
}

/**
 * 挖坑（去掉两格地面）
 */
function makeGap(lv: LevelData, c0: number, c1: number): void {
  for (let c = c0; c <= c1; c++) {
    lv.tiles[LEVEL_ROWS - 2][c] = TileId.EMPTY;
    lv.tiles[LEVEL_ROWS - 1][c] = TileId.EMPTY;
  }
}

/**
 * 第 1 关型：地面世界（各世界舞台 1，结尾水管进入地下关）
 */
function buildOverworld(world: number): LevelData {
  const lv = new LevelData(120);
  lv.theme = ThemeId.OVERWORLD;
  putGround(lv, 0, 119);
  lv.spawnX = 2 * TILE;
  lv.spawnY = groundY() - 32;
  lv.flagCol = 118; // 未使用（本关型用水管过关）
  lv.flagTopRow = 2;
  lv.hasFlag = false;
  const diff = world - 1; // 难度增量

  putCoinTile(lv, 7, 11);
  putCoinTile(lv, 8, 11);
  putCoinTile(lv, 9, 11);
  putQuestion(lv, 10, 9);
  putQuestion(lv, 11, 9);
  putBrick(lv, 16, 9);
  putBrick(lv, 17, 9);
  putBrick(lv, 18, 9);
  putQuestion(lv, 19, 9);
  putBrick(lv, 24, 9);
  putBrick(lv, 25, 9);
  putCoinTile(lv, 24, 5);
  putCoinTile(lv, 25, 5);
  // 奖励关水管 1
  putPipe(lv, 30, 2);
  lv.enterPipes.push({ col: 30, h: 2, kind: 0, exitCol: 38 });
  // 蘑菇
  putPowerQuestion(lv, 44, 9);
  // 高管道（不可进入）
  putPipe(lv, 50, 3);
  // 坑（随世界加宽）
  const gap0 = 56;
  const gapW = 4 + Math.min(diff, 3);
  makeGap(lv, gap0, gap0 + gapW - 1);
  putCoinTile(lv, gap0 + 1, 8);
  lv.checkpoints.push((gap0 + gapW + 2) * TILE);
  // 阶梯
  putStone(lv, 68, 12);
  putStone(lv, 69, 12);
  putStone(lv, 69, 11);
  putStone(lv, 70, 12);
  putStone(lv, 70, 11);
  putStone(lv, 70, 10);
  putStone(lv, 71, 12);
  putStone(lv, 71, 11);
  putStone(lv, 71, 10);
  putStone(lv, 71, 9);
  putStone(lv, 72, 12);
  putStone(lv, 72, 11);
  putStone(lv, 72, 10);
  putStone(lv, 72, 9);
  putStone(lv, 72, 8);
  putStone(lv, 73, 12);
  putStone(lv, 73, 11);
  putStone(lv, 73, 10);
  putStone(lv, 73, 9);
  putStone(lv, 73, 8);
  putStone(lv, 73, 7);
  putStone(lv, 74, 12);
  putStone(lv, 74, 11);
  putStone(lv, 74, 10);
  putStone(lv, 74, 9);
  putStone(lv, 75, 12);
  putStone(lv, 75, 11);
  putStone(lv, 75, 10);
  putStone(lv, 76, 12);
  putStone(lv, 76, 11);
  putStone(lv, 77, 12);
  putQuestion(lv, 82, 9);
  putQuestion(lv, 83, 9);
  putQuestion(lv, 84, 9);
  // 奖励关水管 2
  putPipe(lv, 90, 3);
  lv.enterPipes.push({ col: 90, h: 3, kind: 0, exitCol: 100 });
  // 终点水管：进入本世界第 2 关（地下）
  putPipe(lv, 108, 3);
  lv.enterPipes.push({ col: 108, h: 3, kind: 1, exitCol: 0 });
  // 敌人
  putEnemy(lv, 18);
  putEnemy(lv, 33);
  putEnemy(lv, 48);
  putEnemy(lv, 62);
  putEnemy(lv, 66);
  putEnemy(lv, 96);
  putEnemy(lv, 102);
  putEnemy(lv, 104);
  return lv;
}

/**
 * 第 2 关型：地下世界（各世界舞台 2，旗杆过关）
 */
function buildUnderground(world: number): LevelData {
  const lv = new LevelData(120);
  lv.theme = ThemeId.UNDERGROUND;
  putGround(lv, 0, 119);
  lv.spawnX = 2 * TILE;
  lv.spawnY = groundY() - 32;
  lv.flagCol = 112;
  lv.flagTopRow = 3;
  const diff = world - 1;

  for (let c = 8; c <= 11; c++) {
    putStone(lv, c, 10);
    putStone(lv, c, 11);
  }
  putCoinTile(lv, 9, 8);
  putCoinTile(lv, 10, 8);
  putBrick(lv, 14, 9);
  putBrick(lv, 15, 9);
  putQuestion(lv, 16, 9);
  putBrick(lv, 17, 9);
  putQuestion(lv, 18, 9);
  putPipe(lv, 22, 2);
  putPipe(lv, 28, 3);
  putCoinTile(lv, 33, 10);
  putCoinTile(lv, 34, 9);
  putCoinTile(lv, 35, 8);
  putCoinTile(lv, 36, 9);
  putCoinTile(lv, 37, 10);
  putPowerQuestion(lv, 42, 9);
  const gap0 = 46;
  const gapW = 4 + Math.min(diff, 2);
  makeGap(lv, gap0, gap0 + gapW - 1);
  putCoinTile(lv, gap0 + 1, 8);
  lv.checkpoints.push((gap0 + gapW + 3) * TILE);
  putBrick(lv, 54, 9);
  putBrick(lv, 55, 9);
  putBrick(lv, 56, 9);
  putBrick(lv, 54, 8);
  putBrick(lv, 56, 8);
  putCoinTile(lv, 55, 7);
  putPipe(lv, 62, 2);
  putPipe(lv, 68, 4);
  const gap1 = 74;
  makeGap(lv, gap1, gap1 + 2);
  putCoinTile(lv, gap1 + 1, 8);
  putQuestion(lv, 80, 9);
  putQuestion(lv, 81, 9);
  putQuestion(lv, 82, 9);
  putCoinTile(lv, 104, 9);
  putCoinTile(lv, 105, 8);
  putCoinTile(lv, 106, 9);
  // 敌人
  putEnemy(lv, 12);
  putEnemy(lv, 20);
  putEnemy(lv, 26);
  putEnemy(lv, 40);
  putEnemy(lv, 52);
  putEnemy(lv, 60);
  putEnemy(lv, 66);
  putEnemy(lv, 72);
  putEnemy(lv, 78);
  putEnemy(lv, 88);
  putEnemy(lv, 94);
  putEnemy(lv, 100);
  putEnemy(lv, 106);
  return lv;
}

/**
 * 第 3 关型：水下世界（各世界舞台 3，鱼敌人）
 */
function buildUnderwater(world: number): LevelData {
  const lv = new LevelData(110);
  lv.theme = ThemeId.UNDERWATER;
  putGround(lv, 0, 109);
  lv.spawnX = 2 * TILE;
  lv.spawnY = groundY() - 32;
  lv.flagCol = 102;
  lv.flagTopRow = 3;
  const diff = world - 1;

  // 水底石块
  for (let c = 6; c <= 9; c++) {
    putStone(lv, c, 12);
  }
  putStone(lv, 7, 11);
  // 砖台与金币
  putBrick(lv, 14, 11);
  putBrick(lv, 15, 11);
  putCoinTile(lv, 14, 8);
  putCoinTile(lv, 15, 8);
  putQuestion(lv, 20, 10);
  putQuestion(lv, 21, 10);
  putBrick(lv, 20, 9);
  putBrick(lv, 21, 9);
  // 金币柱
  for (let r = 5; r <= 10; r++) {
    putCoinTile(lv, 28, r);
  }
  putStone(lv, 33, 10);
  putStone(lv, 34, 10);
  putStone(lv, 35, 10);
  putCoinTile(lv, 34, 8);
  putPowerQuestion(lv, 41, 9);
  putBrick(lv, 40, 10);
  putBrick(lv, 42, 10);
  // 拱门
  for (let r = 6; r <= 10; r++) {
    putCoinTile(lv, 49, r);
  }
  for (let r = 6; r <= 10; r++) {
    putCoinTile(lv, 50, r);
  }
  putStone(lv, 55, 11);
  putStone(lv, 56, 11);
  putStone(lv, 57, 11);
  putStone(lv, 58, 11);
  putCoinTile(lv, 56, 7);
  putCoinTile(lv, 57, 7);
  lv.checkpoints.push(62 * TILE);
  // 石块通道
  putStone(lv, 64, 9);
  putStone(lv, 65, 9);
  putStone(lv, 66, 9);
  putStone(lv, 64, 10);
  putStone(lv, 66, 10);
  putCoinTile(lv, 65, 6);
  putQuestion(lv, 71, 9);
  putQuestion(lv, 72, 9);
  putBrick(lv, 71, 10);
  putBrick(lv, 72, 10);
  // 终点前金币
  for (let r = 6; r <= 10; r++) {
    putCoinTile(lv, 92, r);
  }
  putCoinTile(lv, 96, 9);
  putCoinTile(lv, 97, 8);
  putCoinTile(lv, 98, 9);
  // 鱼（数量随世界增加）
  putEnemy(lv, 12);
  putEnemy(lv, 26);
  putEnemy(lv, 38);
  putEnemy(lv, 46);
  putEnemy(lv, 60);
  putEnemy(lv, 70);
  putEnemy(lv, 80);
  putEnemy(lv, 88);
  putEnemy(lv, 94);
  return lv;
}

/**
 * 第 4 关型：城堡（各世界最终关，旗杆过关）
 */
function buildCastle(world: number): LevelData {
  const lv = new LevelData(120);
  lv.theme = ThemeId.CASTLE;
  putGround(lv, 0, 119);
  lv.spawnX = 2 * TILE;
  lv.spawnY = groundY() - 32;
  lv.flagCol = 112;
  lv.flagTopRow = 2;
  const diff = world - 1;

  putBrick(lv, 10, 12);
  putBrick(lv, 11, 12);
  putBrick(lv, 10, 11);
  putBrick(lv, 11, 11);
  putQuestion(lv, 16, 9);
  putBrick(lv, 17, 9);
  putBrick(lv, 18, 9);
  putBrick(lv, 19, 9);
  putQuestion(lv, 20, 9);
  putStone(lv, 26, 12);
  putStone(lv, 27, 12);
  putStone(lv, 26, 11);
  putStone(lv, 27, 11);
  putStone(lv, 26, 10);
  putStone(lv, 27, 10);
  putPowerQuestion(lv, 34, 9);
  // 连续管道障碍
  putPipe(lv, 40, 2);
  putPipe(lv, 46, 3);
  putPipe(lv, 54, 4);
  const gap0 = 60;
  makeGap(lv, gap0, gap0 + 4 + Math.min(diff, 1));
  lv.checkpoints.push((gap0 + 7) * TILE);
  putBrick(lv, 70, 9);
  putBrick(lv, 71, 9);
  putBrick(lv, 72, 9);
  putBrick(lv, 70, 8);
  putBrick(lv, 72, 8);
  putCoinTile(lv, 71, 6);
  putQuestion(lv, 78, 9);
  putQuestion(lv, 79, 9);
  putQuestion(lv, 80, 9);
  putPipe(lv, 86, 3);
  const gap1 = 92;
  makeGap(lv, gap1, gap1 + 2);
  putCoinTile(lv, gap1 + 1, 8);
  putStone(lv, 100, 12);
  putStone(lv, 101, 12);
  putStone(lv, 101, 11);
  putStone(lv, 102, 12);
  putStone(lv, 102, 11);
  putStone(lv, 102, 10);
  // 敌人（城堡最多）
  putEnemy(lv, 14);
  putEnemy(lv, 24);
  putEnemy(lv, 32);
  putEnemy(lv, 44);
  putEnemy(lv, 52);
  putEnemy(lv, 58);
  putEnemy(lv, 66);
  putEnemy(lv, 76);
  putEnemy(lv, 84);
  putEnemy(lv, 90);
  putEnemy(lv, 96);
  putEnemy(lv, 104);
  putEnemy(lv, 108);
  return lv;
}

/**
 * 奖励关（水管内的小型地下房间，收集金币后从出口水管返回）
 */
export function buildBonusRoom(): LevelData {
  const lv = new LevelData(26);
  lv.theme = ThemeId.UNDERGROUND;
  putGround(lv, 0, 25);
  lv.spawnX = 2 * TILE;
  lv.spawnY = groundY() - 32;
  lv.flagCol = 25;
  lv.flagTopRow = 3;
  lv.hasFlag = false;
  // 金币房间
  for (let c = 5; c <= 14; c++) {
    putCoinTile(lv, c, 10);
  }
  for (let c = 7; c <= 12; c++) {
    putCoinTile(lv, c, 8);
  }
  putCoinTile(lv, 9, 6);
  putCoinTile(lv, 10, 6);
  putQuestion(lv, 6, 9);
  putQuestion(lv, 13, 9);
  // 出口水管
  putPipe(lv, 21, 3);
  lv.enterPipes.push({ col: 21, h: 3, kind: 2, exitCol: 0 });
  return lv;
}

/**
 * 按序号构建关卡：4 大世界 × 4 关
 * index: 0..3 世界1（地面/地下/水下/城堡），4..7 世界2，……
 */
export function buildLevel(index: number): LevelData {
  const world = Math.floor(index / 4) + 1;
  const stage = (index % 4) + 1;
  switch (stage) {
    case 1:
      return buildOverworld(world);
    case 2:
      return buildUnderground(world);
    case 3:
      return buildUnderwater(world);
    case 4:
      return buildCastle(world);
  }
  return buildOverworld(1);
}
