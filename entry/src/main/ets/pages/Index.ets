/**
 * Index.ets — 应用界面：预览画布 + 状态 + 控制
 *
 * 画布按设备密度渲染成真实的 1920x462 像素，再缩放到屏幕上预览；
 * 预览所见即为推送到 LCD 的画面（含 180° 旋转，故预览再转回来）。
 */
import { LcdService } from '../service/LcdService';
import EntryAbility from '../entryability/EntryAbility';
import { RunningLock } from '../service/RunningLock';
import { BRIDGE_PORT } from '../bridge/TelemetryBridge';
import { Logger } from '../common/Logger';
import { display, window } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { SelfTest } from '../usb/SelfTest';

/**
 * 预烘焙序列的三个预设（本机 seq_server.py 的默认目录，见 docs/预烘焙序列.md）：
 *   python3 tools/make_seq.py --src <图> --out ~/.cache/seq-root/rich --frames 120 --q 60
 *   python3 tools/seq_server.py --dir ~/.cache/seq-root --port 8899
 * 每个目录里要有 manifest.json（make_seq.py / frames_to_seq.py 会生成）。
 */
const SEQ_PRESETS: string[] = [
  'http://127.0.0.1:8899/movie',  // 真实影片烘的序列（tools/mp4_to_seq.py；约 40KB/帧 → ~17fps）
  'http://127.0.0.1:8899/rich',   // 面板抓帧 + Ken Burns（约 70KB/帧 → ~7fps）
  'http://127.0.0.1:8899/dash',   // 本机仪表盘抓帧（约 48KB/帧 → ~11.6fps）
  'http://127.0.0.1:8899/long',   // 600 帧长片（配"流式"用，内存只占窗口）
];

@Entry
@Component
struct Index {
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private service: LcdService | null = null;
  private statusTimer: number = -1;

  @State canvasVpW: number = 1280;
  @State canvasVpH: number = 320;
  @State previewScale: number = 0.45;
  @State previewVpH: number = 150;   // 预览容器高度（vp），随缩放变化
  @State previewPct: number = 100;   // 滑块显示值（%）
  /**
   * 「设备 / 画面 / 诊断」三块默认收起。
   * ★ 起因（用户 2026-10-15："鸿蒙app打开的时候界面底部可以保留多一点，不用我每次打开
   *   软件都需要拉大窗口"）：页面有 10 个区块一次性全部渲染，总高远超一屏，
   *   导致每次打开都要往下滚、还要拉大窗口。这三块是**排障用**的，日常占着屏幕只是干扰。
   *   收起后页面明显变短，一屏能看到预览 + 主要控制项。
   */
  @State showAdvanced: boolean = false;
  @State previewBoxH: number = 0;    // 预览框高度（vp）—— 固定值，缩放时不变，避免下方布局跳动
  @State panX: number = 500;         // 横向位置 0..1000（500=居中）
  @State panY: number = 500;         // 纵向位置 0..1000（500=居中）
  private screenW: number = 0;      // 屏宽（vp），用于区分手机/宽屏版式
  /**
   * 平移上限（vp）。必须是 @State：Slider 的 max 只在构建时读一次，
   * 用方法 this.maxPanX() 的话，100% 适应时上限是 0，**放大后滑块上限还是 0 → 拉不动**。
   * 这是"放大后看不到左边、拉不过去"的真正原因。
   */
  @State panMaxX: number = 0;
  @State panMaxY: number = 0;
  private userScale: number = 0;     // >0 = 用户指定缩放；0 = 自动适应
  private screenH: number = 800;     // 屏幕高度（vp）
  /** 预览区滚动控制器：双指手势与滚动条都通过它操作 */
  private previewScroller: Scroller = new Scroller();
  private panLastX: number = 0;
  private panLastY: number = 0;
  private previewBoxW: number = 0;   // 预览框宽度（vp）
  private pinchBase: number = 1;     // 双指捏合起始缩放
  @State running: boolean = false;
  @State usbOpen: boolean = false;
  @State usbLabel: string = '未检测';
  @State deviceInfo: string = '—';
  @State epText: string = '—';
  @State jpegInfo: string = '—';
  @State fpsText: string = '0.0';
  @State sentText: string = '0';
  @State errText: string = '0';
  @State bridgeText: string = '未监听';
  /**
   * 整帧旋转 180°。默认 false：同型号开源驱动在真机上验证过"按握手自动旋转"的启发式不可靠
   * （PM=65/SUB=3 开 180° 反而倒），改成纯手动开关。
   */
  /** 旋转模式：0=跟随设备（默认） 1=强制转 2=强制不转；持久化用这个 */
  @State rotMode: number = 0;
  /** 生效的旋转（开关显示 + 预览跟着转，就是推给屏的方向） */
  @State rotEffective: boolean = false;
  /** 服务给出的模式描述（自动时会带上设备报的角度） */
  @State rotDesc: string = '自动';
  /** 主题：0=仪表盘 1=诊断终端 */
  @State theme: number = 0;
  /** 启动时从偏好读到的打印机格设置，等服务就绪后应用一次 */
  private pendingPrinterCell: string = 'printer';
  /** 偏好里的打印机格设置是否已应用过（每进程只应用一次，避免多实例反复覆盖） */
  private static printerCellApplied: boolean = false;
  // 注：打印机格的开关状态**不在这里存** —— 以 LcdService.printerCell 为唯一真源，
  //     避免"界面副本与服务不一致 → 点击切回旧值"的振荡（实测踩过）。
  /** 应用资源管理器（给 LcdService 读 rawfile 里的官方底图用） */
  private resMgr: resourceManager.ResourceManager | null = null;
  @State lastError: string = '';
  @State vmUrlText: string = 'http://127.0.0.1:8787/vm/frame.jpg';   // VM 监视地址（可改，换环境时用）
  /** 偏好存储：把 VM 地址等设置落盘，重启不再回默认 */
  private prefStore: preferences.Preferences | null = null;
  /** 最近一次已保存的地址（用于检测变化后自动落盘，界面输入与 /set 两条路都能覆盖） */
  private savedVmUrl: string = '';
  /**
   * ★权威地址：服务与偏好文件只认这个值，**不认输入框的文字**。
   * 原因：TextInput 的 text 参数不是双向绑定，它在页面首次构建时就固化了当时的值
   * （那时偏好还没读完 = 默认值），之后每次重新布局都可能用这个陈旧值回调 onChange，
   * 把 vmUrlText 打回默认——实测就是这么在 Canvas 第二次 onReady 时又把默认地址
   * 推给服务、并让 /diag 显示默认值的。
   */
  private appliedVmUrl: string = '';
  private urlChangeEvents: number = 0;
  /** 服务只启动一次（Canvas onReady 会多次触发） */
  private startCalled: boolean = false;
  /** 后台保活是否已申请（副屏驱动必须常驻，否则切走就停推） */
  private bgTask: boolean = false;
  /**
   * Toggle 的 isOn 被程序改值也会触发 onChange —— 会自动把"跟随设备"偷偷改成手动。
   * 同步生效值时置位，下一次 onChange 直接忽略。
   */
  private rotSyncing: boolean = false;
  private prefsReady: boolean = false;
  /** 我们最后一次主动推进服务的地址；只有服务里出现「别的值」才判定为外部 /set 改动 */
  private pushedVmUrl: string = '';
  /** 只有用户显式改过设置才落盘；启动过程一律不写（避免默认值覆盖已保存值） */
  private prefsDirty: boolean = false;
  @State selfTestText: string = '未运行';
  @State selfTestOk: boolean = false;
  /** 运行时体检（链路层）：USB/推帧/数据桥/画面源/本机采集 */
  @State runtimeText: string = '未运行';
  /** 已落盘的 sk- key（余额直连用；DSH 不跑也能刷） */
  private savedDeepseekKey: string = '';
  @State runtimeOk: boolean = false;
  @State ackText: string = '（尚未推帧）';
  @State nightEnabled: boolean = false;
  @State verticalMode: boolean = false;
  @State frameUrl: string = '';
  @State frameCount: string = '0';
  /** VM 取帧状态：填了地址"没反应"时，原因要能直接显示出来，而不是只躺在 /diag 里 */
  @State vmAgeMs: number = -1;
  @State vmErrText: string = '';
  @State vmFramesText: string = '0';
  /** 预烘焙序列（"视频"）状态：一行摘要 + 是否在放 + 是否流式 */
  @State seqText: string = '序列 ○ 未启用';
  @State seqOn: boolean = false;
  @State seqStreamOn: boolean = false;
  @State seqBurstOn: boolean = false;

