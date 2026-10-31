# dshlcd —— Windows 绿色单文件版

给**利民 Trofeo Vision 9.16 寸 LCD（1920×462，USB Bulk）**用的自定义仪表盘，功能对齐本工程的鸿蒙版。

- **一个文件**：`dist/dshlcd.exe`（约 107 KB，无 DLL、无安装、不写注册表）
- **依赖**：只有 Windows 自带的 .NET Framework 4.x（Win10/11 默认有）
- **架构**：AnyCPU —— x64 / ARM64 都能直接跑（已在 **Windows 11 ARM64** 虚拟机上实测运行）
- **不放后台服务**：双击就跑，关掉进程就停

---

## 0. 该用哪个文件（**先看这里**）

`win/dist/` 里有三个 exe，功能完全一样，只是**目标架构**不同：

| 文件 | 用在 | 说明 |
|---|---|---|
| `dshlcd_arm64.exe` | **ARM64 Windows**（骁龙本、Surface Pro X、本项目的 Win11 ARM 虚拟机） | PE 机器类型 = ARM64，**原生运行**，不会被当成 x86 应用 |
| `dshlcd_x64.exe` | **x64 Windows**（绝大多数台式机/笔记本） | 原生 x64 |
| `dshlcd_anycpu.exe` | **32 位 x86 Windows**，或不确定时兜底 | PE32（带 32BIT_MACHINE 标志）；在 ARM 机器上会走 x86 模拟层 |

> **为什么之前会弹「应用不兼容或性能缺陷」**：早先那版是用 Windows 自带的旧 csc
> （.NET Framework 4.8 的 4.8.9221.0）编的，它 `/platform` 只支持
> `x86 / Itanium / x64 / arm / anycpu`，**没有 arm64**，所以产物是 PE32 + 32BIT_MACHINE，
> Windows on ARM 就按「x86 应用」对待（模拟运行 → 弹兼容/性能提示）。
> 现在改用 Roslyn csc（`Microsoft.Net.Compilers.Toolset`，放在 VM 的 `C:\dshlcd\roslyn\`）
> 编出真正的 ARM64 原生版，并在 ARM64 虚拟机里跑过自检 125/125。

## 1. 快速开始

```
双击对应架构的那个 exe（见第 0 节）
```

**关于"双击了没反应"**：程序是**无主窗口**的常驻进程，早先版本连控制台都不给，
双击后确实什么都看不到（会被误会成"没反应"）。现在**默认会弹出一个控制台窗口**，
并持续打印状态（遥测包数、帧数、端口、屏幕连接情况）。想要安静后台跑就加 `--hidden`。

排查三步：

1. 看有没有那个黑色控制台窗口 → 没有的话，多半被 SmartScreen/杀软拦了：右键 exe →
   属性 → 勾"解除锁定"，或先放行。
2. 运行 `dshlcd_xxx.exe --doctor` —— 它会打印系统/架构/CLR/端口占用/exe 目录是否可写/USB 枚举
   结论，并把报告写进 `dshlcd.log`。
3. 直接看 exe 同目录的 **`dshlcd.log`**（若是只读目录会自动写到 `%TEMP%`）。日志第一行就是版本与时间。

默认行为：

| 项 | 默认值 |
|---|---|
| 遥测监听 | `127.0.0.1:54545`（UDP，和鸿蒙版同一协议） |
| 预览/诊断网页 | `http://127.0.0.1:54546/`（浏览器打开即可看画面 + 切横竖屏） |
| USB 推屏 | 开启（找不到屏就静默重试，5 秒一次，被拒 2 次后停手） |
| VM 画面源 | 未配置（右侧/下部面板显示占位） |
| 布局 | 横向 1920×462 |

想要固化参数：在 exe 同目录放一个 `dshlcd.ini`，或者先运行一次

```
dshlcd.exe --write-ini
```

生成带注释的模板（**命令行参数优先于 ini**）。常用项：

```ini
vertical = 1                     # 竖装：内容旋转 90°，逻辑 480×1920
vm-url = http://172.16.101.1:8787/vm/frame.jpg   # VM 监视画面
udp-any = 1                      # 桥端在别的机器上时打开（并放行防火墙 UDP 54545）
interval = 100                   # 固定帧间隔；不写 = 按 agent 忙碌/空闲自适应 66/500ms
night = 1                        # 18:30–09:00 降到 3 秒一帧
```

数据从哪来：

- **DSH 会话状态 / token 用量 / 待办**：由桥端 `bridge/dsh-bridge.mjs` 用 UDP 推过来。
  桥端和 exe 不在同一台机器时：
  ```bash
  node bridge/dsh-bridge.mjs --host 192.168.1.50     # 目标机器 IP
  ```
  对应的 exe 侧要 `udp-any = 1`（或 `--udp-any`）。
