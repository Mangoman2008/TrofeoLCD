/**
 * Json.ets — 极小的 JSON 输出助手（纯逻辑，可离线测试）
 *
 * 诊断接口要把设备名、描述符行等任意字符串拼进 JSON，必须转义，
 * 否则一个引号就会产出坏 JSON，外部脚本解析失败——而这恰恰发生在最需要
 * 诊断信息的时候。所以转义单独抽出来并测试。
 */

/** 转义 JSON 字符串内容（不含首尾引号） */
export function jsonEscape(s: string): string {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    const code = s.charCodeAt(i);
    if (c === '"') {
      out += '\\"';
    } else if (c === '\\') {
      out += '\\\\';
    } else if (c === '\n') {
      out += '\\n';
    } else if (c === '\r') {
      out += '\\r';
    } else if (c === '\t') {
      out += '\\t';
    } else if (code < 0x20) {
      // 其它控制字符转成 \\u00XX
      const hex = code.toString(16);
      out += '\\u' + '0000'.substring(0, 4 - hex.length) + hex;
    } else {
      out += c;
    }
  }
  return out;
}

/** 带引号的 JSON 字符串字面量 */
export function jsonStr(s: string): string {
  return '"' + jsonEscape(s) + '"';
}

/** 数字输出；非有限值输出 null（JSON 不允许 NaN / Infinity） */
export function jsonNum(v: number): string {
  if (!isFinite(v)) {
    return 'null';
  }
  return `${v}`;
}

/** 布尔字面量 */
export function jsonBool(v: boolean): string {
  return v ? 'true' : 'false';
}
