#!/usr/bin/env node
/**
 * bridge-standalone.mjs —— **不依赖 DSH 进程**的数据桥（独立运行）
 *
 * ## 为什么要有这个（与 DSH 插件的关系）
 * | | DSH 插件（index.mjs） | 本文件（独立） |
 * |---|---|---|
 * | 谁在跑 | DSH 进程内的子模块 | 自己一个 node 进程 |
 * | DSH 停了会怎样 | ❌ 桥也停 → 屏没数据 | ✅ 照常推 |
 * | 谁负责启动/退出 | DSH 自动（生命周期跟着 DSH） | 你得自己拉起（或用 run-app.sh） |
 * | 需要装什么 | 无 | 无（用本机 node 的原生 zstd） |
 *
 * ## 关键实测依据（决定了"能不能脱离 DSH"）
 *   1. 本机 node（`~/.harmonybrew/opt/node/bin/node`）**自带 zstd**：
 *      `require('node:zlib').zstdDecompressSync` 可用 —— 所以不需要外部 zstd 二进制
 *   2. 会话文件的解码**不依赖 DSH 进程**：只用 `zstd` CLI 解同一文件，
 *      md5 与 node 原生解出的**完全一致**（`8c0d6860…`，50,030,364 字节）
 *   3. `session.mjs` / `balance.mjs` / `printer.mjs` 都是**纯 Node ESM**，
 *      不 import cordis、不用 DSH 的 `ctx` —— 可以直接复用
 *
 * 所以本文件只做一件事：把插件里那套已经被验证过的逻辑，
 * 用一个"不依赖 DSH 的宿主"驱动起来。
 *
 * ## 用法
 *   node bridge-standalone.mjs                  # 前台跑（Ctrl-C 退出）
 *   node bridge-standalone.mjs --once           # 只推一包，便于排查
 *   nohup node bridge-standalone.mjs &          # 后台跑
 *
 *   环境变量：
 *     DSH_LCD_PORT    目标 UDP 端口（默认 54545）
 *     DSH_LCD_HOST    目标地址（默认 127.0.0.1）
 *     DSH_LCD_INTERVAL 推送间隔 ms（默认 1000）
 *     DSH_LCD_FULL_MS 全量刷新间隔 ms（默认 60000）
 */
import dgram from 'node:dgram'
import os from 'node:os'
import path from 'node:path'
import fs from 'node:fs'
import { findCurrentSession, readTailLines, readAllLines, deriveState, dshHome } from './session.mjs'
import { PrinterWatcher } from './printer.mjs'
import { BalanceWatcher } from './balance.mjs'

const PORT = Number(process.env.DSH_LCD_PORT || 54545)
const HOST = process.env.DSH_LCD_HOST || '127.0.0.1'
const INTERVAL_MS = Number(process.env.DSH_LCD_INTERVAL || 1000)
const FULL_EVERY_MS = Number(process.env.DSH_LCD_FULL_MS || 60000)
const ONCE = process.argv.includes('--once')

// ── 本机系统数据（与插件里同一套算法）──
let lastCpu = null
function cpuPercent() {
  const cpus = os.cpus()
  let idle = 0, total = 0
  for (const c of cpus) {
    for (const k of Object.keys(c.times)) total += c.times[k]
    idle += c.times.idle
  }
  const snap = { idle, total }
  if (lastCpu === null) { lastCpu = snap; return 0 }
  const dIdle = idle - lastCpu.idle, dTotal = total - lastCpu.total
  lastCpu = snap
  if (dTotal <= 0) return 0
  return Math.max(0, Math.min(100, (1 - dIdle / dTotal) * 100))
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

// ── 会话：三层节奏（与插件一致，实测依据见 session.mjs 注释）──
const HEAVY_KEYS = ['model', 'provider', 'contextWindow', 'title', 'todayUsage', 'usage', 'sessionId', 'project']
let heavy = null
let cache = { file: '', mtimeMs: 0, size: 0, state: null }
let lastFullMs = 0
let lastFullFile = ''

function projectFromSlug(slug) {
  const m = /^--(.*)--$/.exec(slug || '')
  const p = m ? m[1] : slug || ''
  const parts = p.split('-').filter(Boolean)
  return parts.length ? parts[parts.length - 1] : ''
}
function mergeState(light) {
  if (!heavy) return light
  const out = { ...light }
  for (const k of HEAVY_KEYS) {
    const v = heavy[k]
    if (v === undefined || v === null) continue
    if (typeof v === 'string' || typeof v === 'number') {
      if (!out[k]) out[k] = v
    } else {
      out[k] = v
    }
  }
  return out
}
async function pollSession(nowMs) {
  const cur = findCurrentSession(path.join(dshHome(), 'sessions'))
  if (!cur) return cache.state
  if (nowMs - lastFullMs >= FULL_EVERY_MS || lastFullFile !== cur.file) {
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
    } catch { /* 保留上一次 */ }
  }
  const unchanged = cache.file === cur.file && cache.mtimeMs === cur.mtimeMs && cache.size === cur.size
  if (unchanged && cache.state) return mergeState(cache.state)
  const lines = readTailLines(cur.file, cur.size)
  if (lines.length === 0) return cache.state ? mergeState(cache.state) : heavy
  const st = deriveState(lines, nowMs)
  st.sessionId = cur.sid
  st.project = projectFromSlug(cur.slug)
  cache = { file: cur.file, mtimeMs: cur.mtimeMs, size: cur.size, state: st }
  return mergeState(st)
}