  aboutToAppear(): void {
    Logger.i('Index 页面创建');
    this.computePreviewScale();
    // 先读偏好，读完再允许服务用配置：否则 Canvas onReady 会先用默认值起服务，
    // 之后即使读到保存的地址也会被默认值盖回去（实测：存进去了但重启读不回来）
    this.prefsReady = false;
    this.loadPrefs();
    this.logSafeArea();
  }

  aboutToDisappear(): void {
    // ★ 页面销毁必须清掉每秒的 UI 刷新定时器（2026-10-31 审计 A9）：
    //   不清的话定时器在页面销毁后仍每秒跑 refreshStatus —— 持续读服务状态、
    //   写已拆组件树的 @State，白耗电还可能每秒刷异常日志。
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  /** 读取已保存的设置（VM 地址 + 三个开关） */
  /** 把 sk- key 落盘（只做一次；失败不影响运行） */
  private saveDeepseekKey(k: string): void {
    if (this.prefStore === null || k.length <= 10) {
      return;
    }
    const st = this.prefStore;
    st.put('deepseekKey', k).then(() => st.flush()).then(() => {
      Logger.i('sk- key 已落盘（重启后余额仍可直连，不依赖 DSH）');
    }).catch((e: Object) => {
      Logger.w('sk- key 落盘失败: ' + Logger.safe(e));
    });
  }

  private async loadPrefs(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      // 顺手拿到 resourceManager（给 LcdService 读 rawfile 官方底图用）
      this.resMgr = ctx.resourceManager;
      this.prefStore = await preferences.getPreferences(ctx, 'dshlcd');
      // ★ sk- key：落盘后重启即可用 —— 余额因此**完全不依赖 DSH**
      //   （key 首次由 DSH 侧插件递过来，这里持久化）
      const savedKey = await this.prefStore.get('deepseekKey', '') as string;
      if (savedKey !== undefined && savedKey !== null && savedKey.length > 10) {
        this.savedDeepseekKey = savedKey;
      }
      const url = await this.prefStore.get('vmUrl', '') as string;
      if (url !== undefined && url !== null && url.trim().length > 0) {
        this.appliedVmUrl = url.trim();
        this.vmUrlText = this.appliedVmUrl;
        Logger.i(`已读取保存的 VM 监视地址: ${this.appliedVmUrl}`);
      } else {
        Logger.i('没有保存过 VM 监视地址，用默认值');
        this.appliedVmUrl = this.vmUrlText.trim();
      }
      this.savedVmUrl = this.appliedVmUrl;
      const v = await this.prefStore.get('vertical', false) as boolean;
      const n = await this.prefStore.get('night', false) as boolean;
      // 旋转：读三态模式。老的 rotate180 布尔**故意不沿用**：
      // 真机实测必须转 180° 才正，沿用旧布尔会让升级后的默认值仍然是错的。
      const rm = await this.prefStore.get('rotMode', 0) as number;
      this.rotMode = rm;
      const th = await this.prefStore.get('theme', 0) as number;
      // ★ 两道守卫（第二道是这次审查新加的）：
      //   ① 若服务已在本进程里被显式设过主题（/set?theme=N），旧偏好不许覆盖它
      //      —— 实测：set?theme=15 后屏上先画出 15，随后被存档的 11 覆盖回去。
      //   ② **偏好里的主题号必须在合法范围内**。原实现直接 `this.theme = th`，
      //      而 `/set?theme=N` 只收 `n<=15` —— 两者不对称：
      //      若某天删掉一个主题（合法范围变小），存档里的旧号会被原样应用，
      //      渲染调度里没有对应分支 → 走 else 兜底画成主题 0，
      //      但 `diag` 仍报那个不存在的号 → **状态与实际不符，排障时会被误导**。
      //      所以越界时回落到服务默认值（0），而不是照搬。
      const THEME_MAX = 18;   // 新增主题 18（天气）后必须同步   // ★ 新增主题 16（自走贪吃蛇）/17（超级玛丽）后必须同步，否则存档被丢弃
      const svcRef = this.service;
      if (svcRef !== null && svcRef.themeTouched) {
        Logger.i(`偏好里的主题 ${th} 被跳过（运行时已显式设过 ${svcRef.theme}）`);
      } else if (typeof th !== 'number' || !Number.isFinite(th) || th < 0 || th > THEME_MAX) {
        Logger.w(`偏好里的主题 ${th} 越界（合法 0..${THEME_MAX}）→ 回落到默认 0`);
        this.theme = 0;
      } else {
        this.theme = th;
      }
      const pc = await this.prefStore.get('printerCell', 'printer') as string;
      this.pendingPrinterCell = pc;
      this.verticalMode = v; this.nightEnabled = n;
    } catch (e) {
      Logger.w(`读取偏好失败: ${Logger.safe(e)}`);
    }
    this.prefsReady = true;
    // 读完之后必须把「当前地址」同步给服务与 pushedVmUrl 一起：
    // 这两个值一旦不同步，refreshStatus 就会误判成"外部改了地址"，
    // 反过来把服务里的默认值写回偏好文件（这就是地址存不住的根因之一）。
    const svc = this.service;
    const cur = this.appliedVmUrl.length > 0 ? this.appliedVmUrl : this.vmUrlText.trim();
    this.appliedVmUrl = cur;
    this.vmUrlText = cur;
    if (svc !== null) {
      svc.vmUrl = cur;
      svc.verticalMode = this.verticalMode;
      svc.nightEnabled = this.nightEnabled;
      svc.rotMode = this.rotMode;
      svc.setTheme(this.theme, false);   // 系统路径：回放偏好，不置 touched
      Logger.i(`已把保存值推给服务: ${cur}`);
    }
    this.pushedVmUrl = cur;
    this.refreshStatus();
  }

  /**
   * 把当前设置落盘（flush 后即使进程被杀也不丢）。
   * reason 只用于日志：出问题时能一眼看出是谁写的。
   */
  private async savePrefs(reason: string): Promise<void> {
    const st = this.prefStore;
    if (st === null) {
      return;
    }
    // 关键守卫：偏好还没读完、或不是用户显式改动，就不写。
    if (!this.prefsReady || !this.prefsDirty) {
      Logger.i(`跳过保存（原因=${reason} prefsReady=${this.prefsReady} dirty=${this.prefsDirty}）`);
      return;
    }
    try {
      await st.put('vmUrl', this.appliedVmUrl);
      await st.put('vertical', this.verticalMode);
      await st.put('night', this.nightEnabled);
      await st.put('rotMode', this.rotMode);
      await st.put('theme', this.theme);
      // 原样写服务的值（支持 printer / dotii / v4 三种）。
      // 之前这里只认 'dotii'，'v4' 会被写成 'printer' —— 偏好与运行时不一致。
      await st.put('printerCell',
        this.service !== null ? this.service.printerCell : 'printer');
      await st.flush();
      this.savedVmUrl = this.appliedVmUrl;
      Logger.i(`设置已保存（原因=${reason}）: vmUrl=${this.appliedVmUrl} vertical=${this.verticalMode} night=${this.nightEnabled} rotMode=${this.rotMode}`);
    } catch (e) {
      Logger.w(`保存偏好失败: ${Logger.safe(e)}`);
    }
  }

