/**
 * LocalSys.ets —— 本机系统采集（鸿蒙侧）
 *
 * 为什么需要：遥测里的 system 段是**桥端那台机器**的数据（桥在哪台机器上跑，就报哪台）。
 * 手机/平板单独用这个应用时（没有桥，或在别的机器上），面板会空着；
 * 这里用鸿蒙系统 API 采本机数据，作为**遥测不新鲜时的回退**（与 Windows 版同一套策略：
 * 桥有数据就信桥，桥没数据就显示本机）。
 *
 * 纯逻辑与 API 调用分开：采样结果由 toSystemInfo() 转成既有的 SystemInfo，
 * 归一化/渲染/自检都不需要改（可离线测试）。
 */
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import type { SystemInfo } from '../common/Types';
import { Logger } from '../common/Logger';

/** 一次采样的原始值（便于自检，不依赖系统 API） */
export class LocalRaw {
  cpuPct: number = 0;        // 0..100
  memUsedMB: number = 0;
  memTotalMB: number = 0;
  cores: number = 0;
  uptimeSec: number = 0;
  host: string = '';
  batteryPct: number = -1;   // -1 = 无电池/取不到
  charging: boolean = false;
}

export class LocalSys {
  private last: LocalRaw = new LocalRaw();
  private lastAt: number = 0;
  private errCount: number = 0;

  /** 每 2 秒最多采一次（hidebug 的 CPU 采样有开销，别每帧调） */
  sample(force: boolean = false): LocalRaw {
    const now = Date.now();
    if (!force && now - this.lastAt < 2000 && this.lastAt > 0) {
      return this.last;
    }
    this.lastAt = now;
    const r = new LocalRaw();

    try {
      // CPU：hidebug.getCpuUsage() 返回本进程占比，
      // getSystemCpuUsage() 返回整机占用（0..1 还是 0..100 与版本有关，做钳制）
      const sys = hidebug.getSystemCpuUsage();
      let pct = sys <= 1.0 ? sys * 100 : sys;
      r.cpuPct = clamp(pct, 0, 100);
    } catch (e) {
      this.note(e);
    }

    try {
      const mem = hidebug.getSystemMemInfo();
      // 文档给的是 KB
      // hidebug 的这两个字段是 bigint（SDK d.ts 实测），必须先转 number 再算
      const totalKB = Number(mem.totalMem);
      const freeKB = Number(mem.freeMem);
      r.memTotalMB = Math.round(totalKB / 1024);
      r.memUsedMB = Math.round((totalKB - freeKB) / 1024);
    } catch (e) {
      this.note(e);
    }

    try {
      r.uptimeSec = Math.floor(systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) / 1000);
    } catch (e) {
      this.note(e);
    }

    try {
      r.batteryPct = batteryInfo.batterySOC;
      r.charging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE
        || batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (e) {
      this.note(e);
    }

    try {
      // 型号：优先 productModel 别名，退化到 brand
      const model = deviceInfo.productModel !== undefined && deviceInfo.productModel.length > 0
        ? deviceInfo.productModel : deviceInfo.brand;
      r.host = model + ' · ' + deviceInfo.osFullName;
    } catch (e) {
      this.note(e);
    }

    r.cores = 0;   // 鸿蒙没给公开核数 API；面板会显示 "CPU" 而不是 "N cores"
    this.last = r;
    return r;
  }

  private note(e: Object): void {
    this.errCount++;
    if (this.errCount <= 3 || this.errCount % 50 === 0) {
      Logger.w(`本机系统采集失败第 ${this.errCount} 次: ${e}`);
    }
  }

  /** 转成既有的 SystemInfo（渲染与自检都用这一套） */
  toSystemInfo(): SystemInfo {
    const r = this.sample();
    const s: SystemInfo = {};
    s.cpu = r.cpuPct;
    s.cores = r.cores;
    s.memUsed = r.memUsedMB;
    s.memTotal = r.memTotalMB;
    s.uptimeSec = r.uptimeSec;
    s.host = r.host;
    s.cpuTemp = -1;             // 鸿蒙没有公开的 CPU 温度接口
    s.battery = r.batteryPct;   // -1 = 无电池
    s.charging = r.charging;
    return s;
  }

  get errors(): number {
    return this.errCount;
  }
}

function clamp(v: number, lo: number, hi: number): number {
  if (!isFinite(v)) {
    return lo;
  }
  return v < lo ? lo : (v > hi ? hi : v);
}

/** 纯逻辑：决定用桥端数据还是本机数据（可离线自检） */
