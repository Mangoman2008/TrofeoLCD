#!/usr/bin/env bash
# 签名就绪检查：在 DevEco 里点「自动签名」之前，确认工程侧没有任何会挡住签名的东西
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
ok=0; bad=0
chk() { if [ "$2" = "1" ]; then printf "  ✅ %-34s %s\n" "$1" "${3:-}"; ok=$((ok+1)); else printf "  ❌ %-34s %s\n" "$1" "${3:-}"; bad=$((bad+1)); fi; }

echo "=== A. 应用级配置（签名会绑定 bundle 名）==="
python3 - "$D" <<'PY'
import json, re, sys, os
D = sys.argv[1]
s = open(f'{D}/AppScope/app.json5').read()
bn = re.search(r'"bundleName":\s*"([^"]+)"', s)
vc = re.search(r'"versionCode":\s*(\d+)', s)
vn = re.search(r'"versionName":\s*"([^"]+)"', s)
icon = re.search(r'"icon":\s*"([^"]+)"', s)
label = re.search(r'"label":\s*"([^"]+)"', s)
print(f'  {"✅" if bn else "❌"} bundleName                     {bn.group(1) if bn else "缺失"}')
print(f'  {"✅" if vc and vn else "❌"} version                       {vc.group(1) if vc else "?"} / {vn.group(1) if vn else "?"}')
# 分层图标与兜底图标
media = f'{D}/AppScope/resources/base/media'
has_layered = os.path.exists(f'{media}/layered_image.json')
has_plain = os.path.exists(f'{media}/app_icon.png')
fg = os.path.exists(f'{media}/foreground.png'); bg = os.path.exists(f'{media}/background.png')
print(f'  {"✅" if (has_layered and fg and bg) or has_plain else "❌"} 图标资源                      '
      f'layered={has_layered}(fg={fg},bg={bg}) 普通PNG={has_plain}')
# app_name
st = f'{D}/AppScope/resources/base/element/string.json'
names = [i.get('name') for i in json.load(open(st))['string']] if os.path.exists(st) else []
print(f'  {"✅" if "app_name" in names else "❌"} app_name 字符串资源           {names}')
PY

echo "=== B. 模块与设备类型（目标设备是 tablet）==="
python3 - "$D" <<'PY'
import json, re, sys, os
D = sys.argv[1]
s = open(f'{D}/entry/src/main/module.json5').read()
dt = re.search(r'"deviceTypes":\s*\[(.*?)\]', s, re.S)
types = re.findall(r'"([^"]+)"', dt.group(1)) if dt else []
me = re.search(r'"mainElement":\s*"([^"]+)"', s)
ab = re.findall(r'"srcEntry":\s*"([^"]+)"', s)
print(f'  {"✅" if "tablet" in types else "❌"} deviceTypes 含 tablet          {types}')
print(f'  {"✅" if me else "❌"} mainElement                   {me.group(1) if me else "缺失"}')
print(f'  {"✅" if ab else "❌"} ability srcEntry               {ab}')
perms = re.findall(r'"name":\s*"(ohos\.permission\.[^"]+)"', s)
print(f'  ✅ 权限声明                      {perms}')
PY

echo "=== C. 构建配置 ==="
grep -q '"signingConfigs": \[\]' "$D/build-profile.json5" && chk "signingConfigs 为空（待 DevEco 填）" 1 || chk "signingConfigs" 0 "已非空（可能已签名）"
grep -q '"compatibleSdkVersion"' "$D/build-profile.json5" && chk "compatibleSdkVersion 存在" 1 "$(grep -o '"compatibleSdkVersion": "[^"]*"' "$D/build-profile.json5")" || chk "compatibleSdkVersion" 0
[ -f "$D/.npmrc" ] && chk ".npmrc 存在（Sync 需要）" 1 || chk ".npmrc" 0 "缺失会导致 ohpm 404"
[ -f "$D/local.properties" ] && chk "local.properties 存在" 1 || chk "local.properties" 0

echo "=== D. 工程干净度（CLI 缓存会破坏 DevEco 同步）==="
CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0
CLT_TC="$(python3 -c "import json;print(json.load(open('$CLT/sdk/default/openharmony/toolchains/oh-uni-package.json'))['version'])" 2>/dev/null || echo '')"
META="$D/.hvigor/cache/meta.json"
# 注意：本机 DevEco 也用 hmos-clt 工具链，版本指纹与 CLI 相同，
# 因此"指纹相同"并不代表污染 —— 这里只作提示，不算失败项。
if [ -f "$META" ]; then
  TC="$(python3 -c "import json;print(json.load(open('$META')).get('toolChainsVersion',''))" 2>/dev/null || echo '')"
  SYNCED=""; [ -d "$D/.hvigor/outputs/sync" ] && SYNCED="，且 DevEco 已同步过"
  printf "  ℹ️  %-34s toolchains=%s%s\n" ".hvigor 存在" "$TC" "$SYNCED"
else
  printf "  ✅ %-34s %s\n" ".hvigor 不存在" "（干净）"
fi
[ -d "$D/entry/build" ] && chk "entry/build（产物，DevEco 会重建）" 1 "存在，无碍" || chk "entry/build" 1 "无"

echo
echo "结论: $ok 项就绪, $bad 项待处理"
[ "$bad" = "0" ] && echo "→ 可以在 DevEco 里直接点自动签名了" || echo "→ 先处理上面 ❌ 项"
