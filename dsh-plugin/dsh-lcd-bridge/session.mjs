/**
 * session.mjs —— 进程内读取 DSH 会话，产出屏幕要的遥测字段。
 *
 * ## 为什么能"进程内"
 * DSH 的 node 运行时**原生支持 zstd**（`node:zlib` 里有 `zstdDecompressSync` /
 * `createZstdDecompress`，实测 Node 26）。会话文件 `session.v4.jsonl.zstd` 是
 * **多帧 zstd 流**，但 `zstdDecompressSync` 一次就能解开（实测 13.7MB → 45MB，
 * 313ms）。所以插件可以直接读到解密后的实时数据，
 * **不需要外部的 node 脚本、不需要 zstd.exe、不需要 spawn 任何进程**。
 *
 * ## 为什么只读尾部
 * 单个会话解压后可达 45MB / 18000+ 行，每秒全量重解析不可接受。
 * 这里按 **mtime + size 增量**：文件没变就不重读；变了只解压**尾部若干字节**，
 * 并只解析最后 N 行（屏幕要的是"当前状态"，历史行没有价值）。
 * 注意 zstd 不能从任意偏移解压，所以做法是**从文件尾截取一段压缩字节**再解
 * —— 多帧流的帧边界让我们能这么做：从尾部往前找帧魔数 `28 B5 2F FD`。
 */
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import zlib from 'node:zlib'

/** zstd 帧魔数（小端） */
const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])

/**
 * 从尾部最多读这么多压缩字节（**快路径**）。
 *
 * ★ 实测调优（2026-10-15，13.6MB 会话上量的）：
 *   | 尾部 | 解压 | 行数 | 提炼 | state/turn/step |
 *   |---|---|---|---|---|
 *   | 0.5MB | 11ms | 652 | 21ms | busy/149/3 |
 *   | 1MB   | 25ms | 1302 | 47ms | busy/149/3 |
 *   | 2MB   | 45ms | 2461 | 65ms | busy/149/3 |
 *   | 4MB   | 77ms | 5238 | 114ms | busy/149/3 |
 *   | 8MB   | 160ms | 10804 | 267ms | busy/149/3 |
 *   **活字段（state/activity/tool/turn/step）在 0.5MB 就已经正确**，
 *   而 8MB 每秒要 380ms ≈ **38% 占用率**、事件循环最大阻塞 612ms
 *   —— 会把 DSH 主进程拖卡（同一进程，插件阻塞就是 DSH 阻塞）。
 *   所以快路径只取 1MB（≈72ms/s ≈ 7%），重字段交给低频全量。
 */
const TAIL_BYTES = 1 * 1024 * 1024

/** 最多解析这么多行（从尾部往前） */
const MAX_LINES = 2000

/** 判定"刚结束"的时间窗（对齐桥的 15s） */
const RECENT_MS = 15000

export function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
}

/**
 * 找出"当前会话"：所有会话目录里 session.lock / session.v4.jsonl.zstd
 * mtime 最新的那个。
 */
export function findCurrentSession(sessionsRoot) {
  let best = null
  for (const slug of safeReaddir(sessionsRoot)) {
    const slugDir = path.join(sessionsRoot, slug)
    if (!safeIsDir(slugDir)) continue
    for (const sid of safeReaddir(slugDir)) {
      const dir = path.join(slugDir, sid)
      if (!safeIsDir(dir)) continue
      for (const name of ['session.v4.jsonl.zstd', 'session.jsonl.zstd']) {
        const file = path.join(dir, name)
        let st
        try {
          st = fs.statSync(file)
        } catch {
          continue
        }
        if (!st.isFile()) continue
        // 用 lock 的 mtime 更能反映"最近活动"（会话文件是追加写的，也会更新）
        let actMs = st.mtimeMs
        try {
          actMs = Math.max(actMs, fs.statSync(path.join(dir, 'session.lock')).mtimeMs)
        } catch {
          /* 没有 lock 也能用 */
        }
        if (!best || actMs > best.actMs) {
          best = { file, sid, slug, actMs, size: st.size, mtimeMs: st.mtimeMs }
        }
      }
    }
  }
  return best
}

function safeReaddir(p) {
  try {
    return fs.readdirSync(p)
  } catch {
    return []
  }
}
function safeIsDir(p) {
  try {
    return fs.statSync(p).isDirectory()
  } catch {
    return false
  }
}

