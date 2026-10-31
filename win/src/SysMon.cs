using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace DshLcd
{
    /// <summary>
    /// Windows 本机系统监控（CPU / 内存 / 运行时长 / 主机名）。
    /// 鸿蒙版这些数据来自桥端；Windows 版直接本机采样，面板含义保持一致。
    /// </summary>
    public static class SysMon
    {
        [StructLayout(LayoutKind.Sequential)]
        private class MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;

            public MEMORYSTATUSEX()
            {
                dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME
        {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetSystemTimes(out FILETIME idleTime, out FILETIME kernelTime, out FILETIME userTime);

        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();

        private static ulong _prevIdle, _prevKernel, _prevUser;
        private static bool _havePrev;
        private static double _lastCpu;

        private static ulong ToU64(FILETIME ft)
        {
            return ((ulong)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
        }

        /// <summary>采样一次（CPU% 用两次采样的差值算，第一次返回上次的值或 0）</summary>
        /// <summary>从注册表读 CPU 标称主频（MHz）。失败返回 -1。</summary>
        private static double ReadNominalMhz()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                           @"HARDWARE\DESCRIPTION\System\CentralProcessor\0"))
                {
                    if (k != null)
                    {
                        object v = k.GetValue("~MHz");
                        if (v != null)
                        {
                            double mhz = Convert.ToDouble(v);
                            if (mhz > 0) return mhz;
                        }
                    }
                }
            }
            catch (Exception) { }
            return -1;
        }

        public static SystemInfo Sample()
        {
            SystemInfo s = new SystemInfo();

            FILETIME idle, kernel, user;
            if (GetSystemTimes(out idle, out kernel, out user))
            {
                ulong i = ToU64(idle), k = ToU64(kernel), u = ToU64(user);
                if (_havePrev)
                {
                    ulong di = i - _prevIdle;
                    ulong dk = k - _prevKernel;
                    ulong du = u - _prevUser;
                    ulong total = dk + du;                  // kernel 已含 idle
                    if (total > 0)
                    {
                        double busy = (double)(total - di);
                        double pct = busy * 100.0 / (double)total;
                        if (pct < 0) pct = 0;
                        if (pct > 100) pct = 100;
                        _lastCpu = pct;
                    }
                }
                _prevIdle = i; _prevKernel = k; _prevUser = u;
                _havePrev = true;
            }
            s.Cpu = _lastCpu;

            MEMORYSTATUSEX mem = new MEMORYSTATUSEX();
            if (GlobalMemoryStatusEx(mem))
            {
                s.MemTotal = mem.ullTotalPhys / (1024.0 * 1024.0);
                s.MemUsed = (mem.ullTotalPhys - mem.ullAvailPhys) / (1024.0 * 1024.0);
            }

            s.Cores = Environment.ProcessorCount;
            try { s.UptimeSec = GetTickCount64() / 1000.0; } catch (Exception) { s.UptimeSec = 0; }
            try { s.Host = Environment.MachineName; } catch (Exception) { s.Host = "windows"; }

            // 数字化的 CPU 四元组：面板里当"负载"显示（Windows 没有 1/5/15 分钟负载）
            s.Load1 = s.Cpu / 100.0 * s.Cores;
            s.Load5 = s.MemTotal > 0 ? (s.MemUsed / s.MemTotal) : 0;
            s.Load15 = 0;

            // CPU 温度：Windows 没有无依赖的通用读数（要 OpenHardwareMonitor 之类），
            // 保持 -1，面板会显示 "--"。
            s.CpuTemp = -1;

            // CPU 频率：从注册表 `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0\~MHz`
            // 读**标称主频**（MHz）。零依赖、不需要 WMI 服务，且注册表读取本身就很快。
            // ⚠️ 这是标称值而不是实时值 —— Windows 没有无依赖的实时频率读数；
            //    主题 7（TRCC 官方风）右卡那一行就是它。取不到保持 -1，面板显示 "--"。
            s.CpuFreqMhz = ReadNominalMhz();

            // 电量：WinForms 的 PowerStatus 就能拿到（无需额外依赖），对应鸿蒙侧的
            // batteryInfo.batterySOC / chargingStatus。台式机/虚拟机没有电池时是
            // BatteryLifePercent=255（Unknown）→ 保持 -1，面板不画这一行。
            try
            {
                System.Windows.Forms.PowerStatus ps = System.Windows.Forms.SystemInformation.PowerStatus;
                float pct = ps.BatteryLifePercent;
                if (pct >= 0f && pct <= 1f)
                {
                    s.Battery = Math.Round(pct * 100.0);
                    s.Charging = ps.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online;
                }
            }
            catch (Exception)
            {
                s.Battery = -1;
            }
            return s;
        }
    }
}
