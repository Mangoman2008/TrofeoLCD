# HANDOFF — 利民 9.16" LCD 鸿蒙副屏（TrofeoLCD）

> 一页纸交接：现在到哪了、什么已被验证、还差哪一步、怎么继续。
> 详细内容见 `README.md`（739 行，17 节）；本文件只讲"接手时最需要知道的"。

## 一、目标设备就是本机

```
$ param get const.product.name       → HUAWEI MatePad Edge
$ param get const.product.model      → QXS-W10     (deviceType=tablet, API 26)
```

**运行 DSH 的这台机器本身就是 HUAWEI MatePad Edge**，屏要插的就是本机 USB-C 口，
不需要别的电脑。但：

- 本沙箱 `bm` / `aa` 被拒（`bm dump -a` → `failed to execute your command`），**无法自行安装**
- 本沙箱 `hilog` 读不出任何输出（无权限），**看不到应用日志**
- 本机 hdcd 走 unix socket，外部不可达；hdc 自连需要**开启「无线调试」**

## 二、已完成

| 部分 | 内容 | 规模 |
|---|---|---|
| 鸿蒙应用 | LY 协议驱动 + 1920×480 仪表盘 + USB 推帧 + 远程预览/诊断 | 17 个 .ets / 3632 行 |
| 数据桥 | DSH 会话 → UDP 遥测（尾部 zstd 解压、系统指标、可选天气/歌词） | `bridge/dsh-bridge.mjs` |
| 工具链 | 构建 / 签名（3 种）/ 安装 / 自检 / 布局审计 / 诊断 / 看板 | 21 个脚本 / 2598 行 |

## 三、已被验证的（可复现）

```bash
bash tools/run_selftest.sh     # 协议/校准/归一化/调度    → 38/38 通过
bash tools/run_hw_test.sh      # USB 层（真实源码+仿真设备）→ 20/20 通过
python3 tools/layout_check.py  # 布局审计                → 0 问题
python3 tools/layout_check.py --stress   # 6 类极端/真实输入 → 全部干净
bash tools/cli_build.sh        # 命令行构建（副本内，不污染工程）→ BUILD SUCCESSFUL
```

- **协议已与参考实现逐字核对**（trcc 的 `ly_lcd.py` / `core/protocol.py`）：
  握手 2048B `[0]=02 [1]=FF [8]=01`、`PM=64+resp[20]`、`SUB=resp[22]+1`、
  512B 分块（16B 头 + 496B 数据）、4 的倍数补齐、4096B 写入、512B ACK
- **USB 链路离线跑通**：真实的 `LcdUsb.ets` + 假 `usbManager` + 仿真 LY 设备，
  600KB JPEG 推出去再解析回来**逐字节一致**
- **真机期望值已确定**：`PM=65 SUB=5 FBL=192 1920x480 rot=180°`（来自 trcc 的实测 issue 记录）
- 仪表盘布局经镜像渲染 + 包围盒审计（抓到并修掉过 3 类真实溢出 + 1 处元素重叠）

## 四、唯一卡点（需要你操作）

**DevEco 里点一次自动签名**：文件 → 项目结构 → 签名配置 → 勾选「自动生成签名」

- 需要登录华为账号；**签名时最好已连上本机设备**（否则设备 UDID 不进 profile，签出来装不上）
- 工程侧已就绪：`bash tools/signing_readiness.sh` → **0 项待处理**
- 这个对话框与运行配置无关，所以之前那个「模块未定义」不会挡住它

签完 `build-profile.json5` 会出现 `signingConfigs`，之后：

```bash
bash tools/cli_build.sh                          # 自动出签名包 + verify-app 校验
bash tools/install_local.sh --port <无线调试端口>  # 安装 → 启动（脚本带端口扫描）
bash tools/fetch_diag.sh probe                   # 取回完整证据（无需复制日志）
```

无线调试位置：**设置 → 系统 → 开发者选项 → 无线调试**（打开后界面显示 IP:端口）。

## 五、验收标准（装上之后看这几行）

| 界面行 / 接口 | 期望 |
|---|---|
| `协议自检` | `自检 38/38 通过` |
| `USB 屏幕` | `Trofeo Vision ... (416:5408)` |
| `设备信息` | `PM=65 SUB=5 FBL=192 1920x480 rot=180°` |
| `端点` | `iface0/class255 OUT=0x9 IN=0x81` |
| `屏 ACK` | 出现应答字节与耗时（如 `512B/12ms [...]`） |
| 屏幕画面 | 三面板仪表盘；上下颠倒则关「旋转180°」 |
| `http://127.0.0.1:54546/diag` | 上面这些的 JSON 版（我可远程读取） |

**仍然只能靠真机验证的**：真实 USB 驱动与 `usbManager` 服务端的行为
（华为论坛里 `bulkTransfer` 的已知坑）。这是唯一没被离线覆盖的部分，不夸大。

## 六、几个容易踩的坑（已解决，别重犯）

1. **不要在源目录直接跑 hvigorw** —— 会把本机 SDK 路径写进
   `.hvigor/cache/project-config.json`。一律用 `tools/cli_build.sh`（副本内构建）。
2. **`.hvigor` 里的 7.26.8 指纹不等于"污染"** —— 本机 DevEco 也用设备自带的
   hmos-clt 工具链，版本号相同。别乱删它的缓存（删了只会让它重新 Sync）。
3. **本沙箱读不到 hilog** —— 排障靠 `/diag`、`/probe`、`/frame.jpg` 与 `tools/fetch_diag.sh`。
4. **Node 内置 zstd 解压只解第一帧** —— DSH 的 `session.jsonl.zstd` 由数千个独立帧拼成，
   必须用 `zstd -dc` CLI 流式解码（桥里已这么做）。
5. **纯类型导入必须写 `import type`** —— 否则 Node 的类型剥离会当值导入而报错
   （已被 `run_hw_test.sh` / `run_selftest.sh` 抓到过两次）。

## 七、恢复工作的最短路径

