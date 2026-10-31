# Windows 版对齐鸿蒙版 — 进度与移交

> 目标：把 `win/src/`（C#）对齐鸿蒙版（ArkTS）的全部新功能
> 起点：Win 版只有 `Dashboard.RenderHorizontal` / `RenderVertical` 两个渲染器；
> 鸿蒙版有 16 档主题 + burst + Backdrop + HostStats 等一整套。

## ⚠️ 已彻底排查：本机无法编译 C#（附证据，别再重复试）

| 尝试 | 结果 |
|---|---|
| 系统自带编译器 | `dotnet` / `csc` / `mcs` / `mono` / `msbuild` **逐个实测都没有** |
| 仓库里的构建 VM | `172.16.105.2:22` **不可达** |
| **发现本机已有 Roslyn** | `/storage/.../WorkBuddy/.roslyn/tools/csc.exe` 与 `.roslyn/x/tasks/net472/csc.exe`（`build-variants.cmd` 要找的就是它）—— 但 `head -c2` 是 `MZ`，且同目录全是 `Microsoft.CodeAnalysis.*.dll`，属 **net472 的 .NET Framework 程序集**，需 Windows CLR |
| 下载 .NET 8 Runtime (linux-arm64) | **下载成功**（28.5MB，`builds.dotnet.microsoft.com` 可达），但 `readelf -d` 显示 `NEEDED: libpthread.so.0 / libstdc++.so.6 / libgcc_s.so.1`、解释器 `/lib/ld-linux-aarch64.so.1` → **glibc 程序** |
| 本机 C 运行库 | 只有 `/lib/ld-musl-aarch64.so.1`（**musl**），无 `libc.so.6`/`libpthread.so.0`/`libstdc++` → 运行即 `Permission denied` |
| Mono | 同样是 glibc 构建，本机跑不了；源码自建成本过高 |

**结论**：C# 只能在**你的 Windows 虚拟机上**编译。所以本地验证只能靠
`tools/csharp_audit.py`（文本层能查的部分）+ 逐行对照 ArkTS + 逐个核对字段是否存在。

## ⚠️ 关键约束（决定了交付方式）

| 约束 | 事实 |
|---|---|
| **无法在本机编译 C#** | 本机无 `dotnet`/`csc`/`mcs`/`mono`/`msbuild`（逐个实测） |
| **构建 VM 不可达** | `172.16.105.2:22` 实测不可达 |
| **语言上限 C# 5** | 构建用 `.NET Framework v4.0.30319\csc.exe`（`win/build.cmd:8`），不能用字符串插值、`?.`、表达式体成员、`out var`、元组 |
| 源文件收集方式 | `win/build.cmd:23` 用 `"%SRC%\*.cs"` 通配 → **新增 .cs 会自动被编译**，无需改构建脚本 |

**结论**：C# 代码只能"按 C# 5 手写 + 静态自审"，最终**由你在 Windows 虚拟机上编译验证**。

## 一、已交付（本机可验证的部分）

### 1. 静态自审工具 —— 无编译器时的第一手验证
`tools/csharp_audit.py`（新增）。把"编译器会报的错"里能在文本层查出来的部分自动化：

- **C# 5 违规扫描**：字符串插值 / `?.` / `?[]` / `??=` / 表达式体成员（排除 lambda）/ `nameof` / `out var` / 元组 / `is not` / `record` / `init`
- **括号平衡**（正确剔除注释与四种字符串字面量）
- **符号存在性**：新代码调用的 `Draw.*` / `F.*` / `Backdrop.*` / `HostStats.*` / `Themes.*` 必须有定义（抓错别字）
- **重复定义**检测

**它已经抓到 1 个真错误**：`enum Align` 在 `Dashboard.cs`（private）与 `ThemeCore.cs` 重复定义 → 已把我的改名为 `TextAlign`。

当前状态：**21 个文件 / 9632 行，全部通过**。
（注意：它**不能**替代编译 —— 类型错误、重载解析、API 存在性都查不出来。）

