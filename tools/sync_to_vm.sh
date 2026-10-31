#!/usr/bin/env bash
# 把 win/src/*.cs、.cmd、桥、素材同步到 VM 共享盘，并**逐字节校验**。
# 共享盘会闪断（Resource busy / 目录暂时消失），所以带重试 + 校验，
# 不靠"探测一次存在"就宣布成功（2026-10-15 因此误报过一次）。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="${V:-/storage/Users/currentUser/.VMDocs/.hwf_share/.disks/C/dshlcd}"
TRIES="${TRIES:-12}"

wait_ready() {
  local i
  for ((i=1; i<=TRIES; i++)); do
    if [ -d "$V/src" ] && [ -w "$V" ]; then return 0; fi
    printf '  等待共享盘就绪 (%d/%d)...\r' "$i" "$TRIES"
    sleep 5
  done
  echo
  return 1
}

echo "目标: $V"
if ! wait_ready; then
  echo "  ❌ 共享盘一直不可用（VM 侧共享可能关了）"
  exit 1
fi
echo "  ✅ 共享盘就绪"

# ---- 1. 源码 ----
n=0
for f in "$ROOT"/win/src/*.cs; do
  cp "$f" "$V/src/$(basename "$f")" 2>/dev/null && n=$((n+1))
done
echo "  .cs 复制: $n"

# ---- 2. 脚本 ----
cp "$ROOT/win/build.cmd"        "$V/build.cmd"        2>/dev/null && echo "  build.cmd ok"
cp "$ROOT/bridge/win/start.cmd" "$V/start.cmd"        2>/dev/null && echo "  start.cmd ok"
cp "$ROOT/bridge/win/stop.cmd"  "$V/stop.cmd"         2>/dev/null && echo "  stop.cmd ok"

# ---- 3. 桥与素材 ----
cp "$ROOT/bridge/dsh-bridge.mjs" "$V/dsh-bridge.mjs"  2>/dev/null && echo "  bridge ok"
[ -f "$ROOT/bridge/win/zstd.exe" ] && cp "$ROOT/bridge/win/zstd.exe" "$V/zstd.exe" 2>/dev/null && echo "  zstd ok"
for f in "$ROOT"/win/assets/*; do
  b=$(basename "$f")
  cp "$f" "$V/$b" 2>/dev/null
done
echo "  素材: $(ls "$ROOT"/win/assets | wc -l) 个"

# ---- 4. 逐字节校验（关键：不校验就等于没同步）----
echo
echo "  逐字节校验："
bad=0; tot=0
for f in "$ROOT"/win/src/*.cs; do
  b=$(basename "$f"); tot=$((tot+1))
  a=$(md5sum "$f" | cut -d' ' -f1)
  c=$(md5sum "$V/src/$b" 2>/dev/null | cut -d' ' -f1)
  [ "$a" != "$c" ] && { echo "    ❌ $b"; bad=$((bad+1)); }
done
echo "    .cs: $tot 个，不一致 $bad 个"
[ $bad -eq 0 ] && echo "    ✅ 源码完全一致" || echo "    ❌ 有未同步文件"
exit $([ $bad -eq 0 ] && echo 0 || echo 1)