  /**
   * 预览尽量占满屏幕：取「可用宽度」与「最大高度」两个约束里更小的缩放，
   * 这样小屏也不会横向裁切，大屏则吃到高度上限。
   */
  /**
   * 预览缩放。
   * 关键：预览框高度 previewBoxH 只在首次计算，缩放时**不再改变**——
   * 否则滑块一动，下面的状态与按钮就跟着位移，非常难受。
   */
  private computePreviewScale(): void {
    let availW = 360;
    try {
      const d = display.getDefaultDisplaySync();
      const density = d.densityPixels > 0 ? d.densityPixels : 1;
      availW = (d.width / density) * 0.94;
      this.screenH = d.height / density;
      this.screenW = d.width / density;
    } catch (e) {
      Logger.w(`取屏幕尺寸失败，用回退值: ${Logger.safe(e)}`);
    }
    // 实测框宽优先：availW=0.94×屏宽只是估算，实际框是"屏宽-32"，
    // 用估算值算自动缩放会让内容比框宽 9vp → 明明点了"适应"却一直显示左右滑块。
    if (this.previewBoxW <= 0) {
      this.previewBoxW = availW;
    }
    if (this.previewBoxH <= 0) {
      // 框高固定（缩放时不变，避免下方布局跳动）。
      // 手机（窄屏）给 58%：默认 40% 时手机上预览只有 165x40vp，太小看不清；
      // 平板/宽屏仍用 40%。
      const phoneLike = this.screenW > 0 && this.screenW < 600;
      const frac = phoneLike ? 0.58 : 0.40;
      this.previewBoxH = Math.max(200, Math.round(this.screenH * frac));
      Logger.i(`版式: ${phoneLike ? '手机' : '宽屏'}（屏宽 ${Math.round(this.screenW)}vp）预览占屏高 ${Math.round(frac * 100)}%`);
    }
    if (this.userScale > 0) {
      this.previewScale = this.userScale;
    } else {
      // 自动：缩放到刚好放进框内（宽或高哪个先到算哪个）
      this.previewScale = Math.min(this.previewBoxW / this.canvasVpW, this.previewBoxH / this.canvasVpH);
    }
    // 滑块下限必须低于"自动适应"可能算出的值（手机上 353/1920 ≈ 18%），
    // 否则 Slider 会把 value 夹到 min 并回调 onChange，把自动缩放"焊死"成手动低倍
    // （实测日志：缩放=0.300 (手动)，内容只有 165x40vp，预览小得看不清）。
    const pct = Math.round(this.previewScale * 100);
    this.previewPct = pct < 10 ? 10 : (pct > 300 ? 300 : pct);
    // 缩放变化后复位到**居中**（500），然后拨滑块就能左右看
    this.setPan(500, 500);
    Logger.i(`平移范围: 横向 ${this.overflowX()}vp / 纵向 ${this.overflowY()}vp `
      + `(内容 ${(this.canvasVpW * this.previewScale).toFixed(0)}x${(this.canvasVpH * this.previewScale).toFixed(0)}vp`
      + ` 框 ${this.previewBoxW.toFixed(0)}x${this.previewBoxH.toFixed(0)}vp) 缩放=${this.previewScale.toFixed(3)}`
      + ` 缩放原点补偿=${((this.canvasVpW * (this.previewScale - 1)) / 2).toFixed(0)}vp`);
    Logger.i(`预览: 缩放=${this.previewScale.toFixed(3)} 框高=${this.previewBoxH}vp `
      + `内容=${(this.canvasVpW * this.previewScale).toFixed(0)}x`
      + `${(this.canvasVpH * this.previewScale).toFixed(0)}vp ` + (this.userScale > 0 ? '(手动)' : '(自动)'));
  }

  /** 内容横向可平移上限（vp） */
  /** 内容超出预览框的横向溢出量（vp）；<=0 表示没放大到超出，无需平移 */
  private overflowX(): number {
    const c = this.canvasVpW * this.previewScale - this.previewBoxW;
    return c > 0 ? Math.round(c) : 0;
  }

  /** 内容超出预览框的纵向溢出量（vp） */
  private overflowY(): number {
    const c = this.canvasVpH * this.previewScale - this.previewBoxH;
    return c > 0 ? Math.round(c) : 0;
  }

  private maxPanX(): number {
    const c = this.canvasVpW * this.previewScale - this.previewBoxW;
    return c > 0 ? Math.round(c) : 0;
  }

  /** 内容纵向可平移上限（vp） */
  private maxPanY(): number {
    const c = this.canvasVpH * this.previewScale - this.previewBoxH;
    return c > 0 ? Math.round(c) : 0;
  }

  /** 箭头按钮：dir 0=左 1=右 2=上 3=下；一次移动 15% 行程（无键盘设备也能精确挪动） */
  private nudge(dir: number): void {
    const step = 150;
    if (dir === 0) {
      this.setPan(this.panX - step, this.panY);
    } else if (dir === 1) {
      this.setPan(this.panX + step, this.panY);
    } else if (dir === 2) {
      this.setPan(this.panX, this.panY - step);
    } else {
      this.setPan(this.panX, this.panY + step);
    }
  }

