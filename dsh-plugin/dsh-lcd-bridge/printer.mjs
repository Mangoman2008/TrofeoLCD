/**
 * printer.mjs —— 拓竹打印机状态（进程内轮询本机 bambu-monitor）
 *
 * ## 为什么在插件里做
 * 原来这项由**外部 node 桥**负责（`dsh-bridge.mjs --printer http://127.0.0.1:8790/api/state`）。
 * 用户要求数据桥"搬进软件本身"，而且实测发现**外部桥其实没在推这两项数据**
 * （进程在、但余额/打印机都没到 App）→ 干脆在插件里自己取。
 *
 * ## 映射语义
 * 与 `bridge/dsh-bridge.mjs` 的 `mapBambuState()` 保持同构 —— App 侧的
 * `normalizePrinter()` 认这套字段名（state / percent / layer / trays / hms …），
 * 不能改名字，否则屏上显示不出来。
 */

/** 默认的监控服务地址（桥的默认值是空，这里给个可用默认） */
const DEFAULT_URL = 'http://127.0.0.1:8790/api/state'

/** 连续失败几次就报离线 */
const MAX_FAILS = 3

export function printerUrl() {
  return process.env.DSH_LCD_PRINTER || DEFAULT_URL
}

/**
 * RGB 整数（拓竹给的是 `"000000FF"` 这类 RGBA hex）→ CSS 颜色。
 * 返回 undefined 表示"没有有效颜色"，App 侧会跳过色块。
 */
export function toCssColor(v) {
  if (typeof v !== 'string') return undefined
  const s = v.trim()
  // 支持 "RRGGBB" / "RRGGBBAA"
  if (/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(s)) {
    return '#' + s.slice(0, 6).toUpperCase()
  }
  if (/^#[0-9a-fA-F]{6}$/.test(s)) return s.toUpperCase()
  return undefined
}

function num(v, def) {
  return (typeof v === 'number' && Number.isFinite(v)) ? v : def
}

/**
 * 把 bambu-monitor 的 `/api/state` 响应映射成 App 认的 printer 结构。
 * 字段名与外部桥的 `mapBambuState()` 一致。
 */
export function mapBambuState(api) {
  const st = (api && api.state) || {}
  const pr = st.progress || {}
  const te = st.temps || {}
  const am = st.ams || {}
  const er = st.errors || {}
  const dev = (api && api.monitor && api.monitor.device) || {}

  // 托盘拉平：多台 AMS 的槽位按 1..N 连续编号（面板只画前几个）
  const trays = []
  const units = Array.isArray(am.units) ? am.units : []
  for (const u of units) {
    const list = Array.isArray(u.trays) ? u.trays : []
    for (const t of list) {
      const type = String(t.type || '')
      if (!type || type === 'Empty') continue
      trays.push({
        index: trays.length + 1,
        type,
        color: toCssColor(t.color),
        remain: num(t.remain, -1)
      })
    }
  }
  // 外挂料盘（vt_tray）
  if (am.vtTray && am.vtTray.type && am.vtTray.type !== 'Empty') {
    trays.push({
      index: trays.length + 1,
      type: String(am.vtTray.type),
      color: toCssColor(am.vtTray.color),
      remain: num(am.vtTray.remain, -1)
    })
  }

  // 机型串：设备名/型号 + 喷嘴直径 + 喷嘴类型
  const modelBits = []
  if (dev.name || dev.model) modelBits.push(String(dev.name || dev.model))
  if (st.model && st.model.nozzleDiameter) modelBits.push(`${st.model.nozzleDiameter}mm`)
  if (st.model && st.model.nozzleType) modelBits.push(String(st.model.nozzleType))

  const hms = Array.isArray(er.hms) ? er.hms.slice(0, 8) : []

  return {
    state: String(st.state || 'UNKNOWN'),
    stateLabel: String(st.stateLabel || ''),
    connected: st.connected === true,
    online: st.online === true,
    jobName: st.jobName ? String(st.jobName) : '',
    percent: num(pr.percent, -1),
    layer: num(pr.layer, -1),
    totalLayer: num(pr.totalLayer, -1),
    remainingSec: num(pr.remainingSec, -1),
    elapsedSec: num(pr.elapsedSec, -1),
    nozzleTemp: num(te.nozzle, -1),
    nozzleTarget: num(te.nozzleTarget, -1),
    bedTemp: num(te.bed, -1),
    bedTarget: num(te.bedTarget, -1),
    chamberTemp: num(te.chamber, -1),
    printError: num(er.printError, 0),
    hms,
    trays,
    trayNow: num(am.trayNow, -1),
    model: modelBits.join(' ')
  }
}

/** 离线占位（连续失败后上报，让屏上明确显示"离线"而不是停在旧数据） */
function offlineState() {
  return {
    state: 'OFFLINE',
    stateLabel: '离线',
    connected: false,
    online: false,
    jobName: '',
    percent: -1,
    layer: -1,
    totalLayer: -1,
    remainingSec: -1,
    elapsedSec: -1,
    nozzleTemp: -1,
    nozzleTarget: -1,
    bedTemp: -1,
    bedTarget: -1,
    chamberTemp: -1,
    printError: 0,
    hms: [],
    trays: [],
    trayNow: -1,
    model: ''
  }
}

export class PrinterWatcher {
  constructor(intervalMs) {
    this.url = printerUrl()
    this.intervalMs = intervalMs || 5000
    this.lastAt = 0
    this.fails = 0
    this.state = null
  }

  /** 到点了就拉一次；返回当前状态（可能是缓存的） */
  async poll(nowMs) {
    if (!this.url) return this.state
    if (this.state && nowMs - this.lastAt < this.intervalMs) return this.state
    this.lastAt = nowMs
    try {
      const ctrl = new AbortController()
      const timer = setTimeout(() => ctrl.abort(), 4000)
      const res = await fetch(this.url, { signal: ctrl.signal })
      clearTimeout(timer)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const api = await res.json()
      this.state = mapBambuState(api)
      this.fails = 0
    } catch (e) {
      this.fails++
      if (this.fails >= MAX_FAILS) {
        this.state = offlineState()
      }
    }
    return this.state
  }
}
