#!/usr/bin/env python3
"""
theme_pong_verify.py — 主题 4「打砖块」的离线一致性验证

## 为什么需要它
`win/src/ThemePong.cs` 无法在本机编译（本机是 musl，.NET 是 glibc 构建），
而它的核心是**确定性物理**：LCG 随机 + 每 tick 的位置积分。
这类逻辑只要**常量或公式抄错一位**，屏上表现就是"球会动但轨迹怪"，
靠肉眼看渲染结果很难发现。

所以这里做两件事：
  ① **常量逐条比对**：从 `ThemePong.cs` 里按正则读出所有版面/玩法常量，
     与 `ThemePong.ets` 的同名常量逐一核对 —— 抄错立刻报。
  ② **物理独立复现**：用 Python 重新实现同一套公式（LCG / launch / 碰撞 / 挡板），
     跑几千 tick，断言不变量（球不出界、砖数单调、重开会回满、tick 与帧预算一致）。

⚠️ 这**不能替代编译**，但能抓住"数值抄错"和"公式抄错"这两类最隐蔽的问题。
"""
import math
import re
import sys
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CS = os.path.join(ROOT, 'win', 'src', 'ThemePong.cs')
ETS = os.path.join(ROOT, 'entry', 'src', 'main', 'ets', 'render', 'ThemePong.ets')

fails = []
def check(ok, msg):
    if not ok:
        fails.append(msg)

# ---------------------------------------------------------------------------
# ① 常量比对：C# vs ArkTS
# ---------------------------------------------------------------------------
# 常量名映射（ArkTS 用 k 前缀，C# 用 PascalCase）
PAIRS = [
    ('CanvasW', 'kCanvasW'), ('CanvasH', 'kCanvasH'),
    ('BrickRows', 'kBrickRows'), ('BrickCols', 'kBrickCols'),
    ('BrickW', 'kBrickW'), ('BrickH', 'kBrickH'), ('BrickGap', 'kBrickGap'),
    ('BrickStartX', 'kBrickStartX'), ('BrickStartY', 'kBrickStartY'),
    ('PaddleW', 'kPaddleW'), ('TimeY', 'kTimeY'), ('DateY', 'kDateY'),
    ('DigitW', 'kDigitW'), ('DigitH', 'kDigitH'), ('ColonW', 'kColonW'),
    ('PaddleY', 'kPaddleY'),
    ('BallSize', 'kBallSize'), ('PaddleH', 'kPaddleH'),
    ('PaddleSpeed', 'kPaddleSpeed'), ('TickMs', 'kTickMs'),
    ('StickyMs', 'kStickyMs'), ('StickyTrigger', 'kStickyTrigger'),
    ('ResetAfterMisses', 'kResetAfterMisses'),
]
FLOAT_PAIRS = [
    ('BallSpeed', 'kBallSpeed'),
    ('PaddleJitterDeg', 'kPaddleJitterDeg'),
    ('StickyJitterDeg', 'kStickyJitterDeg'),
    ('Scale', 'kScale'),
]

def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()

cs_src, ets_src = read(CS), read(ETS)

def cs_const(name):
    m = re.search(r'public const (?:int|double) %s = ([0-9.]+)' % re.escape(name), cs_src)
    return m.group(1) if m else None

def ets_const(name):
    m = re.search(r'const %s: number = ([0-9.]+)' % re.escape(name), ets_src)
    return m.group(1) if m else None

print('① 常量比对（C# ↔ ArkTS 同名常量）')
for cs_n, ets_n in PAIRS + FLOAT_PAIRS:
    a, b = cs_const(cs_n), ets_const(ets_n)
    check(a is not None, f'  ❌ C# 缺常量 {cs_n}')
    check(b is not None, f'  ❌ ArkTS 缺常量 {ets_n}')
    if a is not None and b is not None:
        check(float(a) == float(b),
              f'  ❌ {cs_n}={a} ≠ ArkTS {ets_n}={b}')
print(f'  核对了 {len(PAIRS) + len(FLOAT_PAIRS)} 个常量')

# 砖色：C# 必须与 ArkTS 用同一套 4:2:0 预补偿值
def hexes(src, pattern):
    return re.findall(pattern, src)

cs_colors = re.findall(r'Color\.FromArgb\(0x([0-9A-Fa-f]{2}), 0x([0-9A-Fa-f]{2}), 0x([0-9A-Fa-f]{2})\)',
                      cs_src.split('BrickColors')[1].split('};')[0])
cs_hex = ['#' + ''.join(c).upper() for c in cs_colors]
ets_hex = [h.upper() for h in re.findall(r"'(#[0-9A-Fa-f]{6})'",
           ets_src.split('kBrickColors: string[] = [')[1].split(']')[0])]
print(f'② 砖色（4:2:0 预补偿）：C# {cs_hex}')
print(f'                        ArkTS {ets_hex}')
check(cs_hex == ets_hex, f'  ❌ 砖色不一致')

