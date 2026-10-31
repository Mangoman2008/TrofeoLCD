# TrofeoLCD — 利民 Trofeo Vision 9.16 LCD 鸿蒙驱动 + DSH 状态仪表盘

把利民 **Trofeo Vision 9.16 LCD**（1920×462，USB `0416:5408`）变成一块显示
**DeepSeek Harness 会话状态 / token 用量 / 任务进度 / 系统监控 / 时钟** 的副屏，
全部在鸿蒙上原生运行，不依赖官方 TRCC 或 Windows。

```
┌──────────────────────── 宿主 shell（harmonybrew 环境）────────────────────────┐
│  node bridge/dsh-bridge.mjs                                                  │
│    ├─ 尾部解压 ~/.dsh/sessions/**/session.jsonl.zstd（只解最后 24 个 zstd 帧）│
│    ├─ 解析 tool/call · assistant/message.usage · todo/write · turn/end        │
│    ├─ 读 /proc/stat · /proc/meminfo · loadavg（系统面板）                     │
│    └─ UDP 127.0.0.1:54545 → JSON 遥测                                        │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ JSON
┌───────────────────────────────────▼──────────────────────────────────────────┐
│  鸿蒙应用 TrofeoLCD（本工程）                                                 │
│    TelemetryBridge ── 收遥测                                                 │
│    Dashboard        ── 在 1920×462 画布上绘制仪表盘（5 列面板 + 右侧 VM 画面）  │
│    LcdService       ── 画布 toDataURL('image/jpeg') → 尺寸自校正 → LY 分块    │
│    LcdUsb           ── @ohos.usbManager: requestRight → claimInterface →     │
│                        bulkTransfer EP09 OUT（16 字节块头 / 496 字节数据）    │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ USB Bulk
                            ┌───────▼────────┐
                            │  9.16" LCD     │
                            └────────────────┘
```

---

## 一、设备与协议（已核实）

| 项 | 值 |
|---|---|
| 型号 | 利民 Trofeo Vision 9.16 LCD（`TH-TV916LCD`） |
| 分辨率 | 1920×462（协议 FBL 192；PM=68 时是 1280×480，PM=69 时是 1920×400） |
| USB | VID `0x0416` / PID `0x5408`（LY），`0x5409`（LY1） |
| 端点 | 厂商自定义接口（class `0xFF`）的 bulk OUT / IN |
| 帧格式 | 整帧 JPEG，按 496 字节切片，每片加 16 字节块头 → 512 字节块 |
| 约束 | JPEG ≤ 650KB；LY 块数补齐到 4 的倍数；每 4096 字节写一次；写完读 512B ACK |
| 空闲行为 | 固件会清屏，必须持续推帧 |

块头（小端）：`[0]=01 [1]=FF | LE32 整帧长度@2 | LE16 本块数据长@6 | cmd@8 |
LE16 总块数@9 | LE16 块序号@11 | [13..15]=0`，`cmd` 对 0x5408 为 `0x01`。

握手：发 2048 字节（`[0]=02 [1]=FF [8]=01`），读 512 字节，
校验 `resp[0]==3 && resp[1]==0xFF && resp[8]==1`；
`PM = 64 + resp[20]`（resp[20] ≤ 3 时按 1 处理），`SUB = resp[22] + 1`。

**真机期望值**：Trofeo Vision 9.16 实测上报 **`PM=65 SUB=5`** → `FBL=192` → `1920x462`。

### 编码旋转角（决定画面正不正）

依据 trcc `core/protocol.py` 的 encode 表（由厂商反编译得出），**按 SUB 分支**：

| 分辨率 | 规则 |
|---|---|
| 1920×462 / 1920×440 | `SUB ∈ {2,3,4}` → 0°，否则 **180°** |
| 1280×480 | `SUB == 2` → 90°，否则 0°（本工程只实现 0/180） |

9.16 面板是 `SUB=5` → **180°**（界面上的「旋转180°」开关默认开，握手后会自动按设备值设置）。
`0x5409`（LY1）的 PM 公式是 `49 + resp[20]`，**不是** `50 + resp[36]`（后者取错了回复字节，
参考实现已修正，本工程同步）。

> **鸿蒙的关键约束**：应用**不能**用 `usbfs` ioctl 直接操作 `/dev/bus/usb`
> （SELinux 域 `u:r:hishell_hap` 会拒绝 ioctl，实测 open 成功但 control transfer 报 EACCES），
> USB DDK（`OH_Usb_*`）又需要系统级权限 `ohos.permission.ACCESS_DDK_USB`。
> 因此**唯一可行路径**是应用层 `@ohos.usbManager` + 用户授权（`requestRight`），
> 也就是本工程采用的方式。

---

## 二、构建（纯命令行，已验证）

本机（鸿蒙 + harmonybrew）具备完整命令行构建链，**不需要 DevEco Studio**：

