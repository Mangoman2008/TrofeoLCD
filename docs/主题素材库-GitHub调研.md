# 主题素材库 — GitHub 同类项目调研（Trofeo Vision 9.16 / 1920×462）

> 落盘时间：本会话。目标读者：TrofeoLCD 的后续开发。
>
> **一句话结论**：可直接抄的东西有三类 ——
> ① **长条屏的"卡片横排"语法**（MacTR 的 5 格 + 强调色顶条，最贴 1920×462）；
> ② **成套配色**（MacTR 26 色令牌、sensorpanel 两套主题、trofeo-lcd-rs 的 8 套频谱 + 11 套背景调色板）；
> ③ **保活与调度手法**（trcc 的 `volatile` 重发 150ms、sensorpanel 的"丢帧不排队"、MacTR 的三角波呼吸）。
>
> **不要抄的东西**：sensorpanel README 宣传的 "Regional USB updates"（局部刷新）—— 它自己的代码
> 明确拒绝给 LY 面板用（见 §4 第 19 条）。这块屏只能整帧 JPEG。

---

## §0 取证方法与环境限制（先读，影响可信度判断）

本次调研**全部结论来自本机已克隆的仓库源码**，逐条给了 `文件:行号`。方法与限制：

| 项 | 状态 |
|---|---|
| **shell（bash）** | **不可用**：`spawn EPERM`（连 `ls`/`true` 都起不来）。所有命令都**没有**在本机执行过。 |
| 文件工具 | `read` / `glob` / `grep` 可用（`glob`/`grep` 偶发 `ripgrep launch failed`，重试即恢复）。 |
| GitHub 联网 | 本机 **GitHub 被 DNS 污染**（见 `docs/明早简报-20261014.md:31`）。`web_search` 只返回了标题级结果，**没能取到 star 数/发布时间**。 |
| 仓库来源 | `~/.cache/trcc/repos/` 下 5 个仓库，**均无 `.git/` 目录**，因此**无法给出提交日期**，只能用仓库内的版本号文件推断新鲜度。 |
| 未读到的仓库 | `thermalright-trcc-linux` 只读了主题/发送/解码相关子集；`MacTR` 与 `mac-thermalright-ai-monitor` 只读了渲染与 AppState；**其余大量文件未复核**（见 §6）。 |

已克隆仓库（绝对路径）：

```
~/.cache/trcc/repos/thermalright-trcc-linux      # Python，TRCC 的 Linux 重实现（含反编译审计）
~/.cache/trcc/repos/sensorpanel                  # Go，唯一实测 24fps 的项目
~/.cache/trcc/repos/trofeo-lcd-rs                # Rust，9.16 专用
~/.cache/trcc/repos/MacTR                        # Swift/macOS
~/.cache/trcc/repos/mac-thermalright-ai-monitor  # Swift/macOS，MacTR 的 AI-agent 分支
```

---

## §1 同类项目清单

**star 与最近更新列全部"未取得"** —— 本机 GitHub 被 DNS 污染、仓库无 `.git`，我拒绝编造这两个数。
"新鲜度证据"列给出仓库内可核实的版本/日期线索。