```bash
cd ~/WorkBuddy/TrofeoLCD
bash tools/preflight.sh          # 一眼看清：设备 / hdc / 产物 / 缓存来源 / 签名绑定
bash tools/run_selftest.sh       # 确认代码仍健康（38/38）
bash tools/run_hw_test.sh        # 确认 USB 层仍健康（20/20）
```

数据桥日常运行：

```bash
cd bridge && ./start.sh --weather 北京 && ./status.sh   # 停止用 ./stop.sh
```

---

# 附：Windows 绿色单文件版（2026-10-12 新增，与上面鸿蒙版并列的两条腿之一）

产物：`win/dist/dshlcd.exe`（约 107 KB，单文件，只依赖系统自带 .NET Framework 4.x，
AnyCPU 在 x64 / ARM64 都能跑）。详细文档见 **`win/README.md`**。

## 已完成并实测

- **协议层逐字节同构**：`win/src/Ly.cs` 与鸿蒙版 `LyProtocol.ets` 由同一个参考实现
  （`tools/ly_reference.py`）生成期望值，两边 FNV-1a 完全一致。
- **仪表盘逐行移植**：`win/src/Dashboard.cs` + `Theme.cs`（System.Drawing，横竖两套布局）。
- **竖装方案在 Windows 侧同样成立**：逻辑 480×1920，调用方整体旋转 90°；分区像素统计
  与**鸿蒙真机实测的竖屏落点一致**（表头在最右侧带，VM/USAGE 在左侧）。
- **自检 119/119 通过**（协议 + 调度 + 归一化 + JSON），在真 Windows 11 ARM64 上跑出来。
- **完整链路在 VM 里真跑通**：UDP 遥测 → 渲染 → JPEG 编码（1920×480，88–113 KB，质量 0.9）
  → HTTP 全套接口（`/status` `/diag` `/frame.jpg` `/set` `/preview` `/probe`）
  → VM 画面源从主机 livepad 抓帧（`vmFrames=6–9`，1680×1120，5–19 ms）。
- **USB 枚举路径可用**：`--probe` 能正确读出真实 VID/PID（硬件 ID 解析的
  `SPDRP_HARDWAREID` 常量写错过一次，已修正为 0x01）。

## 唯一没验证的

**没有插着这块屏推过帧**（硬件未到）。协议字节级正确性有自检背书，但
`winusb.dll` 的实际握手/写管道/ACK 只能等屏到了跑 `dshlcd.exe --probe` 再确认。
另外"画面好不好看"没人眼确认过（渲染靠数值统计验证，没视觉通道）。

## 怎么继续构建（关键：在虚拟机里真编译真验证）

```bash
cd ~/WorkBuddy/TrofeoLCD
python3 tools/win.py build                                   # 推源码进 VM 编译，回读 build.log
python3 tools/win.py run "--selftest"                        # 119 项自检
python3 tools/win.py run "--demo --seconds 8 --out-frame C:\\dshlcd\\out\\demo.jpg"
python3 tools/win.py run "--probe"                           # 屏到手后先跑这个
```

通道原理与踩过的坑记在 `~/WorkBuddy/ENVIRONMENT.md` 第 11 节（务必先读，
尤其是"C# 5 语法上限"和"注入要串行/文本落地要等"三条）。

构建约束：VM 里只有 `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`，
**语言上限 C# 5**，没有 Roslyn/dotnet/VS。


---

# 附二：打印机（拓竹）面板 —— 2026-10-12 新增，鸿蒙版已上真机

## 做了什么

- **数据源**：桥端新增 `--printer <url>`（默认关），每 5 秒拉一次 `bambu-monitor` 的
  `/api/state`（`~/WorkBuddy/拓竹PS2/bambu-monitor`，零依赖 Node 服务，端口 8790），
  把它的嵌套结构压成一个扁平的 `printer` 段塞进同一份 UDP 遥测里。
  另有 `--printer-fake run|idle|error|offline` 造数，用于没打印机/云 token 过期时验证面板。
- **鸿蒙端**：`Types/Normalize` 增加 `PrinterInfo`（含归一化：类型不可信、托盘上限 8、
  空槽过滤、颜色清洗成 #RRGGBB、`print_error` 是 32 位码不能小上限截断）；
  `Dashboard.printerPanel` 在**右侧那一列的下半部分**渲染（VM 画面从 452 缩到 290，
  正好接近 VM 源 1680×1120 的 3:1.5，黑边更小）。没有打印机数据时**不拆栏**，布局与旧版一致。
- **自检**：46/46 通过（新增 8 条打印机用例）。

## 真机验证（2026-10-12 01:14）

装了新 HAP（`tools/cli_build.sh` → `entry-default-signed.hap` 566KB，verify-app success），
桥端跑 `--printer-fake`，抓 `/frame.jpg` 做像素定位（横屏 180° 翻转后卡片落在左上 x14-470/y14-166）：

- 四个 AMS 色块精确命中：红 `FF3B30` x146-153/y119-126、绿 `34C759` x144-154/y87-97、
  蓝 `0A84FF` x145-153/y58-66、黄 `FFCC00` x145-153/y27-35 —— 间距 30px，与 `Theme.P` 的比例布局一致。
- 告警态（`--printer-fake error`）出现 **369 个红色像素**（`#EF4444`）位于 x145-450/y73-143，
  即 HMS 告警行 + 状态徽标。
- VM 面板区域内容密度 47%（画面正常，没被卡片挤坏），其余面板密度 1-5%（文字型）。

## 还没做的

- **真实打印机数据**：`bambu-monitor` 的云端 token 已过期（401 请登录账号），
  要看到真机数据得你重新登录一次；面板本身不依赖云端，接上就能显示。
- **Windows 版同步**：按"鸿蒙固化后再做 win 版"，打印机卡片**还没**进 C# 渲染器。
- **Windows 版子代理的交付**：`win/src/Dashboard.cs` 已与 ArkTS 做过机械逐行比对
  （23/23 方法一致，脚本 `win_dash/audit_vs_ets.py`，输出在 `win_dash/out/verify/audit_vs_ets.txt`），
  自检 119/119。

## 另外两份文档

