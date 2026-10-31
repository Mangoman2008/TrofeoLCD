#!/usr/bin/env node
/**
 * console-server.mjs —— TrofeoLCD **可视化 Agent 控制台**（后端）
 *
 * ## 这是什么
 * 把 DSH 会话的**完整过程**（你的话 / 思考 / 工具调用+参数 / 工具结果 / 回复 / 待办 / 用量）
 * 做成一个浏览器里能看到、能操作的实时页面；同时把副屏（1920×462）的实时画面与**控制**
 * （主题、背景特效、旋转、画质档位…）并到同一页里。
 *
 * ## 与现有部件的关系（都不改动，纯新增）
 * ```
 *   ~/.dsh/sessions/<项目slug>/<会话id>/session.v4.jsonl.zstd
 *            │  ← 直接 import 插件里的解析器（同一份代码，不抄第二遍）
 *            ▼
 *   dsh-plugin/dsh-lcd-bridge/session.mjs   findCurrentSession / readTailLines /
 *            │                              readAllLines / deriveState
 *            ▼
 *   console-server.mjs（本文件，独立进程）
 *      ├─ 轻路径 1s：尾部快读 → state + 时间线
 *      ├─ 重路径 60s：全量解码 → 当日用量 / 小时柱 / 标题 / 模型 / 工具分布
 *      ├─ HTTP+SSE :54550 → 浏览器页面
 *      └─ 代理 ──▶ App 的 :54546 (/status /diag /frame.jpg /set?...)
 * ```
 * **不碰**：DSH 进程（插件照旧推 UDP）、App 的 USB 链路、`dsh-bridge.mjs`（外部老桥）、
 *          `web/preview.html`（网页预览页，另有 tools/make_web.py 管着它的两个宿主）。
 *
 * ## 为什么是"外部进程"而不是做成 DSH 插件
 * 插件改完必须**重启 DSH** 才生效（进程内加载）；而重启会打断正在跑的会话。
 * 这个控制台从会话文件读数据、从 App 的 HTTP 读画面，两条路都不需要重启任何人。
 * 解析逻辑仍然**只有一份**（import 插件的 session.mjs），所以不存在"两边走样"。
 * 想让指令框真正注入会话时，再把本文件的 startServer() 挂进插件即可（见 docs）。
 *
 * ## 用法
 *   node bridge/console-server.mjs                 # 起服务并打印地址
 *   node bridge/console-server.mjs --port 54550
 *   node bridge/console-server.mjs --once          # 打印一份 JSON 快照后退出（自检用）
 *   node bridge/console-server.mjs --watch <会话文件>   # 固定看某个会话
 * 环境变量：DSH_HOME / DSH_LCD_PORT 同插件。
 */

import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import {
  findCurrentSession,
  readTailLines,
  readAllLines,
  deriveState,
  dshHome,
} from '../dsh-plugin/dsh-lcd-bridge/session.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.dirname(HERE)
const WEB_FILE = path.join(ROOT, 'web', 'console.html')
/** 副屏 dashboard 的网页版（1:1 按 1920×462 画，改版式先在这里定稿，再交给 tools/dash_frame.py 渲染成屏上的帧） */
const DASH_FILE = path.join(ROOT, 'web', 'dashboard.html')
/** JEV 决策服务（bridge/jev-hud.mjs）：dashboard 的 JEV 面板经本服务同源代理过去，省掉跨端口 CORS */
// ★ 取值要放在 argValue 定义**之后**：ESM 的 const 是 TDZ，提前引用会在 import 阶段直接抛
//   （第一版就是这么挂的：服务起不来，页面全 000）
let JEV_BASE = process.env.DSH_JEV_URL || 'http://127.0.0.1:54551'

const argv = process.argv.slice(2)
const argValue = (name, def) => {
  const i = argv.indexOf(name)
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def
}

const PORT = Number(argValue('--port', process.env.DSH_LCD_CONSOLE_PORT || 54550))
JEV_BASE = argValue('--jev', JEV_BASE)
const APP_BASE = argValue('--app', process.env.DSH_LCD_APP || 'http://127.0.0.1:54546')
const ONCE = argv.includes('--once')
const WATCH = argValue('--watch', '')
/** 轻路径解析多少行（尾部窗口内） */
const TAIL_LINES = Number(argValue('--tail-lines', 4000))
/** 重路径（全量解码）间隔 */
const FULL_MS = Number(argValue('--full-ms', 60000))
/** 时间线保留多少条 */
const TIMELINE_KEEP = Number(argValue('--timeline', 240))
/** App 状态轮询间隔（毫秒） */
const APP_MS = Number(argValue('--app-ms', 1000))
/** 快照落盘（余额/打印机排障文件）刷新间隔 */
const SNAP_FILE_MS = 5000

const SESSIONS_ROOT = path.join(dshHome(), 'sessions')
const LCD_SNAP_FILE = path.join(dshHome(), 'storages', 'lcd-bridge', 'last.json')
const INBOX_FILE = path.join(dshHome(), 'storages', 'lcd-console', 'inbox.jsonl')

const log = (...a) => process.stderr.write('[console] ' + a.join(' ') + '\n')

// ───────────────────────── 工具函数 ─────────────────────────

function humanBytes(n) {
  if (!Number.isFinite(n)) return ''
  if (n < 1024) return n + ' B'
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB'
  return (n / 1048576).toFixed(2) + ' MB'
}

function oneLine(s, max = 160) {
  const t = String(s ?? '').replace(/\s+/g, ' ').trim()
  return t.length > max ? t.slice(0, max - 1) + '…' : t
}

