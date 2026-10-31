using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace DshLcd
{
    /// <summary>
    /// 设备访问层（libusb 版）。
    ///
    /// ★ 为什么从 WinUSB P/Invoke 换成 libusb：
    /// 在同一台 Win11 ARM64 虚拟机 + USB 直通设备上，WinUsb_Initialize 对这块屏
    /// 稳定返回 6 (ERROR_INVALID_HANDLE)。已排除的可能：
    ///   · 设备接口 GUID —— 三个候选（GUID_DEVINTERFACE_USB_DEVICE / WINUSB /
    ///     设备自定义 DeviceInterfaceGUIDs）全部试过，都报 6
    ///   · 访问权限 —— GENERIC_WRITE 与 GENERIC_READ|GENERIC_WRITE 都试过
    ///   · 进程架构 —— 原生 ARM64 与 x64（模拟层）都试过
    ///   · 调用方 —— 另用 PowerShell Add-Type 走独立 CLR 路径，同样报 6
    ///   · 设备占用 —— trofeo_lcd.exe 优雅退出后复现
    ///   · 驱动绑定 —— 注册表确认 Service=WINUSB、CompatibleIDs 含
    ///     USB\MS_COMP_WINUSB、DeviceDesc 指向 winusb.inf
    /// 而同一台机上 trofeo_lcd.exe（内置 libusb/rusb）能正常握手推屏
    /// （其日志有 "Terhubung: Ly, PM=65 SUB=5"）。故改用 libusb。
    ///
    /// 依赖：libusb-1.0.dll 与本 exe 同目录（取 libusb 1.0.30 发行包里的
    /// VS2025/MS64/dll/libusb-1.0.dll）。不再是"单文件无依赖"，这一点已知并接受。
    ///
    /// 公开 API 与原 WinUsb 类保持一致，调用方（LcdRunner / Program / Gui）
    /// 无需任何改动。
    /// </summary>
    public static class WinUsb
    {
        // ---------- libusb P/Invoke ----------

        private const string DLL = "libusb-1.0.dll";

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int libusb_init(out IntPtr ctx);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern void libusb_exit(IntPtr ctx);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr libusb_get_device_list(IntPtr ctx, out IntPtr list);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern void libusb_free_device_list(IntPtr list, int unrefDevices);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int libusb_get_device_descriptor(IntPtr dev, out UsbDeviceDescriptor desc);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int libusb_open(IntPtr dev, out IntPtr handle);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern void libusb_close(IntPtr handle);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int libusb_claim_interface(IntPtr handle, int interfaceNumber);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int libusb_release_interface(IntPtr handle, int interfaceNumber);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int libusb_bulk_transfer(IntPtr handle, byte endpoint,
            [In, Out] byte[] data, int length, out int transferred, uint timeoutMs);

        /// <summary>libusb 的设备描述符（18 字节，紧凑排列）。</summary>
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        private struct UsbDeviceDescriptor
        {
            public byte bLength;
            public byte bDescriptorType;
            public ushort bcdUSB;
            public byte bDeviceClass;
            public byte bDeviceSubClass;
            public byte bDeviceProtocol;
            public byte bMaxPacketSize0;
            public ushort idVendor;
            public ushort idProduct;
            public ushort bcdDevice;
            public byte iManufacturer;
            public byte iProduct;
            public byte iSerialNumber;
            public byte bNumConfigurations;
        }

        private static readonly object InitLock = new object();
        private static IntPtr _ctx = IntPtr.Zero;

        private static bool EnsureInit()
        {
            lock (InitLock)
            {
                if (_ctx != IntPtr.Zero) return true;
                IntPtr ctx;
                int rc = libusb_init(out ctx);
                if (rc != 0)
                {
                    Log.Err("libusb_init 失败（返回 {0}）——libusb-1.0.dll 是否在 exe 同目录？", rc);
                    return false;
                }
                _ctx = ctx;
                return true;
            }
        }

        // ---------- 枚举 ----------

        public class DeviceRef
        {
            public string Path;
            public string HardwareId;
            public int Vid;
            public int Pid;
            /// <summary>libusb_device*（枚举期间有效，用 libusb_open 时要用）</summary>
            public IntPtr Device;
        }

        public static List<DeviceRef> Enumerate()
        {
            List<DeviceRef> list = new List<DeviceRef>();
            if (!EnsureInit()) return list;

            IntPtr raw;
            IntPtr count = libusb_get_device_list(_ctx, out raw);
            if (count == IntPtr.Zero || raw == IntPtr.Zero) return list;
            try
            {
                int n = count.ToInt32();
                for (int i = 0; i < n; i++)
                {
                    IntPtr dev = Marshal.ReadIntPtr(raw, i * IntPtr.Size);
                    if (dev == IntPtr.Zero) continue;
                    UsbDeviceDescriptor d;
                    if (libusb_get_device_descriptor(dev, out d) != 0) continue;
                    DeviceRef r = new DeviceRef();
                    r.Device = dev;
                    r.Vid = d.idVendor;
                    r.Pid = d.idProduct;
                    r.HardwareId = string.Format("USB\\VID_{0:X4}&PID_{1:X4}&REV_{2:X4}",
                        d.idVendor, d.idProduct, d.bcdDevice);
                    // libusb 不给设备路径字符串，用总线号:地址代替（只用于日志/显示）
                    int bus = libusb_get_bus_number(dev);
                    int addr = libusb_get_device_address(dev);
                    r.Path = string.Format("libusb://bus{0}.addr{1}", bus, addr);
                    list.Add(r);
                }
            }
            finally
            {
                // ★ 这里必须传 0，不能传 1。
                //   传 1 会把列表里的 libusb_device 一起解引用，而 Open() 之后还要拿
                //   DeviceRef.Device 去 libusb_open —— 那就是已释放的指针（会崩或随机失败）。
                //   传 0 表示只释放列表本身，设备对象保持有效到 libusb_exit 为止；
                //   我们的上下文是进程级的、从不 exit，所以这是安全且够用的做法。
                libusb_free_device_list(raw, 0);
            }
            return list;
        }

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int libusb_get_bus_number(IntPtr dev);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int libusb_get_device_address(IntPtr dev);

        // ---------- 设备句柄 ----------

        public class LyDevice : IDisposable
        {
            /// <summary>libusb 的 device handle 存在这里（沿用原字段名以兼容 Opened 判定）</summary>
            public IntPtr InterfaceHandle = IntPtr.Zero;
            public IntPtr FileHandle = new IntPtr(-1);
            public byte PipeOut = 0x09;
            public byte PipeIn = 0x81;
            public bool HasIn = true;
            public ushort OutMaxPacket = 512;
            public string Path = "";
            public string HardwareId = "";
            public int Vid = -1;
            public int Pid = -1;
            public int InterfaceNumber = -1;
            public int Endpoints;

            public bool Opened { get { return InterfaceHandle != IntPtr.Zero; } }

            public void Dispose()
            {
                if (InterfaceHandle != IntPtr.Zero)
                {
                    try { libusb_release_interface(InterfaceHandle, InterfaceNumber >= 0 ? InterfaceNumber : 0); }
                    catch (Exception) { }
                    try { libusb_close(InterfaceHandle); }
                    catch (Exception) { }
                    InterfaceHandle = IntPtr.Zero;
                }
            }
        }

        /// <summary>
        /// 打开指定 VID/PID 的设备：libusb_open → claim interface 0。
        ///
        /// 端点地址沿用本设备的固定值（OUT=0x09 / IN=0x81）：这两个值在鸿蒙宿主侧
        /// 由 sysfs 读到（ep_09 / ep_81），在 Windows 侧由 libusb 的
        /// windows_assign_endpoints 日志确认，两处一致。Ly.cs 本身也是绑型号的，
        /// 故这里不再走描述符遍历。
        /// </summary>
        public static LyDevice Open(int vid, int pid)
        {
            List<DeviceRef> all = Enumerate();
            DeviceRef hit = null;
            for (int i = 0; i < all.Count; i++)
            {
                DeviceRef d = all[i];
                if (d.Vid != vid) continue;
                if (pid != 0 && d.Pid != pid) continue;
                hit = d;
                break;
            }
            if (hit == null)
            {
                Log.W("没找到 VID=0x{0:X4} PID={1} 的设备（USB 设备共 {2} 个）",
                    vid, pid == 0 ? "(任意)" : string.Format("0x{0:X4}", pid), all.Count);
                return null;
            }

            LyDevice dev = new LyDevice();
            dev.Path = hit.Path;
            dev.HardwareId = hit.HardwareId;
            dev.Vid = hit.Vid;
            dev.Pid = hit.Pid;
            Log.W("打开设备：VID=0x{0:X4} PID=0x{1:X4} 硬件ID={2}", hit.Vid, hit.Pid, hit.HardwareId);
            Log.W("设备路径：{0}", hit.Path);

            IntPtr handle;
            int rc = libusb_open(hit.Device, out handle);
            if (rc != 0)
            {
                Log.Err("libusb_open 失败（返回 {0}）：{1}", rc, LibusbErrorName(rc));
                return null;
            }
            dev.InterfaceHandle = handle;

            rc = libusb_claim_interface(handle, 0);
            if (rc != 0)
            {
                Log.Err("libusb_claim_interface(0) 失败（返回 {0}）：{1}", rc, LibusbErrorName(rc));
                dev.Dispose();
                return null;
            }
            dev.InterfaceNumber = 0;
            dev.Endpoints = 2;
            Log.W("已 claim interface 0；端点 OUT=0x{0:X2} IN=0x{1:X2} 最大包={2}",
                dev.PipeOut, dev.PipeIn, dev.OutMaxPacket);
            return dev;
        }

        private static string LibusbErrorName(int rc)
        {
            switch (rc)
            {
                case -1: return "IO 错误";
                case -2: return "参数无效";
                case -3: return "拒绝访问（设备被别的进程占用，或驱动/权限不对）";
                case -4: return "设备不存在（已拔出）";
                case -5: return "找不到（驱动未绑 WinUSB）";
                case -6: return "资源忙";
                case -7: return "传输超时";
                case -8: return "溢出";
                case -9: return "管道错误";
                case -10: return "被中断";
                case -11: return "内存不足";
                case -12: return "不支持该操作";
                case -99: return "其它错误";
                default: return "未知";
            }
        }

        // ---------- 传输 ----------

        public static int Write(LyDevice dev, byte[] data, int offset, int count)
        {
            if (dev == null || !dev.Opened) return -1;
            byte[] tmp;
            if (offset == 0 && count == data.Length)
            {
                tmp = data;
            }
            else
            {
                tmp = new byte[count];
                Array.Copy(data, offset, tmp, 0, count);
            }
            int transferred;
            int rc = libusb_bulk_transfer(dev.InterfaceHandle, dev.PipeOut, tmp, tmp.Length,
                out transferred, 5000);
            if (rc != 0) return -1;
            return transferred;
        }

        public static int Read(LyDevice dev, byte[] buffer, int timeoutMs)
        {
            if (dev == null || !dev.Opened || !dev.HasIn) return -1;
            int transferred;
            int rc = libusb_bulk_transfer(dev.InterfaceHandle, dev.PipeIn, buffer, buffer.Length,
                out transferred, (uint)timeoutMs);
            if (rc != 0) return -1;
            return transferred;
        }

        // ---------- 协议动作 ----------

        /// <summary>握手：写 2048 字节，读 512 字节响应并解析</summary>
        public static DeviceInfo Handshake(LyDevice dev, int pidHint)
        {
            byte[] hs = Ly.BuildHandshake();
            int w = Write(dev, hs, 0, hs.Length);
            if (w < 0)
            {
                Log.Err("握手写入失败");
                return null;
            }
            byte[] resp = new byte[512];
            int r = Read(dev, resp, 2000);
            if (r <= 0)
            {
                Log.Err("握手没有读到响应（返回 {0}）", r);
                return null;
            }
            DeviceInfo info = Ly.ParseHandshakeResponse(resp, pidHint);
            if (info == null)
            {
                Log.Err("握手响应校验失败：[0]=0x{0:X2} [1]=0x{1:X2} [8]=0x{2:X2}（读了 {3} 字节）",
                    resp[0], resp[1], resp[8], r);
                return null;
            }
            Log.W("握手成功：{0}", info.ToString());
            return info;
        }

        /// <summary>
        /// ACK 慢帧门槛（毫秒）。厂商 C# 的 ACK 读超时是 100 ms，超了会拆掉重握手。
        /// 见 trcc-linux issue #251 的"画面冻住"排查。
        /// </summary>
        private const int AckSlowThresholdMs = 100;

        /// <summary>推一帧 JPEG：分块 → 4096 字节一次写 → 读 ACK</summary>
        public static bool PushJpeg(LyDevice dev, byte[] jpeg, int pid, out string ack)
        {
            ack = "";
            if (jpeg == null || jpeg.Length == 0)
            {
                ack = "空帧";
                return false;
            }
            if (jpeg.Length > Ly.MaxJpegSize)
            {
                ack = string.Format("JPEG 过大（{0} > {1}）", jpeg.Length, Ly.MaxJpegSize);
                return false;
            }

            byte[] stream = Ly.BuildChunkStream(jpeg, pid);
            byte[][] writes = Ly.WriteChunks(stream, pid);
            for (int i = 0; i < writes.Length; i++)
            {
                int n = Write(dev, writes[i], 0, writes[i].Length);
                if (n < 0)
                {
                    ack = string.Format("第 {0}/{1} 次写失败", i + 1, writes.Length);
                    return false;
                }
            }

            byte[] resp = new byte[512];
            int t0 = Environment.TickCount;
            int r = Read(dev, resp, 1500);
            int ackMs = Environment.TickCount - t0;
            string slow = (ackMs > AckSlowThresholdMs)
                ? string.Format("  ⚠ ACK 耗时 {0} ms，超过厂商的 {1} ms 门槛（C# 在此会重新握手）",
                                ackMs, AckSlowThresholdMs)
                : "";
            if (r > 0)
            {
                if (resp[0] == 0x03 && resp[1] == 0xFF)
                {
                    ack = string.Format("OK（{0} 字节 / {1} ms，{2} 次写）{3}", r, ackMs, writes.Length, slow);
                    return true;
                }
                ack = string.Format("响应异常 [0]=0x{0:X2} [1]=0x{1:X2}（{2} 字节 / {3} ms）",
                                    resp[0], resp[1], r, ackMs);
                return true;
            }
            // 未读到 ACK：帧很可能已被固件接受（数据是分块写进去的），但少了同步点，
            // 不当作干净的成功 —— 调用方据此可以把这帧记进异常计数。
            ack = string.Format("已写入 {0} 次，{1} ms 内未读到 ACK", writes.Length, ackMs);
            return false;
        }

        // ---------- 诊断 ----------

        /// <summary>诊断报告：不需要设备存在也能跑</summary>
        public static string ProbeReport()
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("后端：libusb");
            sb.AppendLine(string.Format("libusb 上下文：{0}", _ctx != IntPtr.Zero ? "已初始化" : "未初始化"));
            List<DeviceRef> all = Enumerate();
            sb.AppendLine(string.Format("USB 设备共 {0} 个", all.Count));
            int ours = 0;
            for (int i = 0; i < all.Count; i++)
            {
                DeviceRef d = all[i];
                bool isOurs = (d.Vid == Ly.VendorId && (d.Pid == Ly.PidLy || d.Pid == Ly.PidLy1));
                if (isOurs) ours++;
                if (isOurs || i < 12)
                {
                    sb.AppendLine(string.Format("  {0}VID=0x{1:X4} PID=0x{2:X4}  {3}",
                        isOurs ? "* " : "  ", d.Vid, d.Pid, d.HardwareId));
                    if (isOurs) sb.AppendLine(string.Format("      路径={0}", d.Path));
                }
            }
            if (ours == 0)
            {
                sb.AppendLine(string.Format("结论：没找到利民 LY 屏（VID=0x{0:X4} PID=0x{1:X4}/0x{2:X4}）",
                    Ly.VendorId, Ly.PidLy, Ly.PidLy1));
            }
            else
            {
                LyDevice dev = Open(Ly.VendorId, 0);
                if (dev == null)
                {
                    sb.AppendLine("结论：看到了设备但打开失败（详见日志；libusb 的 -12 通常表示驱动未绑 WinUSB）");
                }
                else
                {
                    sb.AppendLine("结论：设备打开成功");
                    sb.AppendLine(string.Format("  接口={0} 端点={1} OUT=0x{2:X2} IN=0x{3:X2} 最大包={4}",
                        dev.InterfaceNumber, dev.Endpoints, dev.PipeOut, dev.PipeIn, dev.OutMaxPacket));
                    dev.Dispose();
                }
            }
            string text = sb.ToString();
            Log.W("──── USB 探测 ────");
            Log.W(text.TrimEnd());
            return text;
        }
    }
}
