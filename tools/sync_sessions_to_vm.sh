#!/usr/bin/env bash
# sync_sessions_to_vm.sh — 把本机 DSH 会话数据的**尾部**送到 VM 共享盘，
# 供 Windows 侧的桥用 `--sessions-root` 读取。
#
# ## 为什么只送尾部
# 本机实测单个 session.jsonl.zstd 有 **41MB**（几千个 zstd 帧拼接），
# 每隔几十秒全量拷贝不现实。而桥本来也只读**文件尾部**（TAIL_BYTES，默认约 1MB 级），
# 因为它只需要"最新状态"。所以这里只拷最后 2MB —— 已在本机实测：
# 2MB 尾部副本能被桥正确解出真实数据（tool/turn/lastText 都对）。
#
# ## 目录结构（必须与桥的期望一致）
#   <root>/<slug>/<session-name>/session.jsonl.zstd
# 桥的 findNewestSession 只认同名文件，所以写完要按原文件名放置。
#
# 用法：
#   bash tools/sync_sessions_to_vm.sh            # 同步一次
#   bash tools/sync_sessions_to_vm.sh --loop 30  # 每 30 秒同步一次
set -u

SRC="${DSH_SESSIONS:-$HOME/.dsh/sessions}"
V="${V:-/storage/Users/currentUser/.VMDocs/.hwf_share/.disks/C/dshlcd}"
DST="$V/sessions"
TAIL_BYTES="${TAIL_BYTES:-2097152}"     # 2MB
LOOP=0
[ "${1:-}" = "--loop" ] && LOOP="${2:-30}"

sync_once() {
  if [ ! -d "$V" ]; then
    echo "[sessions-sync] 共享盘不可用：$V"
    return 1
  fi
  mkdir -p "$DST" 2>/dev/null || { echo "[sessions-sync] 无法创建 $DST"; return 1; }
  local n=0
  for slugdir in "$SRC"/*/; do
    [ -d "$slugdir" ] || continue
    local slug; slug="$(basename "$slugdir")"
    # 该 slug 下按 mtime 最新的会话（v4 与普通两种文件名都认）
    local newest="" newest_mt=0
    for ses in "$slugdir"*/; do
      [ -d "$ses" ] || continue
      for fn in session.jsonl.zstd session.v4.jsonl.zstd; do
        local f="$ses$fn"
        [ -f "$f" ] || continue
        local mt; mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        if [ "$mt" -gt "$newest_mt" ]; then newest_mt=$mt; newest="$f"; fi
      done
    done
    [ -n "$newest" ] || continue
    # 目标：保持 <slug>/<session-name>/<filename> 结构
    local rel="${newest#$SRC/}"
    local out="$DST/$rel"
    mkdir -p "$(dirname "$out")" 2>/dev/null || continue
    # 只拷尾部 TAIL_BYTES（文件小于它就全拷）
    # ★ 必须用 `cp -f` 直接写目标名，**不能**先写 .tmp 再 mv ——
    #   这个共享盘（虚拟盘映射）不支持 rename，`mv` 会失败并留下 .tmp
    #   （2026-10-15 实测：连续两次都卡在 .tmp 上）。
    local size; size=$(stat -c %s "$newest" 2>/dev/null || echo 0)
    if [ "$size" -gt "$TAIL_BYTES" ]; then
      tail -c "$TAIL_BYTES" "$newest" > "$out" 2>/dev/null
    else
      cp -f "$newest" "$out" 2>/dev/null
    fi
    if [ -s "$out" ]; then n=$((n+1)); fi
    rm -f "$out.tmp" 2>/dev/null
    # 清掉另一个文件名，避免桥按 mtime 挑到过期的那份
    local other
    if [ "${newest##*/}" = "session.jsonl.zstd" ]; then other="session.v4.jsonl.zstd"; else other="session.jsonl.zstd"; fi
    rm -f "$(dirname "$out")/$other" 2>/dev/null
  done
  echo "[sessions-sync] $(date '+%H:%M:%S') 已同步 $n 个会话（每个取尾部 $((TAIL_BYTES/1024))KB）"
  return 0
}

if [ "$LOOP" = "0" ]; then
  sync_once
else
  while true; do
    sync_once
    sleep "$LOOP"
  done
fi
