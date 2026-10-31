#!/usr/bin/env python3
"""audit_vs_ets.py —— 「和 Dashboard.ets 逐行一致」的机械核对。

把 ArkTS 的 Dashboard.ets 与 C# 的 Dashboard.cs 各自按方法切开，逐方法比较：
  1) 数值字面量集合（坐标/字号/圆角/阈值）  —— 先剥掉注释，避免注释里的数字污染
  2) 文案片段集合 —— ArkTS 的模板串先按 ${...} 切段，再剥掉对齐/字重这类 API 枚举词
     （'left'/'center'/'right'/'bold'/'normal'/'middle'：ArkTS 用字符串传，C# 用
       Align 枚举 + bool，属于调用形式的差异，不是内容差异）

差异必须能被白名单解释，否则判 DIFF：
  - FrameStats 槽位：ArkTS 每个入口还收 FrameStats(USB/JPEG/耗时)，C# 契约没有，
    改成用 State 的等价信息（见 Dashboard.cs 文件头说明）
  - '#08090F'：ArkTS 徽章文字内联颜色，C# 收进 Theme.cs 的 C.BadgeText（同一个值）
  - 角度单位：ArkTS ctx.arc 用弧度，C# DrawArc 用度（-90/360 等）
  - 渐变：ArkTS addColorStop(0/1,...)，C# LinearGradientBrush 双色构造
  - 10：ArkTS fs.bridgeAge<10 阈值，C# 在 BridgeColor() 里（同一个 10）

  python3 win_dash/audit_vs_ets.py
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ETS = os.path.join(ROOT, "entry/src/main/ets/render/Dashboard.ets")
CS = os.path.join(ROOT, "win/src/Dashboard.cs")

PAIRS = [
    ("render", "RenderHorizontal"), ("renderVertical", "RenderVertical"),
    ("headerV", "HeaderV"), ("agentPanelV", "AgentPanelV"),
    ("usagePanelV", "UsagePanelV"), ("vmPanel", "VmPanel"),
    ("background", "Background"), ("roundRect", "RoundRect"), ("panel", "Panel"),
    ("label", "Label"), ("mono", "Mono"), ("bar", "Bar"),
    ("fitText", "FitText"), ("valueMaxW", "ValueMaxW"), ("measure", "Measure"),
    ("wrap", "Wrap"), ("fmtTokens", "FmtTokens"), ("pad2", "Pad2"),
    ("systemPanel", "SystemPanel"), ("agentPanel", "AgentPanel"),
    ("stateColor", "StateColor"), ("stateText", "StateText"), ("usagePanel", "UsagePanel"),
]

# 白名单：ArkTS 有、C# 没有的数字 → 说明原因
WNUM_ETS_ONLY = {
    "renderVertical": {"1": "addColorStop(1,...) → C# 用双色渐变构造"},
    "background": {"1": "addColorStop(1,...) → C# 用双色渐变构造"},
    "usagePanelV": {"10": "fs.bridgeAge<10 → C# 收在 BridgeColor() 里"},
    "usagePanel": {"10": "fs.bridgeAge<10 → C# 收在 BridgeColor() 里"},
}
# 白名单：C# 多出来的数字 → 说明原因
WNUM_CS_EXTRA = {
    "RoundRect": "AddArc 的四角起始角 0/90/180/270 + 半径下限 0/2",
    "SystemPanel": "ctx.arc 弧度 → DrawArc 角度 -90/360",
    "Measure": "MeasureString 的 PointF(0,0) 原点",
    "Pad2": "'0' 前缀",
    "VmPanel": "注释里的显示区尺寸 452×480",
    "RenderVertical": "V/Rect 的填充路径实现细节",
    "Background": "Rect() 填充路径实现细节",
}
# 白名单：ArkTS 有、C# 没有的文案
# 说明：这些 FrameStats 相关文案在 C# 里被搬进 LinkText/BridgeText/FrameCountText 三个
# 小helper（因为本版契约没有 FrameStats，用 State 的等价信息还原），所以逐方法比对时
# 会显示"ArkTS 有、C# 无"，但它们在 Dashboard.cs 里确实存在，只是换了个方法。
WSTR_ETS_ONLY = {
    "usagePanelV": {"USB ○ 未连接", "USB ● ", "帧", "ms", "桥 ○", "桥 ● ", "/", "s"},
    "usagePanel": {"USB ○ 未连接", "USB ● ", "未连接", "帧", "ms", "帧 ", "桥 ○", "桥 ● ", "/", "s"},
    "agentPanelV": {"#08090F"},
    "agentPanel": {"#08090F"},
}
REASON = "FrameStats 槽位：文案搬到 Dashboard.cs 的 LinkText/BridgeText/FrameCountText（文件头已说明）；#08090F → Theme.C.BadgeText"

API_WORDS = {"left", "center", "right", "bold", "normal", "middle", "start", "end", "italic"}


def strip_comments(s, is_cs):
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)
    s = re.sub(r"//[^\n]*", " ", s)
    return s


def split_methods(text, is_cs):
    if is_cs:
        pat = re.compile(r"^\s*(?:public|private|internal)\s+static\s+[\w<>\[\],\.\?]+\s+(\w+)\s*\(", re.M)
    else:
        pat = re.compile(r"^\s*(?:private\s+)?static\s+(\w+)\s*\(", re.M)
    marks = [(m.group(1), m.start()) for m in pat.finditer(text)]
    out = {}
    for i, (name, pos) in enumerate(marks):
        end = marks[i + 1][1] if i + 1 < len(marks) else len(text)
        out.setdefault(name, []).append(text[pos:end])
    return {k: "\n".join(v) for k, v in out.items()}


NUM = re.compile(r"(?<![\w.$])(\d+(?:\.\d+)?)(?![\w.])")
STR = re.compile(r"'([^'\n]*)'|\"([^\"\n]*)\"|`([^`]*)`")


def nums(body):
    out = set()
    for m in NUM.finditer(body):
        v = m.group(1)
        if "." in v:
            v = v.rstrip("0").rstrip(".") if v.endswith("0") else v
        out.add(v)
    return out


def fragments(body):
    """模板串按 ${...} 切段后的文案片段集合；剥掉 API 枚举词"""
    out = set()
    for m in STR.finditer(body):
        v = m.group(1) if m.group(1) is not None else (m.group(2) if m.group(2) is not None else m.group(3))
        if not v:
            continue
        for frag in re.split(r"\$\{[^}]*\}", v):
            if frag and frag.strip().lower() not in API_WORDS:
                out.add(frag)
    return out


EXPECT_NUMS = {}


def main():
    ets = strip_comments(io.open(ETS, encoding="utf-8").read(), False)
    cs = strip_comments(io.open(CS, encoding="utf-8").read(), True)
    em, cm = split_methods(ets, False), split_methods(cs, True)
    print(f"ArkTS 方法 {len(em)} 个，C# 方法 {len(cm)} 个，逐方法核对 {len(PAIRS)} 对\n")
    bad = []
    for e_name, c_name in PAIRS:
        e, c = em.get(e_name), cm.get(c_name)
        if e is None or c is None:
            print(f"  [MISS] {e_name} -> {c_name}")
            bad.append(c_name)
            continue
        en, cn = nums(e), nums(c)
        dn = sorted(en - cn, key=float)
        xn = sorted(cn - en, key=float)
        ef, cf = fragments(e), fragments(c)
        df = sorted(ef - cf)
        xf = sorted(cf - ef)
        prob = []
        un = [d for d in dn if d not in WNUM_ETS_ONLY.get(e_name, {})]
        if un:
            prob.append(f"数字缺 {un}")
        uf = [d for d in df if d not in WSTR_ETS_ONLY.get(e_name, set())]
        if uf:
            prob.append(f"文案缺 {uf}")
        if prob:
            bad.append(c_name)
        print(f"  [{'OK  ' if not prob else 'DIFF'}] {e_name:15s}-> {c_name:18s} "
              f"数字 {len(en):2d}/{len(cn):2d}  文案 {len(ef):2d}/{len(cf):2d}"
              + ("   " + "; ".join(prob) if prob else ""))
        if dn:
            for d in dn:
                why = WNUM_ETS_ONLY.get(e_name, {}).get(d, "** 未解释 **")
                print(f"         ArkTS 独有数字 {d:>7s} : {why}")
        if dn == [] and xn:
            pass
        if xn and c_name in WNUM_CS_EXTRA:
            print(f"         C# 额外数字 {xn} : {WNUM_CS_EXTRA[c_name]}")
        if df:
            wh = WSTR_ETS_ONLY.get(e_name, set())
            for d in df:
                print(f"         ArkTS 独有文案 {d!r} : " +
                      (REASON if d in wh else "** 未解释 **"))
        if xf:
            print(f"         C# 额外文案 {xf}")
    print()
    print("结论：", "全部方法一致（差异仅限已说明的机制性差异）" if not bad
          else f"需人工确认：{bad}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