// ── 主体 ──
const printer = new PrinterWatcher(Number(process.env.DSH_LCD_PRINTER_MS || 5000))
const balance = new BalanceWatcher(fs, path, os, Number(process.env.DSH_LCD_BALANCE_MS || 600000))
const sock = dgram.createSocket('udp4')
let sent = 0

async function tick() {
  const nowMs = Date.now()
  const st = await pollSession(nowMs)
  let printerState, balanceState = undefined, balanceErr = ''
  try { printerState = await printer.poll(nowMs) } catch { }
  try { const b = await balance.poll(nowMs); balanceState = b.state; balanceErr = b.err } catch (e) {
    balanceErr = 'poll 异常: ' + (e && e.message ? e.message : String(e))
  }

  const empty = { state: 'unknown', activity: '', tool: '', lastText: '', turn: 0, step: 0, project: '', sessionId: '', model: '', provider: '' }
  const payload = {
    ts: nowMs,
    agent: st ? {
      state: st.state, activity: st.activity, tool: st.tool, lastText: st.lastText,
      turn: st.turn, step: st.step, project: st.project, sessionId: st.sessionId,
      model: st.model, provider: st.provider
    } : empty,
    todos: st ? st.todos : [],
    tokens: st ? {
      todayInput: st.todayUsage.inputTokens, todayOutput: st.todayUsage.outputTokens,
      todayTotal: st.todayUsage.total,
      sessionTotal: st.usage.inputTokens + st.usage.outputTokens,
      contextUsed: st.contextUsed, contextWindow: st.contextWindow || 1000000
    } : { contextWindow: 1000000 },
    system: systemPayload(),
    printer: printerState,
    balance: balanceState,
    balanceErr,
    health: { bridge: true, printer: printerState !== undefined, weather: false, summary: false },
    source: 'dsh-bridge-standalone'
  }
  const buf = Buffer.from(JSON.stringify(payload), 'utf8')
  await new Promise((res) => {
    sock.send(buf, PORT, HOST, (err) => {
      if (!err) sent++
      res()
    })
  })
  return payload
}

// 诊断落盘（与插件同路径，便于两种模式互查）
function dumpDbg(p, nowMs) {
  try {
    const dir = path.join(dshHome(), 'storages', 'lcd-bridge')
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(path.join(dir, 'last.json'), JSON.stringify({
      at: new Date(nowMs).toISOString(),
      mode: 'standalone',
      keyFrom: balance.keyNote,
      balanceErr: balance.err,
      balance: balance.state === undefined ? null : balance.state,
      printerState: p && p.printer ? p.printer.state : null,
      printerTrays: p && p.printer ? (p.printer.trays || []).length : 0
    }, null, 2))
  } catch { /* 落盘失败不影响推送 */ }
}

async function main() {
  cpuPercent()
  if (ONCE) {
    const p = await tick()
    console.log(JSON.stringify({ sent, agent: p.agent, tokens: p.tokens, balance: p.balance, printerState: p.printer && p.printer.state }, null, 2))
    sock.close()
    return
  }
  console.log(`[standalone] 启动：${HOST}:${PORT} 每 ${INTERVAL_MS}ms（不依赖 DSH 进程）`)
  console.log(`[standalone] 会话目录: ${path.join(dshHome(), 'sessions')}`)
  let running = true
  const stop = () => {
    running = false
    try { sock.close() } catch { }
    console.log(`\n[standalone] 停止（共推 ${sent} 次）`)
    process.exit(0)
  }
  process.on('SIGINT', stop)
  process.on('SIGTERM', stop)
  // 先预热一次（拿到 model/title/当日用量），再进入循环
  await tick().catch(() => { })
  while (running) {
    const t0 = Date.now()
    try {
      const p = await tick()
      dumpDbg(p, t0)
    } catch (e) {
      console.error(`[standalone] 一轮失败: ${e && e.message ? e.message : e}`)
    }
    const wait = Math.max(0, INTERVAL_MS - (Date.now() - t0))
    await new Promise((r) => setTimeout(r, wait))
  }
}

main().catch((e) => {
  console.error(`[standalone] 致命错误: ${e && e.stack ? e.stack : e}`)
  process.exit(1)
})
