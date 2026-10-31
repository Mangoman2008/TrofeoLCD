/**
 * WeatherService.ets —— 天气数据（Open-Meteo 无密钥接口）
 *
 * 参考：本机 BambuHelper/ESP32 那套天气页（手动城市 / IP 定位、摄氏度固定）。
 * 这里同样只做摄氏度，城市用经纬度（默认北京），支持 /set 改。
 *
 * 设计要点：
 *  · **绝不阻塞帧循环**：fetch 是异步的，到点（15 分钟）才发起；失败保留旧数据
 *  · 解析只挑需要的字段，WMO weather_code → 内部 Condition
 *  · 没有网络 / 首次失败时返回 `ok=false`，渲染层照常画动态背景 + "取数中"
 */

import { http } from '@kit.NetworkKit';
import { Logger } from '../common/Logger';

/** WMO 天气代码归一成内部条件（决定画什么） */
export enum WxCond {
  CLEAR = 0,      // 晴
  CLOUDY = 1,     // 多云/阴
  FOG = 2,        // 雾
  RAIN = 3,       // 雨
  SNOW = 4,       // 雪
  THUNDER = 5     // 雷
}

export class WeatherData {
  ok: boolean = false;
  city: string = '北京';
  lat: number = 39.9042;
  lon: number = 116.4074;
  /** 当前温度（℃） */
  tempC: number = 0;
  /** 体感温度 */
  feelsC: number = 0;
  humidity: number = 0;
  windKph: number = 0;
  /** 风向（度，0=北，顺时针） */
  windDeg: number = 0;
  cond: WxCond = WxCond.CLEAR;
  /** WMO 原始代码（诊断用） */
  code: number = 0;
  /** 未来 24 小时温度（从当前小时起） */
  hourly: number[] = [];
  /** 未来 7 天：最低温 */
  dMin: number[] = [];
  /** 未来 7 天：最高温 */
  dMax: number[] = [];
  /** 未来 7 天：条件 */
  dCond: WxCond[] = [];
  /** 最近一次成功取数的时间（ms） */
  atMs: number = 0;
  /** 失败原因（空=正常） */
  errText: string = '';
}

/** WMO code → 内部条件 */
export function condOf(code: number): WxCond {
  if (code === 0 || code === 1) {
    return WxCond.CLEAR;
  }
  if (code === 2 || code === 3) {
    return WxCond.CLOUDY;
  }
  if (code === 45 || code === 48) {
    return WxCond.FOG;
  }
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
    return WxCond.RAIN;
  }
  if (code >= 71 && code <= 77) {
    return WxCond.SNOW;
  }
  if (code >= 85 && code <= 86) {
    return WxCond.SNOW;
  }
  if (code >= 95) {
    return WxCond.THUNDER;
  }
  return WxCond.CLOUDY;
}

/** 条件中文名 */
export function condName(c: WxCond): string {
  switch (c) {
    case WxCond.CLEAR: return '晴';
    case WxCond.CLOUDY: return '多云';
    case WxCond.FOG: return '雾';
    case WxCond.RAIN: return '雨';
    case WxCond.SNOW: return '雪';
    case WxCond.THUNDER: return '雷阵雨';
    default: return '—';
  }
}

/** 刷新间隔：15 分钟（天气变化没那么快，省流量也省电） */
const REFRESH_MS: number = 15 * 60 * 1000;
/** 首次失败后的重试间隔 */
const RETRY_MS: number = 60 * 1000;

export class WeatherService {
  data: WeatherData = new WeatherData();
  /** 是否正在请求（防重入） */
  private busy: boolean = false;
  private lastTryMs: number = 0;
  private failCount: number = 0;

  /** 设置城市（下次刷新生效；立即触发一次） */
  setPlace(city: string, lat: number, lon: number): void {
    if (city.length > 0) {
      this.data.city = city;
    }
    if (Number.isFinite(lat) && Number.isFinite(lon)) {
      this.data.lat = lat;
      this.data.lon = lon;
    }
    this.lastTryMs = 0;    // 立刻可刷新
  }

  /** 强制刷新（/set?wx=1） */
  forceRefresh(): void {
    this.lastTryMs = 0;
    this.data.atMs = 0;
  }

  /** 数据有多旧（秒），-1=从未成功 */
  ageSec(nowMs: number): number {
    return this.data.atMs === 0 ? -1 : Math.floor((nowMs - this.data.atMs) / 1000);
  }