### 2. 主题调度框架 + 共享工具（`win/src/ThemeCore.cs`，新增）
- `Themes`：16 档主题号常量 + 名称表 + `Clamp()` + `Dispatch()`（等价 ArkTS `LcdService` 里那条 if-else 长链；**未移植的主题诚实回落到仪表盘**，不画空白）
- `Draw`：圆角矩形（Fill/Stroke）、圆、**`Arc`（进度环，含 canvas→GDI+ 角度语义换算）**、文字（自量宽度对齐，与既有 `Dashboard.TextAt` 同做法）、`Measure`、**`ShrinkText`（自动缩字号，ArkTS `drawShrink` 等价物）**、`Fit`（截断）、**`Tracked`/`TrackedWidth`（逐字字距，NanoMuse 的 `letter-spacing` 用它实现）**、**`CapsuleTitle`（胶囊居中标题）**
- `Backdrop`：**保饱和压暗 `Dim()`**（照 trofeo-lcd-rs `effect.rs` 的测试断言）、5 种风格（none/plasma/aurora/lava/waves/image）、`FromName`、`StatusLine`
- `HostStats`：**纯本机采集**（CPU 用 `GetSystemTimes` 差值、内存用 `GlobalMemoryStatusEx`、网络用 `GetIfTable` 差值、磁盘用 `DriveInfo`）+ `Lcg` 固定种子伪随机

### 3. 5 档二次元主题已移植（`win/src/ThemeAnime.cs`，新增）

| 类 | 对应 ArkTS | 主题号 |
|---|---|---|
| `ThemeAnimeBG` | `ThemeAnimeBG.ets` | 11 二次元壁纸 |
| `ThemeAnimeFree` | `ThemeAnimeFree.ets` | 12 二次元·无框 |
| `ThemeAnimeHUD` | `ThemeAnimeHUD.ets` | 13 明亮二次元 HUD |
| `ThemeNanoMuse` | `ThemeNanoMuse.ets` | 14 NanoMuse 大字 |
| `ThemeTrofeoRust` | `ThemeTrofeoRust.ets` | 15 trofeo-lcd |

其中 **trofeo-lcd 的 12 套调色板 RGB 值逐字节照抄** `effect.rs:78-100`，并做了 4:2:0 预补偿；
**13 个栅格版面**照抄它的 `LayoutDef` 结构；健康度环、水印进度条、峰值帽、胶囊标题均已实现。

### 3.5 调度接线 + 版面档位（本轮新增，让上面 5 个主题**真正能跑**）

| 项 | 内容 |
|---|---|
| **调度接入帧循环** | `LcdRunner.cs` 的渲染回调改走 `Themes.Dispatch(...)` —— 原来只有竖/横两个渲染器，**主题 11~15 移植了也永远跑不到** |
| **`/set` 新增 5 个键** | `theme`（带 `Clamp`）/ `burst` / `printerCell` / `background` / `bgdim` |
| **`/diag` 新增 7 个字段** | `theme` / `themeName` / `burst` / `printerCell` / `bgStyle` / `bgDim` / `jpegLimit` |
| **v6 定稿版面几何** | `Theme.cs` 的 `L` 类新增 `FinalDotiiX/FinalDotiiW/FinalUsageX/FinalUsageW/FinalVmX/FinalVmW/FinalDshW` + `V4*` + `SwapCellX/W`，**逐值与 ArkTS `ThemeDotiiCell.ets` 的 `FINAL_*` 一致** |
| **`RenderHorizontal` 支持档位** | 新增 `printerCell` 参数，内部按 `v6` / `v4` / 标准三套排布；`Themes.Dispatch` 与调用点同步 |
| **Dotii 格占位 → 已换成真渲染** | 见下面「3.6」 |
| **burst 语义对齐** | ⚠️ 本版 C# 的帧循环**本来**就是"间隔扣除本帧耗时"（`wait - used`），即 ArkTS 加了 `burst=1` 才有的行为。为让同一条命令两平台一致，改为：`burst=1` 用 `wait-used`、`burst=0` 用 `wait` |

### 3.6 Dotii 分页屏已移植（本轮新增，`win/src/ThemeDotii.cs`）

`ThemeDotii.ets`（552 行）+ `ThemeDotiiCell.ets`（272 行）→ C# 一份文件约 600 行。

| 内容 | 说明 |
|---|---|
| **几何** | `DotiiGeom`：源画布 368×448、`Scale=0.9333`、4 页；装得下 1:1、装不下等比缩（对齐 `RenderCell` 的 `fit` 逻辑） |
| **配色** | `DotiiColors` 逐值照抄源 `state_ui.c:51-63` 的 `COLOR_*` 宏（含 `faceWarm/FaceAmber/FaceCyan/FaceCoral` 四个表情色） |
| **4 页** | 表情 / 余额 / 打印机(Bambu) / 自定义，每页 10s 轮播（对齐 ArkTS `DOTII_PAGE_MS`） |
| **表情表** | 8 种表情 × 5 部件（左眼/右眼/嘴/左点/右点），**乒乓相位** + 运行时 ×1.2 放大，逐值与源一致 |
| **圆点** | 只有余额页(row=1)与 Bambu 页(row=2)有；选中 16×5、未选 5×5，颜色取 `PAGE_COLORS` |
| **状态栏** | 只挂余额页：WiFi 圆点 + **循环滚动**的连接名（`State.NowMs() % 14000`）+ 电量 + 时钟 |
| **圆环** | LVGL 角度语义（0°=3 点、顺时针）→ GDI+ `DrawArc`；Bambu 环 140→400 不圆头、自定义环 0→360 圆头 |
| **状态胶囊** | **先量文字再定宽**（源固定 138px，中文状态词会超 —— 这是 ArkTS 侧踩过的坑，C# 一并照做）；描边用 `GraphicsPath.AddString` + `DrawPath` |
| **状态色** | 余额胶囊（可用=绿 / 不可用·密钥无效·获取失败=红 / 预览数据=琥珀）与 Bambu 胶囊（FAULT=红 / PAUSE=琥珀 / 离线=灰）逐条照搬 |