```bash
CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0     # 鸿蒙命令行工具集
export NODE_HOME="$CLT/node/bin"
export DEVECO_SDK_HOME="$CLT/sdk"
export PATH="$CLT/node/bin:$PATH"

cd ~/WorkBuddy/TrofeoLCD
"$CLT/hvigor/bin/hvigorw" --mode module -p product=default assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（约 210KB）
完整构建约 **20–40 秒**，改代码后可反复快速迭代。

工具链版本：Node v24.18.1、hvigor 7.26.8、ohpm 6.0.1、SDK API 26（26.0.0.105 Release）。

---

## 三、签名与安装

`build-profile.json5` 里 **`signingConfigs` 目前为空**，所以构建出的是 unsigned HAP，
不能直接安装。签名材料与 **bundleName 绑定**，无法用别的项目的证书顶替。

### 方式 A：DevEco 一键自动签名（推荐，与你已有 7 个项目相同）

1. DevEco Studio → **Open** → 选择 `~/WorkBuddy/TrofeoLCD`
2. **File → Project Structure → Signing Configs** → 勾选 **Automatically generate signature**
   - 会在 `~/Documents/ohos/config/` 生成 `default_TrofeoLCD*.p12/.cer/.p7b`
3. **Build → Build Hap(s)** → 得到 `entry-default-signed.hap`
4. 连接设备后 **Run ▶**，或 `hdc install entry-default-signed.hap`

### 方式 B：把本工程并入已有签名项目

若想立刻拿到可安装产物，可把 `entry/src/main/ets/` 下的 `usb/ render/ bridge/ service/ common/`
与 `pages/Index.ets` 复制进 `~/WorkBuddy/DeepSeekHarness`（bundle `com.deepseek.harness`
已有可用签名与 profile），作为它的第二个页面使用。

### 安装与启动

```bash
hdc list targets
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -b com.dsh.trofeolcd -a EntryAbility
```

---

## 四、数据桥用法

**日常使用**：数据桥可以后台跑，不用占着终端：

```bash
cd ~/WorkBuddy/TrofeoLCD/bridge
./start.sh                       # 后台启动（PID 写 .bridge.pid，日志写 .bridge.log）
./start.sh --weather 北京         # 顺带开天气
./status.sh                      # 看状态与日志尾部
./stop.sh                        # 停止
```

**调试用法**：

```bash
node dsh-bridge.mjs --once        # 打印一次 JSON（调试，含全量扫描）
node dsh-bridge.mjs               # 常驻，1 秒推一次（纯本地，不联网）
node dsh-bridge.mjs --interval 2000 --port 54545
```

可选功能（**默认关闭，开启后才会联网/执行外部命令**）：

```bash
# 天气：wttr.in，无需 API key，15 分钟刷新，天况自动译成中文
node dsh-bridge.mjs --weather 北京

# 歌词：任意命令，取 stdout 最后一行作为当前歌词（可接你自己的播放器脚本）
node dsh-bridge.mjs --lyrics-cmd 'mpc current'
```

可选：在文件顶部 `PRICING` 里填 DeepSeek 单价（美元/百万 token），
填了才会在屏幕上显示「预估花费」。

### 性能设计

DSH 的会话文件是**数千个独立 zstd 帧拼接**的（每次 flush 一帧），因此：

- **实时状态**：只读文件尾 256KB、从倒数第 24 个帧边界开始解码 → 一次约 30ms
- **今日 token 累计**：需要全量扫描，**每 60 秒**后台跑一次（不阻塞推送）
- ⚠️ 不要用 Node 内置的 `zlib.zstdDecompressSync` 解这个文件：
  它**只解第一个帧**（实测 256KB 输入只出 83 字节）。桥里用的是 `zstd -dc` CLI 流式解码。

---

## 五、屏幕上的内容

| 面板 | 内容 |
|---|---|
| **SYSTEM**（左，370px） | CPU 圆环、内存、负载 1/5/15、CPU 温度（有则显示）、主机名、运行时长 |
| **DEEPSEEK HARNESS**（中，1130px） | 项目名、`provider`/`turn`/`step` 徽章、**状态徽章**（工作中呼吸 / 等待输入闪烁 / 空闲）、当前活动（如「执行命令」）、工具名、最后一段回复、**任务进度 N/M + 分段进度条**、待办列表（最多 9 条） |
| **USAGE**（右，370px） | 今日 token（万/亿格式化）、输入/输出、上下文占用条与百分比、预估花费、大时钟、日期星期、天气/歌词（预留）、USB 与数据桥自检状态 |

数据来源与 DSH 事件的对应关系：

| 屏幕内容 | DSH 事件 |
|---|---|
| 会话/项目 | 目录 slug（`--storage-Users-...--` 反解）与 `session` |
| 状态/活动/工具 | `tool/call`、`turn/start`、`turn/end.reason.kind` |
| 最后回复 | `assistant/message` 的 text（去 Markdown） |
| token 用量 | `assistant/message.usage`（`inputTokens`/`outputTokens`/`cacheReadTokens`） |
| 上下文占用 | 最近一次请求的 `inputTokens + cacheReadTokens`；`compaction/prune` 时扣减 |
| 任务进度/待办 | `todo/write.todos[].status` |
| 模型/厂商 | `request/context`（全量扫描时抓取） |

---

## 六、真机排障

```bash
hdc shell hilog | grep TrofeoLCD          # 应用日志（含握手响应十六进制）
```

| 现象 | 处理 |
|---|---|
| 「未发现 USB 屏幕」 | 确认屏插在本机 USB 口（`0416:5408`）；本工程只认这两个 PID |
| 授权弹窗点了拒绝 | 界面上点**「连接屏幕」**重新授权（自动重试在被拒 2 次后会停止，避免反复弹窗） |
| 画面上下颠倒 | 界面上切换**「旋转180°」**开关（LY FBL192 默认为需要旋转，故默认开） |
| 画面被裁切/比例不对 | 看界面「输出帧」一行：应显示 `1920x462`。画布会按 JPEG 实际像素自动校正密度，正常 1–2 帧内收敛 |
| 推帧失败/设备掉线 | 日志看 `bulkTransfer` 返回码；应用会在 5 秒后自动重连 |
| 屏幕黑屏 | 固件空闲会清屏，确认应用在「运行中」且帧率非 0 |

已知限制：

- **天气/歌词**已接入但默认关闭（见第四节，加 `--weather` / `--lyrics-cmd` 开启）
- **预计花费**需要自己填单价，默认不显示
- 应用需在前台或允许后台运行才能持续推帧（建议在系统设置里给「DSH 副屏」开自启动）

---

## 七、工程结构

```
TrofeoLCD/
├── AppScope/app.json5                     bundle com.dsh.trofeolcd
├── build-profile.json5                    签名配置（当前为空，见第三节）
├── entry/src/main/
│   ├── module.json5                       权限：INTERNET / GET_NETWORK_INFO / KEEP_BACKGROUND_RUNNING
│   └── ets/
│       ├── common/Types.ets               遥测数据模型
│       ├── common/Theme.ets               配色与 5 列网格布局令牌
│       ├── common/Logger.ets              hilog 封装（TAG: TrofeoLCD）
│       ├── usb/LyProtocol.ets             LY 协议：握手 / 分块 / JPEG 尺寸解析
│       ├── usb/LcdUsb.ets                 usbManager 封装（端点发现、授权、bulkTransfer）
│       ├── render/Dashboard.ets           1920×462 仪表盘绘制
│       ├── bridge/TelemetryBridge.ets     UDP 遥测接收
│       ├── service/LcdService.ets         帧循环 + 画布尺寸自校正 + 自适应帧率
│       ├── pages/Index.ets                预览画布 + 状态 + 控制
│       └── entryability/EntryAbility.ets  入口（窗口常亮）
├── bridge/dsh-bridge.mjs                  shell 侧数据桥
└── tools/
    ├── preview.py                         布局镜像（开发期审图，输出 preview.png）
    └── layout_check.py                    布局自动审计（越界/重叠/撞分隔线）