function projectFromSlug(slug) {
  const m = /^--(.*)--$/.exec(slug || '')
  const p = m ? m[1] : slug || ''
  const parts = p.split('-').filter(Boolean)
  return parts.length ? parts[parts.length - 1] : ''
}

/** 工具名 → 中文标签（与屏幕侧 TOOL_LABEL 同表；屏幕那份在 session.mjs） */
const TOOL_LABEL = {
  bash: '执行命令',
  read: '读文件',
  write: '写文件',
  edit: '改文件',
  grep: '搜索内容',
  glob: '查找文件',
  subagent: '派子代理',
  subagent_fork: '派子代理',
  workflow: '跑工作流',
  todo_write: '更新待办',
  todo_read: '读取待办',
  ask_user_question: '询问用户',
  present: '交付文件',
  skill: '加载技能',
  create_goal: '建立目标',
  update_goal: '更新目标',
  web_search: '联网搜索',
  web_fetch: '抓取网页',
  job_output: '取后台输出',
  job_list: '列后台任务',
  job_kill: '停后台任务',
  read_image: '看图',
  modlens_read_image: '视觉识图',
  plugin_compat_check: '插件兼容检查',
  get_goal: '读目标',
  exit_plan_mode: '提交计划',
  send_message: '给子代理发消息',
  interrupt_agent: '中断子代理',
  list_agents: '列子代理',
  task_board_create: '建任务卡',
  task_board_run: '跑任务卡',
  task_board_get: '读任务卡',
  task_board_list: '列任务卡',
  task_board_update: '改任务卡',
  task_board_manage: '管理任务卡',
  beauticode_apply_image: '换背景图',
  beauticode_apply_video: '换背景视频',
  beauticode_clear: '清除背景',
  beauticode_set_fish: '摸鱼模式',
  beauticode_set_muted: '背景声音',
  beauticode_status: '背景状态',
  beauticode_theme_list: '列背景主题',
  beauticode_theme_use: '换背景主题',
}
const toolLabel = (t) => TOOL_LABEL[t] || (t ? `调用 ${t}` : '工具')

/**
 * 从 tool/call 的 arguments（JSON 字符串）里提炼"一眼能看懂"的摘要 + 细节。
 * 不同工具的入参形状差别很大，这里按工具挑最关键的字段；认不出来就截断原文。
 */
function summarizeArgs(name, rawArgs) {
  let a = null
  try {
    a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs
  } catch {
    a = null
  }
  if (!a || typeof a !== 'object') {
    return { brief: oneLine(rawArgs, 140), detail: String(rawArgs ?? '').slice(0, 4000) }
  }
  const pick = (...keys) => {
    for (const k of keys) {
      const v = a[k]
      if (typeof v === 'string' && v.length) return v
      if (Array.isArray(v) && v.length) return v.join(' ｜ ')
    }
    return ''
  }
  let brief = ''
  switch (name) {
    case 'bash':
      brief = pick('command')
      break
    case 'read':
    case 'write':
    case 'edit':
      brief = pick('file_path', 'path')
      break
    case 'grep':
      brief = pick('pattern')
      if (a.path) brief += `  @ ${oneLine(a.path, 60)}`
      break
    case 'glob':
      brief = pick('pattern')
      break
    case 'web_search':
      brief = pick('queries', 'query')
      break
    case 'web_fetch':
      brief = pick('url')
      break
    case 'subagent':
    case 'subagent_fork':
      brief = pick('description', 'prompt')
      break
    case 'workflow':
      brief = a.meta?.name || pick('script').slice(0, 80)
      break
    case 'ask_user_question':
      brief = a.questions?.[0]?.question || pick('question')
      break
    case 'todo_write':
      brief = Array.isArray(a.todos) ? `${a.todos.length} 条待办` : ''
      break
    case 'skill':
      brief = pick('name')
      break
    case 'present':
      brief = Array.isArray(a.files)
        ? a.files.map((f) => f?.path || f).slice(0, 3).join(' ｜ ')
        : ''
      break
    case 'task_board_create':
    case 'task_board_run':
      brief = pick('title', 'taskId')
      break
    default:
      brief = pick('description', 'path', 'file_path', 'command', 'query', 'name') ||
        JSON.stringify(a)
  }
  const detail = JSON.stringify(a, null, 2)
  return {
    brief: oneLine(brief || JSON.stringify(a), 140),
    detail: detail.length > 4000 ? detail.slice(0, 4000) + '\n…' : detail,
  }
}

function contentParts(message) {
  const content = message?.content
  if (!Array.isArray(content)) {
    if (typeof content === 'string') return [{ type: 'text', text: content }]
    return []
  }
  return content.filter((c) => c && typeof c === 'object')
}

function textOfParts(parts, type) {
  return parts
    .filter((c) => c.type === type && typeof c.text === 'string')
    .map((c) => c.text)
    .join('')
}

// ───────────────────────── 时间线 ─────────────────────────

/**
 * 把会话行变成"人能顺着读"的时间线。
 *
 * ★ 一行 = 一件事。工具调用与它的结果**配对成一条**（按 callId），
 *   这样界面上看到的是"读了哪个文件、花了多久、回来多大"，而不是两条互不相干的记录。
 *   配对失败的调用（正在跑的那条）标成 running —— 界面上就是"当前在做的事"。
 */