  /**
   * 申请后台保活（continuous task，dataTransfer）。
   *
   * 为什么在这里而不是服务里：只有 UI 层能正确拿到 UIAbilityContext；
   * 之前写在服务里用 getContext(画布 ctx) 拿错了对象，真机直接抛 401。
   * 另外 wantAgent.getWantAgent() 返回的是 Promise，**必须 await** —— 直接把它
   * 传给 startBackgroundRunning 同样是 401（参数类型不对）。
   */
  private async acquireBgTask(): Promise<void> {
    if (this.bgTask) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: ctx.abilityInfo.bundleName, abilityName: ctx.abilityInfo.name }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      // 逐个试：真机实测 DATA_TRANSFER 会被拒（9800005 bgMode is invalid），
      // 不同 ROM/机型放行的模式不一样，所以按优先级挨个申请，谁成用谁。
      const modes: number[] = [
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING,
        backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION,
        backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION
      ];
      const names: string[] = ['dataTransfer', 'taskKeeping', 'multiDeviceConnection', 'bluetoothInteraction'];
      let lastErr = '';
      for (let i = 0; i < modes.length; i++) {
        try {
          await backgroundTaskManager.startBackgroundRunning(ctx, modes[i], agent);
          this.bgTask = true;
          if (this.service !== null) {
            this.service.bgTask = true;
          }
          EntryAbility.bgMode = names[i];
          EntryAbility.bgErr = '';
          Logger.i(`后台保活已开启（${names[i]}）—— 切到别的应用也会继续推帧`);
          return;
        } catch (e) {
          const err = e as BusinessError;
          lastErr = `${names[i]}: ${err === undefined ? Logger.safe(e) : err.code + ' ' + err.message}`;
          Logger.w(`后台保活模式 ${names[i]} 不被允许：${lastErr}`);
        }
      }
      EntryAbility.bgMode = '';
      EntryAbility.bgErr = lastErr;
      Logger.w(`后台保活全部模式都被拒（切走会停推）：${lastErr}`);
    } catch (e) {
      const err = e as BusinessError;
      EntryAbility.bgMode = '';
      EntryAbility.bgErr = err === undefined ? Logger.safe(e) : `${err.code} ${err.message}`;
      Logger.w(`后台保活申请失败（切走会停推）: ${err === undefined ? Logger.safe(e) : err.code + ' ' + err.message}`);
    }
  }

  private async releaseBgTask(): Promise<void> {
    if (!this.bgTask) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      this.bgTask = false;
      if (this.service !== null) {
        this.service.bgTask = false;
      }
      Logger.i('后台保活已释放');
    } catch (e) {
      Logger.w(`释放后台保活失败: ${Logger.safe(e)}`);
    }
  }

  /** 把旋转模式推给服务并刷新显示（界面唯一入口，避免两处各写一半） */
  private rotApply(): void {
    const svc = this.service;
    if (svc !== null) {
      svc.rotMode = this.rotMode;
      svc.setTheme(this.theme, false);   // 系统路径：回放偏好，不置 touched
      this.rotEffective = svc.rotateNow();
      this.rotDesc = svc.rotModeDesc();
    }
    Logger.i(`旋转模式改为 ${this.rotMode}（${this.rotDesc}）`);
  }

  /** 用户显式改动设置：标记脏 + 落盘。这是**唯一**允许写盘的入口。 */
  private markDirty(reason: string): void {
    this.prefsDirty = true;
    this.savePrefs(reason);
  }

  /**
   * 远程取帧状态一行话。
   * 之前只显示"远程预览"URL，地址填错 / livepad 没跑 / 需要令牌 时界面上完全没有反馈，
   * 用户只能猜（"填了没反应，可能是要输入令牌"）。现在把 vmErr / vmAge 直接显示出来。
   */
  private vmStatusLine(): string {
    const err = this.vmErrText;
    if (err.length > 0) {
      if (err.indexOf('401') >= 0) {
        return `${err}（需要令牌？改用 /vm/frame.jpg 这个免鉴权路径）`;
      }
      if (err.indexOf('403') >= 0) {
        return `${err}（livepad 侧鉴权拒绝）`;
      }
      return err;
    }
    // 注意：vmAge 是"距上次**尝试**取帧"的时间（服务在请求前就打了时间戳），
    // 所以只有真的收到过帧（vmFrames>0）才能说"取到"。
    if (this.vmFramesText !== '0') {
      return `${(this.vmAgeMs / 1000).toFixed(1)}s 前取到 · 共 ${this.vmFramesText} 帧`;
    }
    return '尚未取到画面（正在轮询）';
  }

  private vmStatusColor(): string {
    if (this.vmErrText.length > 0) {
      return '#F85149';
    }
    return this.vmFramesText !== '0' ? '#3FB950' : '#D29922';
  }

  /** 顶部状态条一行话 */
  private summaryText(): string {
    const usb = this.usbOpen ? 'USB 已连接' : 'USB 未连接';
    const err = this.errText === '0' ? '无错误' : `错误 ${this.errText}`;
    return `${usb} · ${this.jpegInfo} · ${this.fpsText} fps · 已发 ${this.sentText} · ${err}`;
  }

  /**
   * 平移（居中模型）：
   *   panX = 0        → 内容居中（默认，也是缩放后的初始位置）
   *   panX = +half    → 看到最左边
   *   panX = -half    → 看到最右边
   * 只有当内容真的超出预览框（overflow > 0，也就是放大超过 100%）时，半幅才 > 0，
   * 滑块才会有行程；没放大时 slider 会被禁用（灰掉），不会误导。
   */
  private setPan(x: number, y: number): void {
    // panX/panY 现在是 0..1000 的百分比：0=最左/最上、500=居中、1000=最右/最下。
    // 这个映射最直白（和 Windows 版一致）：滑块往右拨就是看右边。
    const ox = this.overflowX();
    const oy = this.overflowY();
    this.panMaxX = ox > 0 ? 1000 : 0;   // @State：0 表示"没超出"，滑块禁用
    this.panMaxY = oy > 0 ? 1000 : 0;
    this.panX = x < 0 ? 0 : (x > 1000 ? 1000 : x);
    this.panY = y < 0 ? 0 : (y > 1000 ? 1000 : y);
  }

  private refreshStatus(): void {
    // /set?vmurl=... 这类远程改动也要落盘：发现服务里的地址与我们推下去的不一致就存一次。
    // 前提是 pushedVmUrl 始终与「我们给服务的值」一致——startService / loadPrefs 都保证这点。
    const svc0 = this.service;
    if (svc0 !== null && this.prefStore !== null && this.prefsReady
        && this.pushedVmUrl.length > 0 && svc0.vmUrl !== this.pushedVmUrl) {
      Logger.i(`检测到外部改地址: ${svc0.vmUrl}`);
      this.appliedVmUrl = svc0.vmUrl;
      this.vmUrlText = svc0.vmUrl;
      this.pushedVmUrl = svc0.vmUrl;
      this.prefsDirty = true;
      this.savePrefs('refreshStatus:外部改地址');
    }
    const s = this.service;
    if (s === null) {
      return;
    }
    this.usbOpen = s.usbOpen;
    this.usbLabel = s.usbLabel;
    const info = s.deviceInfo;
    this.deviceInfo = info === null ? '（未握手）' : info.toString();
    this.epText = s.endpointSummary;
    const st = s.stats;
    this.jpegInfo = `${st.jpegW}x${st.jpegH}  ${(st.jpegSize / 1024).toFixed(0)}KB`;
    this.fpsText = st.fps.toFixed(1);
    this.sentText = `${st.sent}`;
    this.errText = `${st.errors}`;
    this.lastError = s.lastError;
    this.selfTestText = s.selfTestSummary;
    this.selfTestOk = SelfTest.allPass(s.selfTests);
    // sk- key：有保存值就注入；服务拿到新 key 就落盘
    if (this.savedDeepseekKey.length > 10) {
      s.injectDeepseekKey(this.savedDeepseekKey);
    } else if (s.hasDeepseekKey) {
      this.savedDeepseekKey = s.getDeepseekKey();
      this.saveDeepseekKey(this.savedDeepseekKey);
    }
    this.runtimeText = s.runtimeSummary;
    let rtOk = s.runtimeChecks.length > 0;
    for (const it of s.runtimeChecks) {
      if (!it.ok) { rtOk = false; }
    }
    this.runtimeOk = rtOk;
    this.ackText = s.lastAck;
    this.frameUrl = s.frameUrl;
    this.frameCount = `${s.frameCount}`;
    this.rotMode = s.rotMode;
    this.theme = s.theme;
    // ★ 这里**故意不**从快照回写打印机格开关（以服务为准）。
    //   原因（实测踩过）：refreshStatus() 每秒跑一次，而它拿的是 status 快照；
    //   用户点按钮把服务设成 'dotii' 后，下一秒就被这条快照回写成 'printer' ——
    //   表现为"点了按钮没反应，Dotii 还留在原格"。
    //   printerCell 以**服务为准**，界面只在初始化（读偏好）时同步一次。
    //
    //   同理，`this.theme = s.theme` 这一行也有同样的风险，但它依赖"用户切主题后
    //   服务也是同一个值"，本会话暂未出问题，先保持原样、记录在此。
    const eff = s.rotateNow();
    if (eff !== this.rotEffective) {
      this.rotSyncing = true;    // 让随之而来的 onChange 忽略掉
      this.rotEffective = eff;
    }
    this.rotDesc = s.rotModeDesc();
    this.vmAgeMs = s.vmAgeMsForUi();
    this.vmErrText = s.vmErrForUi();
    this.vmFramesText = `${s.vmFramesForUi()}`;
    // 预烘焙序列（"视频"）状态：以服务为准
    this.seqText = s.seqSummary();
    this.seqOn = s.seqPlaying();
    this.seqStreamOn = s.seqIsStream();
    this.seqBurstOn = s.seqIsBurst();
    if (st.bridgeAge < 0) {
      this.bridgeText = `未收到数据 (UDP ${BRIDGE_PORT})`;
    } else {
      this.bridgeText = `${st.bridgeAge}s 前收到 (UDP ${BRIDGE_PORT})`;
    }
  }

  private startService(): void {
    if (this.service === null) {
      this.service = new LcdService(this.ctx, this.resMgr);
      // 生命周期钩子（EntryAbility.onForeground）要拿到实例才能立刻补帧
      LcdService.active = this.service;
      this.service.onStatus = () => {
        this.refreshStatus();
      };
      this.service.onCanvasResize = (w: number, h: number) => {
        this.canvasVpW = w;
        this.canvasVpH = h;
        this.computePreviewScale();
      };
    }
    // ★ 地址同步必须在**创建服务之后**做。
    // 旧代码把同步放在创建之前，于是"偏好先读完、Canvas onReady 后到"这条路径下
    // 服务是带着默认地址 new 出来的，pushedVmUrl 却已经是保存值；
    // 随后 start() 的 refreshStatus 看到两者不等 → 误判成外部改地址 →
    // 把默认值写回偏好文件（手机版"输过的地址存不住"就是这个顺序 bug）。
    if (this.prefsReady) {
      // 注意：这里用 appliedVmUrl（权威值），**不能用输入框文字**——
      // Canvas onReady 会触发多次（画布尺寸变化后重建），每次都会走到这里，
      // 而输入框文字可能已被陈旧回调打回默认值。
      const want = this.appliedVmUrl.length > 0 ? this.appliedVmUrl : this.vmUrlText.trim();
      this.appliedVmUrl = want;
      this.service.vmUrl = want;
      this.pushedVmUrl = want;
      Logger.i(`启动前同步监视地址: ${want}`);
    }
    this.service.rotMode = this.rotMode;
    this.service.theme = this.theme;
    this.service.verticalMode = this.verticalMode;
    this.service.nightEnabled = this.nightEnabled;
    // Canvas onReady 会触发多次（画布尺寸校准后重建），但服务只需要启动一次：
    // 重复 start() 会重新起 FrameServer、重复跑自检，日志里是一串重复行。
    if (this.startCalled) {
      this.refreshStatus();
      return;
    }
    this.startCalled = true;
    const svc: LcdService = this.service;   // 非空局部引用（回调里 this.service 会被判可能为 null）
    svc.start().then(() => {
      this.running = true;
      // 服务就绪后，把偏好里的打印机格设置应用一次（之后以服务为准，界面不再回写）
      // ★ 只应用一次（静态守卫）：HarmonyOS 可能同时存在多个 Index 实例，
      //   每个实例都跑一遍这里的话，会把用户/命令刚设的 printerCell 覆盖回偏好值
      //   —— 表现就是"设完 3 秒后又自己变回去"（实测踩过）。
      //   再加两条：① **运行时显式设过的优先**（svc.printerCellTouched）；
      //   ② **服务默认值优先于旧偏好** —— 默认已定稿为 v6（用户 2026-10-14"就这个定格吧"），
      //      若偏好里还存着旧值（如 dotii/v4），不能再把定稿版覆盖掉（实测踩过）。
      if (!Index.printerCellApplied && !svc.printerCellTouched
          && svc.printerCell === 'printer'
          && this.pendingPrinterCell !== 'printer') {
        Index.printerCellApplied = true;
        svc.setPrinterCell(this.pendingPrinterCell);
      }
      this.pendingPrinterCell = 'printer';
      this.computePreviewScale();
      this.refreshStatus();
      this.acquireBgTask();
      // ★ 运行锁：熄屏/休眠时保持 CPU 运行（continuous task 挡不住熄屏冻结）。
      //   启动就持有并长期保持 —— 状态副屏的语义是"只要应用在跑就一直喂屏"。
      void RunningLock.acquire();
    }).catch((e: Object) => {
      Logger.e(`启动失败: ${Logger.safe(e)}`);
    });
    if (this.statusTimer < 0) {
      this.statusTimer = setInterval(() => {
        // ★ 每秒一次的 UI 刷新必须自带兜底：refreshStatus 会读大量服务状态，
        //   任何一处抛异常都会变成"每秒一次的未捕获异常"。虽然定时器本身不会被杀，
        //   但会持续刷错误日志并可能让界面停在半更新状态。
        try {
          this.refreshStatus();
        } catch (e) {
          Logger.w(`界面刷新异常: ${Logger.safe(e)}`);
        }
      }, 1000);
    }
  }

  build() {
    // 背景层 + 内容层分开，这是"沉浸式但不被挖孔挡"的标准做法：
    //   背景层 expandSafeArea → 铺满整个窗口（含挖孔区/手势条区），没有白边；
    //   内容层**不**扩展安全区 → 由系统自动避开挖孔，标题不会被前置摄像头挡住。
    // 之前两层合一（Scroll 自己 expandSafeArea），结果"Trofeo Vision"滚到顶栏就被挖孔遮住，
    // 只能看到结尾的 sion。
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#0D1117')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Scroll() {
        Column({ space: 8 }) {
          // 版式参照 DiPlay 诊断仪：整页水平内边距 16，区块各自满宽，不再用 96% 居中

      this.header()
      this.summaryBar()

      this.sect('预览', `${this.previewPct}%`)

      // 预览区：平移完全由我们自己算（panX/panY），不依赖 Scroll / 手势组件，
      // 这样在任何输入方式下都不会"滑不动"。
      Stack({ alignContent: Alignment.TopStart }) {
        Stack({ alignContent: Alignment.TopStart }) {
          Canvas(this.ctx)
            .width(this.canvasVpW)
            .height(this.canvasVpH)
            .scale({ x: this.previewScale, y: this.previewScale })
            .rotate({ angle: this.rotEffective ? 180 : 0 })
            .backgroundColor('#000000')
            .onReady(() => {
              Logger.i(`Canvas ready ${this.canvasVpW}x${this.canvasVpH} vp`);
              this.startService();
            })
        }
        .width(this.canvasVpW * this.previewScale)
        .height(this.canvasVpH * this.previewScale)
        // 位移 = ①缩放原点补偿 + ②平移量
        // ① .scale() 是绕自身中心缩放、不改布局盒，所以放大后画面的视觉左边缘会比容器
        //    左边缘再往左偏 (scale-1)*宽/2；不补偿的话这段内容永远在屏幕外（"看不到左边"），
        //    而右边会多出一段空白（"左右行程不一致"）。补偿 = +(scale-1)*canvasVpW/2。
        // ② 0..1000 → 0=最左(位移0) … 1000=最右(-溢出量)，两端正好是图像左右边缘。
        .translate({
          x: (this.canvasVpW * (this.previewScale - 1)) / 2 - this.overflowX() * (this.panX / 1000),
          y: (this.canvasVpH * (this.previewScale - 1)) / 2 - this.overflowY() * (this.panY / 1000)
        })
      }
      .width('100%')
      .height(this.previewBoxH)
      .clip(true)
      .borderRadius(10)
      .border({ width: 1, color: '#21262D' })
      .backgroundColor('#010409')
      // 关键：平移的"溢出量"必须用**实测**框宽高来算。
      // 原来用 0.94×屏宽 估算，与真实框（屏宽-32）不等 → 明明点了"适应"却一直
      // 显示左右滑块（内容比框宽 9vp），行程也不对称。
      .onAreaChange((_old: Area, now: Area) => {
        const w = Number(now.width);
        const h = Number(now.height);
        if (w > 0 && h > 0 && (Math.abs(w - this.previewBoxW) > 0.5 || Math.abs(h - this.previewBoxH) > 0.5)) {
          this.previewBoxW = w;
          this.previewBoxH = h;
          // computePreviewScale() 内部会调 setPan()，所以自动模式走它、手动模式只复位范围
          if (this.userScale <= 0) {
            this.computePreviewScale();
          } else {
            this.setPan(this.panX, this.panY);
          }
          Logger.i(`预览框实测 ${w.toFixed(1)}x${h.toFixed(1)}vp 内容=${(this.canvasVpW * this.previewScale).toFixed(0)}x`
            + `${(this.canvasVpH * this.previewScale).toFixed(0)}vp 横向溢出=${this.overflowX()}vp 纵向溢出=${this.overflowY()}vp`);
        }
      })
      // 手势分工（两条互不抢）：
      //   单指拖动 = 整页滚动（否则"夜间熄屏"以下的内容会滚不出来）
      //   双指拖动 = 平移预览（放大后看左右）；双指捏合 = 缩放
      .gesture(
        GestureGroup(GestureMode.Parallel,
          // 单指/多指拖动平移（fingers=1 表示至少 1 指，双指拖动同样生效）
          PanGesture({ fingers: 2, distance: 2 })
            .onActionStart(() => {
              this.panLastX = 0;
              this.panLastY = 0;
            })
            .onActionUpdate((event: GestureEvent) => {
              const dx = event.offsetX - this.panLastX;
              const dy = event.offsetY - this.panLastY;
              this.panLastX = event.offsetX;
              this.panLastY = event.offsetY;
              this.setPan(this.panX - dx, this.panY - dy);
            })
            .onActionEnd(() => {
              this.panLastX = 0;
              this.panLastY = 0;
            }),
          // 双指捏合缩放（触摸屏与触控板都支持）
          PinchGesture({ fingers: 2, distance: 5 })
            .onActionStart(() => {
              this.pinchBase = this.previewScale;
            })
            .onActionUpdate((event: GestureEvent) => {
              let sc = this.pinchBase * event.scale;
              if (sc < 0.3) {
                sc = 0.3;
              }
              if (sc > 3.0) {
                sc = 3.0;
              }
              this.userScale = sc;
              this.computePreviewScale();
            }),
          // 双击复位（回到左上角 + 自动缩放）
          TapGesture({ count: 2 })
            .onAction(() => {
              this.userScale = 0;
              this.computePreviewScale();
              this.panX = 0;
              this.panY = 0;
            })
        )
      )

      this.viewCard()

      this.controls()
      this.themeRow()
      this.seqRow()
      this.switchCard()
      this.sect('数据源', 'VM 监视')
      this.vmCard()

      // 状态分三张卡：设备 / 画面 / 诊断。原来 12 行挤在一张卡里，
      // 手机上既难扫读、长值又容易溢出。
      // ---- 高级/排障区（默认收起）----
      // 收益：收起后省掉 3 个卡片 + 3 个标题的高度，且日常操作（启动/换主题/换开关）
      // 都在上方，不用再滚到底。
      Row({ space: 8 }) {
        Text(this.showAdvanced ? '▾ 高级与排障' : '▸ 高级与排障')
          .fontSize(12).fontColor('#7D8590')
        Text(this.showAdvanced ? '（点此收起）' : '（设备 / 画面 / 诊断）')
          .fontSize(10).fontColor('#484F58')
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor('#161B22')
      .borderRadius(8)
      .border({ width: 1, color: '#21262D' })
      .onClick(() => {
        this.showAdvanced = !this.showAdvanced;
      })

      if (this.showAdvanced) {
        this.sect('设备', this.usbOpen ? 'USB 已连接' : 'USB 未连接')
        this.deviceCard()

        this.sect('画面', this.running ? '推送中' : '未推送')
        this.pictureCard()

        this.sect('诊断', '')
        this.diagCard()
      }
      this.footer()

      }
      .width('100%')
      // ★ 底部留白（用户 2026-10-14："鸿蒙app打开的时候界面底部可以保留多一点，
      //   不用我每次打开软件都需要拉大窗口"）。
      //   原来只有 20，窗口打开时最后一屏内容贴着底边，用户必须手动拉大窗口才能看全。
      //   改为 140：给底部留出充足余量，且手势条不会压住内容。
      .padding({ left: 16, right: 16, bottom: 140 })
      .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      // 顶部**故意不**扩展安全区（避开挖孔）；底部仍延伸，免得手势条处留一条边
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
  }

  /** 量一下避让区并记日志：确认"内容层不扩展安全区"确实拿到了挖孔高度 */
  private async logSafeArea(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const w = await window.getLastWindow(ctx);
      const sys = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const d = display.getDefaultDisplaySync();
      const den = d.densityPixels > 0 ? d.densityPixels : 1;
      Logger.i(`避让区: 系统 top=${sys.topRect.height}px(${(sys.topRect.height / den).toFixed(1)}vp)`
        + ` bottom=${sys.bottomRect.height}px(${(sys.bottomRect.height / den).toFixed(1)}vp)`
        + ` left=${sys.leftRect.width}px right=${sys.rightRect.width}px`
        + ` | 手势条 bottom=${nav.bottomRect.height}px(${(nav.bottomRect.height / den).toFixed(1)}vp)`
        + ` | 密度=${den}`);
    } catch (e) {
      Logger.w(`取避让区失败（不影响功能）: ${Logger.safe(e)}`);
    }
  }

  // ================= 界面片段 =================
  // 风格参照隔壁 DiPlay 诊断仪：标题 + 状态药丸、状态条、分区小标题、
  // 等宽字体显示数值、染色提示条（#0D2818 + #3FB950）、按钮分主次色。

  /** 标题行 + 运行状态药丸 */
  @Builder
  header() {
    Row() {
      Text('Trofeo Vision').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#E6EDF3')
      Text('9.16 LCD').fontSize(12).fontColor('#7D8590').margin({ left: 6, top: 5 })
      Blank()
      Row({ space: 6 }) {
        Column()
          .width(6).height(6).borderRadius(3)
          .backgroundColor(this.running ? '#3FB950' : '#8B949E')
        Text(this.running ? 'RUNNING' : 'STOPPED')
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(this.running ? '#3FB950' : '#8B949E')
      }
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor(this.running ? '#0D2818' : '#161B22')
      .borderRadius(6)
      .border({ width: 1, color: this.running ? '#238636' : '#30363D' })
    }
    .width('100%')
    .margin({ top: 10 })
  }

  /** 一行摘要条（USB / 分辨率 / 帧率 / 已发 / 错误） */
  @Builder
  summaryBar() {
    Text(this.summaryText())
      .fontSize(12)
      .fontColor('#C9D1D9')
      .width('100%')
      .padding(10)
      .backgroundColor('#161B22')
      .borderRadius(8)
      .border({ width: 1, color: '#21262D' })
      .wordBreak(WordBreak.BREAK_ALL)
  }

  /** 分区小标题：左侧色条 + 标题 + 右侧等宽注脚 */
  @Builder
  sect(title: string, note: string) {
    Row({ space: 7 }) {
      Column().width(3).height(12).backgroundColor('#238636').borderRadius(2)
      Text(title).fontSize(12).fontColor('#C9D1D9').fontWeight(FontWeight.Medium)
      Blank()
      Text(note).fontSize(11).fontColor('#7D8590').fontFamily('monospace')
    }
    .width('100%')
    .margin({ top: 6, bottom: 1 })
  }

  /** 键值行：标签可压缩、值用等宽字体并按状态着色 */
  @Builder
  stat(label: string, value: string, color: string) {
    // 窄屏（手机 376vp）上"标签固定 + 长值"会横向冲出屏幕：
    // VM 地址 http://192.168.3.57:8787/vm/frame.jpg 约 252vp，加标签 > 屏宽。
    // 所以标签可压缩（上限 100vp），值允许按字符换行。
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor('#7D8590')
        .constraintSize({ maxWidth: 100, minWidth: 72 })
      Text(value)
        .fontSize(12)
        .fontFamily('monospace')
        .fontColor(color)
        .layoutWeight(1)
        .wordBreak(WordBreak.BREAK_ALL)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Top)
  }

  /** 染色提示条（绿底 = 操作指引；红底 = 故障提示） */
  @Builder
  banner(text: string, fg: string, bg: string, border: string) {
    Text(text)
      .fontSize(11)
      .fontFamily('monospace')
      .fontColor(fg)
      .width('100%')
      .padding(9)
      .backgroundColor(bg)
      .borderRadius(8)
      .border({ width: 1, color: border })
      .wordBreak(WordBreak.BREAK_ALL)
  }

  /** 圆形箭头按钮 */
  @Builder
  arrow(dir: number, enabled: boolean) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      Path()
        .commands(dir === 0 ? 'M13.5 6 L7.5 12 L13.5 18'
          : (dir === 1 ? 'M8.5 6 L14.5 12 L8.5 18'
            : (dir === 2 ? 'M6 13.5 L12 7.5 L18 13.5' : 'M6 8.5 L12 14.5 L18 8.5')))
        .stroke(enabled ? '#E6EDF3' : '#484F58')
        .strokeWidth(2.2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .fill('none')
        .width(20)
        .height(22)
    }
    .width(34)
    .height(34)
    .backgroundColor('#21262D')
    .border({ width: 1, color: '#30363D' })
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.4)
    .onClick(() => {
      this.nudge(dir);
    })
  }

  /** 视图卡：缩放 + 左右/上下平移（没放大到超出时，滑块不显示，只留说明） */
  @Builder
  viewCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('缩放').fontSize(12).fontColor('#7D8590').width(28)
        Slider({ value: this.previewPct, min: 10, max: 300, step: 5 })
          .layoutWeight(1)
          .trackColor('#21262D')
          .selectedColor('#238636')
          .onChange((v: number) => {
            this.userScale = v / 100;
            this.computePreviewScale();
          })
        Text(`${this.previewPct}%`)
          .fontSize(12).fontFamily('monospace').fontColor('#E6EDF3')
          .width(46).textAlign(TextAlign.End)
        Button('适应')
          .fontSize(11).height(28).padding({ left: 10, right: 10 })
          .backgroundColor('#21262D')
          .onClick(() => {
            this.userScale = 0;
            this.computePreviewScale();
          })
      }
      .width('100%')

      if (this.panMaxX > 0) {
        Row({ space: 8 }) {
          Text('左右').fontSize(12).fontColor('#7D8590').width(28)
          this.arrow(0, this.panX > 0)
          Slider({ value: this.panX, min: 0, max: 1000, step: 10 })
            .layoutWeight(1)
            .trackColor('#21262D')
            .selectedColor('#238636')
            .onChange((v: number) => {
              this.setPan(v, this.panY);
            })
          this.arrow(1, this.panX < 1000)
        }
        .width('100%')
      }

      if (this.panMaxY > 0) {
        Row({ space: 8 }) {
          Text('上下').fontSize(12).fontColor('#7D8590').width(28)
          this.arrow(2, this.panY > 0)
          Slider({ value: this.panY, min: 0, max: 1000, step: 10 })
            .layoutWeight(1)
            .trackColor('#21262D')
            .selectedColor('#238636')
            .onChange((v: number) => {
              this.setPan(this.panX, v);
            })
          this.arrow(3, this.panY < 1000)
        }
        .width('100%')
      }

      if (this.panMaxX === 0 && this.panMaxY === 0) {
        Text('内容已完整放进预览框：放大到超出后，这里会出现左右/上下滑块；也可双指拖动画布、双指捏合缩放、双击复位')
          .fontSize(11).fontColor('#7D8590')
          .width('100%').wordBreak(WordBreak.BREAK_ALL)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#161B22')
    .borderRadius(10)
    .border({ width: 1, color: '#21262D' })
  }

  /** 主操作按钮：主色 = 干活的那个 */
  @Builder
  controls() {
    Row({ space: 8 }) {
      Button(this.running ? '停止推送' : '启动推送')
        .layoutWeight(1)
        .height(40)
        .fontSize(14)
        .backgroundColor(this.running ? '#9E6A03' : '#238636')
        .onClick(() => {
          const svc = this.service;
          if (svc === null) {
            this.startService();
            return;
          }
          if (this.running) {
            svc.stop();
            this.running = false;
            // ★ 必须复位 startCalled：否则再点「启动推送」时会命中 startService() 开头的
            //   `if (this.startCalled) { refreshStatus(); return; }` 守卫，service.start()
            //   永远不会被再次调用 → 帧循环永久死亡（只能 /set?run=1 或重启应用恢复）。
            this.startCalled = false;
            this.releaseBgTask();
          } else {
            this.startService();
          }
          this.refreshStatus();
        })
      Button('连接屏幕')
        .layoutWeight(1)
        .height(40)
        .fontSize(14)
        .backgroundColor('#21262D')
        .onClick(() => {
          const svc = this.service;
          if (svc === null) {
            this.startService();
            return;
          }
          svc.requestUsb().then(() => {
            this.refreshStatus();
          });
        })
    }
    .width('100%')
  }

  /**
   * 开关组：原来三个开关裸放在一行里，手机上第三个（旋转180°）会被挤出屏幕。
   * 现在做成可换行的胶囊，开着的时候边框变绿，状态一眼可见。
   */
  /**
   * 预烘焙 JPEG 序列（这块屏上的"视频"）：帧是现成 JPEG，运行时零编码直推。
   * 帧由本机 HTTP 提供（App 里没有文件 IO）：先跑 tools/make_seq.py 烘序列，
   * 再 tools/seq_server.py --dir <序列根> --port 8899，然后点下面三个预设之一。
   * 想放自己的序列：/set?seq=http://127.0.0.1:8899/<子目录>，详见 docs/预烘焙序列.md。
   */
  @Builder
  seqRow() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
      Row({ space: 8 }) {
        Text('序列').fontSize(12).fontColor('#7D8590')
        Button('正片 12s')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.seqOn ? '#1F6FEB' : '#21262D')
          .onClick(() => { this.seqStart(SEQ_PRESETS[0]); })
        Button('面板抓帧')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor('#21262D')
          .onClick(() => { this.seqStart(SEQ_PRESETS[1]); })
        Button('仪表盘视频')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor('#21262D')
          .onClick(() => { this.seqStart(SEQ_PRESETS[2]); })
        Button('长片 600 帧')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor('#21262D')
          .onClick(() => { this.seqStart(SEQ_PRESETS[3]); })
        Button(this.seqStreamOn ? '流式 ✓' : '流式')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.seqStreamOn ? '#238636' : '#21262D')
          .onClick(() => {
            const svc = this.service;
            if (svc === null) {
              return;
            }
            svc.seqSetStream(!this.seqStreamOn);
            this.seqStreamOn = svc.seqIsStream();
          })

        Button(this.seqBurstOn ? '极速 ✓' : '极速')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.seqBurstOn ? '#238636' : '#21262D')
          .onClick(() => {
            const svc = this.service;
            if (svc === null) {
              return;
            }
            svc.seqSetBurst(!this.seqBurstOn);
            this.seqBurstOn = svc.seqIsBurst();
          })
        Button('停止')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.seqOn ? '#8B2E2E' : '#21262D')
          .onClick(() => {
            const svc = this.service;
            if (svc !== null) {
              svc.seqStop();
            }
          })
      }
      Text(this.seqText)
        .fontSize(11)
        .fontColor(this.seqOn ? '#3FB950' : '#7D8590')
        .margin({ left: 8, top: 6 })
    }
    .width('100%')
  }

  private seqStart(url: string): void {
    const svc = this.service;
    if (svc === null) {
      this.lastError = '服务未启动（先点「启动推送」）';
      return;
    }
    svc.seqSetStream(this.seqStreamOn);
    svc.seqPlay(url);
  }

  /** 主题选择：两个胶囊，点一下立刻换（并落盘） */
  @Builder
  themeRow() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
      Row({ space: 8 }) {
        Text('主题').fontSize(12).fontColor('#7D8590')
        Button('仪表盘')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 0 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 0;
            this.themeApply();
          })

        Button('诊断终端')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 1 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 1;
            this.themeApply();
          })

        Button('监控墙')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 2 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 2;
            this.themeApply();
          })

        Button('分页屏')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 3 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 3;
            this.themeApply();
          })

        Button('打砖块')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 4 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 4;
            this.themeApply();
          })

        Button('Dotii')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 5 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 5;
            this.themeApply();
          })

        Button('固件仿真')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 6 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 6;
            this.themeApply();
          })

        Button('官方浅色')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 7 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 7;
            this.themeApply();
          })

        Button('MacTR')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 8 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 8;
            this.themeApply();
          })

        Button('打印机位 Dotii')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 9 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 9;
            this.themeApply();
          })

        Button('赛博二次元')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 10 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 10;
            this.themeApply();
          })

      }   // ← 第一行结束（经典主题 0-10）

      // ---- 二次元系列（第二行）----
      Row({ space: 8 }) {

        Button('二次元壁纸')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 11 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 11;
            this.themeApply();
          })

        Button('二次元·无框')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 12 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 12;
            this.themeApply();
          })

        Button('明亮二次元HUD')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 13 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 13;
            this.themeApply();
          })

        Button('NanoMuse')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 14 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 14;
            this.themeApply();
          })

        Button('trofeo-lcd')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 15 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 15;
            this.themeApply();
          })

        // ★ 主题 16/17：之前只加了 themeName 名字，**漏加按钮** → 界面上根本点不到
        //   （用户反馈"软件上面没见呢"）。这两个是全屏游戏主题。
        Button('自走贪吃蛇')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 16 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 16;
            this.themeApply();
          })

        Button('超级玛丽')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 17 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 17;
            this.themeApply();
          })

        Button('天气')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor(this.theme === 18 ? '#238636' : '#21262D')
          .onClick(() => {
            this.theme = 18;
            this.themeApply();
          })

        // 第一屏（仪表盘）的"打印机格显示什么"开关：真打印机卡 ↔ Dotii。
        // 只在主题 0 下有意义（其它主题的打印机格各有各的用法）。
        // ★ 状态**只信服务**（不用本地 @State 取反 —— 本地值与服务不一致时会"点了切回旧值"，实测踩过）。
        //   三态循环：打印机卡 → VM⇄Dotii 对调 → Dotii 在左(13:29 版) → 回到打印机卡
        Button(this.service !== null ? this.service.printerCellLabel() : '打印机格: 打印机卡')
          .fontSize(11).height(28).padding({ left: 12, right: 12 })
          .backgroundColor((this.service !== null && this.service.printerCell !== 'printer')
            ? '#1F6FEB' : '#21262D')
          .enabled(this.theme === 0)
          .opacity(this.theme === 0 ? 1 : 0.45)
          .onClick(() => {
            const svc = this.service;
            if (svc === null) {
              return;
            }
            svc.setPrinterCell(svc.nextPrinterCell());
            this.markDirty('开关:打印机格');
            this.refreshStatus();
          })
      }
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .margin({ right: 8, bottom: 8 })
      .backgroundColor('#161B22')
      .borderRadius(8)
      .border({ width: 1, color: '#21262D' })
    }
    .width('100%')
  }

  /**
   * 主题名。★ 用查表而不是嵌套三元 —— 原来的嵌套三元连括号都数错了（编译报 "')' expected"），
   * 而且只覆盖 0..6，主题 7~15 全显示"仪表盘"（按钮却已有 16 个）。
   */
  static themeName(t: number): string {
    const names: string[] = [
      '仪表盘', '诊断终端', '监控墙', '分页屏', '打砖块', 'Dotii 分页屏',
      '固件仿真屏', '官方浅色', 'MacTR', '打印机位 Dotii',
      '赛博二次元', '二次元壁纸', '二次元·无框', '明亮二次元HUD', 'NanoMuse', 'trofeo-lcd',
      '自走贪吃蛇', '超级玛丽', '天气'
    ];
    if (t < 0 || t >= names.length) {
      return '未知';
    }
    return names[t];
  }


  /**
   * 换主题：推给服务、立刻刷新画面并落盘。
   *
   * ★ 2026-10-15（代码审查【高危-5】）：原来直接 `svc.theme = this.theme`，
   *   **不置 themeTouched** → `loadPrefs` 的守卫失效（守卫依赖 touched），
   *   于是"存档里的旧主题把用户刚选的主题覆盖回去"这个历史 bug 会以**界面按钮**这个
   *   新入口复现。现在统一走 `svc.setTheme(n, true)`：置 touched + 清内容签名 + 重置轮播计时。
   *   顺带修掉日志：原来 `theme === 1 ? '诊断终端' : '仪表盘'` 会把主题 2~15 全记成"仪表盘"。
   */
  private themeApply(): void {
    const svc = this.service;
    if (svc !== null) {
      svc.setTheme(this.theme, true);
    }
    Logger.i(`主题切换为 ${this.theme}（${Index.themeName(this.theme)}）`);
    this.markDirty('主题切换');
  }

  @Builder
  switchCard() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
      Row({ space: 8 }) {
        Text('竖屏布局').fontSize(12).fontColor('#C9D1D9')
        Toggle({ type: ToggleType.Switch, isOn: this.verticalMode })
          .width(42)
          .height(24)
          .selectedColor('#238636')
          .onChange((on: boolean) => {
            this.verticalMode = on;
            if (this.service !== null) {
              this.service.verticalMode = on;
            }
            this.markDirty('开关:竖屏布局');
          })
      }
      .padding({ left: 10, right: 8, top: 4, bottom: 4 })
      .margin({ right: 8, bottom: 8 })
      .backgroundColor('#161B22')
      .borderRadius(8)
      .border({ width: 1, color: this.verticalMode ? '#238636' : '#21262D' })

      Row({ space: 8 }) {
        Text('夜间熄屏').fontSize(12).fontColor('#C9D1D9')
        Toggle({ type: ToggleType.Switch, isOn: this.nightEnabled })
          .width(42)
          .height(24)
          .selectedColor('#238636')
          .onChange((on: boolean) => {
            this.nightEnabled = on;
            if (this.service !== null) {
              this.service.nightEnabled = on;
            }
            this.markDirty('开关:夜间熄屏');
          })
      }
      .padding({ left: 10, right: 8, top: 4, bottom: 4 })
      .margin({ right: 8, bottom: 8 })
      .backgroundColor('#161B22')
      .borderRadius(8)
      .border({ width: 1, color: this.nightEnabled ? '#238636' : '#21262D' })

      Row({ space: 8 }) {
        Text('旋转180°').fontSize(12).fontColor('#C9D1D9')
        Toggle({ type: ToggleType.Switch, isOn: this.rotEffective })
          .width(42)
          .height(24)
          .selectedColor('#238636')
          .onChange((on: boolean) => {
            if (this.rotSyncing) {
              // 这次变化是 refreshStatus 同步生效值引起的，不是用户拨的
              this.rotSyncing = false;
              return;
            }
            // 拨开关 = 手动覆盖（1=强制转 2=强制不转）
            this.rotMode = on ? 1 : 2;
            this.rotEffective = on;
            this.rotApply();
            this.markDirty('开关:旋转180');
          })
        if (this.rotMode !== 0) {
          // 手动覆盖后给一条回自动的路（真机默认应该是自动跟设备）
          Button('跟随设备')
            .fontSize(10)
            .height(22)
            .padding({ left: 8, right: 8 })
            .backgroundColor('#21262D')
            .onClick(() => {
              this.rotMode = 0;
              this.rotApply();
              this.markDirty('旋转:回到自动');
            })
        }
      }
      .padding({ left: 10, right: 8, top: 4, bottom: 4 })
      .margin({ right: 8, bottom: 8 })
      .backgroundColor('#161B22')
      .borderRadius(8)
      .border({ width: 1, color: this.rotEffective ? '#238636' : '#21262D' })
    }
    .width('100%')
  }

  /** VM 监视地址（换环境时在这里改：livepad 在别的机器/别的端口都能填） */
  @Builder
  vmCard() {
    Column({ space: 8 }) {
      Row() {
        Text('监视地址').fontSize(12).fontColor('#7D8590')
        Blank()
        Text('IP / IP/vm / IP:端口/vm').fontSize(11).fontColor('#7D8590')
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.vmUrlText, placeholder: 'http://192.168.3.105:8787/vm' })
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor('#E6EDF3')
          .placeholderColor('#484F58')
          .caretColor('#238636')
          .backgroundColor('#0D1117')
          .border({ width: 1, color: '#30363D' })
          .borderRadius(8)
          .onChange((v: string) => {
            this.vmUrlText = v;
            // 诊断：TextInput 的 text 不是双向绑定，某些时机会用陈旧值回调，
            // 这里只记录"和权威值不一致"的事件，便于事后确认是谁改的。
            if (v.trim() !== this.appliedVmUrl) {
              this.urlChangeEvents++;
              if (this.urlChangeEvents <= 5) {
                Logger.i(`输入框变更 #${this.urlChangeEvents}: 「${v}」 权威值=${this.appliedVmUrl}`);
              }
            }
          })

        Button('应用')
          .fontSize(13)
          .height(38)
          .backgroundColor('#238636')
          .onClick(() => {
            this.appliedVmUrl = this.vmUrlText.trim();
            this.vmUrlText = this.appliedVmUrl;
            this.urlChangeEvents = 0;
            if (this.service !== null) {
              this.service.vmUrl = this.appliedVmUrl;
            }
            this.pushedVmUrl = this.appliedVmUrl;
            Logger.i(`VM 监视地址已应用: ${this.appliedVmUrl}`);
            this.markDirty('界面:应用VM地址');
          })
      }
      .width('100%')

      this.banner('数据桥: cd ~/WorkBuddy/TrofeoLCD/bridge && ./start.sh', '#3FB950', '#0D2818', '#1F6F3A')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#161B22')
    .borderRadius(10)
    .border({ width: 1, color: '#21262D' })
  }

  @Builder
  deviceCard() {
    Column() {
      this.stat('USB 屏幕', this.usbLabel, this.usbOpen ? '#3FB950' : '#F85149')
      this.stat('设备信息', this.deviceInfo, '#E6EDF3')
      this.stat('端点', this.epText, '#D0BCFF')
      this.stat('屏 ACK', this.ackText, '#58A6FF')
      this.stat('主题', Index.themeName(this.theme), '#58A6FF')
      this.stat('旋转', `${this.rotDesc} → ${this.rotEffective ? '180°' : '0°'}`,
        this.rotMode === 0 ? '#58A6FF' : '#E6EDF3')
      this.stat('协议自检', this.selfTestText, this.selfTestOk ? '#3FB950' : '#D29922')
      this.stat('运行时体检', this.runtimeText, this.runtimeOk ? '#3FB950' : '#D29922')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#161B22')
    .borderRadius(10)
    .border({ width: 1, color: '#21262D' })
  }

  @Builder
  pictureCard() {
    Column() {
      this.stat('输出帧', this.jpegInfo, '#58A6FF')
      this.stat('帧率 / 已发送', `${this.fpsText} fps / ${this.sentText}`, '#E6EDF3')
      this.stat('数据桥', this.bridgeText, '#D0BCFF')
      this.stat('远程预览', `${this.frameUrl} (${this.frameCount} 帧)`, '#3FB950')
      this.stat('远程取帧', this.vmStatusLine(), this.vmStatusColor())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#161B22')
    .borderRadius(10)
    .border({ width: 1, color: '#21262D' })
  }

  @Builder
  diagCard() {
    Column() {
      this.stat('诊断接口', 'http://127.0.0.1:54546/diag · /probe · /set', '#8B949E')
      if (this.lastError.length > 0) {
        this.stat('最近错误', this.lastError, '#F85149')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#161B22')
    .borderRadius(10)
    .border({ width: 1, color: '#21262D' })
  }

  /** 页脚：诊断入口与版式实测值（排障要看） */
  @Builder
  footer() {
    Column({ space: 3 }) {
      Text(`版式 ${Math.round(this.screenW)}x${Math.round(this.screenH)}vp · 画布 ${this.canvasVpW}x${this.canvasVpH}vp`
        + ` · 框 ${Math.round(this.previewBoxW)}x${Math.round(this.previewBoxH)}vp`)
        .fontSize(10).fontColor('#484F58').fontFamily('monospace')
        .width('100%').wordBreak(WordBreak.BREAK_ALL)
    }
    .width('100%')
    .margin({ top: 6 })
  }
}