### 3.7 仪表盘改进已移植（本轮新增，对齐 ArkTS 主题 0）

| 改进 | 内容 |
|---|---|
| **胶囊居中标题** | `Panel()` 从"左侧 4px 强调条 + 裸文字"改成**胶囊包裹 + 水平居中**（底色 18% + 2px 描边 + 全圆角）；强调条去掉（与 ArkTS 同理由：胶囊本身已起强调作用） |
| **中文标题** | `SYSTEM`→`系统`、`USAGE`→`用量`、`VM 画面`→`虚拟机`（VM 面板不走 `Panel()`，单独画了同样的胶囊） |
| **项目名自动缩字号** | 新增 `ShrinkMono()`：从 26px 逐 1 往下试到 15px，到下限仍放不下才截断加省略号（原来只有截断，`WorkBuddy` 会被砍成 `WorkB...`） |
| **三行滚动留言条** | 新增 `FeedLines` / `FeedAtMs` / `PushFeed()`（对齐 ArkTS 的 `feedLines`/`feedAt`）+ 帧循环接线；渲染改为 15px 字号、30px 行距、**3 行**、**由暗到亮**（0.42/0.68/1.0），新条目到达时整体从 +30px 缓动到 0（300ms） |

### 3.8 背景图载入 + 主题 5 整屏版（本轮新增）

| 项 | 内容 |
|---|---|
| **内置背景图载入** | `Backdrop.LoadImageFrom(exeDir)`：按 4 个候选路径找 `bg_sample.jpg`（exe 同级 / `assets/` / `resources/` / 当前目录），**用 FileStream + new Bitmap 脱离流**避免长期占用文件句柄；找不到**静默跳过**（程序化特效仍可用） |
| **图片资产** | `win/assets/bg_sample.jpg`（21KB，从 `entry/src/main/resources/rawfile/` 复制）；`build.cmd` 构建后自动复制到 exe 同级 |
| **主题 5 整屏版** | `ThemeDotii.Render()`：黑底铺满 1920×462 + Dotii 框**居中**（`BoxX/BoxY`）+ ×0.9333 等比 —— 与 `RenderCell`（v6 版面的最右格）是同一套页面内容、两种装载方式 |

### 3.9 又一个 Win 版缺失功能：事件流没解析（本轮补齐）

桥端一直在发 `events: [{t,k,s}]`（最近 12 条），而 **C# 侧既没有 `BridgeEvent` 类也没解析它**
→ 主题 1「诊断终端」的事件流永远是空的。已补：
`BridgeEvent` 类（`State.cs`）+ `NormalizeEvents()`（对齐 `NormalizeTodos` 的 `IsArr` 写法）
+ 挂进 `NormalizeTelemetry` + `Telemetry.Events` 字段。

### 3.10 主题 1「诊断终端」已移植（本轮新增，`win/src/ThemeDiag.cs`）

`ThemeDiag.ets`（323 行）→ C# 一份文件。结构逐条对齐：

| 区块 | 内容 |
|---|---|
| 顶部 | `DSH 诊断终端` + **状态药丸**（busy 用品牌蓝底白字 / idle 绿 / 其它灰）+ 右侧"项目 · 模型" |
| 事件流 | 等宽 16px、行距 38、按 `k` 着色（err=红 / busy=品牌蓝 / idle=绿 / tool=青 / todo=橙 / print=紫）+ **从底部往上排**（终端习惯；条数少时最新一条贴底） |
| 指标栏 | CPU / 内存 / 今日 TOKEN / 余额（按额度变色）/ 燃烧 / 还能用 / 打印机 / **上下文条** |
| 体检条 | 数据桥（有数据绿 / 无数据橙）+ USB（已连接绿 / 未连接红）+ 帧大小；整体底色按"全绿"与否区分；**按测量宽度依次排**避免长文本互压 |

