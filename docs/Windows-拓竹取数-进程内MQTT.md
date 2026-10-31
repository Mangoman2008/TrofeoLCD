# Windows 版拓竹取数：进程内直连云端 MQTT

> 2026-10-15 完成。把原先依赖 Node 服务（`bambu-monitor`）的打印机取数，
> 以 C# 5 重写进 `dshlcd` 程序自身 —— 程序直接连拓竹云 MQTT，不再需要任何外部进程。

## 为什么必须"有个东西"去取数

打印机状态**不是本地可读的**，而是上报到拓竹云：

```
拓竹打印机 (P2S, 局域网)
   ↕  ← 没有可用的局域网直连协议（bambu-monitor 里也没实现）
拓竹云 MQTT: cn.mqtt.bambulab.com:8883 (TLS)
   ↕  ← 认证 = access token（username = u_<uid>）
持有长连接 + 解析上报的那个进程
```

所以无论如何都必须**有个进程持有这条 TLS 长连接**。本次改造把它从
"外面那个 Node 服务" 变成了 "dshlcd 自己"。

## 架构

```
拓竹云 MQTT ──TLS──> MqttClient ──> BambuState ──> PrinterInfo
                                          │              │
                    BambuCloud(发现/uid)   │              ↓
                    BambuConfig(凭据)      │        LcdRunner 覆写
                                          │        Telemetry.Printer
                                          ↓              │
                                     事件回调      显示层（Dotii/Dashboard）
```

| 文件 | 职责 |
|---|---|
| `MqttClient.cs` | 手写 MQTT 3.1.1：TLS、报文构造/解析、粘包拆包、心跳、订阅/发布 |
| `BambuCloud.cs` | 云端 REST：`/iot-service/api/user/bind` 发现设备、`/design-user-service/my/preference` 取 uid |
| `BambuState.cs` | 状态机：原始报文 → **压平成桥格式 JSON** → 交给 `State.NormalizePrinter` |
| `BambuPrinter.cs` | 编排：发现 → 连 broker → 订阅 → 定时 pushall → 离线判定 → 指数退避重连 |
| `BambuConfig.cs` | 凭据加载（token / cookie 双源）、脱敏、路径解析 |

### 关键设计：压平后复用已有的归一化

`BambuState` **不自己拼 `PrinterInfo`**，而是先产出与 `dsh-bridge.mjs` 的
`mapBambuState()` **同构**的 JSON，再喂给已有的 `State.NormalizePrinter`：

```csharp
flat = BuildFlatJson();              // 与桥同构
return State.NormalizePrinter(flat); // ← 钳制/白名单/字段名只有一份实现
```

好处：**显示层与 16 个主题一行未改**，而且两条取数路径（桥 / 本机 MQTT）
的钳制规则不可能漂移。

## 配置

默认路径（**按顺序找**）：

1. `--bambu-config <路径>` 指定的文件
2. exe 同目录的 `bambu.json`（若存在）
3. `%ProgramData%\dshlcd\bambu.json` ← **默认**

> 为什么不默认放 exe 旁：本工程的 exe 目录在 VM 共享盘上（`C:\dshlcd`），
> 把 access token 明文放那儿风险太大。

文件格式：

```json
{
  "region": "cn",
  "token": "AQDRjw…",
  "cookie": "",
  "serial": "22E8BJ5C1101135",
  "deviceName": "",
  "offlineTimeoutMs": 90000,
  "pushallIntervalMs": 30000,
  "insecure": false
}
```

| 字段 | 说明 |
|---|---|
| `region` | `auto` / `cn` / `global`；`auto` 会依次试 cn、global |
| `token` | 浏览器 access token（与 `cookie` 二选一，**cookie 优先**） |
| `cookie` | 拓竹网页 Cookie 整段（里面含 `token=`） |
| `serial` | 打印机 SN；留空则自动发现并**写回配置** |
| `pushallIntervalMs` | 定期逼打印机上报全量的间隔（默认 30 秒） |
| `offlineTimeoutMs` | 多久没上报判离线（默认 90 秒） |
| `insecure` | 跳过 TLS 证书校验（仅自签代理排障用） |

**令牌会过期**：拓竹的 token 是长期串（不是 JWT，解不出 `exp`）。
过期后 `bambuMode` 变 `error`、`bambuError` 给出原因，需要重新粘贴。

## 命令行

| 参数 | 作用 |
|---|---|
| `--no-bambu` | 关掉拓竹取数（默认开；没配凭据时自动跳过） |
| `--bambu-config <文件>` | 指定凭据 JSON |
| `--mqtt-debug` | 打印 MQTT 包级追踪（排查连接/订阅问题） |

## 自检：不用启整个程序就能验证取数链路

```cmd
cd /d C:\dshlcd
build-bambu-test.cmd                 # 默认观察 12 秒
build-bambu-test.cmd --seconds 60    # 跑久一点，看保活/持续推送
```

它只编 9 个文件（**不需要 USB、不开界面、不推屏**），然后真的连 broker 并
把归一化后的 `PrinterInfo` 逐字段打出来。

> ⚠️ **文件列表由 `tools/csharp_closure.py` 算出，不要手工维护** ——
> 手工列表漏过 `State.cs`（报 CS0246 "PrinterInfo"）和 `BambuPrinter.cs`。
>
> ```bash
> python3 tools/csharp_closure.py win/src/MqttClient.cs win/src/BambuCloud.cs \
>   win/src/BambuState.cs win/src/BambuConfig.cs win/src/BambuPrinter.cs \
>   win/tools/bambu-selftest.cs
> ```

## `/diag` 暴露的字段

