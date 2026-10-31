# Windows 版部署：为什么"没见同步" + 怎么让主题和数据桥到 VM 上

> 结论先说：**源码我改在鸿蒙这边的仓库里，VM 上那份是旧副本** ——
> 主题代码需要**重新编译成 exe** 才能看到；数据桥则**根本没有 Windows 启动方式**。
> 这两件事是分开的两个缺口，下面各自说明。

## 一、主题为什么"没见同步"

### 时间线（这是最直接的证据）

| 时间 | 事件 |
|---|---|
| 10-15 **02:11** | VM 构建出 `dshlcd_*_v30.exe`（**你运行的就是这个**） |
| 10-15 **03:03~03:23** | 我在这边仓库写入 11 个主题文件（`ThemeCore.cs` / `ThemeDotii.cs` / `ThemePong.cs` …） |
| 10-15 **07:46** | 我把 31 个 `.cs` + 6 个图片资产同步到 VM 共享盘 `C:\dshlcd\` |

**所以：新主题在你的 exe 里确实没有 —— 因为 exe 是 02:11 编的，代码是 03:03 之后写的。**
`win/dist/` 下最新的 v30 也一样（02:11），它编不出来后来的代码。

### 已经做了什么

`C:\dshlcd\src\` 里现在应该是 **31 个 `.cs`**（含 11 个新主题文件），根目录还有 6 个图片：

```
bg_sample.jpg  trcc_official_1.png … trcc_official_5.png
```

### 你要做的（一步）

**✅ 同步已完成**：`C:\dshlcd\` 现在是

```
src\            31 个 .cs（含 12 个新主题文件）
bg_sample.jpg + trcc_official_1..5.png    6 个图片素材（扁平放在根目录）
build.cmd        已更新为兼容扁平布局
dsh-bridge.mjs + start.cmd + stop.cmd    数据桥
```

在 VM 里：

```cmd
cd /d C:\dshlcd
build.cmd
```

产物是 **`out\dshlcd2.exe`**（`/platform:anycpu`，ARM64 上能跑），直接运行它。

`build.cmd` 用 `"%SRC%\*.cs"` 通配，**新文件自动收进去**，不用改脚本。

> ⚠️ 别用 `build-variants.cmd` —— 它需要 `roslyn\csc.exe`，而那个目录在共享盘里不存在
> （`build.cmd` 用的是系统自带的 `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`）。
>
> ⚠️ 我另外给图片加载加了**向上找 2 级父目录**的兜底：即使你把 exe 从 `out\` 单独拷到别处，
> 只要图片还在附近就能找到。失败是静默的（退回程序化配色），所以在源头堵掉了。

> ⚠️ **一个已知的未同步项**：我后来把 `build.cmd` 改成了**兼容扁平布局**
> （原来的版本只会从 `assets\` 子目录找图片，而这个共享盘**不允许新建子目录**，
> 所以图片只能平铺在根目录）。VM 上那份 `build.cmd` 可能还是旧的。
> 如果是旧的，图片没被复制到 exe 同级，表现是：**主题 7（TRCC）和背景图模式看不到图**，
> 但主题本身正常。两种解法任选：
> - 手动把 6 个图片复制到和 exe 同目录
> - 或者从仓库取最新的 `win/build.cmd` 覆盖过去

## 二、数据桥为什么"没有"

### 缺口在哪

桥本体 `bridge/dsh-bridge.mjs` 是 **Node 脚本，本来就跨平台**。但：

| 缺口 | 说明 |
|---|---|
| **没有 Windows 启动脚本** | 原来只有 `start.sh`（bash），Windows 跑不了 → exe 有 UDP 接收器（默认 **54545**，与桥一致），**却没人往里推数据** |
| **`zstd` 依赖** | 桥要解 `session.jsonl.zstd`，走的是外部 `zstd` 命令。**Windows 不自带 zstd** → 桥会"起来了但永远没有遥测" |
| **`/bin/sh` 依赖** | 歌词功能用 `execFile('/bin/sh', ...)`，Windows 没有 `/bin/sh`（这个功能可选，不指定就不触发） |

后两个我已经在桥里修好了（见下）；第一个我补了 `start.cmd`。

### 已经做了什么

`bridge/win/` 目录（在鸿蒙这边仓库里），包含：

| 文件 | 说明 |
|---|---|
| `dsh-bridge.mjs` | 桥本体，已修 Windows 兼容性 |
| `start.cmd` | Windows 启动脚本（对应 `start.sh`，含日志轮转、zstd 缺失提示） |
| `stop.cmd` | 停止脚本 |

桥的三处修复：

1. **`ZSTD_BIN` 统一解析**（3 处引用）：环境变量 `DSH_LCD_ZSTD` → **脚本同目录的 `zstd.exe`** → PATH。
   Linux/鸿蒙 的既有行为完全不变（还是走 PATH）。
2. **`/bin/sh` → 平台化**：Windows 用 `cmd.exe /d /s /c`。
3. `spawn('zstd', ...)` 两处改用 `ZSTD_BIN`。

### 你要做的

1. **把 `bridge/win/` 整个拷到 VM**，例如 `C:\dshlcd\bridge\`
2. **下载 zstd.exe**（必须，否则桥收不到数据）：
   https://github.com/facebook/zstd/releases → 选 `zstd-v*-win64.zip` → 解出 `zstd.exe`
   放到 `C:\dshlcd\bridge\`（桥会优先找同目录）
3. 启动：
   ```cmd
   cd /d C:\dshlcd\bridge
   start.cmd
   ```
   有打印机就 `start.cmd --printer http://127.0.0.1:8790/api/state`
