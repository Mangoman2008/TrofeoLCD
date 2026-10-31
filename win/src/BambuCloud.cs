using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;

namespace DshLcd
{
    /// <summary>
    /// 拓竹云端（Bambu Cloud）访问：区域选择、token 校验、设备发现、MQTT 用户名推导。
    ///
    /// 为什么要有它：本机 Node 版 `bambu-monitor` 用 `lib/cloud.mjs` + `lib/auth.mjs`
    /// 先"用 access token 问云端要设备列表 + 数字 uid"，再拿 `u_{uid}` 去连 MQTT
    /// （`cn.mqtt.bambulab.com:8883`，对应本工程的 <see cref="MqttClient"/>）。
    /// 把这一步也搬进 C#，dshlcd 就彻底不依赖 Node 取数服务了 —— 与 MqttClient.cs
    /// 的移植动机一致。
    ///
    /// 逐条对齐 Node 原实现（`lib/cloud.mjs` / `lib/util.mjs` / `lib/auth.mjs`）：
    ///   · REGIONS 两张表（api / mqtt 主机名）一字不差
    ///   · BBL_HEADERS 全部请求头一字不差（服务端会校验 User-Agent 与 X-BBL-*）
    ///   · `/v1/iot-service/api/user/bind` 取设备；`/v1/design-user-service/my/preference` 取 uid
    ///   · token 有效性门槛：trim 后长度 &lt; 20 直接判无效
    ///   · region='auto' 时依次试 cn → global；显式指定区域则只试一次
    ///   · 数字 uid 优先取 preference（新 access token 里已没有 username），
    ///     取到就用 `u_{uid}` 覆盖 JWT 里的用户名，uidSource 记 'preference'，否则 'jwt'
    ///
    /// ⚠️ C# 5 约束（构建 VM 只有 .NET Framework 4.0 的 csc）：不用 async/await，
    ///    一律用 <see cref="HttpWebRequest"/> 同步调用。本类是给后台线程用的，
    ///    阻塞不影响界面（超时 15 秒，与 Node 的 AbortSignal.timeout(15000) 对齐）。
    ///
    /// ⚠️ 除 token 校验直接返回中文原因外，其余失败原因一律写进 out error
    ///    （不抛异常给调用方）；success 时 error 恒为空串。
    /// </summary>
    public static class BambuCloud
    {
        // ---------------- 区域表（对齐 cloud.mjs 的 REGIONS） ----------------

        /// <summary>一个区域的云端地址（对齐 Node 的 <c>{ api, mqtt }</c>）</summary>
        private class Region
        {
            public string Api;
            public string Mqtt;
        }

        private static readonly Dictionary<string, Region> Regions = BuildRegions();

        private static Dictionary<string, Region> BuildRegions()
        {
            Dictionary<string, Region> d = new Dictionary<string, Region>();
            Region cn = new Region();
            cn.Api = "https://api.bambulab.cn";
            cn.Mqtt = "cn.mqtt.bambulab.com";
            d["cn"] = cn;
            Region gl = new Region();
            gl.Api = "https://api.bambulab.com";
            gl.Mqtt = "us.mqtt.bambulab.com";
            d["global"] = gl;
            return d;
        }

        /// <summary>区域 → API 主机（对齐 <c>REGIONS[r].api</c>）。region 大小写不敏感。</summary>
        public static string ApiBase(string region)
        {
            Region r = Lookup(region);
            return (r == null) ? null : r.Api;
        }

        /// <summary>区域 → MQTT 主机（对齐 <c>REGIONS[r].mqtt</c>）。region 大小写不敏感。</summary>
        public static string MqttHost(string region)
        {
            Region r = Lookup(region);
            return (r == null) ? null : r.Mqtt;
        }

        /// <summary>查表；未知区域返回 null（Node 版这里会抛 TypeError，C# 里改成返回 null）</summary>
        private static Region Lookup(string region)
        {
            if (region == null) return null;
            string key = region.Trim().ToLowerInvariant();
            Region r;
            return Regions.TryGetValue(key, out r) ? r : null;
        }

        // ---------------- 汇总请求头（对齐 BBL_HEADERS） ----------------

        private const string UserAgent = "bambu_network_agent/01.09.05.01";
        private const string AcceptJson = "application/json";
        private const string ContentTypeJson = "application/json";