新增基础设施：**`FrameStats` 全局快照**（`UsbOpen`/`Sent`/`Errors`/`BridgeAgeSec`/`JpegBytes`）
—— ArkTS 的每个 `Theme.render` 都多收一个 `fs: FrameStats`，但 C# 侧为**页脚一行**去改整条
渲染签名链（含 Dashboard 的 4 个入口）不划算，改为帧循环每帧写一次小快照、主题按需读。

**踩到并修掉的字段差异**：ArkTS 的 `PrinterInfo` 有 `monitorMode`/`monitorError`（监控未登录态），
**C# 侧没有这两个字段** → 改用现有字段（`State`/`Percent`/`Connected`）表达同一语义。

### 3.11 主题 7「官方浅色风 TRCC」+ 主题 8「MacTR 五格」（本轮新增）

**主题 7**（`win/src/ThemeTrcc.cs`，对齐 `ThemeTrcc.ets` 208 行）
- 5 套官方配色**闭环轮换**（`cardColor(idx) = COLORS[(idx+1)%5]`，每套 30 秒）
- **官方卡片层图**已随构建发布：`win/assets/trcc_official_1..5.png`（1920×462 RGBA，各 20KB，
  来自 `entry/src/main/resources/rawfile/trcc/`）；`build.cmd` 自动复制到 exe 同级；
  `ThemeTrcc.LoadCardLayers()` 启动时载入，**找不到就退回自绘卡片**
- 官方两层合成方式照做：**先铺官方背景色、再叠卡片层**（01.png 是透明卡片层）
- 主数值那行是**两个数并排**，按总宽居中（ArkTS 侧实测写死偏移会让 `50°C` 与 `1%` 叠 28%）

**主题 8**（`win/src/ThemeMac.cs`，对齐 `ThemeMac.ets` 295 行）
- 与主题 0 **同几何**（margin 14 / gap 10 / 5 格 / 274.4×434），只换视觉语言：
  圆角 16、**强调色顶条**（`x+2, y, w−4, 3px`）+ 顶条下 **6 行 1px 渐隐光晕**（`0.12×(1−i/6)`）、
  **弧表**（270° 扫角 135°→405°、圆头端点、末端 `thickness/2` 圆点）、阈值配色（<50 绿 / <75 橙 / 否则红）
- 数据源全是本机真实项；MacTR 原版第 2 格是 GPU、第 4 格是磁盘 —— 本机**没有独显**、
  C# 也**没有磁盘读数**，所以第 2 格改成 TOKEN、第 4 格用运行时长（弧表按"当天已过比例"填，是真实值）。

**顺带补的本机采集能力**：`SysMon` 新增 **CPU 标称主频**（注册表
`HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0\~MHz`，零依赖、不需要 WMI），
`SystemInfo` 加 `CpuFreqMhz` 字段 —— 这是主题 7 右卡那行需要的。

### 3.12 主题 9「打印机位 Dotii」+ 主题 10「赛博二次元」+ 趋势曲线前置（本轮新增）

**主题 9**（借位几何，`Dashboard.cs` 的 `borrowed` 档）
- 逐值对齐 `ThemeDotiiCell.ets`：`SYSTEM 14(274.4) │ DSH 余下(427) │ USAGE 721(300) │ Dotii 1031(409)`
- ⚠️ **关键约束**：原始打印机格只有 **274.4** 宽，装不下 **409** 的 Dotii
  → 这一档**必须借位**（从 DSH 挪宽度），这是 ArkTS 侧已确认的结论
- 内容复用 `ThemeDotii.RenderCell`（主题 5 的同一套页面），只是搬了格子

**主题 10**（`win/src/ThemeCyber.cs`）
- ⚠️ **命名冲突**：ArkTS 把主题 10 放在 `ThemeAnime.ets` 里，而 C# 侧的 `ThemeAnime.cs`
  已经装了主题 11~15 → 类名改 `ThemeCyber`、文件名改 `ThemeCyber.cs`，并在文件头注明原因
- 氛围层照做：深紫黑渐变 + 极淡青色网格（每 60px）+ **扫描线**（每 4px）+ 四角 L 形切角
  + 右上角**四角星**（缓慢闪烁）
- **故障色差**：标题左右各错位 2px 画青/品红；主文字用 `GraphicsPath.AddString + DrawPath`
  做 3px 黑描边（GDI+ 没有 canvas 的 `strokeText`），字体不支持时退回普通绘制