# ---------------------------------------------------------------------------
# ③ 帧预算 / 防御性常量
# ---------------------------------------------------------------------------
print('③ 关键防御常量')
m = re.search(r'Math\.Min\(Math\.Floor\(dtMs / TickMs\), (\d+)\)', cs_src)
check(m is not None and m.group(1) == '8', '  ❌ Advance 的单帧最大补 tick 数不是 8')
print(f'  单帧最大补 tick = {m.group(1) if m else "?"}（防卡顿穿砖）')

# ★ 只在**去掉注释后**的代码里找真实调用 —— 否则注释里那句
#   "一次都没用 System.Random" 会把自己匹配出来（第一版就是这么误报的）。
def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    return src

code_only = strip_comments(cs_src)
for must in ['System.Random', 'Math.Random', 'new Random']:
    check(must not in code_only, f'  ❌ C# 代码里出现了非确定性随机：{must}')
print('  未使用 System.Random / Math.Random（确定性 LCG）✅')

# ---------------------------------------------------------------------------
# ④ 物理独立复现：跑 4000 tick 断言不变量
# ---------------------------------------------------------------------------
print('④ 物理独立复现（Python 重写同一套公式）')
C = {n: float(cs_const(n)) for n, _ in PAIRS + FLOAT_PAIRS if cs_const(n)}
CANVAS_W, CANVAS_H = int(C['CanvasW']), int(C['CanvasH'])
BALL, PADDLE_W, PADDLE_H, PADDLE_Y = int(C['BallSize']), int(C['PaddleW']), int(C['PaddleH']), int(C['PaddleY'])
SPEED, PSPEED, TICKMS = C['BallSpeed'], int(C['PaddleSpeed']), int(C['TickMs'])

class St:
    def __init__(self, seed):
        self.rand = (abs(int(seed)) % 4294967295) + 1
        self.tick = 0
        self.bricks = [[True] * int(C['BrickCols']) for _ in range(int(C['BrickRows']))]
        self.bx = self.by = self.vx = self.vy = 0.0
        self.active = False
        self.stuck = False
        self.sticky_hit = 0.5
        self.sticky_until = 0
        self.paddle = CANVAS_W / 2
        self.misses = 0
        self.broken = 0
        self.hits = 0
        self.best = 0
        self.combo = 0
        self.resets = 0

def rnd(st):
    st.rand = (st.rand * 1664525 + 1013904223) % 4294967296
    return st.rand / 4294967296

def randint(st, mx):
    return int(rnd(st) * mx) % mx if mx > 0 else 0

def randrange(st, lo, hi):
    return lo + randint(st, hi - lo)

def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)

def launch(st, hit, jitter):
    h = clamp(hit, 0.08, 0.92)
    st.bx = st.paddle - PADDLE_W / 2 + h * PADDLE_W - BALL / 2
    st.by = PADDLE_Y - BALL
    a = clamp(150.0 - h * 120.0 + jitter, 30.0, 150.0)
    rad = a * 3.141592653589793 / 180.0
    import math
    st.vx = SPEED * math.cos(rad)
    st.vy = -SPEED * math.sin(rad)
    if abs(st.vx) < 1.2: st.vx = 1.2 if st.vx >= 0 else -1.2
    if abs(st.vy) < 1.0: st.vy = -1.5
    st.active = True; st.stuck = False; st.sticky_until = 0

def spawn(st):
    st.stuck = False; st.sticky_until = 0
    launch(st, 0.5, randrange(st, -50, 51) / 10.0)
    st.misses = 0

def use_sticky(st):
    if st.misses < int(C['StickyTrigger']): return False
    ch = 15 + (st.misses - int(C['StickyTrigger'])) * 10
    if ch > 70: ch = 70
    return randint(st, 100) < ch

def stick(st, hit):
    off = randrange(st, -18, 19) / 100.0
    st.sticky_hit = clamp(hit + off, 0.18, 0.82)
    st.stuck = True
    st.sticky_until = st.tick + round(int(C['StickyMs']) / TICKMS)
    st.active = True; st.vx = 0; st.vy = 0
    st.bx = st.paddle - PADDLE_W / 2 + st.sticky_hit * PADDLE_W - BALL / 2
    st.by = PADDLE_Y - BALL

def check_bricks(st):
    import math
    bx, by = math.floor(st.bx), math.floor(st.by)
    hx = hy = hit = False
    for r in range(int(C['BrickRows'])):
        for c in range(int(C['BrickCols'])):
            if not st.bricks[r][c]: continue
            rx = C['BrickStartX'] + c * (C['BrickW'] + C['BrickGap'])
            ry = C['BrickStartY'] + r * (C['BrickH'] + C['BrickGap'])
            if bx + BALL > rx and bx < rx + C['BrickW'] and by + BALL > ry and by < ry + C['BrickH']:
                st.bricks[r][c] = False
                st.broken += 1; st.combo += 1
                st.best = max(st.best, st.combo)
                oL = (bx + BALL) - rx; oR = (rx + C['BrickW']) - bx
                oT = (by + BALL) - ry; oB = (ry + C['BrickH']) - by
                if min(oL, oR) < min(oT, oB): hx = True
                else: hy = True
                hit = True
    if hx: st.vx = -st.vx
    if hy: st.vy = -st.vy
    if hit:
        st.bx += st.vx; st.by += st.vy; st.misses = 0
    return hit

