/**
 * Types.ets — 遥测数据模型（由 shell 侧数据桥通过 UDP JSON 推送）
 */

export interface TodoItem {
  content?: string;
  status?: string; // pending | in_progress | completed
}

export interface SystemInfo {
  cpu?: number;          // 0..100
  cores?: number;
  memUsed?: number;      // MB
  memTotal?: number;     // MB
  load1?: number;
  load5?: number;
  load15?: number;
  uptimeSec?: number;
  host?: string;
  cpuTemp?: number;
  /** 电量百分比 0..100（-1 = 无电池/取不到）。桥端数据里通常没有，本机采集会给 */
  battery?: number;
  /** 是否在充电（本机采集给） */
  charging?: boolean;
}

export interface TokenInfo {
  todayInput?: number;
  todayOutput?: number;
  todayTotal?: number;
  sessionTotal?: number;
  contextUsed?: number;
  contextWindow?: number;
  costUsd?: number;
  cacheHitRate?: number;
}

export interface AgentInfo {
  state?: string;        // idle | busy | waiting | unknown
  activity?: string;     // Thinking… / Running bash…
  tool?: string;
  lastText?: string;
  turn?: number;
  step?: number;
  project?: string;
  sessionId?: string;
  model?: string;
  provider?: string;
  /** 本轮错误文本（turn/end 的 reason.kind 非 completed 时才有）；空串=正常 */
  errorText?: string;
}

export interface WeatherInfo {
  text?: string;
  tempC?: number;
}

export interface LyricsInfo {
  line?: string;
  artist?: string;
  title?: string;
}

/** 一盒耗材（AMS 托盘或外挂料盘） */
export interface PrinterTray {
  /** 托盘序号（1 起） */
  index?: number;
  /** 材料类型，如 PLA / PETG / ABS / Empty */
  type?: string;
  /** 颜色 #RRGGBB（拓竹给的是 8 位带 alpha，取前 6 位） */
  color?: string;
  /** 剩余百分比 0..100 */
  remain?: number;
}

/** 打印机（拓竹）状态，由桥端从 bambu-monitor 的 /api/state 取来 */
/**
 * DeepSeek 账户余额（桥端查 /user/balance 得到）。
 * 数字在 JSON 里是字符串（如 "49.47"），归一化时统一转成 number；取不到就是 -1。
 */
/** 一句话摘要：text=摘要内容 error=取数失败原因 at=生成时间 */
export interface SummaryInfo {
  text?: string;
  error?: string;
  at?: number;
}

/** 依赖健康：桥端报自己能看到的部分，应用侧再合并 USB / livepad */
export interface HealthInfo {
  bridge?: boolean;
  printer?: boolean;
  printerState?: string;
  weather?: boolean;
  summary?: boolean;
  tokensPerMin?: number;
}

/** 桥端事件流的一条：t=时间 k=类型(idle|busy|tool|todo|print|err|info) s=文本 */
export interface BridgeEvent {
  t?: string;
  k?: string;
  s?: string;
}

export interface BalanceInfo {
  currency?: string;      // CNY / USD
  total?: number;         // 总余额
  granted?: number;       // 赠送余额
  toppedUp?: number;      // 充值余额
  available?: boolean;    // 账户是否可用
  /** 桥端取数失败时的原因（空串=正常） */
  error?: string;
  /** 每小时烧多少钱（需要 >=5 分钟的采样跨度，否则 -1） */
  perHour?: number;
  /** 按当前速率还能用多少小时（-1 = 算不出来） */
  etaHours?: number;
  /** 速率所依据的采样跨度（分钟） */
  spanMin?: number;
}

export interface PrinterInfo {
  /** 监控服务状态：'' = 正常；'error' = 连不上云端（凭据问题） */
  monitorMode?: string;
  /** 监控服务报的原始错误（用于屏上给出一句人话提示） */
  monitorError?: string;
  /** IDLE/PREPARE/RUNNING/PAUSE/FINISH/FAILED/STUCK/OFFLINE/UNKNOWN */
  state?: string;
  /** 中文状态（桥端给，缺了则按 state 推） */
  stateLabel?: string;
  /** MQTT 是否连上云端 */
  connected?: boolean;
  /** 打印机是否在线（收到过上报） */
  online?: boolean;
  /** 机型/喷嘴描述，如 "P2S 0.4mm 不锈钢" */
  model?: string;
  /** 正在打的文件名 */
  jobName?: string;
  /** 进度 0..100，-1 表示未知 */
  percent?: number;
  layer?: number;
  totalLayer?: number;
  /** 剩余/已用秒数，-1 表示未知 */
  remainingSec?: number;
  elapsedSec?: number;
  /** 预计完成时间 HH:MM */
  eta?: string;
  /** 温度（℃）；-1 表示该传感器没有 */
  nozzleTemp?: number;
  nozzleTarget?: number;
  bedTemp?: number;
  bedTarget?: number;
  chamberTemp?: number;
  wifi?: string;
  coolingFan?: number;
  heatbreakFan?: number;
  speedLevel?: number;
  /** 拓竹 print_error 码 */
  printError?: number;
  /** HMS 告警条数 */
  hmsCount?: number;
  /** 第一条 HMS 的短码，便于一眼看出问题 */
  hmsCode?: string;
  /** 当前进料的托盘序号（1 起，0 = 外挂） */
  trayNow?: number;
  /** 托盘（已过滤空位，最多 MAX_TRAYS 个） */
  trays?: PrinterTray[];
}

export interface Telemetry {
  ts?: number;
  agent?: AgentInfo;
  todos?: TodoItem[];
  tokens?: TokenInfo;
  system?: SystemInfo;
  weather?: WeatherInfo;
  lyrics?: LyricsInfo;
  /** 打印机状态（没有打印机/桥端没开这个功能时为空） */
  printer?: PrinterInfo;
  /** DeepSeek 账户余额（桥端开 --deepseek-balance 才有） */
  balance?: BalanceInfo;
  /** 事件流（最近若干条，给"诊断风"主题当实时日志） */
  events?: BridgeEvent[];
  /** LLM 一句话摘要（桥端开 --summary 才有） */
  summary?: SummaryInfo;
  /** 依赖健康（桥端能看到的那些；USB/livepad 由应用侧合并） */
  health?: HealthInfo;
}

export class TelemetryState {
  data: Telemetry = {};
  lastRxTs: number = 0;
  packets: number = 0;
  lastError: string = '';
  /**
   * 最近一个包的 `source` 标识（谁在供数）。
   *
   * ★ 为什么需要：实测环境里**可能同时有两个源**在往 54545 推
   *   （外部 node 桥 = 1 个，进程内 DSH 插件 = 1 个），
   *   而 App 侧原来无从分辨 —— 排障时"遥测在推"却说不清是谁推的。
   *   载荷里带 source 的源会写在这里（如 `dsh-plugin`）。
   */
  lastSource: string = '';

  get fresh(): boolean {
    return (Date.now() - this.lastRxTs) < 10000;
  }

  ageSec(): number {
    if (this.lastRxTs === 0) {
      return -1;
    }
    return Math.floor((Date.now() - this.lastRxTs) / 1000);
  }
}