4. 验证：桥起来后 exe 的 `/diag` 里 `bridgeAgeSec` 应该是 0~1 秒级；
   如果一直是 -1，看 `.bridge.log` 尾部（`start.cmd` 会自动打印最后 5 行）。

## 三、为什么这次没能全部推过去

我这边能**看到并写入** VM 的共享盘（`C:\dshlcd` 映射到
`~/.VMDocs/.hwf_share/.disks/C/dshlcd`），所以 07:46 那批 31 个 `.cs` 是我直接写过去的。

期间共享盘掉过一次（`Resource busy`），**现在已恢复，全部同步完成**：

| 项 | 状态 |
|---|---|
| 31 个 `.cs` | ✅ 在 `C:\dshlcd\src\` |
| 6 个图片素材 | ✅ 扁平放在 `C:\dshlcd\` |
| `build.cmd` | ✅ 已更新（兼容扁平布局） |
| `dsh-bridge.mjs` / `start.cmd` / `stop.cmd` | ✅ 在 `C:\dshlcd\` |
| 图片加载的父目录兜底（`FindNear`） | ✅ 已同步 |

**剩下只有两步是 VM 侧的动作**：`build.cmd` 编译，以及给桥准备 `zstd.exe`。

---

# 附：2026-10-15「闪退」的两个根因（都已修）

## 根因一：`.cmd` 换行符 —— 我送过去的文件是 LF，cmd.exe 解析错乱

**症状**：`build.cmd` 和 `start.cmd` **窗口一闪就退**，不报错。

**原因**：`cmd.exe` 解析 .cmd 时对换行敏感。VM 上原有的 .cmd 全是 **CRLF**
（实测 `v30.cmd` CRLF=8/纯LF=0、`diag.cmd` CRLF=5/纯LF=0），
而我从仓库拷过去的是 **LF**（仓库里几份 .cmd 恰好都是 LF，我据此误判"LF 没问题"）。

**修法**：三个脚本统一转 **CRLF**，并**把仓库侧也改成 CRLF**（避免下次同步再踩）。

**教训**：判断"某种换行能不能用"要看**目标平台既有的、能跑的文件**，不是看源仓库。

## 根因二：Dispose 了共享缓存字体 —— 运行几秒必崩

**症状**：exe 能编译、能启动，但**跑几秒就闪退**。

**原因**：`win/src/Theme.cs` 的 `F.Get` 是按 (字体族, 尺寸, 粗细) **缓存**的静态字体：

> "Font 是按 …缓存的静态对象 —— 每帧 new 几十个 Font 会很快耗光 GDI 句柄。
>  **缓存对象不要 Dispose**；要释放请调 `ClearCache()`。"（`Theme.cs:249-250`）

也就是 `F.SansFont(14, false)` **每次返回同一个实例**。
我移植 C# 主题时按"谁创建谁释放"的通用习惯，在 149 处加了 `.Dispose()`
—— 那等于**把共享缓存销毁**，下一帧再取出这个已销毁的 Font 去 `DrawString`
→ GDI+ 抛 `ArgumentException: Parameter is not valid` → **进程闪退**。

**修法**：删净全部 **149 处**字体 Dispose（只剩 2 处 `img.Dispose()` 是合法的
`Image.FromStream` 资源）。释放字体只在退出时用 `F.ClearCache()`。

**防复发**：`tools/csharp_audit.py` 新增 `check_font_dispose()` ——
扫描"从 `F.SansFont`/`F.MonoFont`/`new Font` 赋值的变量是否被 Dispose"，
并在文档字符串里写明踩坑经过。**已用"故意注入一处泄漏"反向验证过它能抓到。**

**教训**：`F.SansFont` 这类**返回缓存/共享实例**的工厂函数，
调用方**没有所有权**，不能 Dispose。用之前先看那个函数的注释。

---

# 附二：2026-10-15 编译迭代记录（每轮的错误类型都在收敛）

| 轮次 | 错误数 | 类型 | 根因 |
|---|---|---|---|
| 1 | 13 | `CS1518/CS0116/CS1022` | `ThemeCore.cs` 里 `TrccStateFrom` 落在 `Themes` 类**外**（游离成员） |
| 2 | 2 | `CS0246/CS0426` | `ShrinkText` 参数写成裸 `Align`（应为 `Draw.TextAlign`）；`ThemePong.PongSnapshot` 是命名空间级类、不是嵌套类型 |
| 3 | 26 | 7 类 | **类型名遮蔽**（`Themes` 的常量 `Dashboard` 遮蔽 `Dashboard` 类、`PongHolder.State()` 遮蔽 `State` 类）+ `Log.I` 不存在 + `StrokeRounded` 参数个数 + `DateTime`↔`long` 混用 + `AsBool` + `LineCap` 缺 using |
| 4 | 3 | `CS1502/CS1503` | `long`（epoch 毫秒）传给了要 `DateTime` 的 `Dashboard.Render*` —— 与第 3 轮**方向相反**的同一个坑 |
| 5 | **脚本没跑起来** | `'LF'/'evel' 不是内部或外部命令` | ★ **`.cmd` 编码**：我给的是 **UTF-8**，而中文 Windows 的 cmd 用 **GBK(936)** 读 → 中文注释被错解并截断行。VM 上原有能跑的 `.cmd` 全是**纯 ASCII**（这点当时没看） |

## 最终修法

**`.cmd` 一律纯 ASCII**（`build.cmd` / `start.cmd` / `stop.cmd` 已改），
并把脆弱的嵌套 `if/else` 换成 `call :sub`。工具：`tools/cmd_check.py`
（编码 / CRLF / 括号平衡 / `goto` 标签存在性 / 延迟展开 / `for` 里嵌 `else`）。

**时间类型统一**：`Dispatch` 的 `now` 是 **epoch 毫秒（long）**（14 个主题都要这个量纲），
只在调用 `Dashboard` 时换算成 `DateTime wall`。工具：`tools/csharp_types.py`
（作用域级类型跟踪，**只查 `DateTime` ↔ `long` 混淆** —— 通用类型推断在 C# 上不可靠，
放宽会淹没真问题；已用"注入真实 bug"做回归验证）。

**同步**：`tools/sync_to_vm.sh`（带重试 + **逐字节 md5 校验**）。
共享盘会间歇性只暴露部分内容（`C` 可见但 `dshlcd` 消失），所以不能"探测一次存在"就宣布成功
—— 这点也误报过一次。