function buildTimeline(lines) {
  const rows = []
  const callIndex = new Map()
  let seq = 0

  const push = (r) => {
    r.i = seq++
    rows.push(r)
    if (rows.length > 4000) rows.splice(0, rows.length - 4000)
    return r
  }

  for (const line of lines) {
    let o
    try {
      o = JSON.parse(line)
    } catch {
      continue
    }
    const t = o.type
    const d = o.data || {}
    const ts = typeof o.time === 'number' ? o.time : 0
    const turn = typeof d.turn === 'number' ? d.turn : undefined
    const step = typeof d.step === 'number' ? d.step : undefined

    if (t === 'user/message') {
      const parts = contentParts(d)
      const text = textOfParts(parts, 'text')
      if (text.trim()) push({ ts, kind: 'user', text: text.slice(0, 4000), turn, step })
    } else if (t === 'assistant/message') {
      const msg = d.message || {}
      const parts = contentParts(msg)
      const text = textOfParts(parts, 'text').trim()
      const reasoning = textOfParts(parts, 'reasoning').trim()
      const usage = d.usage || msg.usage || null
      const row = push({
        ts,
        kind: 'assistant',
        text: text.slice(0, 4000),
        reasoning: reasoning.slice(0, 4000),
        reasoningLen: reasoning.length,
        usage: usage
          ? {
              input: usage.inputTokens ?? 0,
              output: usage.outputTokens ?? 0,
              cacheRead: usage.cacheReadTokens ?? 0,
              cacheWrite: usage.cacheWriteTokens ?? 0,
              total: usage.totalTokens ?? 0,
            }
          : null,
        turn,
        step,
      })
      row.hasText = text.length > 0
    } else if (t === 'tool/call') {
      const name = String(d.name || '')
      const { brief, detail } = summarizeArgs(name, d.arguments)
      const row = push({
        ts,
        kind: 'tool',
        callId: d.callId || '',
        tool: name,
        label: toolLabel(name),
        brief,
        detail,
        turn,
        step,
        running: true,
      })
      if (d.callId) callIndex.set(d.callId, row)
    } else if (t === 'tool/result') {
      const id = d.toolCallId || d.message?.toolCallId || ''
      const row = id ? callIndex.get(id) : null
      const text = textOfParts(contentParts(d.message), 'text')
      const info = {
        preview: oneLine(text, 400),
        bytes: Buffer.byteLength(text, 'utf8'),
        ms: row && row.ts ? Math.max(0, ts - row.ts) : undefined,
      }
      if (row) {
        row.running = false
        row.result = info
      } else {
        push({ ts, kind: 'result', text: info.preview, bytes: info.bytes, turn, step })
      }
    } else if (t === 'turn/start') {
      push({ ts, kind: 'turn', phase: 'start', turn })
    } else if (t === 'turn/end') {
      push({
        ts,
        kind: 'turn',
        phase: 'end',
        turn,
        reason: d.reason?.kind || '',
        error: d.reason?.error?.message ? oneLine(d.reason.error.message, 200) : '',
      })
    } else if (t === 'todo/write' || t === 'todo/update') {
      const items = Array.isArray(d.todos) ? d.todos : Array.isArray(d.items) ? d.items : []
      const done = items.filter((x) => x?.status === 'completed').length
      const doing = items.find((x) => x?.status === 'in_progress')
      push({
        ts,
        kind: 'todo',
        done,
        total: items.length,
        current: doing ? oneLine(doing.content ?? doing.text, 120) : '',
        turn,
        step,
      })
    } else if (t === 'session/title') {
      if (d.title) push({ ts, kind: 'title', text: String(d.title) })
    } else if (t === 'compaction/prune') {
      push({ ts, kind: 'compact', text: `上下文压缩，抵扣 ${d.shadowedTokenCount ?? 0} token` })
    } else if (t === 'agent/inbox/spliced') {
      const ins = Array.isArray(d.inserted) ? d.inserted : []
      for (const m of ins) {
        const txt = textOfParts(contentParts(m), 'text')
        if (txt.trim()) push({ ts, kind: 'user', text: txt.slice(0, 4000), via: 'inbox' })
      }
    }
  }

  // 正在跑的工具 = 最后一条还 running 的
  let runningTool = ''
  for (let i = rows.length - 1; i >= 0; i--) {
    if (rows[i].kind === 'tool' && rows[i].running) {
      runningTool = rows[i].tool
      break
    }
  }
  return { rows, runningTool }
}

// ───────────────────────── 重路径：全量统计 ─────────────────────────

/**
 * 全量解码统计（约 1.5–2.5s / 13MB 会话，所以 60s 一次）。
 * 拿的是尾部窗口覆盖不到的东西：**标题**（文件很前面）、**模型/provider**、当日用量、小时柱、工具分布。
 */