- **系统监控**：exe 自己采样本机（CPU/内存/主机名/运行时长），不需要额外依赖。
- **VM 画面**：抓 `livepad` 的 `/vm/frame.jpg`，`vm-url` 指向它的地址即可。

## 2. 命令行速查

```
dshlcd.exe                      # 正式运行
dshlcd.exe --selftest           # 协议/调度/归一化自检（结果写日志）
dshlcd.exe --probe              # 列出 USB 设备并尝试打开 LY 屏
dshlcd.exe --render out.jpg     # 用本机数据渲染一帧（不推屏）
dshlcd.exe --demo --seconds 8   # 合成遥测跑完整链路（自带 HTTP 自测）
dshlcd.exe --console            # 附加控制台窗口看日志（默认无窗口）
dshlcd.exe --help
```

常用选项：`--vertical 0|1`、`--rotate180 0|1`、`--night 0|1`、`--interval <ms>`、
`--vm-url <url>`、`--http-port <n>`、`--udp-port <n>`、`--udp-any`、`--no-usb`、
`--no-http`、`--pid 0x5408`、`--log <文件>`。

日志默认写在 **exe 同目录的 `dshlcd.log`**（无控制台窗口时的唯一输出通道）。

## 3. 与鸿蒙版的功能对齐

| 功能 | 鸿蒙版 | Windows 版 |
|---|---|---|
| LY 协议（2048B 握手 / 512B 分块 / 4096B 写 / 512B ACK） | ✅ | ✅ 逐字节同构（同一套参考实现生成的期望值） |
| 设备消歧（PM/SUB/FBL、1920×480/440/462、1280×480） | ✅ | ✅ |
| 旋转规则（SUB∈{2,3,4}→0° 等） | ✅ | ✅ |
| UDP 遥测 + 字段归一化（类型不可信） | ✅ | ✅ 同一套收敛规则 |
| 仪表盘（DSH 会话 / 系统 / 用量 / 待办 / 时钟 / VM 画面） | ✅ | ✅ 逐行移植 |
| 竖装布局（480×1920 逻辑，旋转 90°） | ✅ | ✅ |
| 自适应帧率（忙 66ms / 闲 500ms / 夜间 3000ms） | ✅ | ✅ |
| USB 打开退避（被拒 2 次停自动重试） | ✅ | ✅ ✅（Web 页面可手动重连） |
| 画质阶梯（超 650KB 就降质量，下限 0.4） | ✅ | ✅ |
| 预览/诊断接口 | ✅ 54546 | ✅ 54546（`/`、`/preview`、`/frame.jpg`、`/status`、`/diag`、`/set`、`/probe`） |
| VM 画面（livepad） | ✅ | ✅ |
| 打印机卡片（拓竹，含 AMS 托盘/HMS 告警） | ✅ 真机验证 | ✅ 数值对齐（见下） |
| 竖装 SYSTEM 面板行重叠修复 | ✅ 真机验证 | ✅ 同值移植 |
| 天气 / 歌词 | 桥端可选 | 桥端可选（同一份数据） |

**行为差异（有意为之）**：

- 竖屏时**不叠加** `rotate180` —— 与鸿蒙版实测一致（竖装时 90° 就是正立方向）。
- 横屏时 `rotate180` 默认按握手结果自动决定（真机 9.16 为 180°），也可以 `--rotate180 0|1` 强制。
- 鸿蒙版的 USB 授权弹窗、画布标定在 Windows 上不存在（不需要授权；GDI+ 直接按设备像素画）。
- 面板底部那几行"USB ● N帧 / 桥 ● Ns"在 Windows 版用等价信息顶替（没有 FrameStats 传入），位置字号不变。

## 4. 代码结构（`win/src/`）

| 文件 | 作用 |
|---|---|
| `Ly.cs` | LY 协议：握手包、响应解析、分块流、写分段、JPEG 尺寸解析、FNV |
| `WinUsb.cs` | WinUSB 直连（SetupAPI 枚举 + `winusb.dll` P/Invoke），无 libusb 依赖 |
| `State.cs` / `Json.cs` | 遥测模型 + 归一化（对齐鸿蒙版 `Normalize.ets`）+ 自研极简 JSON |
| `Telemetry.cs` | UDP 遥测接收（54545） |
| `VmSource.cs` | VM 画面抓取（HTTP → 位图，抓取时降采样，双缓冲防撕裂） |
| `MiniHttp.cs` | 裸 TcpListener 的预览/诊断服务（免 URL ACL，非管理员可用） |
| `Dashboard.cs` / `Theme.cs` | 仪表盘渲染（System.Drawing，横竖两套布局）+ 视觉令牌 |
| `SysMon.cs` | 本机 CPU/内存/运行时长采样 |
| `Schedule.cs` | 帧调度、夜间窗口、USB 退避（对齐 `SchedulePolicy.ets`） |
| `LcdRunner.cs` | 帧循环：遥测 → 渲染 → 编码 → 推屏 + 诊断接口接线 |
| `Program.cs` | 入口、参数/ini、自检/探测/单帧/演示/正式运行各模式 |
| `SelfTest.cs` | 119 项自检（协议 + 调度 + 归一化 + JSON） |

