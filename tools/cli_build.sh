#!/usr/bin/env bash
# 命令行构建 HAP —— 在临时副本里构建，源工程保持干净。
#
# 为什么不在源目录构建：hvigor 会把**本机 SDK 路径**写进
# .hvigor/cache/project-config.json（/data/service/hnp/hmos-clt.org/...）。
# 这份缓存一旦被带到 DevEco 就会导致 Sync 失败，而 Sync 失败的表现是
# app.json5 里的 $string:app_name / $media:layered_image 报「无法解析符号」。
# 所以在副本里构建，源工程永远保持可交付状态。
set -e

D="$(cd "$(dirname "$0")/.." && pwd)"
W="$HOME/WorkBuddy/.trofeolcd-build"
CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0

rm -rf "$W"
mkdir -p "$W"
# 只拷源码，排除所有生成物
for item in AppScope entry hvigor tools build-profile.json5 hvigorfile.ts \
            oh-package.json5 local.properties .npmrc README.md; do
  [ -e "$D/$item" ] && cp -r "$D/$item" "$W/"
done
rm -rf "$W/.hvigor" "$W/entry/build" "$W/oh_modules" "$W/.bitfun" "$W/tools/__pycache__"

export NODE_HOME="$CLT/node/bin"
export DEVECO_SDK_HOME="$CLT/sdk"
export PATH="$CLT/node/bin:$PATH"

cd "$W"
"$CLT/hvigor/bin/hvigorw" --mode module -p product=default assembleHap --no-daemon \
  2>&1 | grep -viE "Finished :|UP-TO-DATE|Installing pnpm|added [0-9]+ package|npm fund|vulnerabilit|npm audit|Pnpm install"

OUT="$W/entry/build/default/outputs/default"
mkdir -p "$D/.build-output"
FOUND=0
if [ -f "$OUT/entry-default-signed.hap" ]; then
  cp "$OUT/entry-default-signed.hap" "$D/.build-output/entry-default-signed.hap"
  echo
  echo "✅ 签名产物: $D/.build-output/entry-default-signed.hap ($(stat -c%s "$OUT/entry-default-signed.hap") bytes)"
  "$HOME/.harmonybrew/bin/hap-sign-tool" verify-app \
    -inFile "$OUT/entry-default-signed.hap" \
    -outCertChain "$W/.c.cer" -outProfile "$W/.p.p7b" 2>&1 | grep -iE "verify-app success|failed"
  FOUND=1
fi
if [ -f "$OUT/entry-default-unsigned.hap" ]; then
  cp "$OUT/entry-default-unsigned.hap" "$D/.build-output/entry-default-unsigned.hap"
  if [ "$FOUND" = "0" ]; then
    echo
    echo "⚠️  只有 unsigned 产物: $D/.build-output/entry-default-unsigned.hap"
    echo "    原因：build-profile.json5 的 signingConfigs 为空（尚未在 DevEco 里签名）"
    echo "    在 DevEco 里点一次「自动签名」后，本脚本就会自动产出签名包。"
  fi
  FOUND=1
fi
[ "$FOUND" = "0" ] && { echo "构建未产出 HAP"; exit 1; }
echo "源工程未被写入任何构建缓存（可安全交付 DevEco）"