        /// <summary>
        /// 把 BBL_HEADERS 装进一个新建的请求。
        /// ★ 为什么不放进静态字典后遍历：.NET Framework 4.0 的 <c>WebHeaderCollection</c>
        ///   对 User-Agent / Accept / Content-Type 有专门属性，塞进集合会被拦或被改写；
        ///   而且静态集合被多线程共享不划算。这里逐个 Set 更可控。
        ///   Authorization 最后设，保证 token 是最终值（对齐 Node 里展开顺序：BBL_HEADERS 之后覆盖）。
        /// </summary>
        private static HttpWebRequest NewRequest(string url, string token, string cookie)
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "GET";
            req.Timeout = TimeoutMs;
            req.ReadWriteTimeout = TimeoutMs;
            // ★ 不关证书校验（对齐 Node fetch 的默认行为）；也不要走系统代理：
            //   本工程的 VmProbe.cs 也是 req.Proxy = null，保持一致。
            req.Proxy = null;
            req.UserAgent = UserAgent;
            req.Accept = AcceptJson;
            req.ContentType = ContentTypeJson;
            req.Headers["X-BBL-Client-Name"] = "bambu-monitor";
            req.Headers["X-BBL-Client-Type"] = "slicer";
            req.Headers["X-BBL-Client-Version"] = "01.09.05.51";
            req.Headers["X-BBL-Language"] = "zh-CN";
            req.Headers["X-BBL-OS-Type"] = "linux";
            req.Headers["X-BBL-OS-Version"] = "6.2.0";
            req.Headers["X-BBL-Agent-Version"] = "01.09.05.01";
            // 让服务端可以直接回 gzip/deflate（Node 的 fetch 默认就会带 accept-encoding 并自动解压；
            // HttpWebRequest 不带这个头，服务端通常回明文，所以不加也能工作 —— 加上更稳）
            try { req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate; }
            catch (Exception) { }
            req.Headers["Authorization"] = "Bearer " + token;
            if (!string.IsNullOrEmpty(cookie)) req.Headers["Cookie"] = cookie;
            return req;
        }

        /// <summary>
        /// 请求结果（对齐 Node 的 <c>{ status, json, text }</c>）。
        /// status &lt;= 0 表示"根本没拿到 HTTP 响应"（DNS/连接/超时/TLS 失败），error 里是原因。
        /// </summary>
        private class ApiResult
        {
            public int Status;
            public JsonValue Json;
            public string Text = "";
            public string Error = "";
        }

        /// <summary>
        /// 同步 GET（对齐 <c>apiFetch()</c>）。
        /// ★ 关键点：HttpWebRequest 对 401/403 等非 2xx 会**抛 WebException**（Node fetch 不会），
        ///   必须在 catch 里从 <c>ex.Response</c> 把真实状态码和响应体捞回来 ——
        ///   否则 401 会退化成"网络错误"，日志里的"cn 区返回 401"就没了。
        /// </summary>
        private static ApiResult Fetch(string baseUrl, string path, string token, string cookie)
        {
            EnsureTls();
            ApiResult ar = new ApiResult();
            string url = baseUrl + path;
            try
            {
                HttpWebRequest req = NewRequest(url, token, cookie);
                try
                {
                    using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                    {
                        ar.Status = (int)resp.StatusCode;
                        ar.Text = ReadBody(resp);
                    }
                }
                catch (WebException wex)
                {
                    if (wex.Response != null)
                    {
                        using (HttpWebResponse resp = (HttpWebResponse)wex.Response)
                        {
                            ar.Status = (int)resp.StatusCode;
                            ar.Text = ReadBody(resp);
                        }
                    }
                    else
                    {
                        // 连响应都没有：超时 / DNS / 连接被拒 / TLS 握手失败
                        ar.Status = 0;
                        ar.Text = "";
                        ar.Error = wex.Message;
                    }
                }
            }
            catch (Exception ex)
            {
                ar.Status = 0;
                ar.Text = "";
                ar.Error = ex.Message;
            }
            // 解析失败容忍：Node 是 `try { JSON.parse } catch {}`，拿到 null 继续走
            if (!string.IsNullOrEmpty(ar.Text)) ar.Json = JsonValue.Parse(ar.Text);
            return ar;
        }

