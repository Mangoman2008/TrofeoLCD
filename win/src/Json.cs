using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace DshLcd
{
    /// <summary>
    /// 极简 JSON（C# 5，零外部依赖）。
    /// 不引 System.Web.Extensions：绿色单文件少一个 GAC 依赖，解析行为也完全可控。
    /// 解析失败返回 null，调用方一律走"回到默认值"的路径。
    /// </summary>
    public class JsonValue
    {
        public enum Kind { Null, Bool, Num, Str, Arr, Obj }

        public Kind K = Kind.Null;
        public bool B;
        public double N;
        public string S;
        public List<JsonValue> Arr;
        public Dictionary<string, JsonValue> Obj;

        public bool IsNull { get { return K == Kind.Null; } }
        public bool IsObj { get { return K == Kind.Obj; } }
        public bool IsArr { get { return K == Kind.Arr; } }
        public bool IsStr { get { return K == Kind.Str; } }
        public bool IsNum { get { return K == Kind.Num; } }
        public bool IsBool { get { return K == Kind.Bool; } }

        /// <summary>取对象成员；不存在返回 null</summary>
        public JsonValue Get(string key)
        {
            if (K != Kind.Obj || Obj == null) return null;
            JsonValue v;
            return Obj.TryGetValue(key, out v) ? v : null;
        }

        public JsonValue At(int i)
        {
            if (K != Kind.Arr || Arr == null || i < 0 || i >= Arr.Count) return null;
            return Arr[i];
        }

        public int Count { get { return (K == Kind.Arr && Arr != null) ? Arr.Count : 0; } }

        public static JsonValue NewObj()
        {
            JsonValue v = new JsonValue();
            v.K = Kind.Obj;
            v.Obj = new Dictionary<string, JsonValue>();
            return v;
        }

        public static JsonValue NewArr()
        {
            JsonValue v = new JsonValue();
            v.K = Kind.Arr;
            v.Arr = new List<JsonValue>();
            return v;
        }

        public static JsonValue NewStr(string s)
        {
            JsonValue v = new JsonValue();
            v.K = Kind.Str;
            v.S = s;
            return v;
        }

        public static JsonValue NewNum(double d)
        {
            JsonValue v = new JsonValue();
            v.K = Kind.Num;
            v.N = d;
            return v;
        }

        public static JsonValue NewBool(bool b)
        {
            JsonValue v = new JsonValue();
            v.K = Kind.Bool;
            v.B = b;
            return v;
        }

        public static JsonValue Parse(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            int i = 0;
            try
            {
                JsonValue v = ParseValue(text, ref i);
                SkipWs(text, ref i);
                if (i < text.Length) return v;   // 后面还有垃圾就忽略（UDP 分包场景）
                return v;
            }
            catch (Exception)
            {
                return null;
            }
        }

        private static void SkipWs(string s, ref int i)
        {
            while (i < s.Length)
            {
                char c = s[i];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') i++;
                else break;
            }
        }

        private static JsonValue ParseValue(string s, ref int i)
        {
            SkipWs(s, ref i);
            if (i >= s.Length) throw new FormatException("空");
            char c = s[i];
            if (c == '{') return ParseObj(s, ref i);
            if (c == '[') return ParseArr(s, ref i);
            if (c == '"') return NewStr(ParseString(s, ref i));
            if (c == 't' || c == 'f')
            {
                if (Match(s, ref i, "true")) return NewBool(true);
                if (Match(s, ref i, "false")) return NewBool(false);
                throw new FormatException("坏字面量");
            }
            if (c == 'n')
            {
                if (Match(s, ref i, "null")) return new JsonValue();
                throw new FormatException("坏字面量");
            }
            return ParseNumber(s, ref i);
        }

        private static bool Match(string s, ref int i, string lit)
        {
            if (i + lit.Length > s.Length) return false;
            if (string.CompareOrdinal(s, i, lit, 0, lit.Length) != 0) return false;
            i += lit.Length;
            return true;
        }

        private static JsonValue ParseObj(string s, ref int i)
        {
            JsonValue o = NewObj();
            i++;                       // {
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == '}') { i++; return o; }
            while (true)
            {
                SkipWs(s, ref i);
                if (i >= s.Length || s[i] != '"') throw new FormatException("期望键");
                string key = ParseString(s, ref i);
                SkipWs(s, ref i);
                if (i >= s.Length || s[i] != ':') throw new FormatException("期望冒号");
                i++;
                JsonValue val = ParseValue(s, ref i);
                o.Obj[key] = val;
                SkipWs(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == '}') { i++; return o; }
                throw new FormatException("期望逗号或右括号");
            }
        }

        private static JsonValue ParseArr(string s, ref int i)
        {
            JsonValue a = NewArr();
            i++;                       // [
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == ']') { i++; return a; }
            while (true)
            {
                JsonValue val = ParseValue(s, ref i);
                a.Arr.Add(val);
                SkipWs(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == ']') { i++; return a; }
                throw new FormatException("期望逗号或右括号");
            }
        }

        private static string ParseString(string s, ref int i)
        {
            i++;                       // "
            StringBuilder sb = new StringBuilder();
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= s.Length) break;
                char e = s[i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        if (i + 4 <= s.Length)
                        {
                            int code = 0;
                            for (int k = 0; k < 4; k++)
                            {
                                code = code * 16 + HexVal(s[i + k]);
                            }
                            sb.Append((char)code);
                            i += 4;
                        }
                        break;
                    default: sb.Append(e); break;
                }
            }
            throw new FormatException("字符串没结束");
        }

        private static int HexVal(char c)
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            throw new FormatException("坏十六进制");
        }

        private static JsonValue ParseNumber(string s, ref int i)
        {
            int start = i;
            if (i < s.Length && (s[i] == '-' || s[i] == '+')) i++;
            while (i < s.Length)
            {
                char c = s[i];
                if ((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '-' || c == '+') i++;
                else break;
            }
            string num = s.Substring(start, i - start);
            double d;
            if (double.TryParse(num, NumberStyles.Float, CultureInfo.InvariantCulture, out d))
            {
                return NewNum(d);
            }
            throw new FormatException("坏数字: " + num);
        }

        /// <summary>序列化为 JSON 文本（诊断接口用）</summary>
        public string ToJson()
        {
            StringBuilder sb = new StringBuilder();
            Write(sb);
            return sb.ToString();
        }

        private void Write(StringBuilder sb)
        {
            switch (K)
            {
                case Kind.Null: sb.Append("null"); break;
                case Kind.Bool: sb.Append(B ? "true" : "false"); break;
                case Kind.Num:
                    if (N == Math.Floor(N) && Math.Abs(N) < 1e15) sb.Append(((long)N).ToString(CultureInfo.InvariantCulture));
                    else sb.Append(N.ToString("0.####", CultureInfo.InvariantCulture));
                    break;
                case Kind.Str: WriteStr(sb, S); break;
                case Kind.Arr:
                    sb.Append('[');
                    for (int i = 0; i < Arr.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        Arr[i].Write(sb);
                    }
                    sb.Append(']');
                    break;
                case Kind.Obj:
                    sb.Append('{');
                    bool first = true;
                    foreach (KeyValuePair<string, JsonValue> kv in Obj)
                    {
                        if (!first) sb.Append(',');
                        first = false;
                        WriteStr(sb, kv.Key);
                        sb.Append(':');
                        kv.Value.Write(sb);
                    }
                    sb.Append('}');
                    break;
            }
        }

        public static void WriteStr(StringBuilder sb, string s)
        {
            sb.Append('"');
            if (s != null)
            {
                for (int i = 0; i < s.Length; i++)
                {
                    char c = s[i];
                    switch (c)
                    {
                        case '"': sb.Append("\\\""); break;
                        case '\\': sb.Append("\\\\"); break;
                        case '\n': sb.Append("\\n"); break;
                        case '\r': sb.Append("\\r"); break;
                        case '\t': sb.Append("\\t"); break;
                        default:
                            if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                            else sb.Append(c);
                            break;
                    }
                }
            }
            sb.Append('"');
        }
    }
}