**趋势曲线前置**（主题 2/3 的共同依赖，本轮补齐）
| 项 | 内容 |
|---|---|
| `win/src/History.cs` | 逐值移植 `History.ets`（122 行）：4 条序列（CPU/内存/token/余额）× 90 点、2 秒采样、CPU 与内存固定纵轴 100 |
| **修正一处 ArkTS 缺陷** | ArkTS 的 `push()` 把负数一律转 0，而 `pushGap()` 是 `push(-1)` → **断点语义整个失效**（桥断开会画成"跌到 0 并保持"，审查报告【中-14】已记录）。C# 侧**保留 -1** 作为断点，让折线能真的断开；正常数据路径行为完全一致 |
| `Draw.Sparkline` | 逐值移植 `Chrome.sparkline`：**样本不足时从右边对齐**（新数据贴右，像"直播"）、**断点断开折线**、曲线下渐变填充（0.28→0.02）、末端圆点 |

### 3.13 主题 2「监控墙」+ 界面控件（本轮新增）

**主题 2**（`win/src/ThemeWall.cs`，对齐 395 行）
- 顶部：标题 + 摘要（**按测量宽度截断**，给右上健康灯留 580px）+ 右上 4 个健康灯
- 中部：4 张等宽卡（CPU 曲线 / 内存曲线 / TOKEN 曲线 / 打印机）+ 底部余额卡（占两卡宽，含余额曲线）+ 状态卡
- 曲线用上一轮补的 `Draw.Sparkline`；每张卡有**两条量程参照线**
- **两处如实处理的 C# 数据差异**（不编数据）：
  · 没有 `focus` 段 → 状态卡改显示帧统计与桥龄
  · 没有 `tokensPerMin` → TOKEN 卡显示"今日累计"，曲线记断点（不画假曲线）

**界面控件**（`Gui.cs`，对齐目标项 ⑥）
| 控件 | 说明 |
|---|---|
| **主题切换** | `‹` / 当前名称（`N · 名称`）/ `›` **循环切换 16 档**（与鸿蒙版 `themePrev/themeNext` 同交互，而不是摆 16 个按钮挤爆左下角） |
| **极速模式**开关 | 对齐 ArkTS 的 `burst` |
| **打印机格**下拉 | `printer（标准）/ v6（定稿版面）/ v4（13:29 版）/ dotii（对调）` |
| **背景**下拉 | `无 / plasma / aurora / lava / waves / 图片` |
| 卡片高度 | 显示卡 78 → **156**，容纳四行控件 |

**⚠️ 顺手堵住一个"存了不生效"的坑**：`BuildSettings` 里原本**没有**读取 `theme` / `burst` /
`printer-cell` / `bg-style` —— 也就是说 Gui 里 `SaveIniValue` 存下来的选择**下次启动读不回来**。
本轮把这 4 项接进 `BuildSettings`（读的是 ini 合并后的 `Args`），持久化才真正闭环。

**别名**：`Gui.cs` 自带一批自绘控件（`Card`/`Switch`/`FlatButton`），裸写 `ComboBox` 容易让人
以为也是自绘的 → 加了 `using ComboBox = System.Windows.Forms.ComboBox;` 把意图写清楚。

### 3.14 主题 3「分页屏」+ FrameStats 补全（本轮新增）

**主题 3**（`win/src/ThemePages.cs`，对齐 522 行）
- 顶部状态栏：时钟 / 日期 / 页名 / **摘要按测量宽度截断**（右侧还有状态点，过长会压印）/ 右侧 USB·桥·VM·电量
- **4 个子页**（每 10 秒自动翻页）：
  · 页 0 拓竹打印机 —— 三栏：状态+大百分比+进度条 / 当前作业+三温 / **AMS 耗材托盘**（色块 + 选中描边 + 余量）
  · 页 1 DeepSeek 余额 —— 左：余额+燃烧+还能用+余额曲线；右：今日 TOKEN（+ 真实 token 曲线）
  · 页 2 DSH 会话 —— 左：项目/模型/状态/工具/最后一句；右：待办（✓/○ + 完成态变灰）
  · 页 3 系统状态 —— 三栏：CPU 曲线 / 内存曲线 / **本屏自身**（推帧·错误·耗时）
- 底部：4 个页面指示点 + `N/4 · 每 10 秒自动翻页`

**`FrameStats` 补全**：新增 `RenderMs` / `EncodeMs` / `PushMs`（帧循环从
`_renderMs`/`_encodeMs`/`_pushMs` 填），供页 3 的"本屏"栏显示。