        /// <summary>响应体按 UTF-8 读成字符串（IgnoreCase 无关，这里只要"读全"）</summary>
        private static string ReadBody(HttpWebResponse resp)
        {
            if (resp == null) return "";
            try
            {
                using (Stream s = resp.GetResponseStream())
                {
                    if (s == null) return "";
                    using (StreamReader sr = new StreamReader(s, new UTF8Encoding(false)))
                    {
                        return sr.ReadToEnd();
                    }
                }
            }
            catch (Exception)
            {
                // 出错响应体读不到很正常（比如 204/被服务端提前断开），当作空体
                return "";
            }
        }

        // ---------------- 公用的 JSON 取值（全部做 null / 类型防御） ----------------

        /// <summary>取字符串字段：非字符串、缺失、null 一律给 fallback。
        /// Node 原实现用 <c>d.dev_name || ''</c>，但 JSON 里可能是数字/布尔，
        /// 所以这里只认字符串，其余走 fallback（比 ToString() 更贴近原语义）。</summary>
        private static string Str(JsonValue o, string key, string fallback)
        {
            if (o == null) return fallback;
            JsonValue v = o.Get(key);
            if (v == null) return fallback;
            if (v.IsStr) return (v.S == null) ? fallback : v.S;
            return fallback;
        }

        // ---------------- token 有效性 / JWT ----------------

        /// <summary>token 有效门槛：trim 后长度 &gt;= 20（对齐 Node：<c>token.trim().length &lt; 20</c> → 抛错）</summary>
        private static bool TokenLooksValid(string token)
        {
            if (token == null) return false;
            return token.Trim().Length >= 20;
        }

        /// <summary>
        /// 解码 JWT payload 并取一个字段（对齐 util.mjs 的 decodeJwtPayload + cloud.mjs 的三段兜底）。
        /// field 依次试 username → uid → userId（Node 是 <c>payload?.username || payload?.uid || payload?.userId</c>）。
        /// 解不出来 / 字段缺失 / payload 不是对象 / 解析失败 → 返回 null。
        /// </summary>
        public static string JwtField(string token, string field)
        {
            if (token == null || field == null) return null;
            string[] parts = token.Split('.');
            if (parts.Length != 3) return null;                 // 不是 JWT
            try
            {
                // base64url → base64（对齐 replace(/-/g,'+').replace(/_/g,'/')）
                string b64 = parts[1].Replace('-', '+').Replace('_', '/');
                int rem = b64.Length % 4;
                if (rem != 0)
                {
                    StringBuilder pad = new StringBuilder();
                    int need = 4 - rem;
                    for (int i = 0; i < need; i++) pad.Append('=');
                    b64 = b64 + pad.ToString();                 // 对齐 '='.repeat(4 - len % 4)
                }
                byte[] raw = Convert.FromBase64String(StripBom(b64).Trim());
                string json = new UTF8Encoding(false).GetString(raw);
                JsonValue obj = JsonValue.Parse(json);
                if (obj == null || !obj.IsObj) return null;     // payload 不是对象就当解不出来
                JsonValue v = obj.Get(field);
                if (v == null) return null;
                // 只认字符串（Node 里 username/uid 可能是数字，这里不强转 —— 主控需要数字 uid
                // 时会走 getUid() 的 preference 接口，那条路是明确的）
                if (v.IsStr) return v.S;
                return null;
            }
            catch (Exception)
            {
                // 对齐 Node：整个 try 包住，任何异常（坏 base64 / 坏 UTF-8 / 坏 JSON）→ null
                return null;
            }
        }

