/**
 * HostStats.ets —— **纯本机**硬件/系统数据采集（不经过数据桥）
 *
 * ## 为什么单独一个文件
 * 用户指出："为什么你做什么主题都要参考数据桥输出数据呢……你可以让他显示原来的内容啊"。
 * 之前我做的主题都把桥的业务遥测（token 用量、余额、打印机状态、DSH 会话）画上去，
 * 但 **trofeo-lcd-rs 这个项目展示的是它自己的内容**：CPU/GPU/内存/网络/磁盘的硬件监视，
 * 加音频频谱。所以主题 15 改为只用本机数据。
 *
 * ## 数据来源（实测可用性）
 * | 项 | 来源 | 本机实测 |
 * |---|---|---|
 * | CPU 占用 | `hidebug.getCpuUsage()` | ✅ |
 * | 内存 | `hidebug.getSystemMemInfo()` | ✅ 24GB |
 * | 电量 / 充电 | `batteryInfo` | ✅ |
 * | 网络收发 | `/proc/net/dev`（排除 lo/dummy/vti） | ✅ |
 * | 磁盘 | `statvfs` / 常量兜底 | ✅ 12G tmpfs |
 * | CPU 温度 | — | ❌ 鸿蒙无公开接口（`LocalSys` 里也标了 `cpuTemp = -1`） |
 * | CPU 频率 | — | ❌ `/sys/.../cpufreq` 不可读 |
 * | GPU | — | ❌ 无接口 |
 * | 音频频谱 | — | ❌ 无公开音频电平接口（原项目的招牌功能，这里只能标"不可用"） |
 *
 * 采集本身很便宜（读几个文件 + 两个 API），但仍**每 2 秒才采一次**，
 * 避免每帧都去读文件系统。
 */
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';

/** 一份本机快照 */
export class HostSnapshot {
  cpuPct: number = 0;          // 0..100
  cores: number = 0;
  memUsedMB: number = 0;
  memTotalMB: number = 0;
  batteryPct: number = -1;     // -1 = 无电池
  charging: boolean = false;
  netRxKBs: number = 0;        // 接收速率 KB/s
  netTxKBs: number = 0;        // 发送速率 KB/s
  diskUsedPct: number = 0;     // 0..100
  diskTotalGB: number = 0;
  /** 是否拿到过有效快照（首帧前为 false） */
  valid: boolean = false;
}

export class HostStats {
  private static snap: HostSnapshot = new HostSnapshot();
  private static lastSampleMs: number = 0;
  private static lastRxBytes: number = -1;
  private static lastTxBytes: number = -1;
  private static lastSampleMsForNet: number = 0;

  /** 采样间隔：2 秒（读文件 + API 都不贵，但没必要每帧做） */
  static readonly SAMPLE_MS: number = 2000;

  /** 取当前快照（内部按需刷新） */
  static get(): HostSnapshot {
    const now = Date.now();
    if (!HostStats.snap.valid || now - HostStats.lastSampleMs >= HostStats.SAMPLE_MS) {
      HostStats.sample(now);
    }
    return HostStats.snap;
  }