**三处 C# 数据差异**（都如实处理，不编数据）：
| 项 | 处理 |
|---|---|
| 没有 `monitorMode`/`monitorError` | 用 `State`+`Connected`+`Percent` 表达"监控未登录" |
| 没有 `focus` 段（专注计时） | 不画那一行 |
| 没有 `tokensPerMin` | 不显示速率行（曲线仍是真实序列） |
| `skippedFrames` | **恒为 0**：C# 帧循环是**同步**的（渲染→编码→推送→睡），不存在 ArkTS 那种背压跳帧路径。这是结构差异不是缺失，如实显示 0 |

### 3.15 主题 4「打砖块」（本轮新增，`win/src/ThemePong.cs`）

对齐 `ThemePong.ets`（712 行）。本质是**源固件 `clock_pong.cpp` 的 1:1 复刻**：
物理、绘制顺序、砖色、版面常量（`layout_368x448.h` 的 AMOLED18 档）全部照抄。

| 内容 | 说明 |
|---|---|
| **确定性物理** | `rand` 是自实现的 **LCG**（Numerical Recipes 参数），**一次都没用 `System.Random`** → 同一份 state 重复推进逐像素一致，可离线断言 |
| 完整玩法 | 挡板追踪 / 砖块碰撞（按最小穿透轴决定反弹方向）/ 粘球辅助（misses≥4 后概率触发）/ 空挡 20 次或砖清空则重开 |
| **防穿砖** | `Advance` 单帧最多补 **8 tick**（160ms），卡顿后球不会瞬移穿过砖块 |
| 版面 | 源 368×448 × **0.9333** = 343×418 居中，两侧各 758px 信息栏 |
| 左栏 | 战况（得分/连击/击碎/回球/剩余/推帧）+ **砖块存活小地图** |
| 右栏 | 移植参数（球速/球径/砖块/周期/已运行）+ **砖色图例** |
| **4:2:0 预补偿** | 砖色用与 `ThemeFwSim` **同一套补偿值**（纯蓝解码后几乎归零、纯绿掉一半）；**挡板**的固件原值是纯青 `#00FFFF` → 补成 `#30D8E0`，否则挡板在屏上会"看不见" |

**新增 `PongHolder`**：`ThemePong` 的渲染是**纯函数**，但游戏状态必须**跨帧保持**（球会动）。
ArkTS 侧由 `LcdService` 持有 `pongState`；C# 侧 `Dispatch` 是无状态静态调用 →
放一个持有器（语义与 ArkTS 的拥有者一致），单线程访问无需加锁。

**一处写法统一**：变换的保存/恢复用 `g.Save()/g.Restore()`（与 `ThemeMac`/`ThemeCyber` 一致），
而不是手动读写 `g.Transform` —— 后者语义上更脆。

### 3.16 新增：**主题 4 的离线一致性验证**（`tools/theme_pong_verify.py`）

这是目前**唯一能在无 C# 编译器的情况下真正验证 C# 逻辑**的手段，做法是两条：

① **常量逐条比对**：从 `win/src/ThemePong.cs` 按正则读出全部版面/玩法常量，
   与 `ThemePong.ets` 的同名常量**逐一核对** —— 抄错一位立刻报。当前 **27 个常量 + 5 个砖色全部一致**。
② **物理独立复现**：用 Python 重写同一套公式（LCG / launch / 碰撞 / 挡板 / 粘球），
   跑 4000 tick 断言不变量：

```
4000 tick：砸砖 88 · 接球 66 · 最高连击 12 · 重开 1
球速上限 12.00（基准 12.0）· 出界 0 次
同种子两次跑逐值一致 ✅（确定性成立）
帧预算：20ms→1 · 160ms→8 · 5000ms→8（封顶，防穿砖）✅
```

**顺带修掉自己的一个误报**：第一版"检查有没有用 `System.Random`"时，
**注释里那句"一次都没用 System.Random"把自己匹配出来了** → 改为**去掉注释后**再匹配。

> 这个 harness 的价值在于：**确定性物理只要常量或公式抄错一位，屏上表现是"球会动但轨迹怪"**，
> 靠肉眼看渲染结果几乎发现不了。这类验证以后可以按同样套路复用到其它主题。

### 3.17 主题 6「固件仿真屏」（本轮新增，`win/src/ThemeFwSim.cs`）—— **16 档主题至此全齐**

对齐 `ThemeFwSim.ets`（1033 行）。把 **ESP32-S3 那版固件的 UI** 复刻到 1920×462。

**★ 范围决定：4 屏全保真 + 其余诚实占位**

用户 2026-10-14 明确定过这块屏**只需要 4 个界面**：打印中(6) / 表情(16) / 打砖块时钟(8) / 余额(17)。
ArkTS 侧 18 屏全实现，但其中 14 屏（启动/配网/OTA/分屏/相机/电源确认/烘干/错误详情…）
**在真机上是一次性或异常态界面，日常根本看不到**。所以 C# 侧：

