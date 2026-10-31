/**
 * dsh-lcd-bridge —— **进程内**数据桥（随 DSH 启动，替代原来的外部 `dsh-bridge.mjs`）
 *
 * ## 为什么改成进程内
 * 原来屏幕的遥测靠一个**外部 node 脚本**：要手动 `./start.sh`、要 `zstd.exe`、
 * 要在 DSH 之外再起一个进程。用户要求"数据桥的功能实现并到软件本身，
 * 而不是需要接触外部提供"。
 *
 * 关键前提（已实测）：**DSH 的 node 原生带 zstd**
 *   `zlib.zstdDecompressSync` 一次就能解开多帧 `session.v4.jsonl.zstd`
 *   （实测 13.7MB → 45MB / 313ms）。
 * 所以插件能直接读**解压后的实时会话**，不需要 spawn 任何进程、不需要外部二进制。
 *
 * ## 数据流
 *   DSH 会话文件（zstd） ──进程内解压──▶ 提炼状态 ──UDP 127.0.0.1:54545──▶ 屏幕 App
 * App 侧的 `TelemetryBridge.ets` 照旧收包，**App 一行都不用改**。
 *
 * ## 与外部桥的关系
 * 两者载荷同构，可共存（谁先发谁后到无所谓，App 只认最新）。
 * 建议只留一个：插件跑起来了就不用再 `./start.sh`。
 */
import dgram from 'node:dgram'
import os from 'node:os'
import path from 'node:path'
import { findCurrentSession, readTailLines, readAllLines, deriveState, dshHome } from './session.mjs'
import fs, { writeFileSync } from 'node:fs'
import http from 'node:http'
import { PrinterWatcher } from './printer.mjs'
import { BalanceWatcher, readApiKey } from './balance.mjs'

export const name = 'dsh-lcd-bridge'

/** UDP 目标：App 的 TelemetryBridge 绑的就是这个 */
/**
 * 安全读取数值型环境变量。
 *
 * ★ 为什么必须校验（2026-10-16 审计，已实测）：
 *   `Number('abc')` 是 NaN，而 Node 的 `setInterval(fn, NaN)` 会把间隔当成 **1ms**
 *   （实测告警：`TimeoutNaNWarning: NaN is not a number. Timeout duration was set to 1.`）。
 *   本插件与 DSH **同进程**，一个写错的环境变量就能让宿主事件循环被 1ms 定时器打死。
 */
function envNum(raw, def, min, max, why) {
  if (raw === undefined || raw === null || String(raw).length === 0) {
    return def
  }
  const v = Number(raw)
  if (!Number.isFinite(v) || v < min || v > max) {
    try {
      process.stderr.write(`[dsh-lcd-bridge] 环境变量 ${why}=${raw} 非法（需 ${min}..${max}），已回落 ${def}\n`)
    } catch { /* 忽略 */ }
    return def
  }
  return v
}

const PORT = envNum(process.env.DSH_LCD_PORT, 54545, 1, 65535, 'DSH_LCD_PORT')
const HOST = process.env.DSH_LCD_HOST || '127.0.0.1'

/** 推送节奏（对齐 App 侧 10s 的新鲜度判定，留足余量） */
const INTERVAL_MS = envNum(process.env.DSH_LCD_INTERVAL, 1000, 100, 600000, 'DSH_LCD_INTERVAL')

/** CPU 采样窗 */
const CPU_SAMPLE_MS = 1000

export const inject = []

/** 打印机状态（进程内轮询本机 bambu-monitor；原来由外部桥做） */
const printer = new PrinterWatcher(envNum(process.env.DSH_LCD_PRINTER_MS, 5000, 1000, 3600000, 'DSH_LCD_PRINTER_MS'))
/** DeepSeek 余额（进程内拉取；原来由外部桥做，实测那条链路是坏的） */
const balance = new BalanceWatcher(fs, path, os, envNum(process.env.DSH_LCD_BALANCE_MS, 600000, 60000, 86400000, 'DSH_LCD_BALANCE_MS'))

/** 最近一次读到的 sk- key（随载荷发给 App，供其自行取余额） */
let currentApiKey = ''

// ───────────────────────── 本机系统数据 ─────────────────────────

let lastCpu = null