```

### 两个值得留意的实现细节

1. **画布尺寸自校正**：鸿蒙 Canvas 的坐标是 vp、输出像素取决于设备密度，
   而设备要求精确的 1920×462。做法是先按猜测尺寸渲染一帧，
   从 JPEG 的 SOF 标记读出真实像素宽高，反推并修正画布 vp 尺寸，
   连续匹配后才开始推帧（校准帧不推给屏幕）。这样完全不依赖
   `display.densityPixels` 的准确性。
2. **自适应帧率**：agent 忙碌或等待输入时 15fps（让呼吸/闪烁动画流畅），
   空闲时 2fps（省电），与参考项目 mac-thermalright-ai-monitor 的策略一致。

---

## 八、在 MatePad Edge / 鸿蒙 PC 上验证（本次目标设备）

### 1. 连接设备（无线调试）

平板/PC 上：**设置 → 关于本机 → 连点版本号进入开发者模式 → 开发者选项 → 无线调试**
→ 记下 `IP:端口`，然后在本机：

```bash
hdc tconn <IP>:<端口>          # 例：hdc tconn 192.168.3.120:37911
hdc list targets               # 出现设备即成功
hdc shell param get const.product.name      # 确认机型
hdc shell param get const.ohos.apiversion   # 应为 26 左右
```

> USB 直连也行：`hdc list targets` 直接看得到设备。

### 2. 签名 → 安装

先在 DevEco 完成一次自动签名（第三节方式 A），之后 **签名材料就固定了**，
后续我可以直接在这台机器上用命令行出**已签名**的 HAP：

```bash
# DevEco 签名后，build-profile.json5 里会有 signingConfigs；
# 之后每次改完代码，命令行直接出签名包：
CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0
export NODE_HOME="$CLT/node/bin" DEVECO_SDK_HOME="$CLT/sdk" PATH="$CLT/node/bin:$PATH"
cd ~/WorkBuddy/TrofeoLCD
"$CLT/hvigor/bin/hvigorw" --mode module -p product=default assembleHap --no-daemon
# → entry/build/default/outputs/default/entry-default-signed.hap

hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -b com.dsh.trofeolcd -a EntryAbility
```

### 3. 验收清单

插上 LCD 后打开应用，**逐项对照界面上的状态行**：

| 检查项 | 期望 | 不符时 |
|---|---|---|
| USB 屏幕 | 显示 `Trofeo Vision ... (416:5408)` 且为绿色 | 未发现 → 换 USB 口 / 确认屏供电（必要时用带供电的 USB-C 扩展坞） |
| 设备信息 | `PM=… SUB=… FBL=192 1920x462` | 若是 `1280x480`/`1920x400`，说明 PM 消歧走到别的分支，把这一行发我 |
| 输出帧 | `1920x462` + 约 30–120KB | 分辨率不对 → 等 1–2 帧会自动校正；持续不对 → 发我这一行 |
| 帧率 / 已发送 | 空闲 2fps 上下，agent 干活时 15fps，计数持续增长 | 计数不涨 → 看「最近错误」与 hilog |
| 屏幕画面 | 三面板仪表盘；若上下颠倒 → 关掉「旋转180°」 | — |

抓日志（排障时把这段输出给我）：

```bash
hdc shell hilog | grep TrofeoLCD
```

其中握手那两行最关键：

```
握手已发送 2048 字节
握手响应 NNN 字节, [0..8]=03 ff 00 00 00 00 00 00 01
设备: PM=.. SUB=.. FBL=192 1920x462
```

### 4. 同时跑数据桥

```bash
cd ~/WorkBuddy/TrofeoLCD/bridge && node dsh-bridge.mjs
```

保持这个终端窗口开着即可（它只读本地文件，不联网）。

---

## 八之一、打印机（拓竹）面板

桥端 `--printer http://127.0.0.1:8790/api/state`（默认关）会把 `bambu-monitor` 的
打印机状态塞进同一份 UDP 遥测；鸿蒙版在右侧一列的下半部分渲染打印机卡片
（状态/进度/层数/剩余/ETA/喷嘴·热床·腔温/风扇/速度/AMS 托盘/HMS 告警），
没有数据时不拆栏、布局与旧版完全一致。离线造数：`--printer-fake run|idle|error|offline`。

- 真机验证：AMS 四色块位置与告警红字都按设计落点（见 `HANDOFF.md` 附二）
- 功能建议：`docs/功能建议清单.md`；清理提案：`docs/代码清理提案.md`

