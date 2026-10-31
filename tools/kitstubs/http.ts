// kitstub: http —— 真机网络 API（service/WeatherService 的取数走它）。
// 自检/审计从不真正发请求：createHttp 一旦被调用就大声失败，
// 宁可在审计里立刻暴露"不该走到网络路径"，也不静默吞掉。
export const http = {
  createHttp: (): never => {
    throw new Error('kitstub/http: 离线审计不发真请求（WeatherService.fetchNow 不该被走到）');
  },
  RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE', HEAD: 'HEAD' },
  HttpDataType: { STRING: 'STRING', ARRAY_BUFFER: 'ARRAY_BUFFER', OBJECT: 'OBJECT' },
};