function analyzeAll(lines, nowMs) {
  const day = new Date(nowMs)
  day.setHours(0, 0, 0, 0)
  const dayStart = day.getTime()

  const hourly = new Array(24).fill(0)
  const out = {
    title: '',
    model: '',
    provider: '',
    contextWindow: 0,
    sessionId: '',
    cwd: '',
    turns: 0,
    todayUsage: { input: 0, output: 0, total: 0, calls: 0 },
    sessionUsage: { input: 0, output: 0, cacheRead: 0, total: 0 },
    hourly,
    toolCounts: {},
    errors: 0,
    todoDone: 0,
    todoTotal: 0,
    todos: [],
  }

  for (const line of lines) {
    let o
    try {
      o = JSON.parse(line)
    } catch {
      continue
    }
    const t = o.type
    const d = o.data || {}
    const ts = typeof o.time === 'number' ? o.time : 0

    if (t === 'session') {
      out.sessionId = o.id || out.sessionId
      out.cwd = o.cwd || out.cwd
      continue
    }
    if (t === 'session/title') {
      if (d.title) out.title = String(d.title)
      continue
    }
    if (t === 'request/context' || t === 'request/header') {
      if (d.model) out.model = d.model
      if (d.provider) out.provider = d.provider
      if (typeof d.contextWindow === 'number' && d.contextWindow > 0) out.contextWindow = d.contextWindow
      const h = d.header
      if (h) {
        if (!out.model && h.model) out.model = h.model
        if (!out.provider && h.provider) out.provider = h.provider
        const cfg = h.config
        if (cfg) {
          if (!out.model && cfg.model) out.model = cfg.model
          if (!out.provider && cfg.provider) out.provider = cfg.provider
        }
      }
      continue
    }
    if (t === 'assistant/message') {
      const u = d.usage || d.message?.usage
      if (u) {
        const inp = u.inputTokens ?? 0
        const outp = u.outputTokens ?? 0
        out.sessionUsage.input += inp
        out.sessionUsage.output += outp
        out.sessionUsage.cacheRead += u.cacheReadTokens ?? 0
        out.sessionUsage.total += u.totalTokens ?? inp + outp
        if (ts >= dayStart) {
          out.todayUsage.input += inp
          out.todayUsage.output += outp
          out.todayUsage.calls++
          const hh = new Date(ts).getHours()
          hourly[hh] += (u.totalTokens ?? inp + outp)
        }
      }
      continue
    }
    if (t === 'tool/call') {
      const n = String(d.name || '?')
      out.toolCounts[n] = (out.toolCounts[n] || 0) + 1
      continue
    }
    if (t === 'turn/start') {
      out.turns++
      continue
    }
    if (t === 'turn/end') {
      if (d.reason?.kind === 'error') out.errors++
      continue
    }
    if (t === 'todo/write' || t === 'todo/update') {
      const items = Array.isArray(d.todos) ? d.todos : Array.isArray(d.items) ? d.items : []
      if (items.length) {
        out.todos = items.slice(0, 40).map((x) => ({
          content: String(x?.content ?? x?.text ?? ''),
          status: String(x?.status ?? 'pending'),
        }))
        out.todoTotal = items.length
        out.todoDone = items.filter((x) => x?.status === 'completed').length
      }
      continue
    }
  }
  out.todayUsage.total = out.todayUsage.input + out.todayUsage.output
  return out
}

// ───────────────────────── 会话列表 ─────────────────────────

function listSessions(limit = 30) {
  const out = []
  let slugs = []
  try {
    slugs = fs.readdirSync(SESSIONS_ROOT)
  } catch {
    return out
  }
  for (const slug of slugs) {
    const slugDir = path.join(SESSIONS_ROOT, slug)
    let sids = []
    try {
      sids = fs.readdirSync(slugDir)
    } catch {
      continue
    }
    for (const sid of sids) {
      const dir = path.join(slugDir, sid)
      for (const name of ['session.v4.jsonl.zstd', 'session.jsonl.zstd']) {
        const file = path.join(dir, name)
        let st
        try {
          st = fs.statSync(file)
        } catch {
          continue
        }
        if (!st.isFile() || st.size === 0) continue
        let actMs = st.mtimeMs
        try {
          actMs = Math.max(actMs, fs.statSync(path.join(dir, 'session.lock')).mtimeMs)
        } catch {
          /* 没有 lock 也能用 */
        }
        out.push({
          file,
          sid,
          slug,
          project: projectFromSlug(slug),
          size: st.size,
          mtimeMs: st.mtimeMs,
          actMs,
          fname: name,
        })
      }
    }
  }
  out.sort((a, b) => b.actMs - a.actMs)
  return out.slice(0, limit)
}

// ───────────────────────── 采样器 ─────────────────────────

/**
 * ★ 选会话为什么不能只看文件 mtime（实测踩到）：
 *   会话文件会被 DSH 侧**重写/刷盘**（不一定是"这个会话有新活动"），
 *   于是某个几天前的大会话 mtime 一跳，就抢走了"最近活跃"的位置 ——
 *   控制台会突然开始显示一个**与你无关的旧会话**（第一次跑就撞上了：
 *   当前会话从本次会话跳到一个 15MB 的老会话，然后又跳回来）。
 *   正确做法：比**文件里最后一条事件的时间**（`time` 字段），那才是"谁在动"。
 *   代价可控：只在 (size,mtime) 变化时才重解一次尾部，其余命中缓存。
 */
const lastTsCache = new Map()

function lastEventTsOf(cand) {
  const c = lastTsCache.get(cand.file)
  if (c && c.size === cand.size && c.mtimeMs === cand.mtimeMs) return c.lastTs
  let lastTs = 0
  try {
    const lines = readTailLines(cand.file, cand.size)
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const o = JSON.parse(lines[i])
        if (typeof o.time === 'number' && o.time > 0) {
          lastTs = o.time
          break
        }
      } catch {
        /* 跳过坏行 */
      }
    }
  } catch {
    lastTs = 0
  }
  if (lastTs === 0) lastTs = cand.mtimeMs // 兜底：实在没有 time 字段
  lastTsCache.set(cand.file, { size: cand.size, mtimeMs: cand.mtimeMs, lastTs })
  return lastTs
}

const cache = {
  file: '',
  size: 0,
  mtimeMs: 0,
  tail: null,
  timeline: null,
  runningTool: '',
  heavy: null,
  heavyAt: 0,
  heavyFile: '',
  heavyBusy: false,
}

let watchFile = WATCH ? path.resolve(WATCH) : ''
/** 最近一条下发给页面的 UI 指令（页面按 id 去重，只执行一次） */
let uiCmd = null
let uiCmdSeq = 0
let current = null

/** 轻路径：尾部快读 → 状态 + 时间线（文件没变则复用） */
function sampleSession(sess, nowMs) {
  const unchanged = cache.file === sess.file && cache.size === sess.size && cache.mtimeMs === sess.mtimeMs
  if (unchanged && cache.tail) return cache

  let lines = readTailLines(sess.file, sess.size)
  if (lines.length > TAIL_LINES) lines = lines.slice(-TAIL_LINES)
  const st = deriveState(lines, nowMs)
  st.sessionId = sess.sid
  st.project = sess.project
  const { rows, runningTool } = buildTimeline(lines)

  cache.file = sess.file
  cache.size = sess.size
  cache.mtimeMs = sess.mtimeMs
  cache.tail = st
  cache.timeline = rows
  cache.runningTool = runningTool
  return cache
}