function cpuPercent() {
  const cpus = os.cpus()
  let idle = 0
  let total = 0
  for (const c of cpus) {
    for (const k of Object.keys(c.times)) total += c.times[k]
    idle += c.times.idle
  }
  const snap = { idle, total }
  if (lastCpu === null) {
    lastCpu = snap
    return 0
  }
  const dIdle = idle - lastCpu.idle
  const dTotal = total - lastCpu.total
  lastCpu = snap
  if (dTotal <= 0) return 0
  const pct = (1 - dIdle / dTotal) * 100
  return Math.max(0, Math.min(100, pct))
}

function systemPayload() {
  const load = os.loadavg()
  const totalMB = Math.round(os.totalmem() / 1048576)
  const freeMB = Math.round(os.freemem() / 1048576)
  return {
    cpu: Number(cpuPercent().toFixed(1)),
    cores: os.cpus().length,
    memUsed: totalMB - freeMB,
    memTotal: totalMB,
    load1: Number(load[0].toFixed(2)),
    load5: Number(load[1].toFixed(2)),
    load15: Number(load[2].toFixed(2)),
    uptimeSec: Math.round(os.uptime()),
    host: os.hostname()
  }
}

// ───────────────────────── 会话轮询（三层节奏） ─────────────────────────
//
// ★ 分层与实测依据（2026-10-15 在 13.6MB 会话上量的）：
//   快路径（1MB 尾部）        ≈ 72ms/s  → state/activity/tool/turn/step  （每秒）
//   全量流式解码              ≈ 1300ms  → 含 model/provider/title/当日用量（每 60s）
//   ★ 关键约束：插件与 DSH **同一个进程**，插件阻塞事件循环 = DSH 卡顿。
//     早期用 8MB 尾部时每秒 380ms（38% 占用）、事件循环最大阻塞 612ms，
//     会把 DSH 拖出可见卡顿；现在快路径 1MB（≈7%）+ 全量摊薄（≈2%）。

/**
 * ★ 为什么是两层（实测依据）：
 *   · **尾部快读**（8MB 尾部 + 最早帧起点）：几十~几百 ms，能拿到"当前活动"
 *     —— state / activity / tool / turn / step / contextUsed / todos。
 *     但拿不到**文件开头**的元数据（model / provider / contextWindow / title）
 *     和完整的当日用量（当日用量要覆盖当天全部行）。
 *   · **全量流式解码**：1.5 秒级（13.7MB→45MB / 18350 行），能拿到一切。
 *     太慢，不能每秒跑。
 *   所以：快字段每秒刷，重字段每 FULL_EVERY_MS 刷一次，然后**合并**。
 */
const FULL_EVERY_MS = envNum(process.env.DSH_LCD_FULL_MS, 60000, 5000, 3600000, 'DSH_LCD_FULL_MS')

/** 重字段（只在全量刷新时更新） */
const HEAVY_KEYS = [
  'model',
  'provider',
  'contextWindow',
  'title',
  'todayUsage',
  'usage',
  'sessionId',
  'project'
]

let heavy = null // 上一次全量刷出来的重字段

function mergeState(light, nowMs) {
  if (!heavy) return light
  const out = { ...light }
  for (const k of HEAVY_KEYS) {
    const v = heavy[k]
    if (v === undefined || v === null) continue
    // 字符串/对象：重字段为空时才用（轻字段里 model 等本来就是空的）
    if (typeof v === 'string') {
      if (!out[k]) out[k] = v
    } else if (typeof v === 'number') {
      if (!out[k]) out[k] = v
    } else {
      out[k] = v // 用量是累计值，直接用全量的（尾部窗口算不全）
    }
  }
  return out
}

let cache = { file: '', mtimeMs: 0, size: 0, state: null }
/** 换会话文件时允许的**最小**全量解码间隔（防多会话抖动导致每秒全量解码） */
const FULL_ON_CHANGE_MIN_MS = 10000
let lastFullMs = 0
let lastFullFile = ''