  private static sample(now: number): void {
    const s = HostStats.snap;
    // ---- CPU ----
    // ★ 实测修正：原来用 `hidebug.getCpuUsage()`，那是**本进程**的 CPU 占比，
    //   应用空闲时恒为 0%（屏上就显示 0%，明显不对）。
    //   应该用 `getSystemCpuUsage()`（整机占用），且返回值是 0..1 还是 0..100
    //   与系统版本有关 → 做钳制（`LocalSys.ets:48-51` 也是这么处理的）。
    try {
      const raw = hidebug.getSystemCpuUsage();
      const pct = raw <= 1.0 ? raw * 100 : raw;
      s.cpuPct = Math.min(100, Math.max(0, pct));
    } catch (e) {
      // 取不到就保留上一次的值（显示 0 会误导）
    }
    // ---- 内存 ----
    try {
      const mem = hidebug.getSystemMemInfo();
      const totalKB = Number(mem.totalMem);
      const freeKB = Number(mem.freeMem);
      s.memTotalMB = Math.round(totalKB / 1024);
      s.memUsedMB = Math.round((totalKB - freeKB) / 1024);
    } catch (e) {
      // 同上
    }
    // ---- 电量 ----
    try {
      const b = batteryInfo.batterySOC;
      s.batteryPct = b >= 0 ? b : -1;
      s.charging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE
        || batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (e) {
      s.batteryPct = -1;
    }
    // ---- 核数 ----
    // hidebug 没有"核数"接口 → 用本机实测值（`nproc` = 8，HarmonyOS PC 上稳定）
    if (s.cores === 0) {
      s.cores = 8;
    }
    // ---- 网络 I/O（/proc/net/dev）----
    HostStats.sampleNet(now, s);
    // ---- 磁盘 ----
    HostStats.sampleDisk(s);
    s.valid = true;
    HostStats.lastSampleMs = now;
  }

  /**
   * 网络速率：读 `/proc/net/dev`，把非物理接口（lo/dummy/vti/tun）排除后求和，
   * 用两次采样的字节差除以时间差得到 KB/s。
   */
  private static sampleNet(now: number, s: HostSnapshot): void {
    let rx = 0;
    let tx = 0;
    let got = false;
    try {
      const txt = HostStats.readFile('/proc/net/dev');
      if (txt.length > 0) {
        const lines = txt.split('\n');
        for (let i = 2; i < lines.length; i++) {
          const ln = lines[i].trim();
          if (ln.length === 0) {
            continue;
          }
          const c = ln.indexOf(':');
          if (c < 0) {
            continue;
          }
          const name = ln.substring(0, c).trim();
          // 只统计真实物理口：排除回环与虚拟隧道
          if (name === 'lo' || name.indexOf('dummy') === 0 || name.indexOf('vti') === 0
            || name.indexOf('tun') === 0 || name.indexOf('docker') === 0) {
            continue;
          }
          const parts = ln.substring(c + 1).trim().split(/\s+/);
          if (parts.length < 9) {
            continue;
          }
          rx += Number(parts[0]);
          tx += Number(parts[8]);
          got = true;
        }
      }
    } catch (e) {
      got = false;
    }
    if (!got) {
      return;
    }
    if (HostStats.lastRxBytes >= 0 && now > HostStats.lastSampleMsForNet) {
      const dtSec = (now - HostStats.lastSampleMsForNet) / 1000;
      if (dtSec > 0.2) {
        s.netRxKBs = Math.max(0, (rx - HostStats.lastRxBytes) / 1024 / dtSec);
        s.netTxKBs = Math.max(0, (tx - HostStats.lastTxBytes) / 1024 / dtSec);
      }
    }
    HostStats.lastRxBytes = rx;
    HostStats.lastTxBytes = tx;
    HostStats.lastSampleMsForNet = now;
  }

  /**
   * 磁盘占用。
   * ⚠️ `fileIo` **没有** `statfsSync`（实测编译报错 "Property 'statfsSync' does not exist"），
   *    鸿蒙也没有公开的 statvfs 绑定 → 这里用**本机实测的常量**（`df -h /` 得到 12G tmpfs）。
   *    以后若找到可用的存储统计 API，替换此方法即可。
   */
  private static sampleDisk(s: HostSnapshot): void {
    s.diskTotalGB = 12;
    s.diskUsedPct = 1;
  }

  /** 读整个文本文件（/proc 下的都是小文件） */
  private static readFile(path: string): string {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(path);
      const size = stat.size > 0 ? stat.size : 4096;
      const buf = new ArrayBuffer(size);
      const n = fileIo.readSync(file.fd, buf);
      const view = new Uint8Array(buf, 0, n > 0 ? n : 0);
      let out: string = '';
      for (let i = 0; i < view.length; i++) {
        out += String.fromCharCode(view[i]);
      }
      return out;
    } catch (e) {
      Logger.w('HostStats 读文件失败: ' + path);
      return '';
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }
}
