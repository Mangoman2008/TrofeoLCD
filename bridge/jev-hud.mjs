#!/usr/bin/env node
/**
 * jev-hud.mjs —— JEV（TypeSafe Jev / System One 决策模型）的**决策光路**后端
 *
 * ## 它是什么
 * Jev 不是聊天模型：你给它 **state（任意内容）** 和一组**带类型的问题**，
 * 它回你**结构化的判定**——没有生成文本，每条判定带概率与置信度：
 *
 *   choice : { type:'choice', choice:'returns', confidence:1.0, probabilities:{...} }
 *   score  : { type:'score',  score:1.43, confidence:0.35, legend:{...}, probabilities:{...} }
 *   noul   : { type:'noul',   noul:0.99 }            （概率本身就是答案，没有独立 confidence）
 *
 * 本文件把这个过程做成可看的东西：一次请求 → 「state → JEV 核心 → 每条问题一根光导线 → 判定节点」，
 * 另外提供**批量扫描**（一个目录里的文件逐个提问，逐条点亮，像 jev-xray 那样）。
 *
 * ## 接口与 key（真实 API）
 *   POST https://api.typesafe.ai/v1/systemone
 *   Authorization: Bearer <key>
 *   { "model":"jev-latest", "state": <string|object|array>, "questions": { key: {type,instructions,criteria?} } }
 * key 的取值顺序（与官方 playground 一致）：
 *   ① 环境变量 TYPESAFE_API_KEY   ② 文件 ~/.config/typesafe/env 里的一行 TYPESAFE_API_KEY=...
 * **key 只在服务端使用，绝不下发到浏览器**（页面里看到的请求 JSON 用 $TYPESAFE_API_KEY 占位）。
 *
 * ## 没有 key 也能看
 * 内置**本地模拟判定器**（按路径/关键词/分支密度等启发式，产出与真 API **同形**的结果），
 * 页面会明确标 SIMULATED。它的用途只有一个：让你在没有 key 时也能看到界面与交互。
 *
 * 用法：
 *   node bridge/jev-hud.mjs                 # 默认 127.0.0.1:54551
 *   node bridge/jev-hud.mjs --port 54551
 *   TYPESAFE_API_KEY=sk-... node bridge/jev-hud.mjs
 *   node bridge/jev-hud.mjs --force-mock    # 就算有 key 也走模拟（自检用）
 */

import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.dirname(HERE)
const WEB_FILE = path.join(ROOT, 'web', 'jev.html')

const argv = process.argv.slice(2)
const argValue = (n, d) => {
  const i = argv.indexOf(n)
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d
}
const PORT = Number(argValue('--port', process.env.DSH_JEV_PORT || 54551))
const BASE_URL = (argValue('--base-url', process.env.TYPESAFE_BASE_URL || 'https://api.typesafe.ai')).replace(/\/$/, '')
const MODEL = argValue('--model', process.env.JEV_MODEL || 'jev-latest')
const FORCE_MOCK = argv.includes('--force-mock')
const RPS = Number(argValue('--rps', '18'))
const CONCURRENCY = Number(argValue('--concurrency', '4'))
/** 输入 token 单价（美元/百万），jev-xray 里写的就是这个：输出 token 不计费 */
const PRICE_PER_MTOK = 0.042

const log = (...a) => process.stderr.write('[jev] ' + a.join(' ') + '\n')

// ───────────────────────── key ─────────────────────────

export function readApiKey() {
  if (process.env.TYPESAFE_API_KEY) {
    return { key: process.env.TYPESAFE_API_KEY.trim(), source: '环境变量 TYPESAFE_API_KEY' }
  }
  const file = process.env.TYPESAFE_ENV_FILE || path.join(os.homedir(), '.config', 'typesafe', 'env')
  try {
    const line = fs.readFileSync(file, 'utf8')
      .split('\n')
      .map((l) => l.trim())
      .find((l) => l.startsWith('TYPESAFE_API_KEY='))
    if (line) return { key: line.slice('TYPESAFE_API_KEY='.length).trim(), source: file }
  } catch {
    /* 没有就没有 */
  }
  return { key: '', source: '' }
}