| 字段 | 含义 |
|---|---|
| `bambuMode` | `not-configured` / `discovering` / `running` / `error` |
| `bambuError` | 出错原因（凭据问题会在这里说明） |
| `bambuMqtt` | MQTT 是否已连上云端 |
| `bambuOnline` | 打印机是否在线（收到过上报且未超时） |
| `bambuState` | `IDLE`/`PREPARE`/`RUNNING`/`PAUSE`/`FINISH`/`FAILED`/`STUCK`/`OFFLINE` |
| `bambuRegion` / `bambuDevice` / `bambuModel` | 区域 / SN / 机型 |
| `bambuReports` | 累计收到多少条报文（0 = 订阅或网络有问题） |
| `bambuReportAgeSec` | 距上次上报多少秒（-1 = 从未收到） |
| `bambuConfig` | 实际读到的凭据文件路径 |

**排障顺序**：先看 `bambuMode` → 再看 `bambuReports` → 最后 `bambuReportAgeSec`。

## 踩过的坑（都是实测出来的，改代码前请先读）

### 1. 订阅自锁（会永久卡在"已连接"）

`Connected` 事件是在 **MQTT 接收线程**上触发的（`HandlePacket` 的 CONNACK 分支），
而在事件回调里调 `Subscribe` 要阻塞等 SUBACK —— **SUBACK 只能由同一个接收线程读出来**。

⇒ `Subscribe` 必须放到**独立线程**；`MqttClient.Subscribe` 现在还加了防线：
若检测到在接收线程上调用会**直接拒绝并报错**。

### 2. 重连永不触发（静默失效，最难发现）

等待循环原来只看 `IsClosedByUs()`（本方主动关）。broker 主动断开时它恒为 `false`
→ 循环永不退出 → **永远不重连**（程序看着在跑，数据永不更新）。

⇒ 用 `IsDead`（本方关闭 **或** 接收线程已退出）。

### 3. 读缓冲装不下一个包 → 无限循环

原来读缓冲固定 **8192** 字节，而真实 PUBLISH（body 就是整个 `print` 对象）
实测 **7421 字节**（占 91%）。一旦单包超过缓冲，compact 后可用空间仍装不下
→ `while` 永远凑不齐一个包。

⇒ 缓冲改为**自动扩容**（64KB 起，装满且含完整包时翻倍）+ 只移动未消费的残余。

### 4. 嵌套类型被跨类裸用（CS0246）

`BambuDevice` / `BambuDiscovery` 原来嵌套在 `BambuCloud` 里，而 `BambuPrinter.cs`
用了无条件名 → `build.log` 报 CS0246。**自检程序当时用的是带前缀的写法，所以能编过**
—— 这就是"自检绿、主程序挂"的来源。

⇒ 两个类已移到**命名空间级**（和工程其它类型一致）。

### 5. `ams.tray_now` 的哨兵值

拓竹用 **255**（原始报文里是字符串 `"255"`）表示"未选料盘"。
`NormalizePrinter` 的 `ClampInt` 是**钳到边界**，255 会变成 **99**（一个看上去合法但错误的料盘号）。

⇒ 在压平层按设备语义先判掉（`<0` 或 `>99` 视为未选）→ 不写该键 → 默认 `-1`。

### 6. `chamber_temper` 是 `null` 而非缺失

P2S 没有腔温传感器，字段值是 `null`。`NumOrNull` 对 null 返回 null → 不写该键
→ `NormalizePrinter` 用默认 `-1`。**这条链路是对的**，别"修"成写 0。

### 7. `dev_name` 可能为空

这台 P2S 的 `dev_name` 是空的，直接用 `DeviceName` 拼 `model` 会得到
`"0.4mm HS01"`（看不出是哪台机）。桥用的是 `dev.name || dev_id`。

⇒ `DeviceName` 为空时退回 `DeviceId`。

### 8. TLS 版本

- broker 与 API **都接受 TLS 1.2**（实测），也接受 1.3
- **TLS 1.1 / 1.0 被拒绝**
- .NET Framework 4.x 的 `SslProtocols.Tls12` 可用（VM 的 `System.dll` 含 `Tls12`/`Tls13` 符号）

⇒ 代码里用 `SslProtocols.Tls12` + `ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12`。

## 如何验证"不依赖 Node"

1. 停掉本机（鸿蒙）的 Node 服务：
   ```bash
   bash ~/WorkBuddy/拓竹PS2/bambu-monitor/stop.sh
   kill $(cat ~/WorkBuddy/TrofeoLCD/bridge/.bridge-to-vm.pid)
   ```
2. 等 1~2 分钟，在 VM 上：
   ```cmd
   curl http://127.0.0.1:54546/diag
   ```
3. 判据：
   - `bambuMode` / `bambuMqtt` / `bambuOnline` 仍正常，`bambuReports` 继续增长 → **打印机取数已独立**
   - `telemetryPackets` 冻住不动 → 证明桥确实停了（DSH 的会话数据不再更新，那是桥的职责）

**注意**：停桥后 DSH 的 agent/token/事件数据会停止更新，但打印机数据应照常。

## 相关工具

| 工具 | 用途 |
|---|---|
| `tools/csharp_closure.py` | **算编译闭包**（避免手工列表漏文件） |
| `tools/csharp_audit.py` | 结构审计：C#5 违规、括号、重复定义 |
| `tools/csharp_types.py` | DateTime/long/int 混淆 |
| `tools/csharp_calls.py` | 自定义方法实参个数 |
| `tools/cmd_check.py` | `.cmd` 编码（ASCII + CRLF） |
| `tools/sync_to_vm.sh` | 同步源码到 VM（带 md5 校验） |
| `tools/bridge_to_vm.sh` | 本机桥直推 VM（带打印机服务自动探测） |
