# 可视化 Agent 控制台（浏览器里的 Agent 界面）

> 日期：2026-10-15 · 新增文件：`bridge/console-server.mjs`、`web/console.html`、`tools/console.sh`
> 面向：想在**电脑屏幕上**（而不是 1920×462 副屏上）看 DSH 会话全过程、并顺手控制副屏的人。

## 一、一句话

把 DSH 会话的**完整过程**——你的指令 / 思考 / 工具调用（含参数）/ 工具结果 / 回复 / 待办 / 用量——
做成一个浏览器里的实时页面；同一页右边是**副屏实时画面**与**副屏控制**（主题、背景特效、档位、开关）。

```bash
bash tools/console.sh start      # 起服务
bash tools/console.sh url        # → http://127.0.0.1:54550/
bash tools/console.sh check      # 端到端自检（17 项）
bash tools/console.sh stop
```

## 二、为什么是"外部进程"而不是 DSH 插件

项目里已经有一个**进程内**数据桥（`dsh-plugin/dsh-lcd-bridge/`，随 DSH 启动、推 UDP）。控制台**没有**照抄这个做法，原因只有一条：

| | 进程内插件 | 外部进程（本方案） |
|---|---|---|
| 改完怎么生效 | **必须重启 DSH** | 重启控制台即可（`console.sh restart`） |
| 重启 DSH 的代价 | **打断正在跑的会话**（包括正在跑的 agent 任务） | 无 |
| 解析逻辑是否重复 | — | **不重复**：直接 `import` 插件的 `session.mjs` |

所以：**解析只有一份**（`findCurrentSession` / `readTailLines` / `readAllLines` / `deriveState` 都是 import 来的），
控制台自己只加"控制台特有的提炼"（时间线、小时柱、工具分布）与 HTTP 面。

```
   ~/.dsh/sessions/<slug>/<sid>/session.v4.jsonl.zstd
                     │  ← import 插件的 session.mjs（同一份代码）
                     ▼
   bridge/console-server.mjs   轻路径 1s：尾部快读 → 状态 + 时间线
                              重路径 60s：全量解码 → 标题/模型/当日用量/小时柱/工具分布
                     │
        ┌────────────┴─────────────┐
        ▼                          ▼
   HTTP+SSE  :54550          代理 → App :54546
   浏览器页面 web/console.html      /status /diag /frame.jpg /set?...
```

**没碰任何现有部件**：DSH 进程（插件照旧推 UDP）、App 的 USB 链路、`bridge/dsh-bridge.mjs`（外部老桥）、
`web/preview.html`（预览页，它有两宿主注入机制，见 `tools/make_web.py`）。

## 三、页面结构（三栏）

| 栏 | 卡片 | 数据来源 |
|---|---|---|
| **左** | 会话选择（● 标 30s 内活跃）/ 当前状态（活动、工具、最后回复、上下文占用条、今日用量、速率） | 尾部快读 + 全量 |
| | 副屏画面（实时 JPEG，1920×462）/ 副屏控制（16 档主题、5 种背景特效、档位、竖屏/流水线/打印机格） | 代理 App `/frame.jpg` `/set` |
| **中** | **Agent 时间线**：你的指令 / 回复 / 思考（可展开）/ 工具调用（中文标签 + 参数摘要 + 结果预览 + 耗时 + 返回字节）/ 待办变更 / 轮次边界；顶部可按类型过滤、自动滚动、一键展开详情 | 会话事件流 |
| | 指令框（复制 / 存收件箱 / 打开 DSH） | 见第六节 |
| **右** | 任务进度（todo 进度条 + in_progress 高亮）/ 用量与上下文（今日 in/out/合计、本会话累计含缓存读、24 小时柱）/ 本机（CPU/内存 + 双线 sparkline + 负载/开机时长）/ 工具分布（Top 8 调用次数）/ 环境与链路（副屏自检、USB、余额、打印机、轮次、全量统计耗时、cwd） | 全量统计 + App + 插件快照文件 |

时间线的每一行来自真实事件，不是估算：

| 行 | 来自事件 | 关键字段 |
|---|---|---|
| 你的指令 | `user/message` / `agent/inbox/spliced` | `data.content[].text` |
| 回复 | `assistant/message` | `message.content[type=text]`、`data.usage` |
| 思考 | `assistant/message` | `message.content[type=reasoning]`（默认折叠） |
| 工具 | `tool/call` **与** `tool/result` 按 `callId` **配对成一行** | `name` / `arguments`（按工具提炼摘要）/ 结果首 400 字 / 耗时 = 结果 ts − 调用 ts / 返回字节 |
| 待办 | `todo/write` · `todo/update` | `todos[].status`（完成数 + 正在做的那条） |
| 轮次 | `turn/start` · `turn/end` | `reason.kind`（error 会标红） |

