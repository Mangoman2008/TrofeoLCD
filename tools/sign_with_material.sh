#!/usr/bin/env bash
# 用**你自己的证书材料**直接签名（不依赖 DevEco 的签名配置对话框）
#
# 适用场景：DevEco 里找不到「项目结构 → 签名配置」，但你手上有
#   ① .p12   ——「构建 → 生成密钥和证书请求文件」产出的密钥库
#   ② .cer   —— 用 .csr 向华为换来的应用证书
#   ③ .p7b   —— 华为签发的 Profile（必须包含本机 UDID）
# 这条路径直接调 hap-sign-tool 签 HAP，**不修改 build-profile.json5**，
# 因此不会因密码格式（DevEco 用加密串）而卡住。
#
# 用法：
#   tools/sign_with_material.sh --p12 KEY.p12 --cer APP.cer --profile PROFILE.p7b \
#        [--alias debugKey] [--store-pwd 密码] [--key-pwd 密码]
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
SB="$HOME/.harmonybrew/bin/hap-sign-tool"
P12=""; CER=""; PROF=""; ALIAS="debugKey"; SPWD=""; KPWD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) P12="$2"; shift 2;;
    --cer) CER="$2"; shift 2;;
    --profile) PROF="$2"; shift 2;;
    --alias) ALIAS="$2"; shift 2;;
    --store-pwd) SPWD="$2"; shift 2;;
    --key-pwd) KPWD="$2"; shift 2;;
    *) shift;;
  esac
done
[ -z "$KPWD" ] && KPWD="$SPWD"

for f in "$P12" "$CER" "$PROF"; do
  [ -f "$f" ] || { echo "❌ 文件不存在: $f"; exit 1; }
done
UNSIGNED="$D/.build-output/entry-default-unsigned.hap"
[ -f "$UNSIGNED" ] || { echo "缺少未签名包，先跑 tools/cli_build.sh"; exit 1; }

echo "=== 先看看 Profile 绑的是哪个 bundle / 哪些设备 ==="
T="$D/.verify-sign"; rm -rf "$T"; mkdir -p "$T"
"$SB" verify-profile -inFile "$PROF" -outFile "$T/p.json" >/dev/null 2>&1 || true
python3 - "$T/p.json" "$D/AppScope/app.json5" <<'PY'
import json, re, sys, datetime
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print('  ⚠️ Profile 解析失败:', e); raise SystemExit
app = open(sys.argv[2]).read()
bundle = re.search(r'"bundleName":\s*"([^"]+)"', app).group(1)
pb = d.get('bundle-info', {}).get('bundle-name')
ids = d.get('debug-info', {}).get('device-ids', [])
v = d.get('validity', {})
print(f"  Profile bundle : {pb}")
print(f"  工程 bundle    : {bundle}   {'✅ 一致' if pb == bundle else '❌ 不一致（装不上，必须一致）'}")
print(f"  类型           : {d.get('type')}")
print(f"  绑定设备数     : {len(ids)}" + ('（release 类型无设备限制）' if not ids else ''))
print(f"  有效期至       : {datetime.datetime.fromtimestamp(v.get('not-after',0)):%Y-%m-%d}")
PY

echo
echo "=== 签名 ==="
OUT="$D/.build-output/entry-default-signed.hap"
"$SB" sign-app -keyAlias "$ALIAS" -signAlg SHA256withECDSA -mode localSign \
  -appCertFile "$CER" -profileFile "$PROF" -inFile "$UNSIGNED" \
  -keystoreFile "$P12" -outFile "$OUT" \
  -keyPwd "$KPWD" -keystorePwd "$SPWD" -signCode 1 2>&1 | tail -4

if [ -f "$OUT" ]; then
  echo
  echo "签名产物: $OUT ($(stat -c%s "$OUT") bytes)"
  "$SB" verify-app -inFile "$OUT" -outCertChain "$T/c.cer" -outProfile "$T/p2.p7b" 2>&1 \
    | grep -iE "verify-app success|failed"
else
  echo "❌ 未产出签名包"; exit 1
fi
rm -rf "$T"
