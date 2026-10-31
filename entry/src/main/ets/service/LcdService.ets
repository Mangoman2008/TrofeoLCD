/**
 * LcdService.ets — 帧循环：渲染 -> JPEG -> LY 分块 -> USB 推帧
 *
 * 关键设计：
 * 1) 画布尺寸自校正：先按猜测的 vp 尺寸画一帧，用 JPEG 头里的真实像素宽高反推
 *    设备密度，再修正画布 vp 尺寸，直到输出正好是设备要求的分辨率（9.16 为 1920x462）。
 *    这样完全不依赖 display.densityPixels 的准确性。
 * 2) 前几帧只用于校准，不推给屏幕，避免推送错误尺寸的帧。
 * 3) 自适应帧率：agent 忙碌/等待时 15fps（呼吸动画），空闲时 2fps（省电）。
 */
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { LyProtocol, parseJpegSize, JpegInfo, DeviceInfo } from '../usb/LyProtocol';
import { LcdUsb } from '../usb/LcdUsb';
import { usbManager, BusinessError } from '@kit.BasicServicesKit';
import { Dashboard, FrameStats } from '../render/Dashboard';
import { Chrome } from '../render/Chrome';
import { ThemeDiag } from '../render/ThemeDiag';
import { ThemeWall } from '../render/ThemeWall';
import { ThemePages } from '../render/ThemePages';
import { ThemePong, PongState, pongInit, pongAdvance } from '../render/ThemePong';
import { ThemeDotii, DotiiState, DOTII_PAGES, DOTII_SNAKE_PAGE, randomExpr } from '../render/ThemeDotii';
import { Overlay } from '../render/Overlay';
import { ThemeSnake, SnakeState } from '../render/ThemeSnake';
import { MarioDemo } from '../mario/MarioDemo';
import { WeatherService } from './WeatherService';
import { ThemeWeather } from '../render/ThemeWeather';
import { ThemeFwSim, FwSimState, FW_SCREEN_COUNT, FW_ROTATION } from '../render/ThemeFwSim';
import { ThemeTrcc, TrccState, TRCC_THEME_COUNT } from '../render/ThemeTRCC';
import { ThemeMac } from '../render/ThemeMac';
import { ThemeAnime } from '../render/ThemeAnime';
import { ThemeAnimeBG } from '../render/ThemeAnimeBG';
import { ThemeAnimeFree } from '../render/ThemeAnimeFree';
import { ThemeAnimeHUD } from '../render/ThemeAnimeHUD';
import { ThemeNanoMuse } from '../render/ThemeNanoMuse';
import { ThemeTrofeoRust } from '../render/ThemeTrofeoRust';
import { Backdrop, BgStyle, bgStyleFromName } from '../render/Backdrop';
import { ThemeDotiiCell, DotiiCellInfo } from '../render/ThemeDotiiCell';
import { History } from '../common/History';
import { ToastPolicy, FocusTimer, Toast } from '../common/Toasts';
import { RenderExtras } from '../common/Extras';
import { TelemetryBridge } from '../bridge/TelemetryBridge';
import { FrameServer } from '../bridge/FrameServer';
import { jsonStr, jsonBool, jsonNum } from '../common/Json';
import { http, connection } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { resourceManager } from '@kit.LocalizationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common } from '@kit.AbilityKit';
import { Telemetry, BridgeEvent, PrinterInfo, PrinterTray, BalanceInfo } from '../common/Types';
import { SelfTest, TestItem } from '../usb/SelfTest';
import { CalibState, CalibStep, calibrate, nextQuality } from './CanvasCalib';
import { RuntimeCheck, RuntimeSnapshot } from './RuntimeCheck';
import { HostStats } from './HostStats';
import { RunningLock } from './RunningLock';
import { fileIo } from '@kit.CoreFileKit';
import { SeqState, SeqManifest, parseSeqManifest, seqIntervalMs, nextSeqCursor,
  seqFrameUrl, seqFetchCount, seqSelfTest, SEQ_DEFAULT_LIMIT,
  seqBufCap, seqBufSlot, seqCanFetch, seqShouldStop, seqBufFill, seqNeedsPump,
  seqPlayInterval,
  SEQ_DEFAULT_WIN, SEQ_MIN_WIN, SEQ_MAX_WIN } from './SeqPlayback';
import { LocalSys } from './LocalSys';
import { pickSystem } from '../common/SystemMerge';
import { FrameTickInput, NightWindow, UsbAttemptState, UsbAttemptDecision,
  nextFrameInterval, shouldAttemptUsbOpen, noteOpenFailure, noteOpenSuccess,
  armManualRetry } from './SchedulePolicy';
import { Logger } from '../common/Logger';
import EntryAbility from '../entryability/EntryAbility';

/** 指数滑动平均，让耗时读数稳定可读 */
function ema(prev: number, cur: number): number {
  return prev <= 0 ? cur : prev * 0.7 + cur * 0.3;
}

/** VM 监视画面来源（livepad 的取帧接口） */
/**
 * VM 监视地址。默认本机（livepad 通常就跑在这台设备上），
 * 但**允许运行时改**：换了环境（livepad 挪到 PC、改了端口）时不用重编译，
 * 走 /set?vmurl=... 或界面上的输入框即可。Windows 版同一套思路（多候选 + 自动探测）。
 */
/**
 * VM 监视画面的默认地址。
 *
 * ★ 原值是 `http://127.0.0.1:8787/vm/frame.jpg` —— 实测**该路由不存在**：
 *   数据桥只提供 `/bg`（背景图）一个 HTTP 路由，`/vm/...` 会稳定返回 404，
 *   面板上那一格就长期显示"等待 VM 画面 / HTTP 404"。
 *   所以默认留空（显示"未接入"更诚实）；要用的时候由界面填真实地址。
 */
const VM_FRAME_URL_DEFAULT: string = '';
/** VM 帧抓取间隔（VM 侧约 1 帧/秒，抓太勤只是浪费解码） */
const VM_INTERVAL_MS: number = 1000;

const TARGET_W: number = 1920;
/** 帧高：9.16 是 462（依据：官方 TRCC 型号表 + trofeo-lcd-rs 的默认面板） */
const LY_FRAME_H: number = 462;
const LY_FRAME_W: number = 1920;
const TARGET_H: number = 462;   // 9.16 的帧高（见 Theme.L.height 的一手证据）
const MIN_QUALITY: number = 0.4;
/**
 * 是否用"canvas → PixelMap → 原生打包"的快路径编码。
 * 实测本机 getPixelMap 取到的区域不对（15401x3849），已完成回退与护栏但仍默认关闭：
 * 编码耗时不是当前主要瓶颈（推送更贵），先保证画面正确。
 */
// 2026-10-21 复测：打开快路径后编码 93ms（toDataURL 是 75ms）→ 更慢，维持关闭。
// 编码不是瓶颈，真实的 CPU 差异来自**推帧频率**（见 SchedulePolicy 的主题下限）。
const FAST_ENCODE: boolean = false;

function ThemeMacTick(theme: number): number {
  // 主题 8 的时钟带秒 → 签名要带秒，否则秒不动（签名没变就跳过重推）
  return theme === 8 ? new Date().getSeconds() : 0;
}

function ThemeTrccFreq(): number {
  // HarmonyOS 侧没有直接的 CPU 频率接口；返回 -1 让屏上显示 "--"（不编数据）
  return -1;
}

function ThemeDotiiPad(n: number): string {
  return (n < 10 ? '0' : '') + n;
}

export class LcdService {
  private ctx: CanvasRenderingContext2D;
  private usb: LcdUsb = new LcdUsb();
  private bridge: TelemetryBridge = new TelemetryBridge();

  /**
   * key 递送回调：载荷里带了 deepseekKey 就接住（落进 this.deepseekKey）。
   * 为什么挂在这里而不是 start() 里：字段初始化时就挂好，
   * 保证第一包就能接住（start() 之前的包也不丢）。
   */
  private onBridgeReady(): void {
    this.bridge.OnKey = (o: Record<string, Object>) => {
      this.adoptKey(o);
    };
  }
  /** 把当前帧通过 localhost 暴露出来，便于外部验证（本沙箱读不到 hilog） */
  private frameServer: FrameServer = new FrameServer();
  readonly stats: FrameStats = new FrameStats();

  private running: boolean = false;

  /**
   * 是否处于后台（由 EntryAbility.onBackground/onForeground 维护）。
   * ★ 为什么需要它：HarmonyOS 的 continuous task 有一条规则——
   *   `DATA_TRANSFER` 类型的任务**若数据传输速率低，会被系统挂起/取消**
   *   （SDK 文档：SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED = 4）。
   *   而本应用"内容签名未变就跳帧"，屏上静止时 3 秒才推一帧 → 速率极低
   *   → 很容易被判定为低速。后台期间**关闭跳帧**可稳定维持传输速率。
   *   代价：后台时 USB/CPU 占用略高；但屏是状态副屏，宁可多推也别停更。
   */
  private backgrounded: boolean = false;
  private timerId: number = -1;
  private b64: util.Base64Helper = new util.Base64Helper();
  /** 屏幕密度：画布 vp → 像素（getPixelMap 用像素坐标；只在首帧兜底用） */
  private density: number = 1;
  /**
   * 看门狗：最近一次"推帧成功"的时间。
   * 真机上出现过"USB 还开着、但推帧悄悄不再前进"的情况（用户说的"容易断掉"），
   * 只靠 sendJpeg 的返回值发现不了 —— 超时没成功就主动断开重连。
   */
  private lastOkPushMs: number = 0;
  /**
   * 错误蓝屏（彩蛋）：agent 本轮出错时盖一块 Win95 蓝屏。
   * errShown 记录"已弹过的错误文本"，同一错误不重复弹；错误清空后复位。
   */
  /**
   * 主题 16「自走贪吃蛇」的全屏棋盘状态。
   * 与打印机格的 Dashboard.cellSnake 是**两个独立实例**（不同棋盘尺寸）。
   */
  private snakeFull: SnakeState | null = null;

  private bsodText: string = '';
  private bsodUntil: number = 0;
  /** 蓝屏显示时长 */
  private static readonly BSOD_MS: number = 6000;

  /**
   * 全宽跑马灯（/set?ticker=1 开启）。
   * 1920×462 是 4.16:1 的极宽比例，跑马灯正好吃满宽度。
   */
  private tickerOn: boolean = false;
  /** 一天时间轴（/set?timeline=1 开启）：1440 格 = 每分钟一格 */
  private timelineOn: boolean = false;
  /** 当天每分钟的忙碌标记：0=空闲 1=忙碌（跨天自动清空） */
  private dayAct: number[] = [];
  /** dayAct 对应的“第几天”，跨天时重置 */
  private dayKey: string = '';

  /**
   * 伪频谱瀑布（/set?spec=1）：不解码音频，用 token 速率/CPU 当驱动。
   * 96 根柱子，最新在最右，每帧左移一格。
   */
  private specOn: boolean = false;
  private specBuf: number[] = [];
  /** 上一帧推入瀑布的时间（节流到 ~8Hz，肉眼够顺且省 CPU） */
  private specAt: number = 0;
  /** 复古掌机滤镜（/set?retro=1）：扫描线 + 淡绿染色 */
  private retroOn: boolean = false;
  /**
   * 整点彩虹跑马灯（/set?hourbell=0 可关，默认开）。
   * 每到整点后 HOUR_BELL_MS 内，底部盖一条彩虹色滚动条庆祝"整点"。
   */
  private hourBellOn: boolean = true;
  /**
   * 彩虹带宽度（像素）。/set?ringband=N 可调。
   * 历程：初版 34 → 用户要"粗一倍"改成 68 → 反馈"太粗了"改回 **34**。
   */
  private ringBand: number = 34;
  /** 调试：强制彩条显示到某个时刻（/set?hbtest=N 秒），0 = 不用强制的 */
  private hourBellForceUntil: number = 0;
  /** 整点彩条显示时长（毫秒） */
  private static readonly HOUR_BELL_MS: number = 30000;
  private static readonly STALL_MS: number = 12000;
  /**
   * 是否有一次 sendJpeg 正在途中。
   *
   * ★ 2026-10-15（代码审查【高危-3】）：看门狗原来只看"距上次成功推帧多久"，
   *   **不看有没有在途传输**。而一帧要 11~25 次 bulkTransfer、每次超时 5s，
   *   端点进错误态时单帧可从 ~55ms 涨到秒级 → 12s 的阈值会被触发，
   *   `close()` 把 pipe/iface/outEp 全置 null，**正在途中的那一帧就写进了已关闭的 pipe**。
   *   更糟的是它"成功"返回后会 `recordPushResult(true)` 把看门狗重新喂饱 ——
   *   这正是"sent 在涨、屏没画面、usbOpenCount 恒为 1"这种最难查故障的成因。
   */
  private pushInFlight: boolean = false;
  /** 上一帧的内容签名；相同就跳过"渲染+编码+推送"（省 ~160ms/帧） */
  private lastSig: string = '';
  private lastPushMs: number = 0;
  private skipped: number = 0;
  /** 诊断：帧循环回调次数 */
  private tickCount: number = 0;
  private lastTickLogMs: number = 0;
      private lastSkipLogMs: number = 0;
  /** 即使内容没变，也要每隔这么久补推一帧（防止面板丢帧/息屏） */
  private static readonly HEARTBEAT_MS: number = 10000;
  /**
   * 推帧间隔下限（ms）。一帧的真实成本 = render 2 + encode 50 + push 55 ≈ 110ms，
   * 间隔小于它不会提升帧率，只会把 USB 端点灌爆（实测：端点错误态、屏黑）。
   * 120ms ≈ 8fps，就是这块屏+这条链路的实测天花板。
   */
  private static readonly MIN_PUSH_INTERVAL_MS: number = 120;
  /**
   * 推帧流水线：true 时把"编码 + USB 推送"从帧循环的关键路径上摘下来 ——
   * 本帧渲染完立刻异步发出去，不等它完成就返回，于是下一帧的渲染/编码与上一帧的
   * USB 传输**重叠**。实测每帧 render 2 + encode 50 + push 55 ≈ 110ms 是串行的，
   * 重叠后理论上限从 encode+push 变成 max(encode, push) ≈ 55ms（≈18fps）。
   * 代价：延迟增加约一帧；背压靠"上一帧还在推就跳过本帧"实现（丢帧不排队）。
   */
  /**
   * ★ 跨帧流水线默认关闭。
   *
   * 它本身是安全的（只是不等推送完成就返回），但**必须先把屏内固件从错误态救回来**再开，
   * 否则"上一帧还没推完就叠下一帧"会加重固件的队列压力（固件在解码期间静默丢帧，
   * 见 trcc-linux issue #251）。等屏恢复正常、且 writeBatch=1 的前提下，再 /set?pipe=1 试。
   */
  pipelinePush: boolean = false;
  /**
   * 右下角漏光补偿强度 0..1（0 = 关）。运行时 /set?vig=0..100。
   * 这块屏右下角漏光明显，用径向渐变压暗那一角，把不均匀藏在暗处。
   */
  vignette: number = 0.25;   // 漏光补偿默认轻档；0 = 关（/set?vig=N）
  /** 漏光补偿的衰减半径（px），/set?vigreach=N 可调 */
  vignetteReach: number = 620;
  /** true = 主题 4/5 也在 LcdService 这一层再补一次（只画一遍，不叠加） */
  vigAll: boolean = false;
  /** 强制指定补偿角（缓冲区坐标），-1 = 自动。仅供实测映射用 */
  vigCornerForce: number = -1;

  /**
   * 漏光补偿该压"缓冲区里的哪个角"。
   *
   * 实测结论：物理屏的右下角漏光；本机型 rotate180=true，整帧推之前做了 180° 旋转，
   * 所以缓冲区里要对角压 —— 即**左上角（0）**。之前没考虑旋转，结果压到了物理左上角
   * （实测左上 -13.9、右下 0.0，正好压反）。旋转关掉时则压缓冲区的右下角（3）。
   */
  private vigCorner(): number {
    // vigcorner 可强制指定（0=左上 1=右上 2=左下 3=右下，指**缓冲区**里的角），
    // 用来实测"缓冲区角 → 物理角"的映射；-1 = 自动按旋转推断。
    if (this.vigCornerForce >= 0) {
      return this.vigCornerForce;
    }
    return this.rotateNow() ? 1 : 3;
  }
  private pushBusy: boolean = false;
  private pushSkip: number = 0;
  /** 计时探针：一轮 tick 自身耗时 / 两轮之间的间隔（定位"帧率上不去"到底卡在哪） */
  private lastTickStartMs: number = 0;
  /** JPEG 编码质量（可调：/set?q=0.8）。真机上 0.9 的 117KB 帧编码 ~70ms、推送 ~120ms，
   *  质量降一点能同时省下编码与推送两头的耗时（650KB 的上限远没用满）*/
  encodeQuality: number = 0.85;

  // ===================== 预烘焙 JPEG 序列播放（零编码直推） =====================
  /**
   * 视频离线烘成 JPEG 帧序列后，运行时**不再渲染、不再编码**，只把字节原样推给屏。
   * 依据：本机实测编码 ~55ms/帧、每次 4096B bulkTransfer ~5.5ms 固定开销，
   * 所以省掉编码能把天花板从 ~6fps 抬到 ~8..16fps（见
   * .verify/video-seq/报告-预烘焙序列验证.md）。纯策略在 service/SeqPlayback.ets。
   *
   *   /set?seq=http://127.0.0.1:8899/seq   开始播放（先取 manifest.json 再拉帧）
   *   /set?seqfps=12                       覆盖清单里的帧率
   *   /set?seqlimit=120                    最多拉多少帧（内存上限 480）
   *   /set?seq=off                         停止并释放
   */
  private seq: SeqState | null = null;
  /** 播放期间实测帧率（3s 滑动窗口，与 stats.fps 同法） */
  private seqFps: number = 0;
  private seqTimes: number[] = [];
  /** 序列推帧耗时 EMA（ms） */
  private seqPushMs: number = 0;
  /** /set?seqfps=N（0 = 用清单帧率） */
  private seqFpsOverride: number = 0;
  /** /set?seqlimit=N（0 = 用默认 SEQ_DEFAULT_LIMIT） */
  private seqLimitOverride: number = 0;
  /** /set?seqstream=1 → 边播边拉（只把 win 帧放进内存）；默认 0 = 一次全拉 */
  private seqStream: boolean = false;
  /** /set?seqwin=N → 流式预取窗口（帧）；0 = 用 SEQ_DEFAULT_WIN */
  private seqWin: number = 0;
  /** /set?seqburst=1 → 极速：帧间隔压到 1ms，明确"USB 有多快推多快"（默认按帧率节流） */
  private seqBurst: boolean = false;
  /** 打砖块显示期间被顶掉的 forceIntervalMs 原值（-1 = 没顶过） */
  private pongSavedForceInterval: number = -1;
  /** 打砖块的目标帧间隔（≈15fps）：物理 20ms/步，66ms 一帧约 3 步，速度正确 */
  private static readonly PONG_FPS_MS: number = 66;

  /** 播放期间被顶掉的 forceIntervalMs 原值（-1 = 没顶过） */
  private seqSavedForceInterval: number = -1;

  // 画布 vp 尺寸（由 UI 绑定）
  canvasVpW: number = 1280;
  canvasVpH: number = 320;
  private scaleX: number = 1;
  private scaleY: number = 1;

  /** 竖装模式：逻辑空间 462×1920，绘制时整体旋转 90° */
  verticalMode: boolean = false;
  /** VM 监视地址（可运行时改；见 this.vmUrl_DEFAULT 的说明） */
  /** 本机系统采集（桥端遥测不新鲜时兜底；见 LocalSys.ets） */
  private localSys: LocalSys = new LocalSys();
  vmUrl: string = VM_FRAME_URL_DEFAULT;
  /** 画面 180° 旋转（LY FBL192 面板默认需要；真机上可切换） */
  /**
   * 是否把整帧旋转 180°。
   * 默认 false —— 同型号开源驱动在真机上验证过"按握手自动旋转"的启发式不可靠
   * （PM=65/SUB=3 的机器开了反而倒），所以改成纯手动开关。
   */
  /**
   * 旋转模式：0 = 跟随设备握手（默认） / 1 = 强制旋转 180° / 2 = 强制不旋转。
   *
   * 为什么不再写死 false：真机（Trofeo Vision 9.16，PM=65 SUB=5）实测**必须**旋转 180°
   * 画面才是正的（用户实测反馈）。之前照抄"某开源驱动把该字段固定为 false"就默认不转，
   * 结果默认值本身就是错的、得手动打开才对。现在默认跟随握手。
   * 界面上的开关仍然可以强制覆盖（会切到 1/2 并落盘）。
   */
  rotMode: number = 0;
  /**
   * 主题：0 = 仪表盘（默认，信息密度高）· 1 = 诊断终端（DiPlay/CarPlay 诊断仪的"证据流"风格）
   * · 2 = 监控墙（CPU/内存/token/余额曲线 + 还能用多久 + 健康灯 + 专注计时）
   * · 3 = 分页屏 · 4 = 打砖块（源固件 clock_pong 的 1:1 复刻，整屏居中，见 ThemePong.ets）。
   * 主题决定的不只是配色，还有"看什么"—— 所以放在渲染分发这一层。
   */
  theme: number = 0;
  /** 边框扫掠开关（默认开；只作用于天气主题，sweepForce 时对所有主题生效） */
  sweepOn: boolean = true;
  sweepForce: boolean = false;
  /** 扫掠一圈的时长（ms）。12 秒 = 用户拍板的速度；/set?slap=N 可调 */
  sweepLapMs: number = 12000;
  /** 扫掠线宽（px）；/set?sthk=N 可调 */
  sweepThick: number = 7;
  /** 主题 18「天气」的数据源（Open-Meteo，15 分钟刷新，异步不阻塞帧循环） */
  wx: WeatherService = new WeatherService();
  /** 主题 3 是分页屏：当前页 0..3（打印机/余额/DSH/系统） */
  page: number = 0;
  /**
   * 主题 4「打砖块」的游戏状态（源 clock_pong 的移植：砖块/球/挡板/确定性随机）。
   * 每帧按真实经过时间推进（pongAdvance），所以动画速度与帧率无关；
   * 切走主题再切回来会重新开一局（pongLastMs 归零触发）。见 ThemePong.ets。
   */
  private pongState: PongState | null = null;
  private pongLastMs: number = 0;
  /**
   * 强制推帧间隔（ms）。0 = 按策略走（idle 500 / busy 66 / 夜间 3000）。
   * >0 时覆盖策略 —— 用于实测"这块屏最高能推多少帧"，以及给游戏类主题拉高帧率。
   * 运行时：/set?fps=30 → 33ms；/set?fps=0 → 回到策略。
   */
  forceIntervalMs: number = 0;
  /**
   * 极速模式（`/set?burst=1`）：把帧间隔改成"**减去本帧耗时**"。
   *
   * ★ 起因（实测）：帧循环是 `tick → 推帧 → setTimeout(间隔) → tick`，
   *   间隔是**加在推帧耗时之外**的。fps=8（间隔 125ms）时实测每帧
   *   `render 5 + encode 71 + push 66 + 间隔 125 = 267ms` → 只有 3.7fps，
   *   而字节数换算出的上限是 **18fps** —— 也就是说大量时间白等。
   *   序列那边用 `seqburst` 解决同一个问题（间隔压到 1ms），这里给主题做同样的加速，
   *   但用"减去耗时"而不是"压到 1ms"，避免把 USB 端点灌到错误态
   *   （历史上灌爆过一次：bulkTransfer 返回 -1、屏黑、/diag 都不响应）。
   */
  burst: boolean = false;
  /** 本帧开始时刻（用于极速模式扣除耗时） */
  private tickStartMs: number = 0;
  /**
   * 推帧高度的运行时覆盖（0 = 用设备握手报的高度）。
   *
   * 起因：面板官方规格是 **1920×480**，而设备握手报 462。按 trcc-linux issue #248 的测量，
   * 固件内部帧缓冲是 480 行、玻璃约 468 行 —— 推 462 会触发 **462→480→468 的双重缩放**
   * （画质变糊），推 480 只缩放一次。本项目一直用 462（厂商反编译与 haven80 驱动也都写 462），
   * 所以做成运行时可切换，用**实测锐度**定：
   *   /set?frh=480  → 按 480 推（少一次缩放）
   *   /set?frh=0    → 回到设备握手值（462）
   * 改完会重建校准状态，画布尺寸会自动收敛到新目标。
   */
  frameHeightOverride: number = 0;
  /**
   * 本帧内容签名（**待提交**）。
   *
   * ★ 修的是"签名先于推送提交"这个 bug：原来 tick() 在推送**之前**就写 lastSig，
   *   于是一旦推送失败（sendJpeg 返回 false）或被流水线背压丢掉，该内容就被记成
   *   "已推过" → 最长 10 秒（HEARTBEAT_MS）不会再推：屏上留旧画面，而且
   *   **瞬时告警帧（toast / 监控未登录 / 余额不足）永远不显示**。
   * 现在只有 recordPushResult(true) 才把 pendingSig 提交进 lastSig；失败则清空 lastSig
   * 让下一轮无条件重推。
   */
  private pendingSig: string = '';
  /**
   * 主题 5「Dotii 分页屏」：状态（当前页/表情/数据快照）。
   * 源固件（ESP32-S3 LVGL）是 368×448 竖屏那套 UI，这里按 ×0.9333 等比画进
   * 与打砖块同一块区域（343×418，屏幕居中）。页数 4：表情/余额/打印机/自定义。
   */
  private dotiiState: DotiiState = new DotiiState();
  /** Dotii 页自动翻页的节拍（10 秒），与主题 3 的分页屏同一节奏 */
  private dotiiPageMs: number = 10000;
  /**
   * Dotii「贪吃蛇」页的单独保留时长（用户 2026-10-21 要求 **60 秒**）。
   * 其余页仍是 dotiiPageMs（10 秒）—— 蛇要跑起来才看得出在玩，
   * 60 秒大概能吃到 10~20 个。用 /set?dspage=N 调（毫秒）。
   */
  private dotiiSnakePageMs: number = 60000;
  private dotiiPageAt: number = 0;
  private dotiiExprAt: number = 0;
  /**
   * 主题 6「固件仿真屏」：把 ESP32-S3 固件那套 UI 搬过来仿真显示。
   * 界面切换用 /set?fws=N（0..17，对应 display_ui.h 的 enum ScreenOrder），
   * fws=-1 或 /set?fwsauto=1 时按 12 秒自动轮播全部界面。
   */
  private fwState: FwSimState = new FwSimState();
  fwAuto: boolean = true;
  private fwAutoAt: number = 0;
  /**
   * 主题 7「官方浅色风」：TRCC 官方 1920×462 主题的复刻（素材已解包落盘）。
   * /set?trcc=N 切配色（0..4），N 省略或 -1 时 30 秒自动轮换。
   */
  private trccState: TrccState = new TrccState();
  private trccAutoAt: number = 0;
  /**
   * 主题 7 用的官方底图（packing 在 resources/rawfile/trcc/official_N.png）。
   * 这批图是 TRCC 官方 1920×462 主题包里的**无文字干净底图**（动画帧 00.png），
   * 官方带示例文字的预览图是 Theme.png（不用它，否则示例数字会和我们叠的数字打架）。
   * 素材出处与解包方法见 docs/官方主题包分析.md。
   */
  private trccBg: (image.PixelMap | null)[] = [null, null, null, null, null];
  private trccBgLoading: boolean = false;
  /** 主题 9「打印机位 Dotii」：把 Dotii 内容搬到打印机格，缺口从 DSH 会话格挪 */
  private dotiiCellInfo: DotiiCellInfo = new DotiiCellInfo();
  /**
   * 第一屏（主题 0）的打印机格显示什么：
   *   'printer' = 真打印机卡（默认，原有行为）
   *   'dotii'   = 画 Dotii（用户 2026-10-14 选定的方案 A：合并进第一屏、且**保留**打印机卡随时可切回）
   * 切换：界面按钮 或 `/set?printerCell=dotii` / `/set?printerCell=printer`
   */
  /** 'printer'=标准档 | 'dotii'=对调档(VM 第四格/Dotii 第五格) | 'v4'=13:29 版(Dotii 第四格+USAGE 右移) */
  /**
   * 第一屏打印机格的版式。**默认 v6**（用户 2026-10-14 定稿"就这个定格吧"）：
   *   v6     = 最终版：DSH 缩小 / USAGE 尺寸不变 / **VM 保持原大小贴着 Dotii 左边** / Dotii 在最右
   *   v4     = Dotii 在第四格、VM 在最右
   *   printer= 标准：打印机卡 + VM
   *   dotii  = VM 在第四格（旧版，已移出按钮循环，仅 /set 可进）
   */
  printerCell: string = 'v6';
  /**
   * 运行时是否已显式设置过 printerCell。
   * 用途：界面侧在服务启动后有"应用一次偏好"的逻辑，它会覆盖运行时设置 ——
   * 加了这条标记后，**命令行/界面显式设过的值优先**，偏好不再抢（实测踩过：
   * 设 v4 后 3 秒被偏好里的 dotii 覆盖回去）。
   */
  printerCellTouched: boolean = false;
  /**
   * 主题是否被**运行时显式设置**过（`/set?theme=N` 或界面点按钮）。
   *
   * ★ 起因（实测）：我 `set?theme=15` 后，屏上先画出主题 15，但很快被**旧偏好 theme=11
   *   覆盖回去** —— 因为启动流程里"应用偏好"那步会用存档值覆盖运行时设置。
   *   这和之前 `printerCell` 存不住是同一类 bug，用同样的守卫解决。
   */
  themeTouched: boolean = false;