- `docs/功能建议清单.md` —— 打印机/DSH/内容/交互四类，含我的推荐顺序
- `docs/代码清理提案.md` —— 可删项分 A/B/C 三组，**等你确认才动手**

---

## 2026-10-13 界面精修 + 三个真 bug 修复（真机实测）

界面风格对齐隔壁 DiPlay（CarPlay 诊断仪）：标题 22 + `9.16 LCD` 副标 + 右侧 RUNNING/STOPPED
**状态药丸**（`#0D2818`/`#238636` 描边），下面一条摘要条，各区块带小标题（左侧 3vp 绿条 + 右注脚），
数值一律 `fontFamily('monospace')`，开关做成**可换行胶囊**（开着时边框变绿），VM 地址卡里放一条
绿底提示条，页脚显示实测版式。整页改为 16vp 水平内边距（原来是 `96%` 居中），主/次按钮分色。

### 修掉的 bug（都有日志证据）

1. **VM 地址存不住（根因是顺序 bug，不是偏好存储的问题）**
   `startService()` 原来**先**把 `vmUrlText` 推给服务、**后**才 `new LcdService()`。于是当
   "偏好先读完、`Canvas.onReady` 后到"时，服务是带着**默认地址**创建的，而 `pushedVmUrl` 已是保存值；
   随后 `start()` 里的 `refreshStatus()` 看到两者不等 → 误判成"外部改了地址" → **把默认值写回偏好文件**
   （实测 27～36ms 后就写回去了）。修法：地址同步挪到创建之后，并且服务/偏好只认新的权威字段
   `appliedVmUrl`，不再认输入框文字。
2. **`TextInput` 用陈旧值回调，把地址打回默认**
   `TextInput({ text: ... })` 不是双向绑定：它在页面首次构建时就固化了当时的值（那时偏好还没读完 = 默认值），
   之后重新布局会用这个陈旧值触发 `onChange`。日志实证：
   `输入框变更 #1: 「http://127.0.0.1:8787/vm/frame.jpg」 权威值=http://192.168.3.57:8787/vm`。
   现在输入框只改 `vmUrlText`，只有「应用」按钮才写 `appliedVmUrl`。
3. **缩放滑块下限把手动缩放"焊死"在 30%**
   自动适应算出的缩放是 27.6%，低于滑块 `min:30` → Slider 夹值并回调 `onChange` → `userScale=0.3`，
   变成"手动 30%"，内容只剩 165×40vp（日志：`缩放=0.300 (手动)`）。改为 `min:10` + 钳制 `previewPct`。
4. **自动适应用了估算框宽，永久溢出 9vp**
   自动缩放按 `0.94×屏宽` 估，真实框是 `屏宽-32` → 点了"适应"仍显示左右滑块。
   现在框宽以 `onAreaChange` 实测值为准，实测出来后自动模式重算。

### 实测结果（Mate 70 RS，`192.168.3.145:37911`）

```
版式: 手机（屏宽 376vp）预览占屏高 58%
已读取保存的 VM 监视地址: http://192.168.3.57:8787/vm      ← 冷启动读回保存值
启动前同步监视地址: http://192.168.3.57:8787/vm            ← 推给服务的是保存值，不是默认值
预览框实测 344.0x469.0vp 内容=344x86vp 横向溢出=0vp 纵向溢出=0vp   ← "适应"就是刚好放下
自检 46/46 通过 | jpeg 1920x462 26642 B | canvas 548.6x132 vp
启动全过程零写盘（grep 设置已保存/跳过保存/外部改地址 无输出，prefs mtime 不变）
```

`LcdService` 现在只启动一次（原来 `Canvas.onReady` 多次触发会重复起 FrameServer、重复跑自检）。

### 新增工具

`tools/shot_ascii.py <png|jpeg> [列数]` —— 无视觉通道时核对版式：调色板命中统计 +
每 1/40 高度的分带平均色与内容列范围（判断有没有横向溢出）+ 亮度 ASCII 图。
**注意：手机锁屏时 `snapshot_display` 只能拍到锁屏**（本次手机锁着，界面观感最终要你自己看一眼）。

### 补：标题被前置挖孔挡住（2026-10-13，用户反馈）

照片：`Trofeo Vision` 滚到顶栏时被挖孔遮住，只剩结尾的 `sion`。

根因：`expandSafeArea` 加在 **Scroll 自己**身上，内容直接顶到物理顶边，而那里正是挖孔位置。

修法（沉浸式 + 不被挖孔挡的标准两层结构）：

```ts
Stack() {
  Column().width('100%').height('100%').backgroundColor('#0D1117')   // 背景层
    .expandSafeArea([SYSTEM], [TOP, BOTTOM])                          // 铺满整窗，不留白边
  Scroll() { ... }                                                    // 内容层：不扩顶部
    .expandSafeArea([SYSTEM], [BOTTOM])                               // 只延伸底部
}
```

实测避让区（`logSafeArea()` 输出，Mate 70 RS）：

```
避让区: 系统 top=136px(38.9vp) bottom=0px left=0px right=0px | 手势条 bottom=0px | 密度=3.5
```

即系统确实给了 38.9vp 顶部避让（挖孔+状态栏），内容层从这条线往下排；上滚时裁在 38.9vp，
不会再钻到摄像头下面。**注意 `getWindowAvoidArea(TYPE_SYSTEM)` 在隐藏状态栏后仍返回非 0**，
所以这个方案不需要写死像素值，平板/手机都自适应。

### 桌面图标重绘（2026-10-13）

发现：`AppScope/resources/base/media/{foreground,background,app_icon}.png` 与
`entry/src/main/resources/base/media/startIcon.png` **和隔壁 DiPlay 项目逐字节相同**，
也就是 DevEco 模板默认图（蓝色方块 + 白色 "H"）——桌面图标一直是没换过的模板。
而桌面图标取的是 `module.json5` 里 `abilities[0].icon = $media:startIcon`。