async function pollSession(nowMs) {
  const sessionsRoot = path.join(dshHome(), 'sessions')
  const cur = findCurrentSession(sessionsRoot)
  if (!cur) return cache.state

  // ── 重字段：全量流式解码（低频，或换了文件时立即做一次）──
  // ★ 换文件时**不能**无条件全量解码（审计实测）：原条件含 `|| lastFullFile !== cur.file`，
  //   而 findCurrentSession 取"mtime 最新"的会话 —— 多会话并存时来回跳（实测 6 秒切 2 次），
  //   于是每秒触发一次全量解码：async 1415ms、**同步阻塞合计 966ms**
  //   （concat 50 + toString 125 + split 179 + JSON.parse 612）。与 DSH 同进程 → 宿主每秒被卡近 1 秒。
  //   改为：换文件时也给**最小间隔**，最多 10 秒解码一次。
  const fileChanged = lastFullFile !== cur.file
  const dueByTime = nowMs - lastFullMs >= FULL_EVERY_MS
  const dueByChange = fileChanged && (nowMs - lastFullMs >= FULL_ON_CHANGE_MIN_MS)
  if (dueByTime || dueByChange) {
    lastFullMs = nowMs
    lastFullFile = cur.file
    try {
      const all = await readAllLines(cur.file)
      if (all.lines && all.lines.length) {
        const h = deriveState(all.lines, nowMs)
        h.sessionId = cur.sid
        h.project = projectFromSlug(cur.slug)
        heavy = h
      }
    } catch {
      /* 保留上一次的重字段 */
    }
  }

  // ── 活字段：尾部快读（每次都做，但文件没变就跳过解压）──
  const unchanged = cache.file === cur.file && cache.mtimeMs === cur.mtimeMs && cache.size === cur.size
  if (unchanged && cache.state) return mergeState(cache.state, nowMs)

  const lines = readTailLines(cur.file, cur.size)
  if (lines.length === 0) return cache.state ? mergeState(cache.state, nowMs) : heavy

  const st = deriveState(lines, nowMs)
  st.sessionId = cur.sid
  // 项目名：会话目录 slug 形如 `--storage-Users-currentUser-WorkBuddy--`
  st.project = projectFromSlug(cur.slug)
  cache = { file: cur.file, mtimeMs: cur.mtimeMs, size: cur.size, state: st }
  return mergeState(st, nowMs)
}

function projectFromSlug(slug) {
  const m = /^--(.*)--$/.exec(slug || '')
  const p = m ? m[1] : slug || ''
  const parts = p.split('-').filter(Boolean)
  return parts.length ? parts[parts.length - 1] : ''
}

// ───────────────────────── 载荷 ─────────────────────────

function buildPayload(st, nowMs, printerState, balanceState, balanceErr) {
  const empty = {
    state: 'unknown',
    activity: '',
    tool: '',
    lastText: '',
    turn: 0,
    step: 0,
    project: '',
    sessionId: '',
    model: '',
    provider: ''
  }
  const agent = st
    ? {
        state: st.state,
        activity: st.activity,
        tool: st.tool,
        lastText: st.lastText,
        turn: st.turn,
        step: st.step,
        project: st.project,
        sessionId: st.sessionId,
        model: st.model,
        provider: st.provider,
        // 错误文本（BSOD 彩蛋用）：turn/end 的 reason.kind 非 completed 时才有值
        errorText: st.errorText
      }
    : empty

  return {
    ts: nowMs,
    agent,
    todos: st ? st.todos : [],
    tokens: st
      ? {
          todayInput: st.todayUsage.inputTokens,
          todayOutput: st.todayUsage.outputTokens,
          todayTotal: st.todayUsage.total,
          sessionTotal: st.usage.inputTokens + st.usage.outputTokens,
          contextUsed: st.contextUsed,
          contextWindow: st.contextWindow || 1000000
        }
      : { contextWindow: 1000000 },
    system: systemPayload(),
    // ★ balance / printer 由插件自己提供（原来是外部桥的活；实测外部桥其实没在推）
    //   只在拿到有效数据时才放进去 —— 放了 undefined 会让 App 侧把好值覆盖掉
    //   （App 已改成按字段合并，但这里也不该主动塞空值）。
    printer: printerState,
    balance: balanceState,
    balanceErr: balanceErr,
    // ★ 把 sk- key 一并交给 App。
    //   目的：余额要能在 **DSH 不跑时**继续刷新 —— App 自己拿 key 直连
    //   `https://api.deepseek.com/user/balance`，不依赖这个快照服务。
    //   App 无法读 `~/.dsh/.credentials.yaml`（实测 13900001 访问被拒），
    //   所以只能这样递一次；App 会把它存进自己的 preferences，之后长期有效。
    deepseekKey: currentApiKey,
    health: {
      bridge: true,
      printer: printerState !== undefined,
      weather: false,
      summary: false
    },
    source: 'dsh-plugin'
  }
}

// ───────────────────────── 快照 HTTP 服务 ─────────────────────────