  /** 打印机格三态的循环顺序：标准 → 对调(VM 第四格/Dotii 第五格) → 13:29 版 → 标准 */
  nextPrinterCell(): string {
    // 循环：标准 → v4(Dotii左) → v6(最终版) → 标准
    // ★ 已按用户要求剔除 `dotii` 档（VM 被压到 250×167 的那版，用户明确说不需要）。
    //   该档仍可用命令 `/set?printerCell=dotii` 进入，只是不在按钮循环里。
    return this.printerCell === 'printer' ? 'v4'
      : (this.printerCell === 'v4' ? 'v6' : 'printer');
  }

  /** 给界面用的可读名称（按钮文字） */
  printerCellLabel(): string {
    return this.printerCell === 'dotii' ? '打印机格: VM⇄Dotii'
      : (this.printerCell === 'v4' ? '打印机格: Dotii左'
        : (this.printerCell === 'v6' ? '打印机格: Dotii右·VM原大' : '打印机格: 打印机卡'));
  }

  /**
   * 切换第一屏打印机格的显示内容，并**立刻重画**（不等内容签名心跳，~10s）。
   *
   * ★ 2026-10-15 收敛为**唯一写入口**（代码审查【高危-4】）：
   *   原先两条路各写一次 —— 本方法设 `printerCellTouched = true`，而
   *   `/set?printerCell=` 直接 `this.printerCell = v` 不设 → 守卫（依赖 touched）失效，
   *   症状正是"设完几秒后又自己变回去"（多 Index 实例 / Canvas onReady 重入时必现）。
   *   现在 `/set` 也走本方法，touched 的赋值只有一个地方，结构上不可能再漏。
   *
   * @param byUser true = 用户主动（界面按钮 / /set）→ 置 touched 并允许同值重复调用
   */
  setPrinterCell(v: string, byUser: boolean = false): void {
    const nv = (v === 'dotii' || v === 'v4' || v === 'v6') ? v : 'printer';
    if (nv === this.printerCell && !byUser) {
      return;
    }
    // 用户主动设置时**即使值相同也要置 touched** —— 否则"界面选中的值恰好等于初值"
    // 这个常见情形下守卫永远不生效（原实现的早退就是漏这一点）。
    if (byUser) {
      this.printerCellTouched = true;
    }
    if (nv !== this.printerCell) {
      Logger.w(`[printerCell] ${this.printerCell} -> ${nv}  (调用方=${byUser ? '用户' : '系统'})`);
      this.printerCell = nv;
    }
    this.lastSig = '';
    Logger.i(`打印机格 = ${nv}（touched=${this.printerCellTouched}）`);
    this.onStatus();
  }

  /**
   * 主题切换的**唯一写入口**（代码审查【高危-5】）。
   *
   * 原先有 4 条写入口：`/set?theme=`（设 touched）、界面 `themeApply()`（不设）、
   * 轮播自增（不设）、夜间回落（不设）—— 其中界面那条会让"旧偏好覆盖用户选择"
   * 的历史 bug 以另一个入口复现。现在统一走这里。
   *
   * @param byUser true = 用户主动选中 → 置 touched（防止旧偏好回写），
   *               并且**重置轮播计时**（否则开着轮播时点按钮，最多 1 秒后又被切走）
   */
  setTheme(n: number, byUser: boolean = false): void {
    // ★ 上限跟着主题表走：加了主题 16（全屏贪吃蛇）之后这里必须同步，
    //   否则 /set?theme=16 会被静默改回 0（实测踩过）。
    const v = (n >= 0 && n <= 18) ? n : 0;
    if (byUser) {
      this.themeTouched = true;
      this.lastThemeSwitch = Date.now();   // 见上：防轮播立刻把用户的选择切走
    }
    if (v !== this.theme) {
      Logger.i(`主题 ${this.theme} -> ${v}（调用方=${byUser ? '用户' : '系统'}）`);
      this.theme = v;
      this.lastSig = '';                   // 强制重画，不等签名心跳
    }
  }

  /** 强制下一帧重画重推（内容签名清空）。界面切开关后立刻见效，不用等心跳。 */
  /**
   * 画面心跳间隔（毫秒）。**即使内容签名没变，也强制重推一帧**。
   *
   * 起因（用户 2026-10-14）："经常性画面丢失" —— 屏端固件偶尔会丢帧/自己重置，
   * 而应用侧因为"内容没变"就不重推，屏上就一直是空的或旧画面（实测排障时见过一次：
   * 应用侧 sent 正常增长，屏却没画面；`usbOpenCount` 恒为 1、无任何错误）。
   * 加了这个心跳后，屏最多 N 秒内就会被重新喂一帧，能自愈。
   * 代价：每 N 秒多推一帧（本屏 8fps 下完全可忽略）。
   */
  private static readonly FRAME_HEARTBEAT_MS: number = 3000;

  clearSignature(): void {
    this.lastSig = '';
  }
  /** 分页屏自动翻页间隔（秒），0 = 不自动 */
  pageRotateSec: number = 10;
  private lastPageSwitch: number = 0;
  /** 主题轮播：>0 时每 N 秒自动切到下一个主题（0=关闭） */
  /**
   * 主题轮播间隔（秒）。0 = 关闭（默认）。
   *
   * ⚠️ 实测教训：这个值一旦被设成 1，10 个主题就会**每秒换一个** ——
   * 每换一次都要重新渲染 + 编码 + 推帧，屏上表现为"一闪一闪"，而且帧循环会被
   * 拖到 tickMs≈3.9s（正常 125ms），最后应用直接卡死（diag 都无响应）。
   * 所以下面 setThemeRotateSec() 强制下限 5 秒。
   */
  private themeRotateSecRaw: number = 0;

  get themeRotateSec(): number {
    return this.themeRotateSecRaw;
  }

  /** 设置轮播间隔：**强制下限 5 秒**（避免秒级轮播把屏刷成闪烁、把应用拖死） */
  setThemeRotateSec(sec: number): void {
    let v = Number.isFinite(sec) ? Math.floor(sec) : 0;
    if (v > 0 && v < 5) {
      Logger.w(`主题轮播间隔 ${v}s 太短（会闪屏并拖死帧循环），已抬到 5s`);
      v = 5;
    }
    this.themeRotateSecRaw = v;
    this.lastThemeSwitch = Date.now();   // 重置计时，避免刚设完立刻切一次
  }
  /** 历史曲线采样（CPU/内存/token 速率/余额） */
  history: History = new History();
  /** 当前弹窗（null=没有） */
  toast: Toast | null = null;
  /** 专注计时（番茄钟） */
  focus: FocusTimer = new FocusTimer();
  /** 上一帧的遥测：弹窗策略要拿它做对比 */
  private prevT: Telemetry | null = null;
  private lastToolToast: string = '';
  private lastToastAt: number = 0;
  private lastThemeSwitch: number = 0;
  /** 背景图（来自桥的 /bg；null=没有） */
  bgPm: image.PixelMap | null = null;
  private bgTried: number = 0;
  bgUrl: string = '';
  /** 设备握手报出来的旋转角（0/90/180/270），用于 rotMode=0 时决定转不转 */
  private deviceRotDeg: number = 0;
  /** 后台保活任务是否已申请（由界面层设置：它才拿得到 UIAbilityContext） */
  bgTask: boolean = false;

  // 校准状态（纯逻辑在 CanvasCalib.ets，可离线测试）
  private calib: CalibState = new CalibState(1280, 320);

  private sentTimes: number[] = [];
  private lastSendTs: number = 0;
  private usbRetryTs: number = 0;
  /** USB 打开退避状态（纯逻辑见 SchedulePolicy.ets） */
  private usbState: UsbAttemptState = new UsbAttemptState();
  /** 夜间熄屏（默认关，由界面开关控制） */
  nightEnabled: boolean = false;
  private nightWin: NightWindow = new NightWindow(18, 30, 9, 0);
  /** 上一帧是否出错，用于退避 */
  private lastTickErrored: boolean = false;
  lastError: string = '';
  // ---- VM 监视画面（右侧 480×480 区域）----
  private vmPm: image.PixelMap | null = null;
  private vmAt: number = 0;
  private vmErr: string = '';
  private vmBusy: boolean = false;
  private vmFrames: number = 0;

  /** 协议层自检结果（真机第一次运行即可判断代码是否正确） */
  selfTests: TestItem[] = [];
  selfTestSummary: string = '未运行';

  /**
   * 运行时自检（链路层面：USB/推帧/数据桥/画面源/本机采集）。
   * 与协议 KAT 的区别见 service/RuntimeCheck.ets 的说明。
   */
  runtimeChecks: TestItem[] = [];
  runtimeSummary: string = '未运行';
  private lastRuntimeCheckMs: number = 0;

  /**
   * 明文快照路径（由 DSH 侧插件写出）。
   *
   * ★ 为什么要读文件而不是只收 UDP：
   *   App 解不开 zstd（ArkTS 无 zstd，`@ohos.zlib` 只有 DEFLATED），
   *   所以会话数据必须由能解压的一方（DSH）写成**明文**快照，App 直接读。
   *   比 UDP 少三类故障：丢包、多源互相覆盖、socket 失效需自愈。
   */
  /**
   * 快照地址（★ 从"读文件"改为"HTTP 取"—— 实测依据）：
   *   读 `/storage/Users/currentUser/.dsh/storages/lcd-bridge/last.json`
   *   被系统拒绝，错误码 **13900001**（访问被拒），即使 chmod 666 也一样
   *   → 鸿蒙对 `~/.dsh` 这类用户私有目录有跨应用访问控制。
   *   而 **HTTP 回环是通的**：App 现在就在成功取 `http://127.0.0.1:8787/vm/frame.jpg`
   *   （实测 vmFrames 在涨、vmErr 为空）。所以快照改由插件的 HTTP 服务提供。
   */
  private static readonly SNAPSHOT_URL: string = 'http://127.0.0.1:54548/snapshot.json';

  /**
   * 余额直连配置（★ 用户要求：**DSH 不跑时余额也要正常**）
   *
   * sk- key 从哪来：App 读不了 `~/.dsh/.credentials.yaml`（实测 13900001 访问被拒），
   * 所以由插件在快照里**递一次**（`deepseekKey`），App 收到后存进 preferences，
   * 之后长期有效、不再依赖 DSH。
   */
  private static readonly BALANCE_URL: string = 'https://api.deepseek.com/user/balance';
  private deepseekKey: string = '';
  /**
   * App **自己直连**取到的余额。
   *
   * ★ 为什么单独存而不放进 `bridge.state.data.balance`（实测踩过）：
   *   `mergeInto()` 每次合并都会**用新对象替换整份 `state.data`**，
   *   而余额不在它的合并列表里 → 新对象里没有余额 →
   *   **下一次快照/包一来，刚取到的余额就被抹掉**。
   *   表现为日志里明明打印了"余额（App 直连）: CNY 182.75"，
   *   但 `/diag` 的 balanceTotal 仍是 -1。
   *   独立存放后，任何来源的对象替换都影响不到它。
   */
  private directBalance: BalanceInfo | undefined = undefined;
  private balanceAt: number = 0;
  private balanceBusy: boolean = false;
  /** 余额刷新间隔：10 分钟（余额变化慢，且是公网请求） */
  private static readonly BALANCE_EVERY_MS: number = 600000;

  /**
   * 打印机直连（★ 用户要求：**DSH 不跑时打印机也要正常**）
   *
   * 数据源是本机 `bambu-monitor`（实测 `http://127.0.0.1:8790/api/state` 返回
   * `{"monitor":{...},"state":{"state":"FINISH","progress":{...},"temps":{...},"ams":{...}}}`
   * ），App 用 `http.createHttp()` 直接取 —— 它本来就在对 127.0.0.1 取 VM 画面。
   *
   * 映射规则与插件侧 `printer.mjs` 的 `mapBambuState()` **保持一致**（字段名不能改，
   * 屏上的 `normalizePrinter` 认这套名字）。
   */
  private static readonly PRINTER_URL: string = 'http://127.0.0.1:8790/api/state';
  private directPrinter: PrinterInfo | undefined = undefined;
  private printerAt: number = 0;
  private printerBusy: boolean = false;
  private printerFails: number = 0;
  /** 打印机刷新间隔：5 秒（与桥端一致） */
  private static readonly PRINTER_EVERY_MS: number = 5000;
  private snapshotProbe: SnapshotProbe = new SnapshotProbe();

  onStatus: () => void = () => {};
  onCanvasResize: (vpW: number, vpH: number) => void = () => {};

  /**
   * 应用资源管理器（用于读 resources/rawfile 里的官方底图）。
   * 由界面侧注入 —— LcdService 手里的 ctx 是**画布**，不是 UIAbilityContext，
   * 拿不到 resourceManager（真机上直接抛错）。没注入时相关功能安全降级。
   */
  private resMgr: resourceManager.ResourceManager | null = null;
  /**
   * 网络变化监听。
   *
   * 起因：用户把网络切到 192.168.11 之后，应用/桥全断了 —— 因为本机 IP 变了，
   * 而桥的监视地址（vmUrl）与遥测来源都按旧地址/旧连接停着，应用自己不知道。
   * 这里监听系统的网络能力变化：一旦网络可用/切换，就
   *   ① 丢弃"桥龄"统计，让看门狗重新计时；
   *   ② 立刻允许重取 VM 帧（清掉 1s 节流）；
   *   ③ 把当前本地 IP 记进日志与 diag，便于定位。
   * （桥是 app 主动 HTTP 拉取的，所以不需要"重连"，只需要清掉陈旧状态、立刻重试。）
   */
  /** 只有横装版面的主题（竖装下回落到 0）：6=固件仿真、7=官方浅色风 */
  private static readonly HORIZONTAL_ONLY: Set<number> = new Set([6, 7]);
  /** 记录上一次因竖装回落而改写的主题（避免每次 tick 重复写日志/状态） */
  private lastFallbackTheme: number = -1;
  private lastBridgeRebind: number = 0;
  /**
   * DSH 面板底部滚动留言条（旧→新）。用户 2026-10-14 要求：
   * "执行命令底下的文字，能否改成三行，文字缩小带滚动，这样带感一点"。
   * 摘要/最后一句一变就 push；只保留最近若干条，避免无限增长。
   */
  private feedLines: string[] = [];
  private feedAt: number = 0;
  private lastFeedKey: string = '';

  /** 把一条内容推进滚动留言条（去重：同一条不重复 push） */
  /**
   * 跑马灯内容：把最近的 feed 行 + 关键数据拼成一条长文本。
   * 只取最近 4 条，避免字符串过长导致每帧 measureText 变慢。
   */
  private tickerText(t: Telemetry): string {
    const bits: string[] = [];
    const ag = t.agent;
    if (ag !== undefined && ag.state === 'busy') {
      const act = ag.activity !== undefined ? ag.activity : '';
      const tool = ag.tool !== undefined && ag.tool.length > 0 ? ` (${ag.tool})` : '';
      bits.push(`DSH 忙碌${tool} ${act}`);
    } else {
      bits.push('DSH 空闲');
    }
    if (ag !== undefined && ag.lastText !== undefined && ag.lastText.length > 0) {
      bits.push(ag.lastText.length > 90 ? ag.lastText.substring(0, 90) + '…' : ag.lastText);
    }
    const bal = this.balanceTotal();
    if (bal >= 0) {
      bits.push(`余额 ¥${bal.toFixed(2)}`);
    }
    const pr = t.printer;
    if (pr !== undefined && pr.state !== undefined) {
      const pct = pr.percent !== undefined && pr.percent >= 0 ? ` ${pr.percent}%` : '';
      bits.push(`打印机 ${pr.stateLabel !== undefined && pr.stateLabel.length > 0 ? pr.stateLabel : pr.state}${pct}`);
    }
    for (let i = Math.max(0, this.feedLines.length - 4); i < this.feedLines.length; i++) {
      const f = this.feedLines[i];
      if (f.length > 0) {
        bits.push(f.length > 60 ? f.substring(0, 60) + '…' : f);
      }
    }
    return bits.join('   •   ') + '   •   ';
  }

  /**
   * 伪频谱的驱动值（0..1）。
   *
   * 取"相对近期峰值的速率"而不是绝对值 —— 否则一直贴顶/贴底看不出变化。
   * 数据源：输出 token 的增量（用 history.tokens 的最近两点差），退化为 CPU 百分比。
   */
  private specValue(t: Telemetry): number {
    const toks = this.history.tokens;
    let v = 0;
    if (toks.length >= 2) {
      const d = Math.abs(toks.last() - toks.at(toks.length - 2));
      // 经验刻度：一个采样周期里涨 200 token 视为满格
      v = Math.min(1, d / 200);
    }
    if (v <= 0.01) {
      // CPU 占用来自 History 的采样序列（0..100），不是 FrameStats
      const cpu = this.history.cpu.last();
      if (cpu >= 0) {
        v = Math.max(0, Math.min(1, cpu / 100));
      }
    }
    // 给一点底噪，避免整条全黑（看起来像坏了）
    return Math.max(0.03, v);
  }

  /**
   * 整点彩条还剩多少毫秒（0 = 不在整点窗口内）。
   * 窗口 = 每小时的第 0 分钟、且已过的秒数 < HOUR_BELL_MS。
   */
  private hourBellLeftMs(): number {
    if (!this.hourBellOn) {
      return 0;
    }
    // 调试强制优先（/set?hbtest=N）
    if (this.hourBellForceUntil > Date.now()) {
      return this.hourBellForceUntil - Date.now();
    }
    const d = new Date();
    if (d.getMinutes() !== 0) {
      return 0;
    }
    const passed = d.getSeconds() * 1000 + d.getMilliseconds();
    const left = LcdService.HOUR_BELL_MS - passed;
    return left > 0 ? left : 0;
  }

  private pushFeed(text: string): void {
    const t = text.trim();
    if (t.length === 0 || t === this.lastFeedKey) {
      return;
    }
    this.lastFeedKey = t;
    this.feedLines.push(t);
    while (this.feedLines.length > 12) {
      this.feedLines.shift();
    }
    this.feedAt = Date.now();
  }
  private netConn: connection.NetConnection | null = null;
  private netEvents: number = 0;
  private netLastIface: string = '';
  private netLastIp: string = '';

  constructor(ctx: CanvasRenderingContext2D, resMgr: resourceManager.ResourceManager | null = null) {
    this.ctx = ctx;
    this.resMgr = resMgr;
  }

  get isRunning(): boolean {
    return this.running;
  }

  get usbLabel(): string {
    return this.usb.deviceLabel;
  }

  get usbOpen(): boolean {
    return this.usb.isOpen;
  }

  get deviceInfo(): DeviceInfo | null {
    return this.usb.deviceInfo;
  }

  /** 端点选择摘要（界面上显示，真机排障用） */
  get endpointSummary(): string {
    return this.usb.endpointSummary;
  }

  /**
   * 注册网络变化监听。系统网络能力一变（连上/断开/切网），就清掉陈旧的
   * "桥龄/VM 节流"状态，让下一轮 tick 立刻重新拉取，而不是干等看门狗。
   */
  private bindNetworkWatcher(): void {
    if (this.netConn !== null) {
      return;
    }
    try {
      const conn = connection.createNetConnection();
      this.netConn = conn;
      conn.on('netAvailable', () => {
        this.onNetChanged('netAvailable');
      });
      conn.on('netLost', () => {
        this.onNetChanged('netLost');
      });
      conn.on('netCapabilitiesChange', () => {
        this.onNetChanged('netCapabilitiesChange');
      });
      conn.register((err: Object) => {
        if (err !== null && err !== undefined) {
          Logger.w(`网络监听注册失败: ${JSON.stringify(err)}`);
        } else {
          Logger.i('网络监听已注册（自动识别网络切换）');
        }
      });
    } catch (e) {
      Logger.w(`网络监听不可用: ${Logger.safe(e)}`);
    }
  }

  /** 网络变化后的处理：清陈旧状态 + 记录当前链路，便于 diag 定位 */
  private async onNetChanged(reason: string): Promise<void> {
    this.netEvents++;
    this.lastSig = '';          // 强制下一轮重画重推
    this.vmAt = 0;              // 允许立刻重取 VM 帧（清 1s 节流）
    this.vmErr = '';
    // 记下当前默认网络的链路信息
    try {
      const net = await connection.getDefaultNet();
      const link = await connection.getConnectionProperties(net);
      let iface = '';
      if (link !== null && link.interfaceName !== undefined) {
        iface = link.interfaceName;
      }
      let ip = '';
      const addrs = link !== null && link.linkAddresses !== undefined ? link.linkAddresses : [];
      for (const a of addrs) {
        if (a !== undefined && a.address !== undefined && a.address.address !== undefined) {
          ip = a.address.address;
        }
      }
      this.netLastIface = iface;
      this.netLastIp = ip;
      Logger.i(`网络变化(${reason}): ${iface} ${ip}`);
      if (iface.length === 0) {
        this.lastError = `网络变化(${reason})：当前没有默认网络`;
      }
      this.onStatus();
    } catch (e) {
      Logger.i(`网络变化(${reason})：取链路信息失败（不影响推帧）`);
    }
  }

  /**
   * 主题 5 / 主题 9 共用的 Dotii 状态准备：翻页与表情计时、余额、打印机、网络、
   * 自定义页文案。抽出来的原因：主题 9 把 Dotii 搬到打印机格，但内容必须与主题 5
   * 完全一致 —— 状态准备只留一份，避免两边漂移。
   */
  /**
   * Dotii 是否正被画在**打印机格**里（主题 0 + 对应档位）。
   *
   * ★ 为什么内容签名需要它（实测 bug）：
   *   签名原来只写 `${this.theme === 5 ? this.dotiiState.page : 0}` ——
   *   主题 0 把 Dotii 放进打印机格时（printerCell = dotii/v4/v6），
   *   **页号变化不进签名** → 每 10 秒翻页那一刻签名不变 →
   *   被"内容未变则跳过"挡掉 → 屏上永远停在第一页（用户反馈"轮播的标怎么都不变"）。
   *   判定必须与渲染侧的 dotiiInPrinter **一致**，故抽成这一个函数共用。
   */

  private dotiiShownInCell(): boolean {
    return this.theme === 0
      && (this.printerCell === 'dotii' || this.printerCell === 'v4'
        || this.printerCell === 'v6');
  }