重绘：`tools/make_icon.py`（可重复运行，结果确定），符号 = **1920×462 的超宽副屏 + 屏里的
仪表盘 + 支架**，配色直接取应用自身（底板 #2E4054→#1C2836、屏体近黑、柱 #C9D1D9、
最高一根绿 #3FB950、强调 #2EA043），屏体下方带一层极淡的地面倒影。

```
  97727 B  (1024,1024)  entry/src/main/resources/base/media/startIcon.png   桌面图标 + 启动页
  97727 B  (1024,1024)  AppScope/resources/base/media/app_icon.png          应用级合成图
  88646 B  (1024,1024)  AppScope/resources/base/media/foreground.png        分层前景层
  49634 B  (1024,1024)  AppScope/resources/base/media/background.png        分层背景层
 175081 B  (1180, 940)  docs/icon-preview.png                              预览对照图（浅/深底、三种遮罩、真实尺寸）
```

数值自检（脚本内置，跑完就打印）：

```
✅ 实心内容 595x449px（上限 614x471）；最远角距中心 381px（上限 502）→ 圆形/超椭圆遮罩都不会切到
屏体填充 lum 7~8  vs  底板 lum 60  → 明暗差 52   （第一版只有 29，缩到 48px 是一团黑，已重做）
柱区 lum 207      vs  屏体 lum 8   → 明暗差 199
32 / 48 / 96 / 192px 缩放后结构不变（竖直剖面仍是 底板→屏体→柱→支架→倒影 五段）
```

预览图也推到手机上方便随时看：`文件管理 → 下载 → icon-preview.png`。

---

## 2026-10-13 三版本同步对齐（鸿蒙 / Windows / 网页预览）

背景：网页预览页在两个地方各有一份**手抄**实现，实测已经走样——
鸿蒙那份停在 `1920×480` + 旧蓝色调色板（`#4d6bfe`），Windows 那份结构完全不同
（还把竖屏当成图片旋转 90° 再转一次）。开发期工具也一起停在 480。
这次不是"再抄一遍"，而是把**单一来源 + 生成注入 + 门禁**建起来。

### 结构改动

| 项 | 之前 | 现在 |
|---|---|---|
| 网页预览页 | 鸿蒙、Windows 各一份手抄 | **`web/preview.html` 唯一来源**，`tools/make_web.py` 注入两侧 |
| 注入方式 | — | 标记区间 `>>> WEB-PREVIEW >>>` / `<<< WEB-PREVIEW <<<`；`--check` 校验一致性 |
| 帧高常量 | 网页页/审计脚本写 480 | 全部 462（与 `Theme.ets` 的 `L.height` 一致） |
| 预览页功能 | 两边各有一半 | 区域聚焦（全图/VM/打印机/DSH/系统/用量）、缩放+平移、竖屏/180°/夜间开关、远程取帧状态、协议自检、诊断 JSON |

模板约束（`make_web.py` 会强制检查）：不能出现反引号、`${`、反斜杠——
前两者会破坏 ArkTS 模板字符串，反斜杠会破坏 C# verbatim 字符串。

### 字段对齐

- `/status`：两侧现在**完全同字段**（16 项，实测比对）：`ack bridgeAgeSec device errors frames jpegBytes jpegH jpegW night platform rotate180 sent state usbOpen vertical vmUrl`
  - 鸿蒙侧补了 `night` / `platform`；Windows 侧补了 `vmUrl`
- `/diag`：Windows 侧补齐
  - `vmAgeMs` 原来是 `_vm == null ? -1 : 0` 的**占位**（永远 0）→ 改成真实值 `VmSource.AgeMs`
  - 新增 `vmErr`（错误文本，与鸿蒙同名）
  - 新增 `selfTest` / `selfTestAllPass` / `platform`：Windows 现在**启动即跑一次协议自检**（纯计算），
    和鸿蒙 `LcdService.start()` 的行为一致
- Windows 的 VM 摘要补上"多久之前取到"（原来只有帧数/尺寸/耗时，看不出画面是不是停了）

### 图标三处统一

同一个设计（1920×462 超宽副屏 + 仪表盘 + 支架）现在三处都在用：

```
entry/src/main/resources/base/media/startIcon.png   鸿蒙桌面图标 + 启动页
AppScope/resources/base/media/{background,foreground,app_icon}.png   鸿蒙分层图标
win/icon/dshlcd.ico                                 exe 图标（7 个尺寸；16/24/32 用独立绘制的简化版）
网页预览页 favicon                                  内联 SVG（同一符号）
```

Windows 侧同时补了文件属性：`FileVersion 1.0.<构建号>.0`、`ProductVersion v<构建号> built … src <指纹>`、
ProductName / FileDescription / Company（由 `tools/win.py` 每次构建生成 `win/src/AssemblyInfo.cs`）。

### 实测证据（最终版：Windows v9 / 鸿蒙 955035 字节）

```
sh tools/win_verify.sh --quick      →  通过 12，失败 0，跳过 1  ✅
  ✅ 双架构编译通过（arm64 size=236544 x64 size=236544）
  ✅ 自检 125/125    ✅ USB 枚举跑通（没插屏，读出真实 VID/PID）
  ✅ 横屏 1920x462 white=0 colors=20084    ✅ 竖屏也进 1920x462 帧
  ✅ 网页预览页：鸿蒙 / Windows 两侧与 web/preview.html 完全一致（10215 字节 × 2 份）
  ✅ exe 图标 7 个尺寸    ✅ /diag 字段与鸿蒙对齐    ✅ 鸿蒙侧取帧状态取值器

sh tools/win_page_check.sh C:\dshlcd\out\dshlcd_arm64_v9.exe
  ✅ 网页预览页逐字节一致（模板 10214 B / 服务返回 10214 B）
  ✅ /status 字段与鸿蒙一致（16 项）
  ✅ ICON_OK 40x40 · FileVersion 1.0.9.0 · ProductVersion "v9 built … src …"
```

顺带修掉的**验证工具自身**的问题（不修就会误报）：

