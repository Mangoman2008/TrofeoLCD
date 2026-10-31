import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { LcdService } from '../service/LcdService';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';

/**
 * 窗口尺寸记忆的偏好库名（与页面里那个 'dshlcd' 分开，避免两处互相覆盖）。
 * 键：winW / winH（vp）。
 */
const WIN_PREF_STORE: string = 'dshlcd_win';
/**
 * 首次启动（还没记住尺寸时）用的默认窗口高度。
 * 实测本机窗口为 2090x1394（用户拉大后），所以默认取 1250 —— 对 1440 高的屏留约 190 余量，
 * 内容一屏能看全，用户不必手动拉大。之后由 `windowSizeChange` 记住用户实际尺寸。
 */
const WIN_DEFAULT_H: number = 1250;
const WIN_DEFAULT_W: number = 0;   // 0 = 宽度交给系统（不强制）

export default class EntryAbility extends UIAbility {
  /** 当前窗口尺寸（供 diag 读取，用于验证窗口高度设置是否生效） */
  static curW: number = 0;
  /** 诊断用：生命周期调用次数 */
  static bgCount: number = 0;
  /**
   * ★ 后台保活申请的真实结果（诊断用）。
   *   `bgTask = true` 只表示"尝试过"，**不代表被批准** ——
   *   实测最小化后约 300ms 内整个 JS 事件循环被冻结
   *   （setTimeout 不回调、HTTP 也不响应），所以必须把真实结果暴露出来。
   */
  static bgMode: string = '';      // 申请成功的模式名；空 = 全部被拒
  static bgErr: string = '';       // 最后一次失败原因（含错误码）
  static fgCount: number = 0;
  static curH: number = 0;
  /** resize 尝试的结果（排障用）：'' = 未尝试；其余为结果说明 */
  static resizeNote: string = '';