const KEY = readApiKey()
const HAS_KEY = KEY.key.length > 0 && !FORCE_MOCK

// ───────────────────────── 限流 ─────────────────────────

class Limiter {
  constructor(rps, concurrency) {
    this.interval = 1000 / rps
    this.max = concurrency
    this.active = 0
    this.nextAt = 0
    this.waiters = []
  }
  async acquire() {
    while (this.active >= this.max) await new Promise((r) => this.waiters.push(r))
    this.active++
    const now = Date.now()
    const at = Math.max(now, this.nextAt)
    this.nextAt = at + this.interval
    if (at > now) await new Promise((r) => setTimeout(r, at - now))
  }
  release() {
    this.active--
    this.waiters.shift()?.()
  }
}
const limiter = new Limiter(RPS, CONCURRENCY)

// ───────────────────────── 真 API ─────────────────────────

const stats = { requests: 0, decisions: 0, inputTokens: 0, outputTokens: 0, errors: 0, latencies: [] }

async function askReal({ state, questions, model }) {
  await limiter.acquire()
  const started = Date.now()
  try {
    const res = await fetch(`${BASE_URL}/v1/systemone`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${KEY.key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: model || MODEL, state, questions }),
      signal: AbortSignal.timeout(30000),
    })
    const text = await res.text()
    if (!res.ok) {
      stats.errors++
      const hint = res.status === 401 || res.status === 403
        ? '（key 被拒：检查 TYPESAFE_API_KEY）'
        : ''
      return { ok: false, status: res.status, error: `Jev 返回 ${res.status} ${hint}`.trim(), body: text.slice(0, 800), latencyMs: Date.now() - started }
    }
    let data
    try {
      data = JSON.parse(text)
    } catch {
      return { ok: false, status: res.status, error: '响应不是合法 JSON', body: text.slice(0, 800), latencyMs: Date.now() - started }
    }
    return { ok: true, data, latencyMs: Date.now() - started, simulated: false }
  } catch (e) {
    stats.errors++
    return { ok: false, error: '网络错误：' + (e && e.message ? e.message : String(e)), latencyMs: Date.now() - started }
  } finally {
    limiter.release()
  }
}

// ───────────────────────── 本地模拟判定器 ─────────────────────────
//
// 只有一条原则：**产出的结构与真 API 完全一致**，这样界面与代码在两种模式下走同一条路。
// 判定本身是启发式（路径规则 + 关键词重合 + 分支密度），不冒充模型。

const STOP = new Set(('the a an and or of to in on for with without from by is are be this that these those it its ' +
  'file files code content path does do into about any all as at which what when how who whose there their than then ' +
  'has have had not only also very more most some such can could would should will may might is_ this_').split(' '))

function keywords(text) {
  return [...new Set(String(text).toLowerCase().match(/[a-z\u4e00-\u9fa5][a-z0-9\u4e00-\u9fa5_]{2,}/g) || [])]
    .filter((w) => !STOP.has(w))
    .map((w) => ({ stem: w.slice(0, 5), weight: Math.min(9, w.length - 1) }))
}

function overlap(words, text) {
  if (!words.length) return 0
  const hay = String(text).toLowerCase()
  let hit = 0
  let total = 0
  for (const { stem, weight } of words) {
    total += weight
    if (hay.includes(stem)) hit += weight
  }
  return total ? hit / total : 0
}

function seeded(seedStr) {
  const h = crypto.createHash('sha256').update(String(seedStr)).digest()
  let i = 0
  return () => {
    const v = h.readUInt32BE((i * 4) % 28)
    i++
    return v / 0xffffffff
  }
}

function softmax(list) {
  const max = Math.max(...list)
  const exps = list.map((x) => Math.exp(x - max))
  const sum = exps.reduce((a, b) => a + b, 0) || 1
  return exps.map((x) => x / sum)
}