        /// <summary>
        /// 一次调用取三个候选字段（对齐 <c>payload?.username || payload?.uid || payload?.userId</c>）。
        /// ★ 为什么不复用 JwtField：三字段要的是**同一个 payload 只解一次**，
        ///   否则要 base64 解码三遍（token 很长，而且这里是每次发现的必经路径）。
        /// </summary>
        private static string JwtUserName(string token)
        {
            if (token == null) return null;
            string[] parts = token.Split('.');
            if (parts.Length != 3) return null;
            try
            {
                string b64 = parts[1].Replace('-', '+').Replace('_', '/');
                int rem = b64.Length % 4;
                if (rem != 0)
                {
                    StringBuilder pad = new StringBuilder();
                    int need = 4 - rem;
                    for (int i = 0; i < need; i++) pad.Append('=');
                    b64 = b64 + pad.ToString();
                }
                byte[] raw = Convert.FromBase64String(StripBom(b64).Trim());
                JsonValue obj = JsonValue.Parse(new UTF8Encoding(false).GetString(raw));
                if (obj == null || !obj.IsObj) return null;
                string v = Str(obj, "username", null);
                if (!string.IsNullOrEmpty(v)) return v;
                v = Str(obj, "uid", null);
                if (!string.IsNullOrEmpty(v)) return v;
                v = Str(obj, "userId", null);
                if (!string.IsNullOrEmpty(v)) return v;
                return null;
            }
            catch (Exception) { return null; }
        }

        /// <summary>
        /// 去掉 JWT 段里可能夹带的 UTF-8 BOM 字符。
        /// ★ 为什么需要：Convert.FromBase64String 会忽略空白但**不认 BOM 字符**，
        ///   带 BOM 就抛 FormatException。Node 的 Buffer.from(b64,'base64') 是宽松的，
        ///   为了语义等价这里先削掉 BOM（正常 token 不会有，属于防御）。
        /// </summary>
        private static string StripBom(string s)
        {
            if (s == null) return "";
            if (s.Length > 0 && s[0] == '\uFEFF') return s.Substring(1);
            return s;
        }

        // ---------------- 数字 uid（对齐 getUid） ----------------