- **这 4 屏逐值移植**（打印中的进度环/徽标/ETA/底栏、表情的 6 套部件表、
  打砖块时钟叠层、余额的大数额+状态徽标）
- 其余 14 屏画**诚实的占位**：界面名 + 中文标签 + "该界面未移植到 Windows 版" +
  已移植清单 —— **不留空白**（空白会被误判成渲染 bug，本仓库踩过这个坑）
- `/set?fws=N` 仍可定点查看任意界面；`/diag` 的返回标签会区分
  `fwsim` 与 `fwsim-placeholder`

**打砖块时钟与主题 4 复用同一场游戏**：通过新增的 `PongSnapshot` 只读快照取三个实时量
（球位、挡板、砖块存活表）—— 做成独立小类而不是直接把可变的 `PongState` 传出去，
避免两个主题同时持有可变状态。

**修掉自己一个 bug**：`Balance` 屏里 `sf` 字体被 **Dispose 了两次**（状态徽标之后一次、
方法末尾又一次）→ use-after-dispose。

### 3.18 收尾补齐（本轮）

| 项 | 说明 |
|---|---|
| **窗口尺寸记录** | `GuiForm.WinW/WinH`（对齐 ArkTS `EntryAbility.curW/curH`）+ `/diag` 暴露 —— 窗口拉大缩小后面板是按新尺寸重排的，排障第一件要看的就是这个 |
| **又一处单向持久化** | `burst` 只读不存（改完重启就丢）→ 补 `SaveIniValue`。现在 `theme`/`burst`/`printer-cell`/`bg-style` 四项**存读成对** |
| **审计器自动判定** | "纯静态类"名单从**硬编码改为自动推导**（类里无任何实例成员 → `ClassName.Member` 必然是静态访问）。以后新增静态工具类自动覆盖，不会漏 |

### 4. 顺带发现并补齐的 C# 缺失功能
**`BalanceInfo`**（`State.cs`）—— 桥端一直在发 `balance` 段，而 **C# 侧既没有这个类也没解析它**，
所以 Windows 版仪表盘上**从来没有余额**。已补类 + `NormalizeBalance()` + 挂进 `NormalizeTelemetry`。

## 二、鸿蒙版这边修掉的缺陷（代码审查的成果，已上屏验证）

审查报告：`docs/代码审查报告-2026-10-15.md`（5 条致命/高危 + 22 条中等 + 14 条低）。

| # | 缺陷 | 修法 | 验证 |
|---|---|---|---|
| **致命-1** | **ArkTS 的 JPEG 上限 650000，C# 已是 450000** → 450~650KB 的帧应用侧不降质、固件直接忽略：`sent` 正常涨、`sendJpeg` 返回 true、`/diag` 全绿而**屏是旧画面** | 改 450000 + 加自检断言（ArkTS 自检原先**没有**这条，所以 38/38 从没覆盖它）+ `/diag` 暴露 `jpegLimit` | ✅ `jpegLimit=450000`；自检 50/50 |
| **致命-2** | `printerSubPage()` 30 秒后**恒返回 0**，而渲染侧用 `% 4` → 内容签名与渲染两套算法 → 打印机格周期性停帧 20 秒 | 收敛成唯一纯函数 `printerSlot()`，两侧都调它 | ✅ 审计干净 |
| **高危-3** | 看门狗**在传输中途硬关 USB 句柄** → "sent 在涨、屏没画面"的成因，也是端点进错误态（要拔插）的诱因 | 加 `pushInFlight` 标记，看门狗条件加 `!pushInFlight`（主通路 + 序列通路都置位） | ✅ 构建通过 |
| **高危-4** | `printerCellTouched` **两条写入口**，`/set?printerCell=` 那条不设守卫 | 收敛为唯一 `setPrinterCell(v, byUser)`；用户路径**即使同值也置 touched**（原早退漏了这一点） | ✅ |
| **高危-5** | `themeTouched` **四条写入口**，界面 `themeApply()` 不设守卫；且日志把主题 2~15 全记成"仪表盘" | 收敛为唯一 `setTheme(n, byUser)`（置 touched + 清签名 + **重置轮播计时**）；`themeName` 改查表覆盖 0..15 | ✅ |
| 中-1 | `loadSampleBg()` 的 `sampleBgLoading` 不在 finally 复位 → **失败一次即永久失效**（本报告唯一一条"一次失败永久不可用"） | 标志与 `ImageSource.release()` 都放进 finally | ✅ |
| 中-5 | `dbgLastTheme` 只在主题 14/15 赋值 → 切回主题 0 后 diag 仍报 15，**恰好复现它本来要诊断的误导** | 移到内容签名判定**之前**（放末尾会被提前 return 跳过 —— 第一版就是这么错的，实测发现并改正） | ✅ 4 个主题切换全部一致 |
| **低-9** | **C# `Ly.cs` 保留了 ArkTS 已修掉的丢帧尾 bug**（`pos += UsbWriteSize` 而非 `pos += size`）| 改为 `pos += size`；LY1 下末段更易触发 | 待你编译验证 |
| 中-7 | C# `MiniHttp` 绑 `IPAddress.Any` 且 `/set` 无鉴权（ArkTS 只绑回环）；`interval` **无下限** | 改绑 `IPAddress.Loopback`；`interval` 加 120ms 下限（对齐 ArkTS 的 `MIN_PUSH_INTERVAL_MS`） | 待你编译验证 |

