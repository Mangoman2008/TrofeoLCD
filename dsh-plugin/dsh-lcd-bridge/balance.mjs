/**
 * balance.mjs —— DeepSeek 账户余额（进程内定时拉取）
 *
 * ## 为什么在插件里做
 * 原来由**外部 node 桥**负责（`--deepseek-balance 600`）。实测发现：
 *   · 外部桥**找不到 key 文件**（它的默认路径 `--deepseek-key-file` 下没有文件）
 *     → `balanceErr = '读不到 key 文件'`，余额一项永远是空的
 *   · 而 DeepSeek 的余额 API 本身是通的（实测返回 `CNY 184.63`）
 * 用户要求"搬进软件本身"，所以在插件里自己取，并把 key 的来源做得更宽松。
 *
 * ## key 从哪来（按顺序找）
 *   1. 环境变量 `DEEPSEEK_API_KEY`
 *   2. `$DSH_HOME/deepseek.key`（或 `~/.dsh/deepseek.key`）—— 与外部桥约定一致
 *   3. `$DSH_HOME/.credentials.yaml` 里的 `DEEPSEEK_API_KEY:` 行
 *
 * 第 3 条是**从 DSH 自己的凭据库里取**，最省事（用户不用额外放文件）。
 * 它用正则取行而不是完整解析 YAML —— 这个文件是 DSH 自己写的、格式稳定，
 * 而且**解析失败只会少一个数据源，不会影响其他功能**。
 */

const BALANCE_URL = 'https://api.deepseek.com/user/balance'

/** 默认刷新间隔：10 分钟（余额变化慢，且这是外网请求） */
const DEFAULT_INTERVAL_MS = 600000

export function balanceIntervalMs() {
  const v = Number(process.env.DSH_LCD_BALANCE_MS || DEFAULT_INTERVAL_MS)
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_INTERVAL_MS
}

/** 读 key：env → deepseek.key → .credentials.yaml */
export function readApiKey(fs, path, os) {
  const env = process.env.DEEPSEEK_API_KEY
  if (typeof env === 'string' && env.trim().length > 0) {
    return { key: env.trim(), from: 'env DEEPSEEK_API_KEY' }
  }
  const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
  const keyFile = path.join(home, 'deepseek.key')
  try {
    const k = fs.readFileSync(keyFile, 'utf8').trim()
    if (k) return { key: k, from: keyFile }
  } catch {
    /* 继续找下一个来源 */
  }
  // DSH 凭据库
  try {
    const cred = fs.readFileSync(path.join(home, '.credentials.yaml'), 'utf8')
    const m = /^\s*DEEPSEEK_API_KEY:\s*(\S+)\s*$/m.exec(cred)
    if (m && m[1]) return { key: m[1], from: '.credentials.yaml' }
  } catch {
    /* 忽略 */
  }
  return { key: '', from: '' }
}

export class BalanceWatcher {
  constructor(fsMod, pathMod, osMod, intervalMs) {
    this.fs = fsMod
    this.path = pathMod
    this.os = osMod
    this.intervalMs = intervalMs || balanceIntervalMs()
    this.lastAt = 0
    this.state = undefined
    this.err = ''
    this.keyNote = ''
  }

  async poll(nowMs) {
    if (this.state !== undefined && nowMs - this.lastAt < this.intervalMs) {
      return { state: this.state, err: this.err }
    }
    this.lastAt = nowMs
    const { key, from } = readApiKey(this.fs, this.path, this.os)
    if (!key) {
      this.err = '找不到 DEEPSEEK_API_KEY（env / deepseek.key / .credentials.yaml）'
      this.state = undefined
      return { state: this.state, err: this.err }
    }
    this.keyNote = from
    try {
      const ctrl = new AbortController()
      const timer = setTimeout(() => ctrl.abort(), 10000)
      const res = await fetch(BALANCE_URL, {
        headers: { Authorization: 'Bearer ' + key },
        signal: ctrl.signal
      })
      clearTimeout(timer)
      if (!res.ok) {
        this.err = 'HTTP ' + res.status
        return { state: this.state, err: this.err }
      }
      const j = await res.json()
      const infos = Array.isArray(j.balance_infos) ? j.balance_infos : []
      const first = infos.length > 0 ? infos[0] : {}
      const n = (v) => {
        const x = Number(v)
        return Number.isFinite(x) ? x : -1
      }
      this.state = {
        currency: typeof first.currency === 'string' ? first.currency : 'CNY',
        total: n(first.total_balance),
        granted: n(first.granted_balance),
        toppedUp: n(first.topped_up_balance),
        available: j.is_available === true
      }
      this.err = ''
      return { state: this.state, err: this.err }
    } catch (e) {
      this.err = '请求失败: ' + (e && e.message ? e.message : String(e))
      return { state: this.state, err: this.err }
    }
  }
}
