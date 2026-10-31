// kitstub: hilog —— 真机日志 API（mario/Game、common/Logger 的日志走它）。
// 离线自检/布局审计时全部 no-op：日志不影响渲染与布局，静默丢弃即可。
const noop = (): void => {};
export const hilog = { debug: noop, info: noop, warn: noop, error: noop, fatal: noop };