- `tools/win.py build` 用"日志大小稳定 4 秒"判定构建完成 —— 脚本开头先写头行，
  之后 csc 要跑几十秒，于是拿到一份**只有头行**的"成功"构建日志（win_verify 第 1 步据此误报 FAIL）。
  改成等 `arm64 size=` + `x64 size=` 同时出现，并且**要求日志比本次开始时间新**
  （注入失败时旧日志会"复活"，里面的 size 行同样会造成误判 + dist 同步找不到 vN 产物）。
- `tools/win_verify.sh` 第 1 步还在 grep 老 `build.cmd` 的 `[OK] compiled`（实际是 `[OK] arm64`）；
  第 2/4/5 步没有重试，会撞上 VM 输入注入偶发丢包 —— 加了重试。
- `tools/win_page_check.sh` 不先删旧结果文件，等 `DONE` 会立刻命中上一次的残留，
  读到**上一版 exe 的版本号与页面**（假通过）—— 已修。
- `tools/fetch_frame.sh` 把 `1920x480` 当"与设备要求一致"，会给正确的 462 帧打警告 —— 已修。


**未实测**：鸿蒙手机上的网页预览页字节比对 —— 手机锁屏，开发模式下 `aa start` 被拒
（`Error Code:10106102 The device screen is locked during the application launch`）。
源码级一致性由 `make_web.py --check` 保证（两侧注入块与模板完全相同）；
应用真的吐出来的那份要等手机解锁后跑一次 `curl http://<手机>:54546/` 对比。

### 新增/改动的工具

- `web/preview.html` —— 网页预览页唯一来源
- `tools/make_web.py` —— 注入（`make_web.py`）/ 校验（`--check`）
- `tools/win_page_check.sh` —— 端到端：VM 里起 exe → 抓 `/` 与 `/status` → 主机逐字节比对 + 字段比对 + 图标/版本信息
- `tools/win_verify.sh` —— 帧尺寸断言 480→462（原来会误报 FAIL），新增第 7 步"三版本对齐"门禁
- `tools/preview.py` / `tools/make_sim.py` / `tools/sim.html` —— 帧高 480→462，sim.html 已重新生成

---

## 2026-10-13（下半场）"同步吧" 之后的第二轮：把**审计工具**也同步了

用户一句"同步吧"之后复查，发现真正没同步的不只是网页页，还有**审计自己**：

| 位置 | 问题 | 影响 |
|---|---|---|
| `win_dash/src/` | 停在 10-12 的 C# 源码副本 | 审计外壳渲染的 4 张对照图是**旧代码**画的 |
| `win_dash/verify.py` | 常量还是 1920×480、贴底行区域按 480 手写 | 帧高 462 时"尺寸"与"up 行"误报 FAIL |
| `win_dash/verify_frame.py` | 同上（1920×480 / 480×1920） | 竖装断言越界 |
| `win_dash/harness/Program.harness.cs.txt` | `new Bitmap(1920, 480)` 写死 | 编译出来的 exe 永远画 480 高 |
| `tools/win_verify.sh` | 断言 1920×480、grep 老的 `[OK] compiled` | 误报 FAIL（已在上节修） |
| `tools/fetch_frame.sh` | 把 480 当"与设备要求一致" | 给正确的 462 帧打警告 |

### 顺带抓到的**真功能缺口**（不是工具问题）

`audit_vs_ets.py`（ArkTS ↔ C# 逐方法比对）报 `systemPanel` 需人工确认，打开一看：

```
[DIFF] systemPanel -> SystemPanel  数字 31/31  文案 18/16
       数字缺 ['20', '40']; 文案缺 ['电量', '电量（充电中）']
```

**鸿蒙侧 `systemPanel` 有"电量"行，Windows 侧根本没有** —— 电量功能只在鸿蒙实现过。

而且鸿蒙侧那条规则本身也不对：`pickSystem()` 在桥端数据新鲜时**整块用桥端**，
而电量是**本机**属性（桥端 JSON 里没有这一项）→ 结果"电量"只在**桥端断流时**才显示，
桥端正常跑着反而看不到。

两边一起修（同一规则、同一组用例）：

- `common/SystemMerge.ets` **新文件**：把 `pickSystem()` 从 `LocalSys`（依赖 `@kit.*`，主机自检跑不了）
  挪出来做纯函数，规则改成"不管用哪一份数据，都拿本机读数补上电量"。
  与 Windows 的 `State.PickSystem()` 同名同语义。
- `win/src/State.cs`：`SystemInfo` 加 `Battery/Charging`；`NormalizeSystem` 解析并钳到 -1..100；
  新增 `PickSystem()`。
- `win/src/SysMon.cs`：用 WinForms 的 `SystemInformation.PowerStatus` 采本机电量
  （无电池/虚拟机时 `BatteryLifePercent=255` → 保持 -1，面板不画）。
- `win/src/Dashboard.cs`：按 ArkTS 同款数字（`y+334+dy`、字号 17/16、阈值 20/40、`x+22`/`x+w-22`）
  画电量行；与"CPU 温度"共用一行（面板高度不够再开一行，实测两者不会同时出现）。
- 两侧自检各加 2 个用例（`归一化(电量)`、`系统数据合并(本机电量)`）；
  Windows 侧另有 5 个细项（钳制/布尔/桥端自带电量优先/断流用本机）。

### 实测（Windows v10 / 鸿蒙 964450 字节）

```
ArkTS 自检（主机跑真源码）      48/48  ✅（46 → 48，多的是电量两例）
Windows 自检（虚拟机）          132/132 ✅（125 → 132）
audit_vs_ets.py                全部方法一致（systemPanel 从 DIFF 转 OK，文案 18/18）
win_dash/verify.py             全部通过（6 张对照图全部 1920×462 / 462×1920）
win_dash/verify_frame.py       横装/竖装 全部通过
```

### 新增工具

- `tools/dash_sync.sh` —— 同步审计副本 → 虚拟机编译渲染 → 主机侧核对，一条命令跑完。
  两个必须记住的坑写在脚本注释里：
  ① 外壳只编"渲染链"那几个 .cs（`Gui.cs`/`LcdRunner.cs` 引用外壳 Program 没有的
     `Program.Version`/`SaveIniValue`，编进去必然 CS0117）；
  ② VM 共享盘旧文件删不干净，**每次换新目录/新文件名**，否则"审计通过"其实是旧代码的结论
     （这次就中了一次：新日志没生成，脚本把上一轮的 480 对照图当成本次结果）。

