/**
 * ThemeWeather.ets —— 主题 18「天气」（全屏 1920×462，动态 + 3D）
 *
 * 数据来自 WeatherService（Open-Meteo，无密钥，15 分钟刷新）。
 * 视觉：3D 自转线框地球 + 景深粒子 + 立体温度 + 透视风向罗盘 + 24h 曲线 + 7 天。
 *
 * ★ 2026-10-22 改版（用户反馈「整体字太小、要带秒的时钟」）：
 *   · 左上新增**大号带秒时钟**（HH:MM 92px + :SS 50px）
 *   · 全屏字号整体放大 1.4~1.8 倍，最小字号提到 24px
 *   · 修掉原版 bug：7 天那排的天气名画在 y=482，**超出 462 被裁掉**；
 *     现在 7 天只显示"高温/低温/日期"+条件色点，全部落在 y≤444
 *
 * 注意：本工程画布不支持 hsl()，颜色一律用 rgb()/rgba()。
 */

import { WeatherData, WxCond, condName } from '../service/WeatherService';

const W: number = 1920;
const H: number = 462;

/** 3D 点投影：返回 [屏幕x, 屏幕y, 缩放] */
function project(x: number, y: number, z: number, cx: number, cy: number, focal: number): number[] {
  const d: number = z + focal;
  const dd: number = d < 1 ? 1 : d;
  return [cx + x * focal / dd, cy + y * focal / dd, focal / dd];
}

/** 按条件/昼夜给天空配色（上、下） */
function skyColors(c: WxCond, hour: number): number[][] {
  const night: boolean = hour < 6 || hour >= 19;
  if (c === WxCond.THUNDER) {
    return night ? [[14, 12, 30], [40, 28, 64]] : [[24, 22, 44], [58, 44, 86]];
  }
  if (c === WxCond.RAIN) {
    return night ? [[10, 18, 30], [26, 40, 58]] : [[40, 58, 76], [86, 108, 128]];
  }
  if (c === WxCond.SNOW) {
    return night ? [[24, 30, 44], [48, 58, 74]] : [[120, 140, 165], [186, 202, 220]];
  }
  if (c === WxCond.FOG) {
    return night ? [[26, 28, 34], [48, 52, 60]] : [[128, 134, 142], [176, 182, 190]];
  }
  if (c === WxCond.CLOUDY) {
    return night ? [[18, 24, 40], [44, 54, 78]] : [[74, 108, 150], [150, 178, 206]];
  }
  return night ? [[8, 14, 36], [28, 44, 86]] : [[42, 96, 168], [126, 180, 226]];
}

/** 温度数值 → 颜色（冷蓝 → 热红） */
function tempColor(t: number): string {
  const k: number = Math.max(0, Math.min(1, (t + 10) / 45));
  const r: number = Math.round(70 + k * 185);
  const g: number = Math.round(180 - k * 120);
  const b: number = Math.round(255 - k * 210);
  return `rgb(${r},${g},${b})`;
}

/** 条件 → 色点颜色（7 天用） */
function condDot(c: WxCond): string {
  switch (c) {
    case WxCond.CLEAR: return 'rgb(255,205,80)';
    case WxCond.CLOUDY: return 'rgb(190,210,230)';
    case WxCond.FOG: return 'rgb(170,175,185)';
    case WxCond.RAIN: return 'rgb(120,200,255)';
    case WxCond.SNOW: return 'rgb(235,248,255)';
    case WxCond.THUNDER: return 'rgb(255,220,120)';
    default: return 'rgb(200,200,200)';
  }
}

export class ThemeWeather {
  private static px: number[] = [];
  private static py: number[] = [];
  private static pz: number[] = [];
  private static inited: boolean = false;

  /**
   * ★ 字号系数：2026-10-31 布局审计改 **1.0**（原 1.85）。
   *
   * 原注释声称"本工程画布把 ctx.font 的 px 渲染成约 0.5 倍实际高度"——这个前提
   * 是**错的**：F.scale=2.5 的注释（Theme.ets）用 px/mm 实测过设备按 1:1 渲染
   * （"正文 16px ≈ 2mm 字高"），LcdService 的 ctx.scale(1920→画布vp) 也把字号
   * 随变换一起缩放。1.85 补偿下真机实际渲染 1.85×：278px 时钟顶被裁掉 62px、
   * 温度/条件/体感三行互相咬合、体感行横穿 7 天面板、相邻日期标签互叠
   * （layout_check --theme=18 69 条）。全部 f(x) 的**版面坐标本来就是按
   * "x px 字号"设计的**（本文件 :202 注释"时钟 150px 约占屏高 1/4"=150/462
   * 才成立），去掉补偿即恢复设计意图；排版审计以标准字体度量验证通过。
   */
  static FS: number = 1.0;