  private prepareDotiiState(t: Telemetry): void {
    const nowMs = Date.now();
    const ds = this.dotiiState;
    const d = new Date();
    ds.hour = d.getHours();
    ds.minute = d.getMinutes();
        // 自动翻页（10s）+ 表情自动换（10s 换一个，用户 2026-10-14 定"一个表情占满 10s"）
        if (this.dotiiPageAt === 0) { this.dotiiPageAt = nowMs; this.dotiiExprAt = nowMs; }
        // ★ 每种页可以有自己的保留时长：贪吃蛇页 60s，其余 10s
        const curDur: number = ((ds.page % DOTII_PAGES) === DOTII_SNAKE_PAGE)
          ? this.dotiiSnakePageMs : this.dotiiPageMs;
        if (nowMs - this.dotiiPageAt >= curDur) {
          this.dotiiPageAt = nowMs;
          ds.page = (ds.page + 1) % DOTII_PAGES;
        }
        if (nowMs - this.dotiiExprAt >= this.dotiiPageMs) {
          this.dotiiExprAt = nowMs;
          // ★ 表情**随机**（用户 2026-10-16 明确要求）：
          //   原来是 `(ds.expr + 1) % 8` 顺序轮播，看着像"按顺序播一遍"，
          //   容易让人以为表情在跟某个状态走。用户要的是"随机、不关联其他动作或结果"。
          //   · 用 DOTII_EXPR_NAMES.length 而非写死 8 —— 以后加表情不会漏
          //   · 避开"和当前相同"，否则连出同一个会像卡住
          //   · 本函数是从固件移植的表情表，8 个里含 connecting/working/complete/failure
          //     等名字，但**应用侧从不按状态选表情**（全仓只有这一处赋值），
          //     所以随机挑不会破坏"表情与状态解耦"。
          ds.expr = randomExpr(ds.expr);
        }
        // ---- 数据快照：按源固件的状态机映射（state_ui.c:2244-2356 / 2393-2443）----
        const bal = t.balance;
        const balErr = (bal !== undefined && bal.error !== undefined) ? bal.error : '';
        ds.balanceHasValue = bal !== undefined && bal.total !== undefined;
        ds.balanceTotal = (bal !== undefined && bal.total !== undefined) ? bal.total.toFixed(2) : '--';
        ds.balanceGranted = (bal !== undefined && bal.granted !== undefined) ? bal.granted.toFixed(2) : '--';
        ds.balanceTopped = (bal !== undefined && bal.toppedUp !== undefined) ? bal.toppedUp.toFixed(2) : '--';
        if (!ds.balanceHasValue) {
          ds.balanceStatus = '未接入';
        } else if (balErr.length > 0) {
          ds.balanceStatus = balErr.indexOf('401') >= 0 || balErr.indexOf('密钥') >= 0 ? '密钥无效' : '获取失败';
        } else if (bal !== undefined && bal.available === false) {
          ds.balanceStatus = '不可用';
        } else {
          ds.balanceStatus = '可用';
        }

        const pr = t.printer;
        if (pr !== undefined) {
          const st5 = pr.state !== undefined ? pr.state : '';
          ds.prState = st5;
          ds.prPct = pr.percent !== undefined ? pr.percent : -1;
          ds.prNozzle = pr.nozzleTemp !== undefined ? pr.nozzleTemp : -1;
          ds.prBed = pr.bedTemp !== undefined ? pr.bedTemp : -1;
          ds.prLayer = pr.layer !== undefined ? pr.layer : -1;
          ds.prTotalLayer = pr.totalLayer !== undefined ? pr.totalLayer : -1;
          if ((pr.monitorMode ?? '') === 'error' || (pr.monitorError ?? '').length > 0) {
            ds.prStatusText = '监控未登录';
          } else if (st5 === 'RUNNING') {
            ds.prStatusText = '打印中';
          } else if (st5 === 'PAUSE') {
            ds.prStatusText = '已暂停';
          } else if (st5 === 'PREPARE') {
            ds.prStatusText = '准备中';
          } else if (st5 === 'FINISH') {
            ds.prStatusText = '已完成';
          } else if (st5 === 'FAILED') {
            ds.prStatusText = '失败';
          } else if (st5 === 'OFFLINE' || st5.length === 0) {
            ds.prStatusText = '离线';
          } else {
            ds.prStatusText = '待机';
          }
          const rem = pr.remainingSec !== undefined ? pr.remainingSec : -1;
          if (rem > 0) {
            ds.prRemainText = `${Math.floor(rem / 3600)}h${Math.floor((rem % 3600) / 60)}m`;
          } else {
            ds.prRemainText = '--';
          }
          ds.prFinishText = (pr.eta !== undefined && pr.eta.length > 0) ? pr.eta : '--';
        }

        const sys5 = t.system;
        ds.batt = (sys5 !== undefined && sys5.battery !== undefined) ? sys5.battery : -1;
        ds.charging = (sys5 !== undefined && sys5.charging === true);
        ds.wifiOn = this.stats.usbOpen;
        ds.wifiConnecting = !this.stats.usbOpen;
        ds.connText = this.summaryText().length > 0 ? this.summaryText() : 'DSH · 本机';
        // 自定义页（源无百分比，是四段文本）
        ds.customTitle = '我的页面';
        ds.customValue = `第 ${ds.page + 1}/${DOTII_PAGES} 页`;
        ds.customBody = ThemeDotii.NAME;
        ds.customFooter = '';   // 用户要求删掉这类来源说明（ESP32-S3 等）
  }

  /**
   * 打印机格右侧信息栏的数据（主题 0 的 Dotii 开关 与 主题 9 共用）。
   * 抽出来的理由同 prepareDotiiState：同一份内容不能有两套取值逻辑，否则会漂移。
   */
  private prepareDotiiCellInfo(t: Telemetry): PrinterInfo | undefined {
    // 主题 9：打印机格位置放 Dotii（内容复用主题 5），右侧窄栏显示真实打印机数据
    const ci = this.dotiiCellInfo;
    const pr9 = t.printer;
    ci.prState = pr9 !== undefined && pr9.stateLabel !== undefined && pr9.stateLabel.length > 0
      ? pr9.stateLabel : (pr9 !== undefined && pr9.state !== undefined ? pr9.state : '');
    ci.prPct = pr9 !== undefined && pr9.percent !== undefined ? pr9.percent : -1;
    ci.prNozzle = pr9 !== undefined && pr9.nozzleTemp !== undefined ? pr9.nozzleTemp : -1;
    ci.prBed = pr9 !== undefined && pr9.bedTemp !== undefined ? pr9.bedTemp : -1;
    ci.prLayer = pr9 !== undefined && pr9.layer !== undefined ? pr9.layer : -1;
    ci.prRemainText = (pr9 !== undefined && pr9.remainingSec !== undefined && pr9.remainingSec > 0)
      ? `${Math.floor(pr9.remainingSec / 3600)}h${Math.floor((pr9.remainingSec % 3600) / 60)}m` : '--';
    ci.trays = pr9 !== undefined && pr9.trays !== undefined ? pr9.trays.length : 0;
    ci.balance = t.balance !== undefined && t.balance.total !== undefined && t.balance.total >= 0
      ? `¥${t.balance.total.toFixed(2)}` : '--';
    // 与主题 5 共用同一份状态准备（翻页/表情/余额/打印机/网络），
    // 这样 Dotii 在两种位置显示的内容完全一致，只是搬了格子
    this.prepareDotiiState(t);
    return pr9;
  }

  async start(): Promise<void> {
    // ★ 内置背景图必须**无条件**在启动时载入。
    //   原来它被放在"只在主题 7 才执行"的分支里（`if (this.trccBg[0] === null)`），
    //   于是主题 15 用图片背景时 `Backdrop.image` 恒为 null（实测踩过）。
    this.loadSampleBg();

    if (this.running) {
      return;
    }
    this.running = true;
    this.bindNetworkWatcher();
    try {
      const d = display.getDefaultDisplaySync();
      if (d.densityPixels > 0) {
        this.density = d.densityPixels;
      }
    } catch (e) {
      // 取不到就保持 1：首帧可能返回 null，下一帧用 JPEG 真值
    }
    this.runSelfTest();
    this.onBridgeReady();
    await this.bridge.start();
    // 注入诊断数据提供者（本沙箱读不到 hilog，外部靠 HTTP 取证据）
    this.frameServer.statusProvider = () => this.statusJson();
    this.frameServer.diagProvider = () => this.diagJson();
    this.frameServer.probeProvider = () => this.probeJson();
    this.frameServer.setProvider = (q: string) => this.applySettings(q);
    await this.frameServer.start();
    await this.tryOpenUsb();
    this.loop();
    Logger.i('LcdService 已启动');
  }

  /**
   * 抓一帧 VM 监视画面（来自 livepad）。
   * 失败不影响帧循环；旧 PixelMap 会被 release，避免内存持续增长。
   */
  /**
   * 取自定义背景图（桥端 --bg 提供的 /bg）。
   * 只在启动后取一次；失败则每 5 分钟重试（桥可能后启动）。成功就不再重复下载。
   */
  /**
   * 载入主题 7 的官方底图（5 套，各 ~4.6KB PNG）。
   * 从 resources/rawfile/trcc/official_N.png 读，失败则返回 null（主题会退回纯色底，不报错）。
   */
  /** 载入内置背景图（rawfile/bg_sample.jpg，来自 trofeo-lcd-rs 的 sample_background） */
  /** 内置背景图是否正在载入 */
  private sampleBgLoading: boolean = false;

  private async loadSampleBg(): Promise<void> {
    if (this.sampleBgLoading || Backdrop.image !== null) {
      return;
    }
    this.sampleBgLoading = true;
    // ★ 2026-10-15（代码审查【中-1】）：`sampleBgLoading` 与 `ImageSource` 必须在 finally 里
    //   复位/释放。原实现只在成功路径走到最后 —— 一旦抛异常，`sampleBgLoading` 永远是 true，
    //   `loadSampleBg()` 之后每次进来都在开头 `return` → **内置背景图永久失效**
    //   （这是本报告里唯一一条"一次偶发失败即永久不可用"的缺陷）。
    //   对照：`loadTrccBg` 与 `fetchVmFrame` 都正确用了 finally。
    let src: image.ImageSource | null = null;
    try {
      const rm: resourceManager.ResourceManager | null = this.resMgr;
      if (rm === null) {
        Logger.w('没有 resourceManager，内置背景图跳过');
        return;
      }
      const bytes: Uint8Array = rm.getRawFileContentSync('bg_sample.jpg');
      const ab: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset,
        bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      src = image.createImageSource(ab);
      const pm: image.PixelMap = await src.createPixelMap();
      Backdrop.image = pm;
      const info = pm.getImageInfoSync();
      Backdrop.imageNote = `OK ${info.size.width}x${info.size.height}`;
      Logger.i(`内置背景图载入完成（bg_sample.jpg）${Backdrop.imageNote}`);
    } catch (e) {
      const err = e as BusinessError;
      Backdrop.imageNote = `FAIL ${err.code} ${err.message}`;
      Logger.w(`内置背景图载入失败: ${err.code} ${err.message}`);
    } finally {
      if (src !== null) {
        try {
          src.release();
        } catch (e) {
          // 释放失败不影响功能
        }
      }
      this.sampleBgLoading = false;   // ★ 必须复位，否则失败一次就永久不再重试
    }
  }

  private async loadTrccBg(): Promise<void> {
    if (this.trccBgLoading || this.trccBg[0] !== null) {
      return;
    }
    this.trccBgLoading = true;
    try {
      const rm: resourceManager.ResourceManager | null = this.resMgr;
      if (rm === null) {
        Logger.w('没有 resourceManager，官方底图跳过（主题 7 会退回自绘卡片）');
        return;
      }
      for (let i = 0; i < 5; i++) {
        try {
          const bytes: Uint8Array = rm.getRawFileContentSync(`trcc/official_${i + 1}.png`);
          const ab: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset,
            bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
          const src: image.ImageSource = image.createImageSource(ab);
          const pm: image.PixelMap = await src.createPixelMap();
          this.trccBg[i] = pm;
          src.release();          // ★ ImageSource 必须释放（fetchVmFrame 曾漏了，每秒泄漏一个）
        } catch (e) {
          Logger.w(`官方底图 ${i + 1} 载入失败: ${Logger.safe(e)}`);
        }
      }
      Logger.i(`官方底图载入完成：${this.trccBg.filter((x) => x !== null).length}/5`);
    } catch (e) {
      Logger.e(`官方底图载入异常: ${Logger.safe(e)}`);
    } finally {
      this.trccBgLoading = false;
    }
  }