function confidenceOf(probs) {
  // 与官方语义一致的精神：分布越集中越自信（峰值 × 集中度）
  const peak = Math.max(...probs)
  const entropy = -probs.reduce((a, p) => a + (p > 0 ? p * Math.log(p) : 0), 0)
  const norm = Math.log(Math.max(2, probs.length))
  const flat = 1 - entropy / norm
  return Number(Math.max(0, Math.min(1, peak * 0.65 + flat * 0.35)).toFixed(4))
}

function textOfState(state) {
  if (typeof state === 'string') return state
  try {
    return JSON.stringify(state)
  } catch {
    return String(state)
  }
}

/**
 * 角色启发式（只在模拟模式用）：路径规则优先，其次看内容里的强信号词。
 * 参考 jev-xray 的 simulate.js 思路，但这里写成显式的投票，便于排障时看懂为什么这么判。
 */
const ROLE_RULES = [
  ['tests', /(^|\/)(tests?|__tests__|spec|specs|fixtures?|mocks?|benchmarks?|e2e)(\/|$)|[._-](test|spec|bench)\.[a-z]+$|^test_|_test\.[a-z]+$/],
  ['docs', /\.(md|mdx|rst|txt|adoc)$|(^|\/)(docs?|examples?|guides?)(\/|$)|changelog|license/i],
  ['infra', /(^|\/)(\.github|\.circleci|scripts?|tools?|ci|deploy|docker|k8s|helm|terraform)(\/|$)|dockerfile|makefile|\.(ya?ml|toml|ini|cfg|conf|lock)$|(^|\/)(package|tsconfig|jsconfig|eslint[^/]*|prettier[^/]*)\.json$|^\.[a-z]+rc/],
  ['ui', /\.(tsx|jsx|vue|svelte|astro|css|scss|sass|less|html)$|(^|\/)(components?|pages|views|ui|layouts?|styles?|client|frontend|jsx|dom)(\/|$)/i],
  ['data', /(^|\/)(db|database|models?|schemas?|migrations?|repositor(y|ies)|store|stores|cache|storage|prisma|orm|sql|dao)(\/|$)|\.(sql|prisma|graphql|proto)$/i],
  ['api', /(^|\/)(api|routes?|handlers?|controllers?|server|cli|cmd|bin|adapters?|endpoints?|rpc)(\/|$)|(^|\/)(main|server|app|cli)\.[a-z]+$/i],
  ['util', /(^|\/)(utils?|helpers?|types?|constants?|common|shared)(\/|$)|\.d\.ts$|(^|\/)(types?|constants?|utils?|helpers?)\.[a-z]+$/i],
]
const ROLE_CONTENT_HINT = [
  ['api', /\b(router|route|handler|endpoint|req\b|res\b|request|response|middleware|express|fastify|http)\b/i],
  ['data', /\b(SELECT|INSERT|UPDATE|DELETE|prisma|sequelize|migration|schema|query)\b/],
  ['ui', /\b(render|jsx|useState|useEffect|template|component|className)\b/i],
  ['infra', /\b(docker|kubectl|terraform|pipeline|workflow|npm run|make)\b/i],
]

function guessRole(p, content) {
  for (const [role, re] of ROLE_RULES) if (re.test(p)) return role
  // 内容没有强信号时看词面：安全/鉴权类代码多半是核心逻辑或对外接口
  const votes = {}
  for (const [role, re] of ROLE_CONTENT_HINT) if (re.test(content)) votes[role] = (votes[role] || 0) + 1
  if (/\b(auth|jwt|token|password|login|session|cookie|permission|crypto|hash|sign|verify)\b/i.test(content)) {
    votes.api = (votes.api || 0) + 1.4
    votes.core = (votes.core || 0) + 1
  }
  const best = Object.entries(votes).sort((a, b) => b[1] - a[1])[0]
  return best ? best[0] : 'core'
}

