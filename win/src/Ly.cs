using System;

namespace DshLcd
{
    /// <summary>设备信息（握手结果）</summary>
    public class DeviceInfo
    {
        public int Pm;
        public int Sub;
        public int Fbl;
        public int Width;
        public int Height;
        public bool Rotate;
        public int RotateDeg;
        public int Pid;

        public DeviceInfo(int pm, int sub, int fbl, int w, int h, bool rotate, int rotateDeg, int pid)
        {
            Pm = pm; Sub = sub; Fbl = fbl; Width = w; Height = h;
            Rotate = rotate; RotateDeg = rotateDeg; Pid = pid;
        }

        public override string ToString()
        {
            return string.Format("PM={0} SUB={1} FBL={2} {3}x{4} rot={5}°, PID=0x{6:X4}",
                Pm, Sub, Fbl, Width, Height, RotateDeg, Pid);
        }
    }

    /// <summary>
    /// 利民 Trofeo Vision 9.16 LCD 的 "LY" Bulk 协议。
    /// 与鸿蒙版 entry/src/main/ets/usb/LyProtocol.ets 逐字节同构：
    /// 两边都由 tools/ly_reference.py 的期望值做交叉验证。
    /// </summary>
    public static class Ly
    {
        public const int ChunkSize = 512;
        public const int ChunkHeaderSize = 16;
        public const int ChunkDataSize = ChunkSize - ChunkHeaderSize;   // 496
        public const int UsbWriteSize = 4096;
        public const int HandshakeSize = 2048;
        /// <summary>
        /// 单帧 JPEG 上限。450000 有两个独立来源 + 一个硬件实测锚点：
        ///   · 厂商反编译 USBLCDNEW.dll / ImageToJpg 的 max_frame_bytes 常量 = 450000（trcc 引用）
        ///   · 同型号开源驱动 trofeo-lcd（Rust）MAX_FRAME_BYTES = 450_000
        ///   · 真机实测：~360 KB 正常显示，~570 KB 被固件忽略
        /// 旧值 650000 抄自 MacTR —— 那个项目声明了 maxJPEGSize 却从不检查它，
        /// 650 KB 落在"被忽略"区间里，属于没有依据的值。
        /// </summary>
        public const int MaxJpegSize = 450000;

        public const int PidLy = 0x5408;
        public const int PidLy1 = 0x5409;
        public const int VendorId = 0x0416;

        /// <summary>PM -&gt; FBL 覆写表（对应 trcc core/protocol.py 的 _PM_TO_FBL_OVERRIDES）</summary>
        public static int PmToFbl(int pm)
        {
            if (pm == 65 || pm == 66 || pm == 68 || pm == 69) return 192;
            if (pm == 64 || pm == 63) return 114;
            return pm;
        }

        /// <summary>
        /// 编码旋转角。1920x462 / 1920x440 / 1920x480：SUB ∈ {2,3,4} -&gt; 0°，否则 180°；
        /// 1280x480：SUB == 2 -&gt; 90°，否则 0°（本工程只处理 0/180 两种情况）。
        /// 真机实测 Trofeo Vision 9.16 为 PM=65 SUB=5，即 180°。
        /// </summary>
        public static int EncodeRotation(int w, int h, int sub)
        {
            if (w == 1920 && (h == 462 || h == 440 || h == 480 || h == 400))
            {
                return (sub == 2 || sub == 3 || sub == 4) ? 0 : 180;
            }
            if (w == 1280 && h == 480)
            {
                return sub == 2 ? 90 : 0;
            }
            return 180;
        }

        /// <summary>构造 2048 字节握手包：[0]=0x02 [1]=0xFF [8]=0x01，其余 0</summary>
        public static byte[] BuildHandshake()
        {
            byte[] buf = new byte[HandshakeSize];
            buf[0] = 0x02;
            buf[1] = 0xFF;
            buf[8] = 0x01;
            return buf;
        }