/** 重路径：全量解码（异步、不阻塞采样；失败保留上一次） */
async function refreshHeavy(sess, nowMs, force = false) {
  if (cache.heavyBusy) return
  if (!force && cache.heavyFile === sess.file && nowMs - cache.heavyAt < FULL_MS) return
  cache.heavyBusy = true
  cache.heavyAt = nowMs
  cache.heavyFile = sess.file
  try {
    const all = await readAllLines(sess.file)
    if (all.lines && all.lines.length) {
      cache.heavy = analyzeAll(all.lines, Date.now())
      cache.heavy.ms = all.ms
      cache.heavy.lines = all.lines.length
    }
  } catch (e) {
    log('全量解码失败: ' + (e && e.message ? e.message : e))
  } finally {
    cache.heavyBusy = false
  }
}

// ───────────────────────── App 侧（副屏）─────────────────────────

const appCache = { at: 0, status: null, diag: null, diagAt: 0, err: '' }

async function getJSON(url, ms = 1500) {
  const ac = new AbortController()
  const timer = setTimeout(() => ac.abort(), ms)
  try {
    const r = await fetch(url, { signal: ac.signal })
    if (!r.ok) throw new Error('HTTP ' + r.status)
    return await r.json()
  } finally {
    clearTimeout(timer)
  }
}

async function refreshApp(nowMs, force = false) {
  if (!force && nowMs - appCache.at < APP_MS) return
  appCache.at = nowMs
  try {
    appCache.status = await getJSON(APP_BASE + '/status')
    appCache.err = ''
  } catch (e) {
    appCache.status = null
    appCache.err = e && e.message ? e.message : String(e)
  }
  if (nowMs - appCache.diagAt > 5000) {
    appCache.diagAt = nowMs
    try {
      appCache.diag = await getJSON(APP_BASE + '/diag')
    } catch {
      appCache.diag = null
    }
  }
}

function readLcdSnapshot() {
  try {
    return JSON.parse(fs.readFileSync(LCD_SNAP_FILE, 'utf8'))
  } catch {
    return null
  }
}

// ───────────────────────── 快照组装 ─────────────────────────

const history = { cpu: [], mem: [] }
const MAX_HIST = 90

