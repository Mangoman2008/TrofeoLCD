#!/usr/bin/env bash
# 直接在电脑上运行 App 里的协议/校准/归一化代码（ArkTS 源码 -> Node 类型剥离执行）
#
# 为什么能这样跑：这些 .ets 是纯 TS 语法，Node 22.6+ 的 --experimental-strip-types
# 剥离类型后可直接执行。测的是**真实 App 源码**，期望值来自 tools/ly_reference.py
# （照 trcc 语义重写的独立参考实现）。
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
V="$D/.verify"
rm -rf "$V"
mkdir -p "$V/usb" "$V/common" "$V/service" "$V/render"

# ★ 工程里新增 render/ 或 common/ 模块后，**必须**把文件加进下面这个清单 ——
#   否则 Dashboard 之类 import 到它时会 ERR_MODULE_NOT_FOUND，自检整段失败。
#   （本会话踩过两次：layout_check.py 与这里的清单都漏过新模块 ThemeDotiiCell）
for f in usb/LyProtocol usb/EndpointPick usb/SelfTest common/Types common/Normalize common/SystemMerge service/CanvasCalib service/SchedulePolicy common/Theme common/History common/Toasts common/Extras render/Chrome render/Dashboard render/ThemeDiag render/ThemeWall \
         render/ThemePong render/ThemeDotii render/ThemeFwSim render/ThemeTRCC render/ThemeMac render/ThemeDotiiCell render/ThemeAnime render/ThemeAnimeBG render/ThemeAnimeFree render/ThemeAnimeHUD render/ThemeNanoMuse render/ThemeTrofeoRust; do
  # 相对导入补上 .ts 扩展名（Node ESM 要求显式扩展名）
  sed -E "s|from '(\.\.?/[A-Za-z0-9_/]+)'|from '\1.ts'|g" \
      "$D/entry/src/main/ets/$f.ets" > "$V/$f.ts"
done

cp "$D/tools/selftest_runner.mts" "$V/run.mts"
cd "$V"
node --no-warnings --experimental-strip-types run.mts