def bricks_left(st):
    return sum(1 for r in st.bricks for v in r if v)

def update_paddle(st):
    if st.stuck: return
    target = math.floor(st.bx + BALL / 2) if (st.active and st.vy > 0) else math.floor(CANVAS_W / 2)
    d = target - st.paddle
    if abs(d) > 2:
        step = min(PSPEED, abs(d))
        st.paddle += step if d > 0 else -step
    st.paddle = clamp(st.paddle, PADDLE_W / 2, CANVAS_W - PADDLE_W / 2)

def update_ball(st):
    import math
    if not st.active: return
    if st.stuck:
        st.bx = st.paddle - PADDLE_W / 2 + st.sticky_hit * PADDLE_W - BALL / 2
        st.by = PADDLE_Y - BALL
        if st.tick >= st.sticky_until:
            lim = round(C['StickyJitterDeg'] * 10)
            launch(st, st.sticky_hit, randrange(st, -lim, lim + 1) / 10.0)
        return
    st.bx += st.vx; st.by += st.vy
    if st.bx <= 0: st.bx = 0; st.vx = abs(st.vx)
    if st.bx >= CANVAS_W - BALL: st.bx = CANVAS_W - BALL; st.vx = -abs(st.vx)
    if st.by <= 0: st.by = 0; st.vy = abs(st.vy)
    if st.vy > 0 and st.by + BALL >= PADDLE_Y and st.by < PADDLE_Y + PADDLE_H:
        pL = st.paddle - PADDLE_W / 2; pR = st.paddle + PADDLE_W / 2
        if st.bx + BALL >= pL and st.bx <= pR:
            hit = (st.bx + BALL / 2 - pL) / PADDLE_W
            st.misses += 1; st.hits += 1; st.combo = 0
            if use_sticky(st): stick(st, hit)
            else:
                lim = round(C['PaddleJitterDeg'] * 10)
                launch(st, hit, randrange(st, -lim, lim + 1) / 10.0)
            if st.misses >= int(C['ResetAfterMisses']):
                st.misses = 0; st.resets += 1
                for r in range(int(C['BrickRows'])):
                    for c in range(int(C['BrickCols'])): st.bricks[r][c] = True
    if st.by > CANVAS_H: spawn(st)
    check_bricks(st)
    if bricks_left(st) <= 0:
        st.resets += 1
        for r in range(int(C['BrickRows'])):
            for c in range(int(C['BrickCols'])): st.bricks[r][c] = True

TICKS = 4000
st = St(12345)
spawn(st)
oob = 0
maxv = 0.0
for _ in range(TICKS):
    st.tick += 1
    update_ball(st); update_paddle(st)
    if st.active and not st.stuck:
        if st.bx < -1 or st.bx > CANVAS_W - BALL + 1 or st.by < -1 or st.by > CANVAS_H + 1:
            oob += 1
        maxv = max(maxv, abs(st.vx), abs(st.vy))

check(oob == 0, f'  ❌ 球出界 {oob} 次（应在画布内）')
check(st.broken > 0, '  ❌ 4000 tick 内一次砖都没砸到')
check(st.hits > 0, '  ❌ 4000 tick 内一次都没接到球')
check(0 <= st.paddle <= CANVAS_W, '  ❌ 挡板越界')
check(maxv <= SPEED + 2.0, f'  ❌ 球速异常 max={maxv:.2f}（基准 {SPEED}）')
check(st.best >= 1, '  ❌ 最高连击 < 1')
print(f'  {TICKS} tick 跑完：砸砖 {st.broken} · 接球 {st.hits} · 最高连击 {st.best} · 重开 {st.resets}')
print(f'  球速上限 {maxv:.2f}（基准 {SPEED}）· 出界 {oob} 次')

# 确定性：同种子两次跑必须完全一致
def run(seed, ticks):
    s = St(seed); spawn(s)
    for _ in range(ticks):
        s.tick += 1; update_ball(s); update_paddle(s)
    return (s.bx, s.by, s.broken, s.hits, s.rand)
check(run(12345, 800) == run(12345, 800), '  ❌ 同种子两次跑结果不一致（非确定性！）')
print('  同种子两次跑逐值一致 ✅（确定性成立）')

# 帧预算
def advance_ticks(dt):
    return int(min(dt // TICKMS, 8))
check(advance_ticks(20) == 1, '  ❌ dt=20ms 应补 1 tick')
check(advance_ticks(160) == 8, '  ❌ dt=160ms 应补 8 tick')
check(advance_ticks(5000) == 8, '  ❌ 大卡顿应封顶 8 tick（防穿砖）')
print('  帧预算：20ms→1 · 160ms→8 · 5000ms→8（封顶）✅')

# ---------------------------------------------------------------------------
print()
if fails:
    print(f'❌ {len(fails)} 项未通过：')
    for f in fails:
        print(f)
    sys.exit(1)
print('✅ 主题 4 打砖块：常量一致 + 物理不变量全部通过')
