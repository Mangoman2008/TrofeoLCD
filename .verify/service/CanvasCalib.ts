/**
 * CanvasCalib.ets — 画布尺寸自校正（纯逻辑，可离线测试）
 *
 * 背景：鸿蒙 ArkUI Canvas 的绘制坐标是 vp，而 toDataURL 输出的是「组件 vp 尺寸 ×
 * 设备密度」的像素。设备要求精确 1920×462（9.16），所以不能靠读 densityPixels（可能不准），
 * 而是：渲染一帧 → 从 JPEG 的 SOF 读出真实像素尺寸 → 反推并修正画布 vp 尺寸 →
 * 收敛后再开始推帧。
 *
 * 这段逻辑一旦出错就是「永远不出画面」或「尺寸永远不对」，所以抽成纯函数，
 * 用合成场景做已知答案测试（见 SelfTest.ets）。
 */

/** 画布尺寸上下限（防止异常测量值把组件尺寸搞爆） */
export const VP_MIN_W: number = 160;
export const VP_MAX_W: number = 3840;
export const VP_MIN_H: number = 40;
export const VP_MAX_H: number = 960;

/** 连续不匹配多少次后放弃精确校准、按当前尺寸强行推帧 */
export const MAX_CALIB_ATTEMPTS: number = 5;

export class CalibState {
  vpW: number;
  vpH: number;
  okStreak: number = 0;
  calibrated: boolean = false;
  /** 连续尺寸不匹配的次数 */
  attempts: number = 0;

  constructor(vpW: number, vpH: number) {
    this.vpW = vpW;
    this.vpH = vpH;
  }
}

export class CalibStep {
  /**
   * resize : 需要更新画布尺寸
   * ready  : 尺寸匹配，可以推帧
   * forced : 多次不匹配后放弃精确校准，按当前尺寸推帧（至少让屏幕有画面）
   * invalid: 测量无效，本帧跳过
   */
  action: string = 'invalid';
  calibrated: boolean = false;
  vpW: number = 0;
  vpH: number = 0;
  /** 本次调整前的实际测量值，便于日志 */
  measuredW: number = 0;
  measuredH: number = 0;
  note: string = '';
}

function finitePositive(v: number): boolean {
  return typeof v === 'number' && isFinite(v) && v > 0;
}

function clamp(v: number, lo: number, hi: number): number {
  if (!isFinite(v)) {
    return lo;
  }
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

/**
 * 推进一次校正。
 *
 * @param st        当前状态（会被就地更新）
 * @param targetW/H 设备要求的分辨率
 * @param measW/H   本帧 JPEG 实测像素尺寸（0 或 NaN 表示无效）
 * @param needStreak 连续匹配多少帧才认为收敛（默认 1）
 */
export function calibrate(st: CalibState, targetW: number, targetH: number,
                          measW: number, measH: number,
                          needStreak: number = 1,
                          maxAttempts: number = MAX_CALIB_ATTEMPTS): CalibStep {
  const step = new CalibStep();
  step.measuredW = measW;
  step.measuredH = measH;
  step.vpW = st.vpW;
  step.vpH = st.vpH;

  // 目标本身无效 -> 无从校正
  if (!finitePositive(targetW) || !finitePositive(targetH)) {
    step.action = 'invalid';
    step.note = 'target invalid';
    step.calibrated = st.calibrated;
    return step;
  }

  // 测量无效 -> 本帧跳过，不计入 streak
  if (!finitePositive(measW) || !finitePositive(measH)) {
    step.action = 'invalid';
    step.note = `measure invalid (${measW}x${measH})`;
    step.calibrated = st.calibrated;
    return step;
  }

  if (measW === targetW && measH === targetH) {
    st.okStreak++;
    st.attempts = 0;
    const need = needStreak > 0 ? needStreak : 1;
    st.calibrated = st.okStreak >= need;
    step.calibrated = st.calibrated;
    step.action = st.calibrated ? 'ready' : 'invalid';
    step.note = `match streak=${st.okStreak}/${need}`;
    return step;
  }

  // 尺寸不符：先按比例反推画布 vp 尺寸
  const nw = clamp(st.vpW * targetW / measW, VP_MIN_W, VP_MAX_W);
  const nh = clamp(st.vpH * targetH / measH, VP_MIN_H, VP_MAX_H);
  st.okStreak = 0;
  st.attempts = st.attempts + 1;

  // 兜底：反复收敛不了（例如被钳制或测量不稳定），就按当前尺寸强行推帧。
  // 尺寸不完美至少能看见画面并据此判断问题，比一直黑屏好排查得多。
  if (st.attempts >= maxAttempts) {
    st.calibrated = true;
    step.calibrated = true;
    step.action = 'forced';
    step.note = `放弃精确校准（尝试 ${st.attempts} 次，实测 ${measW}x${measH}，`
      + `画布 vp ${st.vpW.toFixed(0)}x${st.vpH.toFixed(0)}）`;
    return step;
  }

  st.calibrated = false;
  st.vpW = nw;
  st.vpH = nh;
  step.vpW = nw;
  step.vpH = nh;
  step.calibrated = false;
  step.action = 'resize';
  step.note = `${measW}x${measH} -> vp ${nw.toFixed(1)}x${nh.toFixed(1)}`
    + ` (第 ${st.attempts}/${maxAttempts} 次)`;
  return step;
}

/**
 * JPEG 体积超限时的降质序列（≤650KB 是设备限制）。
 * 返回下一个质量值；已到下限则返回下限。
 */
export function nextQuality(current: number, step: number = 0.15,
                            min: number = 0.4): number {
  const q = current - step;
  return q < min ? min : q;
}
