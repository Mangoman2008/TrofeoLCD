/**
 * Normalize.ets — 遥测数据归一化（纯逻辑，可离线测试）
 *
 * 为什么需要：UDP 收到的是 JSON.parse 的结果，字段类型完全不可信。
 * 桥端一个改动（比如把 cpu 发成 "52"）就会让 Dashboard 里的 toFixed 抛异常，
 * 而异常发生在帧循环里 → 屏幕一直不出画面，且很难定位。
 *
 * 这里把所有外部输入收敛成强类型 Telemetry：类型不对就回退默认值，数组超长就截断，
 * 字符串超长就裁剪。App 内**唯一**的遥测入口。
 */
// 全部是类型：必须 import type，否则 Node 类型剥离后会当成值导入而报错
import type { Telemetry, TodoItem, AgentInfo, TokenInfo, SystemInfo,
  WeatherInfo, LyricsInfo, PrinterInfo, PrinterTray, BalanceInfo, BridgeEvent,
  SummaryInfo, HealthInfo } from './Types';

/** 原始（未信任）结构：每个字段都是 Object，逐项校验 */
export interface RawTelemetry {
  ts?: Object;
  agent?: Object;
  todos?: Object;
  tokens?: Object;
  system?: Object;
  weather?: Object;
  lyrics?: Object;
  printer?: Object;
  balance?: Object;
  events?: Object;
  summary?: Object;
  health?: Object;
}

interface RawPrinter {
  state?: Object;
  stateLabel?: Object;
  monitorMode?: Object;
  monitorError?: Object;
  connected?: Object;
  online?: Object;
  model?: Object;
  jobName?: Object;
  percent?: Object;
  layer?: Object;
  totalLayer?: Object;
  remainingSec?: Object;
  elapsedSec?: Object;
  eta?: Object;
  nozzleTemp?: Object;
  nozzleTarget?: Object;
  bedTemp?: Object;
  bedTarget?: Object;
  chamberTemp?: Object;
  wifi?: Object;
  coolingFan?: Object;
  heatbreakFan?: Object;
  speedLevel?: Object;
  printError?: Object;
  hms?: Object;
  trayNow?: Object;
  trays?: Object;
}

interface RawTray {
  index?: Object;
  type?: Object;
  color?: Object;
  remain?: Object;
}

interface RawAgent {
  state?: Object;
  activity?: Object;
  tool?: Object;
  lastText?: Object;
  turn?: Object;
  step?: Object;
  project?: Object;
  sessionId?: Object;
  model?: Object;
  provider?: Object;
  errorText?: Object;
}

interface RawTokens {
  todayInput?: Object;
  todayOutput?: Object;
  todayTotal?: Object;
  sessionTotal?: Object;
  contextUsed?: Object;
  contextWindow?: Object;
  costUsd?: Object;
  cacheHitRate?: Object;
}

interface RawSystem {
  cpu?: Object;
  cores?: Object;
  memUsed?: Object;
  memTotal?: Object;
  load1?: Object;
  load5?: Object;
  load15?: Object;
  uptimeSec?: Object;
  host?: Object;
  cpuTemp?: Object;
  battery?: Object;
  charging?: Object;
}

interface RawWeather {
  text?: Object;
  tempC?: Object;
}

interface RawLyrics {
  line?: Object;
  artist?: Object;
  title?: Object;
}

interface RawTodo {
  content?: Object;
  status?: Object;
}

/** 数组/字符串上限，避免异常大报文拖垮渲染 */
export const MAX_TODOS: number = 64;
export const MAX_TEXT: number = 2000;
/** 打印机托盘上限（AMS 4 个槽 + 外挂，再多屏幕也放不下） */
export const MAX_TRAYS: number = 8;

const VALID_PRINTER_STATE: string[] = ['IDLE', 'PREPARE', 'RUNNING', 'PAUSE', 'FINISH',
  'FAILED', 'STUCK', 'OFFLINE', 'UNKNOWN'];

/** 状态码 -> 中文（桥端也会给，这里做兜底，保证面板永远有字可显示） */
export function printerStateLabel(state: string): string {
  if (state === 'IDLE') { return '空闲'; }
  if (state === 'PREPARE') { return '准备中'; }
  if (state === 'RUNNING') { return '打印中'; }
  if (state === 'PAUSE') { return '已暂停'; }
  if (state === 'FINISH') { return '已完成'; }
  if (state === 'FAILED') { return '失败'; }
  if (state === 'STUCK') { return '卡住'; }
  if (state === 'OFFLINE') { return '离线'; }
  return '未知';
}

function optBool(v: Object | undefined): boolean | undefined {
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  return undefined;
}