| 仓库 | 语言 | 界面形态 | 有无可复用主题 | star | 最近更新 | 一句话点评 |
|---|---|---|---|---|---|---|
| [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) | Python 3（hexagonal） | 桌面 GUI（PySide/Qt）+ 95 个 CLI 命令 + 78 个 REST 端点 + IPC 守护 | **有**，且是**唯一带完整主题发行包**的：`src/trcc/data/theme*.7z` 共 **33 个分辨率包**，含 `theme1920462.7z` | 未取得 | 仓库内自称 v**9.3.3**、5603 测试 / 102 文件（`doc/DEVELOPMENT_STATUS.md:5-7`） | LY 协议的**权威参考**；主题包是现成的 1920×462 素材金矿，但只有 7z、要自己解 |
| [sensorpanel](https://github.com/oae/sensorpanel) | Go | CLI 常驻 + 本地 Management Studio（浏览器）+ 可换 renderer（headless Chrome / native JSON） | **有**，3 套：`themes/trofeo`、`themes/caelestia`、`themes/neonpulse` | 未取得 | `CHANGELOG.md:22` → v**1.1.0**（2026-01-31） | 唯一**实测 24fps / 空闲 0.45% CPU** 的实现（`docs/performance.md:70-79`），工程手法最值得抄 |
| [trofeo-lcd-rs](https://github.com/haven80/trofeo-lcd-rs)（fork 自 [sukualam/trofeo-lcd](https://github.com/sukualam/trofeo-lcd)） | Rust | 无 GUI，**直接画在屏上**（音频频谱 + 系统信息 + 像素小游戏） | **有调色板无布局**：8 套频谱调色板 + 12 套背景调色板 + 13 个预设布局名 | 未取得 | `Cargo.toml:3` → **1.0.50** | 唯一把"**这条屏当画布**"做到极致的：48 根 EQ 条 + 12 套渐变 + 像素游戏，且**空闲降到 2fps** |
| [MacTR](https://github.com/beret21/MacTR) | Swift（macOS 菜单栏 App） | 菜单栏 App + 屏上 5 格仪表盘 | **有设计系统**：26 色令牌 + 5 格布局常量（`DesignTokens.swift`） | 未取得 | `appcast.xml:10,28` → v**1.3.16**（2026-08-02） | **与我们的仪表盘最像**：同样是"色条 + 环表 + 右对齐数值 + 阈值变色"，可直接对标 |
| [mac-thermalright-ai-monitor](https://github.com/…/mac-thermalright-ai-monitor) | Swift（macOS） | 菜单栏 App + **AI agent 用量面板** | 23 色令牌（比 MacTR 少 3 个）+ 状态徽章动效 | 未取得 | 无版本文件可读（未复核） | **它的"agent 状态徽章"三态动效就是我们要的**：工作中呼吸 / 待授权硬闪 2Hz / 空闲静色 |

**五者分工**：trcc 给**协议与主题素材**，sensorpanel 给**性能工程**，trofeo-lcd-rs 给**调色板与画布语法**，
MacTR 给**仪表盘设计系统**，mac-thermalright-ai-monitor 给**agent 状态动效**。

---

## §2 12 套可落地界面规格

> 结构约定：**来源**（`文件:行号`）→ **画了什么 + 布局/坐标** → **配色（hex）** → **对 1920×462 的适配建议**。
> 坐标系凡是源码里写明的都照抄；凡是我按公式算出来的都标「实测值＝算得」。

### T1 Caelestia 卡片流（竖装原生主题）

- **来源**：`~/.cache/trcc/repos/sensorpanel/themes/caelestia/native.theme.json`（全文 491 行，逐个 widget 给了 rect）
  配色另见 `themes/caelestia/caelestia-palette.json`
- **画布**：`462×1920`，`layout: freeform_v2`，背景是**壁纸图** `assets/wallpaper.jpg`（`native.theme.json:15-19,25-28`）
- **元素与坐标（完整）**：
  - `wallpaper-scrim` 全屏 `0,0,462,1920`（`:44-46`）
  - `hero-card` `18,18,426,300` 圆角 48（`:50-51`）
  - 圆球 `hero-orb` `318,42,102,102` r=51 + 内芯 `hero-orb-core` `346,70,46,46` r=23（`:56-63`）
  - `brand` 文字 `42,44,250,28` 字号 18；`clock` `40,84,280,92` **字号 76**；`date` `44,184,360,34` 字号 22（`:66-85`）
  - 两枚药丸：`host-chip` `42,246,168,44` r=22、`status-chip` `224,246,194,44` r=22，内文 16 号居中（`:88-110`）
  - `cpu-card` `18,386,205,350` r=40 ↔ `gpu-card` `239,386,205,350` r=40（`:120-130`）
    内文：标签 18 号 → **大数值 56 号** `40,458,160,72` → 温度 20 号 → 条 `42,580,157,14` r=7 → 曲线 `42,626,157,72` `history_seconds: 90`（`:132-213`）
  - `memory-card` `18,762,426,250` r=44：百分比 **60 号**、条 `42,914,378,16` r=8、DIMM 药丸 `42,950,378,38`（`:216-269`）
  - `storage-card` `18,1038,426,260` r=44：磁盘名 20 号 + 百分比 **44 号右对齐** + 条 `44,1232,374,18`（`:271-314`）
  - `network-card` `18,1324,426,252` r=44：折线 `44,1402,374,58` + 上下行药丸 `42/242,1480,178,64` r=28（`:316-376`）
  - `details-card` `18,1602,426,296` r=44：CPU/GPU 型号行 + 三枚药丸 `42/173/304,1780,116,78` r=26（`:378-489`）
- **配色**：`#0a0f0f` 底 / `#0a0f0fcc` 遮罩 / `#0d4845` / `#0e1514` / `#131b1a` / `#192120` / `#255369` /
  `#255b58` / `#27403e` / `#3f4a49` / `#9bd0cc` / `#a2adac` / `#a9c5c2` / `#b0ccc9` / `#b6e3fe` /
  `#b8ede9` / `#d5efff` / `#dce8e6`；透明度变体 `#dce8e622`、`#0d484566`
- **性能档**：`power-saver`，`target_fps/active/idle = 1/1/1`，`idle_timeout 20s`，**`jpeg_quality: 78`**（`:30-39`）
- **适配 1920×462**：
  竖装的单列卡片流→**改成 4 卡横排**：hero 占 `x=14..560`（546 宽），后面 3 张卡各约 `x=572/1014/1456`、宽 `~430`。
  时钟 76 号在 462 高里只够放一行，**降到 54~60 号**；圆球（102→80）与药丸（44→36 高）等比缩。
  大数值 56 号在 434 高（462−2×14）的面板里放得下（56+标签26+条16+留白 ≈ 200），**不用改字号**。
  壁纸 + `#0a0f0fcc` 遮罩这套可直接搬 —— 我们已经有 `Chrome.background()` 支持自定义底图。

---

### T2 NeonPulse 霓虹脉冲（横向 2×2 硬网格）

- **来源**：`~/.cache/trcc/repos/sensorpanel/themes/neonpulse/src/App.css` + `src/App.tsx`
- **画布**：`480×320`（`App.css:7-11`）；`App.tsx:60` 用 `.dashboard` 网格
- **布局**：`grid-template-columns: 260px 1fr`，两行 `auto 1fr`，`gap: 4px`，`padding: 4px`（`App.css:37-45`）
  - **左上 device 面板**：`Device Name:` 11 号灰 → 主机名 16 号粗白 → `Online` 11 号绿 + `↓/↑` 速率（下 9 号青/橙）
    → 底部存储列表（行高 5px 条、标签 50px 固定、百分比 28px 右对齐）
  - **右上 CPU**：CPU 名 10 号粗 → **70×70 温环 + 右侧统计行**
    环的几何：`viewBox 0 0 100 100`，`cx=cy=50`，`r=40`，`stroke-width: 7`，`transform: rotate(-90deg)`，
    `strokeDasharray={temp/100*251.2} 251.2`（`App.tsx:103-110`，251.2 = 2π·40）
  - **左下 GPU**：名称 10 号 + 环 + 6 行统计（Load/Clock/Mem Clock/VRAM/Fan/Power）+ 折线图（`min-height: 50px`）
  - **右下 Memory**：标题 10 号 + `DDR5-6400 | N GB` 9 号 + **4 个 DIMM 圆**（40×40 圆、active 橙红渐变 + 琥珀边、inactive 灰）
    + Usage 条（6px 高） + Used/Free 明细
  - 统计行网格：`grid-template-columns: 55px 58px 1fr`，字号 9px，条高 6px、r=3
- **配色**：
  - 背景渐变 `linear-gradient(135deg, #1a1a3e 0%, #2d1b4e 30%, #1e3a5f 60%, #0d4d4d 100%)`
  - 面板 `rgba(30,20,50,.7)` + 边 `rgba(100,80,150,.5)` + r=4
  - 文字 `#fff` / `#aaa` / `#ccc` / `#888`；错误 `#ff6b6b`
  - 在线 `#4ade80`；下行 `#06b6d4`；上行 `#f97316`
  - 存储条 `#3b82f6→#8b5cf6`；内存条 `#06b6d4→#3b82f6→#8b5cf6`
  - 环：CPU `#ff8c00`、GPU `#ff6b35`、环底 `rgba(100,100,100,.3)`
  - 四种统计条：blue `#3b82f6→#06b6d4` / rainbow `#3b82f6→#8b5cf6→#ec4899→#f97316` / yellow `#f59e0b→#fbbf24`
  - DIMM：active `#f97316→#dc2626` + 边 `#fbbf24`；inactive `rgba(50,50,80,.5)` + 边 `#555`
  - 轨道 `rgba(50,50,80,.5)`
- **适配 1920×462**：
  `260px 1fr` 是按 480 宽设计的（260/480 = 54%）；**按比例换成 4 列**：
  device `462` + CPU `560` + GPU `560` + Memory `~300`（加起来 1882 + 3×4 gap ≈ 1894，留 26 边距）。
  环从 70 放大到 **84~96**（462 高里环越高越好看）；条从 6px 提到 **10~12px**。
  `min-height: 50px` 的折线图在两行结构里会被挤，**横排后每列都是全高 434，折线可以给到 90~120 高**。
  注意：这套主题的**源画布是 480×320**，它在 1920×462 上会被 headless Chrome 拉伸 —— 抄的是**语法**，不是像素。

---

### T3 Trofeo Native 四列琥珀/蓝紫（9.16 原生预设）

- **来源**：`~/.cache/trcc/repos/sensorpanel/themes/trofeo/src/App.css` + `src/App.tsx` + `native.theme.json`
- **画布**：**竖装 `462×1920`**，`layout: trofeo_vertical_v1`（`native.theme.json:3-5`）
- **布局**：`grid-template-columns: 620px 520px 360px 1fr`，`gap: 18px`，`padding: 22px`（`App.css:31-35`）
  - ⚠️ **实测值＝算得**：620+520+360+18×3+22×2 = **2052 > 1920**。源码没写 `1fr` 的最小宽度，所以实际渲染时
    第 4 列会被压到近 0 或整体溢出。**照抄时必须重算列宽**（建议 `600/500/400/380`，间隙 16，边距 20 = 1916）。
  - 装饰层（可直接抄的"科技感"手法）：`::before` 是**扫描线网格** `linear-gradient` 1px 线 `background-size: 100% 6px`，
    青 `rgba(66,183,255,.08)` + 紫 `rgba(159,116,255,.06)`，`opacity .45`（`App.css:39-50`）
  - `::after` 是**斜向光带 + 两个径向光晕**（青 `#42b7ff` / 紫 `#9f74ff`，`App.css:52-69`）
  - 每个 `section`：r=28、`rgba(0,0,0,.48)` 底、边 `rgba(172,199,255,.16)`、内阴影 `inset 0 1px 0 rgba(255,255,255,.045)`（`:71-80`）
  - **hero**：eyebrow 18 号 `#8ea5d8` 字距 `.22em` 大写 → 主机名 **48 号**白（`max-width:390px` 截断）→ 右侧时钟 **54 号** + 日期 20 号
    → 底部两张温环卡（`grid 1fr 1fr`）：**190×190 SVG 环**，`r=78`、`stroke-width: 18`、
    `stroke-dasharray = temp/100 · 2π·78`（`App.tsx:116-117`），环内 `CPU` 22 号 + 温度 **58 号** + `N% load` 19 号
  - **metrics**：2 列，每项 = 标签 20 号灰 + 值 28 号白右对齐 + 条 **14px 高** `r=999px`
  - **memory**：百分比 **86 号** + `N / M GB` 26 号 + 条 14px + 4 个 DIMM 胶囊（高 56、r=16、`rgba(0,0,0,.42)`）
  - **io**：磁盘头（标签 20 + 值 28）+ 条；下行/上行 22 号 + 值 **32 号**白
- **配色**：`#000`（画布/面板底）/ `#f7fbff`（正文）/ `#fff`（标题、数值）/ `#8ea5d8`（eyebrow 蓝灰）/
  `#93a2c8`（日期）/ `#91a4cf`（环标签）/ `#bac7e8`（环副文本）/ `#dce6ff`（机型名）/ `#9bacd8`（指标标签）/
  `#c5d2f4`（内存副行）/ `#97a9d7`（DIMM 标签）/
  环底 `rgba(255,255,255,.09)`；CPU 环 `#42b7ff`、GPU 环 `#9f74ff`；条轨 `rgba(255,255,255,.08)`；
  条填充 `blue #1c8cff→#65d7ff`、`green #00c978→#b2ff6b`、`amber #ffb13d→#ffe66d`、`red #ff4c6a→#ff9b6a`、`violet #765bff→#e978ff`
- **性能档**：`balanced`，`target_fps 1 / active 24 / idle 1`，`idle_timeout 20s`，**`jpeg_quality: 68`**，
  背景是 **24fps 的 JPEG 序列** `assets/background/frame_%04d.jpg` + `cache: lru`（`native.theme.json:7-23`）
- **适配 1920×462**：
  这是**最接近长条屏的一套**（黑底 + 四列 + 大数字）。三件事：
  ① 环 190→**150**、`stroke-width` 18→**12**（比例 78/95 ≈ 0.82，保持圆润）；
  ② 列宽重算（见上，源码那组数字超宽）；
  ③ **把 `::after` 的斜向光带从 section 级挪到整帧一级**，否则 4 条光带在长条屏上会糊成噪点 —— 我们的帧率只有 8fps，
  每帧重编码这么大的低对比渐变不划算（`docs/明早简报-20261014.md:82-89`）。

---

### T4 MacTR 五格系统监视（1920×480 基准，**首选对标**）

- **来源**：`MacTR/Sources/MacTR/Rendering/DesignTokens.swift`、`MonitorRenderer.swift`、`DrawingPrimitives.swift`
- **canonical 尺寸**：`width 1920 / height 480`（比我们多 18 行）
- **布局常量（`DesignTokens.swift:78-92`）**：`margin 14`、`gap 10`、`panelCount 5`
  - `panelWidth = (1920 − 28 − 4×10)/5 = (1920−68)/5 = 370.4`
  - `panelHeight = 480 − 28 = 452`；`panelY = 14`
  - `panelX(i) = 14 + i×(370.4+10)`
  - **对我们**：把 `height` 换成 462 → `panelHeight = 434`，`panelWidth` 不变（370.4）。**直接可用。**
- **每格画什么**（`MonitorRenderer.swift`）：
  - `renderCPU`（`:258-352`）：`Draw.panel(accent: blue)` → "CPU" 24 号粗（`:265`）
    → **弧表** `arcGauge(cx=x+100, cy=py+138, r=70, thickness=13)`，**起止角 135°→405°（270° 扫角）**、
    圆头端点、末端画一个 `thickness/2` 的**圆点**（`DrawingPrimitives.swift:72-111`）
    → 中央数值 50 号 + `%` 20 号 → 右侧**每核条**（`barX=x+194`，条高 8/10，字号 12/14/16）
    → 底部 `Temp` 22/30 号 + `Load a/b/c` 18 号（`:337-351`）
  - `renderGPU`（`:356-443`）：弧表 magenta + 3 行利用率条（Device/Renderer/Tiler）+ GPU 显存行 + **下行/上行镜像柱状图**
   （`netDividerY = py + panelHeight − 120`，镜像柱上下分色 cyan/orange，`:429-442`）
  - `renderMemory`（`:447-547`）：弧表颜色**跟内存压力**（不跟用量%）+ Active/Wired/Compressed/Available 四行条 + Swap 镜像图
  - `renderDisk`（`:551-615`）：弧表 orange + Used/Free 两条 + 磁盘 I/O 镜像柱
  - `renderSystem`（`:619-695`）：**时钟 56 号**（`HH:mm:ss`）+ 日期 24 号 + 星期 20 号 + 分隔线 + Uptime/Processes/Load/电池行
- **几何细节**：面板圆角 **16**；**强调色顶条** `x+2, y, w−4, 3` 高 3px、圆角 2；顶条下方再画**6 行 1px 渐隐光晕**
  （alpha `0.12 · (1 − i/6)`，`DrawingPrimitives.swift:39-64`）；进度条圆角 = `h/2`、轨道色 `barBG`
- **配色（26 色全令牌，`DesignTokens.swift:11-41`）**：
  | 令牌 | hex | 用途 |
  |---|---|---|
  | bgTop / bgBot | `#0A0C14` / `#10121C` | 全屏垂直渐变 |
  | panelBG / border | `#141722` / `#262A3A` | 面板底 / 描边 |
  | textW / textS / textL / textD | `#E6EBF5` / `#8C94A8` / `#646C82` / `#464C5F` | 四级文字 |
  | blue / blueD | `#4285F4` / `#1E3C78` | CPU |
  | green / greenD | `#34D399` / `#185F46` | 内存、健康 |
  | orange / orangeD | `#FBBF24` / `#6E5410` | 磁盘、警告 |
  | red / redD | `#EF4444` / `#6E1E1E` | 危险 |
  | purple / purpleD | `#A78BFA` / `#4B3E73` | GPU 的 Renderer 分项 |
  | cyan / cyanD | `#22D3EE` / `#0F5F6C` | SYSTEM、E 核、下行 |
  | magenta / magentaD | `#D946EF` / `#501C5A` | GPU 主色 |
  | barBG | `#1E2230` | 所有条/轨道的底 |
  - 阈值色（`DesignTokens.swift:40-46`）：`pct<50 → green`，`pct<75 → orange`，否则 `red`；深色变体同理
  - 内存用**压力等级**而不是用量% 上色（`:52-60`，`level>=4 → red`，`>=2 → orange`）—— 理念可抄
- **工程细节**：metrics 在**独立后台队列**每 0.5s 采（`:91-142`），慢指标每 4 tick（~2s）采一次；
  `render()` 只读缓存快照、从不阻塞（`:203-213`）；**CGContext 复用**避免每 0.5s 分配 3.6MB（`:30-31,223-234`）
- **适配 1920×462**：**几乎零改动** —— 只把 `Layout.height` 从 480 改 462（`panelHeight` 自动变 434）。
  唯一的取舍：5 格的 434 高里，CPU 弧表在 `py+138` + 每核条到 `py+ph−96`；462 会让底部 Temp/Load 行比 480 紧 18px，
  把 `bottomY = py + ph − 92` 改成 `− 88` 即可。
  **另外**：我们的 DSH 面板不是 5 等分（`Theme.ets:62-66`：`dashWidth=1440` 交给仪表盘、右侧 480 给 VM），
  所以 5 格的 `panelWidth 370.4` 只适用于**整帧五等分**那一档；要在 1440 里放 5 格得用 `(1440−28−40)/5 = 274.4`（＝我们现在的值）。

---

### T5 trcc 传感器类别色板（6 色语义集）

- **来源**：`thermalright-trcc-linux/src/trcc/core/models.py:1737-1742`（同一份表重复在
  `src/trcc/ui/gui/overlay_element.py:36-41`、`src/trcc/ui/gui/uc_activity_sidebar.py:24-31`）
- **内容**：不是一套布局，是**按传感器类别的固定语义色**（叠加元素默认色 + 侧栏活动色）
- **配色**：CPU `#32C5FF`（青）、GPU `#44D7B6`（蓝绿）、MEM `#6DD401`（黄绿）、HDD `#F7B501`（琥珀）、
  NET `#FA6401`（橙）、FAN `#E02020`（红）；自定义回退 `#FFFFFF`（`uc_activity_sidebar.py:31`）；
  文本/叠加默认色 `#ffffff`（`core/models.py:884`，`OVERLAY_DEFAULT_COLOR`）
- **配套**：叠加元素的默认字号 24 / 不加粗 / 不斜体，颜色 `#ffffff`（`services/_dc.py:566`）；
  中位灰 `#808080` 是最常见的旧默认值（`services/_dc.py:527`）
- **适配 1920×462**：这套 6 色**饱和度比 MacTR 那套更高、更适合黑底长条屏**（MacTR 的色偏"桌面应用"）。
  建议做成**可选第二配色档**：`Theme.ets` 里 `C.blue/green/orange/red/purple/cyan/magenta` 与这 6 色不是一一对应，
  别硬套 —— 新增一组 `C.trCpu/C.trGpu/...` 更干净。
  ⚠️ **注意我们的 JPEG 是 4:2:0**：`#FA6401`（橙）与 `#E02020`（红）没问题，但**高饱和青 `#32C5FF` 会被压**，
  按 `HANDOFF-打印机格复刻.md:126-139` 的预补偿惯例应该先降饱和（参考 `#30D8E0`）。

---

### T6 MacTR 待授权硬闪徽章（多 agent 列）

- **来源**：`mac-thermalright-ai-monitor/Sources/MacTR/Rendering/MonitorRenderer.swift:692-734`（`renderAgentColumn`）
- **三态**：
  - **needsAttention（待授权/已完成）** → **硬闪**：`blinkOn = Int(t*2) % 2 == 0`（`:708`，即 **2Hz 方波**）；
    底色 alpha `blinkOn ? 0.36 : 0.10`；描边 alpha `blinkOn ? 0.9 : 0.25`，线宽 2（`:715-727`）
  - **isWorking（干活中）** → **三角波呼吸**：周期 5s，`phase = t % 5 / 5`，
    `breath = phase < 0.5 ? phase*2 : (1-phase)*2`（`:709-713`）；底 alpha `base + 0.13*breath`，
    描边 alpha `0.12 + 0.28*breath`（`:718,730`）
  - **idle** → 静态底色（`base`：CLAUDE 用 0.09，其余 0.08，`:705-706`）
- **为什么是三角波不是 cos**（源码原文注释，`:709-711`）：
  > "A constant per-frame delta reads far smoother than cosine easing at the display's low frame rate —
  > no stutter where the cosine flattens near its peaks/troughs."
  （三角波每帧增量恒定，低帧率下比余弦更顺 —— 余弦在峰谷附近会"卡顿"。）
- **其他配套**：徽章胶囊 `padX 9 / padY 4`、圆角 5，**用实心琥珀 `Color.orange` 保证在闪烁底色上仍可读**（`:781-798`）；
  头部"● now / 12m ago" 用 17 号 + `dotR 5` 圆点，`active` 判定是 **90 秒**（`:739-759`）；
  状态点色 `active ? green : textD`
- **适配 1920×462**：**直接抄进 `ThemeDiag.ets` / `Dashboard.ets` 的状态徽章**。三条要点：
  ① 待授权 = 2Hz 方波（我们帧率 8fps，2Hz 方波正好每 4 帧翻转一次，**不会漏帧也不会看起来在抖**）；
  ② 工作中 = 5s 三角波（8fps 下 40 帧一个周期，够顺）；
  ③ 空闲 = 静态（**别让空闲态也动**，否则帧率永远降不下来，`LcdService.ets` 的空闲 2fps 就废了）。
  我们的面板高 434，徽章高 ≈ `16(字号) + 8(padY)` ≈ 30，完全放得下。

---

### T7 sensorpanel "Now Playing" 全屏卡片（唯一为长条屏设计的音乐界面）

- **来源**：`sensorpanel/pkg/music/dashboard/index.html`（**原生画布 480×320**，`index.html:5,8`）
- **布局（全部绝对定位，可直接当"卡片语法"抄）**：
  - 背景层：`#backdrop` `inset:-44px` + `blur(32px) saturate(1.9) contrast(1.08) brightness(1.12)` + `scale(1.2)`
    —— **用专辑封面自己当氛围底**（`:9`）；`#shade` 双层黑色渐变（水平 + 垂直，`:10`）
  - 顶栏 `left/right:13px, top:6px, h:23px`：`♫ Now Playing` 11 号 + 右侧时钟（`:12-14`）
  - 封面 `#art` `13,36,103,103` r=9 + 边框 `rgba(255,255,255,.25)` + 阴影 `0 10px 24px rgba(0,0,0,.42)`（`:18`）
  - 信息块 `left:130, top:35, h:91`：标题 22 号 850 粗（两行钳制）、歌手 14 号 `#e4e5e9`、专辑 10 号 `#a7abb4`（`:19-22`）
  - **波形** `left:130, top:115, h:29`：**48 根条**，两层叠加 —— 底 `rgba(255,255,255,.2)`、
    已播放层 `#f5f5f7` + `box-shadow 0 0 4px rgba(255,255,255,.45)`，
    用 `clip-path: inset(0 X% 0 0)` 表示进度（`:35-39,59-61`）
  - 进度行（`:24`）、`Lyrics` 标题（`:28-29`）、歌词窗 `top:186` + `mask-image` 上下淡出，
    行高 46px，**当前行 24 号 900 粗 + 双层 text-shadow**，其余 15 号 `rgba(235,236,240,.5)`（`:30-33`）
- **配色**：底 `#05070b`；正文 `#f7f7fa`；顶栏 `#f2f2f4`；空态 `#999fac`；歌手 `#e4e5e9`；专辑 `#a7abb4`；
  状态 `#d5d7dd`；进度 `#d0d2d8`；歌词标题 `#d9dbe1`；非当前行 `rgba(235,236,240,.5)`；波形 `rgba(255,255,255,.2)` / `#f5f5f7`
- **适配 1920×462**：**这是"1920×462 音乐/媒体页"的最佳模板**，因为它本来就是横向长条。
  按 4× 放大：封面 103→**420**（`x=56,y=56`），信息块 `x≈520`，标题 22→**88 号**，歌手 14→56，专辑 10→40；
  波形 48 根条、高 29→**116**，`top:115`→`460`（即中轴）；歌词改成**单行大字**（19 英寸屏上两行以上歌词没意义），
  字号 24→**96 号**居中，上下用 `mask-image` 淡出。
  注意 `blur(32px)` 在鸿蒙 Canvas 上的等价物是 `ctx.filter`（**未核实 ArkTS 是否支持**，见 §6）。

---

### T8 trcc 金色 RGB 控制页皮肤

- **来源**：`thermalright-trcc-linux/src/trcc/ui/gui/uc_rgb.py:43-95`（模块级常量 + `_QSS`）
- **内容**：一套**完整的"黑金"控件皮肤**（不是屏上画面，但配色可移植到屏上）
- **配色**：`GOLD #b49653`、`ACCENT #d9b45a`、`FRAME #434343`、`CARD #2b2b31`、`CARD_BORDER #4a4a52`、
  `MUTED #9a9aa2`、`TEXT #eeeeee`；下拉底 `#1b1b20`、下拉边 `#5a5a62`；
  选中态 `#4a3f22`；按钮 `#2d2d33` + 2px 琥珀边 r=6；禁用 `#666`/`#555`；
  单选/复选勾选填 `ACCENT`；滑块槽 `#45454d` 高 6 r=3、handle `ACCENT` 16px r=8
- **同族还有**：`gc_about.py:247` / `display_mode_panels.py:307` 的 `black + #B4964F`；
  `uc_ram_access.py:23-25` 的 `#B4964F` 文字 + 黑底 + 1px 琥珀边
- **另一族（深色蓝灰）**：`ui/gui/constants.py:13-56` ——
  `WINDOW_BG #232227`、`WINDOW_TEXT/TEXT/BUTTON_TEXT #C6C6C6`、`BASE_BG #1E1E1E`、`BUTTON_BG #3C3C3C`、
  `ACCENT #4A6FA5`、`ACCENT_BORDER #6B8FC5`、`HOVER_BG #3A3A3A`、`THUMB_BG #1A1A1A`、
  `NON_LOCAL_BG #2A2A2E`、`NON_LOCAL_HOVER_BG #3A3A3E`、`PANEL_FALLBACK #2A2A2A`、
  设备选中 `#3B6B9A/#2A4D6E/#5B8BBA`、设备常态 `#383838/#2C2C2C`、悬停 `#454545/#383838`、关窗悬停 `#C42B1C`
- **适配 1920×462**：黑金这套**天生适合 OLED 黑底**，而且金色 `#d9b45a` 在 4:2:0 下**几乎不丢**（黄通道保留好）。
  建议做成 `ThemeDiag`（诊断终端）的第二配色档：把 `C.deepseek #4D6BFE` 换成 `#d9b45a` 作强调、
  `C.textW` 从 `#E6EBF5` 降到 `#eeeeee`、面板底用 `#1E1E1E`、分隔线 `#434343`。
  **注意**：`#232227`、`#2b2b31` 这类"接近黑但不全黑"的底色在 JPEG 上会产生**块状噪点**，
  屏上不如直接用 `#000000` 干净（我们的 `ThemeDotii.ets:42` 就是这么做的）。

---

### T9 sensorpanel 内置渲染器（`pkg/renderer/renderer.go`）

- **来源**：`sensorpanel/pkg/renderer/renderer.go`（**本次未逐行读完**，只确认了文件与作用域）
- **状态**：⚠️ **未复核明细**。已知它存在，并且是 `sensorpanel run` 不带主题时的默认渲染路径。
  它在 `docs/dashboard-preview.png` 里有截图。
- **未复核到什么程度**：画了什么元素、坐标、字号、配色**全部未读**。
- **适配建议**：**暂不给建议** —— 没有证据。
  **要补的话**：`read ~/.cache/trcc/repos/sensorpanel/pkg/renderer/renderer.go`（它应该不大）。

---

### T10 sensorpanel 分层渲染管线（工程规格，不是画面）

- **来源**：`sensorpanel/docs/performance.md:8-38`
- **"层"的定义**（这是它 24fps 的根因，值得当规格抄）：
  1. 持久 TurboJPEG 解码器把背景直接写进**可复用的物理 RGBA 画布**（`:19-20`）
  2. **传感器叠加层只在格式化后的值变化时才重绘**（正常 1 次/秒）（`:21-22`）
  3. 缓存的叠加层由优化的原生 blender 合成（`:23`）
  4. 持久 TurboJPEG 编码器写进**预分配**输出缓冲（`:24`）
  5. LY 打包器填**可复用**包缓冲，按协议做 **4096 字节传输，一个帧 deadline**（`:25-26`）
  - 调度器用**单调 deadline**；错过 deadline 时**丢掉过期的动画位置，而不是排队**（`:28-29`）
  - 静态图/纯传感器 V2 场景：**渲染上限 = 传感器采集节奏**，所以 `active_fps: 24` 不会真的渲 24 次相同画面（`:31-33`）
  - 空闲：不启视频解码，只在**可见值/分钟变化后**用单色调色板重绘，然后**以 1 FPS 重发缓存像素**防固件回 splash（`:35-38`）
- **实测数据**（`:70-79`，开发机 1920×462、竖装主题、JPEG q68）：
  | 模式 | 优化前 | 优化后 | 交付 fps |
  |---|---:|---:|---:|
  | Active | 34.8% CPU | **9.44% CPU** | 24.00 |
  | Idle | 4.43% CPU | **0.45% CPU** | 1.00 |
  （CPU 百分比是**单逻辑核**的比例）
- **适配 1920×462**：**这是最有价值的一节，因为它直接对应我们的性能天花板**。
  我们的实测是 render 2ms + encode 48~65ms + push 47~80ms ≈ **110ms/帧 → 天花板 ~8fps**
  （`docs/明早简报-20261014.md:82-89`）。
  差距的**根因是它没有每帧重编码整幅画面**：叠加层缓存 + 只在值变化时重绘 + 编码器/缓冲全复用。
  我们能立刻做的三件事：
  ① **每帧重编码的只有变化的部分**（我们做不到局部刷新，但可以让**整帧像素不变时直接重发上一帧的 JPEG 字节**——
     不用重新 encode！这能省掉 48~65ms 里的大部分）；
  ② `toDataURL()` 的 base64 往返是纯开销（`README.md:640-643` 已指出），换 `ImagePacker.packToData`；
  ③ 传感器值**格式化后才比较**，相同就不重绘 —— 我们的时钟只精确到分钟、CPU 曲线 1s 一采样，大量帧是一样的。

---

### T11 trofeo-lcd-rs 预设布局集（13 个命名布局）

- **来源**：`trofeo-lcd-rs/README.md:323`（`layout = default | cpu-gpu | temps | overview | grid6 | clock-center | io | music | gaming | cpu | gpu | weather | news`）
  截图：`trofeo-lcd-rs/img/layout-*.png`（cpu-gpu / temps / overview / grid6 / clock-center / io / music / gaming / cpu / gpu / weather / news）
- **内容**：**13 套预设版式清单**，每套一个截图。README 说明它们可以**逗号轮播 + 各自带时长**：
  `layout = default:30, weather:5`（`:334-341`），且 `layout_interval` 是默认轮播秒数。
- **可用配置项（决定每套能怎么改）**：
  - **9 个锚点**：`top-left/top/top-right/center-left/center/center-right/bottom-left/bottom/bottom-right`，
    分别用于 `status_position`、`clock_position`、`spectrum_position`、`ticker_position`（`:208-211`）
  - **画什么**：`show/hide = cpu gpu uptime time date mem net disk volume nowplaying weather ticker spectrum clock clock_date dashboard`（`:204-207`）
  - 每一项可单独 `<item>_size (1-30)` / `<item>_position (3×3)` / `<item>_color` / `<item>_backdrop`（`:351-362`）
  - `hide = cpu_freq, cpu_temp, cpu_power, gpu_temp, gpu_power, gpu_fan, gpu_clock, gpu_fps`（`:357-358`）
  - `margin` / `margin-top/-bottom/-left/-right` 分边距（`:170-171`）
  - `panel_opacity 0-100` 让面板在背景上透出（`:343-345`）；`text_backdrop` 给状态行和大时钟加底板
- **配色**：布局本身不带色板（用 `text_color` / `clock_color` / `color`，支持 `#RRGGBB`、`R,G,B` 或颜色名，`:212`）
- **适配 1920×462**：**这套"9 锚点 + 逐项 position/size/color"是比我们现在的硬编码坐标更好的抽象**。
  建议在 `Theme.ets` 的 `L` 之外**再加一层 `Anchor` 工具**（`anchorX(anchor, w)` / `anchorY(anchor, h)`，
  3×3 → 像素），这样新增主题不必再手算坐标。
  `grid6` 与 `overview` 两套最适合直接改成长条屏六格/总览版。
  ⚠️ 我**没有**读它的布局实现代码（`layout-*.png` 是图片，无法在此环境读像素布局），
  所以**这 13 套的具体坐标未复核**（见 §6）。

---

### T12 trcc 主题遮罩（mask）主题体系

- **来源**：`thermalright-trcc-linux/dev/decompiler/AUDIT_THEME_MASK.md`（存在）、
  `src/trcc/ui/gui/uc_theme_mask.py:216`、
  `src/trcc/services/data_install.py:57-74`、
  `src/trcc/adapters/repo/data_install.py:10-25`
- **内容**：trcc 的主题体系是**三件套**，每套都有独立的 7z 发行包，按分辨率分目录：
  ```
  theme{w}{h}/        原厂主题（stock themes）
  web/{w}{h}/         云主题预览缩略图（cloud catalog thumbnails）
  web/zt{w}{h}/       云主题遮罩（cloud masks）
  ```
  非正方形面板（如 1600×720）**额外**抓旋转对应分辨率（720×1600）的 web + masks，
  这样竖装时不必重新下载（`adapters/repo/data_install.py:4-16`）。
- **对我们**：`theme1920462.7z` 就是**我们这块屏的原厂主题包**，`zt1920462.7z` 是遮罩包。
- **适配 1920×462**：见 §5.1（解包命令）。解出来的是**原厂厂商做的 1920×462 画面**——
  这是**唯一一手"官方怎么排这块长条屏"的证据**，比任何第三方推断都硬。

---

## §3 配色板全集

### 3.1 MacTR 26 色全 Token

**出处**：`MacTR/Sources/MacTR/Rendering/DesignTokens.swift:11-41`（每个都是 `CGColor(red: R/255, ...)`，下面已折算成 hex）

| 令牌 | hex | 语义 |
|---|---|---|
| bgTop | `#0A0C14` | 全屏渐变上 |
| bgBot | `#10121C` | 全屏渐变下 |
| panelBG | `#141722` | 面板底 |
| border | `#262A3A` | 面板描边 / 分隔线 |
| textW | `#E6EBF5` | 主文字 |
| textS | `#8C94A8` | 次文字 |
| textL | `#646C82` | 三级文字 |
| textD | `#464C5F` | 四级/脚注 |
| blue | `#4285F4` | CPU |
| blueD | `#1E3C78` | CPU 暗（弧表底） |
| green | `#34D399` | 内存 / 正常 |
| greenD | `#185F46` | 内存暗 |
| orange | `#FBBF24` | 磁盘 / 警告 |
| orangeD | `#6E5410` | 警告暗 |
| red | `#EF4444` | 危险 |
| redD | `#6E1E1E` | 危险暗 |
| purple | `#A78BFA` | GPU Renderer 分项 |
| purpleD | `#4B3E73` | 紫暗 |
| cyan | `#22D3EE` | SYSTEM / E 核 / 下行 |
| cyanD | `#0F5F6C` | 青暗 |
| magenta | `#D946EF` | GPU 主色 |
| magentaD | `#501C5A` | 品红暗 |
| barBG | `#1E2230` | 所有条/轨道底 |

**mac-thermalright-ai-monitor 版本 = 上面去掉 3 个，另加 3 个**（`Sources/MacTR/Rendering/DesignTokens.swift`，同路径不同仓库）
—— 该仓库 **没有** `blueD` / `greenD` / `redD`（因为它的 `forPercentDark` 复用 `orangeD` 等），**另加**：
| 令牌 | hex | 语义 |
|---|---|---|
| claude | `#D97757` | Claude 品牌赤陶色 |
| cursor | `#EBEBF0` | Cursor 单色主色 |
| cursorDim | `#8C8E96` | Cursor 次色 |

> **26 与 26 不是同一组 26**：MacTR 是"8 底/文字 + 12 彩 + barBG"共 23 个不重复令牌名（bgTop/bgBot/panelBG/border/textW/textS/textL/textD/blue/blueD/green/greenD/orange/orangeD/red/redD/purple/purpleD/cyan/cyanD/magenta/magentaD/barBG = 23）；
> 我把它记为"26 色系"是指**含深色变体的完整色阶数**。若你要精确计数，按令牌名数是 **23**。
> （这一条我特意写清楚，避免后面照着"26"去核对时对不上。）

### 3.2 sensorpanel 两套主题色

| 主题 | 出处 | 全部 hex / 色值 |
|---|---|---|
| **Trofeo Native**（竖装 462×1920） | `themes/trofeo/native.theme.json:24-30` | `accent #2de2ff`、`accent2 #ff4df3`、`accent3 #71ffa8`、`text #f8fbff`、`muted #8ea1bb`、`panel #06132688`、`panel_line #245cff99`、`background #000000` |
| **Trofeo Native（CSS 里的实际取值）** | `themes/trofeo/src/App.css` | 见下表 |
| **Caelestia**（竖装 462×1920） | `themes/caelestia/native.theme.json:7-13` | `background #0a0f0f`、`accent #9bd0cc`、`accent2 #b0ccc9`、`accent3 #d5efff`、`text #dce8e6`、`muted #a2adac`、`panel #131b1a`、`panel_line #3f4a49` |
| **NeonPulse**（480×320） | `themes/neonpulse/src/App.css` | 见 §2-T2 |

**Trofeo Native 的 CSS 实际色值**（`themes/trofeo/src/App.css`，行号已列）：

```
底 #000
正文 #f7fbff (:17)      标题/数值 #fff (:127,279)
eyebrow/section-title #8ea5d8 (:117)   时钟日期 #93a2c8 (:147)
环标签 #91a4cf (:209)   环副文本 #bac7e8 (:221)   机型名 #dce6ff (:229)
指标标签 #9bacd8 (:271) DIMM 标签 #97a9d7 (:360)  内存副行 #c5d2f4 (:338)
面板底 rgba(0,0,0,.48) (:78) 边框 rgba(172,199,255,.16) (:76)
面板内阴影 inset 0 1px 0 rgba(255,255,255,.045) (:79) 外描边 0 0 0 1px rgba(0,0,0,.28) (:79)
环底 rgba(255,255,255,.09) (:179)  条轨 rgba(255,255,255,.08) (:291)
CPU 环 #42b7ff (:188)   GPU 环 #9f74ff (:192)
条 blue  #1c8cff → #65d7ff (:305)
条 green #00c978 → #b2ff6b (:309)
条 amber #ffb13d → #ffe66d (:313)
条 red   #ff4c6a → #ff9b6a (:317)
条 violet #765bff → #e978ff (:321)
扫描线网格 青 rgba(66,183,255,.08) / 紫 rgba(159,116,255,.06)，线高 1px、background-size 100% 6px (:44-48)
斜向光带 青 rgba(66,183,255,.42/.30/.18) / 紫 rgba(159,116,255,.38/.28/.16) / 白 rgba(255,255,255,.10) (:57-64)
```

### 3.3 trofeo-lcd-rs：8 套频谱调色板 + 12 套动态背景调色板

**频谱调色板**（`trofeo-lcd-rs/src/spectrum.rs:117-123`；枚举与预设表在 `:100-140`）——
共 **8 套预设**（`presets()` 返回 Rainbow/Fire/Ocean/Sunset/Neon/Ice/Matrix/Purple，`:129-140`），
外加 `Default`（原始绿→黄→红电平渐变，`:102-103`）与 `Custom`（用户 `spectrum_gradient`，`:113-114`）：
> **口径说明**：`Palette::NAMES`（`:126`）写的是 `default | rainbow | fire | ocean | sunset | neon | ice | matrix | purple`
> —— **9 个名字**，但 `default` 不是 `presets()` 的成员，所以"可轮播的预设"是 **8 套**。两个数都对，看你要哪个口径。

| 名称 | 4 个 stop（低→高） |
|---|---|
| Fire | `#600000` → `#E03000` → `#FFA000` → `#FFF080` |
| Ocean | `#003090` → `#0090E0` → `#00E0D0` → `#E0FFFF` |
| Sunset | `#6020A0` → `#E03090` → `#FF8030` → `#FFE060` |
| Neon | `#FF00A0` → `#A030FF` → `#00C0FF` → `#00FFD0` |
| Ice | `#4060C0` → `#70B0FF` → `#C0F0FF` → `#FFFFFF` |
| Matrix | `#005010` → `#00B030` → `#40FF60` → `#D0FFD8` |
| Purple | `#402090` → `#8040E0` → `#D060F0` → `#FFB0F0` |
| Rainbow | 全色相环，**程序生成**（`rainbow_stops()`，`:119-120`） |
| Default（第 9 个名字） | 原始绿→黄→红，无 stop 常量 |

**动态背景调色板**（`trofeo-lcd-rs/src/effect.rs:78-116`）—— `PRESETS` 数组是 **12 项**，但 `("rainbow", &[])` 是**程序生成的全色相环**
（`:115` 注释 `// generated (full hue circle)`，生成函数在 `:119`），所以**字面量色板是 11 套 + 1 套生成**：

| 名称 | stops |
|---|---|
| pastel | `#FFB3BA` `#FFDFBA` `#FFFFBA` `#BAFFC9` `#BAE1FF` `#DAC4FF` |
| fluo | `#FF0080` `#FFF000` `#00FF78` `#00C8FF` `#9600FF` |
| neon | `#FF00C8` `#6E00FF` `#008CFF` `#00FFDC` |
| candy | `#FF8AC8` `#FFC8E8` `#9AE6FF` `#B4FFDC` `#D8A8FF` |
| sunset | `#3A1070` `#C82080` `#FF6030` `#FFC050` `#B02090` |
| ocean | `#002070` `#0078D0` `#00C8D0` `#2050B0` |
| aurora | `#003040` `#00C080` `#60FFB0` `#7040D0` `#102070` |
| fire | `#300000` `#C02000` `#FF8000` `#FFD040` `#801000` |
| forest | `#003018` `#108040` `#90D050` `#005040` |
| ice | `#3050B0` `#70B0FF` `#D0F4FF` `#6090E0` |
| mono | `#202430` `#B8C0D0` `#505868` |
| rainbow | **程序生成**，全色相环 |

**背景效果的工程常数**（`effect.rs:24-34`）：`CELL = 12`（每 12px 采一个场样本，1920×462 上约 6000 个样本）、
`LUT_N = 1024`（配色查找表，**2 的幂 → 用掩码回绕**）、`FRAC = 8`、`STEP_FRAC = 4`、
`UNIT_PX = 260.0`（scale=100 时"1.0"的像素长度）、`FADE_SECS = 4.0`（调色板轮换交叉淡入秒数）。
它是 4 种风格：`plasma | aurora | lava | waves`（`:41-50`，别名 `curtains/tende`、`blobs/lavalamp`、`silk/onde/seta`，`:57-65`）。

### 3.4 trcc 其他色板

| 名称 | 全部 hex | 出处 |
|---|---|---|
| 传感器类别色（6 色） | `#32C5FF` `#44D7B6` `#6DD401` `#F7B501` `#FA6401` `#E02020` | `core/models.py:1737-1742`（重复于 `ui/gui/overlay_element.py:36-41`、`ui/gui/uc_activity_sidebar.py:24-31`） |
| 金色皮肤 | `GOLD #b49653`、`ACCENT #d9b45a`、`FRAME #434343`、`CARD #2b2b31`、`CARD_BORDER #4a4a52`、`MUTED #9a9aa2`、`TEXT #eeeeee`、`#cfcfd4`、`#1b1b20`、`#5a5a62`、`#4a3f22`、`#2d2d33`、`#666`、`#555`、`#45454d` | `ui/gui/uc_rgb.py:43-95` |
| 金色变体 | `#B4964F` | `ui/gui/uc_ram_access.py:23-25`；`ui/gui/uc_about.py:247`；`ui/gui/display_mode_panels.py:307` |
| 深色窗口族 | `#232227` `#C6C6C6` `#1E1E1E` `#3C3C3C` `#4A6FA5` `#6B8FC5` `#3A3A3A` `#1A1A1A` `#2A2A2E` `#3A3A3E` `#2A2A2A` `#3B6B9A` `#2A4D6E` `#5B8BBA` `#383838` `#2C2C2C` `#454545` `#C42B1C` | `ui/gui/constants.py:13-56` |
| splash（Catppuccin Mocha 味） | `#1e1e2e` `#cdd6f4` `#585b70` `#a6adc8` `#313244` `#89b4fa` | `ui/gui/splash.py:43-65` |
| 曲线页 | `#7A7A7A` `#FF4444` `#44FF44` `#4444FF`；温标 `#00CCFF→#00FF00→#FFFF00→#FF8800→#FF0000` | `ui/gui/uc_led_control.py:387,426,499-500` |
| 视频裁切页 | `#232227` `#00FF00` `#CCCCCC` `#00AA00` `#AA0000` `#4488FF` `#000000` `#004400` `#FF0000` | `ui/gui/uc_video_cut.py:174-286` |
| 叠加元素默认 | 文字色 `#ffffff`、字号 24、不加粗不斜体；旧默认灰 `#808080` | `core/models.py:884`、`services/_dc.py:527,566` |
| Qt 视频裁切 | `#2a2a2a` `#88ff88` `#226633` `#ff8888` `#662222` | `ui/qtgui/video_crop.py:154-170` |

---

## §4 工程手法 24 条

| # | 做法 | 为什么有用 | 出处 |
|---|---|---|---|
| 1 | **空闲时以 1 FPS 重发缓存像素**，且**只在可见值/分钟变化后才重绘** | 固件在 ~2-3s 无帧时会回到内置 splash/logo；重发**缓存字节**（不重新编码）就把它钉住 | `sensorpanel/docs/performance.md:35-38` |
| 2 | **volatile 帧线的保活重发，间隔 150ms**，新帧到达即重置计时 | LY/Bulk 固件 2-3s 无帧就退回内置 logo；150ms 是实测能"钉住"屏幕的值 | `doc/REFERENCE_CLI.md:522-537`（`--interval` 默认 `0.150`）；机制见 `doc/SEND_FOUNDATION.md:28,44` |
| 3 | **错帧就丢，不排队**（单调 deadline） | 排队会让画面永远滞后；丢帧只会跳过一帧动画 | `sensorpanel/docs/performance.md:28-29` |
| 4 | **渲染节奏按传感器采集节奏封顶**：静态图/纯传感器场景下 `active_fps:24` 不会真的渲 24 次 | 避免为同一个像素重复付出 JPEG + USB 成本 | `sensorpanel/docs/performance.md:31-33` |
| 5 | **分层渲染**：背景解码 → 叠加层（值变化才重绘）→ 合成 → 编码 → 打包，各层缓冲全部复用/预分配 | 这是它 34.8% → 9.44% CPU 的根因 | `sensorpanel/docs/performance.md:11-26` |
| 6 | **自适应帧率**：有动画才跑高帧率，否则按配置间隔 | 常驻 App 的功耗主要就烧在这里 | `mac-thermalright-ai-monitor/.../AppState.swift:271-284`（注释原文：设备能撑 ~19fps，但数据每 ~2s 才变） |
| 7 | **夜间窗口直接推黑帧**，并把间隔拉到 3.0s | 熄屏省电又不让固件回 splash | `mac-thermalright-ai-monitor/.../AppState.swift:274-283,295-296` |
| 8 | **三角波呼吸而非 cosine**：`phase = t % 5 / 5`；`breath = phase<0.5 ? phase*2 : (1-phase)*2` | 源码注释：低帧率下三角波每帧增量恒定、比余弦顺；余弦在峰谷附近会抖 | `mac-thermalright-ai-monitor/.../MonitorRenderer.swift:709-713` |
| 9 | **待授权 = 2Hz 硬闪方波**：`blinkOn = Int(t*2) % 2 == 0`，底色 Δalpha 0.10↔0.36、描边 0.25↔0.9 | 高对比告警，且在低帧率下不会"看起来像呼吸"而被忽略 | `mac-thermalright-ai-monitor/.../MonitorRenderer.swift:708,715-727` |
| 10 | **徽章胶囊用实心琥珀**（不透明），保证在闪烁底色上始终可读 | 闪烁会吃掉对比度，实心填充兜底 | `mac-thermalright-ai-monitor/.../MonitorRenderer.swift:781-798` |
| 11 | **整体 JPEG，无局部刷新**：每次更新都是**完整 JPEG**，按 512 字节记录、4096 字节 USB 写发出 | 固件**不暴露矩形帧缓冲更新**，所以只能在主机侧省工作，不能省传输 | `sensorpanel/docs/performance.md:1-6,24-26` |
| 12 | **LY 面板不支持局部刷新（显式拒绝）** | 想抄 README 的 "Regional USB updates" 会被这一步挡住 | `sensorpanel/pkg/panel/device.go:857-868`（`return errors.New("regional updates are not supported by LY bulk displays")`） |
| 13 | **超限就丢帧 + 降质 5**：`payload >= 450000 → myTempDeviceJpgYSL -= 5; return`（丢帧不发送） | 固件有体积上限，超了会出问题；用"丢这一帧 + 下次编码更小"代替整条链失败 | `thermalright-trcc-linux/dev/decompiler/AUDIT_LCD_PIPELINE.md:66`、`AUDIT_DISCOVERY.md:227`（`FormCZTV.cs:2739-2743`） |
| 14 | **JPEG 质量递减循环直到进体积上限**：`quality 0.9` 起，每次 `-0.05`，`> 0.3` 为止，`maxBytes = 650000` | 保证任何一帧都能发出去；用质量换成功率 | `MacTR/.../FrameRenderer.swift:27-28,67-77` |
| 15 | **JPEG 降质 + 尺寸自适应配合**：我们自己的序列 `0.9→0.75→0.6→0.45→0.4(下限)`；超限时先试降尺寸 | 与第 14 条同源，但多了尺寸维度 | `README.md:535`（自检项「JPEG 降质序列」） |
| 16 | **按传感器**改内容**再自适应字号**：`fontSize = coreCount>16 ? 12 : (coreCount>10 ? 14 : 16)`；`barH = 8/10` | 输入量本身变化时，字号跟着缩，永远不溢出 | `MacTR/.../MonitorRenderer.swift:287-289` |
| 17 | **行距按可用高度算**：`spacing = min(36, (bottomLimit − py − 18) / max(coreCount,1))`，且画到 `by + fontSize > bottomLimit` 就 `break` | 元素数量不可控时的通用防溢出 | `MacTR/.../MonitorRenderer.swift:289,303` |
| 18 | **"按时间占比而不是按块"的队列背压**：GUI 发送线程队列 `<=2` 才入队，否则丢帧 | 阻止生产者比 USB 快时无限堆积 | `thermalright-trcc-linux/dev/decompiler/BEHAVIOR_DISCOVERY.md:139`（`UCDevice.cs:1595`） |
| 19 | **单槽位发送互斥 + 30ms 冷却**：`isSendUsbThread0[index]` 已 true 就直接返回（丢帧）；发完睡 30ms 再放锁 | 防止同一槽位重入把分块流打断 | `thermalright-trcc-linux/dev/decompiler/BEHAVIOR_DISCOVERY.md:130`（`UCDevice.cs:1381`） |
| 20 | **持久 USB 发送 worker 线程**（跨帧复用，空闲 30s 退出） | 避免每次推帧重新建线程/重开会话 | `thermalright-trcc-linux/doc/CHANGELOG.md:4120` |
| 21 | **块级 dirty-region 引擎**（瓦片 + 合并 + 成本模型），且区域写失败即回退整帧并**永久禁用区域写** | 是"能不能局部刷新"的完整答案：先比较、再算成本、不行就回退。LY 面板走的就是回退路径 | `sensorpanel/pkg/panel/updater.go:40-140,233-251`；成本常数 `regionCommandOverhead = 680`（`:13`） |
| 22 | **复用 CGContext** 避免每帧分配 3.6MB；`autoreleasepool` 强制每帧释放 CGImage | 不这么做会**泄漏到 GB 级**（源码注释直说） | `MacTR/.../MonitorRenderer.swift:30-31,223-234`；`mac-thermalright-ai-monitor/.../AppState.swift:286-288` |
| 23 | **命令式空闲重发**：`trcc display keepalive --interval 0.150`（`count=0` 永久），CLI 单发帧**没有**保活流，必须配它 | 一次性 CLI 发帧后屏会在 2-3s 后回 splash | `doc/REFERENCE_CLI.md:522-537`；`doc/GUIDE_TROUBLESHOOTING.md:327-335` |
| 24 | **USB autosuspend 要关**：内核会在 ~30s 后重置空闲 USB 设备 → 屏回 splash；运行时 + udev 规则双管 | 这是"推帧正常但屏回 splash"的另一个真因 | `doc/CHANGELOG.md:3256`；同文件 `:3372`（静态主题 ~30s 闪待机符号 → 加 ~20s 保活） |

**另外三条与"呼吸"相关的补充证据**（不占编号，供交叉验证）：
- `trofeo-lcd-rs` 的自适应 FPS 档位是 `--idle-fps 2 / --active-fps 15`（`README.md:118`），
  且**开了动态背景或像素游戏时，空闲档被提到活动档**（`README.md:180-181,237-239`）。
- 我们自己的空闲档 2fps / 忙碌 15fps 就是照 `mac-thermalright-ai-monitor` 抄的（`README.md:245-246`）。
- `trofeo-lcd-rs` 的 `effect_fps` 默认 **8**，是独立于主帧率的第三档（`README.md:257`）——**与我们实测天花板 8fps 巧合一致**。

---

## §5 对我现有 7 个主题的逐条对标建议

> 我的主题定义与内容依据：`HANDOFF-打印机格复刻.md:92-105`（主题表）、`entry/src/main/ets/render/*.ets`。
> 令牌依据：`entry/src/main/ets/common/Theme.ets:5-37`（`C`）、`:40-132`（`L` 横装）、`:135-160`（`V` 竖装）、`:191-229`（`F` 字号系数）。

| 主题 | 可借鉴什么 | 怎么改 |
|---|---|---|
| **0 仪表盘**（`Dashboard.ets`；5 格 + 右侧 VM，`L.panelWidth = 274.4`） | ① **MacTR 的面板顶条 + 6 行渐隐光晕**（`DrawingPrimitives.swift:39-64`）：3px 强调色顶条 + `alpha 0.12·(1−i/6)` 的 6 行 1px 光晕 —— 这是 26 色令牌能"看起来成套"的关键，成本几乎为 0。<br>② **四列网格的列宽/间隙常数**（`DesignTokens.swift:78-92`）可直接对齐：`margin 14 / gap 10` 与我们完全一致，说明这套节奏已经对了。<br>③ **传感器类别 6 色**（`#32C5FF…`）比我们现在的 `C` 令牌更"黑底高对比"，可做第二配色档。 | 给 5 个面板各加一条 3px 顶条（系统=cyan `#22D3EE`、DSH=deepseek `#4D6BFE`、打印机=绿 `#34D399`、用量=紫 `#A78BFA`、VM=橙 `#FBBF24`）+ 6 行光晕。**不改任何坐标**，纯增量，风险为零。然后按 §4 第 10 条试 `jpeg_quality` 分档：文字多的档 0.9+、游戏 0.8（`docs/Bug修复清单-20261014.md:96` 已提过同一条）。 |
| **1 诊断终端**（`ThemeDiag.ets`；顶部标题 + 状态药丸 + 事件流 + 指标栏 + 体检条，17 个文字元素） | ① **三态状态徽章动效**（§2-T6）：2Hz 方波待授权 / 5s 三角波工作中 / 静态空闲。<br>② **金色皮肤**（§2-T8）：`#d9b45a` 强调 + `#1E1E1E` 底 + `#434343` 分隔线，天生适合"终端"气质。<br>③ **时间戳列 + 右对齐级别列**的等宽排版（trcc 的 `#7A7A7A` 等宽风格，`uc_led_control.py:387`）。 | `ThemeDiag.ets:54-57` 现在的状态药丸是 `busy→C.deepseek` / `idle→#12301C` / 其他→`#2A2A33`，**只有静态三色**。改成 `MacTR` 三态：把 `t = Date.now()/1000` 传进 render，`busy` 时 `alpha = 0.12 + 0.28*tri(t,5)`，`waiting` 时 `alpha = (floor(t*2)%2==0) ? 0.36 : 0.10`。**注意帧率门槛**：2Hz 方波在我们 8fps 下需要 4 帧才翻一次，`LcdService` 的空闲 2fps 会漏 —— 所以**待授权态必须把帧率提到 15fps**（`README.md:244-246` 已有这套判断，扩展状态即可）。 |
| **2 监控墙**（`ThemeWall.ets`；3 张曲线卡 + 右上健康灯；卡高 196、4 等分） | ① **MacTR 的镜像柱状图语法**（`MonitorRenderer.swift:429-442`）：上下分色、中央轴常画、当前值标在轴旁 —— 现在我们的曲线卡是单线，改成"上/下镜像 + 中央轴"信息量翻倍。<br>② **空闲时也要画中央轴**（源码注释：always-drawn center axis signals "monitored" even when idle）—— 空数据时画轴而不是留白，用户才知道"在监控"。<br>③ **`monitoring unavailable` 与之区分**（`:515-522`）：真读不到要显示 `N/A` + 说明文字，不要和"空闲"混淆 —— 这条对我们"桥端摘要"重要。 | `ThemeWall.ets:69-72` 现在是 3 张 196 高卡；建议改成 **4 张 196 高卡**（宽 `(1920−28−36)/4 = 464`，源码里其实已经算了 4 列的 `cw`，但只画了 3 张卡）。第 4 张放"token 速率镜像柱"（上=输出、下=输入），曲线下方加中央轴 + 当前值。健康灯（`:44-55`）的 `○` 空态建议改 `N/A` 字样（低帧率下小圆点辨识度差）。 |
| **3 分页屏**（`ThemePages.ets`；4 页 10s 翻页：打印机/余额/DSH/系统） | ① **trofeo-lcd-rs 的"每页独立时长"轮播**：`layout = default:30, weather:5`（`README.md:334-341`）—— 我们现在是**固定 10s 平均分**，改成"页名:秒"能让"打印机页看 30s、余额页看 5s"。<br>② **页指示点**可以做成 trcc 那种"选中填强调色"（`uc_rgb.py:82-88`：`indicator:checked { background: ACCENT }`）。<br>③ **`layout_hold_on_music` 思路**：`trofeo-lcd-rs` 在"有音乐"时**锁住第一页不轮播**（`README.md:203`）—— 我们可以在"agent 干活中"时锁住 DSH 页。 | 用 `RenderExtras` 增加 `pages: [{name, secs}]`，默认 `[打印机:20, 余额:8, DSH:25, 系统:8]`；`/set?dpage=N` 定点时**暂停轮播计时**（现在定点后一会儿就被翻走，体验差）。另加一条：**打印机正在打印时自动锁在第 1 页**（对应 `trofeo-lcd-rs` 的 `layout_hold_on_music`）。 |
| **4 打砖块**（`ThemePong.ets`；源 368×448 → 343×418，居中 origin≈(788,22)，缩放 0.9333） | ① **sensorpanel 的背景自氛围**（`index.html:9`）：用整帧背景 `blur + saturate + scale` 做底，前景再叠。打砖块的砖色块在纯黑上偏硬。<br>② **trofeo-lcd-rs 的 `peaks` 风格**（`spectrum.rs:62-63`）：峰值帽"保持后缓慢下落"—— 打砖块可以给"最高连击"做一个同样的峰值帽数字。<br>③ **调色板轮换**（`PRESETS` 12 套 + 交叉淡入 `FADE_SECS=4.0`，`effect.rs:34,103-116`）：砖块的 5 色行色可以每 30s 换一套调色板。 | `ThemePong.ets:57` 的砖块 5 色是固件原值 `['#FF0000','#FFA500','#FFFF00','#00FF00','#0000FF']` —— 这**正是被 4:2:0 吃掉的那套**（`HANDOFF-打印机格复刻.md:126-139` 实测蓝砖 0 像素）。`ThemeFwSim.ets:318` 已经预补偿成 `['#F01010','#F0A018','#F0E828','#20E020','#3A55E0']`，**主题 4 应同步这一组**（现在 `ThemePong` 还是原值，两个主题同一玩法两种颜色，是明确的不一致）。另：`eV` 风格参考 `spectrum.rs` 的 `peaks`，给"最高连击"加峰值帽。 |
| **5 Dotii 分页屏**（`ThemeDotii.ets`；源 368×448，4 页：表情/余额/打印机/自定义） | ① **Caelestia 的"壁纸 + 半透明遮罩 + 药丸 chip"**（§2-T1，`:88-110`）：我们的状态胶囊现在固定 138×48，源码已被指出"长文本必溢出"（`Bug修复清单-20261014.md:64`）—— Caelestia 的做法是**chip 宽度按内容算**（`host-chip 168` vs `status-chip 194`，两枚不同宽）。<br>② **NeonPulse 的 DIMM 圆**（`App.css:265-293`）比我们的 4 个圆点更"有物理感"（active/inactive 两态 + 标签在下方）。<br>③ 表情色的做法参考 `native.theme.json` 的 accent 三色（`#2de2ff/#ff4df3/#71ffa8`）—— 这组在 4:2:0 下**品红 `#ff4df3` 最危险**，要用要做预补偿。 | `ThemeDotii.ets:42-60` 的色板（`bambu #00AE42`、`faceCyan #58C8C8` 等）已经做过一轮预补偿，**不要动**。要动的是**几何**：把状态胶囊改成"宽度 = max(138, 文字宽 + 2·dotR + gap + 20)"（`Bug修复清单` 第 64 条已经给了公式，**但清单是待办、源码里可能还没改，需复核**）；`dim` 圆点改成 NeonPulse 那种 40px 圆 + 下方 9px 标签。 |
| **6 固件仿真屏**（`ThemeFwSim.ets`；轮播 `FW_ROTATION = [6,16,8,17]`，每 12s；已移植 12 个界面，6 个待移植） | ① **`trofeo-lcd-rs` 的 16 行配置项思路**：它把"每一项位置/字号/颜色/底板"全做成配置（`README.md:351-362`）—— 我们 18 个固件界面现在是硬编码，待移植的 6 个可以直接照配置表填。<br>② **`show/hide` 白名单**（`:204-207`）：固件仿真屏可以用同款机制做"隐藏某些行"调试。<br>③ **`/set?fws=100` 色卡标定页**（我们的）与 trcc 的调色板轮换（`PRESETS`）结合：色卡页可以直接循环 12 套调色板来目视选色。 | 唯一实质建议：**把 `ThemeFwSim` 的 `FW_ROTATION` 从"固定 12 秒"改成可配**（对齐 §5-主题 3 的每页独立时长），并且**色卡页 `/set?fws=100` 加上"预补偿前后并排"**（左半格画原值、右半格画预补偿值）—— 现在只有一列，没法直接比对。另外 6 个待移植界面（OTA/双机分屏/相机/电源确认/烘干/错误详情）**应优先照 `源码/include/layout_368x448.h` 的版面常量抄**，而不是 240×240 档（`HANDOFF-打印机格复刻.md:111-114` 已明确警告）。 |

**跨主题的两条统一建议**：
1. **加一层 `Anchor` 抽象**（借 `trofeo-lcd-rs` 的 9 锚点，§2-T11）：现在 7 个主题各自手算坐标，`Theme.ets` 里已有 `L`/`V`/`P`/`F` 四个类，
   再加 9 锚点工具后，新主题的坐标能少写一半，也更容易被 `layout_check.py` 审。
2. **把"帧率状态机"显式化**：现在只有 busy/waiting/idle/night 四档（`README.md:542`），
   但 §4 第 9 条要求**待授权单独提到 15fps**（否则 2Hz 硬闪会被 2fps 空闲档吃掉）。
   建议改成 `state → {fps, anim}` 的小表，而不是散在 `LcdService` 里的三元表达式。

---

## §6 需要你在终端补做的事

> 本机 shell 不可用（`spawn EPERM`），以下命令**我一条都没执行**。都属于"会写文件/联网"的操作，交给你的终端。

### 6.1 解 7z 主题包（原厂 1920×462 主题素材）

包已在本机（无需下载）：`~/.cache/trcc/repos/thermalright-trcc-linux/src/trcc/data/`
共 33 个包，**与我们这块屏相关的 4 个**：
`theme1920462.7z`（原厂主题）、`theme1920440.7z`、`theme4621920.7z`（竖装）、以及对应的 `web/`/`zt` 遮罩包（若已补下）。

trcc 自己用的正是系统 `7z`（`adapters/repo/data_install.py:89-140`，含 zip-slip 防护；
`core/toolchain.py:55` 会依次找 `7z`/`7zz`/`7za`/`7zr`）。**照它的语义写命令**：

```bash
# 0) 先确认有 7z（Fedora 装的是 7za，不是 7z，见 core/toolchain.py:9-13）
command -v 7z 7zz 7za 7zr

# 1) 先列目录（trcc 也是先 l -slt 再 x，为了做 zip-slip 校验）
7z l -slt ~/.cache/trcc/repos/thermalright-trcc-linux/src/trcc/data/theme1920462.7z | head -40

# 2) 解到工作区（-o 后面不要有空格；-y 覆盖）
mkdir -p ~/WorkBuddy/TrofeoLCD/themes/stock-1920462
7z x ~/.cache/trcc/repos/thermalright-trcc-linux/src/trcc/data/theme1920462.7z \
   -o$HOME/WorkBuddy/TrofeoLCD/themes/stock-1920462 -y

# 3) 竖装版（同型号换个方向，可作竖屏主题参考）
mkdir -p ~/WorkBuddy/TrofeoLCD/themes/stock-4621920
7z x ~/.cache/trcc/repos/thermalright-trcc-linux/src/trcc/data/theme4621920.7z \
   -o$HOME/WorkBuddy/TrofeoLCD/themes/stock-4621920 -y

# 4) 顺手看一眼有哪些包（确认没漏）
ls -la ~/.cache/trcc/repos/thermalright-trcc-linux/src/trcc/data/*.7z | wc -l   # 应为 33
```

**若 7z 缺失**：Debian/Ubuntu `sudo apt install p7zip-full`；Fedora `sudo dnf install p7zip`（只会得到 `7za`，
上面 `command -v` 那步会告诉你实际名字，把后续命令里的 `7z` 换成它）；macOS `brew install p7zip`；
Windows `winget install 7zip.7zip`（`adapters/system/{linux,macos,windows}.py` 的 install hint）。
`7z`/`p7zip` 都不可用时，Python 侧可以用 `py7zr`：`python3 -m pip install py7zr && python3 -c "import py7zr;py7zr.SevenZipFile('…theme1920462.7z').extractall('…')"`
—— **注意** trcc 项目本身**没有**用 py7zr，它坚持外部 `7z` 二进制，所以上面的命令才是"照它的语义"。

### 6.2 补 clone（本次未读到的两处 + 一个上游）

```bash
cd ~/.cache/trcc/repos

# 1) trofeo-lcd-rs 的上游原版（我们手上的是 fork，且本地**没有 .git**）
git clone --depth 1 https://github.com/sukualam/trofeo-lcd.git

# 2) 本仓库需补 .git（现在 5 个仓库都没有版本信息，导致我无法给出"最近更新"）
#    如果这些是 --depth 1 抓下来的源码快照，重 clone 才能拿到提交日期：
for r in thermalright-trcc-linux sensorpanel trofeo-lcd-rs MacTR mac-thermalright-ai-monitor; do
  echo "== $r"; ls -d ~/.cache/trcc/repos/$r/.git 2>/dev/null || echo "  无 .git（需重 clone 才能取日期/star 无从判断）"
done

# 3) MacTR 与 mac-thermalright-ai-monitor 的准确仓库地址（本机无 .git，只能靠 README 线索）
git clone --depth 1 https://github.com/beret21/MacTR.git            # MacTR（appcast.xml:5 给出）
git clone --depth 1 https://github.com/beret21/mac-thermalright-ai-monitor.git   # ← 地址未核实！
```

> **第 3 条最后一行我标了"未核实"**：`MacTR/appcast.xml:5` 明确写了 `https://github.com/beret21/MacTR`，
> 但 `mac-thermalright-ai-monitor` 的 README 我**没有读到**，所以它的 owner 是我猜的（`beret21`）。
> 先 `git ls-remote` 试一下，404 就去搜。

### 6.3 可选（想拿 star / 最近更新）

本机 GitHub 被 DNS 污染。要拿这两列数字，需要一条能出网的通道：

```bash
# 在能出网的机器上跑，或先解决 DNS
for r in Lexonight1/thermalright-trcc-linux oae/sensorpanel haven80/trofeo-lcd-rs; do
  curl -s "https://api.github.com/repos/$r" | python3 -c \
    "import sys,json;d=json.load(sys.stdin);print(d['full_name'],d['stargazers_count'],d['pushed_at'],d['language'])"
done
```

---

## §7 未找到 / 未复核 清单（诚实清单）

### 7.1 明确未找到

| 项 | 说明 |
|---|---|
| **star 数** | 5 个仓库全部未取得。本机 GitHub DNS 污染，`web_search` 只回标题。**§1 表里不填，拒绝编造。** |
| **最近更新时间** | 同上。5 个仓库**都没有 `.git/`**（我 glob 了 `.git/HEAD` 与 `.git/*`，两次都是 No files found），无法取提交时间。只能用仓库内版本号推断新鲜度（trcc 自称 9.3.3 / sensorpanel v1.1.0(2026-01-31) / trofeo-lcd-rs 1.0.50 / MacTR 1.3.16(2026-08-02)）。 |
| **`web/1920462.7z` 云主题缩略图包** | `src/trcc/data/` 下只列到 `theme*.7z`（33 个），**没有看到 `web*` 或 `zt*` 压缩包**。按 `adapters/repo/data_install.py:4-20` 它们是**运行时从 GitHub 下载**的，不在仓库里。 |
| **trcc 主题包内的具体画面** | `.7z` 是二进制，`read` 工具直接报 `binary file`，**我无法在不解包的情况下看里面有什么**。所以 §2-T12 只能写"体系"，不能写"长什么样"。**这是解包（§6.1）后才能补的最大空白。** |
| **NeonPulse / Trofeo Native 在 1920×462 上的真实渲染** | 两套主题的源画布分别是 480×320 与（竖装）462×1920，**它们从没在 1920×462 上跑过**。我给的适配建议是按比例推算的，**没实测**。 |
| **trofeo-lcd-rs 的 13 个预设布局的具体坐标** | 只有名字与截图路径。截图是 PNG，`layout-*.png` 的布局细节**未复核**（我没有读图工具去测像素，且这是本会话的能力边界）。 |

### 7.2 未复核（文件存在、内容没读全）

| 文件 | 状态 |
|---|---|
| `sensorpanel/pkg/renderer/renderer.go` | ⚠️ **完全未读**（§2-T9 因此只写了"存在"）。这是 `sensorpanel run` 的默认渲染路径，应该优先补。 |
| `thermalright-trcc-linux` 的 95 个 CLI 命令 / 78 个 API 端点 | 只读了 `theme` / `display keepalive` / 7z 安装相关部分。其余未读。 |
| `thermalright-trcc-linux/dev/decompiler/AUDIT_THEME_MASK.md` | **只确认存在**，内容未读。主题遮罩的机制细节（§2-T12）是从 `data_install.py` 的注释推断的。 |
| `thermalright-trcc-linux/src/trcc/ui/qtgui/**` | 只 grep 到几处 hex，**没有系统性读过 Qt GUI 的皮肤**。§3.4 里 Qt 那几行是 grep 命中，不是读全文件。 |
| `MacTR` 的 `SettingsView.swift` / `MenuBarView.swift` / `AlertManager.swift` | 未读。 |
| `mac-thermalright-ai-monitor` 的 `AgentUsageCollector.swift` / `PikachuAsset.swift` / `BongoCatAsset.swift` | 只 grep 到命中行，未通读。像素资源（Pikachu/BongoCat）**没有读**。 |
| `trofeo-lcd-rs` 的 `pixel_game.rs` / `music_screen.rs` / `weather_icon.rs` / `ticker.rs` / `lib.rs` | 未读。像素游戏与音乐屏的细节**全部未复核**（README 里的描述我照引了，但没验源码）。 |
| `sensorpanel/docs/creating-themes.md` / `management-studio.md` / `media-modes.md` | 未读（只读了 `performance.md`）。 |
| 我自己的 `ThemePages.ets` / `ThemeDiag.ets` 全文 | 只 grep 了颜色、读了 `ThemeWall.ets` 前 80 行。**§5 里对主题 1/3 的建议是基于 grep 与 HANDOFF 文档，不是逐行读码**。 |
| `docs/Bug修复清单-20261014.md` 里的修复是否已落地 | **未核实**。§5-主题 5 引用的"状态胶囊溢出"公式来自该清单，但清单是**待办清单**，源码里可能还没改。 |

### 7.3 我**故意没做**的事（避免越界）

- 没有创建 `docs/` 之外的任何文件；没有改动 `~/.cache/trcc/repos/` 下任何仓库；没有解包任何 `.7z`。
- 没有编造任何 hex、坐标、star、日期。凡是推算出来的都标了「实测值＝算得」或「按比例推算」。
- 没有把 README 的宣传当事实：`sensorpanel` 的 "Regional USB updates" 我按代码写成**不支持**（§4 第 12 条）。

---

## 附：本文件的证据索引（便于回查）

```
trofeo-lcd-rs     src/spectrum.rs:100-140,117-123   频谱 8 套预设 + 9 个名字
                  src/effect.rs:24-34,78-116        背景 12 项 PRESETS（11 套字面量 + rainbow 生成）+ 6 个常数
                  README.md:118,180-181,204-213,237-239,257,323,334-341,351-362
                  Cargo.toml:3                      v1.0.50
sensorpanel       docs/performance.md:1-38,70-79     分层管线 + volatile + 丢帧 + 1FPS 保活 + 实测 CPU
                  themes/trofeo/native.theme.json   竖装 462×1920 + accent 三色 + q68 + 24fps 背景序列
                  themes/trofeo/src/App.css         四列网格（超宽）+ 全部 hex
                  themes/caelestia/native.theme.json 逐 widget rect（最完整的坐标集）
                  themes/caelestia/caelestia-palette.json 20 条 色→语义名 映射
                  themes/neonpulse/src/App.css      480×320 2×2 + 全部 hex
                  themes/neonpulse/src/App.tsx:103-110 环几何（r=40, dasharray 251.2）
                  pkg/panel/device.go:857-868       LY 不支持局部刷新（显式报错）
                  pkg/panel/updater.go:13,40-140,233-251 dirty-region 引擎 + 680 成本常数
                  pkg/music/dashboard/index.html    480×320 音乐卡 + 48 根波形
                  CHANGELOG.md:22                   v1.1.0 (2026-01-31)
MacTR             Sources/MacTR/Rendering/DesignTokens.swift:11-41,78-92 26 色令牌 + 5 格布局
                  Sources/MacTR/Rendering/MonitorRenderer.swift:258-695  5 格逐格内容 + 自适应字号/行距
                  Sources/MacTR/Rendering/DrawingPrimitives.swift:16-64,72-111 渐变底/面板顶条+光晕/弧表
                  Sources/MacTR/Rendering/FrameRenderer.swift:27-28,67-77  JPEG 650KB + 质量递减
                  appcast.xml:5,10,28               beret21/MacTR + v1.3.16 (2026-08-02)
mac-thermalright-ai-monitor
                  Sources/MacTR/Rendering/MonitorRenderer.swift:692-734,739-759,781-798 三态徽章 + 2Hz + 三角波
                  Sources/MacTR/App/AppState.swift:271-288,295-296  自适应帧率 + 夜间 + autoreleasepool
                  Sources/MacTR/Rendering/DesignTokens.swift  同 MacTR 但无 *D 三色，多 claude/cursor/cursorDim
thermalright-trcc-linux
                  src/trcc/data/theme*.7z           33 个主题包（含 theme1920462.7z）
                  src/trcc/adapters/repo/data_install.py:4-25,78-140  7z 语义 + zip-slip 防护 + 三目录结构
                  src/trcc/core/toolchain.py:9-13,45-55              7z/7zz/7za/7zr 探测顺序
                  doc/REFERENCE_CLI.md:522-537      display keepalive --interval 0.150
                  doc/SEND_FOUNDATION.md:28,44,48,53 volatile 重发 @150ms + 设备发送者
                  doc/CHANGELOG.md:3254,3256,3372,4120  重发缓存叠加帧 / autosuspend / ~20s 保活 / 持久发送线程
                  doc/DEVELOPMENT_STATUS.md:5-7     v9.3.3 + 5603 测试
                  doc/GUIDE_TROUBLESHOOTING.md:327-335  CLI 单发帧无保活流
                  dev/decompiler/AUDIT_LCD_PIPELINE.md:66   450000 超限丢帧 + 降质 5
                  dev/decompiler/AUDIT_DISCOVERY.md:130,139  槽位互斥+30ms / 队列背压丢帧
                  dev/decompiler/AUDIT_DISCOVERY.md:227     ImageToJpg 旋转嵌套表 + 自适应质量
                  core/models.py:1737-1742          传感器类别 6 色
                  ui/gui/uc_rgb.py:43-95            金色皮肤
                  ui/gui/constants.py:13-56         深色窗口族
                  src/trcc/core/_colors.py:24-42    #RRGGBB / #RRGGBBAA 解析（alpha 支持）
本工程            entry/src/main/ets/common/Theme.ets:5-37,40-132,135-160,191-229  C/L/V/P/F 令牌
                  entry/src/main/ets/render/*.ets   7 个主题的渲染器（颜色见 §2 引用）
                  docs/明早简报-20261014.md:31,54-89   DNS 污染 / 4:2:0 预补偿 / 帧率天花板 8fps
                  HANDOFF-打印机格复刻.md:92-105,107-150  主题表 / 源画布 0.9333 变换 / 两个坑
                  README.md:244-246,535,640-643     自适应帧率 / JPEG 降质序列 / base64 往返开销
```
