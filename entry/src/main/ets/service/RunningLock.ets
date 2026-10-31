import { runningLock, BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

/**
 * 运行锁：让 CPU 在**熄屏/休眠**时保持运行。
 *
 * ## 为什么需要它（实测）
 * 用户反馈：最小化的问题修好后，**设备熄屏仍然会停推**。
 * `continuous task`（dataTransfer）挡不住熄屏这一种，需要运行锁。
 *
 * ## 为什么锁在启动时就拿、并一直持有
 * 熄屏不一定走 `onBackground`，放在那里加锁会漏。而状态副屏的语义就是
 * "只要应用在跑就一直喂屏"，所以启动即持有、直到应用真正退出。
 *
 * ## 逐个尝试锁类型（照 `acquireBgTask` 的多模式策略）
 * SDK 里三种类型各有适用面与废弃情况：
 *   · `BACKGROUND = 1`            熄屏时防休眠，但**API 10 起废弃**
 *   · `BACKGROUND_USER_IDLE = 129` 用户空闲时防自动休眠，较新
 *   · `PROXIMITY_SCREEN_CONTROL = 2` 接近传感器控屏，不适用本场景（留作兜底）
 * 先用 `isSupported()` 探测，再按优先级尝试，谁成用谁 —— 不猜哪个可用。
 *
 * ## `hold(-1)`
 * `timeout = -1` 表示**永久持有**（文档：The lock is permanently held）。
 * 传 0 或正数会在计时结束后自动释放，不适合"长期喂屏"。
 *
 * ## 权限
 * `ohos.permission.RUNNING_LOCK`：`system_grant` + `availableLevel=normal`
 * （查 SDK 的 PermissionDefinitions.json 确认），安装即授予，无需运行时申请。
 *
 * ## 失败不影响功能
 * 拿不到锁只是回到"熄屏可能停推"的旧行为，不会让应用出错。
 */
export class RunningLock {
  /** 当前是否持有（供 /diag 观测） */
  static held: boolean = false;
  /** 最近一次失败原因（空 = 成功） */
  static err: string = '';
  /** 实际生效的类型名 */
  static typeName: string = '';
  /** 各类型支持情况（诊断：一眼看出这台机器认哪种） */
  static supportNote: string = '';

  private static lock: runningLock.RunningLock | null = null;

  /** 候选类型顺序：先新的、再旧的、最后兜底（都带名字，便于诊断） */
  private static readonly CANDIDATES: Array<[string, number]> = [
    ['BACKGROUND_USER_IDLE', runningLock.RunningLockType.BACKGROUND_USER_IDLE],
    ['BACKGROUND', runningLock.RunningLockType.BACKGROUND],
    ['PROXIMITY_SCREEN_CONTROL', runningLock.RunningLockType.PROXIMITY_SCREEN_CONTROL]
  ];

  /**
   * 获取运行锁（幂等，可重复调用）。
   * 逐个探测+尝试；每一步失败都记录原因但不抛出。
   */
  static async acquire(): Promise<void> {
    if (RunningLock.lock !== null) {
      return;
    }
    const notes: string[] = [];
    // 注意：ArkTS 禁止解构声明（arkts-no-destruct-decls），所以按索引取值
    for (let ci = 0; ci < RunningLock.CANDIDATES.length; ci++) {
      const name: string = RunningLock.CANDIDATES[ci][0];
      const type: number = RunningLock.CANDIDATES[ci][1];
      let supported = false;
      try {
        supported = runningLock.isSupported(type);
      } catch (e) {
        supported = false;
      }
      notes.push(`${name}=${supported ? '支持' : '不支持'}`);
      if (!supported) {
        continue;
      }
      try {
        const lk = await runningLock.create('trofeolcd-keep-pushing', type);
        // -1 = 永久持有（见文件头注释）
        lk.hold(-1);
        RunningLock.lock = lk;
        RunningLock.held = true;
        RunningLock.typeName = name;
        RunningLock.err = '';
        RunningLock.supportNote = notes.join(' ');
        Logger.i(`[lock] 运行锁已持有（${name}，永久）—— 熄屏时保持推帧`);
        return;
      } catch (e) {
        const err = e as BusinessError;
        const why = err === undefined ? String(e) : `${err.code} ${err.message}`;
        notes.push(`${name}失败:${why}`);
        Logger.w(`[lock] ${name} 获取失败: ${why}`);
      }
    }
    RunningLock.held = false;
    RunningLock.err = '所有锁类型都不可用';
    RunningLock.supportNote = notes.join(' ');
    Logger.w(`[lock] 运行锁获取失败: ${RunningLock.supportNote}`);
  }

  /** 释放（正常退出时用） */
  static release(): void {
    if (RunningLock.lock === null) {
      return;
    }
    try {
      RunningLock.lock.unhold();
    } catch (e) {
      // ignore
    }
    RunningLock.lock = null;
    RunningLock.held = false;
    Logger.i('[lock] 运行锁已释放');
  }
}
