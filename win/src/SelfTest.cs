using System;
using System.Text;

namespace DshLcd
{
    public class TestItem
    {
        public string Name;
        public bool Ok;
        public string Detail;
        public TestItem(string name, bool ok, string detail) { Name = name; Ok = ok; Detail = detail; }
    }

    /// <summary>
    /// 协议核心自检。期望值全部来自 tools/ly_reference.py（与鸿蒙版 SelfTest.ets 同源），
    /// 因此这里通过 = Windows 实现与鸿蒙实现逐字节一致。
    /// </summary>
    public static class SelfTest
    {
        // ---- 由 tools/ly_reference.py 生成的期望值 ----
        private const int KatLen = 1000;
        private const int KatFrameLen = 2048;
        private const uint KatFnv = 3811976977u;
        private const int KatChunks = 3;
        private const int KatPadded = 4;
        private const int KatSegCount = 1;
        private const int KatSegFirst = 2048;

        private const int Kat496Len = 2048;
        private const uint Kat496Fnv = 2096035961u;
        private const int Kat992Fnv = 764045713;
        private const int Kat60000Len = 63488;
        private const uint Kat60000Fnv = 3127388806u;
        private const int Kat60000Segs = 16;
        private const int KatLy1Len = 1536;
        private const uint KatLy1Fnv = 3500520126u;

        private static System.Collections.Generic.List<TestItem> _items;
        private static int _pass;
        private static int _fail;
        /// <summary>最近一次自检的总项数 / 失败数（-1 = 没跑过）。/diag 用它显示"协议自检 125/125"，
        /// 字段名与鸿蒙版 /diag 的 selfTest / selfTestAllPass 对齐。</summary>
        public static int LastTotal = -1;
        public static int LastFails = -1;
        public static string LastSummary { get { return LastTotal < 0 ? "未运行" : (LastTotal - LastFails) + "/" + LastTotal; } }

        private static void Check(string name, bool ok, string detail)
        {
            _items.Add(new TestItem(name, ok, detail));
            if (ok) _pass++; else _fail++;
            Log.W((ok ? "  [通过] " : "  [失败] ") + name + (string.IsNullOrEmpty(detail) ? "" : "  —— " + detail));
        }

        private static void Eq(string name, long actual, long expected)
        {
            Check(name, actual == expected, string.Format("实际={0} 期望={1}", actual, expected));
        }

        /// <summary>确定性伪 JPEG（与参考实现同构）</summary>
        private static byte[] KatInput(int n)
        {
            byte[] a = new byte[n];
            for (int i = 0; i < n; i++) a[i] = (byte)((i * 37 + 11) & 0xFF);
            return a;
        }

        /// <summary>最小 JPEG：FFD8 + SOF0，声明 w x h</summary>
        private static byte[] KatJpeg(int w, int h)
        {
            byte[] a = new byte[12];
            a[0] = 0xFF; a[1] = 0xD8; a[2] = 0xFF; a[3] = 0xC0;
            a[4] = 0x00; a[5] = 0x11; a[6] = 0x08;
            a[7] = (byte)((h >> 8) & 0xFF); a[8] = (byte)(h & 0xFF);
            a[9] = (byte)((w >> 8) & 0xFF); a[10] = (byte)(w & 0xFF);
            a[11] = 0x00;
            return a;
        }

        /// <summary>构造一个通过校验的握手响应</summary>
        private static byte[] KatResp(int b20, int b22, int pid)
        {
            byte[] r = new byte[512];
            r[0] = 0x03; r[1] = 0xFF; r[8] = 0x01;
            r[20] = (byte)b20;
            r[22] = (byte)b22;
            return r;
        }

