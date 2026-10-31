/**
 * SystemMerge.ets — 选一份系统数据来渲染（纯函数，不碰任何平台 kit，可在主机上离线自检）
 *
 * 规则：桥端数据新鲜就用桥端（它代表 DSH 所在机器的真实负载），否则退回本机；
 * **但电量是本机属性**（桥端 JSON 里没有这一项），所以不管用哪一份，都拿本机读数补上——
 * 不补的话"电量"这一行只在桥端断流时才出现（桥端正常跑着反而看不到电量）。
 *
 * 与 Windows 侧 State.PickSystem() 是同一条规则、同一组用例。
 */
import type { SystemInfo } from './Types.ts';

export function pickSystem(bridge: SystemInfo | undefined, bridgeFresh: boolean,
                           local: SystemInfo): SystemInfo {
  // 桥端数据新鲜就用桥端（它代表 DSH 所在机器的真实负载），否则退回本机
  const base: SystemInfo = (bridgeFresh && bridge !== undefined) ? bridge : local;
  // 电量是**本机**属性（桥端 JSON 里没有这一项）：不管用哪一份数据，都拿本机读数补上。
  // 不补的话"电量"这一行只在桥端断流时才出现 —— 桥端正常跑着反而看不到电量。
  if (base.battery === undefined || base.battery < 0) {
    base.battery = local.battery;
    base.charging = local.charging;
  }
  return base;
}