/**
 * 解压 zstd 文件的**尾部**（从最后一个帧头开始），返回文本行数组。
 * 失败时回退到"整文件解压"（慢但正确）。
 */
export function readTailLines(file, size) {
  const want = Math.min(size, TAIL_BYTES)
  const start = size - want
  const buf = Buffer.allocUnsafe(want)
  let fd = null
  try {
    fd = fs.openSync(file, 'r')
    fs.readSync(fd, buf, 0, want, start)
  } catch {
    return []
  } finally {
    if (fd !== null) {
      try {
        fs.closeSync(fd)
      } catch {
        /* ignore */
      }
    }
  }

  // 只在"从文件中段截取"时才需要对齐帧边界；整文件读取本来就是帧起点。
  // ★ 取**最早**的帧起点（不是最后一个）：最后一个帧往往很小（实测只有几百字节
  //   → 解出 2 行），从最早的帧起点解才能覆盖足够多的近期内容。
  let slice = buf
  if (start > 0) {
    const idx = buf.indexOf(ZSTD_MAGIC)
    if (idx < 0) return []
    slice = buf.subarray(idx)
  }

  const tryDecode = (b) => {
    try {
      return zlib.zstdDecompressSync(b).toString('utf8')
    } catch {
      return null
    }
  }
  let text = tryDecode(slice)
  if (text === null) {
    // 尾部截取落在帧中间：从下一个帧头再试
    let ok = null
    for (let at = buf.indexOf(ZSTD_MAGIC, (slice.length ? 4 : 0)); at >= 0; at = buf.indexOf(ZSTD_MAGIC, at + 1)) {
      ok = tryDecode(buf.subarray(at))
      if (ok !== null) break
    }
    text = ok
  }
  if (text === null) {
    // 最后手段：整文件解压（慢但正确）
    text = tryDecode(fs.readFileSync(file))
  }
  if (text === null) return []
  const lines = text.split('\n')
  // 第一行可能是被截断的半行；只有当它是"从中间开始"时才丢弃
  if (start > 0 && lines.length > 1 && !lines[0].startsWith('{')) lines.shift()
  return lines.filter((l) => l.length > 0).slice(-MAX_LINES)
}

/**
 * 流式解压**整个**会话文件（容忍尾部未完整）。
 *
 * ★ 为什么必须流式（实测教训）：
 *   一开始想"读文件开头一小段"拿元数据（model/title/contextWindow），
 *   试了 32KB→8MB **全部失败**（`unexpected end of file`）；
 *   而尾部截取虽然能解，却只覆盖最近的行 —— 元数据在**文件最前面**（第 2 行），
 *   永远不在尾部窗口里。
 *   实测发现整个会话是**一个持续写入的大帧**，所以：
 *     · 从头部解 → 尾部不完整 → 报错
 *     · 从尾部解 → 拿不到开头的元数据
 *   唯一正确的读法是**流式解码器**：喂完整文件、让它一路输出，
 *   最后那段不完整的尾部会被它自然丢弃（实测没有报错，解出 45MB/18350 行）。
 *
 * 代价：1.5 秒级（13.7MB 压缩）→ 只适合低频调用（见 index.mjs 的两层节奏）。
 * 返回 { lines, ms }，失败时 lines 为 null。
 */
export async function readAllLines(file) {
  const t0 = Date.now()
  const chunks = []
  let err = null
  try {
    // ★ 必须用**异步流**：zlib 的流是异步产出数据的，
    //   同步 `dec.write()` 之后立刻读 `dec.read()` 什么也拿不到
    //   （第一版就是这么错的：解出 0 行，耗时 15ms）。
    //   `for await` 会一直等到流结束；尾部不完整的帧会以 error 形式出现，
    //   此时已产出的数据仍然有效（实测正常会话不会报错）。
    const src = fs.createReadStream(file, { highWaterMark: 1 << 20 })
    for await (const c of src.pipe(zlib.createZstdDecompress())) chunks.push(c)
  } catch (e) {
    err = e
  }
  const out = Buffer.concat(chunks)
  if (out.length === 0) return { lines: null, ms: Date.now() - t0, err }
  return { lines: out.toString('utf8').split('\n').filter((l) => l.length > 0), ms: Date.now() - t0, err }
}

