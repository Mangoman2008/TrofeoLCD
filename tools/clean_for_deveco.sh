#!/usr/bin/env bash
# 【默认不动手】只报告 .hvigor 状态；确实需要清理时显式加 --force。
#
# 为什么改成这样：本机 DevEco 用的是设备自带的 hmos-clt 工具链，
# 其 hvigor 版本(7.26.8)/toolchains(26.0.0.105) 与我们命令行构建**完全相同**，
# 因此无法靠版本指纹区分"CLI 留下的缓存"和"DevEco 自己的缓存"。
# 之前按指纹自动删除，等于在拆 DevEco 的缓存，反而会让它反复重新 Sync
# （并且可能是「模块未定义」的诱因之一）。删除只应作为"同步失败后的补救手段"，
# 而不是例行步骤。
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

echo ".hvigor 现状:"
if [ -d "$D/.hvigor" ]; then
  [ -f "$D/.hvigor/cache/meta.json" ] && echo "  meta: $(cat "$D/.hvigor/cache/meta.json")"
  [ -d "$D/.hvigor/outputs/sync" ] && echo "  outputs/sync 存在 → DevEco 用过这个工程（正常）"
  [ -f "$D/.hvigor/outputs/build-logs/build.log" ] && \
    echo "  最近构建日志: $(stat -c '%y' "$D/.hvigor/outputs/build-logs/build.log" | cut -c1-19)"
else
  echo "  （不存在）"
fi

if [ "$FORCE" = "1" ]; then
  echo "→ --force：清理 .hvigor / entry/build / oh_modules"
  rm -rf "$D/.hvigor" "$D/entry/build" "$D/oh_modules" "$D/entry/oh_modules" "$D/entry/.hvigor"
  echo "   完成。请在 DevEco 里 File → Sync and Rebuild Project 重新同步。"
else
  echo
  echo "未做任何修改。只有在「DevEco 同步失败 / 报模块未定义且重启无效」时才建议："
  echo "  tools/clean_for_deveco.sh --force"
  echo "然后回 DevEco 执行 Sync and Rebuild Project。"
fi
rm -rf "$D/tools/__pycache__"
