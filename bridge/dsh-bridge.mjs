#!/usr/bin/env node
/**
 * dsh-bridge.mjs — DSH 会话状态 → 鸿蒙 LCD 应用的数据桥
 *
 * 读取 ~/.dsh/sessions/<cwd-slug>/session-<uuid>/session.jsonl.zstd
 * 通过 UDP 把 JSON 遥测推给鸿蒙应用（默认 127.0.0.1:54545）。
 *
 * 关键优化：该 zstd 文件由大量独立帧组成（DSH 每次 flush 写一帧），
 * 因此只解压文件尾部的若干帧即可拿到最新状态，无需全量解压 40MB+。
 * 只有"今日 token 总量"这类累计值才需要低频全量扫描（默认 60s 一次）。
 *
 * 用法：
 *   node dsh-bridge.mjs            # 常驻推送（纯本地，不联网）
 *   node dsh-bridge.mjs --once     # 打印一次 JSON 后退出（调试）
 *   node dsh-bridge.mjs --port 54545 --interval 1000
 *   node dsh-bridge.mjs --host 192.168.1.50        # 推给局域网里的机器（如 Windows 版 dshlcd.exe）
 *
 * 可选（默认关闭，开启后才会联网/执行外部命令）：
 *   --weather 北京                 天气（wttr.in，无需 API key，15 分钟刷新）
 *   --lyrics-cmd "<命令>"          歌词：命令 stdout 的最后一行作为当前歌词
 *   --printer <url>                拓竹打印机状态（读 bambu-monitor 的 /api/state）
 *   --printer-fake [run|idle|error|offline]  离线造打印机数据（不连打印机，用来验面板）
 */

import { createSocket } from 'node:dgram';
import { createServer } from 'node:http';
import { execFile, spawn } from 'node:child_process';
import { readFileSync, writeFileSync, statSync, readdirSync, existsSync } from 'node:fs';
import { createInterface } from 'node:readline';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ---------------- 配置 ----------------
// ★ Windows 兼容（2026-10-15）：`os.homedir()` 在部分 Windows 环境返回空串
//   （USERPROFILE / HOMEDRIVE+HOMEPATH 都没设时），于是 HOME='' →
//   SESSIONS_ROOT 变成**相对路径** `.dsh/sessions`，在任意工作目录下都不存在 →
//   桥读不到会话 → 所有遥测都是空默认值（state=idle、tool 空、tokens 全 0）。
//   实测症状：桥每秒都在发包、程序也收到了（telemetryPackets 在涨），但屏幕上"没有相关数据"。
//   这里按平台依次回退，取到第一个存在的目录。
const HOME = (() => {
  const cands = [];
  try { cands.push(os.homedir()); } catch (e) { /* ignore */ }
  cands.push(process.env.USERPROFILE);
  if (process.env.HOMEDRIVE && process.env.HOMEPATH) {
    cands.push(process.env.HOMEDRIVE + process.env.HOMEPATH);
  }
  cands.push(process.env.HOME);
  for (const c of cands) {
    if (c && existsSync(c)) return c;
  }
  return cands.find((c) => c && c.length > 0) || '';
})();
// ★ 可选覆盖：DSH 跑在**另一台机器**时（例：鸿蒙 PC），
//   这台 Windows 上根本没有 ~/.dsh/sessions —— 桥读不到会话，
//   所有遥测就都是空默认值（屏幕上“没有相关数据”）。
//   用 --sessions-root <路径> 指向共享目录（网络映射或拷贝都行）。
const _srootIdx = process.argv.indexOf('--sessions-root');
const SESSIONS_OVERRIDE = (_srootIdx >= 0 && process.argv[_srootIdx + 1])
  ? process.argv[_srootIdx + 1] : '';
const SESSIONS_ROOT = SESSIONS_OVERRIDE
  ? path.resolve(SESSIONS_OVERRIDE)
  : path.join(HOME, '.dsh', 'sessions');

/** DeepSeek 单价（美元 / 百万 token）。填 0 则不显示花费。 */
const PRICING = {
  inputPerM: 0,
  outputPerM: 0,
  cacheReadPerM: 0,
};

/** 尾部读取的压缩字节数（越大覆盖越久，CPU 略增） */
const TAIL_BYTES = 262144;
/** 尾部解码时向前回退的帧数（保证拿到完整上下文） */
const TAIL_FRAMES_BACK = 24;
/** 全量扫描（今日 token 累计）间隔 */
const FULL_SCAN_MS = 60000;

const argv = process.argv.slice(2);
const ONCE = argv.includes('--once');

function argValue(name, def) {
  const i = argv.indexOf(name);
  if (i >= 0 && i + 1 < argv.length) {
    return argv[i + 1];
  }
  return def;
}

const PORT = Number(argValue('--port', '54545'));
// 默认只推本机（鸿蒙应用与桥在同一台机器上）；跨机给 Windows 版用时指定 --host
const HOST = argValue('--host', process.env.DSH_LCD_HOST || '127.0.0.1');
const INTERVAL = Number(argValue('--interval', '1000'));
/** 天气城市（空 = 关闭天气，不联网） */
const WEATHER_CITY = argValue('--weather', '');
/** 歌词命令（空 = 关闭歌词） */
const LYRICS_CMD = argValue('--lyrics-cmd', '');

/**
 * zstd 可执行文件的解析（★ Windows 兼容性修复 2026-10-15）
 *
 * 原来这里直接 `spawn('zstd', ...)`，靠 PATH 找到它。这在 Linux/鸿蒙上成立，
 * 但 **Windows 的 PATH 里没有 zstd**（它不是系统自带命令），于是桥在 Windows 上
 * 解不开 session.jsonl.zstd —— 表现是"桥起来了但永远没有遥测"。
 *
 * 解析顺序（谁先找到用谁）：
 *   1. 环境变量 `DSH_LCD_ZSTD`（用户显式指定，最可靠）
 *   2. **脚本同目录**下的 `zstd.exe` / `zstd`（推荐做法：把 zstd 跟桥放一起，
 *      这样不依赖用户改 PATH —— 见 docs 里的 Windows 部署说明）
 *   3. PATH 里的 `zstd`（Linux/鸿蒙 的既有行为，完全不变）
 */
const ZSTD_BIN = (() => {
  const envBin = process.env.DSH_LCD_ZSTD;
  if (envBin && existsSync(envBin)) return envBin;
  // ★ 用官方 `fileURLToPath` 而不是手撸 `new URL().pathname`：
  //   pathname 在 Windows 上会给出 `/C:/...`（要额外去前导斜杠），
  //   而且**路径含空格时是 `%20` 编码**（例：放在 `C:\Program Files\...`）
  //   → 拼出来的路径 existsSync 永远为 false，于是静默退回 PATH，桥又变成"没数据"。
  //   fileURLToPath 把这两件事都处理对了。
  let here = process.cwd();
  try {
    here = path.dirname(fileURLToPath(import.meta.url));
  } catch (e) {
    // 极端情况下退回工作目录（不致命：下面还有 PATH 兜底）
  }
  const cands = process.platform === 'win32'
    ? ['zstd.exe', 'zstd']
    : ['zstd', 'zstd.exe'];
  for (const c of cands) {
    const full = path.join(here, c);
    if (existsSync(full)) return full;
  }
  return 'zstd';   // 退回 PATH（Linux/鸿蒙 的既有行为）
})();
/**
 * 打印机状态源。
 * 默认关闭（不发 printer 段 → 屏幕上的打印机卡片不出现，布局与旧版一致）。
 * 打开后每 PRINTER_INTERVAL 拉一次 bambu-monitor 的 /api/state，压成扁平结构发出去。
 */
