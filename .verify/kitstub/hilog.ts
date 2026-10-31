// 离线自检桩：hilog 是真机日志 API（mario/Game 的调试日志走它），全部 no-op。
const noop = (): void => {};
export const hilog = { debug: noop, info: noop, warn: noop, error: noop, fatal: noop };