  /**
   * 帧循环每帧调用：到点才发请求，**从不阻塞**。
   * @returns true 表示这次调用发起了一次刷新（供内容签名用）
   */
  tick(nowMs: number): boolean {
    if (this.busy) {
      return false;
    }
    const interval: number = this.data.ok ? REFRESH_MS : RETRY_MS;
    if (this.lastTryMs > 0 && nowMs - this.lastTryMs < interval) {
      return false;
    }
    this.lastTryMs = nowMs;
    this.busy = true;
    this.fetchNow().then(() => {
      this.busy = false;
    }).catch((e: Object) => {
      this.busy = false;
      this.failCount++;
      this.data.errText = Logger.safe(e);
      Logger.w(`天气取数失败（第 ${this.failCount} 次）: ${this.data.errText}`);
    });
    return true;
  }

  private buildUrl(): string {
    const la: string = this.data.lat.toFixed(4);
    const lo: string = this.data.lon.toFixed(4);
    return 'https://api.open-meteo.com/v1/forecast'
      + `?latitude=${la}&longitude=${lo}`
      + '&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,'
      + 'wind_speed_10m,wind_direction_10m'
      + '&hourly=temperature_2m'
      + '&daily=temperature_2m_max,temperature_2m_min,weather_code'
      + '&forecast_days=7&timezone=auto&wind_speed_unit=kmh';
  }

  private async fetchNow(): Promise<void> {
    const req = http.createHttp();
    try {
      const resp = await req.request(this.buildUrl(), {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode !== 200) {
        this.data.errText = `HTTP ${resp.responseCode}`;
        return;
      }
      const body: string = typeof resp.result === 'string' ? resp.result : '';
      this.parse(body);
    } finally {
      req.destroy();
    }
  }

  /** 解析 Open-Meteo 返回（只取需要的字段，字段缺失就跳过） */
  parse(body: string): void {
    if (body.length < 32) {
      this.data.errText = '空响应';
      return;
    }
    let j: Record<string, Object> | null = null;
    try {
      j = JSON.parse(body) as Record<string, Object>;
    } catch (e) {
      this.data.errText = 'JSON 解析失败';
      return;
    }
    if (j === null) {
      this.data.errText = 'JSON 为空';
      return;
    }
    const cur = j['current'] as Record<string, number> | undefined;
    if (cur === undefined) {
      this.data.errText = '缺少 current';
      return;
    }
    const num = (o: Record<string, number> | undefined, k: string, d: number): number => {
      if (o === undefined) {
        return d;
      }
      const v = o[k];
      return (typeof v === 'number' && Number.isFinite(v)) ? v : d;
    };
    this.data.code = Math.round(num(cur, 'weather_code', 0));
    this.data.cond = condOf(this.data.code);
    this.data.tempC = num(cur, 'temperature_2m', 0);
    this.data.feelsC = num(cur, 'apparent_temperature', this.data.tempC);
    this.data.humidity = Math.round(num(cur, 'relative_humidity_2m', 0));
    this.data.windKph = num(cur, 'wind_speed_10m', 0);
    this.data.windDeg = num(cur, 'wind_direction_10m', 0);

    // 24 小时温度：取 current.time 之后最近的 24 个点
    const hourly = j['hourly'] as Record<string, Object> | undefined;
    if (hourly !== undefined) {
      const hT = hourly['temperature_2m'] as number[] | undefined;
      const hTime = hourly['time'] as string[] | undefined;
      if (hT !== undefined && hT.length > 0) {
        let start: number = 0;
        const nowIso: string = new Date().toISOString().substring(0, 13);
        if (hTime !== undefined) {
          for (let i = 0; i < hTime.length; i++) {
            if (hTime[i].substring(0, 13) >= nowIso) {
              start = i;
              break;
            }
          }
        }
        const out: number[] = [];
        for (let i = start; i < hT.length && out.length < 24; i++) {
          out.push(hT[i]);
        }
        this.data.hourly = out;
      }
    }
    // 7 天
    const daily = j['daily'] as Record<string, Object> | undefined;
    if (daily !== undefined) {
      const dMin = daily['temperature_2m_min'] as number[] | undefined;
      const dMax = daily['temperature_2m_max'] as number[] | undefined;
      const dCode = daily['weather_code'] as number[] | undefined;
      if (dMin !== undefined && dMax !== undefined) {
        this.data.dMin = dMin.slice(0, 7);
        this.data.dMax = dMax.slice(0, 7);
        const cs: WxCond[] = [];
        if (dCode !== undefined) {
          for (let i = 0; i < dCode.length && i < 7; i++) {
            cs.push(condOf(dCode[i]));
          }
        }
        this.data.dCond = cs;
      }
    }
    this.data.ok = true;
    this.data.atMs = Date.now();
    this.data.errText = '';
    Logger.i(`天气已更新：${this.data.city} ${this.data.tempC.toFixed(1)}℃ ${condName(this.data.cond)}`);
  }
}