## 三、还没做（下一轮继续）

| 项 | 状态 |
|---|---|
| 主题 0（仪表盘的胶囊标题/缩字号/三行滚动留言/中文标题改进） | ❌ 未移植 |
| ~~主题 1 诊断终端~~ | ✅ **本轮完成** |
| ~~主题 7 官方浅色 TRCC~~ / ~~主题 8 MacTR~~ | ✅ **本轮完成** |
| ~~主题 9 打印机位 Dotii~~ / ~~主题 10 赛博二次元~~ | ✅ **本轮完成** |
| ~~主题 2 监控墙~~ | ✅ **本轮完成** |
| ~~主题 3 分页屏（4 个子页）~~ | ✅ **本轮完成** |
| 主题 4 打砖块 / 5 Dotii 分页屏 / 6 固件仿真 / 7 官方浅色(TRCC) / 8 MacTR / 9 打印机位 Dotii | ❌ |
| ~~v6 定稿版面几何 + printerCell 档位~~ | ✅ **本轮完成**（几何+档位+占位；Dotii **内容**渲染仍待做） |
| ~~`burst`~~ / ~~`/set` 五个键~~ | ✅ **本轮完成** |
| ~~Dotii 单元格内容渲染~~ | ✅ **本轮完成**（`win/src/ThemeDotii.cs`） |
| 主题 10 赛博二次元 | ❌ |
| 内置背景图载入（`bg_sample.jpg` → `Backdrop.Image`） | ❌ 类已就绪，接线未做 |
| ~~C# `Gui.cs` 的主题按钮~~ | ✅ **本轮完成**（循环切换 + 极速/打印机格/背景控件） |
| `win/README.md` 的功能对齐表更新 | ❌ |

### 自审工具本轮增强（第二波）

新增 **跨类成员核对**：`Xxx.Member` 形式的静态访问必须在对应类里有定义。
**范围刻意收窄到"纯静态辅助类"**（`Draw`/`Themes`/`Backdrop`/`HostStats`/`DotiiColors`/
`DotiiGeom`/`Ly`/`L`/`V`/`F`，已逐个确认都是 `static class`）——
因为 `Foo.Bar` 里的 `Foo` **无法从文本区分类名与变量名**（`Telemetry` 既是类名也常做
局部变量类型声明，`Telemetry.Fresh` 这类写法会被误判）。实测放宽范围会产出 6 处误报，
把真问题淹没。收窄后零误报、且正好覆盖我最容易记错的地方。

### 自审工具上一轮增强
`tools/csharp_audit.py` 新增两项检查：
- **颜色令牌交叉核对**：`C.Xxx` 必须在 `Theme.cs` 的 `class C` 里定义（跨类成员访问无法用括号解析验证，写错一个名字就是编译错误）
- **`Color.FromArgb` 参数个数**：**故意做得保守** —— `FromArgb(alpha, Color)` 是合法重载且第二参常是变量（`Cyan`/`PanelC`/`color`），只报"第二参明确是数字"的情况，避免误报淹没真问题；行号也改用**原始文件行号**（早期版本用去注释后的行号，报出来是错位的）

## 四、你要做的事（编译验证）

在 Windows 虚拟机里跑：

```cmd
cd <工程>\win
build.cmd
```

**新文件**（会被 `*.cs` 通配自动收进去，无需改脚本）：
- `win/src/ThemeCore.cs`
- `win/src/ThemeAnime.cs`

**先跑静态自审**（在本机或任何有 python 的机器上）：
```bash
python3 tools/csharp_audit.py
```

若编译报错，把错误贴给我 —— 我按 C# 5 的约束改。