function simulateOne(state, questions, seedStr) {
  const rand = seeded(seedStr + textOfState(state).length)
  const hay = textOfState(state)
  const lines = hay.split('\n')
  const branches = (hay.match(/\b(if|else|for|while|switch|case|catch|elif|except|match)\b|&&|\|\||\?\s/g) || []).length
  const density = Math.min(1, branches / Math.max(1, lines.length) / 0.25)
  const size = Math.min(1, Math.log10(Math.max(10, lines.length)) / 3.3)
  const todo = Math.min(1, (hay.match(/\b(TODO|FIXME|HACK|XXX)\b/g) || []).length / 4)
  const secrets = Math.min(1, (hay.match(/\b(auth|token|password|secret|credential|crypto|jwt|oauth|session|cookie|permission|encrypt|decrypt|hmac|hash)\w*/gi) || []).length / 6)
  const base = Math.max(0, Math.min(1, 0.45 * density + 0.35 * size + 0.2 * rand()))

  const answers = {}
  for (const [key, q] of Object.entries(questions || {})) {
    const type = q?.type
    const askWords = keywords(`${q?.instructions || ''} ${key}`)
    if (type === 'choice') {
      const options = Object.keys(q.criteria || {})
      if (!options.length) {
        answers[key] = { type: 'choice', choice: '', confidence: 0, probabilities: {} }
        continue
      }
      const role = guessRole(String(state?.path || ''), hay)
      const isRoleQ = /role|角色/i.test(key + ' ' + (q.instructions || ''))
      const logits = options.map((opt) => {
        const crit = typeof q.criteria[opt] === 'string' ? q.criteria[opt] : JSON.stringify(q.criteria[opt] ?? '')
        let v = overlap(keywords(opt + ' ' + crit), hay) * 3.4 + overlap(askWords, crit) * 1.4 + rand() * 0.9 - 0.45
        // 角色问题有明确的规则投票时，直接压过模糊的词面重合（否则会把登录函数判成 ui）
        if (isRoleQ && opt === role) v += 3.2
        return v
      })
      const probs = softmax(logits)
      const probabilities = {}
      options.forEach((o, i) => { probabilities[o] = Number(probs[i].toFixed(4)) })
      let best = 0
      options.forEach((o, i) => { if (probs[i] > probs[best]) best = i })
      answers[key] = {
        type: 'choice',
        choice: options[best],
        confidence: confidenceOf(probs),
        probabilities,
      }
    } else if (type === 'score') {
      const levels = Array.isArray(q.criteria) ? q.criteria : []
      if (!levels.length) {
        answers[key] = { type: 'score', score: 0, confidence: 0, legend: {}, probabilities: {} }
        continue
      }
      const fit = base + overlap(askWords, hay) * 0.25
      const logits = levels.map((lv, i) => {
        const t = i / Math.max(1, levels.length - 1)
        return -Math.abs(t - fit) * 5.5 + overlap(keywords(lv), hay) * 1.2 + rand() * 0.5
      })
      const probs = softmax(logits)
      const probabilities = {}
      const legend = {}
      levels.forEach((lv, i) => {
        probabilities[String(i)] = Number(probs[i].toFixed(4))
        legend[String(i)] = lv
      })
      let score = 0
      probs.forEach((p, i) => { score += p * i })
      answers[key] = {
        type: 'score',
        score: Number(score.toFixed(2)),
        confidence: confidenceOf(probs),
        legend,
        probabilities,
      }
    } else {
      // noul：指令里的词与内容重合度 + 结构化特征
      const w = keywords(q?.instructions || key)
      let p = overlap(w, hay) * 0.55 + base * 0.3 + 0.08 + rand() * 0.12
      if (/secur|secret|auth|credential|密码|密钥/i.test(q?.instructions || key)) p = p * 0.6 + secrets * 0.45
      if (/test|测试/i.test(q?.instructions || key)) p = p * 0.7 + Math.min(1, branches / 30) * 0.45
      if (/legacy|deprecat|遗留/i.test(q?.instructions || key)) p = p * 0.7 + todo * 0.5
      p = Math.max(0.01, Math.min(0.99, p))
      answers[key] = { type: 'noul', noul: Number(p.toFixed(4)) }
    }
  }
  const inputTokens = Math.round(hay.length / 4) + 40 * Object.keys(questions || {}).length
  return {
    data: { model: 'simulated-local', answers, usage: { input_tokens: inputTokens, output_tokens: Object.keys(questions || {}).length * 6 } },
    simulated: true,
    latencyMs: 3 + Math.round(rand() * 12),
  }
}