const PRINTER_URL = argValue('--printer', '');
/** 离线造数：run=正在打印 / idle=空闲 / error=有 HMS 告警 / offline=离线 */
const PRINTER_FAKE = argValue('--printer-fake', '');
// ---- DeepSeek 账户余额（可选，开启后才会联网）----
// key 只从文件/环境变量读，**不进命令行**（命令行会出现在进程列表里）；
// 日志里只打印掩码，绝不打印完整 key。
const DS_KEY_FILE = argValue('--deepseek-key-file',
  process.env.HOME + '/.config/dsh-lcd/deepseek.key');
const DS_BALANCE_RAW = (() => {
  const i = argv.indexOf('--deepseek-balance');
  if (i < 0) return null;
  const v = argv[i + 1];
  return (v && /^[0-9]+$/.test(v)) ? Number(v) : 300;   // 默认 5 分钟一次
})();
const DS_BALANCE_SEC = DS_BALANCE_RAW;
const PRINTER_INTERVAL = Number(argValue('--printer-interval', '5000'));

// ---- LLM 一句话摘要（可选）----
// 把助手"最后说的话"摘要成一行人话显示在屏上。默认关闭（会把文本发到 DeepSeek API）。
const SUMMARY_SEC = (() => {
  const i = argv.indexOf('--summary');
  if (i < 0) return null;
  const v = argv[i + 1];
  return (v && /^[0-9]+$/.test(v)) ? Number(v) : 90;
})();
const SUMMARY_MODEL = argValue('--summary-model', 'deepseek-chat');

// ---- 自定义背景图（可选）----
// 桥起一个极小的静态服务，把一张本地图片提供给屏上的应用（应用侧已有 http 权限，无需新权限）。
const BG_PATH = argValue('--bg', '');
const BG_PORT = Number(argValue('--bg-port', '54547'));
/** 打印机离线判定：连续失败这么多次就报 OFFLINE（避免一次抖动就把画面翻成离线） */
const PRINTER_MAX_FAILS = 3;
// 打印机状态变量必须在这里声明：本文件把 `await main()` 放在中部，
// 而 let/const 不像函数声明那样提升，声明写在调用之后会直接 TDZ 报错（踩过）
let printerState;
let printerFails = 0;
let printerLastAt = 0;
const WEATHER_INTERVAL = 15 * 60 * 1000;
const LYRICS_INTERVAL = 3000;

/** wttr.in 的英文天况 -> 中文（只映射常见项，未命中则原样显示） */
const WEATHER_CN = {
  'Sunny': '晴', 'Clear': '晴', 'Partly cloudy': '多云', 'Cloudy': '多云',
  'Overcast': '阴', 'Mist': '薄雾', 'Fog': '雾', 'Haze': '霾',
  'Smoky haze': '烟霾', 'Light rain': '小雨', 'Patchy rain nearby': '零星小雨',
  'Moderate rain': '中雨', 'Heavy rain': '大雨', 'Light drizzle': '毛毛雨',
  'Thundery outbreaks in nearby': '雷阵雨', 'Patchy light rain with thunder': '雷阵雨',
  'Light snow': '小雪', 'Moderate snow': '中雪', 'Heavy snow': '大雪',
  'Blowing snow': '风吹雪', 'Sleet': '雨夹雪', 'Freezing fog': '冻雾',
};

// ---------------- 工具 ----------------

/** cwd-slug -> 真实路径（DSH 用 '-' 替换 '/'） */
function slugToPath(slug) {
  let s = slug;
  if (s.startsWith('--')) s = s.slice(2);
  if (s.endsWith('--')) s = s.slice(0, -2);
  return '/' + s.split('-').join('/');
}

/** 找最近的会话文件 */
function findNewestSession() {
  if (!existsSync(SESSIONS_ROOT)) {
    return null;
  }
  let best = null;
  for (const slug of readdirSync(SESSIONS_ROOT)) {
    const slugDir = path.join(SESSIONS_ROOT, slug);
    let entries;
    try {
      entries = readdirSync(slugDir);
    } catch {
      continue;
    }
    for (const name of entries) {
      // ★ 2026-10-15 修：这里只认 `session.jsonl.zstd`，但 **活跃会话写的是
      //   `session.v4.jsonl.zstd`**（见下方第 870 行的读取顺序）。
      //   于是选会话时会挑到旧的/空的那个，甚至挑不到 ——
      //   表现是“桥在发包、程序也收到了，但所有数值都是空默认值”（屏幕上没数据）。
      //   这里与读取侧保持一致，两个名字都认。
      const cands = ['session.v4.jsonl.zstd', 'session.jsonl.zstd'];
      let file = null;
      for (const cf of cands) {
        const cand = path.join(slugDir, name, cf);
        try { if (statSync(cand).isFile()) { file = cand; break; } } catch { /* try next */ }
      }
      if (!file) continue;
      try {
        const st = statSync(file);
        if (!st.isFile()) continue;
        if (!best || st.mtimeMs > best.mtimeMs) {
          best = { file, mtimeMs: st.mtimeMs, size: st.size, slug, session: name };
        }
      } catch {
        // ignore
      }
    }
  }
  return best;
}

/**
 * 读最后 TAIL_BYTES 压缩数据，从某个 zstd 帧边界开始解码，返回行数组。
 *
 * 注意：Node 内置的 zstdDecompressSync 只解第一个帧（该文件由数千个独立帧拼接），
 * 因此这里用 zstd CLI 通过 stdin 流式解码（fsync 可容忍尾部未写完的帧）。
 */
function tailLines(file, framesBack = TAIL_FRAMES_BACK) {
  return new Promise((resolve) => {
    let st;
    try {
      st = statSync(file);
    } catch {
      resolve([]);
      return;
    }
    if (st.size === 0) {
      resolve([]);
      return;
    }
    const len = Math.min(TAIL_BYTES, st.size);
    let buf;
    try {
      const all = readFileSync(file);
      buf = all.subarray(st.size - len);
    } catch {
      resolve([]);
      return;
    }

    // 找 zstd 帧魔数 28 B5 2F FD
    const magic = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
    const starts = [];
    let i = 0;
    while (true) {
      i = buf.indexOf(magic, i);
      if (i < 0) break;
      starts.push(i);
      i += 4;
    }
    if (starts.length === 0) {
      resolve([]);
      return;
    }

    const from = Math.max(0, starts.length - 1 - framesBack);
    const slice = buf.subarray(starts[from]);

    const child = spawn(ZSTD_BIN, ['-dc', '-q'], { stdio: ['pipe', 'pipe', 'ignore'] });
    const chunks = [];
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      const text = Buffer.concat(chunks).toString('utf8');
      resolve(text.split('\n').filter((l) => l.length > 0));
    };
    child.stdout.on('data', (c) => chunks.push(c));
    child.on('close', finish);
    child.on('error', () => {
      done = true;
      resolve([]);
    });
    setTimeout(() => {
      if (!done) {
        try { child.kill('SIGKILL'); } catch { /* ignore */ }
        finish();
      }
    }, 4000);
    try {
      child.stdin.end(slice);
    } catch {
      finish();
    }
  });
}