        /// <summary>跑全部自检，返回失败数（0 = 全通过）</summary>
        public static int Run()
        {
            _items = new System.Collections.Generic.List<TestItem>();
            _pass = 0; _fail = 0;

            Log.W("==== LY 协议自检（Windows/C# 实现）====");

            // 1) 握手包
            byte[] hs = Ly.BuildHandshake();
            Eq("握手包长度=2048", hs.Length, Ly.HandshakeSize);
            Check("握手包 [0]=02 [1]=FF [8]=01", hs[0] == 0x02 && hs[1] == 0xFF && hs[8] == 0x01,
                string.Format("{0:X2} {1:X2} .. {2:X2}", hs[0], hs[1], hs[8]));
            bool allZero = true;
            for (int i = 0; i < hs.Length; i++)
            {
                if (i == 0 || i == 1 || i == 8) continue;
                if (hs[i] != 0) { allZero = false; break; }
            }
            Check("握手包其余字节全 0", allZero, "");

            // 2) PM -> FBL 覆写表
            Eq("pmToFbl(65)=192", Ly.PmToFbl(65), 192);
            Eq("pmToFbl(66)=192", Ly.PmToFbl(66), 192);
            Eq("pmToFbl(68)=192", Ly.PmToFbl(68), 192);
            Eq("pmToFbl(69)=192", Ly.PmToFbl(69), 192);
            Eq("pmToFbl(64)=114", Ly.PmToFbl(64), 114);
            Eq("pmToFbl(63)=114", Ly.PmToFbl(63), 114);
            Eq("pmToFbl(1)=1（表外原样返回）", Ly.PmToFbl(1), 1);
            // 帧上限 = 450000（厂商 max_frame_bytes + trofeo-lcd 的 MAX_FRAME_BYTES 两票，
            // 真机实测 ~360KB 显示 / ~570KB 被忽略）。曾误用 650000（抄自 MacTR，
            // 而那个项目声明了 maxJPEGSize 却从不检查它）。
            Eq("MaxJpegSize=450000", Ly.MaxJpegSize, 450000);
            Eq("pmToFbl(128)=128", Ly.PmToFbl(128), 128);

            // 3) 旋转规则
            Eq("1920x462 SUB=5 -> 180", Ly.EncodeRotation(1920, 462, 5), 180);
            Eq("1920x462 SUB=2 -> 0", Ly.EncodeRotation(1920, 462, 2), 0);
            Eq("1920x462 SUB=3 -> 0", Ly.EncodeRotation(1920, 462, 3), 0);
            Eq("1920x462 SUB=5 -> 180", Ly.EncodeRotation(1920, 462, 5), 180);
            Eq("1920x440 SUB=2 -> 0", Ly.EncodeRotation(1920, 440, 2), 0);
            Eq("1920x440 SUB=9 -> 180", Ly.EncodeRotation(1920, 440, 9), 180);
            Eq("1280x480 SUB=2 -> 90", Ly.EncodeRotation(1280, 480, 2), 90);
            Eq("1280x480 SUB=1 -> 0", Ly.EncodeRotation(1280, 480, 1), 0);
            Eq("1600x720 未知 -> 180", Ly.EncodeRotation(1600, 720, 1), 180);

            // 4) 握手校验必须拒绝坏响应
            Check("长度不足 -> null", Ly.ParseHandshakeResponse(new byte[10], Ly.PidLy) == null, "");
            byte[] bad0 = KatResp(1, 4, Ly.PidLy); bad0[0] = 0x02;
            Check("resp[0]!=03 -> null", Ly.ParseHandshakeResponse(bad0, Ly.PidLy) == null, "");
            byte[] bad1 = KatResp(1, 4, Ly.PidLy); bad1[1] = 0x00;
            Check("resp[1]!=FF -> null", Ly.ParseHandshakeResponse(bad1, Ly.PidLy) == null, "");
            byte[] bad8 = KatResp(1, 4, Ly.PidLy); bad8[8] = 0x00;
            Check("resp[8]!=01 -> null", Ly.ParseHandshakeResponse(bad8, Ly.PidLy) == null, "");

            // 5) 真机 9.16：resp[20]=1, resp[22]=4 -> PM=65 SUB=5
            DeviceInfo di = Ly.ParseHandshakeResponse(KatResp(1, 4, Ly.PidLy), Ly.PidLy);
            Check("真机握手解析非空", di != null, "");
            if (di != null)
            {
                Eq("真机 PM=65", di.Pm, 65);
                Eq("真机 SUB=5", di.Sub, 5);
                Eq("真机 FBL=192", di.Fbl, 192);
                Eq("真机 1920x462", di.Width * 10000 + di.Height, 1920 * 10000 + 462);
                Eq("真机 rot=180°", di.RotateDeg, 180);
                Check("真机 Rotate=true", di.Rotate, "");
            }

            // 6) PM=68 / PM=69 消歧
            DeviceInfo d68 = Ly.ParseHandshakeResponse(KatResp(4, 1, Ly.PidLy), Ly.PidLy);
            Check("PM=68 -> 1280x480", d68 != null && d68.Pm == 68 && d68.Width == 1280 && d68.Height == 480,
                d68 == null ? "null" : d68.ToString());
            DeviceInfo d69 = Ly.ParseHandshakeResponse(KatResp(5, 1, Ly.PidLy), Ly.PidLy);
            // PM=69 曾断言 1920x400（单一来源 haven80/trofeo-lcd-rs）。改为 440 —— 有**两张
            // 独立表**都写 440：trcc core/protocol.py 的 _FBL_192_BY_PM[69]（引 C# FormCZTV.cs）
            // 与 MacTR LYProtocol.swift 的 fbl192ByPM[69]。原断言等于在保护那个错误值。
            Check("PM=69 -> 1920x440（两票一致）",
                d69 != null && d69.Pm == 69 && d69.Width == 1920 && d69.Height == 440,
                d69 == null ? "null" : d69.ToString());
            DeviceInfo dlow = Ly.ParseHandshakeResponse(KatResp(0, 1, Ly.PidLy), Ly.PidLy);
            Check("rawPm<=3 记为 1 -> PM=65", dlow != null && dlow.Pm == 65, dlow == null ? "null" : dlow.ToString());

            // 7) LY1 变体：PM = 49 + resp[20]，SUB 不加 1
            DeviceInfo ly1 = Ly.ParseHandshakeResponse(KatResp(1, 1, Ly.PidLy1), Ly.PidLy1);
            Check("LY1 PM=50 SUB=1", ly1 != null && ly1.Pm == 50 && ly1.Sub == 1,
                ly1 == null ? "null" : ly1.ToString());

            // 8) 分块流：字节级一致（FNV-1a）+ 块头字段 + 补齐
            byte[] payload = KatInput(KatLen);
            byte[] frame = Ly.BuildChunkStream(payload, Ly.PidLy);
            Eq("分块流总长=2048", frame.Length, KatFrameLen);
            Eq("分块流 FNV-1a 一致", Ly.Fnv1a32(frame), KatFnv);
            Eq("块头 count 字段=3", Ly.ReadLe16(frame, 9), KatChunks);
            Eq("块头 total 字段=1000", Ly.ReadLe32(frame, 2), KatLen);
            Check("第0块头两字节=01 FF", frame[0] == 0x01 && frame[1] == 0xFF, string.Format("{0:X2} {1:X2}", frame[0], frame[1]));
            Eq("第0块数据长=496", Ly.ReadLe16(frame, 6), 496);
            Eq("第0块 cmd=01", frame[8], 1);
            Eq("第0块序号=0", Ly.ReadLe16(frame, 11), 0);
            Eq("第0块 13..15 为 0", frame[13] + frame[14] + frame[15], 0);
            int lastOff = 2 * Ly.ChunkSize;
            Eq("尾块数据长=8", Ly.ReadLe16(frame, lastOff + 6), 8);
            Eq("尾块序号=2", Ly.ReadLe16(frame, lastOff + 11), 2);
            Eq("补齐后总块数=4", frame.Length / Ly.ChunkSize, KatPadded);
            bool padZero = true;
            for (int k = 3 * Ly.ChunkSize; k < frame.Length; k++)
            {
                if (frame[k] != 0) { padZero = false; break; }
            }
            Check("补齐块全 0", padZero, "");

            // 9) 载荷可原样取回
            byte[] back = new byte[KatLen];
            Array.Copy(frame, Ly.ChunkHeaderSize, back, 0, 496);
            Array.Copy(frame, Ly.ChunkSize + Ly.ChunkHeaderSize, back, 496, 496);
            Array.Copy(frame, lastOff + Ly.ChunkHeaderSize, back, 992, 8);
            bool same = true;
            for (int i = 0; i < KatLen; i++) { if (back[i] != payload[i]) { same = false; break; } }
            Check("分块后载荷逐字节可还原", same, "");

            // 10) 边界：正好 496 -> 2 块（尾块数据长 0）
            byte[] f496 = Ly.BuildChunkStream(KatInput(496), Ly.PidLy);
            Eq("496 字节 -> 总长 2048", f496.Length, Kat496Len);
            Eq("496 字节 FNV 一致", Ly.Fnv1a32(f496), Kat496Fnv);
            Eq("496 字节块数字段=2", Ly.ReadLe16(f496, 9), 2);
            Eq("496 字节尾块数据长=0", Ly.ReadLe16(f496, Ly.ChunkSize + 6), 0);
            Eq("992 字节 FNV 一致", Ly.Fnv1a32(Ly.BuildChunkStream(KatInput(992), Ly.PidLy)), (uint)Kat992Fnv);

            // 11) LY1：cmd=02 且不补齐
            byte[] fLy1 = Ly.BuildChunkStream(KatInput(KatLen), Ly.PidLy1);
            Eq("LY1 总长=1536（不补齐）", fLy1.Length, KatLy1Len);
            Eq("LY1 FNV 一致", Ly.Fnv1a32(fLy1), KatLy1Fnv);
            Eq("LY1 cmd=02", fLy1[8], 2);

            // 12) 写分段：4096 一次，尾包 min(2048, 剩余)
            byte[][] segs = Ly.WriteChunks(frame, Ly.PidLy);
            Eq("分段数=1", segs.Length, KatSegCount);
            Eq("首段长度=2048", segs[0].Length, KatSegFirst);

            byte[] big = Ly.BuildChunkStream(KatInput(60000), Ly.PidLy);
            Eq("60000 字节总长=63488", big.Length, Kat60000Len);
            Eq("60000 字节 FNV 一致", Ly.Fnv1a32(big), Kat60000Fnv);
            byte[][] bigSegs = Ly.WriteChunks(big, Ly.PidLy);
            Eq("60000 字节分段数=16", bigSegs.Length, Kat60000Segs);
            int sumSeg = 0;
            bool segShape = true;
            for (int i = 0; i < bigSegs.Length; i++)
            {
                sumSeg += bigSegs[i].Length;
                bool ok = (i < bigSegs.Length - 1) ? bigSegs[i].Length == 4096 : bigSegs[i].Length == 2048;
                if (!ok) segShape = false;
            }
            Check("分段形状：前 15 段 4096 + 尾段 2048", segShape, "");
            Eq("分段总字节=63488（不丢数据）", sumSeg, Kat60000Len);

            // 13) LY1 的尾包不强制 2048
            byte[][] ly1Segs = Ly.WriteChunks(fLy1, Ly.PidLy1);
            Eq("LY1 分段数=1", ly1Segs.Length, 1);
            Eq("LY1 分段长度=1536", ly1Segs[0].Length, 1536);

            // 14) JPEG 尺寸解析
            int w0, h0;
            Check("最小 SOF0 解析 1920x480", Ly.ParseJpegSize(KatJpeg(1920, 480), out w0, out h0) && w0 == 1920 && h0 == 480,
                string.Format("{0}x{1}", w0, h0));
            int w1, h1;
            Check("非 JPEG 数据 -> false", !Ly.ParseJpegSize(new byte[] { 1, 2, 3 }, out w1, out h1), "");
            Check("空数据 -> false", !Ly.ParseJpegSize(new byte[0], out w1, out h1), "");
            Check("null -> false", !Ly.ParseJpegSize(null, out w1, out h1), "");
            int w2, h2;
            Check("1280x480 解析正确", Ly.ParseJpegSize(KatJpeg(1280, 480), out w2, out h2) && w2 == 1280 && h2 == 480,
                string.Format("{0}x{1}", w2, h2));

            // 15) 调度策略（夜间窗口 / 自适应帧率 / USB 退避）
            Schedule.RunTests(
                delegate(string name, bool ok, string detail) { Check(name, ok, detail); },
                delegate(string name, long a, long e) { Eq(name, a, e); });

            // 16) JSON 解析
            JsonValue jv = JsonValue.Parse("{\"a\":1,\"b\":\"2\",\"c\":[true,null,\"x\"],\"d\":{\"e\":-3.5}}");
            Check("JSON 解析对象", jv != null && jv.IsObj, "");
            Eq("JSON 数字", (long)State.Num(jv == null ? null : jv.Get("a"), -1), 1);
            Eq("JSON 字符串数字可转", (long)State.Num(jv == null ? null : jv.Get("b"), -1), 2);
            Eq("JSON 数组长度", jv == null ? -1 : jv.Get("c").Count, 3);
            Check("JSON 嵌套布尔/空值", jv != null && jv.Get("c").At(0).IsBool && jv.Get("c").At(0).B && jv.Get("c").At(1).IsNull, "");
            Eq("JSON 嵌套数字（含负小数）", (long)State.Num(jv == null ? null : jv.Get("d").Get("e"), 0), -3);
            Check("坏 JSON 返回 null", JsonValue.Parse("{oops") == null, "");
            Check("空串返回 null", JsonValue.Parse("") == null, "");
            JsonValue round = JsonValue.Parse("{\"n\":\"中文\\n\"}");
            Check("转义与中文往返", round != null && round.Get("n").S == "中文\n", round == null ? "" : round.Get("n").S);

            // 17) 遥测归一化（类型不可信时的收敛行为）
            State st = new State();
            Check("垃圾输入不抛异常", st.ApplyText("not json") == false, "");
            Check("字符串数字被收敛", st.ApplyText("{\"system\":{\"cpu\":\"52.5\",\"cores\":\"8\",\"memUsed\":\"100\"}}"), "");
            Eq("cpu 收敛为 52.5", (long)(st.Data.System.Cpu * 10), 525);
            Eq("cores 收敛为 8", (long)st.Data.System.Cores, 8);
            Check("越界钳制 cpu<=100", new State().ApplyText("{\"system\":{\"cpu\":999}}") &&
                new State().ApplyText("{\"system\":{\"cpu\":-5}}"), "");
            State s2 = new State();
            s2.ApplyText("{\"system\":{\"cpu\":999}}");
            Eq("cpu>100 被钳到 100", (long)s2.Data.System.Cpu, 100);
            State s3 = new State();
            s3.ApplyText("{\"system\":{\"cpu\":-5}}");
            Eq("cpu<0 被钳到 0", (long)s3.Data.System.Cpu, 0);
            // 电量：-1 表示"没有电池"，越界要钳到 -1..100（不是 0）；charging 是布尔
            State b1 = new State();
            b1.ApplyText("{\"system\":{\"battery\":150,\"charging\":true}}");
            Eq("电量>100 钳到 100", (long)b1.Data.System.Battery, 100);
            Check("charging 解析为 true", b1.Data.System.Charging, "");
            State b2 = new State();
            b2.ApplyText("{\"system\":{\"battery\":-5}}");
            Eq("电量越负钳到 -1（保留「无电池」语义）", (long)b2.Data.System.Battery, -1);
            State b3 = new State();
            b3.ApplyText("{\"system\":{\"cpu\":1}}");
            Eq("没有 battery 字段时为 -1", (long)b3.Data.System.Battery, -1);
            // 合并规则：桥端新鲜也补本机电量；桥端自己有电量则以桥端为准
            SystemInfo local = new SystemInfo(); local.Battery = 88; local.Charging = true; local.Cpu = 1;
            SystemInfo bridge = new SystemInfo(); bridge.Cpu = 10; bridge.Battery = -1;
            SystemInfo merged = State.PickSystem(bridge, true, local);
            Check("桥端新鲜时补本机电量（且保留桥端 cpu）",
                merged != null && merged.Battery == 88 && merged.Charging && merged.Cpu == 10,
                merged == null ? "null" : ("cpu=" + merged.Cpu + " 电量=" + merged.Battery));
            SystemInfo bridge2 = new SystemInfo(); bridge2.Cpu = 10; bridge2.Battery = 42;
            SystemInfo merged2 = State.PickSystem(bridge2, true, local);
            Eq("桥端自己有电量就以桥端为准", (long)merged2.Battery, 42);
            SystemInfo merged3 = State.PickSystem(null, false, local);
            Eq("桥端不新鲜时用本机整份数据", (long)merged3.Battery, 88);

            State s4 = new State();
            s4.ApplyText("{\"tokens\":{\"todayInput\":\"abc\",\"todayOutput\":null,\"todayTotal\":\"100\"}}");
            Eq("无法解析的数字回退 0", (long)s4.Data.Tokens.TodayInput, 0);
            Eq("todayTotal 显式给出就用它", (long)s4.Data.Tokens.TodayTotal, 100);
            State s5 = new State();
            s5.ApplyText("{\"tokens\":{\"todayInput\":10,\"todayOutput\":5}}");
            Eq("缺 todayTotal 时用输入+输出", (long)s5.Data.Tokens.TodayTotal, 15);
            State s6 = new State();
            s6.ApplyText("{\"todos\":[{\"content\":\"做A\",\"status\":\"in_progress\"},{\"content\":\"做B\",\"status\":\"乱写\"},{\"status\":\"pending\"},null]}");
            Eq("todos 过滤掉无 content 的项", s6.Data.Todos.Count, 2);
            Check("非法 status 归为 pending", s6.Data.Todos.Count == 2 && s6.Data.Todos[1].Status == "pending",
                s6.Data.Todos.Count == 2 ? s6.Data.Todos[1].Status : "数量不对");
            State s7 = new State();
            s7.ApplyText("{\"todos\":\"不是数组\"}");
            Eq("todos 非数组 -> 空表", s7.Data.Todos.Count, 0);
            State s8 = new State();
            s8.ApplyText("{\"agent\":{\"state\":\"乱写\",\"activity\":42},\"weather\":{\"text\":\"\"}}");
            Check("非法 state 归为 unknown", s8.Data.Agent.State == "unknown", s8.Data.Agent.State);
            Check("activity 类型不对用默认", s8.Data.Agent.Activity == "空闲", s8.Data.Agent.Activity);
            Check("空天气视为没有天气", s8.Data.Weather == null, "");
            State s9 = new State();
            Check("整包替换语义：后一包丢字段就回默认",
                s9.ApplyText("{\"agent\":{\"state\":\"busy\"}}") && s9.Data.Agent.State == "busy" &&
                s9.ApplyText("{}") && s9.Data.Agent == null, "");

            // 18) 打印机（拓竹）归一化 —— 与鸿蒙版 SelfTest.ets 的对应用例同构
            PrinterInfo pr1 = State.NormalizePrinter(JsonValue.Parse(
                "{\"state\":\"RUNNING\",\"stateLabel\":\"打印中\",\"connected\":true,\"online\":true,"
                + "\"jobName\":\"benchy.gcode\",\"percent\":42,\"layer\":120,\"totalLayer\":300,"
                + "\"remainingSec\":3720,\"eta\":\"14:35\",\"nozzleTemp\":219.6,\"nozzleTarget\":220,"
                + "\"bedTemp\":60,\"bedTarget\":60,\"chamberTemp\":34,\"coolingFan\":80,\"speedLevel\":2,"
                + "\"trayNow\":1,\"trays\":[{\"index\":1,\"type\":\"PLA\",\"color\":\"FF0000FF\",\"remain\":80},"
                + "{\"index\":2,\"type\":\"PETG\",\"color\":\"#00FF00\",\"remain\":55}]}"));
            Check("打印机(完整包)", pr1 != null && pr1.State == "RUNNING" && pr1.Percent == 42
                && pr1.Layer == 120 && pr1.TotalLayer == 300 && pr1.NozzleTemp == 220
                && pr1.Trays.Count == 2 && pr1.Trays[0].Color == "#FF0000" && pr1.Trays[1].Color == "#00FF00",
                pr1 == null ? "null" : string.Format("state={0} pct={1} 喷嘴={2} 色={3}/{4}",
                    pr1.State, pr1.Percent, pr1.NozzleTemp, pr1.Trays[0].Color, pr1.Trays[1].Color));

            PrinterInfo pr2 = State.NormalizePrinter(JsonValue.Parse(
                "{\"state\":\"weird\",\"percent\":\"abc\",\"layer\":\"-5\",\"nozzleTemp\":999,"
                + "\"bedTemp\":-3,\"coolingFan\":250,\"speedLevel\":99,\"hms\":\"notarray\"}"));
            Check("打印机(类型不可信)", pr2 != null && pr2.State == "UNKNOWN" && pr2.StateLabel == "未知"
                && pr2.Percent == -1 && pr2.Layer == 0 && pr2.NozzleTemp == 400 && pr2.BedTemp == -1
                && pr2.CoolingFan == 100 && pr2.SpeedLevel == 4 && pr2.HmsCount == 0,
                pr2 == null ? "null" : string.Format("state={0} 层={1} 喷嘴={2} 风扇={3}",
                    pr2.State, pr2.Layer, pr2.NozzleTemp, pr2.CoolingFan));

            System.Text.StringBuilder many = new System.Text.StringBuilder("[");
            for (int i = 0; i < 12; i++)
            {
                if (i > 0) many.Append(",");
                many.Append("{\"index\":").Append(i + 1).Append(",\"type\":\"PLA\",\"remain\":").Append(i * 5).Append("}");
            }
            many.Append(",{\"index\":99,\"type\":\"Empty\",\"remain\":0}]");
            PrinterInfo pr3 = State.NormalizePrinter(JsonValue.Parse("{\"state\":\"IDLE\",\"trays\":" + many.ToString() + "}"));
            Eq("打印机(托盘上限=8 且过滤空槽)", pr3 == null ? -1 : pr3.Trays.Count, State.MaxTrays);

            PrinterInfo pr4 = State.NormalizePrinter(JsonValue.Parse(
                "{\"state\":\"FAILED\",\"printError\":83951617,\"hms\":[{\"code\":\"0300_0100_0001_0001\"},{\"code\":\"x\"}]}"));
            Check("打印机(HMS 条数/短码/32 位错误码)", pr4 != null && pr4.HmsCount == 2
                && pr4.HmsCode == "0300_0100_0001_0001" && pr4.PrintError == 83951617,
                pr4 == null ? "null" : string.Format("hms={0} code={1} err={2}", pr4.HmsCount, pr4.HmsCode, pr4.PrintError));

            // 注意：NormalizePrinter 收到"对象"就一定返回结果（与 ArkTS 同语义），
            // "有没有打印机"要看遥测里这个键在不在 —— 缺失/null 才算没有
            Check("打印机(无数据 -> null)", State.NormalizePrinter(null) == null
                && State.NormalizeTelemetry(JsonValue.Parse("{\"printer\":null}")).Printer == null
                && State.NormalizeTelemetry(JsonValue.Parse("{\"system\":{}}")).Printer == null, "");
            Check("打印机(主入口接线)", State.NormalizeTelemetry(JsonValue.Parse("{\"printer\":{\"percent\":7}}")).Printer != null
                && State.NormalizeTelemetry(JsonValue.Parse("{\"printer\":{\"percent\":7}}")).Printer.Percent == 7, "");

            LastTotal = _pass + _fail;
            LastFails = _fail;
            Log.W(string.Format("==== 自检结果：通过 {0} / 共 {1}，失败 {2} ====", _pass, LastTotal, _fail));
            return _fail;
        }
    }
}