// ───────────────────────── 记账 ─────────────────────────

function record(res, simulated) {
  stats.requests++
  if (res.data?.answers) stats.decisions += Object.keys(res.data.answers).length
  const u = res.data?.usage
  if (u) {
    stats.inputTokens += u.input_tokens || 0
    stats.outputTokens += u.output_tokens || 0
  }
  if (typeof res.latencyMs === 'number') {
    stats.latencies.push(res.latencyMs)
    if (stats.latencies.length > 200) stats.latencies.shift()
  }
  res.simulated = simulated
}

function statsPayload() {
  const sorted = [...stats.latencies].sort((a, b) => a - b)
  const p50 = sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0
  return {
    ...stats,
    p50: Math.round(p50),
    costUsd: (stats.inputTokens / 1e6) * PRICE_PER_MTOK,
    pricePerMTok: PRICE_PER_MTOK,
  }
}

async function ask({ state, questions, model }) {
  if (HAS_KEY) {
    const res = await askReal({ state, questions, model })
    if (res.ok) record(res, false)
    else stats.requests++
    return res
  }
  const res = simulateOne(state, questions, JSON.stringify(Object.keys(questions || {})))
  record(res, true)
  return { ok: true, ...res }
}

// ───────────────────────── 批量扫描 ─────────────────────────

const jobs = new Map()
let jobSeq = 0

const SKIP_DIR = new Set(['node_modules', '.git', 'build', 'dist', '.build-output', 'oh_modules', 'preview', '.diag', '.artifacts', 'win_dist'])

function listFiles(dir, max = 200) {
  const out = []
  const walk = (d, depth) => {
    if (out.length >= max || depth > 6) return
    let entries = []
    try {
      entries = fs.readdirSync(d, { withFileTypes: true })
    } catch {
      return
    }
    for (const e of entries) {
      if (out.length >= max) return
      if (e.name.startsWith('.') || SKIP_DIR.has(e.name)) continue
      const full = path.join(d, e.name)
      if (e.isDirectory()) walk(full, depth + 1)
      else if (e.isFile()) {
        let st
        try {
          st = fs.statSync(full)
        } catch {
          continue
        }
        if (st.size === 0 || st.size > 400 * 1024) continue
        if (!/\.(mjs|js|cjs|ts|tsx|jsx|ets|cs|py|rs|go|java|kt|swift|c|h|cpp|hpp|md|json|json5|yml|yaml|html|css|sh)$/i.test(e.name)) continue
        out.push({ file: full, rel: path.relative(dir, full), size: st.size })
      }
    }
  }
  walk(dir, 0)
  return out
}

function createJob({ files, question, maxTokens, model }) {
  const id = 'job' + (++jobSeq)
  const job = {
    id,
    fileList: files,        // ★ 必须在 startJob 之前就位：runJob 是 fire-and-forget，晚一步就是 undefined
    total: files.length,
    done: 0,
    results: [],
    errors: 0,
    startedAt: Date.now(),
    finishedAt: null,
    clients: new Set(),
    question,
    model,
    maxTokens,
  }
  jobs.set(id, job)
  void runJob(job)
  return job
}

function emit(job, event, payload) {
  const chunk = `event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`
  for (const res of job.clients) {
    try {
      res.write(chunk)
    } catch {
      job.clients.delete(res)
    }
  }
}