## 八之二、Windows 绿色单文件版（dshlcd.exe）

鸿蒙版之外的另一条腿：同一个屏、同一套协议，做成 Windows 上双击就跑的单文件 exe。

- 产物：`win/dist/dshlcd.exe`（约 107 KB，单文件，只依赖系统自带 .NET Framework 4.x，
  AnyCPU 在 x64 / ARM64 均可），完整文档见 **`win/README.md`**。
- 遥测、VM 画面、诊断/预览接口、横竖屏开关与鸿蒙版对齐；系统监控改为本机采样（少一个依赖）。
- 已在 **Windows 11 ARM64 虚拟机**里实测：自检 119/119、横竖屏渲染编码、
  HTTP 全套接口、从主机 livepad 抓 VM 画面、USB 枚举（无设备不崩）。
- **未验证**：真机 USB 推帧（屏没到）、画面观感（无视觉通道）。
- 构建/验证通道（主机 → VM 编译 → 回读日志）见 `tools/win.py`，
  环境能力与踩坑记在 `~/WorkBuddy/ENVIRONMENT.md` 第 11 节。

## 九、无硬件时期的布局审计

改完 `Dashboard.ets` 的坐标后，可以先在电脑上跑一遍自动审计，
不必等到插上屏幕才发现元素重叠：

```bash
cd ~/WorkBuddy/TrofeoLCD
python3 tools/preview.py tools/preview.png    # 生成布局预览图
python3 tools/layout_check.py                 # 自动审计
```

审计逻辑：复用 `preview.py` 的镜像绘制，但记录每个文字/线条的**真实渲染包围盒**
（PIL `textbbox` 实测，不是估算），然后检查四类问题：

1. 越出 1920×462 画布
2. 文字越出所属面板
3. 文字之间重叠（超过 6% 面积即报警）
4. 文字压到分隔线

**它已经抓到过一个真问题**：右上角状态徽章「● 工作中」与右列的进度数字「3/6」
重叠 42%——两者都右对齐、纵向范围相交。修法是把右列整体下移到 `y+104`
（避开徽章的 `y+52..y+86`），待办条数上限从 9 降到 8 以免撞底部分隔线。

⚠️ 注意 `preview.py` 是**手工镜像**，不是 App 的渲染代码路径：改了
`Dashboard.ets` 的布局必须同步改它，否则审计结论会失真。

---

## 十、1:1 仿真页（无硬件时看效果）

一条命令生成用**你此刻真实 DSH 数据**渲染的 1:1 画面：

```bash
cd ~/WorkBuddy/TrofeoLCD
python3 tools/make_sim.py --live --weather 北京      # 实时数据 + 天气
python3 tools/make_sim.py --data live.json          # 用指定遥测 JSON
python3 tools/make_sim.py                           # 内置示例数据
```

产出两个文件：

| 文件 | 说明 |
|---|---|
| `tools/preview.png` | **正好 1920×462** 的 1:1 画面（就是推给屏幕的那一帧的等价物） |
| `tools/sim.html` | 自包含仿真页（PNG 以 base64 内嵌，69KB，无外部依赖），带 **1:1 / 50% / 25% / 适应宽度** 缩放切换与拖动平移 |

浏览器直接打开仿真页：

```
file:///storage/Users/currentUser/WorkBuddy/TrofeoLCD/tools/sim.html
```

仿真页已用实时数据核对过：项目名、活动、工具、模型、主机名、token 数值
（`316025` → 显示 `31.6万`）都出现在画面上，六个强调色（DeepSeek 蓝 / 绿 / 青 /
蓝 / 橙 / 白）像素统计均正常。

> 若「任务进度」显示 `—`，是因为当前会话没有待办——DSH 只有在使用计划时才写
> `todo/write` 事件，不是渲染问题。

---

## 十一、DevEco 报「无法解析符号 $string:app_name / $media:layered_image」

**结论先说：这不是图标文件格式问题**，而是 **DevEco 的 Sync 没成功 → 资源索引没建起来**。
（与 `wiliwili/ohos/README.md` 第 4.1 节记录的是同一个问题，那里有完整解法。）

已核实的事实：

- `AppScope/resources/base/media/` 下 `foreground.png` / `background.png` 都是**合法 PNG，
  1024×1024 RGBA**，与 DevEco 原生工程 `MyApplication` 完全一致（wiliwili 用的是
  256×256，同样合法）
- `layered_image.json` 与 `MyApplication`、`wiliwili` 三个工程**结构完全相同**
- 用命令行构建**故意把 `app_name` 改错**，hvigor 立刻报
  `The resource reference '$string:app_name' is not defined` —— 说明工程本身是对的，
  符号能正常解析

所以症状出在 DevEco 侧的索引，按下面顺序解决：

### ① 用户主目录要有 `.npmrc`（最常见原因）

`hvigor ERROR 00303137：No npmrc file is matched in the current user folder`

在**用户主目录**创建 `.npmrc`（Windows 是 `C:\Users\<用户名>\.npmrc`）：

```
registry=https://repo.huaweicloud.com/repository/npm/
@ohos:registry=https://repo.harmonyos.com/npm/
```

本工程根目录也自带了一份 `.npmrc`，两处都放最稳。

### ② 让 Sync 能装上 `@ohos/hvigor-ohos-plugin`

`hvigor ERROR 00308019：pnpm install ... @ohos/hvigor-ohos-plugin Not Found - 404`

因为 hvigor 默认从 npmjs.org 拉，而该包只在华为源上。配好 ① 后重试即可。

### ③ 图标兜底（SDK 较旧时才需要）

工程已**同时**保留普通 PNG：`AppScope/resources/base/media/app_icon.png`。
若你的 SDK 不支持分层图标，把 `AppScope/app.json5` 改成：

```json5
"icon": "$media:app_icon"      // 原为 "$media:layered_image"
```