        /// <summary>
        /// 解析握手响应（512 字节）。校验 resp[0]==0x03 &amp;&amp; resp[1]==0xFF &amp;&amp; resp[8]==0x01。
        /// 不满足返回 null（调用方据此判定"设备没应答"）。
        /// </summary>
        public static DeviceInfo ParseHandshakeResponse(byte[] resp, int pid)
        {
            if (resp == null || resp.Length < 37) return null;
            if (resp[0] != 0x03 || resp[1] != 0xFF || resp[8] != 0x01) return null;

            int pm;
            int sub;
            if (pid == PidLy)
            {
                int rawPm = resp[20];
                if (rawPm <= 3) rawPm = 1;
                pm = 64 + rawPm;
                sub = resp[22] + 1;
            }
            else
            {
                // LY1：trcc 已修正为 49 + resp[20]（旧写法 50 + resp[36] 取错了回复字节）
                pm = 49 + resp[20];
                sub = resp[22];
            }

            int fbl = PmToFbl(pm);
            int w = 1920;
            int h = 462;   // 9.16 默认（9.16 尺寸见 Theme.L.Height 的说明）

            if (fbl == 192)
            {
                // FBL 192 被多个分辨率共用，需按 PM 二次消歧
                if (pm == 68) { w = 1280; h = 480; }
                else if (pm == 69)
                {
                    // PM=69 的分辨率有两个来源冲突，这里取 440：
                    //   · trcc core/protocol.py  _FBL_192_BY_PM[69] = (1920, 440)（引 C# FormCZTV.cs）
                    //   · MacTR LYProtocol.swift  fbl192ByPM[69]     = (1920, 440)
                    //   · haven80/trofeo-lcd-rs 写的是 1920x400（单一来源，未采信）
                    // 旧实现按 400 推，会被压扁/裁切 40 行。本机实测 PM=65，走不到这里，
                    // 但换设备就会踩到，故按两票一致的 440。
                    w = 1920; h = 440;
                }
                else
                {
                    // 分辨率分歧说明：电商页面写 1920x480，是宣传值；
                    // 厂商反编译（trcc）的型号/主题表只有 1920X462 / 1920X440，
                    // 同型号开源驱动 haven80/trofeo-lcd-rs 也写 "trofeo-9.16 (default, 1920x462)"。
                    // 取 462 —— 按 480 推帧会被屏裁掉/压扁 18 行。
                    w = 1920; h = 462;
                }
            }
            else if (fbl == 114) { w = 1600; h = 720; }
            else if (fbl == 128) { w = 1280; h = 480; }

            int deg = EncodeRotation(w, h, sub);
            return new DeviceInfo(pm, sub, fbl, w, h, deg != 0, deg, pid);
        }

        /// <summary>
        /// 把整帧 JPEG 打成 LY 分块流。
        /// 块头 16 字节：[0]=0x01 [1]=0xFF | LE32 总长@2 | LE16 本块数据长@6 |
        /// [8]=cmd | LE16 总块数@9 | LE16 块序号@11 | [13..15]=0
        /// LY 要求总块数补齐到 4 的倍数。
        /// </summary>
        public static byte[] BuildChunkStream(byte[] jpeg, int pid)
        {
            int total = jpeg.Length;
            int numChunks = total / ChunkDataSize + 1;
            byte cmd = (byte)(pid == PidLy ? 0x01 : 0x02);

            int paddedChunks = numChunks;
            if (pid == PidLy)
            {
                int rem = numChunks % 4;
                if (rem != 0) paddedChunks = numChunks + (4 - rem);
            }

            byte[] outBuf = new byte[paddedChunks * ChunkSize];

            for (int i = 0; i < numChunks; i++)
            {
                int off = i * ChunkSize;
                bool isLast = (i == numChunks - 1);
                int dataLen = isLast ? (total % ChunkDataSize) : ChunkDataSize;

                outBuf[off] = 0x01;
                outBuf[off + 1] = 0xFF;
                WriteLe32(outBuf, off + 2, total);
                WriteLe16(outBuf, off + 6, dataLen);
                outBuf[off + 8] = cmd;
                WriteLe16(outBuf, off + 9, numChunks);
                WriteLe16(outBuf, off + 11, i);
                // [13..15] 保持 0

                int srcOff = i * ChunkDataSize;
                Array.Copy(jpeg, srcOff, outBuf, off + ChunkHeaderSize, dataLen);
            }
            return outBuf;
        }