## 5. 怎么构建（在本机的 Windows 11 ARM64 虚拟机里）

Windows 侧只有 .NET Framework 自带的老 csc，**语言上限 C# 5**（没有 Roslyn / dotnet SDK / VS）：

```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe
  /target:winexe /platform:anycpu /codepage:65001 /reference:System.Drawing.dll
```

仓库里已经有一条从「鸿蒙主机 → 虚拟机」的完整构建+验证通道（见 `tools/win.py`）：

```bash
cd ~/WorkBuddy/TrofeoLCD
python3 tools/win.py build                  # 推源码进 VM 并编译，回读 build.log
python3 tools/win.py run "--selftest"       # 在 VM 里跑，回读 dshlcd.log
python3 tools/win.py run "--demo --seconds 8 --out-frame C:\\dshlcd\\out\\demo.jpg"
python3 tools/win.py log                    # 看上次日志
```

原理：客户机磁盘直挂在主机上（`~/.VMDocs/.hwf_share/.disks/C` ⇄ `C:\`），
源码推过去 VM 立刻可见；执行靠 livepad 的输入注入（Win+R → 文本 → 回车）；
日志写在共享盘上，主机直接读回。并发注入有文件锁串行化（`vm_exec.py` 的 `InjectLock`）。

## 5.1 一键复验

```bash
cd ~/WorkBuddy/TrofeoLCD
sh tools/win_verify.sh          # 6 大项、11 个判定，约 3-5 分钟
sh tools/win_verify.sh --quick  # 跳过需要 livepad 的那一项
```

最后一次运行结果：**通过 11，失败 0，跳过 0**（编译 / 自检 119 项 / USB 枚举 /
横屏渲染 / 竖屏渲染 / VM 画面源 + HTTP 自测）。

## 6. 已验证 / 未验证

**已在真实 Windows 11 ARM64 上验证**（2026-10-12）：

| 项 | 证据 |
|---|---|
| 编译 | `build.log` → `[OK] compiled` / `size=122880 bytes` |
| 自检 | `自检结果：通过 125 / 共 125，失败 0`（协议 FNV 字节级 + 调度 + 归一化 + JSON + 6 条打印机用例） |
| 渲染+编码 | 横向/竖向各 26–51 帧，`JPEG=1920x462`，88–113 KB，质量 0.9；无外部画面时全帧**零纯白像素**、唯一色 ~1.9 万（说明文字/图形真的画上了） |
| 竖屏布局 | 分区结构与**鸿蒙真机实测一致**（表头落在最右带 x1680–1920，VM/USAGE 在左侧） |
| HTTP 全套 | `/status` `/diag` `/frame.jpg`(86–113KB) `/set?vertical=1` `/` `/preview` `/probe` 全部 200 |
| UDP 遥测 | 合成包 23–32 个全部解析成功，`telemetryLastError` 为空 |
| VM 画面源 | 从 VM 内抓主机 livepad：`vmFrames=6–9`，`源尺寸=1680x1120`，抓取 5–19ms |
| USB 枚举 | `--probe` 正确读出真实 VID/PID（`USB\VID_B74C&PID_0001` 等），无设备时不崩 |
| ini 配置 | 只靠 `dshlcd.ini`（不含命令行参数）成功切竖屏 + 接上 VM 画面源 |
| 性能 | VM 内（无 GPU 加速）渲染 27–82ms、编码 7–9ms；真机应显著更快 |

**打印机卡片跨平台一致性（2026-10-12 01:24 实测）**：
同一份 `--demo` 合成遥测下，AMS 四个色块在两边的落点几乎逐像素相同 ——
鸿蒙真机帧 `x144-154 / y27·58·87·119`，Windows 帧 `x145-153 / y27·58·88·118`（间距 30px）。
竖屏（旋转 90° 后）色块排成一行：`x1322·1358·1393·1429 / y326-334`（间距 ≈35.6px = 卡高 178×0.20）。

**尚未验证（必须说清楚）**：

1. **USB 实际推帧没有验证过** —— 手里没有这块屏（硬件未到）。协议字节级正确性由自检保证，
   但 `winusb.dll` 的 P/Invoke 路径、真实握手与 ACK 只能等屏到了才能确认。
   屏到手后先跑 `dshlcd.exe --probe`，再 `dshlcd.exe` 看面板是否出画面。
2. **画面好不好看没人眼确认过** —— 渲染器是逐行移植 + 数值统计验证（分区像素、
   尺寸、颜色），但"像不像鸿蒙版"需要你看一眼 `--demo --out-frame` 出的图。
3. **x64 机器上没实测**（只在 ARM64 Windows 上跑过；AnyCPU + 纯 IL，理论上一致）。
