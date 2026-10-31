// selftest_runner.mts — 在电脑上运行 App 的协议/校准/归一化自检
// （由 tools/run_selftest.sh 调用；.verify/ 下是镜像目录结构）
import { SelfTest } from './usb/SelfTest.ts';

const items = SelfTest.run();
for (const it of items) {
  console.log(`${it.ok ? '✅' : '❌'} ${it.name.padEnd(24)} ${it.detail}`);
}
const passed = items.filter((i) => i.ok).length;
console.log(`\n自检 ${passed}/${items.length} ${passed === items.length ? '通过' : '失败'}`);
process.exit(passed === items.length ? 0 : 1);
