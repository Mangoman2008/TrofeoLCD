#!/usr/bin/env bash
# 在电脑上运行**真实的 LcdUsb.ets 源码**，配假的 usbManager 与仿真 LY 设备。
#
# 覆盖整条 USB 链路：枚举 → 授权 → 连接 → 配置 → 断言点 → 握手 → 分块 → 推帧 → ACK → 掉线
# 其中"推帧"是完整往返：把推出去的字节按 LY 规范重新解析（解码器在测试里独立实现），
# 要求还原出与输入逐字节相同的 JPEG。
#
# 明确不覆盖：真实 USB 驱动的行为、usbManager 服务端的实现细节 —— 那些只能靠真机。
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
W="$D/.hwtest"
rm -rf "$W"; mkdir -p "$W"

cp "$D/tools/hwsim/FakeKits.ts" "$D/tools/hwsim/Logger.ts" "$D/tools/hwsim/run.mts" "$W/"
cp "$D/entry/src/main/ets/usb/LyProtocol.ets" "$W/LyProtocol.ts"
cp "$D/entry/src/main/ets/usb/EndpointPick.ets" "$W/EndpointPick.ts"
sed -e "s|from '@kit.BasicServicesKit'|from './FakeKits.ts'|g" \
    -e "s|from './LyProtocol'|from './LyProtocol.ts'|g" \
    -e "s|from './EndpointPick'|from './EndpointPick.ts'|g" \
    -e "s|from '../common/Logger'|from './Logger.ts'|g" \
    "$D/entry/src/main/ets/usb/LcdUsb.ets" > "$W/LcdUsb.ts"

cd "$W"
node --no-warnings --experimental-strip-types run.mts