  private static f(px: number, bold: boolean = false): string {
    const v: number = Math.round(px * ThemeWeather.FS);
    return bold ? `bold ${v}px sans-serif` : `${v}px sans-serif`;
  }

  private static init(): void {
    if (ThemeWeather.inited) {
      return;
    }
    let seed: number = 20261021;
    const rnd = (): number => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    };
    for (let i = 0; i < 140; i++) {
      ThemeWeather.px.push(rnd() * W);
      ThemeWeather.py.push(rnd() * H);
      ThemeWeather.pz.push(0.15 + rnd() * 0.85);
    }
    ThemeWeather.inited = true;
  }

  static render(ctx: CanvasRenderingContext2D, nowMs: number, d: WeatherData): void {
    ThemeWeather.init();

    const now = new Date(nowMs);
    const hour: number = now.getHours();
    const cond: WxCond = d.ok ? d.cond : WxCond.CLOUDY;

    ThemeWeather.sky(ctx, cond, hour);
    ThemeWeather.particles(ctx, cond, nowMs);
    if (cond === WxCond.THUNDER) {
      ThemeWeather.lightning(ctx, nowMs);
    }

    ThemeWeather.left(ctx, nowMs, d, now);
    const isNight: boolean = hour < 6 || hour >= 19;
    ThemeWeather.center(ctx, nowMs, d, cond, isNight);
    ThemeWeather.right(ctx, d);

    ctx.globalAlpha = 0.45;
    ctx.fillStyle = 'rgb(120,200,255)';
    ctx.fillRect(0, 0, W, 2);
    ctx.fillRect(0, H - 2, W, 2);
    ctx.globalAlpha = 1;
  }

  // ---------------------------------------------------------------- 天空
  private static sky(ctx: CanvasRenderingContext2D, c: WxCond, hour: number): void {
    const cs: number[][] = skyColors(c, hour);
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, `rgb(${cs[0][0]},${cs[0][1]},${cs[0][2]})`);
    g.addColorStop(1, `rgb(${cs[1][0]},${cs[1][1]},${cs[1][2]})`);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
    ThemeWeather.hill(ctx, 330, 34, 'rgba(10,20,34,0.45)');
    ThemeWeather.hill(ctx, 392, 22, 'rgba(6,12,22,0.65)');
  }

  private static hill(ctx: CanvasRenderingContext2D, baseY: number, amp: number, col: string): void {
    ctx.fillStyle = col;
    ctx.beginPath();
    ctx.moveTo(0, H);
    for (let x = 0; x <= W; x += 24) {
      const y: number = baseY + Math.sin(x * 0.0032) * amp + Math.sin(x * 0.011 + 1.3) * amp * 0.45;
      ctx.lineTo(x, y);
    }
    ctx.lineTo(W, H);
    ctx.closePath();
    ctx.fill();
  }

  // ---------------------------------------------------------------- 粒子（景深）
  private static particles(ctx: CanvasRenderingContext2D, c: WxCond, nowMs: number): void {
    const isRain: boolean = c === WxCond.RAIN || c === WxCond.THUNDER;
    const isSnow: boolean = c === WxCond.SNOW;
    const count: number = isRain ? 140 : (isSnow ? 110 : 48);
    const t: number = nowMs / 1000;
    for (let i = 0; i < count; i++) {
      const z: number = ThemeWeather.pz[i];
      const k: number = 1 / z;
      let y: number = ThemeWeather.py[i] + t * (isSnow ? 26 : 220) * k;
      y = y % (H + 40);
      const x: number = ThemeWeather.px[i] + (isSnow ? Math.sin(t * 1.3 + i) * 26 * z : 0);
      if (isRain) {
        ctx.strokeStyle = `rgba(190,225,255,${(0.16 + 0.5 * z).toFixed(3)})`;
        ctx.lineWidth = 0.8 + 1.4 * z;
        ctx.beginPath();
        ctx.moveTo(x, y);
        ctx.lineTo(x - 3 * k, y + 10 * k);
        ctx.stroke();
      } else if (isSnow) {
        ctx.fillStyle = `rgba(255,255,255,${(0.25 + 0.65 * z).toFixed(3)})`;
        ctx.beginPath();
        ctx.arc(x, y, 1 + 2.2 * z, 0, Math.PI * 2);
        ctx.fill();
      } else {
        ctx.fillStyle = `rgba(255,255,255,${(0.10 + 0.35 * z).toFixed(3)})`;
        ctx.fillRect(x, y, 1.4 + 1.6 * z, 1.4 + 1.6 * z);
      }
    }
  }

  private static lightning(ctx: CanvasRenderingContext2D, nowMs: number): void {
    const ph: number = (nowMs % 4200) / 4200;
    if (ph < 0.06 || (ph > 0.10 && ph < 0.13)) {
      ctx.fillStyle = 'rgba(220,235,255,0.16)';
      ctx.fillRect(0, 0, W, H);
    }
  }

  // ---------------------------------------------------------------- 左：时钟 + 城市 + 3D 地球
  private static left(ctx: CanvasRenderingContext2D, nowMs: number, d: WeatherData, now: Date): void {
    const hh: string = ThemeWeather.pad2(now.getHours());
    const mm: string = ThemeWeather.pad2(now.getMinutes());
    const ss: string = ThemeWeather.pad2(now.getSeconds());
    const x0: number = 40;
    ctx.textAlign = 'left';
    // ★ 时钟放到 150px（约占屏幕高度 1/4），秒 86px
    ctx.font = ThemeWeather.f(150, true);
    ctx.fillStyle = 'rgb(240,250,255)';
    const main: string = `${hh}:${mm}`;
    ctx.fillText(main, x0, 138);
    const mw: number = ctx.measureText(main).width;
    ctx.font = ThemeWeather.f(86, true);
    ctx.fillStyle = 'rgb(120,229,255)';
    ctx.fillText(`:${ss}`, x0 + mw + 8, 138);

    // 城市 + 条件
    ctx.font = ThemeWeather.f(60, true);
    ctx.fillStyle = 'rgb(234,247,255)';
    const cityTxt: string = d.city.length > 0 ? d.city : '未知城市';
    ctx.fillText(cityTxt, x0, 262);
    const cw: number = ctx.measureText(cityTxt).width;
    ctx.font = ThemeWeather.f(42, true);
    ctx.fillStyle = 'rgb(150,225,255)';
    ctx.fillText(d.ok ? condName(d.cond) : '取数中', x0 + cw + 24, 260);

    // ---- 风向罗盘（透视压扁的椭圆 + 指针，放中下部空区，与左下地球并排）----
    const rx: number = 112;
    const ry: number = 38;
    const ox: number = 486;
    const oy: number = 352;
    ctx.strokeStyle = 'rgba(140,210,245,0.5)';
    ctx.lineWidth = 2.2;
    ctx.beginPath();
    ctx.ellipse(ox, oy, rx, ry, 0, 0, Math.PI * 2);
    ctx.stroke();
    for (let i = 0; i < 8; i++) {
      const a: number = i * Math.PI / 4;
      ctx.beginPath();
      ctx.moveTo(ox + Math.cos(a) * rx * 0.86, oy + Math.sin(a) * ry * 0.86);
      ctx.lineTo(ox + Math.cos(a) * rx, oy + Math.sin(a) * ry);
      ctx.stroke();
    }
    const wa: number = ((d.windDeg - 90) * Math.PI) / 180;
    const wpx: number = ox + Math.cos(wa) * rx * 0.72;
    const wpy: number = oy + Math.sin(wa) * ry * 0.72;
    ctx.strokeStyle = 'rgb(120,235,255)';
    ctx.lineWidth = 4.5;
    ctx.beginPath();
    ctx.moveTo(ox, oy);
    ctx.lineTo(wpx, wpy);
    ctx.stroke();
    ctx.fillStyle = 'rgb(120,235,255)';
    ctx.beginPath();
    ctx.arc(wpx, wpy, 5.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.font = ThemeWeather.f(22, true);      // 方位字比正文小一档，避免和左右内容打架
    ctx.fillStyle = 'rgba(190,222,245,0.9)';
    ctx.textAlign = 'center';
    ctx.fillText('N', ox, oy - ry - 12);
    ctx.fillText('S', ox, oy + ry + 26);
    ctx.fillText('W', ox - rx - 18, oy + 8);
    ctx.fillText('E', ox + rx + 18, oy + 8);
    ctx.textAlign = 'left';

    ThemeWeather.globe(ctx, nowMs, 186, 356, 78);
  }

  private static globe(ctx: CanvasRenderingContext2D, nowMs: number,
                        cx: number, cy: number, R: number): void {
    const focal: number = 300;
    const yaw: number = nowMs / 5200;
    const pitch: number = -0.42;

    const halo = ctx.createRadialGradient(cx, cy, R * 0.4, cx, cy, R * 1.8);
    halo.addColorStop(0, 'rgba(90,190,255,0.20)');
    halo.addColorStop(1, 'rgba(90,190,255,0)');
    ctx.fillStyle = halo;
    ctx.fillRect(cx - R * 2, cy - R * 2, R * 4, R * 4);

    const rot = (x: number, y: number, z: number): number[] => {
      const cyaw: number = Math.cos(yaw);
      const syaw: number = Math.sin(yaw);
      const x1: number = x * cyaw + z * syaw;
      const z1: number = -x * syaw + z * cyaw;
      const cp: number = Math.cos(pitch);
      const sp: number = Math.sin(pitch);
      const y2: number = y * cp - z1 * sp;
      const z2: number = y * sp + z1 * cp;
      return [x1, y2, z2];
    };

    for (let lat = -60; lat <= 60; lat += 30) {
      const la: number = lat * Math.PI / 180;
      ctx.beginPath();
      let started: boolean = false;
      for (let lon = 0; lon <= 360; lon += 8) {
        const lo: number = lon * Math.PI / 180;
        const p = rot(Math.cos(la) * Math.cos(lo) * R, Math.sin(la) * R, Math.cos(la) * Math.sin(lo) * R);
        const s = project(p[0], p[1], p[2], cx, cy, focal);
        if (!started) {
          ctx.moveTo(s[0], s[1]);
          started = true;
        } else {
          ctx.lineTo(s[0], s[1]);
        }
      }
      ctx.strokeStyle = 'rgba(120,210,255,0.32)';
      ctx.lineWidth = 1.2;
      ctx.stroke();
    }
    for (let lon = 0; lon < 360; lon += 30) {
      const lo: number = lon * Math.PI / 180;
      for (let half = 0; half < 2; half++) {
        ctx.beginPath();
        const from: number = half === 0 ? -90 : 0;
        const to: number = half === 0 ? 0 : 90;
        for (let lat = from; lat <= to; lat += 6) {
          const la: number = lat * Math.PI / 180;
          const p = rot(Math.cos(la) * Math.cos(lo) * R, Math.sin(la) * R, Math.cos(la) * Math.sin(lo) * R);
          const s = project(p[0], p[1], p[2], cx, cy, focal);
          if (lat === from) {
            ctx.moveTo(s[0], s[1]);
          } else {
            ctx.lineTo(s[0], s[1]);
          }
        }
        ctx.strokeStyle = 'rgba(150,225,255,0.24)';
        ctx.lineWidth = 1.2;
        ctx.stroke();
      }
    }
    ctx.beginPath();
    for (let lon = 0; lon <= 360; lon += 6) {
      const lo: number = lon * Math.PI / 180;
      const p = rot(Math.cos(lo) * R * 1.06, 0, Math.sin(lo) * R * 1.06);
      const s = project(p[0], p[1], p[2], cx, cy, focal);
      if (lon === 0) {
        ctx.moveTo(s[0], s[1]);
      } else {
        ctx.lineTo(s[0], s[1]);
      }
    }
    ctx.strokeStyle = 'rgba(90,220,255,0.8)';
    ctx.lineWidth = 2.4;
    ctx.stroke();
  }

  // ---------------------------------------------------------------- 中：温度 + 图标 + 罗盘
  private static center(ctx: CanvasRenderingContext2D, nowMs: number, d: WeatherData,
                        c: WxCond, isNight: boolean): void {
    const cx: number = 726;
    const baseY: number = 306;
    const temp: number = d.ok ? d.tempC : 0;
    const txt: string = d.ok ? temp.toFixed(0) : '--';

    ctx.textAlign = 'left';
    ctx.font = 'bold 285px sans-serif';   // 温度：已足够大，不参与放大
    const layers: number = 10;
    for (let i = layers; i >= 1; i--) {
      const a: number = 0.10 + 0.03 * (layers - i);
      ctx.fillStyle = `rgba(10,20,36,${a.toFixed(3)})`;
      ctx.fillText(txt, cx + i * 2.4, baseY + i * 1.8);
    }
    ctx.fillStyle = tempColor(temp);
    ctx.fillText(txt, cx, baseY);
    const tw: number = ctx.measureText(txt).width;

    ctx.font = 'bold 118px sans-serif';   // 单位：不参与放大
    ctx.fillStyle = 'rgba(238,248,255,0.96)';
    ctx.fillText('°C', cx + tw + 12, baseY - 118);

    ctx.font = ThemeWeather.f(68, true);      // 缩小一档：给左侧罗盘/地球让位
    ctx.fillStyle = 'rgb(238,248,255)';
    ctx.fillText(d.ok ? condName(c) : '取数中…', cx, 404);
    ctx.font = ThemeWeather.f(32, true);      // 缩小一档：给下方罗盘/日期让位
    if (d.ok) {
      ctx.fillStyle = 'rgba(196,224,244,0.95)';
      ctx.fillText(`体感 ${d.feelsC.toFixed(0)}°  湿度 ${d.humidity}%  风 ${d.windKph.toFixed(0)}km/h`,
        cx + 8, 446);
    } else {
      ctx.fillStyle = 'rgba(210,170,150,0.95)';
      const why: string = d.errText.length > 0 ? d.errText : '等待首次取数';
      ctx.fillText(why.length > 26 ? why.substring(0, 26) + '…' : why, cx, baseY + 136);
    }

    ThemeWeather.icon(ctx, 1188, 168, c, nowMs, isNight);
  }

  // ---------------------------------------------------------------- 右：24h + 7 天
  private static right(ctx: CanvasRenderingContext2D, d: WeatherData): void {
    const x0: number = 1300;
    const x1: number = W - 30;

    // 标题行：7 天 + 24 小时温度区间（小字，次要信息）
    ctx.font = ThemeWeather.f(38, true);
    ctx.fillStyle = 'rgba(216,240,254,0.97)';
    ctx.fillText(`未来 ${Math.min(5, d.dMax.length)} 天`, x0, 58);
    if (d.ok && d.hourly.length > 1) {
      let lo: number = d.hourly[0];
      let hi: number = d.hourly[0];
      for (let i = 1; i < d.hourly.length; i++) {
        lo = Math.min(lo, d.hourly[i]);
        hi = Math.max(hi, d.hourly[i]);
      }
      ctx.font = ThemeWeather.f(30, false);
      ctx.fillStyle = 'rgba(170,206,232,0.95)';
      ctx.fillText(`24h ${lo.toFixed(0)}°~${hi.toFixed(0)}°`, x0 + 300, 58);
    }

    const n: number = Math.min(5, d.dMax.length);   // 只放 5 天：这个宽度下 7 天放不下大字
    if (n === 0) {
      ctx.font = ThemeWeather.f(30, false);
      ctx.fillStyle = 'rgba(190,210,225,0.8)';
      ctx.fillText('（等待数据）', x0, 160);
      return;
    }
    let gMin: number = d.dMin[0];
    let gMax: number = d.dMax[0];
    for (let i = 1; i < n; i++) {
      gMin = Math.min(gMin, d.dMin[i]);
      gMax = Math.max(gMax, d.dMax[i]);
    }
    const gSpan: number = Math.max(1, gMax - gMin);
    const cw: number = (x1 - x0) / n;
    const barBase: number = 340;
    for (let i = 0; i < n; i++) {
      const bx: number = x0 + i * cw;
      const mn: number = d.dMin[i];
      const mx: number = d.dMax[i];
      const bh: number = 50 + (mx - gMin) / gSpan * 110;   // 50~160px
      const by: number = barBase - bh;
      const bw: number = cw * 0.5;
      // 3D 柱：正面 + 顶面 + 侧面
      ctx.fillStyle = 'rgba(120,190,240,0.46)';
      ctx.fillRect(bx, by, bw, bh);
      ctx.fillStyle = 'rgba(206,236,255,0.62)';
      ctx.fillRect(bx, by - 10, bw, 10);
      ctx.fillStyle = 'rgba(12,22,40,0.5)';
      ctx.fillRect(bx + bw, by + 5, cw * 0.14, bh - 5);
      // 高温（大字）
      ctx.font = ThemeWeather.f(40, true);
      ctx.fillStyle = 'rgba(240,250,255,0.99)';
      ctx.fillText(`${mx.toFixed(0)}°`, bx, by - 20);
      // 条件色点
      if (i < d.dCond.length) {
        ctx.fillStyle = condDot(d.dCond[i]);
        ctx.beginPath();
        ctx.arc(bx + bw + 10, by + 10, 7, 0, Math.PI * 2);
        ctx.fill();
      }
      // 低温
      ctx.font = ThemeWeather.f(32, true);
      ctx.fillStyle = 'rgba(176,206,228,0.96)';
      ctx.fillText(`${mn.toFixed(0)}°`, bx, 380);
      // 日期
      ctx.font = ThemeWeather.f(34, true);
      ctx.fillStyle = 'rgba(212,230,243,0.97)';
      ctx.fillText(i === 0 ? '今天' : `+${i}天`, bx, 436);
    }
  }

  // ---------------------------------------------------------------- 图标
  private static icon(ctx: CanvasRenderingContext2D, cx: number, cy: number,
                      c: WxCond, nowMs: number, isNight: boolean): void {
    const R: number = 62;
    // ★ 夜间晴天画月亮：凌晨两点挂个大太阳太违和（用户反馈）
    if (c === WxCond.CLEAR && isNight) {
      ThemeWeather.moon(ctx, cx, cy, R, nowMs);
      return;
    }
    if (c === WxCond.CLEAR) {
      const g = ctx.createRadialGradient(cx, cy, R * 0.3, cx, cy, R * 2.1);
      g.addColorStop(0, 'rgba(255,220,120,0.42)');
      g.addColorStop(1, 'rgba(255,190,80,0)');
      ctx.fillStyle = g;
      ctx.fillRect(cx - R * 2.2, cy - R * 2.2, R * 4.4, R * 4.4);
      const rot: number = nowMs / 9000 * Math.PI * 2;
      ctx.strokeStyle = 'rgba(255,215,110,0.78)';
      ctx.lineWidth = 4;
      for (let i = 0; i < 12; i++) {
        const a: number = rot + i * Math.PI / 6;
        ctx.beginPath();
        ctx.moveTo(cx + Math.cos(a) * R * 1.25, cy + Math.sin(a) * R * 1.25);
        ctx.lineTo(cx + Math.cos(a) * R * 1.62, cy + Math.sin(a) * R * 1.62);
        ctx.stroke();
      }
      ctx.fillStyle = 'rgb(224,142,26)';
      ctx.beginPath();
      ctx.arc(cx + 4, cy + 4, R, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = 'rgb(255,205,80)';
      ctx.beginPath();
      ctx.arc(cx, cy, R, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = 'rgba(255,246,200,0.85)';
      ctx.beginPath();
      ctx.arc(cx - R * 0.3, cy - R * 0.32, R * 0.42, 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    const cloud = (ox: number, oy: number, s: number): void => {
      ctx.fillStyle = 'rgba(120,150,178,0.95)';
      ctx.beginPath();
      ctx.arc(ox - 26 * s, oy + 6 * s, 22 * s, 0, Math.PI * 2);
      ctx.arc(ox + 26 * s, oy + 6 * s, 20 * s, 0, Math.PI * 2);
      ctx.arc(ox, oy - 8 * s, 26 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = 'rgba(228,242,253,0.98)';
      ctx.beginPath();
      ctx.arc(ox - 24 * s, oy + 2 * s, 21 * s, 0, Math.PI * 2);
      ctx.arc(ox + 24 * s, oy + 2 * s, 19 * s, 0, Math.PI * 2);
      ctx.arc(ox, oy - 11 * s, 25 * s, 0, Math.PI * 2);
      ctx.fill();
    };
    cloud(cx, cy, 1.05);
    if (c === WxCond.RAIN || c === WxCond.THUNDER) {
      ctx.strokeStyle = 'rgba(150,220,255,0.9)';
      ctx.lineWidth = 4;
      const off: number = (nowMs / 120) % 26;
      for (let i = -1; i <= 1; i++) {
        ctx.beginPath();
        ctx.moveTo(cx + i * 26, cy + 32 + off * 0.4);
        ctx.lineTo(cx + i * 26 - 6, cy + 56 + off);
        ctx.stroke();
      }
      if (c === WxCond.THUNDER) {
        ctx.strokeStyle = 'rgb(255,230,120)';
        ctx.lineWidth = 6;
        ctx.beginPath();
        ctx.moveTo(cx + 4, cy + 20);
        ctx.lineTo(cx - 10, cy + 50);
        ctx.lineTo(cx + 6, cy + 48);
        ctx.lineTo(cx - 6, cy + 78);
        ctx.stroke();
      }
    } else if (c === WxCond.SNOW) {
      ctx.strokeStyle = 'rgba(240,250,255,0.95)';
      ctx.lineWidth = 3;
      for (let i = 0; i < 3; i++) {
        const a: number = nowMs / 2200 + i * Math.PI / 3;
        const sx: number = cx + Math.cos(a) * 38;
        const sy: number = cy + 46 + Math.sin(a) * 9;
        for (let k = 0; k < 3; k++) {
          const b: number = k * Math.PI / 3;
          ctx.beginPath();
          ctx.moveTo(sx - Math.cos(b) * 8, sy - Math.sin(b) * 8);
          ctx.lineTo(sx + Math.cos(b) * 8, sy + Math.sin(b) * 8);
          ctx.stroke();
        }
      }
    }
  }

  /** 夜间晴：月牙（真月牙形状用两段圆弧拼）+ 环形山 + 少量星点 */
  private static moon(ctx: CanvasRenderingContext2D, cx: number, cy: number,
                      R: number, nowMs: number): void {
    // 柔和光晕
    const g = ctx.createRadialGradient(cx, cy, R * 0.35, cx, cy, R * 2.3);
    g.addColorStop(0, 'rgba(200,225,255,0.24)');
    g.addColorStop(1, 'rgba(180,210,255,0)');
    ctx.fillStyle = g;
    ctx.fillRect(cx - R * 2.4, cy - R * 2.4, R * 4.8, R * 4.8);

    // 周围几颗闪烁的星
    for (let i = 0; i < 7; i++) {
      const a: number = i * 1.71 + 0.4;
      const rr: number = R * (1.45 + (i % 3) * 0.26);
      const sx: number = cx + Math.cos(a) * rr;
      const sy: number = cy + Math.sin(a) * rr * 0.8;
      const tw: number = 0.3 + 0.7 * Math.abs(Math.sin(nowMs / 1500 + i * 1.9));
      ctx.fillStyle = `rgba(226,238,255,${(tw * 0.85).toFixed(3)})`;
      ctx.beginPath();
      ctx.arc(sx, sy, 1.6 + (i % 2) * 1.4, 0, Math.PI * 2);
      ctx.fill();
    }

    // 月牙：外圆左半 + 内圆反向，闭合成月牙形（不用合成模式，兼容性稳）
    ctx.beginPath();
    ctx.arc(cx, cy, R, Math.PI * 0.5, Math.PI * 1.5, false);
    ctx.arc(cx + R * 0.52, cy, R * 0.96, Math.PI * 1.5, Math.PI * 0.5, true);
    ctx.closePath();
    ctx.fillStyle = 'rgb(240,246,255)';
    ctx.fill();

    // 环形山（只在月牙较厚的一侧）
    ctx.fillStyle = 'rgba(196,210,236,0.9)';
    const craters: number[][] = [
      [-0.46, -0.26, 0.11], [-0.30, 0.26, 0.085], [-0.62, 0.06, 0.07], [-0.40, 0.02, 0.05],
    ];
    for (let i = 0; i < craters.length; i++) {
      const c = craters[i];
      ctx.beginPath();
      ctx.arc(cx + c[0] * R, cy + c[1] * R, c[2] * R, 0, Math.PI * 2);
      ctx.fill();
    }
    // 高光边
    ctx.strokeStyle = 'rgba(255,255,255,0.55)';
    ctx.lineWidth = 1.6;
    ctx.beginPath();
    ctx.arc(cx, cy, R - 0.8, Math.PI * 0.55, Math.PI * 1.45, false);
    ctx.stroke();
  }

  private static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }
}