const TOOL_LABEL = {
  bash: '执行命令',
  read: '读取文件',
  write: '写入文件',
  edit: '编辑文件',
  glob: '查找文件',
  grep: '搜索代码',
  web_search: '联网搜索',
  todo_write: '更新任务',
  todo_read: '读取任务',
  subagent: '派生子任务',
  subagent_fork: '派生子任务',
  ask_user_question: '等待你选择',
  create_goal: '建立目标',
  update_goal: '更新目标',
  workflow: '编排工作流',
  ralph: '迭代执行',
  skill: '加载技能',
};

function stripMarkdown(s) {
  return s
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/\*\*([^*]*)\*\*/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/\|/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function textOfAssistant(data) {
  const msg = data?.message;
  if (!msg || !Array.isArray(msg.content)) return '';
  let out = '';
  for (const part of msg.content) {
    if (part && part.type === 'text' && typeof part.text === 'string') {
      out += part.text;
    }
  }
  return out;
}

// ---------------- 会话事件解析（尾部）----------------
class LiveState {
  constructor() {
    this.project = '';
    this.sessionId = '';
    this.tool = '';
    this.activity = '';
    this.lastText = '';
    this.turn = 0;
    this.step = 0;
    this.model = '';
    this.provider = '';
    this.todos = [];
    this.state = 'idle';
    this.contextUsed = 0;
    this.contextWindow = 0;
    this.lastEventTs = 0;
    this.lastTurnEndTs = 0;
    this.turnEndReason = '';
    this.errorText = '';
    this.lastUsage = null;
    this.usageSum = { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, reasoningTokens: 0 };
  }
}

function parseTail(lines, prev) {
  const st = new LiveState();
  Object.assign(st, {
    project: prev.project,
    sessionId: prev.sessionId,
    model: prev.model,
    provider: prev.provider,
    contextWindow: prev.contextWindow,
    turnEndReason: prev.turnEndReason,
    lastTurnEndTs: prev.lastTurnEndTs,
    lastText: prev.lastText,
  });

  let sawTurnEnd = false;
  let lastUserTs = 0;
  let lastWorkTs = 0;

  for (const line of lines) {
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    const type = o.type;
    const data = o.data ?? {};
    const ts = typeof o.time === 'number' ? o.time : 0;

    if (type === 'session') {
      st.sessionId = o.id ?? st.sessionId;
    } else if (type === 'request/context') {
      st.model = data.model ?? st.model;
      st.provider = data.provider ?? st.provider;
      if (typeof data.contextWindow === 'number') st.contextWindow = data.contextWindow;
    } else if (type === 'tool/call') {
      st.tool = data.name ?? st.tool;
      st.activity = TOOL_LABEL[st.tool] ?? `调用 ${st.tool}`;
      st.turn = data.turn ?? st.turn;
      st.step = data.step ?? st.step;
      lastWorkTs = ts;
      st.lastEventTs = Math.max(st.lastEventTs, ts);
    } else if (type === 'assistant/message') {
      const t = textOfAssistant(data);
      if (t.length > 0) st.lastText = stripMarkdown(t);
      st.turn = data.turn ?? st.turn;
      st.step = data.step ?? st.step;
      if (data.usage) {
        st.lastUsage = data.usage;
        st.usageSum.inputTokens += data.usage.inputTokens ?? 0;
        st.usageSum.outputTokens += data.usage.outputTokens ?? 0;
        st.usageSum.cacheReadTokens += data.usage.cacheReadTokens ?? 0;
        st.usageSum.reasoningTokens += data.usage.reasoningTokens ?? 0;
        // 最近一次请求的输入量 ≈ 当前上下文占用
        st.contextUsed = (data.usage.inputTokens ?? 0) + (data.usage.cacheReadTokens ?? 0);
      }
      lastWorkTs = ts;
      st.lastEventTs = Math.max(st.lastEventTs, ts);
    } else if (type === 'user/message') {
      lastUserTs = ts;
      st.lastEventTs = Math.max(st.lastEventTs, ts);
    } else if (type === 'turn/start') {
      st.turn = data.turn ?? st.turn;
      lastWorkTs = ts;
      st.lastEventTs = Math.max(st.lastEventTs, ts);
    } else if (type === 'turn/end') {
      st.turnEndReason = data.reason?.kind ?? '';
      if (data.reason?.kind === 'error') {
        st.errorText = data.reason?.error?.message ?? 'unknown error';
      } else {
        st.errorText = '';
      }
      st.lastTurnEndTs = ts;
      sawTurnEnd = true;
      st.lastEventTs = Math.max(st.lastEventTs, ts);
    } else if (type === 'todo/write') {
      st.todos = Array.isArray(data.todos) ? data.todos : [];
    } else if (type === 'compaction/prune') {
      // 上下文被压缩，粗略抵扣
      const cut = data.shadowedTokenCount ?? 0;
      st.contextUsed = Math.max(0, st.contextUsed - cut);
    }
  }

  // 状态机：有比最后一个 turn/end 更新的工作事件 -> busy
  const now = Date.now();
  if (lastWorkTs > st.lastTurnEndTs) {
    st.state = 'busy';
  } else if (sawTurnEnd || st.lastTurnEndTs > 0) {
    if (st.turnEndReason === 'completed') {
      st.state = now - st.lastTurnEndTs < 15000 ? 'waiting' : 'idle';
      if (st.state === 'waiting') st.activity = '已完成，等待你输入';
    } else if (st.turnEndReason === 'error') {
      st.state = 'waiting';
      st.activity = '出错了：' + (st.errorText || '').slice(0, 60);
    } else {
      st.state = now - st.lastTurnEndTs < 15000 ? 'waiting' : 'idle';
      if (st.state === 'waiting') st.activity = '已中断';
    }
  } else {
    st.state = 'idle';
  }
  if (st.state === 'idle' && st.activity === '') {
    st.activity = '空闲';
  }
  return st;
}

// ---------------- 全量扫描：今日 token 累计 + 元信息 ----------------
async function fullScanToday(file) {
  return new Promise((resolve) => {
    const usage = { inputTokens: 0, outputTokens: 0, total: 0, turns: 0 };
    const meta = { model: '', provider: '', contextWindow: 0 };
    const startOfDay = new Date();
    startOfDay.setHours(0, 0, 0, 0);
    const dayStart = startOfDay.getTime();

    const child = spawn(ZSTD_BIN, ['-dc', '-q', file], { stdio: ['ignore', 'pipe', 'ignore'] });
    const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
    rl.on('line', (line) => {
      const hasUsage = line.indexOf('"usage"') >= 0;
      const hasCtx = line.indexOf('"request/context"') >= 0;
      if (!hasUsage && !hasCtx) return;
      let o;
      try {
        o = JSON.parse(line);
      } catch {
        return;
      }
      if (o.type === 'request/context') {
        meta.model = o.data?.model ?? meta.model;
        meta.provider = o.data?.provider ?? meta.provider;
        if (typeof o.data?.contextWindow === 'number') meta.contextWindow = o.data.contextWindow;
        return;
      }
      if (o.type !== 'assistant/message') return;
      const ts = typeof o.time === 'number' ? o.time : 0;
      const u = o.data?.usage;
      if (!u) return;
      if (ts >= dayStart) {
        usage.turns++;
        usage.inputTokens += u.inputTokens ?? 0;
        usage.outputTokens += u.outputTokens ?? 0;
      }
    });
    child.on('close', () => {
      usage.total = usage.inputTokens + usage.outputTokens;
      resolve({ usage, meta });
    });
    child.on('error', () => resolve({ usage, meta }));
  });
}

// ---------------- 系统指标 ----------------
let prevCpu = null;

function readCpu() {
  try {
    const line = readFileSync('/proc/stat', 'utf8').split('\n')[0];
    const f = line.trim().split(/\s+/).slice(1).map(Number);
    const idle = f[3] + (f[4] ?? 0);
    const total = f.reduce((a, b) => a + b, 0);
    return { idle, total };
  } catch {
    return null;
  }
}

function cpuPercent() {
  const cur = readCpu();
  if (!cur) return 0;
  if (!prevCpu) {
    prevCpu = cur;
    return 0;
  }
  const dTotal = cur.total - prevCpu.total;
  const dIdle = cur.idle - prevCpu.idle;
  prevCpu = cur;
  if (dTotal <= 0) return 0;
  return Math.max(0, Math.min(100, (1 - dIdle / dTotal) * 100));
}

function memory() {
  try {
    const txt = readFileSync('/proc/meminfo', 'utf8');
    const get = (k) => {
      const m = txt.match(new RegExp('^' + k + ':\\s+(\\d+) kB', 'm'));
      return m ? Number(m[1]) * 1024 : 0;
    };
    const total = get('MemTotal');
    const avail = get('MemAvailable');
    return { usedMB: Math.round((total - avail) / 1048576), totalMB: Math.round(total / 1048576) };
  } catch {
    const total = os.totalmem();
    const free = os.freemem();
    return { usedMB: Math.round((total - free) / 1048576), totalMB: Math.round(total / 1048576) };
  }
}

/**
 * DeepSeek 账户余额：GET https://api.deepseek.com/user/balance
 *   返回 { is_available, balance_infos: [{ currency, total_balance, granted_balance, topped_up_balance }] }
 * key 只从文件/环境变量读（命令行会出现在进程列表里）；日志只打掩码。
 * 失败时保留上一次的值并记下错误，面板不会因为一次网络抖动就空掉。
 */
let balanceState = undefined;
let balanceErr = '';
/** 余额采样历史（用于算"每小时烧多少 / 还能用多久"） */
const balanceHist = [];
/** 最近的 token 速率采样 */
let tokenRate = { perMin: 0, at: 0, lastTotal: -1 };
// 注意：livepad / USB 的可达性只有**应用侧**知道（它自己去抓 VM 帧、自己开 USB），
// 桥只能报自己能看到的（打印机/天气/摘要/余额）。健康看板由应用合并两边。

/**
 * 按余额历史算燃烧速率与预计可用时长。
 * 需要至少两个跨 >=5 分钟的采样点，否则返回 -1（宁可不显示，也不瞎猜）。
 */
function burnStats() {
  if (balanceState === undefined || balanceHist.length < 2) {
    return { perHour: -1, etaHours: -1, spanMin: 0 };
  }
  const first = balanceHist[0];
  const last = balanceHist[balanceHist.length - 1];
  const spanMin = (last.at - first.at) / 60000;
  if (spanMin < 5) {
    return { perHour: -1, etaHours: -1, spanMin };
  }
  const spent = first.total - last.total;
  if (spent <= 0) {
    // 没花钱（或充值了）：速率为 0，ETA 视为无限
    return { perHour: 0, etaHours: -1, spanMin };
  }
  const perHour = spent / (spanMin / 60);
  const etaHours = perHour > 0 ? last.total / perHour : -1;
  return { perHour, etaHours, spanMin };
}

async function refreshBalance() {
  let key = '';
  try {
    key = readFileSync(DS_KEY_FILE, 'utf8').trim();
  } catch (e) {
    balanceErr = '读不到 key 文件: ' + DS_KEY_FILE;
    return;
  }
  if (!key) {
    balanceErr = 'key 文件为空';
    return;
  }
  try {
    const res = await fetch('https://api.deepseek.com/user/balance', {
      headers: { Authorization: 'Bearer ' + key },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) {
      balanceErr = 'HTTP ' + res.status;
      return;
    }
    const j = await res.json();
    const infos = Array.isArray(j.balance_infos) ? j.balance_infos : [];
    const first = infos.length > 0 ? infos[0] : {};
    const num = (v) => { const n = Number(v); return isFinite(n) ? n : -1; };
    balanceState = {
      currency: typeof first.currency === 'string' ? first.currency : 'CNY',
      total: num(first.total_balance),
      granted: num(first.granted_balance),
      toppedUp: num(first.topped_up_balance),
      available: j.is_available === true,
      at: Date.now(),
    };
    balanceErr = '';
    if (balanceState.total >= 0) {
      balanceHist.push({ at: balanceState.at, total: balanceState.total });
      const cut = Date.now() - 6 * 3600 * 1000;
      while (balanceHist.length > 2 && balanceHist[0].at < cut) {
        balanceHist.shift();
      }
    }
  } catch (e) {
    balanceErr = '请求失败: ' + (e && e.name ? e.name : String(e));
  }
}

/**
 * 事件环（最近 12 条）：给"诊断风"主题当实时日志流用。
 * 记录：会话开始/切换、状态变化（idle→busy…）、工具变化、待办增减、打印机状态变化、取数错误。
 * 每条：{ t: HH:MM:SS, k: 类型(idle|busy|tool|todo|print|err|info), s: 文本 }
 */
const events = [];
let evLast = { state: '', tool: '', todos: -1, printer: '', step: -1 };

function pushEvent(kind, text) {
  const d = new Date();
  const p2 = (n) => String(n).padStart(2, '0');
  events.push({ t: `${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}`, k: kind, s: text });
  while (events.length > 12) {
    events.shift();
  }
}

/** 每次发帧前调用：把"变了的东西"记成事件（只在变化时记，不刷屏） */
function noteEvents(payload) {
  const a = payload.agent || {};
  if (a.state !== evLast.state) {
    pushEvent(a.state === 'busy' ? 'busy' : (a.state === 'idle' ? 'idle' : 'info'),
      `状态 ${evLast.state || '?'} → ${a.state || '?'}`);
    evLast.state = a.state;
  }
  if (a.tool !== evLast.tool) {
    if (a.tool) pushEvent('tool', `调用工具 ${a.tool}`);
    evLast.tool = a.tool;
  }
  // 步进变化 = 新的助手动作：把"当前在做的那句话"记一条（这才是"证据流"的主要内容）
  if (a.step !== undefined && a.step !== evLast.step) {
    const line = String(a.lastText || a.activity || '').replace(/\s+/g, ' ').slice(0, 70);
    pushEvent('busy', line.length > 0 ? line : `第 ${a.step} 步`);
    evLast.step = a.step;
  }
  const n = (payload.todos || []).length;
  const done = (payload.todos || []).filter((t) => t.status === 'completed').length;
  if (n !== evLast.todos) {
    pushEvent('todo', `待办 ${done}/${n}`);
    evLast.todos = n;
  }
  const pr = payload.printer ? payload.printer.state : '';
  if (pr !== evLast.printer) {
    pushEvent('print', pr ? `打印机 ${pr}` : '打印机离线');
    evLast.printer = pr;
  }
  if (balanceErr) {
    pushEvent('err', `余额取数失败 ${balanceErr}`);
  }
}

/**
 * 一句话摘要：把助手的最后一段话压成一行人话（中文），显示在屏上。
 * 只在文本"实质变化"时调用，避免刷 API；失败保留上一次的摘要。
 */
let summaryState = undefined;
let summaryErr = '';
let summaryLastInput = '';

/** 该不该现在摘要：有足够文本、且还没出过摘要（或文本已换代） */
function maybeSummary() {
  if (SUMMARY_SEC === null) {
    return;
  }
  const src = String(live.lastText || '').trim();
  if (src.length < 8) {
    return;
  }
  refreshSummary(src, live.activity).catch(() => { /* ignore */ });
}

async function refreshSummary(text, activity) {
  const src = String(text || '').replace(/\s+/g, ' ').trim();
  if (src.length < 8) {
    return;
  }
  if (src.slice(0, 400) === summaryLastInput) {
    return;
  }
  let key = '';
  try {
    key = readFileSync(DS_KEY_FILE, 'utf8').trim();
  } catch (e) {
    summaryErr = '读不到 key 文件';
    return;
  }
  if (!key) {
    summaryErr = 'key 文件为空';
    return;
  }
  try {
    const res = await fetch('https://api.deepseek.com/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + key },
      signal: AbortSignal.timeout(20000),
      body: JSON.stringify({
        model: SUMMARY_MODEL,
        max_tokens: 40,
        temperature: 0.3,
        messages: [
          { role: 'system', content: '你是桌面副屏的状态播报器。把用户给的技术工作片段浓缩成一行中文，18 字以内，不要标点结尾，不要引号，直说在做什么。' },
          { role: 'user', content: `当前动作：${activity || '未知'}\n片段：${src.slice(0, 600)}` }
        ]
      })
    });
    if (!res.ok) {
      summaryErr = 'HTTP ' + res.status;
      return;
    }
    const j = await res.json();
    const txt = j && j.choices && j.choices[0] && j.choices[0].message
      ? String(j.choices[0].message.content || '').trim() : '';
    if (txt.length > 0) {
      summaryState = { text: txt.replace(/^["'「]|["'」]$/g, '').slice(0, 40), at: Date.now() };
      summaryErr = '';
      summaryLastInput = src.slice(0, 400);
    }
  } catch (e) {
    summaryErr = '请求失败: ' + (e && e.name ? e.name : String(e));
  }
}

function systemPayload() {
  const load = os.loadavg();
  const mem = memory();
  return {
    cpu: Number(cpuPercent().toFixed(1)),
    cores: os.cpus().length,
    memUsed: mem.usedMB,
    memTotal: mem.totalMB,
    load1: Number(load[0].toFixed(2)),
    load5: Number(load[1].toFixed(2)),
    load15: Number(load[2].toFixed(2)),
    uptimeSec: Math.round(os.uptime()),
    host: os.hostname(),
  };
}

// ---------------- 可选：天气 / 歌词 ----------------

async function fetchWeatherNow() {
  const url = `https://wttr.in/${encodeURIComponent(WEATHER_CITY)}?format=%C|%t&m`;
  await fetch(url, { signal: AbortSignal.timeout(10000) })
    .then((r) => (r.ok ? r.text() : Promise.reject(new Error('HTTP ' + r.status))))
    .then((txt) => {
      const parts = txt.trim().split('|');
      const cond = (parts[0] ?? '').trim();
      const tempRaw = (parts[1] ?? '').trim();
      const m = tempRaw.match(/-?\d+/);
      weather = {
        text: WEATHER_CN[cond] ?? cond,
        tempC: m ? Number(m[0]) : undefined,
      };
      if (!ONCE) process.stderr.write(`\n[bridge] 天气: ${weather.text} ${weather.tempC}°C\n`);
    })
    .catch((e) => {
      if (!ONCE) process.stderr.write(`\n[bridge] 天气获取失败: ${e.message}\n`);
    });
}

function refreshWeather() {
  if (!WEATHER_CITY) return;
  if (Date.now() - lastWeatherAt < WEATHER_INTERVAL) return;
  lastWeatherAt = Date.now();
  fetchWeatherNow();
}

function refreshLyrics() {
  if (!LYRICS_CMD) return;
  if (Date.now() - lastLyricsAt < LYRICS_INTERVAL) return;
  lastLyricsAt = Date.now();
  // ★ Windows 兼容性修复：`/bin/sh` 在 Windows 上不存在 → 用 cmd.exe。
  //   （`--lyrics-cmd` 本身是可选功能，不指定就完全不会走到这里。）
  const shell = process.platform === 'win32' ? 'cmd.exe' : '/bin/sh';
  const shellArgs = process.platform === 'win32' ? ['/d', '/s', '/c', LYRICS_CMD] : ['-c', LYRICS_CMD];
  execFile(shell, shellArgs, { timeout: 2500, maxBuffer: 1 << 20 }, (err, stdout) => {
    if (err || !stdout) return;
    const lines = stdout.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
    if (lines.length > 0) lyricsLine = lines[lines.length - 1];
  });
}

// ---------------- 主循环 ----------------
let session = null;
let live = new LiveState();
let todayUsage = { inputTokens: 0, outputTokens: 0, total: 0 };
let lastFullScan = 0;
let lastTailKey = '';
let lastPick = 0;
let weather = { text: '', tempC: undefined };
let lyricsLine = '';
let lastWeatherAt = 0;
let lastLyricsAt = 0;

/** 按 mtime 取最新的若干会话候选 */
function candidateSessions(limit) {
  if (!existsSync(SESSIONS_ROOT)) return [];
  const all = [];
  for (const slug of readdirSync(SESSIONS_ROOT)) {
    const slugDir = path.join(SESSIONS_ROOT, slug);
    let entries;
    try {
      entries = readdirSync(slugDir);
    } catch {
      continue;
    }
    for (const name of entries) {
      // ★ DSH 的**活跃会话**写的是 session.v4.jsonl.zstd；session.jsonl.zstd 只在会话
      //   关闭/落盘时才出现。原来只读后者 → 桥一直在追旧会话（实测拿到的 lastText 是
      //   几十轮之前的、token/活动全是过期的）。两个名字都当候选，按 mtime 取最新。
      for (const fname of ['session.v4.jsonl.zstd', 'session.jsonl.zstd']) {
        const file = path.join(slugDir, name, fname);
        try {
          const st = statSync(file);
          if (st.isFile() && st.size > 0) {
            all.push({ file, mtimeMs: st.mtimeMs, size: st.size, slug, session: name, fname });
          }
        } catch {
          // ignore
        }
      }
    }
  }
  all.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return all.slice(0, limit);
}

/** 在候选里挑"最后事件时间最新"的会话，避免选中空的/刚创建的新会话 */
async function pickSession() {
  const cands = candidateSessions(6);
  let best = null;
  for (const c of cands) {
    const lines = await tailLines(c.file, 6);
    let lastTs = 0;
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const o = JSON.parse(lines[i]);
        if (typeof o.time === 'number') {
          lastTs = o.time;
          break;
        }
      } catch {
        // ignore
      }
    }
    if (process.env.DSH_LCD_DEBUG) {
      process.stderr.write(`[debug] cand ${path.basename(c.session)} ${c.fname} mtime=${Math.round(c.mtimeMs)} size=${c.size} lines=${lines.length} lastTs=${lastTs}\n`);
    }
    if (!best || lastTs > best.lastTs) {
      best = { ...c, lastTs, lines };
    }
  }
  return best;
}

async function switchSession(found) {
  const changed = !session || session.file !== found.file;
  session = {
    file: found.file,
    slug: found.slug,
    session: found.session,
    lastTs: found.lastTs,
    size: found.size,
    mtimeMs: found.mtimeMs,
  };
  if (changed) {
    live = new LiveState();
    live.project = path.basename(slugToPath(found.slug));
    live.sessionId = found.session;
    lastFullScan = 0;
    if (!ONCE) {
      console.log(`[bridge] 会话: ${found.session}  项目: ${live.project}`);
    }
  }
  lastPick = Date.now();
  if (found.lines && found.lines.length > 0) {
    live = parseTail(found.lines, live);
    lastTailKey = `${found.size}:${found.mtimeMs}`;
  }
}

async function tick() {
  const needPick = !session ||
    (Date.now() - lastPick > 30000) ||
    (Date.now() - (session.lastTs ?? 0) > 20000);
  if (needPick) {
    const found = await pickSession();
    if (found) {
      await switchSession(found);
    }
  }

  if (session) {
    let st = null;
    try {
      st = statSync(session.file);
    } catch {
      st = null;
    }
    if (st) {
      const key = `${st.size}:${st.mtimeMs}`;
      if (key !== lastTailKey) {
        lastTailKey = key;
        session.size = st.size;
        session.mtimeMs = st.mtimeMs;
        const lines = await tailLines(session.file);
        if (lines.length > 0) {
          live = parseTail(lines, live);
          session.lastTs = live.lastEventTs || session.lastTs;
        }
      }
    }
    if (Date.now() - lastFullScan > FULL_SCAN_MS) {
      lastFullScan = Date.now();
      fullScanToday(session.file).then(({ usage, meta }) => {
        todayUsage = usage;
        if (meta.model) live.model = meta.model;
        if (meta.provider) live.provider = meta.provider;
        if (meta.contextWindow) live.contextWindow = meta.contextWindow;
      }).catch(() => { /* ignore */ });
    }
  }
  return buildPayload();
}

async function main() {
  if (ONCE) {
    // 先采样一次 CPU，再扫描，让 CPU% 与 token 累计都有值
    cpuPercent();
    if (WEATHER_CITY) {
      lastWeatherAt = Date.now();
      try { await fetchWeatherNow(); } catch { /* ignore */ }
    }
    if (LYRICS_CMD) {
      lastLyricsAt = 0;
      refreshLyrics();
      await new Promise((r) => setTimeout(r, 300));
    }
    if (SUMMARY_SEC !== null) {
      // 位置很讲究：① 要在会话扫描之后；② tick() 要跑第二次 ——
      // 第一次 tick 只是建立文件读取位置，lastText 还是空的（实测长度 0）
      await tick();
      await refreshSummary(live.lastText, live.activity);
    }
    if (DS_BALANCE_SEC !== null) {
      await refreshBalance();
      const b = balanceState;
      process.stderr.write('[bridge] DeepSeek 余额: ' + (b
        ? `${b.currency} ${b.total.toFixed(2)}（充值 ${b.toppedUp.toFixed(2)} 赠送 ${b.granted.toFixed(2)}）`
        : `取不到（${balanceErr}）`) + '\n');
    }
    if (PRINTER_URL || PRINTER_FAKE) {
      await refreshPrinter();
    }
    const first = await tick();
    if (process.env.DSH_LCD_DEBUG) {
      process.stderr.write(`[debug] session=${session ? session.file : '(none)'} tailKey=${lastTailKey} lastTextLen=${(live.lastText || '').length}\n`);
    }
    if (session) {
      const { usage, meta } = await fullScanToday(session.file);
      todayUsage = usage;
      if (meta.model) live.model = meta.model;
      if (meta.provider) live.provider = meta.provider;
      if (meta.contextWindow) live.contextWindow = meta.contextWindow;
    }
    await new Promise((r) => setTimeout(r, 250));
    const payload = buildPayload();
    console.log(JSON.stringify(payload, null, 2));
    return;
  }

  // 启动先播一条：否则"诊断终端"主题第一屏是空的（实测亮像素只有 1%）
  pushEvent('info', `桥已启动 · 项目 ${live.project || '?'} · ${live.sessionId || ''}`);
  if (SUMMARY_SEC !== null) {
    process.stderr.write('[bridge] 一句话摘要: 每 ' + SUMMARY_SEC + 's（模型 ' + SUMMARY_MODEL + '）\n');
    // 启动后先密集试几次（首次 lastText 要等 tail 建立位置），出结果后自动停
    let boot = 0;
    const bootTimer = setInterval(() => {
      boot++;
      if (summaryState !== undefined || boot > 8) {
        clearInterval(bootTimer);
        return;
      }
      maybeSummary();
    }, 15000);
    bootTimer.unref();
    setInterval(() => {
      maybeSummary();
    }, SUMMARY_SEC * 1000).unref();
  }

  if (DS_BALANCE_SEC !== null) {
    await refreshBalance();
    const b = balanceState;
    process.stderr.write('[bridge] DeepSeek 余额: ' + (b
      ? `${b.currency} ${b.total.toFixed(2)}（充值 ${b.toppedUp.toFixed(2)} 赠送 ${b.granted.toFixed(2)}）`
      : `取不到（${balanceErr}）`) + '\n');
    setInterval(refreshBalance, DS_BALANCE_SEC * 1000).unref();
  }

  // 背景图：给屏上的应用提供一张本地图片（应用已有 http 权限，不需要新权限）
  if (BG_PATH) {
    try {
      const meta = statSync(BG_PATH);
      const body = readFileSync(BG_PATH);
      createServer((req, res) => {
        if (req.url && req.url.startsWith('/bg')) {
          res.writeHead(200, {
            'Content-Type': BG_PATH.endsWith('.png') ? 'image/png' : 'image/jpeg',
            'Content-Length': body.length,
            'Cache-Control': 'no-store'
          });
          res.end(body);
        } else {
          res.writeHead(404);
          res.end('not found');
        }
      }).listen(BG_PORT, '127.0.0.1');
      process.stderr.write(`[bridge] 背景图: ${BG_PATH} (${meta.size} B) → http://127.0.0.1:${BG_PORT}/bg\n`);
    } catch (e) {
      process.stderr.write(`[bridge] 背景图读取失败: ${e && e.message ? e.message : e}\n`);
    }
  }

  // ★ 写 PID 文件：Windows 的 `start.cmd` 需要它来记录/停止进程。
  //   原来那边用 `wmic process` 反查 —— 而 **Windows 11 已弃用 wmic**，
  //   在很多机器上直接不存在（脚本里虽有 fallback，但拿不到 PID 就没法 stop）。
  //   让进程自己写下 PID 最可靠，且两个平台共用同一套逻辑。
  if (process.argv.includes('--pid-file')) {
    const pidPath = argValue('--pid-file', '');
    if (pidPath) {
      try { writeFileSync(pidPath, String(process.pid)); } catch (e) { /* 不致命 */ }
    }
  }

  // 启动时明确打印“读的是哪个目录” —— 排查“没有数据”时这是第一个要看的
  console.log('[bridge] HOME=' + (HOME || '(empty!)') + '  sessions=' + SESSIONS_ROOT
    + (existsSync(SESSIONS_ROOT) ? ' (exists)' : ' (NOT FOUND!)'));

  const sock = createSocket('udp4');
  const send = () => {
    const payload = buildPayload();
    const buf = Buffer.from(JSON.stringify(payload), 'utf8');
    sock.send(buf, PORT, HOST, (err) => {
      if (err) console.error('[bridge] 发送失败:', err.message);
    });
    const a = payload.agent;
    const doneTodos = payload.todos.filter((t) => t.status === 'completed').length;
    process.stdout.write(
      `\r[${new Date().toLocaleTimeString()}] ${String(a.state).padEnd(7)} ` +
      `工具=${String(a.tool || '-').padEnd(14)} ` +
      `轮次=${a.turn || 0}/${a.step || 0} ` +
      `待办=${doneTodos}/${payload.todos.length} ` +
      (payload.printer ? `打印=${payload.printer.stateLabel || payload.printer.state} ` + (payload.printer.percent >= 0 ? `${payload.printer.percent}% ` : '') : '') +
      `CPU=${payload.system.cpu}%   `
    );
  };

  const loop = async () => {
    try {
      await tick();
    } catch (e) {
      console.error('[bridge] tick 异常:', e.message);
    }
    refreshWeather();
    refreshLyrics();
    await refreshPrinter();
    send();
  };

  if (WEATHER_CITY) console.log(`[bridge] 天气已开启: ${WEATHER_CITY}（15 分钟刷新，wttr.in）`);
  if (LYRICS_CMD) console.log(`[bridge] 歌词命令已开启: ${LYRICS_CMD}`);
  loop();
  setInterval(loop, INTERVAL);

  process.on('SIGINT', () => {
    console.log('\n[bridge] 退出');
    sock.close();
    process.exit(0);
  });
}

main();

/** 组装给鸿蒙应用的遥测 JSON */
/**
 * bambu-monitor 的 /api/state 与 ours 不是一套字段名，这里做一层映射。
 * 只取面板用得上的字段，全部扁平化——屏幕那一侧不需要知道上游结构。
 */
/**
 * 拓竹托盘颜色是 "RRGGBBAA"（例如 B9D9EBFF，无 #、8 位）。canvas 需要 "#RRGGBB"，
 * 直接透传会画出黑色/无效色 —— 真机上验过。
 */
function toCssColor(raw) {
  const v = String(raw || '').trim();
  if (v.length >= 6 && /^[0-9a-fA-F]{6,8}$/.test(v)) {
    return '#' + v.slice(0, 6).toUpperCase();
  }
  return '';
}

/**
 * 拓竹的 trayNow 在"无当前料"时会给 254/255 这类哨兵值，直接透传会让面板去高亮一个不存在的托盘。
 */
function saneTrayIndex(v) {
  const n = typeof v === 'number' ? v : Number(v);
  if (!isFinite(n) || n < 0 || n >= 250) return -1;
  return n;
}

function mapBambuState(api) {
  const st = (api && api.state) || {};
  const pr = st.progress || {};
  const te = st.temps || {};
  const am = st.ams || {};
  const er = st.errors || {};
  const dev = (api && api.monitor && api.monitor.device) || {};

  const num = (v, def) => (typeof v === 'number' && isFinite(v) ? v : def);

  // 托盘拉平：多台 AMS 的槽位按 1..N 连续编号（面板只画前几个）
  const trays = [];
  const units = Array.isArray(am.units) ? am.units : [];
  for (const u of units) {
    const list = Array.isArray(u.trays) ? u.trays : [];
    for (const t of list) {
      const type = String(t.type || '');
      if (!type || type === 'Empty') continue;
      trays.push({
        index: trays.length + 1,
        type,
        color: toCssColor(t.color) || undefined,
        remain: num(t.remain, -1),
      });
    }
  }
  // 外挂料盘（vt_tray）
  if (am.vtTray && am.vtTray.type && am.vtTray.type !== 'Empty') {
    trays.push({
      index: trays.length + 1,
      type: String(am.vtTray.type),
      color: toCssColor(am.vtTray.color) || undefined,
      remain: num(am.vtTray.remain, -1),
    });
  }

  const modelBits = [];
  if (dev.name || dev.model) modelBits.push(String(dev.name || dev.model));
  if (st.model && st.model.nozzleDiameter) {
    modelBits.push(`${st.model.nozzleDiameter}mm`);
  }
  if (st.model && st.model.nozzleType) {
    modelBits.push(String(st.model.nozzleType));
  }

  // 监控服务自己的状态：401（token 过期）这类问题要如实上屏，不能只报"未知"
  const mon = (api && api.monitor) || {};
  const monErr = typeof mon.lastError === 'string' ? mon.lastError : '';

  return {
    state: st.state || 'UNKNOWN',
    stateLabel: st.stateLabel || '',
    /** 监控服务是否连上云端（error = 凭据问题，提示用户重新登录） */
    monitorMode: typeof mon.mode === 'string' ? mon.mode : '',
    monitorError: monErr,
    connected: st.connected === true,
    online: st.online === null || st.online === undefined ? undefined : st.online === true,
    model: modelBits.join(' '),
    jobName: (st.job && st.job.name) ? String(st.job.name) : '',
    percent: num(pr.percent, -1),
    layer: num(pr.layer, -1),
    totalLayer: num(pr.totalLayer, -1),
    remainingSec: num(pr.remainingSec, -1),
    elapsedSec: num(pr.elapsedSec, -1),
    eta: pr.eta ? String(pr.eta) : '',
    nozzleTemp: num(te.nozzle, -1),
    nozzleTarget: num(te.nozzleTarget, -1),
    bedTemp: num(te.bed, -1),
    bedTarget: num(te.bedTarget, -1),
    chamberTemp: num(te.chamber, -1),
    wifi: st.wifi ? String(st.wifi) : '',
    coolingFan: st.fans ? num(Number(st.fans.cooling), -1) : -1,
    heatbreakFan: st.fans ? num(Number(st.fans.heatbreak), -1) : -1,
    speedLevel: num(st.speed, -1),
    printError: num(er.printError, 0),
    hms: Array.isArray(er.hms) ? er.hms.map((h) => ({ code: String(h && h.code || '') })) : [],
    trayNow: saneTrayIndex(am.trayNow),
    trays,
  };
}

/**
 * 离线造数。存在的意义：打印机云 token 过期 / 机器不在身边时，
 * 也能把面板的四种状态（打印中、空闲、告警、离线）在真机上看一遍。
 */
function fakePrinter(mode, t) {
  const m = mode || 'run';
  const pct = Math.floor((t / 1000) % 100);
  const base = {
    state: 'RUNNING', stateLabel: '打印中', connected: true, online: true,
    model: 'P2S 0.4mm 不锈钢', jobName: 'BambuHelper_panel_test.gcode.3mf',
    percent: pct, layer: 12 + pct * 3, totalLayer: 300,
    remainingSec: Math.max(0, (100 - pct) * 42), elapsedSec: pct * 40,
    eta: new Date(Date.now() + Math.max(0, (100 - pct) * 42000)).toTimeString().slice(0, 5),
    nozzleTemp: 218 + Math.round(Math.sin(t / 900) * 3), nozzleTarget: 220,
    bedTemp: 59 + Math.round(Math.sin(t / 1300) * 1), bedTarget: 60,
    chamberTemp: 34, wifi: '-52', coolingFan: 80, heatbreakFan: 60, speedLevel: 2,
    printError: 0, hms: [], trayNow: 1,
    trays: [
      { index: 1, type: 'PLA', color: 'FF3B30FF', remain: 78 },
      { index: 2, type: 'PETG', color: '34C759FF', remain: 46 },
      { index: 3, type: 'ABS', color: '0A84FFFF', remain: 91 },
      { index: 4, type: 'TPU', color: 'FFCC00FF', remain: 12 },
      { index: 5, type: 'PLA-CF', color: '8E8E93FF', remain: 63 },
    ],
  };
  if (m === 'idle') {
    return { ...base, state: 'IDLE', stateLabel: '空闲', percent: -1, layer: -1, totalLayer: -1,
      remainingSec: -1, elapsedSec: -1, eta: '', jobName: '',
      nozzleTemp: 32, nozzleTarget: 0, bedTemp: 28, bedTarget: 0, chamberTemp: 26,
      coolingFan: 0, speedLevel: 2 };
  }
  if (m === 'error') {
    return { ...base, state: 'FAILED', stateLabel: '失败', printError: 83951617,
      hms: [{ code: '0300_0100_0001_0001' }, { code: '0700_2000_0002_0003' }] };
  }
  if (m === 'offline') {
    return { ...base, state: 'OFFLINE', stateLabel: '离线', connected: false, online: false,
      wifi: '', percent: -1, remainingSec: -1, eta: '' };
  }
  return base;
}

/** 定期刷新打印机状态；失败累计到阈值就报离线（不清空旧数据，便于排查） */
async function refreshPrinter() {
  if (!PRINTER_URL && !PRINTER_FAKE) return;
  if (Date.now() - printerLastAt < PRINTER_INTERVAL) return;
  printerLastAt = Date.now();

  if (PRINTER_FAKE) {
    printerState = fakePrinter(PRINTER_FAKE === '1' ? 'run' : PRINTER_FAKE, Date.now());
    return;
  }
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 4000);
    const res = await fetch(PRINTER_URL, { signal: ctrl.signal });
    clearTimeout(timer);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const api = await res.json();
    printerState = mapBambuState(api);
    printerFails = 0;
  } catch (e) {
    printerFails++;
    if (printerFails >= PRINTER_MAX_FAILS) {
      printerState = {
        state: 'OFFLINE', stateLabel: '离线', connected: false, online: false,
        jobName: '', percent: -1, layer: -1, totalLayer: -1, remainingSec: -1,
        nozzleTemp: -1, bedTemp: -1, chamberTemp: -1, printError: 0, hms: [], trays: [],
      };
      if (printerFails === PRINTER_MAX_FAILS) {
        console.error(`\n[bridge] 打印机数据源不可用（${e.message}）→ 面板显示离线`);
      }
    }
  }
}

