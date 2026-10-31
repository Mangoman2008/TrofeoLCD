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

# ★ 转译清单与 layout_check.py 共用 tools/ets_files.txt（2026-10-31 C3）：
#   此前两边各维护一份，漏同步翻车三次（ThemeDotiiCell / ThemeSnake+mario 链 / ThemeAnime）。
#   新增模块只改那一份。
while IFS= read -r f; do
  case "$f" in ''|'#'*) continue ;; esac
  python3 "$D/tools/ets_to_ts.py" "$D/entry/src/main/ets/$f.ets" "$V/$f.ts"
done < "$D/tools/ets_files.txt"

# ★ @kit 打桩：ets_to_ts.py 把 kit 导入重写到 '../kitstub/<name>.ts'（KIT_STUBS 表），
#   桩文件本体在 tools/kitstubs/ 下维护（与 layout_check.py 共用），这里只负责拷贝。
mkdir -p "$V/kitstub"
cp "$D"/tools/kitstubs/*.ts "$V/kitstub/"

cp "$D/tools/selftest_runner.mts" "$V/run.mts"
cd "$V"
node --no-warnings --experimental-strip-types run.mts
