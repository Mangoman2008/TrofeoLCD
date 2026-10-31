// bambu-selftest.cs —— 拓竹取数的独立自检程序
//
// 目的：把"编译 + 连真实 broker + 验证字段映射"打包成**一条命令**，
//       不需要启动整个 dshlcd（不碰 USB、不开界面、不推屏）。
//
// 用法（在 Windows VM 上）：
//     cd /d C:\dshlcd
//     build-bambu-test.cmd                 # 默认观察 12 秒
//     build-bambu-test.cmd --seconds 60    # 跑久一点，看保活/持续推送
//
// ★ 2026-10-15 改：连接部分**不再自己写 MQTT 流程，而是直接用 BambuPrinter**。
//   原来自检走的是一条自己搭的并行路径，而主程序跑的是 BambuPrinter ——
//   两者不等价，自检"绿了"不代表主程序那条路也通。
//   现在自检覆盖的就是主程序真正会执行的编排：
//     发现设备 → 连 broker → 订阅 → pushall → 定时 pushall → 离线判定 → 重连

using System;
using System.Globalization;
using System.Text;
using System.Threading;

namespace DshLcd
{
    public static class BambuSelfTest
    {
        public static int Main(string[] args)
        {
            Console.OutputEncoding = Encoding.UTF8;
            // 打开 MQTT 包级追踪：排查连接/订阅问题时要看到每个字节的收发，否则只能猜
            MqttClient.Diagnostic = true;

            int seconds = 12;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--seconds" && i + 1 < args.Length)
                {
                    int.TryParse(args[i + 1], out seconds);
                    if (seconds <= 0) seconds = 12;
                }
            }

            Console.WriteLine("════════ 拓竹取数自检 ════════");
            Console.WriteLine();

            // ---------- 1. 配置 ----------
            string cfgPath = null;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--config" && i + 1 < args.Length) cfgPath = args[i + 1];
            }
            if (string.IsNullOrEmpty(cfgPath))
            {
                cfgPath = BambuConfig.ResolvePath(AppDomain.CurrentDomain.BaseDirectory);
            }
            Console.WriteLine("配置路径: " + cfgPath);
            if (!System.IO.File.Exists(cfgPath))
            {
                Console.WriteLine("❌ 配置文件不存在。请放一份 bambu.json（见 BambuConfig 的注释）。");
                return 1;
            }
            BambuConfig cfg = BambuConfig.Load(cfgPath);
            string token = cfg.ResolveToken();
            Console.WriteLine("  凭据来源 : " + cfg.CredentialSource());
            Console.WriteLine("  token    : " + BambuConfig.Mask(token));
            Console.WriteLine("  区域     : " + cfg.Region);
            Console.WriteLine("  序列号   : " + (string.IsNullOrEmpty(cfg.Serial) ? "(自动发现)" : cfg.Serial));
            if (token.Length < 20)
            {
                Console.WriteLine("❌ token 无效（长度 " + token.Length + "，应 >= 20）");
                return 1;
            }
            Console.WriteLine();

            // ---------- 2. 云端发现（单独跑一次，便于区分"发现"与"MQTT"的问题）----------
            Console.WriteLine("──────── 云端 REST 发现 ────────");
            string err;
            BambuDiscovery found =
                BambuCloud.Discover(token, cfg.Region, cfg.Cookie, cfg.Serial, cfg.DeviceName, out err);
            if (found == null)
            {
                Console.WriteLine("❌ 发现失败: " + err);
                return 2;
            }
            Console.WriteLine("  ✅ 区域=" + found.Region + "  API=" + found.ApiBase);
            Console.WriteLine("     MQTT 用户名=" + BambuConfig.Mask(found.Username)
                              + "（来源 " + found.UidSource + "）");
            Console.WriteLine("     设备 " + found.Devices.Count + " 台:");
            for (int i = 0; i < found.Devices.Count; i++)
            {
                BambuDevice d = found.Devices[i];
                Console.WriteLine("       [" + (i + 1) + "] " + d.DevId
                                  + "  " + d.DevName + "  " + d.ProductName
                                  + "  " + (d.Online ? "在线" : "离线")
                                  + "  打印状态=" + d.PrintStatus);
            }
            if (found.Devices.Count == 0)
            {
                Console.WriteLine("❌ 账号下没有设备");
                return 2;
            }
            Console.WriteLine();

            // ---------- 3. 用 BambuPrinter 跑真实编排 ----------
            Console.WriteLine("──────── BambuPrinter 真实编排（主程序走的就是这条）────────");
            BambuConfig runCfg = BambuConfig.Load(cfgPath);
            BambuPrinter bp = new BambuPrinter(runCfg);
            bp.OnEvent += delegate (string type, string msg)
            {
                Console.WriteLine("  [事件] " + type + ": " + msg);
            };