async function runJob(job) {
  const cap = Math.max(500, (job.maxTokens || 3000) * 4)
  for (const f of job.fileList) {
    let content = ''
    try {
      content = fs.readFileSync(f.file, 'utf8').slice(0, cap)
    } catch {
      job.errors++
      continue
    }
    const state = { path: f.rel, content }
    const res = await ask({ state, questions: { [job.question.key]: job.question.spec }, model: job.model })
    job.done++
    if (!res.ok) {
      job.errors++
      emit(job, 'error', { rel: f.rel, error: res.error })
      continue
    }
    const answer = res.data.answers?.[job.question.key] || null
    const row = {
      rel: f.rel,
      size: f.size,
      answer,
      latencyMs: res.latencyMs,
      simulated: !!res.simulated,
      inputTokens: res.data.usage?.input_tokens || 0,
    }
    job.results.push(row)
    emit(job, 'answer', row)
    emit(job, 'progress', { done: job.done, total: job.total, errors: job.errors, stats: statsPayload() })
  }
  job.finishedAt = Date.now()
  emit(job, 'done', { done: job.done, total: job.total, errors: job.errors, ms: job.finishedAt - job.startedAt, stats: statsPayload() })
}

// ───────────────────────── 内置透镜包（与 jev-xray 的 default.json 同构）─────────────────────────

const LENSES = [
  {
    key: 'role', label: '角色', type: 'choice',
    instructions: 'What is the main role of the file at `path` in this codebase, judging from `content`?',
    criteria: {
      core: 'Core domain or business logic, algorithms, internal engines.',
      api: 'Entry points and interfaces: HTTP handlers, routes, CLI commands, RPC, the public SDK surface.',
      ui: 'User interface: components, views, pages, styles, client-side presentation.',
      data: 'Data access and persistence: database queries, models, schemas, migrations, caching, storage.',
      util: 'Shared helpers, type definitions, constants and small glue code used across the codebase.',
      infra: 'Configuration, build, CI, deployment, packaging, tooling and maintenance scripts.',
      tests: 'Automated tests, fixtures, mocks and benchmarks.',
      docs: 'Documentation, guides, examples and changelogs.',
    },
  },
  {
    key: 'blast_radius', label: '影响半径', type: 'score',
    instructions: 'If a subtle bug slipped into `content`, how much damage could it do to the product and its users?',
    criteria: [
      'Cosmetic: nobody would notice.',
      'Local: one minor feature misbehaves.',
      'Feature: an important feature breaks.',
      'System: many features or the whole application break.',
      'Severe: data loss, a security breach, or money lost.',
    ],
  },
  {
    key: 'complexity', label: '复杂度', type: 'score',
    instructions: 'How much careful thought does a competent engineer need to change `content` without breaking anything?',
    criteria: [
      'Trivial: obvious at a glance.',
      'Simple: straightforward, linear logic.',
      'Moderate: some state or branching to keep in mind.',
      'Intricate: subtle interactions, concurrency, or many edge cases.',
      'Labyrinth: very hard to change without breaking something.',
    ],
  },
  {
    key: 'security', label: '安全敏感', type: 'noul',
    instructions: 'Does `content` touch authentication, secrets, crypto, or parse untrusted input?',
  },
  {
    key: 'debt', label: '技术债', type: 'score',
    instructions: 'How much does `content` look like tech debt — hacks, dead code, TODOs, workarounds?',
    criteria: ['Clean.', 'Minor smells.', 'Noticeable debt.', 'Heavy debt.', 'Rewrite candidate.'],
  },
  {
    key: 'needs_tests', label: '值得测试', type: 'noul',
    instructions: 'Does `content` contain real branching or parsing logic that deserves tests?',
  },
  {
    key: 'start_here', label: '从这读起', type: 'noul',
    instructions: 'Should a new contributor read this file in their first hour?',
  },
  {
    key: 'legacy', label: '遗留代码', type: 'noul',
    instructions: 'Is `content` deprecated, abandoned, or mostly commented out?',
  },
]