function buildSnapshot() {
  const nowMs = Date.now()

  // 1) 选会话：固定 watch > **按最后事件时间**的最新会话（见 lastEventTsOf 的注释）
  const list = listSessions(30)
  const cands = list.slice(0, 8)
  for (const c of cands) {
    c.lastTs = lastEventTsOf(c)
    c.idleSec = Math.max(0, Math.round((nowMs - c.lastTs) / 1000))
  }
  const byEvent = cands.slice().sort((a, b) => b.lastTs - a.lastTs)
  const newest = byEvent[0] || null

  if (watchFile) {
    current = list.find((s) => s.file === watchFile) || (fs.existsSync(watchFile)
      ? { file: watchFile, sid: path.basename(path.dirname(watchFile)), slug: '', project: '', size: fs.statSync(watchFile).size, mtimeMs: fs.statSync(watchFile).mtimeMs, actMs: Date.now() }
      : null)
  } else {
    // 跟随最新（带**粘性**）：这台机器上会同时跑好几个 DSH 会话（实测：同一时刻两个会话
    // 都在 busy），若严格按"谁最新跟谁"，画面会在它们之间来回跳。
    // 规则：当前会话还在出事件（<HOLD_MS）就别动；它安静下来了才切到最活跃的那个。
    const HOLD_MS = 10000
    const prev = current ? cands.find((c) => c.file === current.file) : null
    if (prev) current = prev // 用最新一次 stat 结果刷新（否则尾部缓存永远命中，画面会冻住）
    const curTs = prev ? prev.lastTs : 0
    const best = newest
    if (!current || !best) {
      current = best || current
    } else if (nowMs - curTs > HOLD_MS && best.file !== current.file && best.lastTs > curTs) {
      current = best
    }
  }
  const activeSessions = cands.filter((c) => nowMs - c.lastTs < 30000).length

  const out = {
    ts: nowMs,
    source: 'console-server',
    watch: watchFile ? 'pinned' : 'auto',
    session: null,
    agent: { state: 'unknown', activity: '', tool: '', turn: 0, step: 0, model: '', provider: '', project: '', sessionId: '' },
    todos: [],
    timeline: [],
    tokens: { todayInput: 0, todayOutput: 0, todayTotal: 0, contextUsed: 0, contextWindow: 1000000, hourly: new Array(24).fill(0) },
    stats: null,
    activeSessions,
    sessions: byEvent.concat(list.filter((s) => !cands.some((c) => c.file === s.file))).map((s) => {
      const c = cands.find((x) => x.file === s.file)
      return { ...s, lastTs: c ? c.lastTs : 0, idleSec: c ? c.idleSec : undefined, current: current ? s.file === current.file : false }
    }),
    system: systemPayload(),
    app: appPayload(),
    // 页面文件指纹：dashboard.html 一改（大小或 mtime 变），哈希就变，
    // 页面据此自己刷新 —— 改版式时不用手动按 F5（实测这条很省事）。
    ui: (() => {
      let hash = ''
      try {
        const st = fs.statSync(DASH_FILE)
        hash = `${st.size}-${Math.round(st.mtimeMs)}`
      } catch { /* 文件不在也算 */ }
      // cmd：服务端下发给页面的 UI 指令（下钻/提问/复位）。
      // 为什么需要：实机验证时"用鼠标点某个束"要靠坐标猜，太脆；有了这条通道，
      // 一条 curl 就能让正在看的页面进入指定状态（也方便以后做演示脚本）。
      return { hash, file: 'dashboard.html', cmd: uiCmd }
    })(),
    lcd: readLcdSnapshot(),
    health: { console: true, session: false, app: false, snapFile: false },
  }

  if (current) {
    const c = sampleSession(current, nowMs)
    const st = c.tail
    out.session = {
      file: current.file,
      sid: current.sid,
      project: st.project || current.project,
      size: current.size,
      mtimeMs: current.mtimeMs,
      ageSec: Math.round((nowMs - (current.lastTs || current.actMs)) / 1000),
      fname: current.fname,
    }
    out.agent = {
      state: st.state,
      activity: st.activity,
      tool: c.runningTool || st.tool,
      runningTool: c.runningTool,
      lastText: st.lastText,
      turn: st.turn,
      step: st.step,
      model: st.model || cache.heavy?.model || '',
      provider: st.provider || cache.heavy?.provider || '',
      project: st.project,
      sessionId: st.sessionId,
      errorText: st.errorText,
    }
    out.todos = st.todos
    out.title = st.title || cache.heavy?.title || ''
    out.timeline = (cache.timeline || []).slice(-TIMELINE_KEEP)
    out.tokens = {
      todayInput: st.todayUsage.inputTokens,
      todayOutput: st.todayUsage.outputTokens,
      todayTotal: st.todayUsage.total,
      contextUsed: st.contextUsed,
      contextWindow: st.contextWindow || cache.heavy?.contextWindow || 1000000,
      hourly: cache.heavy?.hourly || new Array(24).fill(0),
    }
    out.health.session = true
    void refreshHeavy(current, nowMs)
  }

  if (cache.heavy) {
    const h = { ...cache.heavy }
    // 全量算出的当日用量比尾部窗口准（尾部只覆盖最近几 MB）
    out.tokens.todayInput = Math.max(out.tokens.todayInput, h.todayUsage?.input ?? 0)
    out.tokens.todayOutput = Math.max(out.tokens.todayOutput, h.todayUsage?.output ?? 0)
    out.tokens.todayTotal = Math.max(out.tokens.todayTotal, h.todayUsage?.total ?? 0)
    if (h.hourly) out.tokens.hourly = h.hourly
    out.stats = {
      lines: h.lines,
      decodeMs: h.ms,
      turns: h.turns,
      errors: h.errors,
      toolCounts: h.toolCounts,
      sessionUsage: h.sessionUsage,
      todoDone: h.todoDone,
      todoTotal: h.todoTotal,
      todos: h.todos,
      cwd: h.cwd,
      ageMs: nowMs - cache.heavyAt,
    }
    if (!out.title && h.title) out.title = h.title
  }

  // 健康度：控制台自己永远活着，其余三项分别代表"能不能看到数据"
  out.health.app = !!(out.app && out.app.online)
  out.health.snapFile = !!out.lcd
  out.health.heavy = !!cache.heavy
  return out
}

function systemPayload() {
  const load = os.loadavg()
  const totalMB = Math.round(os.totalmem() / 1048576)
  const freeMB = Math.round(os.freemem() / 1048576)
  const usedMB = totalMB - freeMB
  const cpu = cpuPercent()
  history.cpu.push(cpu)
  history.mem.push(usedMB)
  if (history.cpu.length > MAX_HIST) history.cpu.shift()
  if (history.mem.length > MAX_HIST) history.mem.shift()
  return {
    cpu,
    cores: os.cpus().length,
    memUsed: usedMB,
    memTotal: totalMB,
    load1: Number(load[0].toFixed(2)),
    load5: Number(load[1].toFixed(2)),
    load15: Number(load[2].toFixed(2)),
    uptimeSec: Math.round(os.uptime()),
    host: os.hostname(),
    cpuHist: history.cpu.slice(-60),
    memHist: history.mem.slice(-60),
  }
}

let lastCpuSnap = null
function cpuPercent() {
  const cpus = os.cpus()
  let idle = 0
  let total = 0
  for (const c of cpus) {
    for (const k of Object.keys(c.times)) total += c.times[k]
    idle += c.times.idle
  }
  const snap = { idle, total }
  if (!lastCpuSnap) {
    lastCpuSnap = snap
    return 0
  }
  const dIdle = idle - lastCpuSnap.idle
  const dTotal = total - lastCpuSnap.total
  lastCpuSnap = snap
  if (dTotal <= 0) return 0
  return Number(Math.max(0, Math.min(100, (1 - dIdle / dTotal) * 100)).toFixed(1))
}

function appPayload() {
  const s = appCache.status
  const d = appCache.diag
  if (!s && !d) return { online: false, err: appCache.err }
  return {
    online: true,
    state: s?.state ?? '',
    theme: d?.theme ?? s?.theme ?? 0,
    jpegW: s?.jpegW ?? 0,
    jpegH: s?.jpegH ?? 0,
    jpegBytes: s?.jpegBytes ?? 0,
    sent: s?.sent ?? 0,
    errors: s?.errors ?? 0,
    fps: d?.fps ?? 0,
    usbOpen: !!(d?.usbOpen ?? s?.usbOpen),
    device: s?.device ?? d?.deviceInfo ?? '',
    rotate180: !!(d?.rotate180 ?? s?.rotate180),
    vertical: !!(d?.vertical ?? s?.vertical),
    night: !!(d?.night ?? s?.night),
    bridgeAgeSec: s?.bridgeAgeSec ?? -1,
    bridgeSource: s?.bridgeSource ?? '',
    selfTest: d?.selfTest ?? '',
    vmUrl: d?.vmUrl ?? '',
    platform: d?.platform ?? '',
  }
}