### ④ 仍提示 hvigor 版本不匹配

在 DevEco 里执行 **Sync**，让它按本机 DevEco 版本自动修正
`hvigor/hvigor-config.json5`。

### ⑤ 本项目特有：命令行构建缓存会污染 DevEco

本机用 hmos-clt 命令行构建时，`.hvigor/cache/project-config.json` 会记录
**本机专属的 SDK 路径**（`/data/service/hnp/hmos-clt.org/...`）。把这份缓存带到
DevEco 会导致 **Sync 失败**，而 Sync 失败的表现**正是**上面两个符号无法解析。

交付给 DevEco 前先清理：

```bash
./tools/clean_for_deveco.sh     # 删 .hvigor / entry/build / oh_modules / .bitfun
```

（本工程交付时已清理干净；每次我在这边跑完命令行构建后也会重新清理。）

---

## 十二、协议自检（可在电脑上运行 App 的真实代码）

`LyProtocol.ets` / `SelfTest.ets` 是纯 TS 语法，Node 22.6+ 的
`--experimental-strip-types` 可以剥离类型后**直接执行**——所以协议逻辑不必等插屏，
在电脑上就能测，而且测的是**真实 App 源码**，不是抄写的副本。

```bash
bash tools/run_selftest.sh     # 协议/校准/归一化/调度：38 项
bash tools/run_hw_test.sh      # USB 层（真实 LcdUsb 源码 + 仿真设备）：20 项
```

### USB 层测试（`tools/run_hw_test.sh`）

把**真实的 `LcdUsb.ets` 源码**放进 Node，配一个假 `usbManager` 和一个会重组 JPEG 的
仿真 LY 设备（HID + 厂商自定义接口 + 存储接口混在一起，与真机形态一致）。
失败语义严格照 SDK 文档（`bulkTransfer` 失败返回 `-1`，不是抛异常）。

覆盖 20 项，关键几条：

| 场景 | 断言 |
|---|---|
| 推帧往返 | 1200B 与 **600KB** 两档：把推出去的字节按 LY 规范重新解析（解码器在测试里**独立实现**，不复用被测代码），要求还原出**逐字节相同**的 JPEG |
| 分块头 | `magic=01FF`、`cmd=1`、`total=输入长度`、块序号连续 |
| 4 的倍数补齐 | `numChunks=3 → 补齐 4`；LY1 则 `cmd=2` 且不补齐 |
| 写分段 | 4096 字节分段、尾包 `min(2048,剩余)` |
| 握手 | 2048 字节 `[0]=02 [1]=FF [8]=01`；`PM=65 SUB=5 → 1920x462 rot=180°` |
| 断言点选择 | `claim=[1] iface1/class255 OUT=0x9 IN=0x81`（不被 HID/存储接口干扰） |
| 负返回值 | OUT 返回 `-1` → `sendJpeg=false`、`isOpen=false`、`closePipe` 被调用 |
| ACK 失败不致命 | IN 返回 `-1` → 仍算本帧成功，`ack` 记为"传输失败(-1)" |
| 异常路径 | 无设备/授权被拒/握手坏响应/未打开就推帧 —— 全部安全返回，不抛异常 |

**明确不覆盖**：真实 USB 驱动与 `usbManager` 服务端的实现细节 —— 那些只能靠真机。

> 这套测试当场抓到源码里的一个真问题：`LcdUsb.ets` 把纯类型 `ItfDesc`/`EpDesc`
> 当值导入了（ArkTS 能编译，但类型剥离后运行时并不存在），已改为 `import type`。

期望值来自 `tools/ly_reference.py`（照 `thermalright-trcc-linux` 的 `ly_lcd.py`
语义重写的**独立参考实现**），因此这组自检是把 ArkTS 实现去对齐参考实现，
而不是自己和自己比。当前 **38 项全通过**：

| 自检项 | 验证内容 |
|---|---|
| 分块流哈希 | 整条分块流的 FNV-1a 与参考实现逐字节一致（`1000 字节输入 → 2048 字节帧，FNV=3811976977`） |
| 块头字段 | `magic=01FF`、`<I 总长@2`、`<H 块长@6`、`cmd@8`、`<H 块数@9`、`<H 序号@11` |
| 尾块与补齐 | 尾块数据长 = `总长 % 496`；LY 块数补齐到 4 的倍数 |
| USB 写分段 | 4096 字节分段、尾包 `min(2048, 剩余)` |
| 握手解析(PM65/SUB5) | 真机 9.16 的响应 → `PM=65 SUB=5 FBL=192 1920×462 rot=180°` |
| 握手校验拒绝坏响应 | `resp[8]≠1` 必须返回 null |
| LY1 变体 | `cmd=0x02` 且不补齐 |
| 旋转规则 | 1920×480/SUB5→180°、1920×462/SUB3→0°、1280×480/SUB2→90° |
| JPEG 尺寸解析 | 画布自校正依赖的 SOF 解析 |
| PM→FBL 覆写表 | 65/66/68/69→192、63/64→114 |
| 端点发现(真实形态) | HID + 厂商自定义(class 255，EP 0x09/0x81) + 存储接口混合时，选中厂商接口 |
| 端点发现(vendor优先) | 厂商接口即使排在数组最后也优先 |
| 端点发现(无vendor) | 无厂商接口时取第一个双向接口 |
| 端点发现(缺IN) | 只有 bulk OUT 时判为不可用并给出原因 |
| 端点发现(无bulk) | 完全没有 bulk 端点时不选接口 |
| 端点发现(回退) | 厂商接口只单向时回退到双向接口 |