/**
 * 从尾部行数组里提炼屏幕需要的状态。
 * 语义对齐 `bridge/dsh-bridge.mjs`（那边是外部脚本，这里是进程内同源逻辑）。
 */
export function deriveState(lines, nowMs) {
  const st = {
    state: 'idle',
    activity: '',
    tool: '',
    lastText: '',
    turn: 0,
    step: 0,
    model: '',
    provider: '',
    contextWindow: 0,
    contextUsed: 0,
    // 本会话累计（今天用量由调用方按 ts 过滤后累加）
    usage: { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, reasoningTokens: 0 },
    todayUsage: { inputTokens: 0, outputTokens: 0, total: 0 },
    lastTurnEndTs: 0,
    errorText: '',
    todos: [],
    title: ''
  }

  let sawBusy = false
  for (const line of lines) {
    let o
    try {
      o = JSON.parse(line)
    } catch {
      continue
    }
    const t = o.type
    const d = o.data || {}
    const time = typeof o.time === 'number' ? o.time : 0

    if (t === 'session') {
      if (d.title) st.title = d.title
      continue
    }
    if (t === 'request/header' || t === 'request/context') {
      // ★ 实测：模型/provider/上下文窗口在 **`data` 这一层**（不是 data.header 里）
      //   request/context 的 data = { provider, model, contextWindow, systemPromptUpdate }
      if (d.model) st.model = d.model
      if (d.provider) st.provider = d.provider
      if (typeof d.contextWindow === 'number' && d.contextWindow > 0) st.contextWindow = d.contextWindow
      // 兜底：有的版本把它们放在 data.header 里
      const h = d.header
      if (h) {
        // 实测：有些版本在 data.header.config.model（不是 data.header.model）
        const cfg = h.config
        const hm = (typeof h.model === 'string') ? h.model
          : (cfg && typeof cfg.model === 'string' ? cfg.model : '')
        const hp = (typeof h.provider === 'string') ? h.provider
          : (cfg && typeof cfg.provider === 'string' ? cfg.provider : '')
        if (!st.model && hm) st.model = hm
        if (!st.provider && hp) st.provider = hp
        if (!st.contextWindow && typeof h.contextWindow === 'number') st.contextWindow = h.contextWindow
      }
      continue
    }
    if (t === 'session/title') {
      // data = { title, messageSeqs, source }
      if (typeof d.title === 'string' && d.title) st.title = d.title
      continue
    }
    if (t === 'assistant/message') {
      const u = d.usage || o.usage
      if (u) {
        const inp = num(u.inputTokens)
        const out = num(u.outputTokens)
        const cr = num(u.cacheReadTokens)
        st.usage.inputTokens += inp
        st.usage.outputTokens += out
        st.usage.cacheReadTokens += cr
        st.usage.reasoningTokens += num(u.reasoningTokens)
        // 上下文占用 = 本轮输入 + 缓存读（对齐桥的算法）
        if (inp + cr > 0) st.contextUsed = inp + cr
        if (isToday(time, nowMs)) {
          st.todayUsage.inputTokens += inp
          st.todayUsage.outputTokens += out
        }
      }
      // ★ 模型/provider 也从这里取（实测 data.message.source 就带）：
      //   request/context 整个会话只有极少数几条，且集中在文件开头 →
      //   原来的"尾部快路径"永远拿不到 model。而 assistant/message 每步都有。
      const src = d && d.message && d.message.source
      if (src) {
        if (!st.model && typeof src.model === 'string') st.model = src.model
        if (!st.provider && typeof src.provider === 'string') st.provider = src.provider
      }
      const txt = textOfAssistant(d)
      if (txt) st.lastText = txt.slice(-400)
      sawBusy = true
      continue
    }
    if (t === 'tool/call') {
      st.tool = String(d.name || d.tool || '')
      if (typeof d.turn === 'number') st.turn = d.turn
      if (typeof d.step === 'number') st.step = d.step
      sawBusy = true
      continue
    }
    if (t === 'turn/start') {
      if (typeof d.turn === 'number') st.turn = d.turn
      // 新一轮开始 → 清掉上一轮的错误，避免"错误粘住"
      st.errorText = ''
      sawBusy = true
      continue
    }
    if (t === 'step/start') {
      if (typeof d.step === 'number') st.step = d.step
      continue
    }
    if (t === 'turn/end') {
      st.lastTurnEndTs = time || nowMs
      // ★ 真实错误信号是 `data.reason.kind`（实测取值 completed / aborted /
      //   interrupted / error），而**没有** data.error（111 条 turn/end 命中 0 次）。
      //   原代码查 d.error → 出错永远不会显示。
      //   另外：正常结束时必须**清空** errorText，否则一次错误会粘住整个窗口。
      const kind = (d.reason && typeof d.reason.kind === 'string') ? d.reason.kind : ''
      if (kind.length > 0 && kind !== 'completed') {
        st.errorText = kind === 'error' ? '本轮出错'
          : (kind === 'aborted' ? '本轮被中止' : `本轮${kind}`)
      } else if (kind === 'completed' || kind === '') {
        st.errorText = ''
      }
      sawBusy = false
      continue
    }
    if (t === 'todo/write' || t === 'todo/update') {
      const items = d.todos || d.items
      if (Array.isArray(items)) {
        st.todos = items.slice(0, 20).map((x) => ({
          content: String(x?.content ?? x?.text ?? ''),
          status: String(x?.status ?? 'pending')
        }))
      }
      continue
    }
  }

  st.todayUsage.total = st.todayUsage.inputTokens + st.todayUsage.outputTokens

  // ── 状态判定（对齐桥：最近活动 → busy / waiting / idle）──
  const lastTs = Math.max(st.lastTurnEndTs, 0)
  if (st.errorText) {
    st.state = 'waiting'
    st.activity = '出错了：' + st.errorText.slice(0, 60)
  } else if (sawBusy) {
    st.state = 'busy'
    st.activity = st.tool ? toolLabel(st.tool) : '思考中…'
  } else if (lastTs > 0) {
    st.state = nowMs - lastTs < RECENT_MS ? 'waiting' : 'idle'
    if (st.state === 'waiting') st.activity = '已完成，等待你输入'
  } else {
    st.state = 'idle'
  }
  return st
}

