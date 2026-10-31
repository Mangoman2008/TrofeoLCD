using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace DshLcd
{
    /// <summary>
    /// 拓竹取数配置（凭据 + 区域 + 阈值）。
    ///
    /// ★ 2026-10-15 新增。移植自 Node 的 `bambu-monitor/lib/config.mjs`，
    ///   但**改了点**：默认路径不再放程序目录，见下面 <see cref="ResolvePath"/> 的说明。
    ///
    /// ## 配置文件格式（JSON，扁平；比 Node 那套少一层嵌套）
    /// ```json
    /// {
    ///   "region": "auto",            // auto | cn | global
    ///   "token": "…",                // 浏览器 access token（与 cookie 二选一，cookie 优先）
    ///   "cookie": "…",               // 拓竹网页 Cookie 整段（里面含 token=…）
    ///   "serial": "22E8…",           // 打印机 SN（留空自动发现并存回）
    ///   "deviceName": "",            // SN 不填时按名称匹配
    ///   "offlineTimeoutMs": 90000,
    ///   "pushallIntervalMs": 30000,
    ///   "insecure": false            // 跳过 TLS 证书校验（仅自签代理排障用）
    /// }
    /// ```
    /// </summary>
    public class BambuConfig
    {
        public string Region = "auto";
        public string Token = "";
        public string Cookie = "";
        public string Serial = "";
        public string DeviceName = "";
        public int OfflineTimeoutMs = BambuState.DefaultOfflineTimeoutMs;
        public int PushallIntervalMs = 30000;
        public bool Insecure;

        /// <summary>实际读到的配置文件路径（不存在时是"将要写入"的路径）</summary>
        public string Path = "";

        /// <summary>是否配了可用凭据（token 或 cookie 里有 token）</summary>
        public bool HasCredential
        {
            get { return ResolveToken().Length > 0; }
        }

        /// <summary>
        /// 凭据解析（对齐 Node `auth.mjs` 的 `resolveAuth`）：
        /// cookie 里能找到 token 就用它，否则用显式 token。
        /// </summary>
        public string ResolveToken()
        {
            string fromCookie = TokenFromCookie(Cookie);
            if (fromCookie.Length > 0) return fromCookie;
            return Token == null ? "" : Token.Trim();
        }

        /// <summary>凭据来源，用于日志（"cookie" / "token" / "none"）</summary>
        public string CredentialSource()
        {
            if (TokenFromCookie(Cookie).Length > 0) return "cookie";
            if (!string.IsNullOrEmpty(Token) && Token.Trim().Length > 0) return "token";
            return "none";
        }

        /// <summary>
        /// 从整段 Cookie 头里取出 token；也接受"直接贴 token"。
        /// 对齐 Node `tokenFromCookie`（含 `[A-Za-z0-9._-]{40,}` 的裸串判断）。
        /// </summary>
        public static string TokenFromCookie(string raw)
        {
            string s = raw == null ? "" : raw.Trim();
            if (s.Length == 0) return "";

            // 形如 "a=1; token=eyJ...; b=2"
            int idx = s.IndexOf("token=", StringComparison.OrdinalIgnoreCase);
            while (idx >= 0)
            {
                bool atStart = (idx == 0) || (s[idx - 1] == ';') || (s[idx - 1] == ' ');
                if (atStart)
                {
                    int from = idx + 6;
                    int to = s.IndexOf(';', from);
                    string val = (to < 0 ? s.Substring(from) : s.Substring(from, to - from)).Trim();
                    if (val.Length > 0) return Uri.UnescapeDataString(val);
                }
                idx = s.IndexOf("token=", idx + 6, StringComparison.OrdinalIgnoreCase);
            }

            // 直接贴的 token / 长串（JWT 或 AQA… 开头）
            if (s.Length >= 40 && IsBareToken(s)) return s;
            return "";
        }

        private static bool IsBareToken(string s)
        {
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                          || c == '.' || c == '_' || c == '-';
                if (!ok) return false;
            }
            return true;
        }

        /// <summary>脱敏，任何日志里都不出现完整凭据（对齐 Node `mask`）</summary>
        public static string Mask(string s)
        {
            string v = s == null ? "" : s;
            if (v.Length <= 14) return v.Length > 0 ? "***" : "";
            return v.Substring(0, 6) + "…" + v.Substring(v.Length - 4) + "（长度 " + v.Length + "）";
        }

        // ================= 路径与读写 =================

        /// <summary>
        /// 解析配置文件路径。查找顺序：
        ///   ① 显式 --bambu-config 指定的路径（由调用方直接赋值给 Path，不走这里）
        ///   ② exe 同目录的 `bambu.json`（方便"整个目录一起拷走"）
        ///   ③ `%ProgramData%\dshlcd\bambu.json`（**默认**；凭据不该躺在会被共享/同步出去的目录里）
        ///
        /// ★ 为什么不默认放 exe 旁：本工程的 exe 目录在 VM 共享盘上（`C:\dshlcd`），
        ///   把 access token 明文放那儿风险太大。所以只有你**主动**在 exe 旁放了
        ///   `bambu.json` 才用它，否则一律写到 ProgramData。
        /// </summary>
        public static string ResolvePath(string exeDir)
        {
            try
            {
                if (!string.IsNullOrEmpty(exeDir))
                {
                    string local = System.IO.Path.Combine(exeDir, "bambu.json");
                    if (File.Exists(local)) return local;
                }
            }
            catch (Exception) { }

            try
            {
                string pd = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
                if (!string.IsNullOrEmpty(pd))
                {
                    return System.IO.Path.Combine(pd, "dshlcd", "bambu.json");
                }
            }
            catch (Exception) { }

            // 兜底：用户目录
            string home = null;
            try { home = Environment.GetEnvironmentVariable("USERPROFILE"); } catch (Exception) { }
            if (string.IsNullOrEmpty(home)) home = ".";
            return System.IO.Path.Combine(home, "bambu.json");
        }

        /// <summary>读配置；文件不存在或坏掉都返回默认值（不抛）</summary>
        public static BambuConfig Load(string path)
        {
            BambuConfig c = new BambuConfig();
            c.Path = path;
            try
            {
                if (!File.Exists(path)) return c;
                string text = File.ReadAllText(path, Encoding.UTF8);
                JsonValue j = JsonValue.Parse(text);
                if (j == null || !j.IsObj) return c;

                c.Region = StrOf(j, "region", c.Region);
                c.Token = StrOf(j, "token", "");
                c.Cookie = StrOf(j, "cookie", "");
                c.Serial = StrOf(j, "serial", "");
                c.DeviceName = StrOf(j, "deviceName", "");
                c.OfflineTimeoutMs = IntOf(j, "offlineTimeoutMs", c.OfflineTimeoutMs);
                c.PushallIntervalMs = IntOf(j, "pushallIntervalMs", c.PushallIntervalMs);
                JsonValue ins = j.Get("insecure");
                if (ins != null && ins.IsBool) c.Insecure = ins.B;
                // region 收敛
                string r = (c.Region == null ? "" : c.Region.Trim().ToLowerInvariant());
                if (r != "cn" && r != "global") r = "auto";
                c.Region = r;
            }
            catch (Exception ex)
            {
                Log.W("读取拓竹配置失败（用默认值）：{0}", ex.Message);
            }
            return c;
        }

        /// <summary>写配置（自动建目录；**只写已知字段**，不改动不认识的键）</summary>
        public bool Save()
        {
            try
            {
                string dir = System.IO.Path.GetDirectoryName(Path);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                {
                    Directory.CreateDirectory(dir);
                }
                JsonValue o = JsonValue.NewObj();
                o.Obj["region"] = JsonValue.NewStr(Region);
                o.Obj["token"] = JsonValue.NewStr(Token);
                o.Obj["cookie"] = JsonValue.NewStr(Cookie);
                o.Obj["serial"] = JsonValue.NewStr(Serial);
                o.Obj["deviceName"] = JsonValue.NewStr(DeviceName);
                o.Obj["offlineTimeoutMs"] = JsonValue.NewNum(OfflineTimeoutMs);
                o.Obj["pushallIntervalMs"] = JsonValue.NewNum(PushallIntervalMs);
                o.Obj["insecure"] = JsonValue.NewBool(Insecure);
                File.WriteAllText(Path, o.ToJson(), new UTF8Encoding(false));
                return true;
            }
            catch (Exception ex)
            {
                Log.Err("写拓竹配置失败：{0}", ex.Message);
                return false;
            }
        }

        private static string StrOf(JsonValue j, string k, string def)
        {
            JsonValue v = j.Get(k);
            if (v == null || v.IsNull) return def;
            if (v.IsStr) return v.S == null ? def : v.S;
            return def;
        }

        private static int IntOf(JsonValue j, string k, int def)
        {
            JsonValue v = j.Get(k);
            if (v == null || v.IsNull) return def;
            if (v.IsNum) return (int)Math.Round(v.N);
            if (v.IsStr)
            {
                double d;
                if (double.TryParse(v.S, out d)) return (int)Math.Round(d);
            }
            return def;
        }
    }
}
