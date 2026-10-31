#!/usr/bin/env bash
# 交付/安装前自检：一眼看清当前状态与还差什么
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
HDC="$(command -v hdc || echo "$HOME/.harmonybrew/bin/hdc")"

echo "=== 1. 目标设备（本机）==="
for p in const.product.name const.product.model const.product.devicetype const.ohos.apiversion const.product.brand; do
  v=$(param get $p 2>/dev/null); printf "  %-30s %s\n" "$p" "${v:-（读不到）}"
done

echo "=== 2. hdc 与安装通路 ==="
T=$(timeout 12 "$HDC" list targets 2>/dev/null | tr -d '\r' | grep -viE '^\[?empty\]?$' | grep -v '^$')
if [ -n "$T" ]; then echo "  ✅ 已连接: $T"; else
  echo "  ❌ 未连接设备 —— 本机「无线调试」大概率没开"
  echo "     开启后: tools/install_local.sh --port <无线调试端口>"
fi

echo "=== 3. 产物 ==="
for f in .build-output/entry-default-signed.hap .build-output/entry-default-unsigned.hap; do
  if [ -f "$D/$f" ]; then printf "  ✅ %-40s %s bytes\n" "$f" "$(stat -c%s "$D/$f")"; else printf "  —  %s\n" "$f"; fi
done

echo "=== 4. 工程缓存来源（只应存在 DevEco 自己的缓存）==="
# 关键区分：hvigor 的 CLI 构建会把**本机 SDK 路径**写进
# .hvigor/cache/project-config.json，这份缓存带到 DevEco 会导致 Sync 失败。
# 而 DevEco 自己产生的 .hvigor / .bitfun 是正常的，不该删。
CLT="${CLT:-/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0}"
CLT_TC="$(python3 -c "import json;print(json.load(open('$CLT/sdk/default/openharmony/toolchains/oh-uni-package.json'))['version'])" 2>/dev/null || echo '')"
META="$D/.hvigor/cache/meta.json"
if [ -f "$META" ]; then
  TC="$(python3 -c "import json;print(json.load(open('$META')).get('toolChainsVersion',''))" 2>/dev/null || echo '')"
  HV="$(python3 -c "import json;print(json.load(open('$META')).get('hvigorVersion',''))" 2>/dev/null || echo '')"
  if [ -n "$CLT_TC" ] && [ "$TC" = "$CLT_TC" ]; then
    # 本机 DevEco 同样使用 hmos-clt 工具链，指纹相同属正常，不能据此判定污染
    echo "  ℹ️  .hvigor 指纹 hvigor=$HV toolchains=$TC（与本机工具链一致，正常）"
    echo "     仅当 DevEco 同步失败且重启无效时，才用 tools/clean_for_deveco.sh --force 清理"
  else
    echo "  ℹ️  .hvigor 指纹 hvigor=$HV toolchains=$TC（非本机 CLI，保留）"
  fi
elif [ -d "$D/.hvigor" ]; then
  echo "  ℹ️  .hvigor 存在但无 meta.json（保留）"
else
  echo "  ✅ 无 .hvigor"
fi
[ -d "$D/.bitfun" ] && echo "  ℹ️  .bitfun 存在（DevEco 自己的工程缓存，正常，保留）" || echo "  ✅ 无 .bitfun"
[ -d "$D/entry/build" ] && echo "  ℹ️  entry/build 存在（DevEco 构建产物，正常）" || echo "  ✅ 无 entry/build"

echo "=== 5. bundle 与签名绑定 ==="
BUNDLE=$(grep -oE '"bundleName": "[^"]+"' "$D/AppScope/app.json5" | head -1 | cut -d'"' -f4)
echo "  当前 bundleName: $BUNDLE"
if [ -f "$D/.build-output/entry-default-signed.hap" ]; then
  P="$D/.verify-preflight"; mkdir -p "$P"
  "$HOME/.harmonybrew/bin/hap-sign-tool" verify-app \
    -inFile "$D/.build-output/entry-default-signed.hap" \
    -outCertChain "$P/c.cer" -outProfile "$P/p.p7b" >/dev/null 2>&1
  "$HOME/.harmonybrew/bin/hap-sign-tool" verify-profile -inFile "$P/p.p7b" -outFile "$P/p.json" >/dev/null 2>&1
  python3 -c "
import json
try:
    d=json.load(open('$P/p.json'))
    print('  签名包 profile bundle:', d.get('bundle-info',{}).get('bundle-name'))
    print('  profile 绑定设备数:', len(d.get('debug-info',{}).get('device-ids',[])), '（本机必须在其列表中才能安装）')
except Exception as e: print('  解析失败:', e)
"
  rm -rf "$P"
fi