/** 取整并钳到 [lo, hi]；缺失/非法回退 def */
function clampInt(v: Object | undefined, lo: number, hi: number, def: number): number {
  const n = optNum(v);
  if (n === undefined) {
    return def;
  }
  const r = Math.round(n);
  return r < lo ? lo : (r > hi ? hi : r);
}

/** 颜色统一成 #RRGGBB（拓竹给 8 位 RRGGBBAA，有些地方给 "FF0000FF" 或 "#FF0000"） */
function normColor(v: Object | undefined): string | undefined {
  const s = optStr(v, 16);
  if (s === undefined) {
    return undefined;
  }
  let t = s.trim();
  if (t.startsWith('#')) {
    t = t.substring(1);
  }
  if (t.length < 6) {
    return undefined;
  }
  t = t.substring(0, 6).toUpperCase();
  for (let i = 0; i < 6; i++) {
    const c = t.charAt(i);
    const isHex = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F');
    if (!isHex) {
      return undefined;
    }
  }
  return '#' + t;
}

function normalizeTrays(v: Object | undefined): PrinterTray[] {
  const out: PrinterTray[] = [];
  if (!Array.isArray(v)) {
    return out;
  }
  const arr = v as Object[];
  const lim = arr.length < MAX_TRAYS ? arr.length : MAX_TRAYS;
  for (let i = 0; i < lim; i++) {
    const item = arr[i];
    if (item === null || item === undefined) {
      continue;
    }
    const rt = item as RawTray;
    const type = str(rt.type, '', 16);
    // 空槽（Empty）不值得占位置；但也保留"有颜色没类型"的异常情况
    if (type.length === 0 || type === 'Empty') {
      continue;
    }
    const t: PrinterTray = {};
    t.index = clampInt(rt.index, 0, 99, out.length + 1);
    t.type = type;
    const col = normColor(rt.color);
    if (col !== undefined) {
      t.color = col;
    }
    t.remain = clampInt(rt.remain, 0, 100, -1);
    out.push(t);
  }
  return out;
}

/**
 * 打印机状态归一化。
 * 输入来自桥端（它把 bambu-monitor 的 /api/state 压成一个扁平对象）。
 * 返回 undefined 表示"没有打印机数据"——面板会退回整高的 VM 画面，
 * 所以这里必须严格：只有真的拿到对象才返回结果。
 */
/**
 * 归一化余额。字段类型不可信（JSON 里余额是字符串 "49.47"，也可能整段缺失）。
 * 整个对象缺失 → undefined（面板不画余额行）；数字取不到 → -1。
 */
/** 归一化事件流：最多 12 条，字段类型不可信 */
export function normalizeEvents(v: Object | undefined): BridgeEvent[] | undefined {
  if (v === undefined || v === null || !Array.isArray(v)) {
    return undefined;
  }
  const out: BridgeEvent[] = [];
  const arr = v as Object[];
  for (const it of arr) {
    if (it === null || typeof it !== 'object') {
      continue;
    }
    const r = it as Record<string, Object>;
    const e: BridgeEvent = {};
    e.t = str(r.t, '', 12);
    e.k = str(r.k, 'info', 12);
    e.s = str(r.s, '', 120);
    out.push(e);
    if (out.length >= 12) {
      break;
    }
  }
  return out;
}

/** 归一化一句话摘要 */
export function normalizeSummary(v: Object | undefined): SummaryInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as Record<string, Object>;
  const s: SummaryInfo = {};
  s.text = str(r.text, '', 60);
  s.error = str(r.error, '', 80);
  s.at = num(r.at, 0);
  if (s.text === '' && (s.error === undefined || s.error.length === 0)) {
    return undefined;
  }
  return s;
}

/** 归一化依赖健康（字段缺失按 false） */
export function normalizeHealth(v: Object | undefined): HealthInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as Record<string, Object>;
  const h: HealthInfo = {};
  h.bridge = r.bridge === true;
  h.printer = r.printer === true;
  h.printerState = str(r.printerState, '', 24);
  h.weather = r.weather === true;
  h.summary = r.summary === true;
  h.tokensPerMin = num(r.tokensPerMin, 0);
  return h;
}

export function normalizeBalance(v: Object | undefined): BalanceInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as Record<string, Object>;
  const b: BalanceInfo = {};
  const cur = r.currency;
  b.currency = typeof cur === 'string' && (cur as string).length > 0 ? cur as string : 'CNY';
  b.total = num(r.total, -1);
  b.granted = num(r.granted, -1);
  b.toppedUp = num(r.toppedUp, -1);
  b.available = r.available === true;
  const err = r.error;
  b.error = typeof err === 'string' ? err as string : '';
  b.perHour = num(r.perHour, -1);
  b.etaHours = num(r.etaHours, -1);
  b.spanMin = num(r.spanMin, 0);
  return b;
}

