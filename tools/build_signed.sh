#!/usr/bin/env bash
# 构建「可安装的签名 HAP」——在副本里构建，源工程保持干净。
#
# 为什么需要它：签名 profile 与 bundleName 强绑定。我们要么在 DevEco 里为本工程
# 生成新证书（bundle com.dsh.trofeolcd），要么复用已有签名材料——后者要求 bundle
# 名与 profile 一致，所以这里会临时把 bundle 名改成签名材料对应的那个。
#
# 默认复用 ~/WorkBuddy/DeepSeekHarness 的签名材料（profile: com.deepseek.harness，
# debug 类型，绑定 2 个设备 UDID，有效期到 2027-08）。
#
# 用法:
#   tools/build_signed.sh                       # 复用默认签名材料
#   SIGN_FROM=~/WorkBuddy/XXX tools/build_signed.sh
set -e

D="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_FROM="${SIGN_FROM:-$HOME/WorkBuddy/DeepSeekHarness}"
W="$HOME/WorkBuddy/.trofeolcd-signed"
CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0

if [ ! -f "$SIGN_FROM/build-profile.json5" ]; then
  echo "找不到签名来源工程: $SIGN_FROM"; exit 1
fi

rm -rf "$W"; mkdir -p "$W"
for item in AppScope entry hvigor tools build-profile.json5 hvigorfile.ts \
            oh-package.json5 local.properties .npmrc; do
  [ -e "$D/$item" ] && cp -r "$D/$item" "$W/"
done
rm -rf "$W/.hvigor" "$W/entry/build" "$W/oh_modules" "$W/.bitfun" "$W/tools/__pycache__"

python3 - "$W" "$SIGN_FROM" <<'PY'
import json, os, re, sys
W, SIGN_FROM = sys.argv[1], sys.argv[2]
src = open(os.path.join(SIGN_FROM, 'build-profile.json5')).read()
m = re.search(r'"signingConfigs": \[.*?\n    \],', src, re.S)
if not m:
    print('签名来源工程里没有 signingConfigs'); sys.exit(1)
signing = m.group(0)
# profile 里的 bundle 名
prof = re.search(r'"profile":\s*"([^"]+)"', signing)
bundle = None
if prof:
    p = prof.group(1)
    out = os.path.join(W, '.prof.json')
    os.system(f'"$HOME/.harmonybrew/bin/hap-sign-tool" verify-profile -inFile "{p}" '
              f'-outFile "{out}" >/dev/null 2>&1')
    try:
        bundle = json.load(open(out)).get('bundle-info', {}).get('bundle-name')
    except Exception:
        bundle = None
    os.path.exists(out) and os.remove(out)

# 改 bundle 名以匹配 profile
if bundle:
    ap = os.path.join(W, 'AppScope/app.json5')
    s = open(ap).read()
    s = re.sub(r'"bundleName":\s*"[^"]+"', f'"bundleName": "{bundle}"', s)
    # versionCode 必须 >= 已安装版本，否则升级安装会被拒
    s = re.sub(r'"versionCode":\s*\d+', '"versionCode": 2000000', s)
    open(ap, 'w').write(s)

bp = os.path.join(W, 'build-profile.json5')
s = open(bp).read()
s = s.replace('"signingConfigs": [],', signing)
if '"signingConfig": "default"' not in s:
    s = s.replace('"name": "default",\n        "compatibleSdkVersion"',
                  '"name": "default",\n        "signingConfig": "default",\n        "compatibleSdkVersion"')
open(bp, 'w').write(s)
print(f'签名来源: {SIGN_FROM}')
print(f'bundleName -> {bundle}  (与 profile 绑定一致才能安装)')
PY

export NODE_HOME="$CLT/node/bin" DEVECO_SDK_HOME="$CLT/sdk" PATH="$CLT/node/bin:$PATH"
cd "$W"
"$CLT/hvigor/bin/hvigorw" --mode module -p product=default assembleHap --no-daemon \
  2>&1 | grep -viE "Finished :|UP-TO-DATE|Installing pnpm|added [0-9]+ package|npm fund|vulnerabilit|npm audit|Pnpm install"

SIGNED="$W/entry/build/default/outputs/default/entry-default-signed.hap"
if [ -f "$SIGNED" ]; then
  mkdir -p "$D/.build-output"
  cp "$SIGNED" "$D/.build-output/entry-default-signed.hap"
  echo
  echo "签名产物: $D/.build-output/entry-default-signed.hap ($(stat -c%s "$SIGNED") bytes)"
  "$HOME/.harmonybrew/bin/hap-sign-tool" verify-app -inFile "$SIGNED" \
    -outCertChain "$W/.c.cer" -outProfile "$W/.p.p7b" 2>&1 | grep -iE "verify-app success|failed"
else
  echo "未产出签名 HAP（检查 signingConfigs 是否有效）"; exit 1
fi