### 验证结果（2026-10-13 上午，"验证吧"之后的一轮全量复核）

Windows 侧（`sh tools/win_verify.sh --quick`）：

```
== 1/7 编译 ==      PASS  双架构 arm64/x64 size=238080
== 2/7 自检 ==      PASS  132 / 132，失败 0
== 3/7 USB 枚举 ==  PASS  4 个接口；没插屏（VID=0x0416 PID=0x5408/0x5409 未找到）
== 4/7 横屏渲染 ==  PASS  1920x462  white=0  colors=21543
== 5/7 竖屏渲染 ==  PASS  竖装也进 1920x462 帧  white=0  colors=19756
== 6/7 VM 画面源 == SKIP  （--quick 跳过；补跑时见下方"未验证"）
== 7/7 三版本对齐 == PASS  网页页两侧一致 / 图标 7 尺寸 / /diag 字段对齐
结果： 通过 12，失败 0，跳过 1  ✅
```

主机侧（不需要虚拟机的那些）：

```
鸿蒙 ArkTS 自检（Node 剥类型跑真源码）        48/48 通过
ArkTS ↔ C# 逐方法比对（audit_vs_ets.py）      全部方法一致（systemPanel 由 DIFF 转 OK，文案 18/18）
布局审计 layout_check.py（462）               0 个问题，49 个文字元素
网页预览页单源一致性 make_web.py --check      两侧与 web/preview.html 一致
网页页内嵌 JS（node --check）                 通过
审计外壳对照图 6 张                           1920×462 / 462×1920（全部新渲染）
win_dash/verify.py（独立按 Theme 常量复推）   全部通过
win_dash/verify_frame.py（横+竖）             全部通过
win_page_check.sh v11                         页面逐字节一致 + /status 16 字段一致 + ICON_OK 40x40
鸿蒙构建                                     964450 字节，verify-app success，已装平板
```

### 这一轮又修掉的验证工具问题

- `tools/win.py run`：把"exe + 一长串参数"直接打进 Win+R 太脆（连着 4 次不生效，
  而同样的命令写进 `.cmd` 用 `cmd /c` 调起就稳）→ 统一改成写 `run-once.cmd` 再注入。
  这个坑让 `win_verify` 的第 4/5 步连续两轮误报 FAIL。
- `win_dash/verify.py`：空状态那两条检查的 y 区域是按 480 帧手写的绝对值，
  帧高 462 后"贴底"的行整体上移 18px，区域没跟着动 → 明明画了字却数到 0。
  改成按版式推导（`LM + LPH - 58` 这类）。
- `tools/dash_sync.sh` 新增：一条命令完成"同步审计副本 → 虚拟机编译渲染 → 主机核对"。

### 本轮仍然未验证（两个外部条件）

1. **鸿蒙手机上的网页预览页字节比对** —— 手机现在连不上了
   （`hdc list targets` 只剩平板；此前是锁屏导致 `aa start` 被拒 10106102）。
   源码级一致性由 `make_web.py --check` 保证，要实测需手机解锁并重连无线调试。
2. **`win_verify` 第 6 步（真实 VM 画面源 + HTTP 自测）** —— VM 应用 `com.oseasy1.ohvm`
   还在跑，但客户机的磁盘共享已消失（`.VMDocs/.hwf_share/.disks` 不存在），
   注入与回读都断了。此前（v9 时期）这一步是通过的；等 Windows 客户机重新开机后
   跑 `sh tools/win_verify.sh`（不带 --quick）即可补上。

---

## 2026-10-13 真机上手后的一轮（只做鸿蒙版；Windows/网页按用户要求暂停）

屏幕接上后暴露的问题都是"只有真机才有"的，逐条修完：

| 用户反馈 | 真因 | 修法 |
|---|---|---|
| 默认得手动开旋转 180° 才对 | 代码在每次打开设备时**硬把 rotate180 置成 false**（照抄另一驱动的结论），默认值本身就是错的 | 改成三态：0=跟随设备握手（默认）/1=强制开/2=强制关；真机报 180°，开箱即正 |
| 字太小，看不清 | 正文 16~17px 在 8.5px/mm 的 9.16" 屏上只有 ~2mm 字高 | 字号总系数 `F.scale`：1.0 → **2.0**，并按新字号重排四个面板的行距 |
| 容易断掉 | 应用从未申请**后台连续任务**，切到浏览器就被系统挂起 | `backgroundModes: ["dataTransfer"]` + `startBackgroundRunning`（缺前者时**所有**模式都报 9800005）；另加 12s 推帧看门狗 |
| 帧率太低 | 编码 ~70ms + 推送 ~90-140ms，单帧 ~200ms | 按**内容签名**推帧（没变化就跳过），跳帧占比实测 ~40-50%；写块大小实测 4096 最优（8192/16384 反而 480/650ms） |
| 屏上 DSH 三格是空的 | 遥测桥没跑 | `bridge/start.sh` 起桥；DSH 面板立刻有项目/模型/活动/工具/轮次/token |

### 顺带把一个"骗人的工具"换成可信的

`tools/layout_check.py` 原来审计的是 `tools/preview.py` —— 一份**手工镜像**。
1.8× 那一轮踩了个正着：改了真源码 `Dashboard.ets`，审计报出来的问题一字不变（它在看旧镜像）。
现在改成：**Node 剥类型直接跑真源码**（`tools/hwsim/layout_real.mts` + `canvas_shim.ts` 打桩记录
每个文字框），面板矩形也从真 `Theme.ets` 常量算出来 —— 检查脚本里再没有一处镜像的布局数字。
1.8×/2.0× 两轮的 6~8 处重叠/越界就是靠它定位并逐条改掉的（含"文字压分隔线"这种肉眼很难看出来的）。

### 实测（平板 + 真机屏）

