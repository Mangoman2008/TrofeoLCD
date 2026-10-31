#!/usr/bin/env bash
# 直接在电脑上运行 App 里的协议/校准/归一化代码（ArkTS 源码 -> Node 类型剥离执行）
#
# 为什么能这样跑：这些 .ets 是纯 TS 语法，Node 22.6+ 的 --experimental-strip-types
# 剥掉类型后可直接执行；enum 由 tools/ets_to_ts.py 先转成常量对象（strip-only 不支持
# enum，Node 26 也没有 --experimental-transform-types）。测的是**真实 App 源码**，
# 期望值来自 tools/ly_reference.py（照 trcc 语义重写的独立参考实现）。
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
V="$D/.verify"
# ★ 只清自建产物目录（2026-10-31 修中-22）：.verify 下还有别的工具的工作区
#   （video-seq 等本地状态），`rm -rf "$V"` 会把它们一起扬了。
for sub in usb common service render mario kitstub; do
  rm -rf "$V/$sub"
done
rm -f "$V/run.mts"
mkdir -p "$V/usb" "$V/common" "$V/service" "$V/render" "$V/mario" "$V/node_modules"

# ★ 工程里新增 render/ 或 common/ 模块后，**必须**把文件加进下面这个清单 ——
#   否则 Dashboard 之类 import 到它时会 ERR_MODULE_NOT_FOUND，自检整段失败。
#   （踩过三次：layout_check.py 与这里都漏过 ThemeDotiiCell；2026-10-31 又漏了
#    ThemeSnake/mario 整条链 —— 主题 16/17 上线时没同步这里，自检静默失效了一轮）
for f in usb/LyProtocol usb/EndpointPick usb/SelfTest common/Types common/Normalize common/SystemMerge service/CanvasCalib service/SchedulePolicy common/Theme common/History common/Toasts common/Extras render/Chrome render/Dashboard render/ThemeDiag render/ThemeWall \
         render/ThemePong render/ThemeDotii render/ThemeFwSim render/ThemeTRCC render/ThemeMac render/ThemeDotiiCell render/ThemeAnime render/ThemeAnimeBG render/ThemeAnimeFree render/ThemeAnimeHUD render/ThemeNanoMuse render/ThemeTrofeoRust \
         render/ThemeSnake render/Backdrop \
         mario/Types mario/Levels mario/Entities mario/Game mario/Input mario/Audio mario/MarioDemo; do
  python3 "$D/tools/ets_to_ts.py" "$D/entry/src/main/ets/$f.ets" "$V/$f.ts"
done

# ★ @kit 打桩（2026-10-31 补）：mario/Game 顶层 `import { hilog } from '@kit.PerformanceAnalysisKit'`。
#   ets_to_ts.py 会把它重写成 '../kitstub/hilog.ts'（见那边的 KIT_STUBS 表），这里负责落桩文件。
#   以后有新 kit 依赖时：ets_to_ts.py 的 KIT_STUBS 加映射 + 这里加对应桩文件。
mkdir -p "$V/kitstub"
cat > "$V/kitstub/hilog.ts" <<'TS'
// 离线自检桩：hilog 是真机日志 API（mario/Game 的调试日志走它），全部 no-op。
const noop = (): void => {};
export const hilog = { debug: noop, info: noop, warn: noop, error: noop, fatal: noop };
TS

cp "$D/tools/selftest_runner.mts" "$V/run.mts"
cd "$V"
node --no-warnings --experimental-strip-types run.mts