  /**
   * 隐藏最小化按钮的结果（诊断用）。'' = 未尝试。
   *
   * ★ 为什么必须隐藏它（2026-10-16 三层证据钉死）：
   *   HarmonyOS PC 在**窗口最小化**时会用 cgroup freezer 把应用**整个冻住**，
   *   而应用声明的保活（continuous task + running lock）**挡不住**：
   *     · 系统日志：`isulad: set state FROZEN to freezer.state`
   *     · 冻结后 12 秒内进程 CPU 时间**一个时钟都不走**（00:09:18 不动）
   *     · 冻结时 bgMode='dataTransfer'、lockHeld=true 都还在
   *   实测触发条件很明确：
   *     · 最小化（onBackground 触发）→ 约 10~18 秒后冻死
   *     · HOME 键（onBackground **不**触发）→ 连续 3 分钟正常
   *   本应用是状态副屏，必须持续推帧，"最小化"对它没有意义且只会让它停，
   *   所以把标题栏上的最小化按钮隐藏 —— 用户仍可用 HOME 键/切应用离开（那条路不冻）。
   */
  static titleBtnNote: string = '';

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    Logger.i('TrofeoLCD 启动');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Logger.e(`加载页面失败: ${err.message}`);
        return;
      }
      Logger.i('页面加载成功');
    });

    // 常亮 + 沉浸式全屏：LCD 长时间显示场景，且不要上下白边（状态栏/导航栏）
    windowStage.getMainWindow().then((win: window.Window) => {
      win.setWindowKeepScreenOn(true).catch((e: BusinessError) => {
        Logger.w(`常亮设置失败: ${e.code} ${e.message}`);
      });
      // 布局延伸到状态栏/导航栏区域
      win.setWindowLayoutFullScreen(true).then(() => {
        Logger.i('已开启全屏布局（沉浸式）');
      }).catch((e: BusinessError) => {
        Logger.w(`全屏布局设置失败: ${e.code} ${e.message}`);
      });
      // 隐藏状态栏与导航栏（空数组 = 都不显示）
      win.setWindowSystemBarEnable([]).then(() => {
        Logger.i('已隐藏状态栏与导航栏');
      }).catch((e: BusinessError) => {
        Logger.w(`隐藏系统栏失败: ${e.code} ${e.message}`);
      });

      // ★ 隐藏最小化按钮：见 titleBtnNote 的注释（系统会因最小化冻结本应用）。
      //   参数顺序：最大化可见 / 最小化可见 / 关闭可见。
      //   保留最大化与关闭 —— 用户还能调整窗口、也能正常退出。
      try {
        win.setWindowTitleButtonVisible(true, false, true);
        EntryAbility.titleBtnNote = '已隐藏最小化按钮';
        Logger.i('[win] 已隐藏最小化按钮（避免系统冻结）');
      } catch (e) {
        const err = e as BusinessError;
        EntryAbility.titleBtnNote = `失败 ${err.code} ${err.message}`;
        Logger.w(`[win] 隐藏最小化按钮失败: ${EntryAbility.titleBtnNote}`);
      }

      // ★ 窗口尺寸记忆（用户 2026-10-14："鸿蒙app打开的时候界面底部可以保留多一点，
      //   不用我每次打开软件都需要拉大窗口"）。
      //   原实现完全没管窗口尺寸 → 每次打开都是系统默认的小窗，用户得手动拉大。
      //   做法：启动时恢复上次记住的尺寸；之后监听 `windowSizeChange` 持续记住，
      //   这样"用户拉大一次"就成为默认，下次打开仍是那么大。
      // ★ 必须**延后** resize：窗口创建后立刻调 resize 会被系统忽略
      //   （实测：启动瞬间设尺寸无效）。等窗口尺寸稳定后再设，并打日志确认。
      win.on('windowSizeChange', (size: window.Size) => {
        Logger.i(`[win] 尺寸变化 ${size.width}x${size.height}`);
        EntryAbility.rememberWindowSize(size.width, size.height);
        // 记下当前尺寸供 diag 读取
        EntryAbility.curW = size.width;
        EntryAbility.curH = size.height;
      });
      setTimeout(() => {
        try {
          const p0 = win.getWindowProperties();
          Logger.i(`[win] 启动尺寸 ${p0.windowRect.width}x${p0.windowRect.height}`
            + `（目标 ${WIN_DEFAULT_H}）`);
          EntryAbility.curW = p0.windowRect.width;
          EntryAbility.curH = p0.windowRect.height;
        } catch (e) {
          Logger.w('[win] 读窗口属性失败');
        }
        EntryAbility.restoreWindowSize(win);
      }, 600);
    }).catch((e: BusinessError) => {
      Logger.w(`获取主窗口失败: ${e.code}`);
    });
  }

  /** 恢复上次记住的窗口尺寸；没有记录则用一个偏高的默认值 */
  private static restoreWindowSize(win: window.Window): void {
    try {
      const store = preferences.getPreferencesSync(
        getContext() as common.UIAbilityContext, { name: WIN_PREF_STORE });
      const w = store.getSync('winW', 0) as number;
      const h = store.getSync('winH', 0) as number;
      Logger.i(`[win] 记住的尺寸 ${w}x${h}`);
      const targetW = w > 400 ? w : WIN_DEFAULT_W;
      const targetH = h > 600 ? h : WIN_DEFAULT_H;
      if (targetW > 400) {
        EntryAbility.resizeNote = `尝试 resize(${targetW}, ${targetH})`;
        win.resize(targetW, targetH).then(() => {
          const np = win.getWindowProperties().windowRect;
          EntryAbility.resizeNote = `resize 成功 → 实际 ${np.width}x${np.height}`;
          EntryAbility.curW = np.width;
          EntryAbility.curH = np.height;
        }).catch((e: BusinessError) => {
          EntryAbility.resizeNote = `resize 失败 ${e.code} ${e.message}`;
        });
      } else {
        // 只设高度：宽度交给系统，避免在小屏/分屏下超出
        const cw = win.getWindowProperties().windowRect.width;
        EntryAbility.resizeNote = `尝试 resize(${cw}, ${targetH})`;
        win.resize(cw, targetH).then(() => {
          const np = win.getWindowProperties().windowRect;
          EntryAbility.resizeNote = `resize 成功 → 实际 ${np.width}x${np.height}`;
          EntryAbility.curW = np.width;
          EntryAbility.curH = np.height;
        }).catch((e: BusinessError) => {
          EntryAbility.resizeNote = `resize 失败 ${e.code} ${e.message}`;
        });
      }
    } catch (e) {
      Logger.w('读取窗口尺寸偏好失败');
    }
  }

  /** 记住当前窗口尺寸（用户拉大后即生效，下次打开沿用） */
  private static rememberWindowSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(
        getContext() as common.UIAbilityContext, { name: WIN_PREF_STORE });
      store.putSync('winW', Math.round(w));
      store.putSync('winH', Math.round(h));
      store.flush();
    } catch (e) {
      // 忽略：记住失败不影响功能
    }
  }

  /**
   * 退出前把当前窗口尺寸再存一次。
   * `windowSizeChange` 已经在变化时保存了，这里是兜底：某些关闭路径（例如
   * 系统直接销毁窗口）不一定派发尺寸变化事件，退出时补记一次更稳。
   */
  /**
   * ★ 诊断：最小化/切后台会走哪条生命周期。
   *   起因：用户反馈"点最小化就立刻停止推送"，但用 HOME 键切后台实测
   *   连续 240 秒正常（sent 19067→19550）。所以问题在"最小化"这条特定路径上，
   *   而本应用此前**完全没有**监听任何后台/窗口事件，无从判断。
   *   这两条 + onWindowStageDestroy 一起打时间戳，就能定位到底哪条发生了。
   */
  onBackground(): void {
    EntryAbility.bgCount++;
    LcdService.active?.setBackgrounded(true);
    Logger.i(`[life] onBackground 第 ${EntryAbility.bgCount} 次 @${Date.now()}`);
  }

  onForeground(): void {
  // ★ 恢复即补帧：最小化会让事件循环被冻结，恢复后内容签名未变时
  //   最多要等 3 秒心跳才补帧（屏上一段空窗）。这里立刻推一帧压掉空窗。
  LcdService.active?.forceRefresh(`回到前台（第 ${EntryAbility.fgCount} 次）`);
    EntryAbility.fgCount++;
    LcdService.active?.setBackgrounded(false);
    Logger.i(`[life] onForeground 第 ${EntryAbility.fgCount} 次 @${Date.now()}`);
  }

  onWindowStageDestroy(): void {
    Logger.i(`[life] onWindowStageDestroy @${Date.now()}`);
    if (EntryAbility.curW > 0 && EntryAbility.curH > 0) {
      EntryAbility.rememberWindowSize(EntryAbility.curW, EntryAbility.curH);
      Logger.i(`[win] 退出前保存尺寸 ${EntryAbility.curW}x${EntryAbility.curH}`);
    }
  }

  onDestroy(): void {
    Logger.i('TrofeoLCD 退出');
  }
}