        /// <summary>
        /// 取账号数字 uid（MQTT 用户名 = <c>u_{uid}</c>）。
        /// ★ 为什么必须有这个接口：新版 access token 的 payload 里**已经没有 username**
        ///   （Node 注释原话），所以只能问 preference 接口要数字 uid。
        /// 失败返回 null（Node 返回 <c>{ uid: null, source: null }</c>）。
        /// </summary>
        private static string GetUid(string baseUrl, string token, string cookie)
        {
            ApiResult r = Fetch(baseUrl, "/v1/design-user-service/my/preference", token.Trim(), cookie);
            if (r.Status != 200 || r.Json == null || !r.Json.IsObj) return null;
            JsonValue u = r.Json.Get("uid");
            if (u == null || u.IsNull) return null;             // 对齐 json.uid != null
            // Node 是 String(json.uid)：数字 123456 要变成 "123456" 而不是 "123456.0"
            if (u.IsNum)
            {
                double d = u.N;
                if (Math.Abs(d - Math.Floor(d)) < 1e-9) return ((long)d).ToString(System.Globalization.CultureInfo.InvariantCulture);
                return d.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
            if (u.IsStr) return u.S;
            return null;
        }

        // ---------------- 设备条目 / 发现结果 ----------------

        /// <summary>
        /// 发现设备。失败返回 null 并把原因（中文）写进 error；成功时 error 为空串。
        /// region 可为 "auto" / "cn" / "global"（大小写不敏感），其余值报错返回 null。
        /// wantSerial / wantName 用于筛选（可为 null/空）：命中才收窄，没命中就保留全量
        /// （对齐 Node：<c>if (hit.length &gt; 0) devices = hit;</c>）。
        /// </summary>
        public static BambuDiscovery Discover(string token, string region, string cookie,
                                             string wantSerial, string wantName, out string error)
        {
            error = "";
            try
            {
                BambuDiscovery d = DiscoverInternal(token, region, cookie, wantSerial, wantName, out error);
                return d;
            }
            catch (Exception ex)
            {
                // 这一层只为"绝不把异常抛给调用方"（Discover 的契约是 null + error）
                error = "发现设备时出错：" + ex.Message;
                Log.Err("BambuCloud.Discover 异常：{0}（token {1}）", ex.Message, Mask(token));
                return null;
            }
        }

        private static BambuDiscovery DiscoverInternal(string token, string region, string cookie,
                                                      string wantSerial, string wantName, out string error)
        {
            error = "";
            // ★ token 校验（对齐 Node 的 throw）：注意判据是"trim 后长度 < 20"
            if (!TokenLooksValid(token))
            {
                error = "token 无效：请粘贴从浏览器获取的完整 access token（长度不足 20）";
                Log.Err("BambuCloud：token 无效（长度不足），已拒绝（token {0}）", Mask(token));
                return null;
            }

            string useRegion = (region == null) ? "auto" : region.Trim().ToLowerInvariant();

            // 候选区域（对齐 Node：region === 'auto' ? ['cn','global'] : [region]）
            List<string> candidates = new List<string>();
            if (useRegion == "auto")
            {
                candidates.Add("cn");
                candidates.Add("global");
            }
            else
            {
                if (Lookup(useRegion) == null)
                {
                    error = "未知区域：" + useRegion + "（只能是 auto / cn / global）";
                    Log.Err("BambuCloud：{0}", error);
                    return null;
                }
                candidates.Add(useRegion);
            }

            string jwtUser = JwtUserName(token);
            string lastErr = null;

            for (int i = 0; i < candidates.Count; i++)
            {
                string r = candidates[i];
                string baseUrl = Lookup(r).Api;
                Log.W("BambuCloud：尝试 {0} 区（{1}）", r, baseUrl);
                try
                {
                    ApiResult res = Fetch(baseUrl, "/v1/iot-service/api/user/bind", token.Trim(), cookie);
                    if (res.Status == 200 && res.Json != null && res.Json.IsObj && res.Json.Get("devices") != null)
                    {
                        JsonValue jd = res.Json.Get("devices");
                        // Node: Array.isArray(json.devices) ? json.devices : [] —— 非数组就是空表
                        JsonValue arr = jd.IsArr ? jd : null;

                        List<BambuDevice> devices = BuildDevices(arr, wantSerial, wantName);

                        // 数字 uid：JWT 里通常已没有 username，所以优先用 preference（对齐 Node）
                        string username = jwtUser;
                        string uidSource = "jwt";
                        try
                        {
                            string uid = GetUid(baseUrl, token, cookie);
                            if (!string.IsNullOrEmpty(uid))
                            {
                                username = "u_" + uid;
                                uidSource = "preference";
                            }
                        }
                        catch (Exception ex)
                        {
                            // 对齐 Node 里那个空 catch：uid 取不到不影响设备发现，继续用 JWT 用户名
                            Log.W("BambuCloud：取数字 uid 失败（继续用 JWT 用户名）—— {0}", ex.Message);
                        }

                        BambuDiscovery outD = new BambuDiscovery();
                        outD.Region = r;
                        outD.ApiBase = baseUrl;
                        outD.Devices = devices;
                        outD.Username = (username == null) ? "" : username;
                        outD.UidSource = uidSource;
                        Log.W("BambuCloud：{0} 区发现 {1} 台设备，用户名 {2}（来源 {3}）",
                              r, devices.Count, outD.Username, uidSource);
                        error = "";
                        return outD;
                    }

                    // 有响应但不是我们想要的（最常见 401/403）→ 记一句中文原因
                    lastErr = r + " 区返回 " + res.Status;
                    if (res.Status <= 0 && !string.IsNullOrEmpty(res.Error)) lastErr = r + " 区请求失败：" + res.Error;
                    Log.W("BambuCloud：{0} 区未通过 —— {1}", r, lastErr);
                    // 对齐 Node：显式指定区域时不再试下一个（多试无意义，还会白等一次超时）
                    if (useRegion != "auto") break;
                }
                catch (Exception ex)
                {
                    lastErr = ex.Message;
                    Log.Err("BambuCloud：{0} 区请求异常 —— {1}", r, ex.Message);
                }
            }

            // 对齐 Node：throw lastErr || new Error('无法验证 token')
            error = string.IsNullOrEmpty(lastErr) ? "无法验证 token" : lastErr;
            Log.Err("BambuCloud：发现失败 —— {0}（token {1}）", error, Mask(token));
            return null;
        }

        /// <summary>
        /// 把 devices 数组转成条目列表（全部做 null / 类型防御）。
        /// 型号三级兜底：dev_product_name → dev_model_name → "未知型号"。
        /// 筛选对齐 Node：命中才收窄；wantSerial 优先于 wantName。
        /// </summary>
        private static List<BambuDevice> BuildDevices(JsonValue arr, string wantSerial, string wantName)
        {
            List<BambuDevice> list = new List<BambuDevice>();
            if (arr != null)
            {
                for (int i = 0; i < arr.Count; i++)
                {
                    JsonValue dv = arr.At(i);
                    if (dv == null || !dv.IsObj) continue;      // 防御：数组里混进非对象
                    BambuDevice d = new BambuDevice();
                    d.DevId = Str(dv, "dev_id", "");
                    d.DevName = Str(dv, "dev_name", "");
                    string product = Str(dv, "dev_product_name", null);
                    if (string.IsNullOrEmpty(product)) product = Str(dv, "dev_model_name", null);
                    if (string.IsNullOrEmpty(product)) product = "未知型号";
                    d.ProductName = product;
                    JsonValue on = dv.Get("online");
                    d.Online = (on != null && on.IsBool && on.B);   // 严格 == true
                    d.PrintStatus = Str(dv, "print_status", "");
                    list.Add(d);
                }
            }

            // 筛选（对齐 Node：d.dev_id === wantSerial / String(d.dev_name || '') === wantName）
            bool hasSerial = !string.IsNullOrEmpty(wantSerial);
            bool hasName = !string.IsNullOrEmpty(wantName);
            if (hasSerial || hasName)
            {
                List<BambuDevice> hit = new List<BambuDevice>();
                for (int i = 0; i < list.Count; i++)
                {
                    BambuDevice d = list[i];
                    if (hasSerial)
                    {
                        if (d.DevId == wantSerial) hit.Add(d);
                    }
                    else
                    {
                        string n = (d.DevName == null) ? "" : d.DevName;
                        if (n == wantName) hit.Add(d);
                    }
                }
                if (hit.Count > 0) list = hit;
            }
            return list;
        }

        // ---------------- 脱敏 ----------------

        /// <summary>
        /// 脱敏（对齐 auth.mjs 的 mask）：长度 &lt;= 14 → 非空就 "***"；否则
        /// 前 6 + '…' + 后 4 + （长度 N）。空/null → 空串。
        /// ★ 日志里凡涉及 token 一律走这里，绝不打印完整 token。
        /// </summary>
        public static string Mask(string s)
        {
            string v = (s == null) ? "" : s;
            if (v.Length <= 14) return (v.Length == 0) ? "" : "***";
            return v.Substring(0, 6) + "…" + v.Substring(v.Length - 4)
                 + "（长度 " + v.Length + "）";
        }

        // ---------------- TLS / 超时 ----------------

        /// <summary>与 Node 的 AbortSignal.timeout(15000) 对齐</summary>
        private const int TimeoutMs = 15000;

        private static bool _tlsReady;

        /// <summary>
        /// 进程内只做一次：打开 TLS 1.2。
        /// ⚠️ 不关证书校验（对齐 Node fetch 默认行为）。
        /// ⚠️ 用 try/catch 且逐位或，不整体赋值 —— 某些环境的 SecurityProtocolType
        ///    没有 Tls12 成员（会抛 ArgumentException），也有的默认已含 Ssl3/Tls
        ///    （整体赋值会把它们清掉，导致连不上老服务器）。
        /// </summary>
        private static void EnsureTls()
        {
            if (_tlsReady) return;
            _tlsReady = true;                 // 事件顺序无所谓：失败就失败，不影响后续请求
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            }
            catch (Exception) { }
        }
    }


    /// <summary>一台已绑定的打印机（对齐 Node devices 数组里用到的字段）</summary>
    public class BambuDevice
    {
        public string DevId = "";
        public string DevName = "";
        /// <summary>dev_product_name，缺失时取 dev_model_name，再缺失为 "未知型号"</summary>
        public string ProductName = "";
        /// <summary>严格 == true（对齐 Node <c>d.online === true</c>；字符串 "true" 也算离线）</summary>
        public bool Online;
        public string PrintStatus = "";
    }

    /// <summary>发现结果（一份就够用：区域、设备、MQTT 用户名及其来源）</summary>
    public class BambuDiscovery
    {
        public string Region = "";
        public string ApiBase = "";
        public List<BambuDevice> Devices = new List<BambuDevice>();
        /// <summary>MQTT 用户名，形如 "u_123456"（preference 成功时）或 JWT 里的原值</summary>
        public string Username = "";
        /// <summary>"jwt" 或 "preference"</summary>
        public string UidSource = "";
    }
}