| 校准(密度1.5首帧收敛) | 首帧即匹配 → 立即可推帧 |
| 校准(密度2.0两帧收敛) | `2560x640px` → vp 修正为 `960x240` → 次帧收敛 |
| 校准(密度1.0两帧收敛) | `1280x320px` → vp 放大为 `1920x480` → 次帧收敛 |
| 校准(无效测量跳过) | `0` / `NaN` 不得改变状态 |
| 校准(异常值钳制) | 异常测量值被钳到 `3840x960` 上限 |
| 校准(目标1280x480) | 换设备（PM=68）时目标变小也能收敛 |
| JPEG 降质序列 | `0.9→0.75→0.6→0.45→0.4(下限)` |
| 归一化(字符串数字) | `"52.5"` → `52.5`（否则渲染会 toFixed 抛异常） |
| 归一化(越界钳制) | cpu 150→100、负数→0 |
| 归一化(null/无法解析) | `null`、`"abc"` 回退默认值 |
| 归一化(垃圾输入不抛异常) | 数字/字符串/null/数组/类型错位全部安全 |
| 归一化(待办) | 非数组→[]、缺 content 跳过、非法 status→pending、超 64 条截断 |
| 归一化(超长文本截断) | 5000 字符 → 2000 字符 |
| 帧率决策 | busy/waiting→66ms、idle→500ms、night→3000ms、出错→1000ms |
| 夜间窗口(跨午夜) | 18:30–09:00：19:00/03:30 命中，09:00 与 12:00 不命中 |
| 夜间窗口(同日/空窗口) | `start==end` 判为空，避免全天熄屏 |
| USB 退避(间隔) | 5 秒内不重试、到期重试、已打开不重试 |
| USB 退避(被拒停止) | 被拒 2 次后停止自动重试，手动点「连接屏幕」可恢复 |
| USB 退避(非授权失败) | 设备未插等失败不累加被拒计数 |
| 校准(不收敛兜底) | 连续 5 次不匹配后放弃精确校准，按当前尺寸强行推帧 |
| 校准(恢复精确) | 兜底后若尺寸匹配上，`attempts` 复位、精度恢复正常 |

> 端点发现、画布校准、遥测归一化这三个模块都单独抽成**纯函数**（与 `usbManager`、
> Canvas、网络解耦）就是为了能被这样测——它们的共同点是**出错就等于不出画面，
> 而现场极难判断**。

同一组自检也内嵌在 App 里：**启动时自动运行并显示在界面上（「协议自检」一行），
详情写入 hilog**。真机第一次运行时就能区分"协议代码有问题"和"USB/硬件问题"。

> 这组自检已经抓到过三个真问题（都在等硬件之前）：
> 1. `SelfTest.ets` 起初把 `parseHandshakeResponse` 当顶层函数导入，而它其实是
>    `LyProtocol` 的静态方法 → `does not provide an export named ...`
> 2. `EpDesc` / `ItfDesc` 是**类型**，类型剥离后运行时不存在，必须写成
>    `import type`，否则同样报导出缺失
> 3. 一条端点发现用例的**期望值写错了**（我以为测的是"无 vendor"，其实数组里带着
>    vendor 接口），反过来印证了"class 255 优先"这条规则确实生效
> 4. 归一化测试最初用嵌套对象字面量构造载荷，**ArkTS 直接编译失败**
>    （`arkts-no-untyped-obj-literals`），改用 `JSON.parse` 构造——这也更贴近真实
>    输入路径（UDP 收到的本来就是 JSON 文本）

### 布局压测矩阵

```bash
python3 tools/layout_check.py --stress
```

覆盖 6 类极端/真实输入：亿级 token、上下文超界、超长主机名、8 条长待办、
**真实长项目名（33 字符）**、全空数据、天气+超长歌词。当前全部干净。

这个矩阵抓到过 3 类**真机会直接看到的溢出 bug**（触发条件很现实）：

- **长项目名**（如 `IPTV-Scanner-Editor-Pro-HarmonyOS`）30px 等宽字体会越过左列、
  撞上右上角状态徽章甚至右侧 USAGE 面板
- **长主机名**与右下角「运行时长」正面重叠
- **长活动行**（如「等待你输入」重复）溢出到任务列表

修法是给 `Dashboard.ets` 加了 `fitText()`（按像素宽度二分截断 + 省略号），
并对项目名、活动行、工具名、主机名、状态 chip 行分别设了宽度上限。

> 同时发现**镜像与 ArkTS 漂移**：`preview.py` 有两处除法缺少 `memTotal > 0` /
> `contextWindow > 0` 守卫，而 `Dashboard.ets` 里是有的。App 一直安全，是镜像漏了
> ——已补齐，两侧现在一致。

## 十三、`usbManager` 语义核查（逐字对过文档）

这是唯一没被执行过、也最贵的一环，所以特意对着 SDK 的 `@ohos.usbManager.d.ts` 逐字核对，
发现两点：

**① 单次 bulkTransfer 有 200KB 上限**（含 pipe/endpoint/buffer/timeout），超出返回 `-1`。
本工程最大单次传输是 4096 字节（握手 2048 字节），**安全** —— 这条同时验证了 LY 分块设计。

**② 失败时返回 `-1`，而不是抛异常。** 这一点很关键：原来只把返回值当字节数，
一次驱动异常会被当成"发送成功"，于是**屏幕黑着、计数却在涨**，极难定位。
现在握手发送/响应、每段推帧、ACK 读取三处都显式判定负返回值：

```ts
if (wrote < 0) { Logger.e(`握手发送失败: ${wrote}（-1 = 驱动异常）`); return false; }
```

**分阶段耗时**（`/diag` 与界面都有）：

```
renderMs / encodeMs / pushMs      # EMA 平滑，用于定位瓶颈在哪一段
quality                           # 本帧实际 JPEG 质量（降质后 < 0.9）
```

底部状态行显示为 `USB ● 1280帧 12/28/45ms`（渲染/编码/推帧）。已用布局审计验过：
即使帧数 999999、耗时 8888ms 也不会撑破面板。