export function normalizePrinter(v: Object | undefined): PrinterInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as RawPrinter;
  const p: PrinterInfo = {};

  let state = str(r.state, 'UNKNOWN', 20).toUpperCase();
  if (VALID_PRINTER_STATE.indexOf(state) < 0) {
    state = 'UNKNOWN';
  }
  p.state = state;
  p.stateLabel = str(r.stateLabel, printerStateLabel(state), 20);
  // 监控服务的状态（凭据问题要如实上屏："监控未登录"，而不是含混的"未知"）
  p.monitorMode = str(r.monitorMode, '', 16);
  p.monitorError = str(r.monitorError, '', 96);
  p.connected = optBool(r.connected);
  p.online = optBool(r.online);
  p.model = str(r.model, '', 60);
  p.jobName = str(r.jobName, '', 120);
  p.eta = str(r.eta, '', 10);
  p.wifi = str(r.wifi, '', 16);
  p.percent = clampInt(r.percent, 0, 100, -1);
  p.layer = clampInt(r.layer, 0, 100000, -1);
  p.totalLayer = clampInt(r.totalLayer, 0, 100000, -1);
  p.remainingSec = clampInt(r.remainingSec, 0, 864000, -1);
  p.elapsedSec = clampInt(r.elapsedSec, 0, 864000, -1);
  // 温度：-1 表示"这台机器没有这个传感器"
  p.nozzleTemp = clampInt(r.nozzleTemp, -1, 400, -1);
  p.nozzleTarget = clampInt(r.nozzleTarget, -1, 400, -1);
  p.bedTemp = clampInt(r.bedTemp, -1, 200, -1);
  p.bedTarget = clampInt(r.bedTarget, -1, 200, -1);
  p.chamberTemp = clampInt(r.chamberTemp, -1, 100, -1);
  p.coolingFan = clampInt(r.coolingFan, -1, 100, -1);
  p.heatbreakFan = clampInt(r.heatbreakFan, -1, 100, -1);
  p.speedLevel = clampInt(r.speedLevel, 0, 4, -1);
  // 拓竹的 print_error 是 32 位码（实测 83951617 这种 8 位数），别用小上限截掉
  p.printError = clampInt(r.printError, 0, 4294967295, 0);
  p.trayNow = clampInt(r.trayNow, -1, 99, -1);

  // HMS 告警：只要条数和第一条短码，面板位置有限
  let hmsCount = 0;
  let hmsCode = '';
  const hms = r.hms;
  if (Array.isArray(hms)) {
    const list = hms as Object[];
    hmsCount = list.length;
    if (hmsCount > 0) {
      const first = list[0];
      if (first !== null && first !== undefined) {
        hmsCode = str((first as Record<string, Object>).code, '', 40);
      }
    }
  }
  p.hmsCount = hmsCount;
  p.hmsCode = hmsCode;
  p.trays = normalizeTrays(r.trays);
  return p;
}

// ---------- 基础类型收敛 ----------

export function num(v: Object | undefined, def: number): number {
  if (typeof v === 'number') {
    const n = v as number;
    return isFinite(n) ? n : def;
  }
  if (typeof v === 'string') {
    const parsed = Number.parseFloat(v as string);
    return isFinite(parsed) ? parsed : def;
  }
  return def;
}

export function str(v: Object | undefined, def: string, max: number = MAX_TEXT): string {
  if (typeof v !== 'string') {
    return def;
  }
  const s = v as string;
  if (s.length <= max) {
    return s;
  }
  return s.substring(0, max);
}

