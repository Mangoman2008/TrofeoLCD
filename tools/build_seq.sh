#!/usr/bin/env bash
# build_seq.sh — 在**独立副本**里构建签名 HAP（不碰源码工程，也不碰别的会话用的
# .trofeolcd-build / .trofeolcd-signed 目录），供「预烘焙序列」验证用。
#
# 与 tools/build_signed.sh 的区别：那个是通用签名流程（会改 bundle 名去匹配别人的
# profile）；本工程 build-profile.json5 里**已经有** com.dsh.trofeolcd 自己的
# signingConfigs，所以直接原样构建即可，产物与线上安装的包同 bundle。
set -e

D="$(cd "$(dirname "$0")/.." && pwd)"
W="${SEQ_BUILD_DIR:-$HOME/WorkBuddy/.trofeolcd-seqbuild}"
CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0

rm -rf "$W"
mkdir -p "$W"
for item in AppScope entry hvigor tools build-profile.json5 hvigorfile.ts \
            oh-package.json5 local.properties .npmrc; do
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
DEST="$D/.verify/video-seq/hap"
mkdir -p "$DEST"
if [ -f "$OUT/entry-default-signed.hap" ]; then
  cp "$OUT/entry-default-signed.hap" "$DEST/entry-default-signed.hap"
  echo
  echo "✅ 签名产物: $DEST/entry-default-signed.hap ($(stat -c%s "$OUT/entry-default-signed.hap") bytes)"
  "$HOME/.harmonybrew/bin/hap-sign-tool" verify-app -inFile "$OUT/entry-default-signed.hap" \
    -outCertChain "$W/.c.cer" -outProfile "$W/.p.p7b" 2>&1 | grep -iE "verify-app success|failed" || true
else
  echo "❌ 未产出签名 HAP"; exit 1
fi
