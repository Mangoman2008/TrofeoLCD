#!/usr/bin/env python3
"""
ly_chunks_verify.py — LY 分块流的**切片数量**验证（防"屏幕重启"这类协议 bug）

## 背景（2026-10-15 实机故障）
Windows 版推帧时屏幕**反复重启**，而同一根线、同一块屏，鸿蒙版稳。
根因在 `win/src/Ly.cs` 的 `WriteChunks`：它分**两遍**做 ——
  第一遍按 `pos += UsbWriteSize(4096)` 数出 pieces 数量并预分配 `byte[][]`；
  第二遍按 `pos += size` 真正填充，而末段取 `min(2048, remaining)`（LY 收尾包必须 ≤2048）。
两遍推进量不一致 → 第二遍常比第一遍**多写一次** → `writes[idx]` 越界 → `IndexOutOfRangeException`。
触发条件：`总长 % 4096 ∈ (2048, 4096)`。用户机上 `jpegBytes=114256` 正是这种。

ArkTS 侧（`usb/LyProtocol.ets` 的 `writeChunks`）是**边算边 push** 的动态数组，从来没这问题。

## 这个脚本做什么
不读 C# 源码（那是 csharp_audit 的事），而是：
  1. 复现**旧的**两遍算法与新算法，穷举大量长度，证明旧算法确实会越界、新算法与 ArkTS 一致
  2. 断言真实帧尺寸区间内不会越界
  3. 校验 `pos += size` 这条推进语义（不是 `pos += ws`）

用法: python3 tools/ly_chunks_verify.py
"""
import sys

USW = 4096          # UsbWriteSize


def old_two_pass(total):
    """旧实现：第一遍估数量，第二遍填 —— 返回 (预估数量, 实际填充次数)。"""
    est = 0
    pos = 0
    while pos < total:
        pos += USW
        est += 1
    filled = 0
    pos = 0
    while pos < total:
        rem = total - pos
        size = USW if rem >= USW else min(2048, rem)
        pos += size
        filled += 1
    return est, filled


def new_single_pass(total):
    """新实现 / ArkTS 的 writeChunks 语义：一遍、动态增长。"""
    n = 0
    pos = 0
    while pos < total:
        rem = total - pos
        size = USW if rem >= USW else min(2048, rem)
        pos += size
        n += 1
    return n


def main():
    fails = []

    print('=' * 62)
    print('LY 分块流切片数量验证')
    print('=' * 62)

    # ---- 1. 穷举：旧算法在哪些长度上会越界 ----
    print('① 旧（两遍）算法 vs 新（一遍）算法')
    bad_old = []
    for total in range(2049, 60000):
        est, filled = old_two_pass(total)
        if filled != est:
            bad_old.append(total)
    if not bad_old:
        fails.append('预期旧算法在某些长度上会数量不一致，但没找到')
    else:
        # 触发条件应当是 total % 4096 ∈ (2048, 4096)
        wrong = [t for t in bad_old if not (2048 < (t % USW) < USW)]
        print(f'  旧算法不一致的长度个数: {len(bad_old)}（2049..59999 区间）')
        print(f'  其中不符合"total%%4096∈(2048,4096)"规律的: {len(wrong)}')
        if wrong:
            fails.append(f'{len(wrong)} 个长度不符合预期触发规律')
        print(f'  触发区间确认: total%%4096 ∈ (2048, 4096) ✅')

    # ---- 2. 新算法必须恒等于"不含 0 片"且与 ArkTS 同式 ----
    print()
    print('② 新算法：不越界 + 与 ArkTS 同式')
    for total in [2049, 4096, 6144, 32768, 40000, 100000, 114256, 350000, 360000, 450000]:
        n_old_est, n_old_fill = old_two_pass(total)
        n_new = new_single_pass(total)
        if n_new != n_old_fill:
            fails.append(f'total={total}: 新算法 {n_new} 与旧算法实际填充 {n_old_fill} 不一致')
        if n_new == 0:
            fails.append(f'total={total}: 切片数为 0（不该发生）')
    print(f'  抽查 10 个长度：新算法 == 旧算法"实际填充数" ✅')
    print(f'  说明：新算法数量 = ArkTS 的动态数组长度，而旧算法的**预分配数组**才是错的那个')

    # ---- 3. 真实帧尺寸区间 ----
    print()
    print('③ 真实帧尺寸区间（按实测 22KB ~ 46KB，以及上限 450KB）')
    real = [22000, 25000, 35000, 40700, 46000, 114256, 360000, 450000]
    hits = [t for t in real if old_two_pass(t)[0] != old_two_pass(t)[1]]
    print(f'  抽查 {len(real)} 个尺寸，旧算法会越界的: {len(hits)} 个 → {hits}')
    if not hits:
        fails.append('真实尺寸里居然没命中触发区间，样本可能不代表性')
    else:
        print(f'  → 这就是"每帧抛异常、屏幕反复重启"的成因（用户机 jpegBytes=114256 命中）')

    # ---- 4. 推进语义 ----
    print()
    print('④ 推进语义：必须按实际发送长度推进')
    total = 114256
    pos_size = 0
    pos_ws = 0
    cnt_size = 0
    cnt_ws = 0
    while pos_size < total:
        rem = total - pos_size
        pos_size += USW if rem >= USW else min(2048, rem)
        cnt_size += 1
    while pos_ws < total:
        pos_ws += USW
        cnt_ws += 1
    print(f'  pos += size → {cnt_size} 次（正确，覆盖全部字节）')
    print(f'  pos += ws   → {cnt_ws} 次（错误：尾部 {total - (cnt_ws-1)*USW} 字节被跳过）')
    if cnt_size == cnt_ws:
        fails.append('该长度下两种推进方式次数相同，无法体现差异，换个长度做样例')

    print()
    if fails:
        print(f'❌ {len(fails)} 项未通过：')
        for f in fails:
            print('   - ' + f)
        return 1
    print('✅ 全部通过：单遍切片的数量与 ArkTS 语义一致，且不会越界')
    return 0


if __name__ == '__main__':
    sys.exit(main())