function optNum(v: Object | undefined): number | undefined {
  if (typeof v === 'number') {
    const n = v as number;
    return isFinite(n) ? n : undefined;
  }
  if (typeof v === 'string') {
    const parsed = Number.parseFloat(v as string);
    return isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

function optStr(v: Object | undefined, max: number = MAX_TEXT): string | undefined {
  if (typeof v !== 'string') {
    return undefined;
  }
  const s = v as string;
  return s.length <= max ? s : s.substring(0, max);
}

const VALID_STATUS: string[] = ['pending', 'in_progress', 'completed'];
const VALID_STATE: string[] = ['idle', 'busy', 'waiting', 'unknown'];

// ---------- 各段归一化 ----------

export function normalizeTodos(v: Object | undefined): TodoItem[] {
  const out: TodoItem[] = [];
  if (!Array.isArray(v)) {
    return out;
  }
  const arr = v as Object[];
  const lim = arr.length < MAX_TODOS ? arr.length : MAX_TODOS;
  for (let i = 0; i < lim; i++) {
    const item = arr[i];
    if (item === null || item === undefined) {
      continue;
    }
    const rt = item as RawTodo;
    const content = str(rt.content, '', 200);
    if (content.length === 0) {
      continue;
    }
    let status = str(rt.status, 'pending', 20);
    if (VALID_STATUS.indexOf(status) < 0) {
      status = 'pending';
    }
    const t: TodoItem = { content: content, status: status };
    out.push(t);
  }
  return out;
}

function normalizeAgent(v: Object | undefined): AgentInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as RawAgent;
  const a: AgentInfo = {};
  let state = str(r.state, 'unknown', 20);
  if (VALID_STATE.indexOf(state) < 0) {
    state = 'unknown';
  }
  a.state = state;
  a.activity = str(r.activity, '空闲', 120);
  a.tool = str(r.tool, '', 60);
  a.lastText = str(r.lastText, '', MAX_TEXT);
  a.errorText = str(r.errorText, '', 120);
  a.project = str(r.project, '（未知项目）', 120);
  a.sessionId = optStr(r.sessionId, 120);
  a.model = optStr(r.model, 80);
  a.provider = optStr(r.provider, 80);
  a.turn = optNum(r.turn);
  a.step = optNum(r.step);
  return a;
}

function normalizeTokens(v: Object | undefined): TokenInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as RawTokens;
  const t: TokenInfo = {};
  t.todayInput = num(r.todayInput, 0);
  t.todayOutput = num(r.todayOutput, 0);
  const total = optNum(r.todayTotal);
  t.todayTotal = total !== undefined ? total : (t.todayInput + t.todayOutput);
  t.sessionTotal = optNum(r.sessionTotal);
  t.contextUsed = num(r.contextUsed, 0);
  t.contextWindow = num(r.contextWindow, 0);
  t.costUsd = optNum(r.costUsd);
  t.cacheHitRate = optNum(r.cacheHitRate);
  // 负数没有意义，钳到 0
  if (t.todayInput < 0) {
    t.todayInput = 0;
  }
  if (t.todayOutput < 0) {
    t.todayOutput = 0;
  }
  if (t.contextUsed < 0) {
    t.contextUsed = 0;
  }
  if (t.todayTotal < 0) {
    t.todayTotal = 0;
  }
  return t;
}

function normalizeSystem(v: Object | undefined): SystemInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as RawSystem;
  const s: SystemInfo = {};
  s.cpu = Math.max(0, Math.min(100, num(r.cpu, 0)));
  s.cores = Math.max(0, Math.round(num(r.cores, 0)));
  s.memUsed = Math.max(0, num(r.memUsed, 0));
  s.memTotal = Math.max(0, num(r.memTotal, 0));
  s.load1 = num(r.load1, 0);
  s.load5 = num(r.load5, 0);
  s.load15 = num(r.load15, 0);
  s.uptimeSec = Math.max(0, num(r.uptimeSec, 0));
  s.host = str(r.host, 'localhost', 120);
  s.cpuTemp = num(r.cpuTemp, -1);
  s.battery = Math.max(-1, Math.min(100, Math.round(num(r.battery, -1))));
  if (typeof r.charging === 'boolean') {
    s.charging = r.charging as boolean;
  }
  return s;
}

function normalizeWeather(v: Object | undefined): WeatherInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as RawWeather;
  const text = str(r.text, '', 60);
  if (text.length === 0) {
    return undefined;
  }
  const w: WeatherInfo = { text: text, tempC: optNum(r.tempC) };
  return w;
}

function normalizeLyrics(v: Object | undefined): LyricsInfo | undefined {
  if (v === undefined || v === null || typeof v !== 'object') {
    return undefined;
  }
  const r = v as RawLyrics;
  const line = str(r.line, '', 200);
  if (line.length === 0) {
    return undefined;
  }
  const l: LyricsInfo = { line: line, artist: optStr(r.artist, 80), title: optStr(r.title, 80) };
  return l;
}

/** 唯一入口：任何来源的 JSON 都收敛成强类型 Telemetry */
export function normalizeTelemetry(raw: Object | undefined | null): Telemetry {
  const t: Telemetry = {};
  if (raw === undefined || raw === null || typeof raw !== 'object') {
    return t;
  }
  const r = raw as RawTelemetry;
  t.ts = optNum(r.ts);
  t.agent = normalizeAgent(r.agent);
  t.todos = normalizeTodos(r.todos);
  t.tokens = normalizeTokens(r.tokens);
  t.system = normalizeSystem(r.system);
  t.weather = normalizeWeather(r.weather);
  t.lyrics = normalizeLyrics(r.lyrics);
  t.printer = normalizePrinter(r.printer);
  t.balance = normalizeBalance(r.balance);
  t.events = normalizeEvents(r.events);
  t.summary = normalizeSummary(r.summary);
  t.health = normalizeHealth(r.health);
  return t;
}