```
设备      USBDISPLAY (416:5408) · PM=65 SUB=5 FBL=192 1920x462 rot=180°
旋转      模式 0（自动）· 设备报 180° · 生效 True        ← 开箱即正，不用手动
后台保活  True（dataTransfer）                          ← 切走也继续推
推帧      1920x462 · 0 错误 · ACK 512B/2-4ms [03 ff ...]
5 分钟采样 60 次：0 次失联、0 错误、USB 从未掉
布局审计  真源码 横装 0 问题（55 个文字元素）· 字号系数 2.0
```

## 2026-10-13 余额上屏（DeepSeek 账户）+ 字号 2.5×

### 余额怎么接的

```
key        只从 ~/.config/dsh-lcd/deepseek.key 读（0600；命令行会进进程列表，所以不传参）
           日志只打掩码（sk-7da…a5e4），错误信息里也不带 key
桥         node dsh-bridge.mjs --deepseek-balance [秒]   默认 600 秒刷一次
           查 GET https://api.deepseek.com/user/balance
           → payload.balance = { currency, total, granted, toppedUp, available, error, at }
           失败保留上一次的值并记下 error（面板不会因一次网络抖动空掉）
鸿蒙侧     Types.BalanceInfo + Normalize.normalizeBalance（字段类型不可信，字符串数字也收）
           /diag 暴露 balanceCur / balanceTotal / balanceErr 便于核对
面板       用量面板「今日 TOKEN」正下方：
             分隔线 / 「余额」+ 大数字（¥48.86，<5 红、<20 橙、否则绿）/ 一行暗色小字「充值 … 赠送 …」
           余额变化会进内容签名 → 立刻重推一帧
```

### 2.5× 字号下的排版取舍（横装审计 0 问题）

字号总系数 2.0 → **2.5**，随即发现四个面板都装不下原来的信息量，于是按重要性取舍：

| 面板 | 保留 | 让位（数据仍在 /diag 与遥测里） |
|---|---|---|
| 系统 | CPU 圆环（环加大到 r=74，% 字号收到 22 才塞得进）+ cores、内存+条、⚡电量 | 负载、主机名/运行时长 |
| 用量 | 今日 TOKEN（大字）、**余额**、时钟（只到分钟） | ↑↓、上下文、预估花费、日期、天气、歌词 |
| DSH | 项目、模型、状态徽章、活动、chips（含工具名）、待办进度+条、2 条待办、数据桥 | 单独的"当前工具"芯片块（并入 chips）、第 3 行"最后一句" |
| 打印机 | 状态 + 42% + 进度条 + 喷嘴/床/腔温度 + 托盘色块 | 作业名、层数、托盘文字 |

**竖装（vertical）还没跟上**：它的分段是固定偏移（hdrY/vmY/sysY/agY/usY 合计 1920），
2.5× 下要重新分配段高才放得下 —— 竖装审计目前 31 个问题，等要用竖装时再改。

### 实测

```
余额      CNY 48.86（桥端 600s 刷新；/diag 可核对）
桥        0s 前 · 状态 busy
推帧/跳帧 60 / 60 · 错误 0        ← 按内容变化推帧（一半的 tick 被省掉）
旋转      模式 0（自动）→ 180° · 后台保活 True
输出帧    1920x462 111KB · 渲染 6.4 编码 56 推送 204ms
布局审计  真源码 横装：0 问题（42 个文字元素）
ArkTS 自检 48/48
```

⚠️ Windows 版按用户要求**暂停**：C# 那侧（Dashboard.cs 的版式数字、F.Scale、余额行）都还没同步，
`win_dash/audit_vs_ets.py` 现在会报 DIFF —— 恢复 Windows 时按它逐条对齐即可。

### 分级字号（用户提的思路）：重要的 2.5×、次要的 2.0×

统一 2.5× 后为了塞下只能砍信息，用户反馈"很多字都看不到了"，
并提出"重要的 2.5×、其他 2.0×"。于是 `Theme.ets` 加了第二档：

```
F.scale    = 2.5   F.font / F.mono        → 重要信息
F.scaleSub = 2.0   F.fontSub / F.monoSub  → 次要信息
Dashboard.label()/mono() 末位多一个 scale 参数（'main' | 'sub'）
```

于是把砍掉的信息按子字号加回来了：

| 面板 | 2.5×（重要） | 2.0×（次要，新加回） |
|---|---|---|
| 系统 | CPU 环 + %、内存 + 条、⚡电量 | **负载**、**运行时长 up 1d 12h** |
| 用量 | 今日 TOKEN、**余额**、时钟 | **上下文 + 占用条** |
| DSH | 项目、模型、徽章、活动、chips、待办进度+条、2 条待办、数据桥 | —（本来就够） |
| 打印机 | 状态、42%、进度条、喷嘴/床/腔温度 | 层数、作业名、托盘文字（本来就都在） |

审计样例里也补上了余额（否则只验到"没有余额"的分支 '—'，真有余额时那行从没被审过）。
横装最终：**47 个文字元素、0 问题**。

仍让位的（面板 434px 真的放不下，数据都在 /diag 与应用界面里）：
用量面板的 ↑↓（输入/输出 token）、日期、余额的"充值/赠送"明细行；系统面板的主机名（项目/模型在 DSH 面板已有）；
天气、歌词；DSH 的第 3 条待办与第 2 行"最后一句"。**竖装仍是 2.5× 单档、尚未重排。**

### 用户 5 条排版反馈（全部落地，横装审计 0 问题 / 50 个文字元素）