/**
 * 为什么快照要用 HTTP 而不是写文件让 App 读（★ 实测结论）：
 *   App（uid 20020330）读 `/storage/Users/currentUser/.dsh/storages/lcd-bridge/last.json`
 *   被系统拒绝，错误码 **13900001**（访问被拒），即使把文件权限放到 666 也不行
 *   —— 鸿蒙对 `~/.dsh` 这类用户私有目录有沙箱访问控制，跨应用读被拦。
 *
 *   而 **HTTP 路是通的**（App 现在就在成功取 `http://127.0.0.1:8787/vm/frame.jpg`，
 *   实测 vmFrames=19、vmErr 为空）。所以改成：插件起一个小 HTTP 服务提供快照 JSON，
 *   App 用同一套 http.createHttp() 取。
 *
 * 端点：
 *   GET /snapshot.json   → 完整遥测快照（与 UDP 载荷同构）
 *   GET /health          → 极简存活探测
 */
const SNAP_PORT = envNum(process.env.DSH_LCD_SNAP_PORT, 54548, 1, 65535, 'DSH_LCD_SNAP_PORT')

function startSnapshotServer(getPayload) {
  const srv = http.createServer((req, res) => {
    const url = (req.url || '').split('?')[0]
    if (url === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('ok')
      return
    }
    if (url === '/snapshot.json' || url === '/snapshot' || url === '/') {
      let body
      try {
        body = JSON.stringify(getPayload())
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' })
        res.end('snapshot error')
        return
      }
      res.writeHead(200, {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
        'Content-Length': Buffer.byteLength(body)
      })
      res.end(body)
      return
    }
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('not found')
  })
  srv.on('error', () => { /* 端口被占等，静默：UDP 路仍可用 */ })
  try {
    srv.listen(SNAP_PORT, '127.0.0.1')
  } catch {
    /* 起不来也不致命 */
  }
  return srv
}

// ───────────────────────── 插件主体 ─────────────────────────