        /// <summary>
        /// 一帧需要分几次 USB 写：每次 4096 字节；不足 4096 时 LY 取 min(2048, 剩余)。
        /// 注意 pos 固定 +4096（沿用参考实现），LY 因补齐到 4 块倍数，
        /// 剩余必然恰好是 2048，不会丢数据。
        /// </summary>
        /// <summary>
        /// 把分块流切成若干次 USB bulk 写。
        ///
        /// ★★ 2026-10-15 修正（这是**屏幕反复重启**的根因）★★
        ///
        /// 原实现分**两遍**：第一遍按 `pos += UsbWriteSize` 数出 pieces 数量并预分配数组，
        /// 第二遍按 `pos += size` 真正填充。两个推进量**不一致**：
        /// 末段取的是 `min(2048, remaining)`（LY 的收尾包必须 ≤2048），
        /// 于是第二遍往往会比第一遍**多写一次** → `writes[idx]` 越界
        /// → `IndexOutOfRangeException`（在 Tick 里被 catch 记进 errors）。
        ///
        /// 实测命中区间：总长 % 4096 落在 (2048, 4096) 时，实际 pieces 比预估多 1。
        /// 用户机上 `jpegBytes = 114256` 正好命中（ArkTS 要 29 次，C# 只开了 28 个槽）。
        ///
        /// ArkTS 侧（usb/LyProtocol.ets 的 writeChunks）是**边算边 push** 的动态数组，
        /// 所以从来没有这个问题 —— 这也解释了为什么鸿蒙版不重启而 Windows 版重启。
        ///
        /// 现在改为**一遍完成**：用 List 边算边加，最后 ToArray。
        /// </summary>
        public static byte[][] WriteChunks(byte[] chunkStream, int pid)
        {
            int total = chunkStream.Length;
            System.Collections.Generic.List<byte[]> writes =
                new System.Collections.Generic.List<byte[]>();
            int pos = 0;
            while (pos < total)
            {
                int remaining = total - pos;
                int size;
                if (remaining >= UsbWriteSize) size = UsbWriteSize;
                else size = (pid == PidLy) ? Math.Min(2048, remaining) : remaining;

                byte[] piece = new byte[size];
                Array.Copy(chunkStream, pos, piece, 0, size);
                writes.Add(piece);
                // 按**实际发送长度**推进（不是 UsbWriteSize）—— 否则尾部 2048..4095 字节被跳过
                pos += size;
            }
            return writes.ToArray();
        }

        /// <summary>从 JPEG 字节流读宽高（SOF 标记）。失败时 w=h=0（画布自校正依赖它）。</summary>
        public static bool ParseJpegSize(byte[] data, out int width, out int height)
        {
            width = 0; height = 0;
            if (data == null || data.Length < 4) return false;
            if (data[0] != 0xFF || data[1] != 0xD8) return false;

            int i = 2;
            while (i + 9 < data.Length)
            {
                if (data[i] != 0xFF) { i++; continue; }
                int marker = data[i + 1];
                bool isSof = (marker >= 0xC0 && marker <= 0xC3) ||
                             (marker >= 0xC5 && marker <= 0xC7) ||
                             (marker >= 0xC9 && marker <= 0xCB) ||
                             (marker >= 0xCD && marker <= 0xCF);
                if (isSof)
                {
                    height = (data[i + 5] << 8) | data[i + 6];
                    width = (data[i + 7] << 8) | data[i + 8];
                    return width > 0 && height > 0;
                }
                int segLen = (data[i + 2] << 8) | data[i + 3];
                if (segLen <= 0) break;
                i += 2 + segLen;
            }
            return false;
        }

        // ---- 小端写入（不依赖 BitConverter 的字节序假设）----
        public static void WriteLe16(byte[] b, int off, int v)
        {
            b[off] = (byte)(v & 0xFF);
            b[off + 1] = (byte)((v >> 8) & 0xFF);
        }

        public static void WriteLe32(byte[] b, int off, long v)
        {
            b[off] = (byte)(v & 0xFF);
            b[off + 1] = (byte)((v >> 8) & 0xFF);
            b[off + 2] = (byte)((v >> 16) & 0xFF);
            b[off + 3] = (byte)((v >> 24) & 0xFF);
        }

        public static int ReadLe16(byte[] b, int off)
        {
            return b[off] | (b[off + 1] << 8);
        }

        public static long ReadLe32(byte[] b, int off)
        {
            return (long)b[off] | ((long)b[off + 1] << 8) | ((long)b[off + 2] << 16) | ((long)b[off + 3] << 24);
        }

        /// <summary>FNV-1a 32 位（自检用，跨语言可比）</summary>
        public static uint Fnv1a32(byte[] data)
        {
            uint h = 2166136261u;
            for (int i = 0; i < data.Length; i++)
            {
                h = h ^ data[i];
                h = h * 16777619u;
            }
            return h;
        }
    }
}