function isToday(timeMs, nowMs) {
  if (!timeMs) return false
  const a = new Date(timeMs)
  const b = new Date(nowMs)
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

function num(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0
}

/**
 * 从 assistant/message 的 data 里取"最近一段文字"。
 *
 * ★ 真实结构（2026-10-19 用真实会话实测，1197 条尾部记录）：
 *     data.message.content = [ { type: 'reasoning', text: '…' },
 *                              { type: 'text',      text: '…' }, … ]
 *   原来查的是 `d.text` / `d.content` —— 两处都不存在（实测 189 条
 *   assistant/message 里命中 0 次），所以**屏上"最近一句话"永远是空**。
 *
 * 取值优先级：
 *   1) data.message.content 里 type === 'text' 的块（只取正文，不取思维链）
 *   2) 同上但任意带 text 的块（有些消息只有 reasoning）
 *   3) 旧/兼容结构：d.text、d.content
 */
function textOfAssistant(d) {
  const msg = d && d.message
  if (msg && Array.isArray(msg.content)) {
    const texts = msg.content
      .filter((c) => c && c.type === 'text' && typeof c.text === 'string')
      .map((c) => c.text)
      .join('')
    if (texts.length > 0) return texts
    const anyText = msg.content
      .filter((c) => c && typeof c.text === 'string')
      .map((c) => c.text)
      .join('')
    if (anyText.length > 0) return anyText
  }
  if (typeof d.text === 'string') return d.text
  if (Array.isArray(d.content)) {
    return d.content
      .filter((c) => c && (c.type === 'text' || typeof c.text === 'string'))
      .map((c) => String(c.text ?? ''))
      .join('')
  }
  if (typeof d.content === 'string') return d.content
  return ''
}

const TOOL_LABEL = {
  bash: '执行命令',
  read: '读文件',
  write: '写文件',
  edit: '改文件',
  grep: '搜索内容',
  glob: '查找文件',
  subagent: '派子代理',
  workflow: '跑工作流',
  todo_write: '更新待办',
  ask_user_question: '询问用户',
  present: '交付文件'
}
function toolLabel(tool) {
  return TOOL_LABEL[tool] || `调用 ${tool}`
}