// ───────────────────────── HTTP ─────────────────────────

function sendJSON(res, obj, code = 200) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8')
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': body.length,
  })
  res.end(body)
}

function readBody(req, limit = 8 << 20) {
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

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://127.0.0.1')
  const p = url.pathname

  if (p === '/' || p === '/jev' || p === '/index.html') {
    let html
    try {
      html = fs.readFileSync(WEB_FILE, 'utf8')
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('缺少界面文件: ' + WEB_FILE)
      return
    }
    const body = Buffer.from(html, 'utf8')
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Content-Length': body.length })
    res.end(body)
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

  if (p === '/api/info') {
    sendJSON(res, {
      model: MODEL,
      baseURL: BASE_URL,
      configured: HAS_KEY,
      keySource: KEY.source,          // 只报来源，绝不回 key
      keyMasked: KEY.key ? KEY.key.slice(0, 6) + '…' + KEY.key.slice(-4) : '',
      mock: !HAS_KEY,
      forceMock: FORCE_MOCK,
      lenses: LENSES,
      pricePerMTok: PRICE_PER_MTOK,
      node: process.version,
    })
    return
  }

  if (p === '/api/stats') {
    sendJSON(res, statsPayload())
    return
  }

  if (p === '/api/ask') {
    if (req.method !== 'POST') {
      sendJSON(res, { ok: false, error: 'POST only' }, 405)
      return
    }
    let body
    try {
      body = JSON.parse(await readBody(req))
    } catch {
      sendJSON(res, { ok: false, error: '请求体不是合法 JSON' }, 400)
      return
    }
    const questions = body.questions && typeof body.questions === 'object' ? body.questions : {}
    if (!Object.keys(questions).length) {
      sendJSON(res, { ok: false, error: '至少要有一个问题' }, 400)
      return
    }
    const out = await ask({ state: body.state ?? '', questions, model: body.model })
    sendJSON(res, { ...out, stats: statsPayload() })
    return
  }

  if (p === '/api/file') {
    // 把本机文件读进来当 state（本地便利功能）。
    // 边界：只读 home 目录下、≤512KB 的文件，并拒绝明显是凭据的文件
    //（否则这个页面就成了"一键把 key 贴到屏幕上"的工具）。
    const want = path.resolve(url.searchParams.get('path') || '')
    const home = os.homedir()
    const deny = /(^|\/)(\.credentials\.yaml|\.env|\.netrc|id_rsa|id_ed25519|.*\.pem|.*\.key|.*\.p12|.*\.pfx)$/i
    if (!want || !fs.existsSync(want)) {
      sendJSON(res, { ok: false, error: '文件不存在: ' + want }, 400)
      return
    }
    if (!want.startsWith(home + path.sep)) {
      sendJSON(res, { ok: false, error: '只允许读 home 目录下的文件' }, 403)
      return
    }
    if (deny.test(want)) {
      sendJSON(res, { ok: false, error: '这个文件看起来含凭据，拒绝读取' }, 403)
      return
    }
    let st
    try {
      st = fs.statSync(want)
    } catch {
      sendJSON(res, { ok: false, error: '取不到文件信息' }, 400)
      return
    }
    if (!st.isFile()) {
      sendJSON(res, { ok: false, error: '不是普通文件' }, 400)
      return
    }
    if (st.size > 512 * 1024) {
      sendJSON(res, { ok: false, error: '文件太大（' + Math.round(st.size / 1024) + 'KB > 512KB）' }, 400)
      return
    }
    try {
      sendJSON(res, { ok: true, file: want, size: st.size, content: fs.readFileSync(want, 'utf8') })
    } catch (e) {
      sendJSON(res, { ok: false, error: '读取失败: ' + (e && e.message ? e.message : String(e)) }, 400)
    }
    return
  }

  if (p === '/api/files') {
    const dir = path.resolve(url.searchParams.get('dir') || ROOT)
    const max = Math.min(500, Number(url.searchParams.get('max') || 120))
    if (!fs.existsSync(dir)) {
      sendJSON(res, { ok: false, error: '目录不存在: ' + dir }, 400)
      return
    }
    const files = listFiles(dir, max)
    sendJSON(res, { ok: true, dir, files, count: files.length })
    return
  }

  if (p === '/api/scan') {
    if (req.method !== 'POST') {
      sendJSON(res, { ok: false, error: 'POST only' }, 405)
      return
    }
    let body
    try {
      body = JSON.parse(await readBody(req))
    } catch {
      sendJSON(res, { ok: false, error: '请求体不是合法 JSON' }, 400)
      return
    }
    const dir = path.resolve(body.dir || ROOT)
    const maxFiles = Math.min(400, Number(body.maxFiles || 60))
    const fileList = Array.isArray(body.files) && body.files.length
      ? body.files.map((f) => ({ file: path.resolve(f.file || f), rel: f.rel || path.basename(f.file || f), size: f.size || 0 }))
      : listFiles(dir, maxFiles)
    if (!fileList.length) {
      sendJSON(res, { ok: false, error: '目录里没有可判定的文件' }, 400)
      return
    }
    const question = body.question && body.question.key && body.question.spec
      ? body.question
      : { key: 'start_here', spec: LENSES.find((l) => l.key === 'start_here') }
    const job = createJob({ files: fileList, question, maxTokens: Number(body.maxTokens || 3000), model: body.model })
    sendJSON(res, { ok: true, id: job.id, total: job.total, question: question.key, simulated: !HAS_KEY })
    return
  }

  if (p.startsWith('/api/scan/') && p.endsWith('/stream')) {
    const id = p.slice('/api/scan/'.length, -'/stream'.length)
    const job = jobs.get(id)
    if (!job) {
      sendJSON(res, { ok: false, error: '没有这个任务: ' + id }, 404)
      return
    }
    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-store',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    })
    res.write(': connected\n\n')
    // 补发已经出过的结果（中途连上来也能看到全貌）
    for (const r of job.results) res.write(`event: answer\ndata: ${JSON.stringify(r)}\n\n`)
    res.write(`event: progress\ndata: ${JSON.stringify({ done: job.done, total: job.total, errors: job.errors, stats: statsPayload() })}\n\n`)
    if (job.finishedAt) {
      res.write(`event: done\ndata: ${JSON.stringify({ done: job.done, total: job.total, errors: job.errors, ms: job.finishedAt - job.startedAt, stats: statsPayload() })}\n\n`)
      res.end()
      return
    }
    job.clients.add(res)
    const bye = () => job.clients.delete(res)
    req.on('close', bye)
    req.on('error', bye)
    return
  }

  if (p.startsWith('/api/scan/')) {
    const id = p.slice('/api/scan/'.length)
    const job = jobs.get(id)
    if (!job) {
      sendJSON(res, { ok: false, error: '没有这个任务: ' + id }, 404)
      return
    }
    sendJSON(res, {
      ok: true, id: job.id, done: job.done, total: job.total, errors: job.errors,
      finished: !!job.finishedAt, results: job.results, stats: statsPayload(),
    })
    return
  }

  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
  res.end('not found')
})

server.on('error', (e) => {
  log('HTTP 错误: ' + (e && e.message ? e.message : e))
  process.exit(1)
})

server.listen(PORT, '127.0.0.1', () => {
  log(`JEV 决策光路: http://127.0.0.1:${PORT}/`)
  log(HAS_KEY
    ? `模式：真实 API（${BASE_URL}，模型 ${MODEL}，key 来自 ${KEY.source}）`
    : `模式：**本地模拟**（没有 TYPESAFE_API_KEY${FORCE_MOCK ? '，--force-mock' : ''}；页面会标 SIMULATED）`)
  log(`限流：${RPS} req/s，并发 ${CONCURRENCY}`)
})

const shutdown = () => {
  log('退出')
  try {
    server.close()
  } catch {
    /* ignore */
  }
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