// ───────────────────────── HTTP ─────────────────────────

const sseClients = new Set()

function sendJSON(res, obj, code = 200) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8')
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': body.length,
  })
  res.end(body)
}

function readBody(req, limit = 1 << 20) {
  return new Promise((resolve) => {
    let n = 0
    const chunks = []
    req.on('data', (c) => {
      n += c.length
      if (n > limit) {
        req.destroy()
        resolve('')
        return
      }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', () => resolve(''))
  })
}

/** 允许的 /set 键（白名单：只放开"改了不会让屏幕下线"的那些） */
const SET_WHITELIST = new Set([
  'theme', 'page', 'pagerot', 'printerCell', 'background', 'profile',
  'vertical', 'vig', 'vigcorner', 'vigall', 'pipe', 'wbatch', 'wsize', 'q',
  'seqfps', 'seqlimit', 'seqstream', 'seqburst', 'seqwin', 'vmurl',
])

function filterSetQuery(q) {
  const keep = []
  const dropped = []
  for (const kv of String(q || '').split('&')) {
    const i = kv.indexOf('=')
    if (i <= 0) continue
    const k = kv.slice(0, i)
    if (SET_WHITELIST.has(k)) keep.push(kv)
    else dropped.push(k)
  }
  return { query: keep.join('&'), dropped }
}

async function proxyAppSet(q) {
  const { query, dropped } = filterSetQuery(q)
  if (!query) return { ok: false, error: '没有可用的键', dropped }
  try {
    const r = await fetch(APP_BASE + '/set?' + query, { signal: AbortSignal.timeout(3000) })
    const text = await r.text()
    let body = text
    try {
      body = JSON.parse(text)
    } catch {
      /* 原样返回 */
    }
    return { ok: r.ok, dropped, applied: body }
  } catch (e) {
    return { ok: false, error: e && e.message ? e.message : String(e), dropped }
  }
}

async function proxyAppFrame(res) {
  try {
    const r = await fetch(APP_BASE + '/frame.jpg', { signal: AbortSignal.timeout(4000) })
    if (!r.ok) throw new Error('HTTP ' + r.status)
    const buf = Buffer.from(await r.arrayBuffer())
    res.writeHead(200, {
      'Content-Type': 'image/jpeg',
      'Cache-Control': 'no-store',
      'Content-Length': buf.length,
    })
    res.end(buf)
  } catch (e) {
    res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('frame unavailable: ' + (e && e.message ? e.message : String(e)))
  }
}

function appendInbox(text, meta = {}) {
  const dir = path.dirname(INBOX_FILE)
  fs.mkdirSync(dir, { recursive: true })
  const line = JSON.stringify({ at: new Date().toISOString(), text, ...meta }) + '\n'
  fs.appendFileSync(INBOX_FILE, line, 'utf8')
  return INBOX_FILE
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://127.0.0.1')
  const p = url.pathname

  if (p === '/' || p === '/console' || p === '/index.html') {
    let html
    try {
      html = fs.readFileSync(WEB_FILE, 'utf8')
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('缺少界面文件: ' + WEB_FILE)
      return
    }
    const body = Buffer.from(html, 'utf8')
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'Content-Length': body.length,
    })
    res.end(body)
    return
  }

  if (p === '/dashboard' || p === '/dash') {
    let html
    try {
      html = fs.readFileSync(DASH_FILE, 'utf8')
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('缺少界面文件: ' + DASH_FILE)
      return
    }
    const body = Buffer.from(html, 'utf8')
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Content-Length': body.length })
    res.end(body)
    return
  }

  // JEV 代理：/jev/<path> → JEV 服务的 /<path>（GET/POST 都转发，原样回 JSON）
  if (p === '/jev' || p.startsWith('/jev/')) {
    const target = JEV_BASE + p.slice('/jev'.length) + (url.search || '')
    try {
      const isPost = req.method === 'POST' || req.method === 'PUT'
      const r = await fetch(target, {
        method: req.method,
        headers: { 'Content-Type': req.headers['content-type'] || 'application/json' },
        body: isPost ? await readBody(req) : undefined,
        signal: AbortSignal.timeout(35000),
      })
      const text = await r.text()
      res.writeHead(r.status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' })
      res.end(text)
    } catch (e) {
      sendJSON(res, { ok: false, error: 'JEV 服务不可达（bash tools/jev-hud.sh start）：' + (e && e.message ? e.message : String(e)) }, 502)
    }
    return
  }

  if (p === '/favicon.ico') {
    res.writeHead(204)
    res.end()
    return
  }

  if (p === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('ok')
    return
  }

  if (p === '/api/state') {
    await refreshApp(Date.now())
    sendJSON(res, buildSnapshot())
    return
  }

  if (p === '/api/stream') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-store',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    })
    res.write(': connected\n\n')
    sseClients.add(res)
    try {
      res.write('event: state\ndata: ' + JSON.stringify(latest) + '\n\n')
    } catch {
      /* 忽略 */
    }
    const bye = () => sseClients.delete(res)
    req.on('close', bye)
    req.on('error', bye)
    return
  }

  if (p === '/api/ui') {
    // 下发 UI 指令：{action:'drill', tool:'bash'} | {action:'ask', q:'最慢的调用'} | {action:'reset'}
    if (req.method !== 'POST') {
      sendJSON(res, { ok: false, error: 'POST only' }, 405)
      return
    }
    const body = await readBody(req)
    let j = {}
    try {
      j = JSON.parse(body)
    } catch {
      const q = new URLSearchParams(body)
      j = { action: q.get('action') || '', tool: q.get('tool') || '', q: q.get('q') || '' }
    }
    if (!j.action) {
      sendJSON(res, { ok: false, error: '缺少 action（drill / ask / reset）' }, 400)
      return
    }
    uiCmd = { id: ++uiCmdSeq, action: String(j.action), tool: j.tool ? String(j.tool) : '', q: j.q ? String(j.q) : '', at: Date.now() }
    sendJSON(res, { ok: true, cmd: uiCmd })
    return
  }

  if (p === '/api/sessions') {
    sendJSON(res, { sessions: listSessions(50), current: current?.file || '' })
    return
  }

  if (p === '/api/frame.jpg') {
    await proxyAppFrame(res)
    return
  }

  if (p === '/api/app') {
    await refreshApp(Date.now(), true)
    sendJSON(res, { status: appCache.status, diag: appCache.diag, err: appCache.err })
    return
  }

  if (p === '/api/watch') {
    if (req.method !== 'POST') {
      sendJSON(res, { ok: false, error: 'POST only' }, 405)
      return
    }
    const body = await readBody(req)
    let file = ''
    try {
      file = JSON.parse(body).file || ''
    } catch {
      file = new URLSearchParams(body).get('file') || ''
    }
    if (file === 'auto' || file === '') {
      watchFile = ''
      current = null
      sendJSON(res, { ok: true, watch: 'auto' })
      return
    }
    const abs = path.resolve(file)
    if (!fs.existsSync(abs)) {
      sendJSON(res, { ok: false, error: '文件不存在: ' + abs }, 400)
      return
    }
    watchFile = abs
    current = null
    cache.file = ''
    cache.heavyFile = ''
    sendJSON(res, { ok: true, watch: abs })
    return
  }

  if (p === '/api/inbox') {
    if (req.method === 'GET') {
      let lines = []
      try {
        lines = fs.readFileSync(INBOX_FILE, 'utf8').trim().split('\n').filter(Boolean).slice(-50)
      } catch {
        /* 还没有收件箱 */
      }
      sendJSON(res, { file: INBOX_FILE, items: lines.map((l) => { try { return JSON.parse(l) } catch { return { text: l } } }) })
      return
    }
    const body = await readBody(req)
    let text = ''
    let meta = {}
    try {
      const j = JSON.parse(body)
      text = j.text || ''
      meta = { target: j.target || '', note: j.note || '' }
    } catch {
      text = new URLSearchParams(body).get('text') || ''
    }
    if (!text.trim()) {
      sendJSON(res, { ok: false, error: '空指令' }, 400)
      return
    }
    const f = appendInbox(text.trim(), { ...meta, session: current?.file || '', sid: current?.sid || '' })
    sendJSON(res, { ok: true, file: f, note: '已存入收件箱（当前版本不会自动注入运行中的会话）' })
    return
  }

  if (p === '/api/app/set') {
    if (req.method !== 'POST') {
      sendJSON(res, { ok: false, error: 'POST only' }, 405)
      return
    }
    const body = await readBody(req)
    let q = ''
    try {
      q = JSON.parse(body).q || ''
    } catch {
      q = new URLSearchParams(body).get('q') || ''
    }
    const out = await proxyAppSet(q)
    await refreshApp(Date.now(), true)
    sendJSON(res, out)
    return
  }

  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
  res.end('not found')
})