            if (!bp.Start())
            {
                Console.WriteLine("❌ BambuPrinter.Start() 返回 false（凭据不可用？）");
                return 1;
            }
            Console.WriteLine("  ✅ BambuPrinter 已启动，观察 " + seconds + " 秒…");

            for (int i = 0; i < seconds; i++)
            {
                Thread.Sleep(1000);
                double age = bp.State.ReportAgeMs();
                Console.WriteLine(string.Format(
                    "  [{0,3}s] mode={1,-14} mqtt={2,-4} 在线={3,-4} state={4,-8} 上报={5} 距上次={6}s",
                    i + 1, bp.State.MonitorMode,
                    bp.State.MqttConnected ? "是" : "否",
                    bp.State.PrinterOnline ? "是" : "否",
                    bp.State.StateCode, bp.State.Reports,
                    age < 0 ? "从未" : Math.Round(age / 1000.0, 1).ToString()));
                // 拿到数据且观察够 6 秒就够（持续推送不必等满整个窗口）
                if (bp.State.Reports > 0 && i >= 5) break;
            }
            Console.WriteLine();

            // ---------- 4. 归一化结果 ----------
            // 这里拿到的就是渲染层会吃的那份数据（Snapshot 每次返回新对象）
            Console.WriteLine("──────── 归一化后的 PrinterInfo（显示层真正吃的数据）────────");
            PrinterInfo p = bp.Snapshot();
            if (p == null)
            {
                Console.WriteLine("❌ Snapshot 返回 null（没有原始报文，或压平/归一化失败）");
                bp.Stop();
                return 3;
            }
            F("state", p.State);
            F("stateLabel", p.StateLabel);
            F("monitorMode", p.MonitorMode);
            F("monitorError", p.MonitorError);
            F("model", p.Model);
            F("jobName", p.JobName);
            F("percent", p.Percent.ToString(CultureInfo.InvariantCulture));
            F("layer", p.Layer + " / " + p.TotalLayer);
            F("remainingSec", p.RemainingSec.ToString(CultureInfo.InvariantCulture));
            F("eta", p.Eta);
            F("nozzleTemp", p.NozzleTemp.ToString(CultureInfo.InvariantCulture));
            F("bedTemp", p.BedTemp.ToString(CultureInfo.InvariantCulture));
            F("chamberTemp", p.ChamberTemp.ToString(CultureInfo.InvariantCulture));
            F("wifi", p.Wifi);
            F("speedLevel", p.SpeedLevel.ToString(CultureInfo.InvariantCulture));
            F("coolingFan", p.CoolingFan.ToString(CultureInfo.InvariantCulture));
            F("printError", p.PrintError.ToString(CultureInfo.InvariantCulture));
            F("hmsCount", p.HmsCount.ToString(CultureInfo.InvariantCulture));
            F("trayNow", p.TrayNow.ToString(CultureInfo.InvariantCulture));
            F("trays", p.Trays.Count + " 个");
            for (int i = 0; i < p.Trays.Count; i++)
            {
                PrinterTray t = p.Trays[i];
                Console.WriteLine("      [" + t.Index + "] " + t.Type + "  余量=" + t.Remain
                                  + "  颜色=" + (t.Color == null ? "(null)" : t.Color));
            }
            Console.WriteLine();
            Console.WriteLine("  ── 编排状态（就是 /diag 暴露的那些字段）──");
            F("bambuMode", bp.State.MonitorMode);
            F("bambuMqtt", bp.State.MqttConnected.ToString());
            F("bambuOnline", bp.State.PrinterOnline.ToString());
            F("bambuState", bp.State.StateCode);
            F("bambuRegion", bp.State.Region);
            F("bambuDevice", bp.State.DeviceName);
            F("bambuModel", bp.State.DeviceModel);
            F("bambuReports", bp.State.Reports.ToString(CultureInfo.InvariantCulture));
            F("bambuReportAgeSec", Math.Round(bp.State.ReportAgeMs() / 1000.0, 1).ToString());

            Console.WriteLine();
            Console.WriteLine("──────── 判定 ────────");
            bool ok = bp.State.Reports > 0 && p.State != "UNKNOWN" && bp.State.MqttConnected;
            Console.WriteLine(ok
                ? "✅ 取数链路正常：BambuPrinter → MQTT → 报文 → 压平 → NormalizePrinter 全部打通"
                : "⚠️ 未完全通过：reports=" + bp.State.Reports + " state=" + p.State
                  + " mqtt=" + bp.State.MqttConnected + "，请把上面内容贴给助手");
            bp.Stop();
            return ok ? 0 : 4;
        }

        private static void F(string k, string v)
        {
            Console.WriteLine("  " + k.PadRight(18) + " = " + v);
        }
    }
}