export function apply(ctx) {
  const sock = dgram.createSocket('udp4')
  // ★ 必须监听 'error'：EventEmitter 无 error 监听时会把 error 抛成**未捕获异常**。
  //   本插件与 DSH 同进程 → 一次 UDP 错误就能直接炸掉宿主（审计 P3）。
  sock.on('error', (e) => {
    try {
      ctx.logger?.warn?.(`[dsh-lcd-bridge] UDP 错误（已忽略，不影响宿主）: ${e && e.message ? e.message : e}`)
    } catch { /* 连日志都不能让它抛 */ }
  })
  let timer = null
  let sent = 0
  /** 最近一次载荷：HTTP 快照服务直接提供它（避免每次请求都重算） */
  let lastPayload = { ts: Date.now(), agent: { state: 'unknown' }, tokens: {}, source: 'dsh-plugin' }
  let snapSrv = null

  /**
   * tick 并发保护（审计 P2）：单轮里可能含 pollSession(1.9s) / printer(4s+) / balance(10s+)，
   * 而 setInterval 每 INTERVAL_MS(1s) 就再调一次 → 轮次叠加，每轮各持一份解码缓冲。
   * busy 标志保证同一时刻只有一轮在跑；stopped 让 dispose 后的在途轮次尽快退出。
   */
  let tickBusy = false
  let stopped = false
  const tick = async () => {
    if (stopped || tickBusy) {
      return lastPayload
    }
    tickBusy = true
    try {
    try {
      const nowMs = Date.now()
      const st = await pollSession(nowMs)
      // 打印机 / 余额：各自内部有节流，到点才真正拉
      let printerState = undefined
      let balanceState = undefined
      let balanceErr = ''
      try {
        printerState = await printer.poll(nowMs)
      } catch {
        /* 打印机失败不影响其他数据 */
      }
      try {
        const b = await balance.poll(nowMs)
        balanceState = b.state
        balanceErr = b.err
        if (balance.keyNote) currentApiKey = readApiKey(fs, path, os).key
      } catch (e) {
        balanceErr = 'poll 异常: ' + (e && e.message ? e.message : String(e))
      }
      // ★ 排障落盘：把余额/打印机的实际取值写到 $DSH_HOME/storages/lcd-bridge/last.json。
      //   为什么需要：App 的 /diag 只能说"balance 是 undefined"，
      //   无法区分「插件没拉到」和「拉了但没进载荷」。写一份就能一眼定位。
      try {
        // ★ 目录必须先建：`writeFileSync` 不会自动建目录，目录不存在时直接抛，
        //   而我原来把异常吞了 → 表现为"落盘文件根本没出现"，排障时看不出原因。
        const dbgDir = path.join(dshHome(), 'storages', 'lcd-bridge')
        try {
          fs.mkdirSync(dbgDir, { recursive: true })
        } catch {
          /* 已存在或建不了，下面的写会失败并被记录下来 */
        }
        writeFileSync(
          path.join(dbgDir, 'last.json'),
          JSON.stringify({
            at: new Date(nowMs).toISOString(),
            keyFrom: balance.keyNote,
            balanceErr,
            balance: balanceState === undefined ? null : balanceState,
            // printer.poll() 可能返回 null（不只是 undefined）——只挡 undefined 会抛
            printerState: printerState == null ? null : printerState.state,
            printerTrays: printerState == null ? 0 : (printerState.trays || []).length
          }, null, 2)
        )
      } catch (e) {
        // 不再完全静默：把失败原因也写进去（若连这里都写不了，至少日志里有一条）
        ctx.logger?.warn?.(`[dsh-lcd-bridge] 排障落盘失败: ${e && e.message ? e.message : e}`)
      }
      const payload = buildPayload(st, nowMs, printerState, balanceState, balanceErr)
      lastPayload = payload
      // ★ sk- key **不进 UDP 载荷**（安全，审计 P4）：UDP 每秒一包、发往 127.0.0.1，
      //   同机任何进程都能抓；而 key 只需递一次。App 走 HTTP 快照接住并落盘。
      const udpPayload = Object.assign({}, payload)
      delete udpPayload.deepseekKey
      const buf = Buffer.from(JSON.stringify(udpPayload), 'utf8')
      sock.send(buf, PORT, HOST, (err) => {
        if (!err) sent++
      })
    } catch (e) {
      ctx.logger?.warn?.(`[dsh-lcd-bridge] 一轮失败: ${e && e.message ? e.message : e}`)
    }
    } finally {
      tickBusy = false
    }
  }

  // 先采样一次 CPU 基线
  cpuPercent()

  // ★ 预热：先把"重字段"（model/provider/title/当日用量）全量解出来，
  //   否则前几包里这些字段是空的（实测抓包前 3 包 model 为空就是这么来的）。
  //   全量解码 13MB 约 2.4 秒，所以**先 await 一次**再开始推。
  // ★ 两件事必须做对（都与"插件与 DSH 同进程"有关）：
  //   ① 任何未捕获的拒绝都会影响宿主 → 整段包 try/catch + 显式 .catch()
  //   ② **不要在 apply() 里同步跑重活**：预热是 2.4 秒的全量 zstd 解码，
  //      直接跑会拖住 DSH 的激活流程（实测怀疑因此让插件看起来"没启动"）。
  //      改成 setTimeout 延后启动，让激活先干净完成，再开始干活。
  const START_DELAY_MS = envNum(process.env.DSH_LCD_START_DELAY_MS, 1500, 0, 60000, 'DSH_LCD_START_DELAY_MS')
  const boot = async () => {
    try {
      await pollSession(Date.now())
    } catch {
      /* 预热失败不影响后续 */
    }
    try {
      if (timer !== null) return;      // 防重复启动
      timer = setInterval(tick, INTERVAL_MS)
      void tick()
      // 快照 HTTP 服务：App 用 http 取（文件路被沙箱拦，见函数注释）
      if (snapSrv === null) {
        snapSrv = startSnapshotServer(() => lastPayload)
      }
      ctx.logger?.info?.(
        `[dsh-lcd-bridge] 已启动：UDP ${HOST}:${PORT} 每 ${INTERVAL_MS}ms`
        + ` ｜ HTTP 快照 http://127.0.0.1:${SNAP_PORT}/snapshot.json（进程内，无外部依赖）`)
    } catch (e) {
      ctx.logger?.warn?.(`[dsh-lcd-bridge] 启动失败: ${e && e.message ? e.message : e}`)
    }
  }
  try {
    setTimeout(() => { void boot().catch(() => {}) }, START_DELAY_MS)
  } catch {
    /* setTimeout 都失败就不能做什么了 */
  }

  // DSH 关闭时清理
  ctx.on?.('dispose', () => {
    // 先置停止标志：让在途 tick 尽快返回，避免 dispose 之后还往已关闭的 socket 写
    stopped = true
    tickBusy = false
    if (timer !== null) clearInterval(timer)
    if (snapSrv !== null) {
      try { snapSrv.close() } catch { /* ignore */ }
      snapSrv = null
    }
    try {
      sock.close()
    } catch {
      /* ignore */
    }
    ctx.logger?.info?.(`[dsh-lcd-bridge] 已停止（共推 ${sent} 次）`)
  })
}