function buildPayload() {
  const cost = (PRICING.outputPerM > 0 || PRICING.inputPerM > 0)
    ? (todayUsage.inputTokens / 1e6) * PRICING.inputPerM +
      (todayUsage.outputTokens / 1e6) * PRICING.outputPerM
    : undefined;

  const out = {
    ts: Date.now(),
    agent: {
      state: live.state,
      activity: live.activity,
      tool: live.tool,
      lastText: live.lastText.slice(-400),
      turn: live.turn,
      step: live.step,
      project: live.project,
      sessionId: live.sessionId,
      model: live.model,
      provider: live.provider,
    },
    todos: live.todos,
    tokens: {
      todayInput: todayUsage.inputTokens,
      todayOutput: todayUsage.outputTokens,
      todayTotal: todayUsage.total,
      contextUsed: live.contextUsed,
      contextWindow: live.contextWindow || 1000000,
      costUsd: cost,
    },
    system: systemPayload(),
    events: events,
    // 未开启余额功能时是 undefined，JSON 序列化会丢掉这个键（面板不画那一行）
    balance: (balanceState === undefined && balanceErr === '')
      ? undefined
      : Object.assign({ error: balanceErr }, burnStats(),
          balanceState === undefined ? {} : balanceState),
    // 一句话摘要（开了 --summary 才有）
    summary: (summaryState === undefined && summaryErr === '')
      ? undefined
      : Object.assign({ error: summaryErr }, summaryState === undefined ? {} : summaryState),
    // 依赖健康（应用侧自己知道 USB；这里给出桥能看到的三个）
    health: {
      bridge: true,
      printer: printerState !== undefined,
      printerState: printerState === undefined ? '' : String(printerState.state || ''),
      weather: weather.text !== undefined && weather.text.length > 0,
      summary: SUMMARY_SEC !== null,
      tokensPerMin: tokenRate.perMin
    },
    weather: weather.text ? weather : undefined,
    lyrics: lyricsLine ? { line: lyricsLine } : undefined,
    // 注意：没开 --printer 时这里是 undefined，JSON 序列化会直接丢掉这个键，
    // 鸿蒙端 normalizePrinter(undefined) 返回 undefined → 打印机卡片不出现
    printer: printerState,
  };
  // token 速率（每分钟）：按两次构建之间的增量算，做一点平滑（EMA 0.3）
  const nowMs2 = Date.now();
  if (tokenRate.lastTotal >= 0 && nowMs2 > tokenRate.at) {
    const dtMin = (nowMs2 - tokenRate.at) / 60000;
    if (dtMin >= 0.05) {
      const inst = Math.max(0, (todayUsage.total - tokenRate.lastTotal) / dtMin);
      tokenRate.perMin = tokenRate.at === 0 ? inst : (tokenRate.perMin * 0.7 + inst * 0.3);
    }
  }
  tokenRate.lastTotal = todayUsage.total;
  tokenRate.at = nowMs2;

  // 事件在这里记：buildPayload 两条路径（常驻推送 / --once 调试）都会走到，且每次只记一次
  noteEvents(out);
  return out;
}