## 十四、远程预览（本沙箱读不到 hilog 的补救）

本沙箱执行 `hilog` **没有任何输出**（无权限读系统日志缓冲区），也就是说应用跑起来后
我无法自己看它的日志。为此应用会把**当前推给屏幕的那一帧**通过 localhost 暴露出来：

```
http://127.0.0.1:54546/              网页预览页（推荐：浏览器打开，带缩放与自动刷新）
http://127.0.0.1:54546/preview       同上
http://127.0.0.1:54546/frame.jpg     当前帧（就是推给 LCD 的等价物）
http://127.0.0.1:54546/status        状态 JSON（分辨率/体积/推帧数/设备/ACK/桥龄）
```

**网页预览页**是在平板浏览器里看清画面的最佳方式（比应用内预览大得多）：
自带「适应宽度 / 1:1 / 200% / 50%」缩放按钮、每 0.4 秒自动刷新，
底部实时显示分辨率、体积、推帧数、USB 状态、ACK、数据桥时效；
并按 `rotate180` 自动把画面转正显示。

**分阶段耗时**（`/diag` 与界面底部都有，真机实测）：
```
renderMs 4.4ms   encodeMs 45.2ms   pushMs（未接屏）
→ 渲染+编码 ≈ 49.7ms/帧 → 当前实现的理论上限 ≈ 20fps
```
瓶颈在 **JPEG 编码**（45ms），不在画布绘制（4.4ms）。
`toDataURL()` 走的是「canvas → base64 字符串 → 解码」，base64 往返是纯开销；
若要冲更高帧率，应改用 `getImageData → createPixelMapFromPixelsSync → ImagePacker.packToData`
（省掉 base64），或直接走 native（`OH_Drawing` + `OH_ImagePackerNative`）。

取帧脚本会顺带校验分辨率与体积限制：

```bash
tools/fetch_frame.sh
# 保存: .build-output/frame.jpg (NNN bytes)
# ✅ 有效 JPEG: 1920x462  ← 与设备要求一致
# 体积限制 650KB: ✅ 通过
```

于是"应用是否在跑""画布是否真渲染成 1920×462""JPEG 是否超限""是否在持续推帧"
这四件事在**没接屏幕**的情况下就能被外部确认。界面上的「远程预览」一行也会显示地址与帧数。

（只监听 127.0.0.1，不对外暴露。）

## 十五、真机排障时会看到什么

连接屏幕时，应用会把**完整 USB 描述符树**写进 hilog（`hdc shell hilog | grep TrofeoLCD`）：

```
[USB] 设备 Trofeo Vision ... | 厂商 ... | 序列号 ...
[USB] VID:PID=416:5408 bus=1 addr=3 class=0 sub=0 proto=0
[USB]   config[0] id=1 ifaces=2 maxPower=...
[USB]     iface[0] id=0 class=255 sub=0 proto=0 alt=0 eps=2
[USB]       ep[0] addr=0x9 type=2 dir=OUT maxPacket=512 interval=0
[USB]       ep[1] addr=0x81 type=2 dir=IN maxPacket=512 interval=0
[USB] 端点选择: iface0/class255 OUT=0x9 IN=0x81
[USB] claimInterface iface=0 ret=0
握手已发送 2048 字节
握手响应 512 字节, [0..8]=03 ff 00 00 00 00 00 00 01
设备: PM=65 SUB=5 FBL=192 1920x462 rot=180°
```

界面上的「端点」一行同时显示端点选择结果，不用翻日志也能看出选对了没有。

已确认 `SystemCapability.USB.USBManager` 存在于 SDK 的 **2in1 / tablet** 设备类
syscap 清单中（`ets/api/device-define/2in1.json`、`tablet.json`），即目标设备类可用。

## 十六、命令行构建（不会污染工程）

```bash
bash tools/cli_build.sh          # 在 $HOME/WorkBuddy/.trofeolcd-build 副本里构建
```

产物拷到 `.build-output/entry-default-unsigned.hap`，**源工程不被写入任何构建缓存**。

原因见第十一节第 ⑤ 条：直接在源目录构建会把本机 SDK 路径写进
`.hvigor/cache/project-config.json`，带到 DevEco 会导致 Sync 失败、进而
`$string:app_name` / `$media:layered_image` 报「无法解析符号」。
用这个脚本就从根本上避免了。

## 十五、重要：目标设备就是本机

```bash
$ param get const.product.name
HUAWEI MatePad Edge
$ param get const.product.model
QXS-W10          # deviceType=tablet, API 26
```

**这台运行 DSH 的机器本身就是 HUAWEI MatePad Edge**，也就是说 LCD 要插的设备就是本机，
不需要把工程送到别的机器去。这带来两个后果：

1. **安装必须经 hdc**（本机 `bm` / `aa` 在应用沙箱里被拒绝：`bm dump -a` 返回
   `failed to execute your command`）。本机的 hdcd 走 unix socket，外部不可达；
   本机自连需要**打开「无线调试」**，然后用
   `hdc tconn 127.0.0.1:<无线调试端口>`。
2. **本机可以完成签名，不需要 DevEco**（见下）。

### 本地签名已实测可用

`hap-sign-tool` 是原生二进制（不需要 JDK），而 hvigor 能解密 DevEco 生成的加密密码，
所以直接在命令行就能出**已签名且校验通过**的 HAP：

```bash
tools/build_signed.sh
# → .build-output/entry-default-signed.hap
# → hap-sign-tool verify-app → verify-app success
```

另外 `tools/make_oh_signed.sh` 会用 SDK 里的 `OpenHarmony.p12`（keystore 密码 123456）
+ `OpenHarmonyProfileRelease.pem` **自造 profile 并签名**，bundle 保持
`com.dsh.trofeolcd` 不变：

