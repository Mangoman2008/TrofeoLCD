#!/usr/bin/env bash
# 用 SDK 自带的 OpenHarmony 材料，为本工程（独立 bundle）生成 profile 并签名。
#
# 用途：验证「这台设备是否信任 OpenHarmony 签名」。若信任，则完全不需要 DevEco
#       为每个 bundle 单独申请华为证书——本机命令行就能出可安装的包。
#
# 注意：Huawei 商用设备通常只信任华为签发的证书，所以成功率未知；但这一步零风险
#       （用的 bundle 是本工程自己的 com.dsh.trofeolcd，不会覆盖任何现有应用）。
#
# 与 tools/build_signed.sh 的区别：
#   build_signed.sh   复用已有华为签名材料（bundle 必须跟着变，会覆盖同名应用）
#   make_oh_signed.sh 自造 OpenHarmony profile（bundle 保持本工程的，不影响别人）
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0
L="$CLT/sdk/default/openharmony/toolchains/lib"
SB="$HOME/.harmonybrew/bin/hap-sign-tool"
W="$HOME/WorkBuddy/.oh-sign"

# 1) 先确保有未签名的 HAP
UNSIGNED="$D/.build-output/entry-default-unsigned.hap"
if [ ! -f "$UNSIGNED" ]; then
  echo "缺少未签名 HAP，先运行 tools/cli_build.sh"
  exit 1
fi

BUNDLE=$(grep -oE '"bundleName": "[^"]+"' "$D/AppScope/app.json5" | head -1 | cut -d'"' -f4)
rm -rf "$W"; mkdir -p "$W"

# 2) 生成 profile（bundle 用本工程自己的）
python3 - "$L" "$W" "$BUNDLE" <<'PY'
import json, sys, time, uuid
lib, w, bundle = sys.argv[1], sys.argv[2], sys.argv[3]
tpl = json.load(open(f'{lib}/UnsgnedReleasedProfileTemplate.json'))
tpl['bundle-info']['bundle-name'] = bundle
tpl['uuid'] = str(uuid.uuid4())
now = int(time.time())
tpl['validity'] = {'not-before': now - 86400, 'not-after': now + 365 * 86400}
json.dump(tpl, open(f'{w}/profile.json', 'w'), indent=2, ensure_ascii=False)
print(f'profile: bundle={bundle} type={tpl["type"]} feature={tpl["bundle-info"]["app-feature"]}')
PY

# 3) 用 OpenHarmony profile CA 签 profile
"$SB" sign-profile \
  -keyAlias "openharmony application profile release" \
  -signAlg SHA256withECDSA -mode localSign \
  -profileCertFile "$L/OpenHarmonyProfileRelease.pem" \
  -inFile "$W/profile.json" -keystoreFile "$L/OpenHarmony.p12" \
  -outFile "$W/profile.p7b" -keyPwd 123456 -keystorePwd 123456 >/dev/null

# 4) 用 OpenHarmony 应用证书签 HAP
"$SB" sign-app \
  -keyAlias "openharmony application release" \
  -signAlg SHA256withECDSA -mode localSign \
  -appCertFile "$L/OpenHarmonyApplication.pem" -profileFile "$W/profile.p7b" \
  -inFile "$UNSIGNED" -keystoreFile "$L/OpenHarmony.p12" \
  -outFile "$W/entry-oh-signed.hap" \
  -keyPwd 123456 -keystorePwd 123456 -signCode 1 >/dev/null

mkdir -p "$D/.build-output"
cp "$W/entry-oh-signed.hap" "$D/.build-output/entry-oh-signed.hap"
echo "产物: $D/.build-output/entry-oh-signed.hap ($(stat -c%s "$W/entry-oh-signed.hap") bytes)"
"$SB" verify-app -inFile "$W/entry-oh-signed.hap" \
  -outCertChain "$W/c.cer" -outProfile "$W/p.p7b" 2>&1 | grep -iE "verify-app success|failed"