## 四、接口清单（只绑 127.0.0.1）

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/` | 控制台页面 |
| GET | `/api/state` | 一份完整 JSON 快照（页面轮询兜底用） |
| GET | `/api/stream` | **SSE**，每秒一帧 `event: state` |
| GET | `/api/sessions` | 会话列表 |
| POST | `/api/watch` | `{file}` 固定看某个会话；`{file:"auto"}` 恢复跟随 |
| GET/POST | `/api/inbox` | 读/写指令收件箱（`~/.dsh/storages/lcd-console/inbox.jsonl`） |
| GET | `/api/app` | App 的 `/status` + `/diag` |
| POST | `/api/app/set` | `{q:"theme=3&background=aurora"}` → **白名单过滤后**代理到 App `/set` |
| GET | `/api/frame.jpg` | 副屏当前帧（代理，浏览器直接 `<img>` 用） |
| GET | `/health` | 存活探测 |
| CLI | `--once` | 打印一份完整快照后退出（自检/排障用） |

**白名单**（`/api/app/set` 只放开这些键，其余一律丢弃并在响应里列出）：
`theme` `page` `pagerot` `printerCell` `background` `profile` `vertical` `vig` `vigcorner` `vigall`
`pipe` `wbatch` `wsize` `q` `seqfps` `seqlimit` `seqstream` `seqburst` `seqwin` `vmurl`

理由：控制台是个网页，理论上任何脚本都能对它发请求；把"能让屏幕下线/进错误态"的键挡在外面，
自检里也验证了未知键（`evil=1&reboot=1`）确实被丢弃。

## 五、两个实测踩到的坑（都修了）

1. **不能按文件 mtime 选"当前会话"**。
   会话文件会被 DSH 侧刷盘，某个几天前的**大**会话 mtime 一跳就会抢走"最近活跃"的位置
   —— 第一次跑就撞上：画面从本次会话跳到一个 15MB 的老会话。
   改成比**文件里最后一条事件的 `time`**；为省 CPU，只在 `(size,mtime)` 变化时才重解尾部（其余命中缓存）。

2. **多会话并发时画面会来回跳**。
   实测同一时刻这台机器上有 **4 个会话在 30s 内活跃**（`activeSessions=4`）。
   严格"谁最新跟谁"就会每 2 秒切一次。加了**粘性**：当前会话还在出事件（<10s）就不切，
   它安静下来才让位；会话下拉里 ● 标出活跃项，随时可手动固定。

## 六、指令框现在能做什么（以及为什么不能直接注入）

| 能力 | 现状 |
|---|---|
| 切主题 / 背景 / 档位 / 开关 | ✅ **真操作**（走 App `/set`，白名单） |
| 复制指令到剪贴板 | ✅ 贴到 DSH 输入框即可 |
| 存入收件箱 | ✅ 落 `~/.dsh/storages/lcd-console/inbox.jsonl`（带会话、时间） |
| **直接注入正在运行的会话** | ❌ 本版本不做 |

原因（实测过，不是猜的）：DSH Host 的 HTTP 面只有页面与静态资源
（带 localhost 授权 cookie 请求 `/api*` 全是 404），会话交互走 WebSocket 内部 RPC；
外部进程没有稳定的注入入口。**升级路径**：把 `console-server.mjs` 里的 `startServer()`
挂进 `dsh-plugin/dsh-lcd-bridge/`（进程内插件），那时可用 DSH 的会话服务直接投递，
指令框就从"存收件箱"变成"真发送"——但要**重启 DSH** 才生效，所以作为下一步单独做。

## 七、实测证据

```
$ bash tools/console.sh check
  ✅ --once 能跑完并输出 JSON
  ✅ 能定位当前会话文件（按**最后事件时间**选）
  ✅ 状态机取值合法：busy
  ✅ 时间线有条目：203 条      # 数字随会话增长，跑一次一个样
  ✅ 时间线每条都带 kind/ts
  ✅ 工具行有中文标签与摘要：112 条
  ✅ 全量统计完成（行数/解码耗时/工具分布）
  ✅ 上下文窗口已知：1000000
  ✅ 会话列表可用：30 个
  ✅ 会话列表正确标记当前项
  ✅ 副屏 App 在线（/status 可达）
  ✅ HTTP 服务在跑：http://127.0.0.1:54550/
  ✅ 首页返回控制台页面（含标题标记，45677 字节）
  ✅ SSE 推流正常（收到 event: state）
  ✅ 副屏画面代理正常（200:image/jpeg）
  ✅ 白名单生效：未知键被丢弃（{"ok":false,"error":"没有可用的键","dropped":["evil","reboot"]}）
  ✅ 收件箱可写（指令落盘通路）
  通过 17 项，失败 0 项
```

其它已经核过的：

| 项 | 结果 |
|---|---|
| 真实会话数据 | `state=busy`、`title=可视化 Agent 界面开发`、`todayTotal≈9.2 万`、`contextUsed 10 万/100 万` |
| 时间线配对 | 工具行带 `result.ms`（例：`edit` 1896ms、返回 112 字节） |
| 副屏链路 | 代理 `/frame.jpg` → `200 image/jpeg`，`1920×462`，`jpeBytes≈90KB` |
| 前端静态检查 | 页面 69 个 DOM id 与 JS 里 `$()` 引用**完全对齐**；`<script>` 过 `node --check` |
| 字段契约 | 前端用到的 **40 个字段**逐个在真实快照里核过存在 |
| 白名单 | `evil=1&reboot=1` → 丢弃；`theme=0`（同值）→ 正常返回 |

**未验证**：浏览器里的**视觉效果**。本机没有 chromium/firefox、没有 puppeteer 缓存、没有 weasyprint，
无法截图自证版式——需要你打开 `http://127.0.0.1:54550/` 看一眼（逻辑、数据、接口、代理都已自检通过）。

## 八、资源占用与边界

| 项 | 值 |
|---|---|
| 轻路径（每秒） | 尾读 1MB → 解压+解析 ≈70ms（**在控制台进程里**，不占 DSH） |
| 重路径（每 60s 或换会话时） | 全量流式解码，13MB 会话 ≈1.5–2.5s |
| 时间线保留 | 最近 240 条（内存里有界，不会越跑越大） |
| 端口 | 54550（控制台）／代理 54546（App）；可用 `DSH_LCD_CONSOLE_PORT` 改 |
| 不写工程 | 只读会话文件；只写 `~/.dsh/storages/lcd-console/inbox.jsonl` 与 `bridge/.console.log` |