  private async fetchBgImage(): Promise<void> {
    if (this.bgPm !== null || this.bgUrl.length === 0) {
      return;
    }
    if (this.bgTried !== 0 && Date.now() - this.bgTried < 300000) {
      return;
    }
    this.bgTried = Date.now();
    const req = http.createHttp();
    try {
      const resp = await req.request(this.bgUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 1500,
        readTimeout: 3000,
      });
      if (resp.responseCode === 200 && resp.result !== undefined) {
        const src = image.createImageSource(resp.result as ArrayBuffer);
        let pm: image.PixelMap | null = null;
        try {
          pm = await src.createPixelMap();
        } finally {
          src.release();
        }
        this.bgPm = pm;      // 进到这里 bgPm 必为 null（上面已 return），不需要释放旧的
        Logger.i('背景图已加载');
      }
    } catch (e) {
      // 桥没开 --bg 或暂时不可达：静默失败，下次再试
    } finally {
      req.destroy();
    }
  }

  private async fetchVmFrame(): Promise<void> {
    if (this.vmBusy || Date.now() - this.vmAt < VM_INTERVAL_MS) {
      return;
    }
    this.vmBusy = true;
    this.vmAt = Date.now();
    const req = http.createHttp();
    try {
      const resp = await req.request(this.vmUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 1500,
        readTimeout: 1500,
      });
      if (resp.responseCode !== 200 || resp.result === undefined) {
        this.vmErr = `HTTP ${resp.responseCode}`;
      } else {
        const buf = resp.result as ArrayBuffer;
        const src = image.createImageSource(buf);
        try {
          const pm = await src.createPixelMap();
          const old = this.vmPm;
          this.vmPm = pm;
          this.vmFrames++;
          this.vmErr = '';
          if (old !== null) {
            old.release();
          }
        } finally {
          // ★ ImageSource 必须释放：本函数每秒取一帧，不释放就是每秒漏一个原生对象。
          //   （PixelMap 有 release，但 ImageSource 没有 —— 之前只释放了老的 PixelMap。）
          src.release();
        }
      }
    } catch (e) {
      this.vmErr = '取帧失败（livepad 未运行？）';
    } finally {
      req.destroy();
      this.vmBusy = false;
    }
  }

  /** VM 画面年龄（毫秒），无帧时 -1 */
  private vmAge(): number {
    return this.vmAt === 0 ? -1 : Date.now() - this.vmAt;
  }

  /**
   * 给界面用的取帧状态。
   * 起因：填了 VM 监视地址"没反应"，但原因（HTTP 401 / livepad 没跑）只写在 /diag 里，
   * 界面上看不到，只能干等。这三个取值器让界面能直接显示"上次取帧多久前 / 错在哪"。
   */
  vmAgeMsForUi(): number {
    return this.vmAge();
  }

  vmErrForUi(): string {
    return this.vmErr;
  }

  vmFramesForUi(): number {
    return this.vmFrames;
  }

  /** 纯计算自检，不碰 USB，无屏幕也能跑 */
  private runSelfTest(): void {
    this.selfTests = SelfTest.run();
    this.selfTestSummary = SelfTest.summary(this.selfTests);
    for (const it of this.selfTests) {
      if (it.ok) {
        Logger.i(`[自检] ✅ ${it.name} | ${it.detail}`);
      } else {
        Logger.e(`[自检] ❌ ${it.name} | ${it.detail}`);
      }
    }
    Logger.i(`[自检] ${this.selfTestSummary}`);
    this.runRuntimeCheck();
    this.onStatus();
  }

  /**
   * 运行时自检：把链路各环的现状打分（只读，无副作用）。
   * `force=false` 时节流到 5 秒一次 —— 它挂在状态刷新里，避免每帧都跑。
   */
  /**
   * 探测快照文件能不能读（每 30 秒一次，避免频繁 IO）。
   * 结论要能在界面上看到 —— 因为它决定 App 是否可以不依赖 UDP 取数。
   */
  private probeSnapshot(): void {
    const now = Date.now();
    if (this.snapshotProbe.at > 0 && now - this.snapshotProbe.at < 10000) {
      return;
    }
    this.snapshotProbe.at = now;
    const req = http.createHttp();
    req.request(LcdService.SNAPSHOT_URL, {
      method: http.RequestMethod.GET,
      connectTimeout: 2000,
      readTimeout: 3000
    }).then((resp: http.HttpResponse) => {
      if (resp.responseCode === 200 && resp.result !== undefined) {
        const txt = typeof resp.result === 'string'
          ? resp.result as string : JSON.stringify(resp.result);
        this.snapshotProbe.ok = true;
        this.snapshotProbe.note = `可读，${txt.length} 字节`;
        this.adoptKeyFromSnapshot(txt);
        this.fetchBalanceDirect();
        // ★ 快照作为**主数据源**：按字段合并进 state（与 UDP 那套合并逻辑同源）
        try {
          const parsed = JSON.parse(txt) as Object;
          this.bridge.mergeInto(parsed);
          const src = (parsed as Record<string, Object>)['source'];
          this.bridge.state.lastSource =
            (typeof src === 'string' ? src as string : '') + '+http';
          this.bridge.state.lastRxTs = Date.now();
        } catch (e) {
          this.snapshotProbe.note = `可读但解析失败: ${Logger.safe(e)}`;
        }
      } else {
        this.snapshotProbe.ok = false;
        this.snapshotProbe.note = `HTTP ${resp.responseCode}`;
      }
      req.destroy();
    }).catch((e: Object) => {
      const err = e as BusinessError;
      this.snapshotProbe.ok = false;
      this.snapshotProbe.note =
        `取不到（${err === undefined ? 'unknown' : err.code}）`;
      req.destroy();
    });
  }

  /**
   * 从快照里接住 sk- key 并**落盘**（只做一次）。
   * 之后即使 DSH 不再运行，App 也能自己刷新余额。
   */
  /**
   * 接住 sk- key（**两条路都能递过来**：UDP 载荷 或 HTTP 快照）。
   * 接住后立刻触发一次直连余额，之后每 10 分钟自刷，不再依赖 DSH。
   */
  /** 当前是否已持有 sk- key（供界面判断要不要落盘） */
  get hasDeepseekKey(): boolean {
    return this.deepseekKey.length > 0;
  }

  /** 取当前 key（仅供界面落盘用） */
  getDeepseekKey(): string {
    return this.deepseekKey;
  }

  /** 由界面在启动时注入已保存的 key（落盘后重启即可用，不依赖 DSH） */
  injectDeepseekKey(k: string): void {
    if (k.length > 10 && this.deepseekKey.length === 0) {
      this.deepseekKey = k;
      Logger.i('已注入保存的 sk- key（余额直连立即可用，无需等 DSH）');
      this.fetchBalanceDirect();
    }
  }

  adoptKey(o: Record<string, Object>): void {
    if (this.deepseekKey.length > 0) {
      return;
    }
    const k = o['deepseekKey'];
    if (typeof k === 'string' && (k as string).length > 10) {
      this.deepseekKey = k as string;
      Logger.i('已接住 sk- key → 余额改由 App 自己直连（DSH 不跑也能刷）');
      this.fetchBalanceDirect();
    }
  }

  private adoptKeyFromSnapshot(txt: string): void {
    try {
      this.adoptKey(JSON.parse(txt) as Record<string, Object>);
    } catch (e) {
      // 解析失败忽略
    }
  }

  /**
   * App **直连** DeepSeek 取余额（不经过 DSH）。
   * 结果写进 bridge.state.data.balance —— 屏幕与 /diag 都从这里读。
   */
  private fetchBalanceDirect(): void {
    if (this.deepseekKey.length === 0 || this.balanceBusy) {
      return;
    }
    const now = Date.now();
    if (this.balanceAt > 0 && now - this.balanceAt < LcdService.BALANCE_EVERY_MS) {
      return;
    }
    this.balanceAt = now;
    this.balanceBusy = true;
    const req = http.createHttp();
    req.request(LcdService.BALANCE_URL, {
      method: http.RequestMethod.GET,
      header: { 'Authorization': 'Bearer ' + this.deepseekKey },
      connectTimeout: 5000,
      readTimeout: 8000
    }).then((resp: http.HttpResponse) => {
      this.balanceBusy = false;
      if (resp.responseCode !== 200 || resp.result === undefined) {
        Logger.w(`余额直连失败: HTTP ${resp.responseCode}`);
        this.setBalanceError(`HTTP ${resp.responseCode}`);
        req.destroy();
        return;
      }
      const txt = typeof resp.result === 'string'
        ? resp.result as string : JSON.stringify(resp.result);
      try {
        const j = JSON.parse(txt) as Record<string, Object>;
        const infos = j['balance_infos'];
        const first: Record<string, Object> = (Array.isArray(infos) && infos.length > 0)
          ? infos[0] as Record<string, Object> : {};
        const n = (v: Object | undefined): number => {
          const x = Number.parseFloat(String(v));
          return Number.isFinite(x) ? x : -1;
        };
        const b: BalanceInfo = {
          currency: typeof first['currency'] === 'string' ? first['currency'] as string : 'CNY',
          total: n(first['total_balance']),
          granted: n(first['granted_balance']),
          toppedUp: n(first['topped_up_balance']),
          available: j['is_available'] === true,
          error: ''
        };
        this.directBalance = b;
        this.publishBalance();
        const tot = b.total === undefined ? -1 : b.total;
        Logger.i(`余额（App 直连）: ${b.currency} ${tot.toFixed(2)}`);
      } catch (e) {
        Logger.w(`余额解析失败: ${Logger.safe(e)}`);
        this.setBalanceError('解析失败');
      }
      req.destroy();
    }).catch((e: Object) => {
      this.balanceBusy = false;
      const err = e as BusinessError;
      Logger.w(`余额直连异常: ${err === undefined ? 'unknown' : err.code}`);
      this.setBalanceError(err === undefined ? 'unknown' : `${err.code}`);
      req.destroy();
    });
  }

  /** 记下余额取数失败（屏幕会显示"取数失败 xxx"） */
  /**
   * 把 App 直连取到的余额贴进 `bridge.state.data.balance`。
   * 屏幕与 /diag 的多个读取点都读这个字段，所以每轮体检时重贴一次。
   */
  private publishBalance(): void {
    // ★ 交给 bridge 持有（mergeInto 会优先用它，任何对象替换都不会冲掉）。
    //   同时也贴进当前 data，保证这一瞬的读取点也能看到。
    this.bridge.DirectBalance = this.directBalance;
    this.publishPrinter();
    if (this.directBalance !== undefined) {
      const d = this.bridge.state.data;
      d.balance = this.directBalance;
      this.bridge.state.data = d;
    }
  }

  private setBalanceError(msg: string): void {
    if (this.directBalance === undefined) {
      this.directBalance = { currency: 'CNY', total: -1, error: msg };
    } else {
      this.directBalance.error = msg;
    }
    this.publishBalance();
  }

  /**
   * App **直连**本机 bambu-monitor 取打印机状态（不经过 DSH）。
   */
  private fetchPrinterDirect(): void {
    if (this.printerBusy) {
      return;
    }
    const now = Date.now();
    if (this.printerAt > 0 && now - this.printerAt < LcdService.PRINTER_EVERY_MS) {
      return;
    }
    this.printerAt = now;
    this.printerBusy = true;
    const req = http.createHttp();
    req.request(LcdService.PRINTER_URL, {
      method: http.RequestMethod.GET,
      connectTimeout: 3000,
      readTimeout: 5000
    }).then((resp: http.HttpResponse) => {
      this.printerBusy = false;
      if (resp.responseCode !== 200 || resp.result === undefined) {
        this.onPrinterFail(`HTTP ${resp.responseCode}`);
        req.destroy();
        return;
      }
      const txt = typeof resp.result === 'string'
        ? resp.result as string : JSON.stringify(resp.result);
      try {
        const api = JSON.parse(txt) as Record<string, Object>;
        this.directPrinter = LcdService.mapBambu(api);
        this.printerFails = 0;
        this.publishPrinter();
      } catch (e) {
        const err = e as BusinessError;
        this.onPrinterFail('解析失败: ' + (err === undefined ? String(e) : err.message));
      }
      req.destroy();
    }).catch((e: Object) => {
      this.printerBusy = false;
      const err = e as BusinessError;
      this.onPrinterFail(err === undefined ? 'unknown' : `${err.code}`);
      req.destroy();
    });
  }

  /** 连续失败几次就报离线（与桥端 MAX_FAILS=3 一致） */
  private onPrinterFail(why: string): void {
    this.printerFails++;
    if (this.printerFails >= 3) {
      this.directPrinter = {
        state: 'OFFLINE', stateLabel: '离线', connected: false, online: false,
        percent: -1, layer: -1, totalLayer: -1, remainingSec: -1,
        nozzleTemp: -1, bedTemp: -1, chamberTemp: -1, printError: 0, hmsCount: 0, trays: []
      };
      this.publishPrinter();
    }
    Logger.w(`打印机直连失败(${this.printerFails}): ${why}`);
  }

  /** 贴回 state.data.printer（与余额同理：让所有读取点都能看到） */
  private publishPrinter(): void {
    this.bridge.DirectPrinter = this.directPrinter;
    if (this.directPrinter !== undefined) {
      const d = this.bridge.state.data;
      d.printer = this.directPrinter;
      this.bridge.state.data = d;
    }
  }

  /**
   * 把 bambu-monitor 的 `/api/state` 映射成 `PrinterInfo`。
   * 与 `dsh-plugin/dsh-lcd-bridge/printer.mjs` 的 `mapBambuState()` **同构**。
   */
  private static mapBambu(api: Record<string, Object>): PrinterInfo {
    // ★ 空值保护必须同时挡 `undefined` **和 `null`**（实测踩过）：
    //   JSON 里的 `null` 不是 undefined，用 `=== undefined ? {} : x` 会漏，
    //   于是 `x['field']` 抛 "Cannot load property of null or undefined"。
    //   打印机接口的 `errors`/`ams` 等字段确实会返回 null。
    const objOr = (v: Object | undefined, fallback: Record<string, Object>): Record<string, Object> => {
      if (v === undefined || v === null || typeof v !== 'object') {
        return fallback;
      }
      return v as Record<string, Object>;
    };
    const st = objOr(api['state'], {});
    const pr = objOr(st['progress'], {});
    const te = objOr(st['temps'], {});
    const am = objOr(st['ams'], {});
    const er = objOr(st['errors'], {});
    const mon = objOr(api['monitor'], {});
    const dev = objOr(mon['device'], {});

    const nums = (v: Object | undefined, def: number): number => {
      if (typeof v === 'number') {
        const n = v as number;
        return Number.isFinite(n) ? n : def;
      }
      // 打印机接口的数值有时是字符串（如 "33"），一起兼容
      if (typeof v === 'string') {
        const n = Number.parseFloat(v as string);
        return Number.isFinite(n) ? n : def;
      }
      return def;
    };

    // 托盘拉平（与桥端一致：过滤空位、按 1..N 连续编号）
    const trays: PrinterTray[] = [];
    const units = am['units'];
    if (Array.isArray(units)) {
      for (const u of units as Record<string, Object>[]) {
        const list = u['trays'];
        if (!Array.isArray(list)) {
          continue;
        }
        for (const t of list as Record<string, Object>[]) {
          const ty = typeof t['type'] === 'string' ? t['type'] as string : '';
          if (ty.length === 0 || ty === 'Empty') {
            continue;
          }
          trays.push({
            index: trays.length + 1,
            type: ty,
            color: LcdService.cssColor(t['color']),
            remain: nums(t['remain'], -1)
          });
        }
      }
    }
    const vtRaw = am['vtTray'];
    const vt = (vtRaw === undefined || vtRaw === null || typeof vtRaw !== 'object')
      ? undefined : vtRaw as Record<string, Object>;
    if (vt !== undefined && typeof vt['type'] === 'string'
        && (vt['type'] as string).length > 0 && vt['type'] !== 'Empty') {
      trays.push({
        index: trays.length + 1,
        type: vt['type'] as string,
        color: LcdService.cssColor(vt['color']),
        remain: nums(vt['remain'], -1)
      });
    }

    // 机型串
    const bits: string[] = [];
    const nm = dev['name'] !== undefined ? dev['name'] : dev['model'];
    if (typeof nm === 'string' && (nm as string).length > 0) {
      bits.push(nm as string);
    }
    const mdlRaw = st['model'];
    const mdl = (mdlRaw === undefined || mdlRaw === null || typeof mdlRaw !== 'object')
      ? undefined : mdlRaw as Record<string, Object>;
    if (mdl !== undefined) {
      const nd = mdl['nozzleDiameter'];
      if (typeof nd === 'string') {
        bits.push(`${nd}mm`);
      }
      const nt = mdl['nozzleType'];
      if (typeof nt === 'string') {
        bits.push(nt as string);
      }
    }

    const hms = er['hms'];
    const hmsArr = Array.isArray(hms) ? hms as Record<string, Object>[] : [];
    let hmsCode = '';
    if (hmsArr.length > 0) {
      const c = hmsArr[0]['code'];
      if (typeof c === 'string') {
        hmsCode = c as string;
      }
    }

    return {
      state: typeof st['state'] === 'string' ? st['state'] as string : 'UNKNOWN',
      stateLabel: typeof st['stateLabel'] === 'string' ? st['stateLabel'] as string : '',
      connected: st['connected'] === true,
      online: st['online'] === true,
      model: bits.join(' '),
      jobName: typeof st['jobName'] === 'string' ? st['jobName'] as string : '',
      percent: nums(pr['percent'], -1),
      layer: nums(pr['layer'], -1),
      totalLayer: nums(pr['totalLayer'], -1),
      remainingSec: nums(pr['remainingSec'], -1),
      elapsedSec: nums(pr['elapsedSec'], -1),
      nozzleTemp: nums(te['nozzle'], -1),
      nozzleTarget: nums(te['nozzleTarget'], -1),
      bedTemp: nums(te['bed'], -1),
      bedTarget: nums(te['bedTarget'], -1),
      chamberTemp: nums(te['chamber'], -1),
      printError: nums(er['printError'], 0),
      hmsCount: hmsArr.length,
      hmsCode: hmsCode,
      trayNow: nums(am['trayNow'], -1),
      trays: trays
    };
  }

  /** "RRGGBB"/"RRGGBBAA" → "#RRGGBB"；无效返回 undefined */
  private static cssColor(v: Object | undefined): string | undefined {
    if (typeof v !== 'string') {
      return undefined;
    }
    const s = (v as string).trim();
    if (s.length === 6 && /^[0-9a-fA-F]{6}$/.test(s)) {
      return '#' + s.toUpperCase();
    }
    if (s.length === 8 && /^[0-9a-fA-F]{8}$/.test(s)) {
      return '#' + s.substring(0, 6).toUpperCase();
    }
    return undefined;
  }

  runRuntimeCheck(force: boolean = true): void {
    const now = Date.now();
    if (!force && now - this.lastRuntimeCheckMs < 5000) {
      return;
    }
    this.lastRuntimeCheckMs = now;

    const st = this.stats;
    const bs = this.bridge.state;
    this.probeSnapshot();
    this.fetchPrinterDirect();
    // ★ 把 App 自己取到的余额贴回 state.data：
    //   mergeInto 每次都用新对象替换整份 data，余额不在它的合并列表里，
    //   所以必须**每轮重贴**，否则屏幕（读 t.balance）会显示成 '--'。
    this.publishBalance();
    const host = HostStats.get();
    const snap: RuntimeSnapshot = {
      // 直接看 items，不靠 summary 的字符串匹配（那种判据一旦措辞变了就静默失效）
      katPass: this.selfTests.length > 0 && this.selfTests.every((it: TestItem) => it.ok),
      katSummary: this.selfTestSummary,
      usbOpen: st.usbOpen,
      usbLabel: st.usbLabel,
      sent: st.sent,
      errors: st.errors,
      lastAck: this.lastAck,
      // -1 = 从未成功推过；否则是距上次成功推帧的秒数
      pushAgeSec: this.lastOkPushMs > 0 ? Math.round((Date.now() - this.lastOkPushMs) / 1000) : -1,
      bridgeListening: this.bridge.isListening,
      bridgeAgeSec: bs.lastRxTs > 0 ? bs.ageSec() : -1,
      bridgePackets: bs.packets,
      bridgeError: bs.lastError,
      bridgeSource: bs.lastSource,
      snapshotPath: LcdService.SNAPSHOT_URL,
      snapshotOk: this.snapshotProbe.ok,
      snapshotNote: this.snapshotProbe.note,
      vmFrames: this.vmFrames,
      vmErr: this.vmErr,
      hostValid: host.valid,
      hostCpuPct: host.cpuPct,
      hostMemUsedMB: host.memUsedMB,
      hostMemTotalMB: host.memTotalMB
    };
    this.runtimeChecks = RuntimeCheck.run(snap);
    this.runtimeSummary = RuntimeCheck.summary(this.runtimeChecks);
    // ★ 这里**故意不调用 onStatus()**：调用方（runSelfTest / start）会在写完
    //   selfTests 之后再统一刷新。早期版本在这里调了，结果 onStatus → UI.refreshStatus
    //   时读到的 selfTests 还是**刷新前**的值（少一项），体检表里
    //   「协议自检(KAT)」于是误报失败 —— 实测日志就抓到过
    //   `[体检] 4/6 通过｜待查：协议自检(KAT)、数据桥遥测`，而自检明明是 50/50。
    const fails: string[] = [];
    for (const it of this.runtimeChecks) {
      if (!it.ok) {
        fails.push(`${it.name}(${it.detail})`);
      }
    }
    // 带上数据桥那一项的判据数值：万一体检表与 /diag 不一致，日志能立刻指认
    const probe = RuntimeCheck.bridgeProbe(this.runtimeChecks);
    if (fails.length > 0) {
      Logger.w(`[体检] ${this.runtimeSummary}`);
    } else {
      Logger.i(`[体检] ${this.runtimeSummary}`);
    }
    Logger.i(`[体检·数据桥] ${probe}`);
  }

  stop(): void {
    this.running = false;
    if (this.netConn !== null) {
      try {
        // ArkTS 的 NetConnection.unregister 需要传回调
        this.netConn.unregister((err: Object) => {
          if (err !== null && err !== undefined) {
            Logger.w(`注销网络监听失败: ${JSON.stringify(err)}`);
          }
        });
      } catch (e) {
        // ignore
      }
      this.netConn = null;
    }
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    this.bridge.stop();
    this.frameServer.stop();
    this.usb.close();
    Logger.i('LcdService 已停止');
  }

  /** 手动触发一次 USB 连接（用于界面上点「连接屏幕」） */
  async requestUsb(): Promise<boolean> {
    armManualRetry(this.usbState);
    const ok = await this.tryOpenUsb();
    this.onStatus();
    return ok;
  }

  private async tryOpenUsb(): Promise<boolean> {
    if (this.usb.isOpen) {
      return true;
    }
    const dev = LcdUsb.findDevice();
    if (dev === null) {
      this.lastError = '未发现 USB 屏幕（0416:5408）';
      this.usbState.lastAttemptMs = Date.now();
      return false;
    }
    let hasRight = false;
    try {
      hasRight = usbManager.hasRight(dev.name);
    } catch (e) {
      hasRight = false;
      Logger.w(`hasRight 异常: ${Logger.safe(e)}`);
    }
    if (!hasRight && this.usbState.denied >= 2) {
      this.usbState.auto = false;
      this.lastError = 'USB 授权被拒绝，请点「连接屏幕」重新授权';
      return false;
    }
    const info = await this.usb.open();
    if (info !== null) {
      this.lastError = '';
      // 用设备上报的分辨率与旋转角作为目标（界面上的开关仍可手动覆盖）
      noteOpenSuccess(this.usbState);
      // 记住设备报的角度：默认（rotMode=0）就按它转 —— 本机型实测必须 180° 才正。
      this.deviceRotDeg = info.rotateDeg;
      Logger.i(`设备 ${info.toString()} -> 目标 ${info.width}x${info.height}, `
        + `设备报旋转 ${info.rotateDeg}°，当前模式 ${this.rotModeDesc()}（生效旋转 ${this.rotateNow() ? 180 : 0}°）`);
      if (info.rotateDeg !== 0 && info.rotateDeg !== 180) {
        Logger.w(`设备要求 ${info.rotateDeg}° 旋转，本工程仅支持 0/180，已按 0 处理`);
      }
      this.calib = new CalibState(this.canvasVpW, this.canvasVpH);
      this.onStatus();
      return true;
    }
    // ★ 区分两种失败：接口被内核占住（软件解不开，要拔插）vs 一般握手失败。
    //   以前两者都写"握手失败"，屏不在线时看不出真因（实测踩过）。
    this.lastError = this.usb.claimBlocked
      ? 'USB 接口被系统占用（claimInterface=-1）：请拔插一次屏的 USB 线'
      : 'USB 打开/握手失败（详见 hilog: TrofeoLCD）';
    noteOpenFailure(this.usbState, !hasRight, Date.now());
    return false;
  }

  /**
   * 快路径编码：canvas → PixelMap → ImagePacker（原生 JPEG）。
   *
   * 老路径是 ctx.toDataURL('image/jpeg') 拿 base64 字符串再解码成字节 —— 一趟 base64
   * 编码 + 一趟解码全白干（~50ms 里相当一部分花在这）。打包器直接出 ArrayBuffer。
   * 任何一步失败就返回 null，调用方回退老路径（不同 ROM 行为不一致时不会因此黑屏）。
   */
  /**
   * 让出主线程一次，让界面事件插进来（修复"选二次元主题时界面不跟手"）。
   *
   * 帧循环用 setTimeout 跑在 **UI 线程**上，一帧 = 渲染 + 编码(toDataURL 同步) + USB 推送，
   * 合计 120~165ms；主题 10/11/13 每帧都在动（星光/花瓣/扫描线），内容签名每帧都变
   * → 永不跳过 → 主线程被持续占满。这里在阶段之间主动 await timeout(0)，
   * 把"连续独占 150ms"拆成几小段，让 UI 输入能插进来。
   */
  private yieldToUi(): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), 0);
    });
  }

  private async encodeFast(ctx: CanvasRenderingContext2D, quality: number): Promise<Uint8Array | null> {
    try {
      // 上一帧 JPEG 的真实宽高就是画布的像素尺寸（校准后的地面真值）；
      // 首帧还没有时用 vp×密度兜底
      const pxW = this.stats.jpegW > 0 ? this.stats.jpegW : Math.round(this.canvasVpW * this.density);
      const pxH = this.stats.jpegH > 0 ? this.stats.jpegH : Math.round(this.canvasVpH * this.density);
      if (pxW <= 0 || pxH <= 0) {
        return null;
      }
      const pm = ctx.getPixelMap(0, 0, pxW, pxH);
      if (pm === null) {
        return null;
      }
      // ★ 护栏：getPixelMap 的坐标语义在不同 ROM 上不一致（实测本机拿到过 15401x3849 的整块
      // surface，推上去等于黑屏）。这里必须先核对尺寸，不对就放弃快路径并回退。
      const got = pm.getImageInfoSync();
      if (got.size.width !== pxW || got.size.height !== pxH) {
        Logger.w(`快路径取到的尺寸是 ${got.size.width}x${got.size.height}，期望 ${pxW}x${pxH} → 回退`);
        pm.release();
        return null;
      }
      const packer = image.createImagePacker();
      const opt: image.PackingOption = {
        format: 'image/jpeg',
        quality: Math.round(quality * 100)
      };
      const buf = await packer.packing(pm, opt);
      pm.release();
      packer.release();
      return new Uint8Array(buf);
    } catch (e) {
      Logger.w(`快路径编码不可用，回退 toDataURL: ${Logger.safe(e)}`);
      return null;
    }
  }

  /** 一句话摘要文本（空串=没有/取数失败） */
  private summaryText(): string {
    const sm = this.bridge.state.data.summary;
    if (sm === undefined || sm.text === undefined) {
      return '';
    }
    return sm.text;
  }

  /** 余额燃烧速率（元/小时），-1 = 还没攒够采样 */
  burnPerHour(): number {
    const b = this.bridge.state.data.balance;
    return b === undefined || b.perHour === undefined ? -1 : b.perHour;
  }

  /** 按当前速率还能用多少小时，-1 = 算不出来 */
  etaHours(): number {
    const b = this.bridge.state.data.balance;
    return b === undefined || b.etaHours === undefined ? -1 : b.etaHours;
  }

  /** 余额（诊断用）：数据来自桥端 --deepseek-balance，取不到为 -1 */
  private balanceTotal(): number {
    const b = this.currentBalance();
    return b === undefined || b.total === undefined ? -1 : b.total;
  }

  /**
   * 当前余额：**App 自己取的优先**（这样 DSH 不跑时也一直有），
   * 没有才回落到快照/UDP 带来的值。
   */
  private currentBalance(): BalanceInfo | undefined {
    if (this.directBalance !== undefined) {
      return this.directBalance;
    }
    return this.bridge.state.data.balance;
  }

  private balanceCur(): string {
    const b = this.currentBalance();
    return b === undefined || b.currency === undefined ? '' : b.currency;
  }

  private balanceErr(): string {
    const b = this.currentBalance();
    return b === undefined || b.error === undefined ? '' : b.error;
  }

  /**
   * 内容签名：把"会影响画面"的所有输入摘成一行。
   * 刻意排除秒（时钟只画到分钟）、包含 VM 帧计数（画面换了要重推）、
   * 把耗时/帧率这类只影响底部小字的值按"取整后"纳入，避免抖动导致每帧都重推。
   */
  private contentSignature(t: Telemetry, bridgeFresh: boolean): string {
    const ag = t.agent;
    const todo = t.todos === undefined ? 0 : t.todos.length;
    const sys = t.system;
    const pr = t.printer;
    const parts: string[] = [
      ag === undefined ? '-' : `${ag.state}|${ag.activity}|${ag.tool}|${ag.turn}|${ag.step}|${ag.project}|${ag.lastText}`,
      `${todo}`,
      t.tokens === undefined ? '-' : `${t.tokens.todayTotal}|${t.tokens.contextUsed}`,
      sys === undefined ? '-' : `${Math.round(sys.cpu ?? 0)}|${Math.round((sys.memUsed ?? 0) / 64)}|${Math.round(sys.battery ?? -1)}`,
      pr === undefined ? '-' : `${pr.state}|${pr.percent}|${pr.layer}`,
      `${this.vmFrames}|${Math.round(this.vmAge() / 1000)}|${this.vmErr}`,
      // 事件流也要进签名：否则新事件不会触发重推（诊断风主题的核心内容）
      t.events === undefined ? 'ev0' : `ev${t.events.length}:${(t.events[t.events.length - 1]?.s ?? '')}`,
      `bal=${this.balanceTotal()}|${this.balanceErr()}|${this.burnPerHour()}`,
      `sum=${this.summaryText()}`,
      `toast=${this.toast === null ? '-' : this.toast.text}`,
      // 专注时长按 10 秒粒度进签名：秒级变化不必每帧重推
      `focus=${this.focus.startedAt === 0 ? 0 : Math.floor(this.focus.elapsedMs(Date.now()) / 10000)}|${this.focus.pomodoros}`,
      // ★ 长度饱和后就是常数（CAP=90，2 秒一点 → 180 秒后恒为 90），
      //   曲线便不再随时间平移（审计 M5）。补上最新值，让"走势在动"也能触发重推。
      `hist=${this.history.cpu.length},${this.history.cpu.last()},${this.history.balance.last()}`,
      `prn=${Dashboard.printerSubPage()}`,
      // ★ Dotii「贪吃蛇」页（第 5 页）：蛇每 70~170ms 走一格，步数必须进签名，
      //   否则会被"内容未变则跳过"冻住（与 cellPong / face 相位同型的问题）。
      `dotSnake=${(this.dotiiState.page % DOTII_PAGES) === DOTII_SNAKE_PAGE ? ThemeDotii.snakeTick() : -1}`,
      // ★ 门控要覆盖**所有**会画 Dotii 脸的地方（审计 H3）：
      //   原来只判打印机槽 3/4（那是主题 0 的格子），而主题 5 与「打印机格画 Dotii」
      //   也画同一张脸 → 它们的 8 步相位动画只有别的签名项变化时才跳一格，看着是卡住的。
      `face=${(this.theme === 5 || this.dotiiShownInCell()
        || Dashboard.printerSubPage() === 3 || Dashboard.printerSubPage() === 4)
        ? this.dotiiState.expr * 8 + ThemeDotii.exprPhase(Date.now(), this.dotiiState.expr) : -1}`,
      // 打印机格「打砖块」槽（5）：球的运动同样必须进签名，否则"内容未变则跳过"
      // 会把球冻住（与 Dotii 页号、表情相位同型的问题）。
      // 用 tick（与主题 4 那条同一种节奏语义）；名字加 cell 前缀以区别于主题 4 的 pong=。
      `cellPong=${Dashboard.printerSubPage() === 5 && Dashboard.cellPong !== null ? `${Dashboard.cellPong.tick}|${Dashboard.cellPong.bricksBroken}` : '-'}`,
      // 主题 4「打砖块」：每帧都不一样，签名必须带上游戏节拍，
      // 否则球在动而签名不变 → 每帧都被当成"没变化"跳过（实测 skippedFrames 涨到 999、只剩 3fps 心跳帧）
      // ★ 主题 6「固件仿真屏」的时钟屏也画同一套 pongState（球/挡板/砖块），
      //   原来这里只判主题 4 → 主题 6 的球只有 3 秒心跳时才挪一下（审计 H1）。
      // 打印机格「贪吃蛇」槽（6）：与 cellPong 同理，tick 必须进签名，否则蛇会冻住。
      // （槽位本身已由上方的 `prn=` 覆盖，这里不再重复。）
      `snake=${Dashboard.printerSubPage() === 6 && Dashboard.cellSnake !== null ? Dashboard.cellSnake.tick : '-'}`,
      // 主题 16 的全屏蛇：同样必须把 tick 进签名，否则会被"内容未变则跳过"冻住
      `snakeFull=${this.theme === 16 && this.snakeFull !== null ? this.snakeFull.tick : '-'}`,
      // VM 没画面时播的马里奥演示：帧计数器进签名，否则"内容未变"会把游戏冻住
      `mario=${(this.vmPm === null && Dashboard.marioEnabled) ? Dashboard.mario.frame : -1}`,
      `marioFull=${this.theme === 17 ? Dashboard.mario.frame : -1}`,
      // 天气主题：数据版本变了要重画；同时按 250ms 量化动画相位（地球自转/粒子/高亮点）
      `wx=${this.theme === 18 ? this.wx.data.atMs : -1},wxq=${this.theme === 18 ? Math.floor(Date.now() / 250) : -1}`,
      `pong=${(this.theme === 4 || this.theme === 6) && this.pongState !== null
        ? `${this.pongState.tick}|${this.pongState.ballX.toFixed(0)}|${this.pongState.ballY.toFixed(0)}|${this.pongState.bricksBroken}`
        : '-'}`,
      // 待办轮播的节拍也要进签名：否则屏上不会随时间滚动（签名没变 → 跳过重推）
      `carousel=${(t.todos !== undefined && t.todos.length > 2) ? Dashboard.carouselTick() : 0}`,
      `${this.verticalMode}|${this.rotateNow()}|${this.isNightNow()}|${this.theme}|${this.theme === 3 ? this.page : 0}|${(this.theme === 5 || this.dotiiShownInCell()) ? this.dotiiState.page : 0}|${(this.theme === 5 || this.dotiiShownInCell()) ? this.dotiiState.expr : 0}|${this.theme === 6 ? this.fwState.screen : 0}|${this.theme === 7 ? this.trccState.palette : 0}|${ThemeMacTick(this.theme)}`,
      // ★ 时间项：竖装表头（Dashboard.headerV）显示的是 HH:MM:SS，
      //   只带分钟会让**秒数冻住**（签名不变 → 被跳帧挡掉）。
      //   横向表头只到分钟，所以按 verticalMode 决定是否带秒。
      `${new Date().getMinutes()}|${this.verticalMode ? new Date().getSeconds() : 0}`,
      // ★ 主题 10~15 是**时间驱动的动画**（ThemeNanoMuse/Anime*/TrofeoRust 用 500ms 步进、
      //   Theme 15 的 Backdrop 用 250ms），而签名里原来没有任何相位项 →
      //   它们只有 3 秒心跳时才动一下（等效 0.33fps，看着像卡顿/抽搐）。
      `anim=${this.theme >= 10 && this.theme <= 14 ? Math.floor(Date.now() / 500)
        : (this.theme === 15 ? Math.floor(Date.now() / 250) : 0)}`,
      `bsod=${this.bsodUntil > Date.now() ? Math.ceil((this.bsodUntil - Date.now()) / 1000) : 0}`,
      // 跑马灯按 ~12Hz 步进进签名；时间轴按分钟（每分钟才需要重推一次）
      `tk=${this.tickerOn ? Math.floor(Date.now() / 80) : 0}`,
      `tl=${this.timelineOn ? Math.floor(Date.now() / 60000) : 0}`,
      `sp=${this.specOn ? Math.floor(Date.now() / 120) : 0}`,
      // 整点彩条：按秒进签名（每帧滚动的相位由 offset 自己算，这里只需保证窗口切换能重推）
      // ★ 呼吸效果必须按**帧**推进签名：原来这里是 1000ms 粒度，
      //   会把呼吸的中间帧当成"内容未变"直接跳过 → 呼吸变成每秒跳一档。
      //   250ms 与当前帧间隔(≈300ms)对齐，能保证每帧都重推。
      `hb=${this.hourBellLeftMs() > 0 ? Math.floor(Date.now() / 250) : 0}`,
      `rt=${this.retroOn ? 1 : 0}`,
      `${bridgeFresh}`,
      // 注：原为 `${this.skipped === 0 ? 0 : 1}` —— 但 skipped 只增不减，
      //   一旦跳过过一帧该项就恒为 1，等于是个常数，已移除。
    ];
    return parts.join('~');
  }

  /** 实际是否要转 180°（rotMode=0 时看设备握手报的角度） */
  rotateNow(): boolean {
    if (this.rotMode === 1) {
      return true;
    }
    if (this.rotMode === 2) {
      return false;
    }
    return this.deviceRotDeg === 180;
  }

  /** 给界面/日志用的一句话描述 */
  rotModeDesc(): string {
    if (this.rotMode === 1) {
      return '手动：旋转 180°';
    }
    if (this.rotMode === 2) {
      return '手动：不旋转';
    }
    return `自动（跟随设备 ${this.deviceRotDeg}°）`;
  }

  /** 回到自动模式 */
  rotateAuto(): void {
    this.rotMode = 0;
  }

  private targetW(): number {
    const di = this.usb.deviceInfo;
    return di !== null ? di.width : TARGET_W;
  }

  private targetH(): number {
    if (this.frameHeightOverride > 0) {
      return this.frameHeightOverride;
    }
    const di = this.usb.deviceInfo;
    return di !== null ? di.height : TARGET_H;
  }

  private loop(): void {
    if (!this.running) {
      return;
    }
    const tick = () => {
      this.tickStartMs = Date.now();   // 极速模式要用它扣除本帧耗时
      this.tick().then(() => {
        if (!this.running) {
          return;
        }
        const inp = new FrameTickInput();
        inp.theme = this.theme;
        const d = this.bridge.state.data;
        inp.state = (d.agent !== undefined && d.agent.state !== undefined)
          ? d.agent.state : 'unknown';
        inp.night = this.isNightNow();
        inp.errored = this.lastTickErrored;
        const policyMs = nextFrameInterval(inp);
        // 极速模式：间隔 = max(0, 目标间隔 − 本帧耗时)，避免"额外白等一整段间隔"
        // 运行时体检：节流 5 秒（函数内部判定）。只读状态、无副作用。
        // ★ force=false：帧循环每秒都会走到这里，不能每次重算。
        const beforeSummary = this.runtimeSummary;
        this.runRuntimeCheck(false);
        if (this.runtimeSummary !== beforeSummary) {
          this.onStatus();   // 结论有变化才刷界面
        }
        const base = this.forceIntervalMs > 0 ? this.forceIntervalMs : policyMs;
        let waitMs = base;
        if (this.burst && this.tickStartMs > 0) {
          const spent = Date.now() - this.tickStartMs;
          waitMs = Math.max(0, base - spent);
        }
        this.timerId = setTimeout(tick, waitMs);
      }).then(() => {
        this.lastTickErrored = false;
      }).catch((e: Object) => {
        // ★ 用 safe()：这里若二次抛出，下面的重排就永远走不到，帧循环会永久停止
        Logger.e(`帧循环异常: ${Logger.safe(e)}`);
        this.lastTickErrored = true;
        if (this.running) {
          this.timerId = setTimeout(tick, 1000);
        }
      });
    };
    this.timerId = setTimeout(tick, 50);
  }

  /** 是否处于夜间熄屏窗口（跨午夜，由 NightWindow 判定） */
  private isNightNow(): boolean {
    if (!this.nightEnabled) {
      return false;
    }
    const now = new Date();
    return this.nightWin.contains(now.getHours() * 60 + now.getMinutes());
  }

  /** 供界面显示：当前是否处于夜间窗口内 */
  get inNightWindow(): boolean {
    return this.isNightNow();
  }

  /** 最近一次设备应答摘要 */
  get lastAck(): string {
    return this.usb.lastAck;
  }

  /** /status 短摘要 */
  private statusJson(): string {
    const st = this.stats;
    const info = this.usb.deviceInfo;
    return '{'
      + `"state":${jsonStr(this.agentState())}`
      + `,"jpegLimit":${jsonNum(LyProtocol.maxJpegSize())},"jpegW":${jsonNum(st.jpegW)},"jpegH":${jsonNum(st.jpegH)},"jpegBytes":${jsonNum(st.jpegSize)}`
      + `,"sent":${jsonNum(st.sent)},"errors":${jsonNum(st.errors)}`
      + `,"skippedFrames":${jsonNum(st.skippedFrames)},"wsize":${jsonNum(LyProtocol.writeSize)}`
      + `,"tickCount":${jsonNum(this.tickCount)},"bgCount":${jsonNum(EntryAbility.bgCount)},"fgCount":${jsonNum(EntryAbility.fgCount)}`
      + `,"bgMode":"${EntryAbility.bgMode}","bgErr":${jsonStr(EntryAbility.bgErr)}`
      + `,"titleBtn":${jsonStr(EntryAbility.titleBtnNote)}`
      + `,"usbOpen":${jsonBool(this.usb.isOpen)}`
      + `,"bridgeAgeSec":${jsonNum(st.bridgeAge)},"bridgeSource":${jsonStr(this.bridge.state.lastSource)}`
      // ★ 后台排障：这两个是"墙钟毫秒"，用来看帧循环**有没有在跑**。
      //   若 lastOkPushAt 长时间不前进 → 帧循环被系统冻结（app 在后台被挂起），
      //   而不是"在跑但推不出去"（后者 sent 不涨但这两值仍在更新）。
      + `,"lastOkPushAt":${jsonNum(this.lastOkPushMs)},"lastPushAt":${jsonNum(this.lastPushMs)}`
      + `,"nowAt":${jsonNum(Date.now())}`
      // 排障：快照读取失败的具体原因（只有 ok/note 两个字段，便于一眼定位）
      + `,"snapshotOk":${jsonBool(this.snapshotProbe.ok)},"snapshotNote":${jsonStr(this.snapshotProbe.note)}`
      // 直连取数状态（余额/打印机都不依赖 DSH，这里给出可验证的读数）
      + `,"directBalance":${jsonNum(this.balanceTotal())}`
      + `,"directPrinterState":${jsonStr(this.directPrinter === undefined ? '' : (this.directPrinter.state === undefined ? '' : this.directPrinter.state))}`
      + `,"directPrinterTrays":${jsonNum(this.directPrinter === undefined || this.directPrinter.trays === undefined ? -1 : this.directPrinter.trays.length)}`
      + `,"directPrinterPercent":${jsonNum(this.directPrinter === undefined || this.directPrinter.percent === undefined ? -1 : this.directPrinter.percent)}`
      + `,"device":${jsonStr(info === null ? '' : info.toString())}`
      + `,"ack":${jsonStr(this.usb.lastAck)}`
      + `,"wsize":${jsonNum(LyProtocol.writeSize)}`
      + `,"frames":${jsonNum(this.frameServer.frameCount)}`
      + `,"rotate180":${jsonBool(this.rotateNow())},"rotMode":${jsonNum(this.rotMode)},"theme":${jsonNum(this.theme)}`
      + `,"deviceRotDeg":${jsonNum(this.deviceRotDeg)}`
      + `,"vertical":${jsonBool(this.verticalMode)}`
      + `,"night":${jsonBool(this.isNightNow())},"platform":"harmonyos"`
      + `,"vmUrl":${jsonStr(this.vmUrl)}`
      + '}';
  }

  /**
   * /diag 完整诊断：自检结果、端点选择、设备描述符、握手解析、ACK、帧统计。
   * 目的是"把证据做成可远程读取的"，因为本沙箱读不到系统日志。
   */
  diagJson(): string {
    const st = this.stats;
    const info = this.usb.deviceInfo;
    let pass = 0;
    const fails: string[] = [];
    for (const it of this.selfTests) {
      if (it.ok) {
        pass++;
      } else {
        fails.push(`${it.name}: ${it.detail}`);
      }
    }
    let f = '';
    for (let i = 0; i < fails.length; i++) {
      if (i > 0) {
        f += ',';
      }
      f += jsonStr(fails[i]);
    }
    let dump = '';
    for (let i = 0; i < this.usb.deviceDump.length; i++) {
      if (i > 0) {
        dump += ',';
      }
      dump += jsonStr(this.usb.deviceDump[i]);
    }
    return '{'
      + `"running":${jsonBool(this.running)}`
      + `,"bgTask":${jsonBool(this.bgTask)}`
      + `,"selfTest":${jsonStr(`${pass}/${this.selfTests.length}`)}`
      + `,"selfTestAllPass":${jsonBool(pass === this.selfTests.length)}`
      + `,"selfTestFails":[${f}]`
      + `,"usbOpen":${jsonBool(this.usb.isOpen)}`
      + `,"deviceLabel":${jsonStr(this.usb.deviceLabel)}`
      + `,"deviceInfo":${jsonStr(info === null ? '' : info.toString())}`
      + `,"endpoint":${jsonStr(this.usb.endpointSummary)}`
      + `,"rotate180":${jsonBool(this.rotateNow())},"rotMode":${jsonNum(this.rotMode)},"theme":${jsonNum(this.theme)}`
      + `,"deviceRotDeg":${jsonNum(this.deviceRotDeg)}`
      + `,"vertical":${jsonBool(this.verticalMode)},"vmUrl":${jsonStr(this.vmUrl)}`
      + `,"rotateDeg":${jsonNum(info === null ? -1 : info.rotateDeg)}`
      + `,"night":${jsonBool(this.isNightNow())},"platform":"harmonyos"`
      + `,"canvasVpW":${jsonNum(this.canvasVpW)},"canvasVpH":${jsonNum(this.canvasVpH)}`
      + `,"jpegLimit":${jsonNum(LyProtocol.maxJpegSize())},"jpegW":${jsonNum(st.jpegW)},"jpegH":${jsonNum(st.jpegH)},"jpegBytes":${jsonNum(st.jpegSize)}`
      + `,"sent":${jsonNum(st.sent)},"errors":${jsonNum(st.errors)},"fps":${jsonNum(st.fps)}`
      + `,"forceIntervalMs":${jsonNum(this.forceIntervalMs)},"burst":${jsonBool(this.burst)},"tickSpentMs":${jsonNum(this.tickStartMs > 0 ? Date.now() - this.tickStartMs : 0)}`
      + `,"pipe":${jsonBool(this.pipelinePush)},"pushBusy":${jsonBool(this.pushBusy)}`
      + `,"tickMs":${jsonNum(this.stats.tickMs)},"tickGapMs":${jsonNum(this.stats.tickGapMs)}`
      + `,"vig":${jsonNum(this.vignette)},"vigreach":${jsonNum(this.vignetteReach)}`
      + `,"buildTag":"r9-cellmode"`
      + `,"usbOpenCount":${jsonNum(LcdUsb.openCount)},"winW":${jsonNum(EntryAbility.curW)},"winH":${jsonNum(EntryAbility.curH)},"winNote":${jsonStr(EntryAbility.resizeNote)},"bgStyle":${jsonNum(Backdrop.style as number)},"bgDim":${jsonNum(Backdrop.dimPct)},"bgImg":${jsonBool(Backdrop.image !== null)},"bgImgNote":${jsonStr(Backdrop.imageNote)},"dbgLastTheme":${jsonNum(Dashboard.dbgLastTheme)},"frameHeartbeatMs":${jsonNum(LcdService.FRAME_HEARTBEAT_MS)},"printerCell":${jsonStr(this.printerCell)},"vmSrcW":${jsonNum(Dashboard.dbgVmSrcW)},"vmSrcH":${jsonNum(Dashboard.dbgVmSrcH)},"vmInW":${jsonNum(Dashboard.dbgVmInnerW)},"vmInH":${jsonNum(Dashboard.dbgVmInnerH)},"vmDw":${jsonNum(Dashboard.dbgVmDrawW)},"vmDh":${jsonNum(Dashboard.dbgVmDrawH)}`
      + `,"scaleX":${jsonNum(this.scaleX)},"scaleY":${jsonNum(this.scaleY)},"tW":${jsonNum(this.targetW())},"tH":${jsonNum(this.targetH())},"density":${jsonNum(this.density)}`
      + `,"dbgUsX":${jsonNum(Dashboard.dbgUsX)},"dbgUsW":${jsonNum(Dashboard.dbgUsW)},"dbgAgentW":${jsonNum(Dashboard.dbgAgentW)},"dbgCellMode":${jsonNum(Dashboard.dbgCellMode)}`
      + `,"usbClaimBlocked":${jsonBool(this.usb.claimBlocked)}`

      // 运行锁状态（熄屏保活的关键读数：held=false 说明熄屏仍会停推）
      + `,"lockHeld":${jsonBool(RunningLock.held)},"lockErr":${jsonStr(RunningLock.err)},"lockType":${jsonStr(RunningLock.typeName)}`
      + `,"lockSupport":${jsonStr(RunningLock.supportNote)}`
      // Dotii 页/表情：验证"轮播是否真的在翻"（签名漏掉它们就会被跳帧挡掉）
      + `,"prnSub":${jsonNum(Dashboard.printerSubPage())},"dotiiPage":${jsonNum(this.dotiiState.page)},"dotiiExpr":${jsonNum(this.dotiiState.expr)},"dotiiInCell":${jsonBool(this.dotiiShownInCell())}`
      + `,"marioScreen":${jsonStr(this.vmPm === null ? Dashboard.mario.screen() : "vm-on")},"marioPlayer":${jsonStr(this.vmPm === null ? Dashboard.mario.playerInfo() : "")},"ringBreath":${jsonNum(Math.round(Overlay.ringBreathValue * 100))},"ringPhase":${jsonNum(Math.floor(Date.now() / 300) * Overlay.ringStepDeg % 360)},"cellPongClock":${jsonNum(Dashboard.cellPong === null ? -1 : (Dashboard.cellPong.hour * 100 + Dashboard.cellPong.minute))},"cellPongTick":${jsonNum(Dashboard.cellPong === null ? -1 : Dashboard.cellPong.tick)},"pongTick":${jsonNum(this.pongState === null ? -1 : this.pongState.tick)},"usbShortWrites":${jsonNum(LcdUsb.shortWrites)},"usbResetTries":${jsonNum(LcdUsb.resetTries)},"netEvents":${jsonNum(this.netEvents)},"netIface":${jsonStr(this.netLastIface)},"netIp":${jsonStr(this.netLastIp)}`
      + `,"frh":${jsonNum(this.targetH())},"frhOverride":${jsonNum(this.frameHeightOverride)}`
      + `,"renderErrors":${jsonNum(this.stats.renderErrors)}`
      + `,"vmAgeMs":${jsonNum(this.vmAge())}`
      + this.seqDiagJson()
      + `,"pushSkip":${jsonNum(this.pushSkip)},"wbatch":${jsonNum(LcdUsb.writeBatch)}`
      + `,"animSplit":${jsonStr(ThemeAnime.dbgSplit.join(","))},"renderMs":${jsonNum(st.renderMs)},"encodeMs":${jsonNum(st.encodeMs)}`
      + `,"pushMs":${jsonNum(st.pushMs)},"quality":${jsonNum(st.quality)}`
      + `,"skippedFrames":${jsonNum(st.skippedFrames)},"wsize":${jsonNum(LyProtocol.writeSize)}`
      + `,"tickCount":${jsonNum(this.tickCount)},"bgCount":${jsonNum(EntryAbility.bgCount)},"fgCount":${jsonNum(EntryAbility.fgCount)}`
      + `,"bgMode":"${EntryAbility.bgMode}","bgErr":${jsonStr(EntryAbility.bgErr)}`
      + `,"titleBtn":${jsonStr(EntryAbility.titleBtnNote)}`
      + `,"ack":${jsonStr(this.usb.lastAck)}`
      + `,"bridgeAgeSec":${jsonNum(st.bridgeAge)},"bridgeSource":${jsonStr(this.bridge.state.lastSource)}`
      // ★ 后台排障：这两个是"墙钟毫秒"，用来看帧循环**有没有在跑**。
      //   若 lastOkPushAt 长时间不前进 → 帧循环被系统冻结（app 在后台被挂起），
      //   而不是"在跑但推不出去"（后者 sent 不涨但这两值仍在更新）。
      + `,"lastOkPushAt":${jsonNum(this.lastOkPushMs)},"lastPushAt":${jsonNum(this.lastPushMs)}`
      + `,"nowAt":${jsonNum(Date.now())}`
      // 排障：快照读取失败的具体原因（只有 ok/note 两个字段，便于一眼定位）
      + `,"snapshotOk":${jsonBool(this.snapshotProbe.ok)},"snapshotNote":${jsonStr(this.snapshotProbe.note)}`
      // 直连取数状态（余额/打印机都不依赖 DSH，这里给出可验证的读数）
      + `,"directBalance":${jsonNum(this.balanceTotal())}`
      + `,"directPrinterState":${jsonStr(this.directPrinter === undefined ? '' : (this.directPrinter.state === undefined ? '' : this.directPrinter.state))}`
      + `,"directPrinterTrays":${jsonNum(this.directPrinter === undefined || this.directPrinter.trays === undefined ? -1 : this.directPrinter.trays.length)}`
      + `,"directPrinterPercent":${jsonNum(this.directPrinter === undefined || this.directPrinter.percent === undefined ? -1 : this.directPrinter.percent)}`
      + `,"usbDenied":${jsonNum(this.usbState.denied)},"usbAutoRetry":${jsonBool(this.usbState.auto)}`
      + `,"lastError":${jsonStr(this.lastError)}`
      + `,"frameUrl":${jsonStr(this.frameServer.url)}`
      + `,"vmFrames":${jsonNum(this.vmFrames)},"vmAgeMs":${jsonNum(this.vmAge())}`
      + `,"vmErr":${jsonStr(this.vmErr)},"vmSize":${jsonStr(this.vmSizeText())}`
      + `,"balanceTotal":${jsonNum(this.balanceTotal())},"balanceCur":${jsonStr(this.balanceCur())}`
      + `,"evCount":${jsonNum(this.bridge.state.data.events === undefined ? -1 : (this.bridge.state.data.events as BridgeEvent[]).length)}`
      + `,"summaryText":${jsonStr(this.summaryText())}`
      + `,"burnPerHour":${jsonNum(this.burnPerHour())},"etaHours":${jsonNum(this.etaHours())}`
      + `,"toast":${jsonStr(this.toast === null ? '' : this.toast.text)}`
      + `,"focusMs":${jsonNum(this.focus.elapsedMs(Date.now()))},"pomodoros":${jsonNum(this.focus.pomodoros)}`
      + `,"histCpu":${jsonNum(this.history.cpu.length)},"bg":${jsonBool(this.bgPm !== null)}`
      + `,"themeRotateSec":${jsonNum(this.themeRotateSec)},"page":${jsonNum(this.page)},"pageRotateSec":${jsonNum(this.pageRotateSec)}`
      + `,"balanceErr":${jsonStr(this.balanceErr())}`
      + `,"deviceDump":[${dump}]`
      + '}';
  }

  /**
   * 远程设置（仅 127.0.0.1）。
   * 例：/set?vertical=1&rotate180=0&night=1
   * 用途：不点界面也能切换横竖屏/旋转/夜间，便于自动化验证与排障。
   */
  private applySettings(query: string): string {
    const applied: string[] = [];
    if (query.length > 0) {
      for (const kv of query.split('&')) {
        const i = kv.indexOf('=');
        if (i <= 0) {
          continue;
        }
        const k = kv.substring(0, i);
        const on = kv.substring(i + 1) === '1';
        if (k === 'vmurl') {
          // 地址不是布尔：原样收下（空值表示恢复默认）
          const raw = decodeURIComponent(kv.substring(i + 1)).trim();
          this.vmUrl = raw.length > 0 ? raw : VM_FRAME_URL_DEFAULT;
        } else if (k === 'vertical') {
          this.verticalMode = on;
        } else if (k === 'theme') {
          const n = Number(kv.substring(i + 1));
          // ★ 走唯一写入口（它内部置 themeTouched、清签名、重置轮播计时）
          this.setTheme(n, true);
        } else if (k === 'page') {
          const n = Number(kv.substring(i + 1));
          this.page = (n >= 0 && n < ThemePages.PAGE_COUNT) ? n : 0;
          this.lastPageSwitch = Date.now();
        } else if (k === 'pagerot') {
          this.pageRotateSec = Math.max(0, Number(kv.substring(i + 1)));
        } else if (k === 'vigcorner') {
          const n = Number(kv.substring(i + 1));
          this.vigCornerForce = (n >= 0 && n <= 3) ? n : -1;
          applied.push(`vigcorner=${n}`);
          continue;
        } else if (k === 'vigall') {
          this.vigAll = (Number(kv.substring(i + 1)) !== 0);
          applied.push(`vigall=${this.vigAll ? 1 : 0}`);
          continue;
        } else if (k === 'vig') {
          // vig=0..100：右下角漏光补偿强度（0 = 关）
          const n = Number(kv.substring(i + 1));
          this.vignette = (n >= 0 && n <= 100) ? n / 100 : 0.5;
          applied.push(`vig=${Math.round(this.vignette * 100)}`);
          continue;
        } else if (k === 'vigreach') {
          const n = Number(kv.substring(i + 1));
          this.vignetteReach = (n >= 100 && n <= 2000) ? n : 620;
          applied.push(`vigreach=${this.vignetteReach}`);
          continue;
        } else if (k === 'pipe') {
          // pipe=0 关流水线（回到"编码完就同步推、等它完成"），=1 开
          this.pipelinePush = (Number(kv.substring(i + 1)) !== 0);
          applied.push(`pipe=${this.pipelinePush ? 1 : 0}`);
          continue;
        } else if (k === 'wbatch') {
          // wbatch=N：一帧内并发派发多少个 4KB 写（1 = 逐个 await）
          const n = Number(kv.substring(i + 1));
          // ★ 上限从 16 收到 **4**（2026-10-20 事故）：实测 wbatch=8/12 会把 USB OUT
          //   端点打进错误态（bulkTransfer 恒 -1，而 claimInterface 仍返回 0），
          //   只能靠 resetDevice 自愈或拔插。并发写本来也没有可测量的帧率收益。
          LcdUsb.writeBatch = (n >= 1 && n <= 4) ? Math.floor(n) : 4;
          applied.push(`wbatch=${LcdUsb.writeBatch}`);
          continue;
        } else if (k === 'seq') {
          // 预烘焙序列：seq=<base url> 开始播放；seq=off / 空值 停止
          const raw = decodeURIComponent(kv.substring(i + 1)).trim();
          if (raw.length === 0 || raw === 'off' || raw === '0') {
            this.stopSeq('手动 /set?seq=off');
            applied.push('seq=off');
          } else {
            applied.push(`seq=${this.startSeqLoad(raw)}`);
          }
          continue;
        } else if (k === 'seqfps') {
          const n = Number(kv.substring(i + 1));
          this.seqFpsOverride = (n > 0 && n <= 60) ? n : 0;
          this.applySeqInterval();
          applied.push(`seqfps=${this.seqFpsOverride}`);
          continue;
        } else if (k === 'seqlimit') {
          const n = Number(kv.substring(i + 1));
          this.seqLimitOverride = (n >= 0 && n <= 480) ? Math.floor(n) : 0;
          applied.push(`seqlimit=${this.seqLimitOverride}`);
          continue;
        } else if (k === 'seqstream') {
          this.seqStream = on;
          applied.push(`seqstream=${this.seqStream ? 1 : 0}`);
          continue;
        } else if (k === 'seqburst') {
          this.seqBurst = on;
          this.applySeqInterval();
          applied.push(`seqburst=${this.seqBurst ? 1 : 0}`);
          continue;
        } else if (k === 'seqwin') {
          const n = Number(kv.substring(i + 1));
          this.seqWin = (n >= SEQ_MIN_WIN && n <= SEQ_MAX_WIN) ? Math.floor(n) : 0;
          applied.push(`seqwin=${this.seqWin}`);
          continue;
        } else if (k === 'wsize') {
          // ★ 上限 4096：实测 8192 会让 bulkTransfer 进错误态（端点挂、diag 都不响应）。
          //   单次传输上限由端点/HAL 决定，不是越大越好。
          const n = LyProtocol.setWriteSize(Math.min(4096, Number(kv.substring(i + 1))));
          applied.push(`wsize=${n}`);
          continue;
        } else if (k === 'q') {
          const q = Number(kv.substring(i + 1));
          if (q >= 0.4 && q <= 1) {
            this.encodeQuality = q;
          }
        } else if (k === 'printerCell') {
          // 第一屏打印机格显示什么：printer（真打印机卡）/ dotii（Dotii 内容）
          const v = kv.substring(i + 1).trim().toLowerCase();
          if (v === 'dotii' || v === 'printer' || v === 'v4' || v === 'v6') {
            // ★ 走唯一写入口（它内部置 printerCellTouched 并清签名）
            this.setPrinterCell(v, true);
            applied.push(`printerCell=${v}`);
          }
          continue;
        } else if (k === 'slap') {
          // 扫掠一圈时长（毫秒），2000~60000
          const n = Number(kv.substring(i + 1));
          if (Number.isFinite(n) && n >= 2000 && n <= 60000) {
            this.sweepLapMs = Math.round(n);
            this.lastSig = '';
            applied.push(`slap=${this.sweepLapMs}`);
          }
          continue;
        } else if (k === 'sthk') {
          // 扫掠线宽（px），2~16
          const n = Number(kv.substring(i + 1));
          if (Number.isFinite(n) && n >= 2 && n <= 16) {
            this.sweepThick = Math.round(n);
            this.lastSig = '';
            applied.push(`sthk=${this.sweepThick}`);
          }
          continue;
        } else if (k === 'sweep') {
          // 边框扫掠：0=关 1=只天气主题 2=所有主题
          const n = Number(kv.substring(i + 1));
          this.sweepOn = n > 0;
          this.sweepForce = n === 2;
          this.lastSig = '';
          applied.push(`sweep=${n}`);
          continue;
        } else if (k === 'wlat' || k === 'wlon' || k === 'wcity') {
          // 天气城市：三个参数可单独给，最后一次性设进去
          const val = kv.substring(i + 1).trim();
          if (k === 'wcity') {
            this.wx.setPlace(decodeURIComponent(val), this.wx.data.lat, this.wx.data.lon);
          } else if (k === 'wlat') {
            this.wx.setPlace('', Number(val), this.wx.data.lon);
          } else {
            this.wx.setPlace('', this.wx.data.lat, Number(val));
          }
          this.wx.forceRefresh();
          this.lastSig = '';
          applied.push(`${k}`);
          continue;
        } else if (k === 'wx') {
          // 强制刷新天气
          this.wx.forceRefresh();
          this.lastSig = '';
          applied.push('wx');
          continue;
        } else if (k === 'mview') {
          // 超级玛丽全屏主题的缩放倍率（1..4）：2 → 960×231（竖向 7.2 格）
          const n = Number(kv.substring(i + 1));
          if (n >= 1 && n <= 4) {
            MarioDemo.viewScale = Math.round(n);
            this.lastSig = '';
            applied.push(`mview=${MarioDemo.viewScale}`);
          }
          continue;
        } else if (k === 'mario') {
          // VM 没画面时是否播超级玛丽演示：/set?mario=0 关
          Dashboard.marioEnabled = kv.substring(i + 1).trim() !== '0';
          this.lastSig = '';
          applied.push(`mario=${Dashboard.marioEnabled ? 1 : 0}`);
          continue;
        } else if (k === 'ringfx') {
          // 彩虹条效果：breath=呼吸（默认，低帧率最好看） scroll=滚动
          const fx = kv.substring(i + 1).trim().toLowerCase();
          Overlay.ringFxBreath = fx !== 'scroll';
          this.lastSig = '';
          applied.push(`ringfx=${Overlay.ringFxBreath ? 'breath' : 'scroll'}`);
          continue;
        } else if (k === 'ringbreath') {
          // 呼吸周期（毫秒）：/set?ringbreath=3600
          const bms = parseInt(kv.substring(i + 1).trim(), 10);
          if (bms >= 800 && bms <= 20000) {
            Overlay.ringBreathMs = bms;
          }
          this.lastSig = '';
          applied.push(`ringbreath=${Overlay.ringBreathMs}ms`);
          continue;
        } else if (k === 'ringdeg') {
          // 彩虹条每步推进的色相（度）：越小越慢越顺；默认 24
          const dg = parseInt(kv.substring(i + 1).trim(), 10);
          if (dg >= 4 && dg <= 120) {
            Overlay.ringStepDeg = dg;
          }
          this.lastSig = '';
          applied.push(`ringdeg=${Overlay.ringStepDeg}`);
          continue;
        } else if (k === 'ringband') {
          // 彩虹带粗细（像素）：/set?ringband=68
          const bw = parseInt(kv.substring(i + 1).trim(), 10);
          if (bw >= 8 && bw <= 160) {
            this.ringBand = bw;
          }
          this.lastSig = '';
          applied.push(`ringband=${this.ringBand}`);
          continue;
        } else if (k === 'hbtest') {
          // 调试用：不用等到整点就能看彩条效果（/set?hbtest=20 → 强制 20 秒）
          const sec = parseInt(kv.substring(i + 1).trim(), 10);
          const ms = (sec > 0 ? sec : 0) * 1000;
          this.hourBellForceUntil = ms > 0 ? Date.now() + ms : 0;
          this.lastSig = '';
          applied.push(`hbtest=${ms > 0 ? sec : 0}s`);
          continue;
        } else if (k === 'hourbell') {
          this.hourBellOn = kv.substring(i + 1).trim() !== '0';
          this.lastSig = '';
          applied.push(`hourbell=${this.hourBellOn ? 1 : 0}`);
          continue;
        } else if (k === 'spec') {
          this.specOn = kv.substring(i + 1).trim() === '1';
          if (this.specOn && this.specBuf.length === 0) {
            this.specBuf = new Array<number>(96);
            for (let j = 0; j < 96; j++) {
              this.specBuf[j] = 0;
            }
          }
          this.lastSig = '';
          applied.push(`spec=${this.specOn ? 1 : 0}`);
          continue;
        } else if (k === 'retro') {
          this.retroOn = kv.substring(i + 1).trim() === '1';
          this.lastSig = '';
          applied.push(`retro=${this.retroOn ? 1 : 0}`);
          continue;
        } else if (k === 'ticker') {
          this.tickerOn = kv.substring(i + 1).trim() === '1';
          this.lastSig = '';
          applied.push(`ticker=${this.tickerOn ? 1 : 0}`);
          continue;
        } else if (k === 'timeline') {
          this.timelineOn = kv.substring(i + 1).trim() === '1';
          this.lastSig = '';
          applied.push(`timeline=${this.timelineOn ? 1 : 0}`);
          continue;
        } else if (k === 'bgurl') {
          // ★ 自定义壁纸（用户 2026-10-19 要的）：抓图 fetchBgImage() 与 Backdrop 的
          //   image 模式早就写好了，但**一直没有参数能设置 URL**（死字段）。
          //   这里接上：传 URL 即拉图并切到 image 模式；传空串则清空。
          //   用法：/set?bgurl=https://…/a.jpg
          const u = kv.substring(i + 1).trim();
          this.bgUrl = u;
          this.bgPm = null;
          this.bgTried = 0;
          Backdrop.image = null;
          Backdrop.imageNote = '';
          if (u.length > 0) {
            void this.fetchBgImage();
            Backdrop.style = BgStyle.Image;
          }
          this.lastSig = '';
          applied.push(`bgurl=${u.length > 48 ? u.substring(0, 48) + '…' : u}`);
          continue;
        } else if (k === 'background') {
          // 背景特效：none | plasma | aurora | lava | waves
          // （复刻 trofeo-lcd-rs 的 `background_effect`，见 render/Backdrop.ets）
          const bsName = kv.substring(i + 1).trim().toLowerCase();
          Backdrop.style = bgStyleFromName(bsName);
          this.lastSig = '';        // 强制重画
          applied.push(`background=${bsName}`);
          continue;
        } else if (k === 'profile') {
          // 速度/画质档位：一条命令同时调好质量与节流，避免用户逐个试参数。
          // ★ 依据是本机实测（docs/质量曲线.md）：
          //   帧时间 = encode(58~68ms，取决于**像素量**、与质量无关) + push(34~47ms)
          //   → 降质量只能碰到 push 那一小半，q=0.95→0.6 的帧率收益仅 +13%
          //   → 且 q<0.8 疑似会触发编码慢路径（待空闲机复核），故 speed 档停在 0.8
          const pv2 = kv.substring(i + 1).trim().toLowerCase();
          if (pv2 === 'speed') {
            this.encodeQuality = 0.8;
            this.burst = true;
            applied.push('profile=speed(q0.8+burst)');
          } else if (pv2 === 'balanced') {
            this.encodeQuality = 0.9;
            this.burst = true;
            applied.push('profile=balanced(q0.9+burst)');
          } else if (pv2 === 'quality') {
            this.encodeQuality = 0.95;
            this.burst = false;
            applied.push('profile=quality(q0.95)');
          } else {
            applied.push(`profile=${pv2}?（有效值 speed|balanced|quality）`);
          }
          continue;
        } else if (k === 'burst') {
          // 极速模式：间隔扣除本帧耗时（见 burst 字段注释）
          this.burst = (kv.substring(i + 1).trim() === '1');
          applied.push(`burst=${this.burst ? 1 : 0}`);
          continue;
        } else if (k === 'bgdim') {
          // 压暗 0..100（对应它的 `--background-dim`，默认 40）
          const dv = Number(kv.substring(i + 1));
          if (!Number.isNaN(dv)) {
            Backdrop.dimPct = Math.max(0, Math.min(100, Math.round(dv)));
            this.lastSig = '';
            applied.push(`bgdim=${Backdrop.dimPct}`);
          }
          continue;
        } else if (k === 'usbreset') {
          // 立刻重试一次 USB 打开（不等 5 秒重试节流）。注意：如果 claimInterface
          // 仍返回 -1，说明占用在内核侧，只能拔插 USB 线 —— 这里会如实上报。
          this.usbRetryTs = 0;
          this.usb.close();
          applied.push('usbreset');
          continue;
        } else if (k === 'trcc') {
          // trcc=N：官方浅色风配色（0..4）；N<0 或省略 = 自动轮换
          const n = Number(kv.substring(i + 1));
          this.trccState.palette = (n >= 0 && n < TRCC_THEME_COUNT) ? n : -1;
          this.trccAutoAt = Date.now();
          applied.push(`trcc=${this.trccState.palette}`);
          continue;
        } else if (k === 'fws') {
          // fws=N：固件仿真屏当前界面（0..17，见 display_ui.h 的 enum）
          const n = Number(kv.substring(i + 1));
          if (n >= 0 && n < FW_SCREEN_COUNT) {
            this.fwState.screen = n;
            this.fwAuto = false;
            applied.push(`fws=${n}`);
          }
          continue;
        } else if (k === 'fwsauto') {
          this.fwAuto = (Number(kv.substring(i + 1)) !== 0);
          this.fwAutoAt = Date.now();
          applied.push(`fwsauto=${this.fwAuto ? 1 : 0}`);
          continue;
        } else if (k === 'dspage') {
          // 贪吃蛇页的保留时长（毫秒）：/set?dspage=60000
          const n = Number(kv.substring(i + 1));
          if (n >= 3000 && n <= 600000) {
            this.dotiiSnakePageMs = n;
            this.lastSig = '';
            applied.push(`dspage=${n}ms`);
          }
          continue;
        } else if (k === 'dpage') {
          // 主题 5：定点到第 N 页，并把两个自动计时器重置（便于逐页截图核对）
          const n = Number(kv.substring(i + 1));
          if (n >= 0 && n < DOTII_PAGES) {
            this.dotiiState.page = n;
            this.dotiiPageAt = Date.now();
            this.dotiiExprAt = Date.now();
            applied.push(`dpage=${n}`);
          }
          continue;
        } else if (k === 'frh') {
          // frh=<480|0>：覆盖推帧高度（0 = 用设备握手值）。改完会触发画布重校准。
          const n = Number(kv.substring(i + 1));
          this.frameHeightOverride = (n >= 400 && n <= 600) ? Math.floor(n) : 0;
          this.calib = new CalibState(this.canvasVpW, this.canvasVpH);
          applied.push(`frh=${this.frameHeightOverride > 0 ? this.frameHeightOverride : 'auto'}`);
          continue;
        } else if (k === 'fps') {
          // fps=<Hz>：强制推帧频率（0 = 回到策略）。
          // ★ 硬护栏：一帧真实成本约 110ms（render+encode+push），把间隔压到远小于它
          //   并不会更快，只会把 USB 批量端点灌到错误态（实测过一次：bulkTransfer 返回 -1，
          //   屏黑、连 /diag 都没响应，只能 force-stop 重开应用才恢复）。
          //   所以这里下限钉在 120ms（≈8fps）——正好是实测天花板，再快没意义还危险。
          const hz = Number(kv.substring(i + 1));
          const want = hz > 0 ? Math.round(1000 / hz) : 0;
          this.forceIntervalMs = hz > 0 ? Math.max(LcdService.MIN_PUSH_INTERVAL_MS, want) : 0;
          applied.push(`fps=${hz > 0 ? Math.round(1000 / this.forceIntervalMs) : 'auto'}`);
          continue;
        } else if (k === 'rot') {
          // rot=auto|on|off —— 便于自动化验证"自动"模式
          const v = kv.substring(i + 1);
          this.rotMode = v === 'auto' ? 0 : (v === 'on' ? 1 : 2);
        } else if (k === 'rotate180') {
          // 手动覆盖：1=强制转，0=强制不转（与"自动"区分开）
          this.rotMode = on ? 1 : 2;
        } else if (k === 'night') {
          this.nightEnabled = on;
        } else if (k === 'run') {
          if (on) {
            this.start();
          } else {
            this.stop();
          }
        } else {
          continue;
        }
        applied.push(k);
      }
    }
    this.onStatus();
    return '{'
      + `"applied":[${applied.map((x: string) => jsonStr(x)).join(',')}]`
      + `,"vertical":${jsonBool(this.verticalMode)}`
      + `,"rotate180":${jsonBool(this.rotateNow())},"rotMode":${jsonNum(this.rotMode)},"theme":${jsonNum(this.theme)}`
      + `,"night":${jsonBool(this.nightEnabled)}`
      + `,"running":${jsonBool(this.running)}`
      + '}';
  }

  private vmSizeText(): string {
    if (this.vmPm === null) {
      return '';
    }
    try {
      const info = this.vmPm.getImageInfoSync();
      return `${info.size.width}x${info.size.height}`;
    } catch (e) {
      return '';
    }
  }

  /** /probe：主动扫一次 USB 并尝试打开，返回设备是否出现 */
  async probeJson(): Promise<string> {
    const dev = LcdUsb.findDevice();
    const found = dev !== null;
    let label = '';
    let name = '';
    if (dev !== null) {
      label = `${dev.productName} (${dev.vendorId.toString(16)}:${dev.productId.toString(16)})`;
      name = dev.name;
    }
    if (found && !this.usb.isOpen) {
      armManualRetry(this.usbState);
      await this.tryOpenUsb();
    }
    const info = this.usb.deviceInfo;
    return '{'
      + `"found":${jsonBool(found)}`
      + `,"label":${jsonStr(label)}`
      + `,"name":${jsonStr(name)}`
      + `,"usbOpen":${jsonBool(this.usb.isOpen)}`
      + `,"deviceInfo":${jsonStr(info === null ? '' : info.toString())}`
      + `,"endpoint":${jsonStr(this.usb.endpointSummary)}`
      + `,"ack":${jsonStr(this.usb.lastAck)}`
      + `,"lastError":${jsonStr(this.lastError)}`
      + '}';
  }

  private agentState(): string {
    const d = this.bridge.state.data;
    if (d.agent !== undefined && d.agent.state !== undefined) {
      return d.agent.state;
    }
    return 'unknown';
  }

  /** 远程预览地址（外部可 curl 当前帧） */
  get frameUrl(): string {
    return this.frameServer.url;
  }

  get frameCount(): number {
    return this.frameServer.frameCount;
  }

  /**
   * 全局当前实例（供生命周期钩子调用）。
   * 起因（实测）：**点最小化**会触发 onBackground，随后整个 JS 事件循环被系统冻结
   * （setTimeout 不回调、HTTP 也不响应）；而内容签名未变时最多要等 3 秒心跳
   * 才会补帧。所以从后台恢复时要**立刻补一帧**，把这段空窗压到毫秒级。
   */
  static active: LcdService | null = null;

  /**
   * 立刻推一帧（前台恢复时调用）。
   * 清掉两个签名缓存，保证下一次 tick 不会被"内容没变"跳过。
   */
  /**
   * 由生命周期钩子设置后台状态。进后台关闭跳帧以维持传输速率，
   * 回前台恢复跳帧并立刻补一帧。
   */
  setBackgrounded(v: boolean): void {
    if (this.backgrounded === v) {
      return;
    }
    this.backgrounded = v;
    Logger.i(`[bg] backgrounded=${v}（${v ? '关闭跳帧维持速率' : '恢复跳帧'}）`);
    if (!v) {
      this.forceRefresh('回到前台');
    }
  }

  forceRefresh(reason: string): void {
    // 清两个签名缓存：`lastSig` 是"上一次的签名"，不清的话 tick 会判定
    // "内容没变"直接跳过，补帧就白补了。`lastPushMs` 归零则绕过心跳间隔判断。
    this.lastSig = '';
    this.pendingSig = '';
    this.lastPushMs = 0;
    Logger.i(`[recover] ${reason} → 清签名并立刻补一帧`);
    if (!this.running || this.pushBusy) {
      return;
    }
    void this.tick().catch((e: Object) => {
      Logger.w(`[recover] 补帧失败: ${Logger.safe(e)}`);
    });
  }

  private async tick(): Promise<void> {
    // ★ 帧循环心跳（插在 tick 最开头，保证每次调用都计到）。
    //   我第一版插在 `setTimeout(tick, 50)` 前 —— 那是**启动路径**才走的分支，
    //   结果 tickCount 恒为 1，看着像"循环死了"，其实是仪表插错地方。
    //   正确读法：tickCount 持续增长 ⇒ 事件循环活着；停止增长 ⇒ 被冻结。
    this.tickCount++;
    this.stats.tickCount = this.tickCount;
    if (Date.now() - this.lastTickLogMs > 30000) {
      this.lastTickLogMs = Date.now();
      Logger.i(`[frame] tick 存活 tickCount=${this.tickCount} sent=${this.stats.sent} skipped=${this.skipped}`);
    }
    const tTick0 = Date.now();
    this.stats.tickGapMs = this.lastTickStartMs > 0 ? (tTick0 - this.lastTickStartMs) : 0;
    this.lastTickStartMs = tTick0;

    // ---- 预烘焙序列：零编码直推（绕开"渲染 + JPEG 编码"，只留 USB 一段成本）----
    if (this.seq !== null && this.seq.state === 'playing') {
      await this.pushSeqFrame();
      this.stats.tickMs = ema(this.stats.tickMs, Date.now() - tTick0);
      return;
    }

    const st = this.bridge.state;
    const t: Telemetry = st.fresh ? st.data : {};
    // 桥端数据不新鲜时，用本机采集兜底（手机/平板单独使用时面板不会空着）。
    // 纯策略在 common/SystemMerge.pickSystem() 里，可离线自检。
    t.system = pickSystem(t.system, st.fresh, this.localSys.toSystemInfo());

    // ---- 应用侧派生状态：历史采样 / 专注计时 / 弹窗 / 主题轮播 ----
    const busy = t.agent !== undefined && t.agent.state === 'busy';
    const cpuPct = t.system !== undefined && t.system.cpu !== undefined ? t.system.cpu : 0;
    const memPct = (t.system !== undefined && t.system.memTotal !== undefined && t.system.memTotal > 0)
      ? ((t.system.memUsed ?? 0) / t.system.memTotal * 100) : 0;
    const tp = (t.health !== undefined && t.health.tokensPerMin !== undefined)
      ? t.health.tokensPerMin : -1;
    const balTotal = this.balanceTotal();
    this.history.sample(Date.now(), cpuPct, memPct, tp, balTotal);
    if (this.focus.tick(Date.now(), busy)) {
      Logger.i(`专注计时：${this.focus.pomodoros} 个番茄`);
    }
    const toast = ToastPolicy.pick(this.prevT, t, Date.now(), this.lastToolToast, this.lastToastAt);
    if (toast !== null) {
      this.toast = toast;
      this.lastToastAt = Date.now();
      Logger.i(`弹窗：${toast.text}`);
      if (toast.text.startsWith('运行 ')) {
        this.lastToolToast = t.agent !== undefined && t.agent.tool !== undefined ? t.agent.tool : '';
      }
    } else if (this.toast !== null && Date.now() > this.toast.until) {
      this.toast = null;
    }
    this.prevT = t;

    // 主题轮播：到点自动切下一个主题（只在用户开了轮播时生效）
    if (this.themeRotateSec > 0 && Date.now() - this.lastThemeSwitch >= this.themeRotateSec * 1000) {
      if (this.lastThemeSwitch === 0) {
        // 刚开启轮播：先记一个起点，避免"一开启就立刻切一次"
        this.lastThemeSwitch = Date.now();
      } else {
        this.lastThemeSwitch = Date.now();
        // ★ 原来是 % 3：只会在主题 0/1/2 之间循环，永远轮不到 3~6（分页屏/打砖块/Dotii/固件仿真）。
        //   主题总数见 Theme.L / LcdService 的 theme 字段说明（当前 7 个：0..6）。
        this.setTheme((this.theme + 1) % 16, false);
        this.onStatus();
      }
    }

    if (this.bgPm === null) {
      this.fetchBgImage();
    }
    // 天气：到点才发请求（15 分钟一次），异步，从不阻塞帧循环
    if (this.theme === 18) {
      this.wx.tick(Date.now());
    }

    // 分页屏自动翻页（只在主题 3 生效）
    if (this.theme === 3 && this.pageRotateSec > 0
        && Date.now() - this.lastPageSwitch >= this.pageRotateSec * 1000) {
      this.lastPageSwitch = Date.now();
      this.page = (this.page + 1) % ThemePages.PAGE_COUNT;
    }

    // ---- 看门狗：USB 开着但长时间推不出去 → 主动断开重连 ----
    // ★ 加 `!this.pushInFlight`：有在途传输时不许关句柄（见 pushInFlight 的注释）
    if (this.usb.isOpen && !this.pushInFlight && this.lastOkPushMs > 0
        && Date.now() - this.lastOkPushMs > LcdService.STALL_MS) {
      Logger.w(`看门狗：${LcdService.STALL_MS / 1000}s 没有成功推帧，主动断开重连`);
      this.usb.close();
      this.lastOkPushMs = 0;
      this.lastSig = '';          // 让下一轮强制重推一帧
      this.usbRetryTs = 0;        // 立刻允许下一次打开尝试
      this.lastError = '推送卡住，已自动重连';
    }

    // ---- 数据桥自愈：长时间收不到遥测就重绑 socket ----
    // 实测故障：桥在正常每秒推包，但应用侧 socket 在某次 error 通知后不再收包，
    // 屏幕数据停在几分钟前，且**不会自己恢复**（只能重启应用）。这里带 30s 节流地
    // 重新 bind 一次，让这种情况能自愈。
    if (this.bridge !== null && st.ageSec() > 30
        && Date.now() - this.lastBridgeRebind > 30000) {
      this.lastBridgeRebind = Date.now();
      this.bridge.rebind();
    }

    // ★ 横装专属主题在竖装下回落到主题 0。
    //   主题 6（固件仿真 368×448）与主题 7（官方 1920×462）的版面是按横装写死的，
    //   竖装（画布 462×1920）下实测**内容越出画布**（layout_check --vertical 报
    //   "越出画布: 'USB 已连接' box=(892,406,1029,433)"、"星期六 … box=(806,215,1114,249)"）。
    //   与其在两个主题里各写一套竖装版面，不如明确回落 —— 竖装本来就是次要形态。
    if (this.verticalMode && LcdService.HORIZONTAL_ONLY.has(this.theme)) {
      if (this.lastFallbackTheme !== this.theme) {
        this.lastFallbackTheme = this.theme;
        Logger.w(`主题 ${this.theme} 只有横装版面，竖装下回落到仪表盘(0)`);
        this.lastError = `主题 ${this.theme} 不支持竖装，已回落到仪表盘`;
      }
      this.setTheme(0, false);
    } else {
      this.lastFallbackTheme = -1;
    }

    // ★ 先记录"本轮真正渲染的主题"再判签名 —— 若放在 tick 末尾，
    //   签名未变时会提前 return，这一行永远执行不到（实测：设主题 0 后 diag 仍报 15）。
    //   见代码审查【中-5】：这个探针本来就是为了诊断"diag 报的主题与实际渲染不一致"，
    //   它自己不一致就失去了意义。
    Dashboard.dbgLastTheme = this.theme;

    // ---- 内容签名：没变化就不重复编码推送 ----
    // 这块屏是"状态副屏"，绝大多数时间内容是不动的；而刷一帧要 ~160ms（编码 70 + 推送 90）。
    // 按签名跳过，等于把同样的 CPU/USB 预算全留给真正变化的那一帧。
    const sig = this.contentSignature(t, st.fresh);
    const nowMs = Date.now();
    // 跳过条件：内容签名没变 **且** 距上次成功推帧还不到心跳间隔。
    // ★ 画面心跳（FRAME_HEARTBEAT_MS=3s）：屏端偶尔自己丢帧/重置，而应用以为
    //   "内容没变"就不推 → 屏上空的或停旧画面（用户反馈"经常性画面丢失"）。
    //   用更短的 3 秒心跳兜底，屏最多 3 秒内被重新喂一帧。
    const sinceMs = nowMs - this.lastPushMs;
    // ★ 后台期间**不跳帧**：continuous task 的 DATA_TRANSFER 模式若传输速率过低
    //   会被系统挂起（见 backgrounded 字段注释），所以后台持续推、维持速率。
    if (!this.backgrounded
        && sig === this.lastSig
        && sinceMs < LcdService.FRAME_HEARTBEAT_MS
        && sinceMs < LcdService.HEARTBEAT_MS) {
      this.skipped++;
      this.stats.skippedFrames = this.skipped;
      // ★ 诊断：跳帧也打点，区分两种截然不同的故障——
      //   "循环还在跑但一直跳帧"（应用活着，屏上静止）
      //   "循环根本没被回调"（事件循环被冻结 → 屏上停更）
      if (Date.now() - this.lastSkipLogMs > 30000) {
        this.lastSkipLogMs = Date.now();
        Logger.i(`[frame] 跳帧中（循环活着）tick=${this.tickCount} skip=${this.skipped}`);
      }
      return;
    }
    // ★ 注意：这里**不再**立刻提交 lastSig（原来在这就写，是 bug）。
    //   原因：推送可能失败（sendJpeg 返回 false），或流水线背压把这帧丢掉。
    //   若在推送前就记成"已推过"，则该内容最长 10 秒（HEARTBEAT_MS）不会再推 ——
    //   屏上留旧画面，而且**瞬时告警帧（toast / 监控未登录 / 余额不足）会永远不显示**。
    //   现在改成：只有 confirmedSig 在"推送成功"后才提交（见 recordPushResult）。
    this.pendingSig = sig;

    // ---- 渲染 ----
    const tw = this.targetW();
    const th = this.targetH();
    const doRotate = this.rotateNow();

    this.stats.usbOpen = this.usb.isOpen;
    // ★ 数据桥"新鲜度"必须写进 stats.bridgeAge —— 这是一个**长期没人赋值**的字段：
    //   它被 7 处读取（Dashboard/ThemeDiag/ThemeWall/ThemeMac/ThemePages 的桥指示灯、
    //   界面「数据桥」一行、以及 /diag 的 bridgeAgeSec），
    //   但全仓没有任何地方给它赋值 → 恒为初值 -1。
    //   后果：遥测明明在推，**屏幕 5 个主题上的桥指示灯却永远显示"○ 无数据"**，
    //   界面上也显示"无数据"，/diag 的 bridgeAgeSec 恒为 -1（排障时极易误判）。
    //   实测发现于 2026-10-15：体检日志显示"0s 前收到｜累计 2038 包"，
    //   而同一时刻 /diag 报 bridgeAgeSec=-1。
    const bsLive = this.bridge.state;
    this.stats.bridgeAge = bsLive.lastRxTs > 0 ? bsLive.ageSec() : -1;

    // ★ 逻辑坐标(1920×462) → 画布 vp 坐标的缩放。
    //   这两行曾被一次字符串切片误删（症状：ctx.scale(1,1) → 按像素画 1920 宽 →
    //   屏上只显示左边约 1/3，右侧面板全被裁掉），补回时特意保留注释说明来历。
    this.scaleX = this.canvasVpW / tw;
    this.scaleY = this.canvasVpH / th;

    const tRender0 = Date.now();
    const ctx = this.ctx;
    ctx.save();
    if (this.verticalMode) {
      // 竖装：逻辑空间 462×1920 → 帧 1920×462（顺时针 90°）
      ctx.translate(this.canvasVpW, 0);
      ctx.rotate(Math.PI / 2);
      ctx.scale(this.canvasVpH / LY_FRAME_H, this.canvasVpW / LY_FRAME_W);
    } else {
      if (doRotate) {
        // 旋转 180°：设备要求的方向
        ctx.translate(this.canvasVpW, this.canvasVpH);
        ctx.rotate(Math.PI);
      }
      ctx.scale(this.scaleX, this.scaleY);
    }
    // 维护滚动留言条：优先用 LLM 一句话摘要，没有则用"最后一句原文"
    const feedSrc: string = this.summaryText().length > 0
      ? this.summaryText()
      : (t.agent !== undefined && t.agent.lastText !== undefined ? t.agent.lastText : '');
    this.pushFeed(feedSrc);

    // ★ 错误蓝屏彩蛋：agent 本轮出错（turn/end 的 reason.kind 非 completed）时
    //   盖一块 Win95 蓝屏 6 秒。同一错误只弹一次，错误清空后复位。
    const errNow: string = (t.agent !== undefined && t.agent.errorText !== undefined)
      ? t.agent.errorText : '';
    if (errNow.length > 0) {
      if (errNow !== this.bsodText) {
        this.bsodText = errNow;
        this.bsodUntil = Date.now() + LcdService.BSOD_MS;
      }
    } else if (this.bsodText.length > 0) {
      this.bsodText = '';
      this.bsodUntil = 0;
    }

    // ★ 一天时间轴的数据：每分钟一格，记录这分钟有没有在干活。
    //   跨天自动重置（dayKey 变了就清空）。
    if (this.timelineOn) {
      const nowD = new Date();
      const key = `${nowD.getFullYear()}-${nowD.getMonth()}-${nowD.getDate()}`;
      if (this.dayKey !== key || this.dayAct.length !== 1440) {
        this.dayKey = key;
        this.dayAct = new Array<number>(1440);
        for (let i = 0; i < 1440; i++) {
          this.dayAct[i] = 0;
        }
      }
      const busyNow = t.agent !== undefined && t.agent.state === 'busy';
      if (busyNow) {
        this.dayAct[nowD.getHours() * 60 + nowD.getMinutes()] = 1;
      }
    }

    // ★ 伪频谱：每 120ms 推一格。驱动量取"当前最活跃的那个指标"：
    //   token 速率（本会话输出速度）优先，没有就用 CPU 占用。
    if (this.specOn) {
      const nowS = Date.now();
      if (nowS - this.specAt >= 120) {
        this.specAt = nowS;
        if (this.specBuf.length !== 96) {
          this.specBuf = new Array<number>(96);
          for (let j = 0; j < 96; j++) {
            this.specBuf[j] = 0;
          }
        }
        const v = this.specValue(t);
        for (let j = 0; j < 95; j++) {
          this.specBuf[j] = this.specBuf[j + 1];
        }
        this.specBuf[95] = v;
      }
    }

    const extras: RenderExtras = {
      history: this.history, toast: this.toast, focus: this.focus,
      bg: this.bgPm, summary: this.summaryText(),
      feed: this.feedLines, feedAt: this.feedAt
    };
    // ★ 渲染必须包 try/finally 保住 ctx.restore()。
    //   原来 restore() 在 ~200 行之后、没有任何保护：任一主题渲染抛异常（字体串非法、
    //   measureText/drawImage 抛、数组越界…）异常会冒泡到 loop() 的 catch，
    //   **restore() 被跳过** → 变换/裁剪/globalAlpha/字体状态**逐帧累积**
    //   （每帧再 save 一次、再叠一次 rotate+scale），画面会永久性错乱而不是只坏一帧。
    try {
    // ★ 打砖块是**逐帧动画**，必须临时提高帧率（审计 M12）：
    //   物理步进 kTickMs=20ms（≈50Hz），而空闲档帧间隔是 INTERVAL_IDLE=500ms，
    //   且 pongAdvance 有 8-tick 上限 → 每帧只推进 160ms 游戏时间
    //   → 屏上打砖块只有 **0.32× 速**（慢动作三倍）。
    //   这里复用"序列播放"那套 save/restore，避免覆盖 /set?fps 的设置。
    //   注意：只放开 tick 上限而不提帧率会更难看（球每帧跳 25 步），所以两件事一起做。
    this.syncPongInterval();
    // 主题 9：打印机格让给 Dotii —— 先切布局档位，再让 Dashboard 用同一套几何
    // 档位：主题 9 = 1（借位档）；主题 0 开着"打印机格显示 Dotii"= 2（只换格内容、不动其它面板）
    // ★ 'v4' 也要走这条分支（13:29 版同样是"打印机格画 Dotii"，只是档位不同）。
    //   之前只判 'dotii'，导致 printerCell=v4 时**格子空着没人画**（实测踩过）。
    const dotiiInPrinter = this.theme === 0
      && (this.printerCell === 'dotii' || this.printerCell === 'v4'
        || this.printerCell === 'v6');
    // 主题 0 的打印机格：printer=标准档(0)；dotii=对调档(3)；v4=13:29 版(4)
    // printer=0 标准 | dotii=3 对调 | v4=4(13:29版) | v6=6(在 v4 版面上把第四五格对调)
    const cellLay0 = this.printerCell === 'dotii' ? 3
      : (this.printerCell === 'v4' ? 4 : (this.printerCell === 'v6' ? 6 : 0));
    Dashboard.cellLayout = this.theme === 9 ? 1 : cellLay0;
    if (this.theme === 9) {
      // 主题 9：打印机格位置放 Dotii（内容复用主题 5），右侧窄栏显示真实打印机数据
      const ci = this.dotiiCellInfo;
      const pr9 = t.printer;
      ci.prState = pr9 !== undefined && pr9.stateLabel !== undefined && pr9.stateLabel.length > 0
        ? pr9.stateLabel : (pr9 !== undefined && pr9.state !== undefined ? pr9.state : '');
      ci.prPct = pr9 !== undefined && pr9.percent !== undefined ? pr9.percent : -1;
      ci.prNozzle = pr9 !== undefined && pr9.nozzleTemp !== undefined ? pr9.nozzleTemp : -1;
      ci.prBed = pr9 !== undefined && pr9.bedTemp !== undefined ? pr9.bedTemp : -1;
      ci.prLayer = pr9 !== undefined && pr9.layer !== undefined ? pr9.layer : -1;
      ci.prRemainText = (pr9 !== undefined && pr9.remainingSec !== undefined && pr9.remainingSec > 0)
        ? `${Math.floor(pr9.remainingSec / 3600)}h${Math.floor((pr9.remainingSec % 3600) / 60)}m` : '--';
      ci.trays = pr9 !== undefined && pr9.trays !== undefined ? pr9.trays.length : 0;
      ci.balance = t.balance !== undefined && t.balance.total !== undefined && t.balance.total >= 0
        ? `¥${t.balance.total.toFixed(2)}` : '--';
      // 与主题 5 共用同一份状态准备（翻页/表情/余额/打印机/网络），
      // 这样 Dotii 在两种位置显示的内容完全一致，只是搬了格子
      this.prepareDotiiState(t);
      ThemeDotiiCell.render(ctx, this.dotiiState, Date.now(), ci, pr9,
        this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 18) {
      // 主题 18「天气」：全屏动态天气（3D 自转地球 + 景深粒子 + 24h 曲线 + 7 天）
      Dashboard.dbgLastTheme = 18;
      ThemeWeather.render(ctx, Date.now(), this.wx.data);
    } else if (this.theme === 17) {
      // 主题 17「超级玛丽」：**全屏**演示版。
      //   按屏幕真实比例算逻辑视口（1920×462 → 640×154），整数 ×3 铺满，
      //   **不拉伸也不留黑边** —— 游戏只是看到了更宽的一条关卡切片。
      Dashboard.dbgLastTheme = 17;
      Dashboard.mario.drawFullscreen(ctx, 1920, 462, Date.now());
    } else if (this.theme === 16) {
      // 主题 16「自走贪吃蛇」：**全屏大棋盘**（正方形格子铺满 1920×462）。
      //   与打印机格里的槽 6 是同一个引擎、不同尺寸 —— 全屏 58×14 格，每格 33px。
      Dashboard.dbgLastTheme = 16;
      if (this.snakeFull === null) {
        this.snakeFull = new SnakeState();
        ThemeSnake.reset(this.snakeFull, Date.now(), 58, 14);
      }
      ThemeSnake.step(this.snakeFull, Date.now());
      ThemeSnake.draw(ctx, 0, 0, 1920, 462, this.snakeFull, Date.now());
    } else if (this.theme === 15) {
      // 主题 15「trofeo-lcd」：复刻 haven80/trofeo-lcd-rs 的栅格版面 + 12 套调色板轮换
      Dashboard.dbgLastTheme = 15;
      ThemeTrofeoRust.render(ctx, this.stats, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 14) {
      // 主题 14「NanoMuse」：照 GitHub 项目 NanoMuse 的真实版面改造（三栏+顶底栏+fleet+det-row）
      Dashboard.dbgLastTheme = 14;
      ThemeNanoMuse.render(ctx, t, this.stats, extras, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 13) {
      // 主题 13「明亮二次元 HUD」：NanoMuse 风格的白瓷片 + 青 HUD（本工程唯一浅色主题）
      ThemeAnimeHUD.render(ctx, t, this.stats, extras, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 12) {
      // 主题 12「二次元·自由构图」：无框、整屏一张插画、数据漂浮其上
      ThemeAnimeFree.render(ctx, t, this.stats, extras, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 11) {
      // 主题 11「二次元壁纸」：程序生成的夜景插画当底图 + 半透明面板压在图上
      ThemeAnimeBG.render(ctx, t, this.stats, extras, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 10) {
      // 主题 10「赛博二次元」：霓虹青紫 + 扫描线 + 故障色差 + 日文片假名装饰
      ThemeAnime.render(ctx, t, this.stats, extras, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 8) {
      // 主题 8「MacTR 五格」：同主题 0 的几何 + MacTR 的视觉语言（弧表/顶条光晕/阈值配色）
      ThemeMac.render(ctx, t, this.stats, extras, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 7) {
      // 主题 7「官方浅色风」：CPU / 时间 / 第二指标 三栏卡片
      const tc = this.trccState;
      const d7 = new Date();
      tc.hour = d7.getHours();
      tc.minute = d7.getMinutes();
      const wk7 = ['日', '一', '二', '三', '四', '五', '六'];
      tc.dateText = `星期${wk7[d7.getDay()]}  ${d7.getFullYear()}/${ThemeDotiiPad(d7.getMonth() + 1)}/${ThemeDotiiPad(d7.getDate())}`;
      // 配色自动轮换（30 秒一套）
      const now7 = Date.now();
      if (this.trccAutoAt === 0) { this.trccAutoAt = now7; }
      if (tc.palette < 0 && now7 - this.trccAutoAt >= 30000) {
        this.trccAutoAt = now7;
        tc.palette = (tc.palette + 1) % TRCC_THEME_COUNT;
      }
      // 左卡 CPU：本机真实值
      const sys7 = t.system;
      tc.cpuTemp = (sys7 !== undefined && sys7.cpuTemp !== undefined) ? sys7.cpuTemp : -1;
      tc.cpuLoadPct = (sys7 !== undefined && sys7.cpu !== undefined) ? sys7.cpu : -1;
      tc.cpuFreqMhz = ThemeTrccFreq();
      // 右卡：本机没有独立 GPU，改用**真实的 token 速率**顶上（宁换内容也不编 GPU 数值）
      const tk7 = t.tokens;
      const tpm7 = (t.health !== undefined && t.health.tokensPerMin !== undefined)
        ? t.health.tokensPerMin : -1;
      tc.gpuLabel = 'TOKEN';
      // 主数值位显示"速率/min"，占用位显示今日累计（都用真实值）
      tc.gpuTemp = tpm7;
      tc.gpuLoadPct = (tk7 !== undefined && tk7.todayTotal !== undefined)
        ? Math.round(tk7.todayTotal) : -1;
      tc.gpuFreqMhz = -1;
      // 首次进主题 7 时异步载入官方底图（不阻塞本帧）
      if (this.trccBg[0] === null) {
        this.loadTrccBg();
      }
      const bgIdx = ((tc.palette % TRCC_THEME_COUNT) + TRCC_THEME_COUNT) % TRCC_THEME_COUNT;
      ThemeTrcc.render(ctx, tc, this.vignette, this.vignetteReach, this.vigCorner(),
        this.trccBg[bgIdx]);
    } else if (this.theme === 6) {
      // 主题 6「固件仿真屏」：ESP32-S3 固件 UI 的仿真显示（同一块 343×418 区域）
      const nowMs6 = Date.now();
      const fw = this.fwState;
      const d6 = new Date();
      fw.hour = d6.getHours();
      fw.minute = d6.getMinutes();
      fw.second = d6.getSeconds();
      const wk = ['日', '一', '二', '三', '四', '五', '六'];
      fw.dateText = `周${wk[d6.getDay()]} ${ThemeDotiiPad(d6.getMonth() + 1)}月${ThemeDotiiPad(d6.getDate())}日`;
      // 自动轮播界面（12 秒一个，看全 18 个界面）
      if (this.fwAutoAt === 0) { this.fwAutoAt = nowMs6; }
      if (this.fwAuto && nowMs6 - this.fwAutoAt >= 12000) {
        this.fwAutoAt = nowMs6;
        // 只在用户要的 4 个界面里轮播（打印中/表情/打砖块时钟/余额）
        let pos = 0;
        for (let i = 0; i < FW_ROTATION.length; i++) {
          if (FW_ROTATION[i] === fw.screen) { pos = i; }
        }
        fw.screen = FW_ROTATION[(pos + 1) % FW_ROTATION.length];
      }
      // 实时数据（固件那些屏显示的就是这些）
      const pr6 = t.printer;
      if (pr6 !== undefined) {
        fw.prState = pr6.state !== undefined ? pr6.state : '';
        fw.prModel = pr6.model !== undefined ? pr6.model : '';
        fw.prJob = pr6.jobName !== undefined ? pr6.jobName : '';
        fw.prPct = pr6.percent !== undefined ? pr6.percent : -1;
        fw.prNozzle = pr6.nozzleTemp !== undefined ? pr6.nozzleTemp : -1;
        fw.prBed = pr6.bedTemp !== undefined ? pr6.bedTemp : -1;
        fw.prChamber = pr6.chamberTemp !== undefined ? pr6.chamberTemp : -1;
        fw.prLayer = pr6.layer !== undefined ? pr6.layer : -1;
        fw.prTotalLayer = pr6.totalLayer !== undefined ? pr6.totalLayer : -1;
        const rem6 = pr6.remainingSec !== undefined ? pr6.remainingSec : -1;
        fw.prRemainMin = rem6 > 0 ? Math.floor(rem6 / 60) : -1;
        fw.prEta = pr6.eta !== undefined ? pr6.eta : '';
        fw.prTrays = pr6.trays !== undefined ? pr6.trays.length : 0;
      }
      const bal6 = t.balance;
      if (bal6 !== undefined) {
        fw.balTotal = bal6.total !== undefined ? bal6.total.toFixed(2) : '--';
        fw.balGranted = bal6.granted !== undefined ? bal6.granted.toFixed(2) : '--';
        fw.balTopped = bal6.toppedUp !== undefined ? bal6.toppedUp.toFixed(2) : '--';
        fw.balStatus = (bal6.available === true) ? '可用' : '离线';
      }
      fw.wifiText = this.stats.usbOpen ? 'USB 已连接' : '未连接';
      // 错误详情屏：用桥端 telemetry 的真实 HMS 字段（hmsCount / hmsCode）
      const hmsN = pr6 !== undefined && pr6.hmsCount !== undefined ? pr6.hmsCount : 0;
      fw.hmsCount = hmsN;
      fw.hmsLabel = (pr6 !== undefined && pr6.hmsCode !== undefined) ? pr6.hmsCode : '';
      fw.hmsDetail = hmsN > 0 ? '详见打印机屏幕 / 手机端' : '';
      // OTA 屏：本移植不参与升级，给一个固定演示态（源在升级时由固件提供真实进度）
      fw.otaPct = 0;
      fw.otaStatus = '本屏不参与固件升级（仿真）';
      // 烘干屏：桥端有腔温；湿度/剩余时间固件才有，这里留 -- 并标注
      fw.dryTemp = fw.prChamber;
      fw.dryHumidity = -1;
      fw.dryRemainMin = -1;
      fw.cameraOk = false;
      // 打砖块时钟：与主题 4 共用同一套物理状态（此处只是取它的快照来画）
      if (this.pongState === null) {
        this.pongState = pongInit(nowMs6);
        this.pongLastMs = nowMs6;
      }
      const dt6 = this.pongLastMs > 0 ? (nowMs6 - this.pongLastMs) : 0;
      this.pongLastMs = nowMs6;
      pongAdvance(this.pongState, dt6);
      fw.pongBallX = this.pongState.ballX;
      fw.pongBallY = this.pongState.ballY;
      fw.pongPaddleX = this.pongState.paddleX;
      fw.pongBricks = this.pongState.bricks;
      fw.ssid = 'GXSZ-2.4G';
      fw.ip = '192.168.11.134';
      ThemeFwSim.render(ctx, fw, nowMs6, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 5) {
      // 主题 5「Dotii 分页屏」：ESP32-S3 那套 UI 的等比移植（同一块 343×418 区域）
      const nowMs = Date.now();
      const ds = this.dotiiState;
      const d = new Date();
      ds.hour = d.getHours();
      ds.minute = d.getMinutes();
      this.prepareDotiiState(t);
      ThemeDotii.render(ctx, ds, nowMs, this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 4) {
      // 主题 4「打砖块」：整屏游戏，源画布 368×448 居中（不占任何面板）
      const nowMs = Date.now();
      if (this.pongState === null) {
        this.pongState = pongInit(nowMs);
        this.pongLastMs = nowMs;
      }
      const dt = this.pongLastMs > 0 ? (nowMs - this.pongLastMs) : 0;
      this.pongLastMs = nowMs;
      pongAdvance(this.pongState, dt);
      const d = new Date();
      const week = ['日', '一', '二', '三', '四', '五', '六'];
      this.pongState.hour = d.getHours();
      this.pongState.minute = d.getMinutes();
      this.pongState.second = d.getSeconds();
      this.pongState.dateText =
        `周${week[d.getDay()]} ${ThemePong.pad2(d.getMonth() + 1)}月${ThemePong.pad2(d.getDate())}日`;
      ThemePong.render(ctx, this.pongState, true, this.stats.fps, this.stats.renderMs,
        this.vignette, this.vignetteReach, this.vigCorner());
    } else if (this.theme === 3) {
      ThemePages.render(ctx, t, this.stats, this.vmPm, this.vmAge(), this.vmErr,
        extras, this.page % ThemePages.PAGE_COUNT);
    } else if (this.theme === 2) {
      ThemeWall.render(ctx, t, this.stats, this.vmPm, this.vmAge(), this.vmErr, extras);
    } else if (this.theme === 1) {
      ThemeDiag.render(ctx, t, this.stats, this.vmPm, this.vmAge(), this.vmErr, extras);
    } else {
      // ★ 打印机格「表情」槽要显示的表情：printerPanel 只拿到 PrinterInfo，
      //   拿不到 dotiiState，所以用静态字段递过去（同 cellLayout 的既有做法）。
      //   放在 render 之前赋值 —— prepareDotiiState 已在更早处跑过，值是当帧的。
      // ★ 必须**无条件**准备一次 Dotii 状态（审计 H4）：
    //   prepareDotiiState 原只在 主题5 / 主题9 / dotiiInPrinter 三个分支里调用，
    //   而「打印机格 · 表情槽」恰恰在 printerCell='printer' 时绘制（那时 dotiiInPrinter=false）
    //   → expr 永不推进 → 槽 3/4 永远画同一张脸（实测 40 秒恒为 5）。
    //   本函数自身有时间闸门（10s），同一帧重复调用是幂等的，不会加速推进。
    this.prepareDotiiState(t);
    Dashboard.dotiiFaceExpr = this.dotiiState.expr;
      Dashboard.render(ctx, t, this.stats, this.vmPm, this.vmAge(), this.vmErr,
        this.verticalMode, extras, this.theme === 9 ? 1 : cellLay0);
      if (dotiiInPrinter) {
        // ★ 第一屏（主题 0）的"打印机格显示 Dotii"：Dashboard 已经把这个格子空出来了
        //   （档位 2 → 不画打印机卡），这里把 Dotii 画进去。
        //   其余面板（DSH/USAGE/VM）保持标准版式，一个像素都没动。
        const pr0: PrinterInfo | undefined = this.prepareDotiiCellInfo(t);
        this.prepareDotiiState(t);
        // mode 与 Dashboard 的档位必须一致：dotii→3（Dotii 第五格）、v4→1（Dotii 第四格）。
        // 传错就会出现"Dashboard 把 VM 放第四格、Dotii 也画在第四格"的错位。
        //   Dashboard 走的是档位 3（VM 去第四格），而 Dotii 的几何由这里的 mode 决定 ——
        //   传错就会出现"Dashboard 把 VM 放第四格、Dotii 也画在第四格"，表现为
        //   **Dotii 压在第四个位置、第五格空着**（用户实测反馈过）。
        ThemeDotiiCell.render(ctx, this.dotiiState, Date.now(), this.dotiiCellInfo, pr0,
          this.vignette, this.vignetteReach, this.vigCorner(),
          this.printerCell === 'v4' ? 1 : 3);
      }
    }
    // ★ 右下角漏光补偿：画在所有主题之上（在 restore 之前，坐标系仍是逻辑 1920×462）。
    //   主题 4/5/6 **自己已经画过一层**（它们把补偿放在自己的变换里），这里必须排除掉，
    //   否则会**叠加两次**（渐变相乘 → 角部被过度压暗，实测 0.25×0.25 ≈ 0.44）。
    //   这条兜底只负责主题 0/1/2/3；/set?vigall=1 可强制所有主题都在这一层画（调试用）。
    // ★ 蓝屏盖在最上层（在漏光补偿之前，让它也被漏光压暗、观感统一）
    const bsodLeft: number = this.bsodUntil - Date.now();
    if (bsodLeft > 0) {
      Overlay.bsod(ctx, 1920, 462, this.bsodText, bsodLeft);
      this.lastSig = '';   // 签名失效，保证蓝屏出现/消失都立刻上屏
    } else {
      // 装饰件（都在蓝屏之下，出错时让位给蓝屏）
      // ★ 必须**自下而上堆叠**，否则互相遮挡（初版频谱 72px 直接盖住了 34px 的跑马灯）。
      //   顺序（从屏幕底边往上）：跑马灯 → 时间轴 → 伪频谱。
      const H: number = 462;
      const tickerH: number = 30;
      const timelineH: number = 20;
      const specH: number = 52;
      // 当前哪些开着，决定各自的顶边位置
      let bottom: number = H;
      const tickerY: number = bottom - (this.tickerOn ? tickerH : 0);
      if (this.tickerOn) {
        bottom = tickerY;
      }
      const timelineY: number = bottom - (this.timelineOn ? timelineH : 0);
      if (this.timelineOn) {
        bottom = timelineY;
      }
      const specY: number = bottom - (this.specOn ? specH : 0);

      if (this.specOn && this.specBuf.length === 96) {
        Overlay.spectrum(ctx, 1920, specY, specH, this.specBuf);
      }
      if (this.timelineOn && this.dayAct.length === 1440) {
        const d = new Date();
        Overlay.timeline(ctx, 1920, timelineY, timelineH, this.dayAct,
          d.getHours() * 60 + d.getMinutes(), this.nightWin.startMin, this.nightWin.endMin);
      }
      if (this.tickerOn) {
        Overlay.ticker(ctx, 1920, tickerY, tickerH, this.tickerText(t), Date.now() / 12);
      }
      // ★ 整点彩虹跑马灯：整点后 30 秒内盖在最底部（最高优先级，盖住普通跑马灯）
      //   彩条不占用 ticker/timeline/spec 的位置，而是**替换**底边那一条，
      //   所以不会把三件装饰挤得更靠上。
      const hbLeft: number = this.hourBellLeftMs();
      if (hbLeft > 0) {
        // 纯彩虹带绕屏一圈（用户 2026-10-20 定稿：不要文字，只要色带在转）
        // 带子从 34px 加粗到 **68px**（"粗一倍"）。
        Overlay.rainbowRing(ctx, 1920, 462, this.ringBand, Date.now());
      }
      // ★ 复古滤镜放最后：它是对整幅画面做"后期"，必须盖在所有内容之上
      if (this.retroOn) {
        Overlay.retro(ctx, 1920, 462);
      }
    }
    if (this.vigAll || (this.theme !== 4 && this.theme !== 5 && this.theme !== 6 && this.theme !== 7 && this.theme !== 8 && this.theme !== 9 && this.theme !== 10 && this.theme !== 11 && this.theme !== 12 && this.theme !== 13 && this.theme !== 14 && this.theme !== 15)) {
      Chrome.vignette(ctx, 1920, 462, this.vignette, this.vignetteReach, this.vigCorner());
    }
    } catch (e) {
      // 渲染异常只坏这一帧：记下来，restore() 交给 finally
      const err = e as Error;
      this.lastError = `渲染异常: ${err !== null && err.message !== undefined ? err.message : e}`;
      Logger.e(this.lastError);
      this.stats.renderErrors++;
    } finally {
      // ★ 无论渲染成功还是抛异常，都必须 restore —— 否则画布变换会逐帧累积
      ctx.restore();
    }
    // ★ 边框扫掠（光沿边框环绕）：移植自 BambuHelper 的 display_edge_glow.cpp
    //   默认只在天气主题（18）上开；/set?sweep=0 可关、/set?sweep=1 可强制任意主题开。
    if (this.sweepOn && (this.theme === 18 || this.sweepForce)) {
      Overlay.sweepBorder(ctx, tw, th, Date.now(), this.sweepLapMs, this.sweepThick, '120,235,255');
    }

    this.stats.renderMs = ema(this.stats.renderMs, Date.now() - tRender0);
    // ★ 渲染完先让出（紧接着的 toDataURL 是同步的，会独占主线程 60~75ms）
    await this.yieldToUi();
    const tEncode0 = Date.now();

    // ---- 顺带抓一帧 VM 画面（内部有 1s 节流，不影响帧率）----
    this.fetchVmFrame();

    // ---- 编码 JPEG（超限自动降质）----
    // 快路径：canvas → PixelMap → 原生 JPEG 打包（省掉 toDataURL 的 base64 编解码往返，
    // 实测编码耗时从 ~50ms 降到 ~30ms）；失败则回退到老的 toDataURL 路径。
    //
    // ★ 文字型主题（5=Dotii 分页屏 / 6=固件仿真屏）把**本次编码**的质量下限抬到 0.95：
    //   用户反馈"字体看着虚"，实测 q=0.85 时文字边缘梯度中位只有 45、拉到 0.95 后到 64。
    //   注意必须是**局部变量**：早先的写法直接改 `this.encodeQuality`，会导致
    //   "进过一次主题 5 之后所有主题都按 0.95 编码"（帧更大更慢），并且静默覆盖用户的 /set?q=。
    let quality = this.encodeQuality;
    if ((this.theme === 5 || this.theme === 6) && quality < 0.95) {
      quality = 0.95;
    }
    let jpeg: Uint8Array | null = null;
    let sizeInfo: JpegInfo = new JpegInfo();
    // 默认走 toDataURL（真机验证过）；快路径留着但默认关闭，见 encodeFast 的说明
    const fast = FAST_ENCODE ? await this.encodeFast(ctx, quality) : null;
    if (fast !== null) {
      jpeg = fast;
      sizeInfo = parseJpegSize(fast);
      if (fast.length > LyProtocol.maxJpegSize()) {
        // 超限才走降质阶梯（同样走快路径）
        let q2 = quality;
        for (let i = 0; i < 4 && q2 > MIN_QUALITY; i++) {
          q2 = nextQuality(q2, 0.15, MIN_QUALITY);
          const again = await this.encodeFast(ctx, q2);
          if (again === null) {
            break;
          }
          jpeg = again;
          sizeInfo = parseJpegSize(again);
          quality = q2;
          if (again.length <= LyProtocol.maxJpegSize()) {
            break;
          }
        }
      }
    } else {
      for (let i = 0; i < 5; i++) {
        const dataUrl = ctx.toDataURL('image/jpeg', quality);
        const comma = dataUrl.indexOf(',');
        if (comma < 0) {
          Logger.e('toDataURL 返回异常');
          return;
        }
        const bytes = this.b64.decodeSync(dataUrl.substring(comma + 1));
        jpeg = bytes;
        sizeInfo = parseJpegSize(bytes);
        if (bytes.length <= LyProtocol.maxJpegSize() || quality <= MIN_QUALITY) {
          break;
        }
        quality = nextQuality(quality, 0.15, MIN_QUALITY);
      }
    }
    // ★ 编码完成后也让出一次，再开始 USB 推送
    await this.yieldToUi();
    if (jpeg === null) {
      return;
    }
    this.stats.jpegSize = jpeg.length;
    this.stats.jpegW = sizeInfo.width;
    this.stats.jpegH = sizeInfo.height;

    // 暴露给 localhost，便于外部验证渲染结果
    this.frameServer.setFrame(jpeg);
    this.onStatus();

    this.stats.encodeMs = ema(this.stats.encodeMs, Date.now() - tEncode0);
    this.stats.quality = quality;

    // ---- 尺寸校准（纯逻辑见 CanvasCalib.ets）----
    const step: CalibStep = calibrate(this.calib, tw, th, sizeInfo.width, sizeInfo.height);
    if (step.action === 'resize') {
      this.canvasVpW = step.vpW;
      this.canvasVpH = step.vpH;
      Logger.w(`校准画布: ${step.note}`);
      this.onCanvasResize(step.vpW, step.vpH);
      this.onStatus();
      return;
    }
    if (step.action === 'forced') {
      Logger.w(`尺寸校准放弃: ${step.note}（按当前尺寸推帧，画面可能有缩放）`);
      this.lastError = `校准未收敛，已按 ${sizeInfo.width}x${sizeInfo.height} 推帧`;
    } else if (step.action !== 'ready') {
      return;
    }

    // ---- 推帧 ----
    if (!this.usb.isOpen) {
      const dec: UsbAttemptDecision = shouldAttemptUsbOpen(this.usbState, Date.now(), false);
      if (dec.attempt) {
        this.usbState.lastAttemptMs = Date.now();
        await this.tryOpenUsb();
      } else if (dec.needsManual && this.lastError.length === 0) {
        this.lastError = '自动重试已停止，请点「连接屏幕」';
      }
      this.onStatus();
      return;
    }

    if (this.pipelinePush) {
      // 流水线：不 await —— 交由后台推，帧循环立刻返回去做下一帧
      this.dispatchPush(jpeg);
      this.stats.tickMs = ema(this.stats.tickMs, Date.now() - tTick0);
      return;
    }

    const tPush0 = Date.now();
    this.pushInFlight = true;
    let ok = false;
    try {
      ok = await this.usb.sendJpeg(jpeg);
    } finally {
      this.pushInFlight = false;
    }
    this.stats.pushMs = ema(this.stats.pushMs, Date.now() - tPush0);
    this.recordPushResult(ok, Date.now());
    this.stats.tickMs = ema(this.stats.tickMs, Date.now() - tTick0);
    this.onStatus();
  }

  /**
   * 把一帧丢给后台推。**背压**：上一帧还在推就跳过本帧（丢帧不排队）——
   * 排队只会让延迟越积越大，最后屏上是几秒前的画面。
   */
  private dispatchPush(jpeg: Uint8Array): void {
    if (this.pushBusy) {
      this.pushSkip++;
      return;
    }
    this.pushBusy = true;
    const tPush0 = Date.now();
    this.usb.sendJpeg(jpeg).then((ok: boolean) => {
      this.stats.pushMs = ema(this.stats.pushMs, Date.now() - tPush0);
      this.pushBusy = false;
      this.recordPushResult(ok, Date.now());
      this.onStatus();
    }).catch(() => {
      this.pushBusy = false;
      this.recordPushResult(false, Date.now());
    });
  }

  // ===================== 预烘焙 JPEG 序列：载入 / 直推 / 停止 =====================

  /** /diag 里的序列字段（一条单独的拼接函数，避免动到那一长串诊断 JSON） */
  private seqDiagJson(): string {
    const s = this.seq;
    return `,"seqState":${jsonStr(s === null ? 'off' : s.state)}`
      + `,"seqMsg":${jsonStr(s === null ? '' : s.msg)}`
      + `,"seqBase":${jsonStr(s === null ? '' : s.base)}`
      + `,"seqName":${jsonStr(s === null ? '' : s.manifest.name)}`
      + `,"seqCount":${jsonNum(s === null ? 0 : s.frames.length)}`
      + `,"seqCursor":${jsonNum(s === null ? 0 : s.cursor)}`
      + `,"seqPushed":${jsonNum(s === null ? 0 : s.pushed)}`
      + `,"seqErrors":${jsonNum(s === null ? 0 : s.errors)}`
      + `,"seqLoadMs":${jsonNum(s === null ? 0 : s.loadMs)}`
      + `,"seqFps":${jsonNum(this.seqFps)}`
      + `,"seqPushMs":${jsonNum(this.seqPushMs)}`
      + `,"seqFpsSet":${jsonNum(this.seqFpsOverride)}`
      + `,"seqLimitSet":${jsonNum(this.seqLimitOverride)}`
      + `,"seqLoop":${jsonBool(s !== null && s.manifest.loop)}`
      + `,"seqStream":${jsonBool(s !== null && s.stream)}`
      + `,"seqBurst":${jsonBool(this.seqBurst)}`
      + `,"seqWin":${jsonNum(s === null ? 0 : s.win)}`
      + `,"seqBufFill":${jsonNum(s === null ? 0 : seqBufFill(s.buf))}`
      + `,"seqBufCap":${jsonNum(s === null ? 0 : s.buf.length)}`
      + `,"seqAhead":${jsonNum(s === null ? 0 : (s.head - s.tail))}`
      + `,"seqFetched":${jsonNum(s === null ? 0 : s.fetched)}`
      + `,"seqUnderruns":${jsonNum(s === null ? 0 : s.underruns)}`
      + `,"seqSelfTest":${jsonStr(seqSelfTest())}`;
  }

  /** 开始载入序列：立刻返回（HTTP 拉帧在后台跑），进度看 /diag 的 seq* 字段 */
  private startSeqLoad(base: string): string {
    const s = new SeqState();
    s.base = base;
    s.stream = this.seqStream;
    s.win = this.seqWin > 0 ? this.seqWin : SEQ_DEFAULT_WIN;
    s.state = 'loading';
    s.msg = s.stream ? '取清单（流式）…' : '取清单…';
    s.limit = this.seqLimitOverride > 0 ? this.seqLimitOverride : SEQ_DEFAULT_LIMIT;
    this.seq = s;
    this.seqFps = 0;
    this.seqTimes = [];
    this.seqPushMs = 0;
    Logger.i(`序列载入开始: ${base}（limit=${s.limit}, stream=${s.stream}, win=${s.win}）`);
    this.loadSeq(s).then(() => {
    }).catch((e: Object) => {
      s.state = 'error';
      s.msg = `载入异常: ${e}`;
      Logger.e(`序列载入异常: ${e}`);
    });
    return base;
  }

  /** 取清单 + 逐帧拉 JPEG 进内存；成功后进入 playing */
  private async loadSeq(s: SeqState): Promise<void> {
    const t0 = Date.now();
    let b = s.base;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    const man = parseSeqManifest(await this.httpGetText(`${b}/manifest.json`));
    if (man === null) {
      s.state = 'error';
      s.msg = '清单取不到或非法（需要 count）';
      return;
    }
    s.manifest = man;
    const want = seqFetchCount(man.count, s.limit);
    if (want <= 0) {
      s.state = 'error';
      s.msg = `清单 count=${man.count} 非法`;
      return;
    }
    // ---- 流式模式：只取清单，先把预取窗口填满，再进 playing（内存只占 win 帧）----
    if (s.stream) {
      const cap = seqBufCap(man.count, s.win);
      if (cap <= 0) {
        s.state = 'error';
        s.msg = '流式窗口非法（win<=0）';
        return;
      }
      s.buf = [];
      for (let i = 0; i < cap; i++) {
        s.buf.push(null);
      }
      s.head = 0;
      s.tail = 0;
      s.msg = `预取窗口 ${cap} 帧…`;
      await this.pumpSeq(s);
      const fill = seqBufFill(s.buf);
      if (fill === 0) {
        s.state = 'error';
        s.msg = '一帧都没取到（seq_server 没跑？）';
        return;
      }
      s.loadMs = Date.now() - t0;
      s.state = 'playing';
      s.msg = `${man.name} 流式 ${man.count} 帧 · 窗口 ${cap} 帧 · 起播 ${s.loadMs}ms`;
      this.applySeqInterval();
      this.pendingSig = '';
      this.lastSig = '';
      Logger.i(`流式序列就绪: ${man.toString()} 窗口 ${cap} 帧, 起播 ${s.loadMs}ms`);
      this.onStatus();
      return;
    }

    const frames: Uint8Array[] = [];
    let missed = 0;
    for (let i = 0; i < want; i++) {
      const bytes = await this.httpGetBytes(seqFrameUrl(b, man.pattern, i + 1));
      if (bytes === null || bytes.length < 4) {
        missed++;
        if (missed > 3) {
          break;
        }
        continue;
      }
      frames.push(bytes);
      s.msg = `载入 ${frames.length}/${want}`;
    }
    if (frames.length === 0) {
      s.state = 'error';
      s.msg = '一帧都没取到（seq_server 没跑？）';
      return;
    }
    s.frames = frames;
    s.cursor = 0;
    s.loadMs = Date.now() - t0;
    s.state = 'playing';
    s.msg = `${man.name} ${frames.length} 帧 · 载入 ${s.loadMs}ms`;
    this.applySeqInterval();
    // 序列帧不参与内容签名，停机后常规定时器会无条件重推一帧
    this.pendingSig = '';
    this.lastSig = '';
    Logger.i(`序列就绪: ${man.toString()} 实取 ${frames.length} 帧, 载入 ${s.loadMs}ms`);
    this.onStatus();
  }

  /** 推一帧预编码 JPEG：不渲染、不编码，纯"字节 → LY 分块 → USB" */
  private async pushSeqFrame(): Promise<void> {
    const s = this.seq;
    if (s === null) {
      return;
    }
    if (this.pushBusy) {
      // 背压：上一帧还在推就丢这一帧（排队只会让屏上是几秒前的画面）
      this.pushSkip++;
      this.stats.skippedFrames++;
      return;
    }
    if (!this.usb.isOpen) {
      const dec: UsbAttemptDecision = shouldAttemptUsbOpen(this.usbState, Date.now(), false);
      if (dec.attempt) {
        this.usbState.lastAttemptMs = Date.now();
        await this.tryOpenUsb();
      }
      return;
    }
    // 取这一轮要推的帧：流式从环形缓冲拿（且要还槽），预载从数组拿
    let jpeg: Uint8Array | null = null;
    let slot = -1;
    if (s.stream) {
      const cap = seqBufCap(s.manifest.count, s.win);
      slot = seqBufSlot(s.tail, cap);
      const f = slot >= 0 ? s.buf[slot] : null;
      jpeg = (f === null || f === undefined) ? null : f;
      if (jpeg === null) {
        // 缓冲没喂上：本轮不推（屏保持上一帧），让生产者继续补
        s.underruns++;
        this.kickPump(s);
        if (s.underruns > 200) {
          this.stopSeq(`缓冲长期欠载（${s.underruns} 次），已停`);
        }
        return;
      }
    } else {
      const f = s.frames[s.cursor];
      jpeg = (f === undefined) ? null : f;
      if (jpeg === null) {
        this.stopSeq(`游标越界（cursor=${s.cursor}, count=${s.frames.length}）`);
        return;
      }
    }
    this.pushBusy = true;
    this.pushInFlight = true;      // 看门狗护栏：序列推帧期间同样不许关句柄
    const t0 = Date.now();
    let ok = false;
    try {
      ok = await this.usb.sendJpeg(jpeg);
    } catch (e) {
      ok = false;
    } finally {
      this.pushInFlight = false;
    }
    this.pushBusy = false;

    this.seqPushMs = ema(this.seqPushMs, Date.now() - t0);
    this.stats.pushMs = this.seqPushMs;
    this.stats.jpegSize = jpeg.length;
    const sz = parseJpegSize(jpeg);
    this.stats.jpegW = sz.width;
    this.stats.jpegH = sz.height;
    this.frameServer.setFrame(jpeg);
    this.pendingSig = '';
    this.recordPushResult(ok, Date.now());

    if (ok) {
      s.pushed++;
      s.fails = 0;
      const now = Date.now();
      this.seqTimes.push(now);
      while (this.seqTimes.length > 0 && now - this.seqTimes[0] > 3000) {
        this.seqTimes.shift();
      }
      const span = this.seqTimes.length > 1 ? (now - this.seqTimes[0]) / 1000 : 0;
      this.seqFps = span > 0 ? (this.seqTimes.length - 1) / span : 0;
    } else {
      s.errors++;
      s.fails++;
      if (s.fails >= 10) {
        this.stopSeq(`连续 ${s.fails} 帧推送失败（USB 端点异常？）`);
        return;
      }
    }

    // 前进：流式还槽 + 推进 tail；预载按游标走
    if (s.stream) {
      const cap = seqBufCap(s.manifest.count, s.win);
      if (slot >= 0 && slot < s.buf.length) {
        s.buf[slot] = null;
      }
      s.tail++;
      s.cursor = s.manifest.count > 0 ? (s.tail % s.manifest.count) : 0;
      // 半窗滞回：窗口掉到一半以下才**批量**补，避免"每帧插一次 HTTP"拖慢推帧
      // （实测 win=8 每帧都补时推帧耗时 91→182ms，见 .verify/video-seq/bench_stream.json）
      if (seqNeedsPump(s.head, s.tail, cap)) {
        this.kickPump(s);
      }
      if (seqShouldStop(s.head, s.tail, s.manifest.count, s.manifest.loop)) {
        this.stopSeq(`流式播完 ${s.pushed} 帧（欠载 ${s.underruns} 次）`);
      }
      return;
    }
    const nx = nextSeqCursor(s.cursor, s.frames.length, s.manifest.loop);
    if (nx < 0) {
      this.stopSeq(`播完 ${s.pushed} 帧（载入 ${s.loadMs}ms）`);
      return;
    }
    s.cursor = nx;
  }

  /** 唤起抓帧循环（已在跑 / 非流式 / 已停机则什么都不做） */
  private kickPump(s: SeqState): void {
    if (!s.stream || s.pumping) {
      return;
    }
    if (s.state !== 'playing' && s.state !== 'loading') {
      return;
    }
    if (this.seq !== s) {
      return;
    }
    s.pumping = true;
    this.pumpSeq(s).then(() => {
      s.pumping = false;
    }).catch(() => {
      s.pumping = false;
    });
  }

  /**
   * 流式抓帧：把预取窗口填满（最多抓到 head 追平 tail+cap）。
   * 失败不空转 —— 直接返回，交给下一轮 tick 的 kickPump 重试（每轮一次）。
   */
  private async pumpSeq(s: SeqState): Promise<void> {
    let b = s.base;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    const cap = seqBufCap(s.manifest.count, s.win);
    while (this.seq === s && (s.state === 'playing' || s.state === 'loading')
        && seqCanFetch(s.head, s.tail, cap, s.manifest.count, s.manifest.loop)) {
      const idx = s.head % s.manifest.count;
      const bytes = await this.httpGetBytes(seqFrameUrl(b, s.manifest.pattern, idx + 1));
      if (this.seq !== s) {
        return;
      }
      if (bytes === null || bytes.length < 4) {
        s.fails++;
        if (s.fails >= 10) {
          s.msg = `抓帧连续失败 ${s.fails} 次（seq_server 还在吗？）`;
        }
        return;
      }
      s.fails = 0;
      const slot = seqBufSlot(s.head, cap);
      if (slot >= 0) {
        s.buf[slot] = bytes;
      }
      s.head++;
      s.fetched++;
      if (s.state === 'loading') {
        s.msg = `预取 ${seqBufFill(s.buf)}/${cap} 帧…`;
      }
    }
  }

  /** 停止播放：释放帧内存、还原帧间隔、让常规渲染下一轮重新接手 */
  private stopSeq(reason: string): void {
    const s = this.seq;
    if (s !== null) {
      s.state = 'done';
      s.msg = reason;
      s.frames = [];
      s.buf = [];
      Logger.i(`序列停止: ${reason}（已推 ${s.pushed} 帧, 错 ${s.errors}, 欠载 ${s.underruns}, 均推 ${this.seqPushMs.toFixed(1)}ms）`);
    }
    this.restoreSeqInterval();
    this.lastSig = '';
    this.pendingSig = '';
    this.onStatus();
  }

  /** 播放期间用固定帧间隔（forceIntervalMs > 0 会覆盖自适应策略） */
  /**
   * 按"当前是否在显示打砖块"调整帧间隔。
   *
   * 打砖块在两种位置出现：
   *   ① 主题 4（整屏）
   *   ② 主题 0 + printerCell='printer' 的槽 5（打印机格内）
   * 两者都要提高帧率，否则物理推进被 500ms 空闲间隔拖成慢动作。
   *
   * 用 **PONG_FPS_MS = 66ms（≈15fps）**：kTickMs=20ms → 每帧约 3 tick，速度正确；
   * 若用更快的间隔，USB 推帧成本（≈160ms/帧）反而会成为瓶颈。
   */
  private syncPongInterval(): void {
    // 槽 5=打砖块、槽 6=自走贪吃蛇 —— 都是逐帧动画，都要高帧率
    const sub: number = Dashboard.printerSubPage();
    const inCellAnim: boolean = this.theme === 0 && this.printerCell === 'printer'
      && (sub === 5 || sub === 6);
    // Dotii 的「贪吃蛇」页也是逐帧动画 —— 翻到它时同样要提帧率
    const dotiiSnake: boolean = (this.dotiiState.page % DOTII_PAGES) === DOTII_SNAKE_PAGE
      && (this.theme === 5 || this.theme === 9 || this.dotiiShownInCell());
    // 主题 16 也是逐帧动画（蛇每 170ms 走一格），同样要提帧率
    // 马里奥演示（VM 无画面时）也是逐帧动画，要提帧率
    const marioOn: boolean = this.vmPm === null && Dashboard.marioEnabled;
    const pongVisible: boolean = this.theme === 4 || this.theme === 16 || this.theme === 17
      || inCellAnim || dotiiSnake || marioOn;
    if (pongVisible) {
      if (this.pongSavedForceInterval < 0) {
        this.pongSavedForceInterval = this.forceIntervalMs;
      }
      // 只有在没被别人（序列播放 / /set?fps）压低时才接管
      if (this.forceIntervalMs === 0 || this.forceIntervalMs > LcdService.PONG_FPS_MS) {
        this.forceIntervalMs = LcdService.PONG_FPS_MS;
      }
    } else if (this.pongSavedForceInterval >= 0) {
      this.forceIntervalMs = this.pongSavedForceInterval;
      this.pongSavedForceInterval = -1;
    }
  }

  private applySeqInterval(): void {
    const s = this.seq;
    if (s === null) {
      return;
    }
    const fps = this.seqFpsOverride > 0 ? this.seqFpsOverride : s.manifest.fps;
    const ms = seqPlayInterval(fps, this.seqBurst);
    if (this.seqSavedForceInterval < 0) {
      this.seqSavedForceInterval = this.forceIntervalMs;
    }
    this.forceIntervalMs = ms;
    Logger.i(`序列帧间隔 ${ms}ms（${fps}fps）`);
  }

  private restoreSeqInterval(): void {
    if (this.seqSavedForceInterval >= 0) {
      this.forceIntervalMs = this.seqSavedForceInterval;
      this.seqSavedForceInterval = -1;
    }
  }

  /** 取文本（清单）。失败返回空串 —— 调用方按"清单非法"处理 */
  private async httpGetText(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 2000,
        readTimeout: 4000,
      });
      if (resp.responseCode !== 200 || resp.result === undefined) {
        return '';
      }
      return resp.result as string;
    } catch (e) {
      return '';
    } finally {
      req.destroy();
    }
  }

  /** 取二进制（一帧 JPEG）。失败返回 null */
  private async httpGetBytes(url: string): Promise<Uint8Array | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 2000,
        readTimeout: 4000,
      });
      if (resp.responseCode !== 200 || resp.result === undefined) {
        return null;
      }
      return new Uint8Array(resp.result as ArrayBuffer);
    } catch (e) {
      return null;
    } finally {
      req.destroy();
    }
  }

  /** 供界面/脚本读的序列摘要（一行） */
  seqSummary(): string {
    const s = this.seq;
    if (s === null) {
      return '序列 ○ 未启用';
    }
    if (s.state === 'playing') {
      const where = s.stream
        ? `流式 ${s.cursor + 1}/${s.manifest.count}（窗 ${seqBufFill(s.buf)}/${s.buf.length}）`
        : `预载 ${s.cursor + 1}/${s.frames.length}`;
      return `序列 ● ${s.manifest.name} ${where} · ${this.seqFps.toFixed(1)}fps · ${this.seqPushMs.toFixed(0)}ms/帧`;
    }
    return `序列 ${s.state} · ${s.msg}`;
  }

  /** 界面开关用：现在是否在放序列 */
  seqPlaying(): boolean {
    return this.seq !== null && this.seq.state === 'playing';
  }

  /** 界面开关用：开始播放（返回是否已发起） */
  seqPlay(url: string): boolean {
    const u = url.trim();
    if (u.length === 0) {
      return false;
    }
    this.startSeqLoad(u);
    return true;
  }

  /** 界面开关用：停止播放 */
  seqStop(): void {
    this.stopSeq('界面停止');
  }

  /** 界面开关用：切换流式模式（下次 seqPlay 生效） */
  seqSetStream(on: boolean): void {
    this.seqStream = on;
  }

  seqIsStream(): boolean {
    return this.seqStream;
  }

  /** 界面开关用：极速模式（帧间隔压到 1ms，USB 有多快推多快） */
  seqSetBurst(on: boolean): void {
    this.seqBurst = on;
    this.applySeqInterval();
  }

  seqIsBurst(): boolean {
    return this.seqBurst;
  }

  /** 推帧结果记账（同步与流水线两条路都走这里） */
  private recordPushResult(ok: boolean, now: number): void {
    if (ok) {
      // ★ 只有**确认送达**才提交内容签名 —— 见 tick() 里 pendingSig 的说明。
      //   这样失败/被背压丢掉的帧不会让内容被"记成已推过"，避免最长 10s 的旧画面，
      //   也保证瞬时告警帧（toast / 监控未登录 / 余额不足）一定会重试到显示。
      this.lastSig = this.pendingSig;
      this.lastPushMs = now;
      this.lastOkPushMs = now;
      this.stats.sent++;
      this.sentTimes.push(now);
      while (this.sentTimes.length > 0 && now - this.sentTimes[0] > 3000) {
        this.sentTimes.shift();
      }
      const span = this.sentTimes.length > 1 ? (now - this.sentTimes[0]) / 1000 : 0;
      this.stats.fps = span > 0 ? (this.sentTimes.length - 1) / span : 0;
    } else {
      // 失败：清掉签名，让下一轮无条件重推这一帧内容
      this.lastSig = '';
      this.stats.errors++;
    }
    this.lastSendTs = now;
  }
}

/**
 * 快照探测结果（App 能否直接读 DSH 写出的明文快照）。
 * 放在类外，避免 LcdService 内部再多一层嵌套类型。
 */
export class SnapshotProbe {
  at: number = 0;
  ok: boolean = false;
  note: string = '未探测';
}