```bash
tools/make_oh_signed.sh
# → .build-output/entry-oh-signed.hap（release 类型、无设备限制、有效期一年）
# → verify-app success
```

这条路的成败取决于「设备是否信任 OpenHarmony 的 CA」。值得一试的原因：若信任，
就不必为每个 bundle 单独向华为申请证书，本机命令行即可出可安装包。

但**签名 profile 与 bundleName 强绑定**，所以 `build_signed.sh` 默认复用
`DeepSeekHarness` 的签名材料，并相应地把 bundle 名改成 `com.deepseek.harness`
（profile 为 debug 类型、绑定 2 个设备 UDID、有效期至 2027-08）。

于是有两条路：

| 路径 | 做法 | 代价 |
|---|---|---|
| **A. 独立应用** | 在 DevEco 里为 `com.dsh.trofeolcd` 点一次自动签名；之后证书落在 `~/Documents/ohos/config/`，**我就能在本机永久出签名包** | 需要你操作一次 DevEco |
| **B. 复用现有签名** | 直接 `tools/build_signed.sh`，立刻得到可安装的签名包 | bundle 变成 `com.deepseek.harness`，安装会**覆盖你现有的 DSH 启动器应用**（除非把副屏功能并进那个应用，做成一个应用两个页面） |
| **C. OpenHarmony 自签名** | `tools/make_oh_signed.sh` —— 用 SDK 自带的 OpenHarmony 证书 + 自造 profile 签名，**bundle 保持本工程的**（不影响任何现有应用） | 华为商用设备通常只信任华为签发的证书，成功率未知；但这一步零风险，值得一试 |

### 安装（前提：本机开启无线调试）

设置 → 系统 → 开发者选项 → **无线调试**（打开后会显示 IP:端口）。然后：

```bash
tools/install_local.sh --port <端口>     # 自动 tconn → 安装 → 启动 → 抓日志
tools/preflight.sh                       # 或先自检：设备/通路/产物/工程干净度/签名绑定
```

`install_local.sh` 不带 `--port` 时会**自动扫描本机端口**找 hdc。

## 十七、工具清单

| 工具 | 用途 |
|---|---|
| `tools/run_selftest.sh` | 在电脑上执行 App 的协议自检（真实源码，16 项 KAT） |
| `tools/ly_reference.py` | LY 协议独立参考实现，生成自检期望值 |
| `tools/cli_build.sh` | 命令行构建 HAP（副本内构建，不污染工程） |
| `tools/clean_for_deveco.sh` | 交付 DevEco 前清理机器相关缓存 |
| `tools/layout_check.py` | 布局自动审计（越界/重叠/撞分隔线） |
| `tools/preview.py` | 1:1 布局镜像渲染（可吃真实遥测 JSON） |
| `tools/make_sim.py` | 生成 1:1 自包含仿真页 `tools/sim.html` |
| `tools/build_signed.sh` | 构建**可安装的签名 HAP**（复用已有华为签名材料，副本内构建） |
| `tools/make_oh_signed.sh` | 用 SDK 自带 OpenHarmony 材料自造 profile 并签名（独立 bundle，零风险实验） |
| `tools/install_local.sh` | 本机安装 + 启动 + 抓日志（自动扫描无线调试端口） |
| `tools/preflight.sh` | 交付/安装前自检：设备、hdc 通路、产物、工程干净度、签名绑定 |
| `tools/fetch_frame.sh` | 从运行中的应用取当前帧并校验分辨率/体积（远程预览） |
| `bridge/dsh-bridge.mjs` | DSH 会话状态 → UDP 遥测数据桥 |
| `bridge/console-server.mjs` | **可视化 Agent 控制台**后端（import 插件 `session.mjs` 解析 + SSE + 副屏代理） |
| `web/console.html` | 控制台页面（三栏：会话/状态/副屏控制 ｜ Agent 时间线 ｜ 待办/用量/系统/工具/环境） |
| `tools/console.sh` | 控制台启停与自检：`start` `stop` `restart` `status` `url` `check`（17 项端到端） |
| `bridge/start.sh` · `stop.sh` · `status.sh` | 数据桥后台运行（PID 文件 + 日志） |
| `tools/signing_readiness.sh` | DevEco 签名前的逐项就绪检查 |
| `tools/fetch_diag.sh` | 取应用完整诊断（/diag、/probe） |

## 十八、可视化 Agent 控制台（浏览器里的 Agent 界面）

屏幕上的五格是"摘要"，完整过程在浏览器里看：`http://127.0.0.1:54550/`

```bash
bash tools/console.sh start      # 起控制台（后台，写 bridge/.console.pid + .console.log）
bash tools/console.sh url        # → http://127.0.0.1:54550/
bash tools/console.sh check      # 端到端自检（17 项，含 SSE / 画面代理 / 白名单 / 收件箱）
bash tools/console.sh stop
```

- **三栏**：左＝会话/状态/副屏画面/副屏控制；中＝**Agent 时间线**（你的指令 · 回复 · 思考 · 工具调用+参数+结果+耗时，
  按 `callId` 配对成一行）；右＝待办进度/用量与上下文/本机指标/工具分布/环境与链路。
- **副屏控制是真操作**：16 档主题、5 种背景特效、速度档位、竖屏/流水线/打印机格，
  经白名单过滤后代理到 App 的 `/set`（未知键一律丢弃）。
- **改动隔离**：解析逻辑直接 `import` 插件里的 `session.mjs`（**只有一份**，不存在两边走样）；
  不重启 DSH、不动 App、不动 `web/preview.html`。为什么要做成外部进程、指令框的现状与升级路径、
  两个实测踩到的坑（mtime 选会话被刷盘骗、多会话并发画面来回跳）见
  **[docs/可视化Agent控制台.md](docs/可视化Agent控制台.md)**。
