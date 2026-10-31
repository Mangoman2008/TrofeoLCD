#!/usr/bin/env bash
# 安装到本机（本机就是 HUAWEI MatePad Edge）并启动、看日志。
#
# 前提：本机「设置 → 系统 → 开发者选项 → 无线调试」已开启。
# 本机就是目标设备，所以用 hdc tconn 127.0.0.1:<无线调试端口> 即可，不需要别的电脑。
#
# 用法:
#   tools/install_local.sh                 # 自动扫描本机端口找 hdc
#   tools/install_local.sh --port 39569    # 直接指定无线调试端口
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
HAP="$D/.build-output/entry-default-signed.hap"
HDC="$(command -v hdc || echo "$HOME/.harmonybrew/bin/hdc")"
PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    *) shift;;
  esac
done

if [ ! -f "$HAP" ]; then
  echo "没有签名包，请先跑: tools/build_signed.sh"; exit 1
fi

targets() { timeout 12 "$HDC" list targets 2>/dev/null | tr -d '\r' | grep -viE '^\[?empty\]?$' | grep -v '^$'; }

if [ -z "$(targets)" ]; then
  if [ -n "$PORT" ]; then
    echo "连接 127.0.0.1:$PORT ..."
    timeout 12 "$HDC" tconn "127.0.0.1:$PORT" 2>&1 | head -2
  else
    echo "未发现设备，扫描本机端口寻找 hdc（无线调试）..."
    CAND=$(python3 - <<'PY'
import socket, concurrent.futures
def probe(p):
    s = socket.socket(); s.settimeout(0.12)
    try:
        return p if s.connect_ex(('127.0.0.1', p)) == 0 else None
    except Exception:
        return None
    finally:
        s.close()
ports = list(range(30000, 50000))
with concurrent.futures.ThreadPoolExecutor(max_workers=256) as ex:
    hits = [r for r in ex.map(probe, ports, chunksize=256) if r]
print(' '.join(str(p) for p in sorted(hits)))
PY
)
    for p in $CAND; do
      timeout 10 "$HDC" tconn "127.0.0.1:$p" >/dev/null 2>&1
      if [ -n "$(targets)" ]; then echo "已通过端口 $p 连上本机"; PORT=$p; break; fi
    done
  fi
fi

T="$(targets)"
if [ -z "$T" ]; then
  cat <<'EOF'

❌ 没连上 hdc。请先在本机开启「无线调试」：
   设置 → 系统 → 开发者选项 → 无线调试（打开后界面上会显示 IP:端口）
然后重跑： tools/install_local.sh --port <端口>

（本机 = HUAWEI MatePad Edge，就是 LCD 要插的那台设备，无需其他电脑）
EOF
  exit 1
fi

echo "目标设备: $T"
echo "安装 $HAP ..."
timeout 180 "$HDC" install -r "$HAP" 2>&1 | tail -3
BUNDLE=$(python3 -c "
import json,re
s=open('$D/.build-output/../AppScope/app.json5').read() if False else None
" 2>/dev/null; grep -oE '\"bundleName\": \"[^\"]+\"' "$D/AppScope/app.json5" | head -1 | cut -d'\"' -f4)
echo "启动 $BUNDLE ..."
timeout 30 "$HDC" shell aa start -b "$BUNDLE" -a EntryAbility 2>&1 | tail -2
echo
echo "=== 应用日志（Ctrl-C 退出）==="
timeout 25 "$HDC" shell hilog 2>/dev/null | grep -E "TrofeoLCD|自检|USB|握手|设备:" | head -40