| # | 反馈 | 处理 |
|---|---|---|
| 1 | 待办按需改成轮播 | 一屏 2 条，每 8 秒向前滚一格（`Dashboard.carouselSlice()` 纯函数 + `carouselTick()` 节拍）；多于 2 条时右下角显示 `1›2/4` 页码；**节拍进内容签名**，否则签名不变屏上不会翻。自检加了取模循环用例（49/49） |
| 2 | WorkBuddy/工作中 上方有空白，提上来利用 | DSH 左列整体上移（项目 130→108、chips 182→168、活动 262→226），腾出的空间把"最后一句"从 1 行恢复到 2 行（2.0× 子字号） |
| 3 | 电量字体和内存占用绘图重叠 | 内存行/内存条/电量行三者重新拉开（296 / 320 / 358 + 分隔线 h-40）；**审计补上了"文字压到进度条"检查** —— 顺带抓到打印机卡片里作业名压进度条的同类问题 |
| 4 | 今日 token 数字太大，放标签下面 | 从"右侧 2.5×34px"改成"标签下方 2.0×30px 左对齐" |
| 5 | 日期加月日、缩小、重排 | 新增 `10月13日 周二`（2.0×14），与时钟、上下文、USB 行重排 |

**审计这次是被用户教了一次**：原来只比"文字↔文字"，查不出"文字压在进度条上"。
新增的检查从线段里识别"上下两条横线、间距 ≤22px、x 范围相近"的细长矩形（进度条是
Dashboard 自己的 roundRect 画的，不进 canvas 的 rects），圆环与徽章（文字本来就画在上面）排除。

用量面板最终排布（应用坐标 y）：

```
21..69   USAGE
80..120  今日 TOKEN
136..196 80.5万          ← 标签下方、2.0×
216..264 余额 ¥48.86     ← 2.5× 标签 + 2.0× 金额
272..308 上下文 56.7% + 条
323..393 22:05           ← 时钟 2.5×
396..424 10月13日 周二     ← 2.0×
421..447 USB ● N帧
```

## 2026-10-13 主题系统 + 诊断终端主题（用户第 3 条）

### 同类项目调研（用户第 2 条）

- [mathoudebine/turing-smart-screen-python](https://github.com/mathoudebine/turing-smart-screen-python)：同类 USB 小屏的事实标准项目，
  **内置 74 个主题目录**（BigClock / Cyberpunk 2077 / ColoredFlat / Cyberdeck / Radials / AMD / CyanTheme …），
  主题是**声明式**的：`res/themes/<名>/{theme.yaml, background.png, preview.png}`，
  元素关键字是 `TEXT` / `LINE_GRAPH` / `RADIAL` / `GRAPH`（+ 背景图）。
  → 结论：**多主题是这个品类的标配**，而且差异不只是配色，是"显示什么"（大字钟 / 系统监控 / 曲线仪表 / 带背景图的皮肤）。
- [christensen143/claude-trofeo-hud](https://github.com/christensen143/claude-trofeo-hud)：**同一块屏**（Thermalright Trofeo Vision）的
  Claude 用量 HUD —— session/weekly 限额、token 燃烧速率、按量折算的成本。是我们最接近的"同类作品"，
  可借鉴的点：**限额/速率/成本**这类"AI 用量"指标。
- [haven80/trofeo-lcd-rs](https://github.com/haven80/trofeo-lcd-rs)：同型号 Rust 驱动（我们一直拿它做协议参考）。
- [thairc-dev/turing-smart-screen-custom-themes](https://github.com/thairc-dev/turing-smart-screen-custom-themes)、
  [syntensa/libre-panel](https://github.com/syntensa/libre-panel)：第三方主题包与替代实现。

### 已实现：主题系统（主题 0 = 现有仪表盘，主题 1 = 诊断终端）

- `LcdService.theme`（0/1）+ `/set?theme=N` + 界面胶囊按钮切换 + 落盘 `theme`；主题进内容签名（换主题立刻重推）。
- `render/ThemeDiag.ets`（新）：**风格参考隔壁 DiPlay / CarPlay 诊断仪**——顶部标题 + 状态药丸、
  左侧大段**等宽事件流**（按 idle/busy/tool/todo/print/err 着色）、右侧紧凑指标卡（CPU/内存/token/余额/上下文条）、
  底部染色"体检条"（数据桥 · USB · VM 一行看完）。字号用 2.0× 子档，一屏 10 行事件。
- 桥新增**事件环**（最近 12 条）：状态变化、工具调用、**步进变化（带当前那句话）**、待办增减、打印机变化、取数错误；
  启动时播一条，避免第一屏空白。
  ⚠️ 两个坑：`noteEvents` 一开始写在常驻路径的 `send()` 里（`--once` 看不到），
  后来又在 `buildPayload()` 里调用才两条路径都覆盖。
- 审计支持主题：`layout_check.py --theme=1`（主题 1 有自己的一套分区定义）。
  结果：**主题 0 = 50 个文字元素 0 问题；主题 1 = 17 个文字元素 0 问题**。
- 实测：切主题后两帧差异 14% 的像素（确实是两套版式）；主题 1 四个分区亮像素 1326/3839/835/518。

### 主题 1 的两处修正（都是审计抓出来的）

1. **时间戳与标签列重叠 23%**：2.0×13 的 `22:31:40` 有 115px 宽，标签原来起在 x+96 → 撞上。已改成 x+132 / 正文 x+250。
2. **事件从顶部往下画 → 只有 4 条时下半屏全空**（用户看到的就是"主题 1 几乎是空的"）。
   改成**终端习惯：从底部往上堆**，条数少时最新一条贴底、上面留白读作"历史"。

顺带把审计样例补上了 12 条事件 —— 之前样例里没有事件数据，**主题 1 的事件流那段根本没被审过**，
所以两个 bug 一路漏到真机上。补上样例后立刻全暴露。

### 环境注意

本机 CLI 的可执行名是 **`dsh-harmonyos` / `dsh-ohos`**（DSH 的 HarmonyOS overlay 启动器，不是构建工具）。
**不要重复启动**：它要占 127.0.0.1:3080，而 Web GUI 正在用这个端口（实测会 `EADDRINUSE` 启动失败）。
HAP 构建走的是另一条路：`/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/hvigor/bin/hvigorw`（见 `tools/cli_build.sh`）。

### 两个主题的实拍预览

- `docs/theme0-preview.png`（仪表盘，亮像素 28884）
- `docs/theme1-preview.png`（诊断终端，亮像素 3393：标题 1363 / 事件流 708 / 指标栏 812 / 体检条 510）