// ───────────────────────── 主循环 ─────────────────────────

let latest = { ts: Date.now(), agent: { state: 'starting' } }

function broadcast() {
  if (!sseClients.size) return
  const payload = 'event: state\ndata: ' + JSON.stringify(latest) + '\n\n'
  for (const c of sseClients) {
    try {
      c.write(payload)
    } catch {
      sseClients.delete(c)
    }
  }
}

async function main() {
  if (!fs.existsSync(SESSIONS_ROOT)) {
    log(`警告：找不到会话目录 ${SESSIONS_ROOT}（DSH_HOME=${dshHome()}）`)
  }
  if (ONCE) {
    // 自检要看到"完整"的一份：全量统计是异步的，这里显式等它跑完再输出，
    // 否则 stats/hourly 永远是 null（第一版就是这样，自检看不出问题）。
    await refreshApp(Date.now(), true)
    cpuPercent()
    const list = listSessions(5)
    if (list.length) {
      current = list[0]
      await refreshHeavy(current, Date.now(), true)
    }
    latest = buildSnapshot()
    process.stdout.write(JSON.stringify(latest, null, 2) + '\n')
    return
  }

  cpuPercent() // 建立 CPU 基线
  await refreshApp(Date.now(), true)

  server.on('error', (e) => {
    log('HTTP 服务错误: ' + (e && e.message ? e.message : e))
    process.exit(1)
  })
  server.listen(PORT, '127.0.0.1', () => {
    log(`可视化 Agent 控制台: http://127.0.0.1:${PORT}/`)
    log(`数据源: ${SESSIONS_ROOT}`)
    log(`副屏代理: ${APP_BASE}（/status /diag /frame.jpg /set）`)
  })

  const timer = setInterval(async () => {
    try {
      await refreshApp(Date.now())
      latest = buildSnapshot()
      broadcast()
    } catch (e) {
      log('一轮失败: ' + (e && e.message ? e.message : e))
    }
  }, 1000)
  timer.unref?.()

  const shutdown = () => {
    log('退出中…')
    try {
      server.close()
    } catch {
      /* ignore */
    }
    process.exit(0)
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)

  // 让 --once 之外也能持续运行
  await new Promise(() => {})
}

main().catch((e) => {
  log('启动失败: ' + (e && e.stack ? e.stack : e))
  process.exit(1)
})
