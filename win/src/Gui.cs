using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace DshLcd
{
    // =====================================================================
    //  与鸿蒙版一致的视觉令牌（照抄 entry/src/main/ets/common/Theme.ets 的 C 类）
    // =====================================================================
    /// <summary>
    /// 明确指向 WinForms 的 ComboBox。
    /// ★ 本文件里 `Gui.cs` 自带一批自绘控件（Card/Switch/FlatButton/CircleButton），
    ///   裸写 `ComboBox` 在风格上容易让人误以为也是自绘控件 —— 用别名把意图写清楚。
    /// </summary>
    using ComboBox = System.Windows.Forms.ComboBox;

    public static class G
    {
        public static readonly Color BgTop = Color.FromArgb(10, 12, 20);       // #0A0C14
        public static readonly Color BgBot = Color.FromArgb(16, 18, 28);       // #10121C
        public static readonly Color Panel = Color.FromArgb(20, 23, 34);       // #141722
        public static readonly Color PanelHi = Color.FromArgb(26, 30, 44);     // #1A1E2C
        public static readonly Color Border = Color.FromArgb(38, 42, 58);      // #262A3A
        public static readonly Color TextW = Color.FromArgb(230, 235, 245);    // #E6EBF5
        public static readonly Color TextS = Color.FromArgb(140, 148, 168);    // #8C94A8
        public static readonly Color TextL = Color.FromArgb(100, 108, 130);    // #646C82
        public static readonly Color TextD = Color.FromArgb(70, 76, 95);       // #464C5F
        public static readonly Color Blue = Color.FromArgb(66, 133, 244);
        public static readonly Color Green = Color.FromArgb(52, 211, 153);
        public static readonly Color Orange = Color.FromArgb(251, 191, 36);
        public static readonly Color Red = Color.FromArgb(239, 68, 68);
        public static readonly Color Cyan = Color.FromArgb(34, 211, 238);
        public static readonly Color DeepSeek = Color.FromArgb(77, 107, 254);
        public static readonly Color BarBg = Color.FromArgb(30, 34, 48);

        public static Font YaHei(float px, bool bold)
        {
            return new Font("Microsoft YaHei", px, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
        }

        public static Font Mono(float px, bool bold)
        {
            return new Font("Consolas", px, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
        }

        public static GraphicsPath Round(double x, double y, double w, double h, double r)
        {
            GraphicsPath p = new GraphicsPath();
            if (r * 2 > w) r = w / 2;
            if (r * 2 > h) r = h / 2;
            float d = (float)(r * 2);
            p.AddArc((float)x, (float)y, d, d, 180, 90);
            p.AddArc((float)(x + w - d), (float)y, d, d, 270, 90);
            p.AddArc((float)(x + w - d), (float)(y + h - d), d, d, 0, 90);
            p.AddArc((float)x, (float)(y + h - d), d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    /// <summary>深色卡片：圆角底 + 1px 边框 + 左侧强调条 + 标题（与仪表盘面板同一套语言）</summary>
    public class Card : Panel
    {
        public string Title = "";
        public Color Accent = G.Cyan;
        public bool ShowTitle = true;

        public Card()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            BackColor = G.Panel;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            try { PaintSelf(e); }
            catch (Exception) { /* 自绘失败不应该崩掉整个界面 */ }
        }

        private void PaintSelf(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(G.BgBot);
            using (GraphicsPath p = G.Round(0, 0, Width - 1, Height - 1, 14))
            {
                using (SolidBrush b = new SolidBrush(G.Panel)) g.FillPath(b, p);
                using (Pen pen = new Pen(G.Border)) g.DrawPath(pen, p);
            }
            if (!ShowTitle) return;
            using (GraphicsPath p = G.Round(18, 18, 4, 20, 2))
            using (SolidBrush b = new SolidBrush(Accent)) g.FillPath(b, p);
            using (Font f = G.YaHei(15, true))
            using (SolidBrush b = new SolidBrush(Accent))
            {
                g.DrawString(Title, f, b, 30, 17);
            }
            using (Pen pen = new Pen(G.Border))
            {
                g.DrawLine(pen, 18, 48, Width - 18, 48);
            }
        }
    }

    /// <summary>圆形按钮（鸿蒙版预览两侧的 ◀ ▶ 就是圆形）：到边界时自动变暗</summary>
    public class CircleButton : Button
    {
        public bool Dim;

        public CircleButton()
        {
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            BackColor = G.PanelHi;
            ForeColor = G.TextW;
            Font = G.YaHei(17, false);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            try { PaintSelf(e); }
            catch (Exception) { /* 自绘失败不应该崩掉整个界面 */ }
        }

        private void PaintSelf(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Parent == null ? G.Panel : Parent.BackColor);
            Color bg = Dim ? G.BarBg : (ClientRectangle.Contains(PointToClient(Cursor.Position)) ? G.DeepSeek : G.PanelHi);
            using (GraphicsPath p = G.Round(1, 1, Width - 2, Height - 2, (Width - 2) / 2.0))
            {
                using (SolidBrush b = new SolidBrush(bg)) g.FillPath(b, p);
                using (Pen pen = new Pen(Dim ? G.Border : G.DeepSeek)) g.DrawPath(pen, p);
            }
            using (Font f = G.YaHei(16, true))
            using (SolidBrush b = new SolidBrush(Dim ? G.TextL : G.TextW))
            {
                SizeF sz = g.MeasureString(Text, f);
                g.DrawString(Text, f, b, (Width - sz.Width) / 2f, (Height - sz.Height) / 2f);
            }
        }
    }

    /// <summary>开关（对齐鸿蒙版的 Toggle Switch）：44×24 轨道 + 圆钮</summary>
    public class Switch : Control
    {
        private bool _on;
        public event EventHandler Toggled;

        public Switch()
        {
            Size = new Size(46, 26);
            Cursor = Cursors.Hand;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        public bool On
        {
            get { return _on; }
            set { _on = value; Invalidate(); }
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            _on = !_on;
            Invalidate();
            EventHandler h = Toggled;
            if (h != null) h(this, EventArgs.Empty);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            try { PaintSelf(e); }
            catch (Exception) { /* 自绘失败不应该崩掉整个界面 */ }
        }

        private void PaintSelf(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Parent == null ? G.Panel : Parent.BackColor);
            using (GraphicsPath p = G.Round(1, 3, Width - 2, Height - 6, (Height - 6) / 2.0))
            {
                using (SolidBrush b = new SolidBrush(_on ? G.DeepSeek : G.BarBg)) g.FillPath(b, p);
                using (Pen pen = new Pen(_on ? G.DeepSeek : G.Border)) g.DrawPath(pen, p);
            }
            int d = Height - 10;
            double kx = _on ? (Width - d - 5) : 5;
            using (SolidBrush b = new SolidBrush(_on ? Color.White : G.TextS))
            {
                g.FillEllipse(b, (float)kx, 5, d, d);
            }
        }
    }

    /// <summary>扁平按钮（深色面板风）</summary>
    public class FlatButton : Button
    {
        public bool Primary;

        public FlatButton()
        {
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 1;
            Height = 32;
            Font = G.YaHei(13.5f, false);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            try { PaintSelf(e); }
            catch (Exception) { /* 自绘失败不应该崩掉整个界面 */ }
        }

        private void PaintSelf(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Parent == null ? G.Panel : Parent.BackColor);
            bool hover = ClientRectangle.Contains(PointToClient(Cursor.Position));
            Color bg = Primary ? G.DeepSeek : (hover ? G.PanelHi : G.BarBg);
            Color bd = Primary ? G.DeepSeek : G.Border;
            using (GraphicsPath p = G.Round(0, 0, Width - 1, Height - 1, 8))
            {
                using (SolidBrush b = new SolidBrush(bg)) g.FillPath(b, p);
                using (Pen pen = new Pen(bd)) g.DrawPath(pen, p);
            }
            // 注意：这里绝不能写 using (Font f = Font) —— 那会把控件共享的 Font 释放掉，
            // 第一帧正常、第二帧 MeasureString 就抛"参数无效"（实测弹崩溃框）
            Font f = Font;
            using (SolidBrush b = new SolidBrush(Enabled ? G.TextW : G.TextD))
            {
                SizeF sz = g.MeasureString(Text, f);
                g.DrawString(Text, f, b, (Width - sz.Width) / 2f, (Height - sz.Height) / 2f);
            }
        }
    }

    /// <summary>深色滑块（TrackBar 太难换配色，自己画一个）</summary>
    public class DarkSlider : Control
    {
        public int Min = 0;
        public int Max = 100;
        public int Value = 0;
        public event EventHandler ValueChanged;

        private bool _drag;

        public DarkSlider()
        {
            Height = 26;
            Cursor = Cursors.Hand;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        private void FromMouse(int x)
        {
            double k = (x - 8) / (double)Math.Max(1, Width - 16);
            if (k < 0) k = 0;
            if (k > 1) k = 1;
            int v = Min + (int)Math.Round(k * (Max - Min));
            if (v != Value)
            {
                Value = v;
                Invalidate();
                EventHandler h = ValueChanged;
                if (h != null) h(this, EventArgs.Empty);
            }
        }

        protected override void OnMouseDown(MouseEventArgs e) { _drag = true; FromMouse(e.X); }
        protected override void OnMouseMove(MouseEventArgs e) { if (_drag) FromMouse(e.X); }
        protected override void OnMouseUp(MouseEventArgs e) { _drag = false; }

        protected override void OnPaint(PaintEventArgs e)
        {
            try { PaintSelf(e); }
            catch (Exception) { /* 自绘失败不应该崩掉整个界面 */ }
        }

        private void PaintSelf(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Parent == null ? G.Panel : Parent.BackColor);
            double k = Max > Min ? (Value - Min) / (double)(Max - Min) : 0;
            using (GraphicsPath p = G.Round(8, Height / 2.0 - 3, Width - 16, 6, 3))
            {
                using (SolidBrush b = new SolidBrush(G.BarBg)) g.FillPath(b, p);
                using (GraphicsPath p2 = G.Round(8, Height / 2.0 - 3, Math.Max(6, (Width - 16) * k), 6, 3))
                using (SolidBrush b = new SolidBrush(G.DeepSeek)) g.FillPath(b, p2);
            }
            double kx = 8 + (Width - 16) * k;
            using (SolidBrush b = new SolidBrush(G.TextW)) g.FillEllipse(b, (float)(kx - 7), Height / 2f - 7, 14, 14);
        }
    }

    /// <summary>
    /// dshlcd 的 Windows 控制台界面 —— 按鸿蒙版 App 的版式重做：
    ///   顶部：标题 + 运行状态徽章
    ///   预览：固定高度框（缩放只改画面、不动下方布局）+ 左右圆形 ◀ ▶ + 缩放滑块 + 适应 + 平移滑块
    ///   控制：启动/停止、连接屏幕、断开、网页预览、打开日志
    ///   显示：竖屏布局 / 夜间熄屏 / 旋转180° 三个开关
    ///   状态：两列键值（USB、设备、端点、JPEG、FPS、已推、错误、数据桥…）
    ///   打印机：拓竹状态摘要
    ///   日志：实时滚动
    /// </summary>
    public class GuiForm : Form
    {
        private readonly LcdRunner _r;
        private readonly Settings _cfg;

        private Card _cPrev, _cCtrl, _cVm, _cDisp, _cStat, _cPrinter, _cLog;
        private TextBox _vmUrl;
        private FlatButton _bVmApply, _bVmClear, _bVmProbe;
        private Label _vmStat;
        private Panel _prevHost;
        private PictureBox _pic;
        private CircleButton _bLeft, _bRight;
        private FlatButton _bFit, _bRun, _bUsb, _bDisc, _bWeb, _bLogOpen;
        private DarkSlider _zoom, _pan, _panY;
        private Label _panHint;
        /// <summary>实际客户区尺寸（对齐 ArkTS 的 `EntryAbility.curW/curH`，供 /diag 排障）</summary>
        public static int WinW;
        public static int WinH;

        private Tuple<Switch, Label> _swVert, _swNight, _swRot;
        // ---- 主题与版面（对齐鸿蒙版 Index.ets 的主题按钮组）----
        private Label _lbTheme, _lbPrinterCell, _lbBg, _lbThemeNote;
        /// <summary>
        /// 16 档主题的**直接点按按钮**（对齐鸿蒙版 Index.ets 的 themeRow：
        /// 一排可点的胶囊，选中那个用绿色高亮）。
        ///
        /// ★ 2026-10-15 改：原来是"‹ 上一档 / 名称 / › 下一档"的循环切换 ——
        ///   用户反馈"主题切换不够直观，要像鸿蒙那样直接点按"。
        ///   16 个按钮排成 4×4，点哪档立刻切哪档。
        /// </summary>
        private FlatButton[] _btnTheme = new FlatButton[16];
        /// <summary>按钮上的短标签（与鸿蒙版 Button 文案对齐；长名截短以便 4 列排下）</summary>
        private static readonly string[] ThemeShort = new string[]
        {
            "仪表盘", "诊断终端", "监控墙", "分屏页",
            "打砖块", "Dotii", "固件仿真", "官方浅色",
            "MacTR", "机位Dotii", "赛博二次元", "二次元壁纸",
            "无框二次元", "明亮HUD", "NanoMuse", "trofeo-lcd"
        };
        private ComboBox _cbPrinterCell, _cbBg;
        private Tuple<Switch, Label> _swBurst;
        private Label _labTitle, _labSub, _badgeRun, _badgeUsb, _zoomVal;
        private Label _hint;
        private TextBox _log;
        private readonly List<Label> _kvKeys = new List<Label>();
        private readonly List<Label> _kvVals = new List<Label>();
        private readonly string[] _kvNames = new string[]
        { "屏幕(USB)", "设备", "端点", "JPEG", "帧率", "已推 / 错误", "数据桥", "布局", "画质", "耗时", "网页端口" };
        private Timer _timer;
        private int _lastJpegLen = -1;
        private int _panPct = 500;    // 0=最左 500=居中 1000=最右
        private int _panYPct = 500;   // 0=最上 500=居中 1000=最下
        private bool _autoFit = true;
        private double _zoomK = 1.0;

        private const int Pad = 14;
        private const int RightW = 420;

        public GuiForm(LcdRunner runner)
        {
            _r = runner;
            _cfg = runner.Config;

            Text = "dshlcd — 利民 Trofeo Vision 9.16 LCD 控制台";
            ClientSize = new Size(1240, 900);
            // ★ 2026-10-15 修：原来 1060x700 太小 —— 左列在这尺寸下总需求约 872px
            //   （即使把预览框压到最小），日志卡会被切掉。实测几何下限约 900px。
            // ★ 2026-10-15 修：宽度也要够 —— 显示卡里 16 个主题按钮排成 4×4，
            //   最右到 24 + 3*156 + 150 = **642px**。而左列宽 = W - Pad - RightW - Pad*2
            //   = W - 476，所以窗口宽必须 ≥ **1118px**（取 1120 留 2px 余量）。
            //   原来的 1060 → 左列仅 598px，**第三、四列按钮会被切掉 44px**。
            MinimumSize = new Size(1120, 900);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = G.BgBot;
            ForeColor = G.TextW;

            Build();
            _vmUrl.Text = _cfg.VmUrl == null ? "" : _cfg.VmUrl;
            Log.Sink = AppendLog;
            LayoutAll();
            // 启动时按当前主题高亮对应按钮（对齐鸿蒙版：选中的胶囊是绿底）
            RefreshThemeButtons();
            // 从网页/接口改主题时，界面按钮也跟着更新
            runner.ThemeChanged += delegate { RefreshThemeButtons(); };

            _timer = new Timer();
            _timer.Interval = 300;
            _timer.Tick += delegate(object s, EventArgs e) { Refresh1(); };
            _timer.Start();

            Resize += delegate { LayoutAll(); };
            FormClosing += delegate(object s, FormClosingEventArgs e)
            {
                Log.Sink = null;
                _timer.Stop();
                _r.Stop();
            };
        }

        // ---------------- 建控件 ----------------

        private void Build()
        {
            // 顶部标题与徽章直接画在窗体上（不进卡片，和鸿蒙版一致）
            _labTitle = MkLabel("利民 Trofeo Vision 9.16 LCD", G.YaHei(19, true), G.TextW);
            _labSub = MkLabel("dshlcd " + Program.Version + " · Windows 控制台（同一份引擎，界面与鸿蒙版对齐）", G.YaHei(12, false), G.TextL);
            _badgeRun = MkLabel("已停止", G.YaHei(13, true), G.TextS);
            _badgeUsb = MkLabel("屏幕未连接", G.YaHei(13, true), G.TextS);

            _cPrev = MkCard("预览", G.Cyan);
            _prevHost = new Panel();
            _prevHost.BackColor = Color.FromArgb(5, 7, 12);
            // 不用 AutoScroll：平移全靠手动定位。
            // 之前 AutoScroll=true 又同时手动设负 Location = 双重偏移，左边/上边会到不了。
            _prevHost.AutoScroll = false;
            _prevHost.BorderStyle = BorderStyle.FixedSingle;
            _cPrev.Controls.Add(_prevHost);

            _pic = new PictureBox();
            _pic.SizeMode = PictureBoxSizeMode.StretchImage;
            _pic.Location = new Point(0, 0);
            _pic.Size = new Size(640, 160);
            _pic.MouseWheel += delegate(object s, MouseEventArgs e)
            {
                int v = _zoom.Value + (e.Delta > 0 ? 10 : -10);
                if (v < _zoom.Min) v = _zoom.Min;
                if (v > _zoom.Max) v = _zoom.Max;
                _zoom.Value = v;
                _autoFit = false;
                ApplyZoom();
            };
            _pic.DoubleClick += delegate { _autoFit = true; ApplyZoom(); };
            _prevHost.Controls.Add(_pic);

            _bLeft = MkCircle("◀");
            _bLeft.Click += delegate { PanBy(-1); };
            _bRight = MkCircle("▶");
            _bRight.Click += delegate { PanBy(1); };
            _cPrev.Controls.Add(_bLeft);
            _cPrev.Controls.Add(_bRight);

            Label lz = MkLabel("预览缩放", G.YaHei(13, false), G.TextS);
            _zoom = new DarkSlider();
            _zoom.Min = 30; _zoom.Max = 300; _zoom.Value = 100;
            _zoom.ValueChanged += delegate { _autoFit = false; ApplyZoom(); };
            _zoomVal = MkLabel("100%", G.Mono(13, false), G.TextW);
            _bFit = MkButton("适应", false, 56);
            _bFit.Click += delegate
            {
                _autoFit = true;
                ApplyZoom();
            };
            Label lp = MkLabel("平移", G.YaHei(13, false), G.TextS);
            _pan = new DarkSlider();
            _pan.Min = 0; _pan.Max = 1000; _pan.Value = 500;
            _pan.ValueChanged += delegate
            {
                _panPct = _pan.Value;
                ApplyZoom();
            };
            _cPrev.Controls.Add(lz);
            _cPrev.Controls.Add(_zoom);
            _cPrev.Controls.Add(_zoomVal);
            _cPrev.Controls.Add(_bFit);
            _cPrev.Controls.Add(lp);
            _cPrev.Controls.Add(_pan);

            Label lp2 = MkLabel("上下", G.YaHei(13, false), G.TextS);
            _cPrev.Controls.Add(lp2);
            _panHint = MkLabel("放大后可左右/上下移动", G.YaHei(11, false), G.TextD);
            _cPrev.Controls.Add(_panHint);
            _panY = new DarkSlider();
            _panY.Min = 0; _panY.Max = 1000; _panY.Value = 500;
            _panY.ValueChanged += delegate
            {
                _panYPct = _panY.Value;
                ApplyZoom();
            };
            _cPrev.Controls.Add(_panY);

            _cCtrl = MkCard("控制", G.Blue);
            _bRun = MkButton("停止", true, 92);
            _bRun.Click += delegate
            {
                if (_bRun.Text == "停止")
                {
                    _r.Config.NoUsb = true;
                    _bRun.Text = "启动";
                    Log.W("已停止推屏（仍在预览渲染）");
                }
                else
                {
                    _r.Config.NoUsb = false;
                    _r.ArmUsbRetry();
                    _bRun.Text = "停止";
                    Log.W("已恢复推屏");
                }
                _r.Config.NoUsb = (_bRun.Text == "启动");
            };
            _bUsb = MkButton("连接屏幕", false, 92);
            _bUsb.Click += delegate { _r.ArmUsbRetry(); };
            _bDisc = MkButton("断开屏幕", false, 92);
            _bDisc.Click += delegate { _r.CloseUsbNow(); };
            _bWeb = MkButton("网页预览", false, 92);
            _bWeb.Click += delegate
            {
                try { System.Diagnostics.Process.Start("http://127.0.0.1:" + _cfg.HttpPort + "/"); }
                catch (Exception ex) { Log.Err("打不开浏览器：{0}", ex.Message); }
            };
            _bLogOpen = MkButton("打开日志", false, 92);
            _bLogOpen.Click += delegate
            {
                try { System.Diagnostics.Process.Start(Log.Path); }
                catch (Exception ex) { Log.Err("打不开日志：{0}", ex.Message); }
            };
            _cCtrl.Controls.Add(_bRun);
            _cCtrl.Controls.Add(_bUsb);
            _cCtrl.Controls.Add(_bDisc);
            _cCtrl.Controls.Add(_bWeb);
            _cCtrl.Controls.Add(_bLogOpen);

            // VM 监视地址：换环境（livepad 换机器/换端口）时在这里改，改完立刻生效并写回 ini
            _cVm = MkCard("VM 监视", G.Cyan);
            Label vmL = MkLabel("地址（可填多个，逗号分隔；点自动探测找 livepad）", G.YaHei(12, false), G.TextL);
            _cVm.Controls.Add(vmL);
            _vmStat = MkLabel("—", G.YaHei(12, false), G.TextL);
            _vmUrl = new TextBox();
            _vmUrl.Font = G.Mono(12.5f, false);
            _vmUrl.BackColor = Color.FromArgb(9, 12, 20);
            _vmUrl.ForeColor = G.TextW;
            _vmUrl.BorderStyle = BorderStyle.FixedSingle;
            _bVmApply = MkButton("应用并连接", true, 104);
            _bVmApply.Click += delegate
            {
                string url = _vmUrl.Text.Trim();
                _r.SetVmUrl(url);
                Program.SaveIniValue("vm-url", url);
                // 把补全后的完整地址回填，用户一眼能看到"IP/vm"被解析成了什么
                System.Collections.Generic.List<string> parsed = VmProbe.ParseList(url);
                if (parsed.Count > 0)
                {
                    _vmUrl.Text = url;   // 保留用户输入（可读性好）
                    _vmStat.Text = "已连接：" + string.Join("  |  ", parsed.ToArray());
                    _vmStat.ForeColor = G.TextS;
                }
                Log.W("VM 监视地址已生效：{0}", url.Length == 0 ? "(已清空)" : url);
            };
            _bVmProbe = MkButton("自动探测", false, 88);
            _bVmProbe.Click += delegate
            {
                _bVmProbe.Enabled = false;
                _vmStat.Text = "探测中…（先试候选，再扫本网段 8787，最多十几秒）";
                _vmStat.ForeColor = G.TextS;
                System.Threading.Thread th = new System.Threading.Thread(delegate()
                {
                    try
                    {
                        List<string> cands = VmProbe.ParseList(_vmUrl.Text);
                        cands.AddRange(VmProbe.DefaultCandidates(VmProbe.DefaultPort));
                        string report;
                        string hit = VmProbe.Probe(cands, true, out report);
                        Log.W(report);
                        BeginInvoke((MethodInvoker)delegate()
                        {
                            _bVmProbe.Enabled = true;
                            if (hit == null)
                            {
                                _vmStat.Text = "没找到 livepad：确认它在这台机器/本网段上跑着，或手填地址";
                                _vmStat.ForeColor = G.Red;
                            }
                            else
                            {
                                _vmUrl.Text = hit;
                                _r.SetVmUrl(hit);
                                Program.SaveIniValue("vm-url", hit);
                                _vmStat.Text = "已连接：" + hit + "（已写入 ini）";
                                _vmStat.ForeColor = G.Green;
                            }
                        });
                    }
                    catch (Exception ex)
                    {
                        Log.Err("探测失败：{0}", ex.Message);
                        BeginInvoke((MethodInvoker)delegate() { _bVmProbe.Enabled = true; });
                    }
                });
                th.IsBackground = true;
                th.Start();
            };
            _bVmClear = MkButton("清空", false, 56);
            _bVmClear.Click += delegate
            {
                _vmUrl.Text = "";
                _r.SetVmUrl("");
                Program.SaveIniValue("vm-url", "");
            };
            _vmStat = MkLabel("—", G.YaHei(12, false), G.TextL);
            _cVm.Controls.Add(_vmUrl);
            _cVm.Controls.Add(_bVmProbe);
            _cVm.Controls.Add(_bVmApply);
            _cVm.Controls.Add(_bVmClear);
            _cVm.Controls.Add(_vmStat);

            _cDisp = MkCard("显示", G.Orange);
            _swVert = MkSwitch("竖屏布局", delegate(bool on)
            {
                _cfg.Vertical = on;
                Log.W("竖屏布局 = {0}", on ? "开" : "关");
            });
            _swNight = MkSwitch("夜间熄屏", delegate(bool on)
            {
                _cfg.NightEnabled = on;
                Log.W("夜间熄屏 = {0}（18:30-09:00 降到 3 秒一帧）", on ? "开" : "关");
            });
            _swRot = MkSwitch("旋转180°", delegate(bool on)
            {
                _cfg.Rotate180 = on;
                _cfg.Rotate180Forced = true;
                Log.W("旋转180° = {0}（已锁定，不被握手结果覆盖）", on ? "开" : "关");
            });
            // ---- 主题切换（16 档）：16 个**直接可点**的按钮，排成 4×4 ----
            // 对齐鸿蒙版 Index.ets 的 themeRow：点哪档就切哪档，选中那个高亮。
            // ★ 原来这里是"‹ 上一档 / 名称 / › 下一档"的循环切换，用户反馈不够直观。
            for (int ti = 0; ti < Themes.Count && ti < _btnTheme.Length; ti++)
            {
                int idx = ti;                      // 闭包捕获（C# 5 里 for 变量需另存）
                FlatButton b = MkButton(ThemeShort[ti], false, 150);
                b.Height = 24;
                b.Click += delegate { ApplyTheme(idx); };
                _btnTheme[ti] = b;
            }
            _lbTheme = MkLabel(ThemeLabel(), G.YaHei(13, true), G.Cyan);
            _lbThemeNote = MkLabel("点按钮直接切换 · 说明见 docs/主题总表.md", G.YaHei(11, false), G.TextL);

            // ---- 打印机格档位（主题 0 下生效）----
            _lbPrinterCell = MkLabel("打印机格", G.YaHei(12, false), G.TextS);
            _cbPrinterCell = MkCombo(220);
            _cbPrinterCell.Items.AddRange(new object[] { "printer（标准）", "v6（定稿版面）", "v4（13:29 版）", "dotii（对调）" });
            _cbPrinterCell.SelectedIndex = PrinterCellIndex(_cfg.PrinterCell);
            _cbPrinterCell.SelectedIndexChanged += delegate
            {
                string v = PrinterCellValue(_cbPrinterCell.SelectedIndex);
                _cfg.PrinterCell = v;
                Program.SaveIniValue("printer-cell", v);
                Log.W("打印机格 = {0}", v);
            };

            // ---- 程序化背景 ----
            _lbBg = MkLabel("背景", G.YaHei(12, false), G.TextS);
            _cbBg = MkCombo(220);
            _cbBg.Items.AddRange(new object[] { "无", "plasma", "aurora", "lava", "waves", "图片（bg_sample.jpg）" });
            _cbBg.SelectedIndex = (int)Backdrop.Current;
            _cbBg.SelectedIndexChanged += delegate
            {
                Backdrop.Current = (Backdrop.Style)_cbBg.SelectedIndex;
                Program.SaveIniValue("bg-style", Backdrop.StyleNames[(int)Backdrop.Current]);
                Log.W("背景 = {0}", Backdrop.StyleNames[(int)Backdrop.Current]);
            };

            // ---- 极速模式（对齐 ArkTS 的 burst）----
            _swBurst = MkSwitch("极速模式", delegate(bool on)
            {
                _cfg.Burst = on;
                // ★ 必须存盘：不然改完重启就丢（`BuildSettings` 已经在读 burst，
                //   只存不读或只读不存都是"改了不生效/不保留"的典型成因）
                Program.SaveIniValue("burst", on ? "1" : "0");
                Log.W("极速模式 = {0}（帧间隔扣除本帧耗时）", on ? "开" : "关");
            });

            _cDisp.Controls.Add(_swVert.Item1);
            _cDisp.Controls.Add(_swNight.Item1);
            _cDisp.Controls.Add(_swRot.Item1);
            _cDisp.Controls.Add(_swVert.Item2);
            _cDisp.Controls.Add(_swNight.Item2);
            _cDisp.Controls.Add(_swRot.Item2);
            for (int ti = 0; ti < _btnTheme.Length; ti++)
            {
                if (_btnTheme[ti] != null) _cDisp.Controls.Add(_btnTheme[ti]);
            }
            _cDisp.Controls.Add(_lbTheme);
            _cDisp.Controls.Add(_lbThemeNote);
            _cDisp.Controls.Add(_lbPrinterCell);
            _cDisp.Controls.Add(_cbPrinterCell);
            _cDisp.Controls.Add(_lbBg);
            _cDisp.Controls.Add(_cbBg);
            _cDisp.Controls.Add(_swBurst.Item1);
            _cDisp.Controls.Add(_swBurst.Item2);

            _cStat = MkCard("状态", G.Green);
            for (int i = 0; i < _kvNames.Length; i++)
            {
                Label k = MkLabel(_kvNames[i], G.YaHei(13, false), G.TextS);
                Label v = MkLabel("—", G.Mono(13, false), G.TextW);
                v.TextAlign = ContentAlignment.MiddleRight;
                _kvKeys.Add(k);
                _kvVals.Add(v);
                _cStat.Controls.Add(k);
                _cStat.Controls.Add(v);
            }

            _cPrinter = MkCard("打印机（拓竹）", G.Orange);
            _hint = MkLabel("—", G.YaHei(13, false), G.TextS);
            _cPrinter.Controls.Add(_hint);

            _cLog = MkCard("日志", G.TextL);
            _log = new TextBox();
            _log.Multiline = true;
            _log.ScrollBars = ScrollBars.Vertical;
            _log.ReadOnly = true;
            _log.BorderStyle = BorderStyle.None;
            _log.BackColor = Color.FromArgb(9, 12, 20);
            _log.ForeColor = Color.FromArgb(150, 200, 190);
            _log.Font = G.Mono(12, false);
            _log.WordWrap = false;
            _cLog.Controls.Add(_log);
        }

        /// <summary>下拉框（与 _vmUrl 同配色，避免出现一块亮白洞）</summary>
        private ComboBox MkCombo(int w)
        {
            ComboBox cb = new ComboBox();
            cb.DropDownStyle = ComboBoxStyle.DropDownList;
            cb.Font = G.YaHei(12, false);
            cb.BackColor = Color.FromArgb(9, 12, 20);
            cb.ForeColor = G.TextW;
            cb.FlatStyle = FlatStyle.Flat;
            cb.Width = w;
            return cb;
        }

        /// <summary>
        /// 切到指定主题（16 档，直接点按）。
        /// 落盘 + 刷新按钮高亮与名称标签，行为对齐鸿蒙版 `themeApply()`。
        /// </summary>
        private void ApplyTheme(int t)
        {
            if (t < 0 || t >= Themes.Count) return;
            _cfg.Theme = t;
            Program.SaveIniValue("theme", t.ToString());
            RefreshThemeButtons();
            Log.W("主题 = {0}（{1}）", t, Themes.Name(t));
        }

        /// <summary>
        /// 按当前主题刷新 16 个按钮的高亮：选中那个用主色（Primary），其余用普通样式。
        /// 对齐鸿蒙版 —— 选中的胶囊是绿底，其余是深灰底。
        /// </summary>
        private void RefreshThemeButtons()
        {
            for (int i = 0; i < _btnTheme.Length; i++)
            {
                FlatButton b = _btnTheme[i];
                if (b == null) continue;
                bool on = (i == _cfg.Theme);
                if (b.Primary != on)
                {
                    b.Primary = on;
                    b.Invalidate();          // 自绘控件，改样式后要重画
                }
            }
            if (_lbTheme != null) _lbTheme.Text = ThemeLabel();
        }

        private string ThemeLabel()
        {
            return "当前：" + _cfg.Theme.ToString() + " · " + Themes.Name(_cfg.Theme);
        }

        /// <summary>打印机格档位 → 下拉索引（对齐 _cbPrinterCell 的 Items 顺序）</summary>
        private static int PrinterCellIndex(string v)
        {
            if (v == "v6") return 1;
            if (v == "v4") return 2;
            if (v == "dotii") return 3;
            return 0;
        }

        /// <summary>下拉索引 → 打印机格档位</summary>
        private static string PrinterCellValue(int idx)
        {
            if (idx == 1) return "v6";
            if (idx == 2) return "v4";
            if (idx == 3) return "dotii";
            return "printer";
        }

        private Label MkLabel(string text, Font f, Color c)
        {
            Label l = new Label();
            l.Text = text;
            l.Font = f;
            l.ForeColor = c;
            l.BackColor = Color.Transparent;
            l.AutoSize = true;
            Controls.Add(l);
            return l;
        }

        private Card MkCard(string title, Color accent)
        {
            Card c = new Card();
            c.Title = title;
            c.Accent = accent;
            Controls.Add(c);
            return c;
        }

        private FlatButton MkButton(string text, bool primary, int w)
        {
            FlatButton b = new FlatButton();
            b.Text = text;
            b.Primary = primary;
            b.Width = w;
            return b;
        }

        private CircleButton MkCircle(string text)
        {
            CircleButton b = new CircleButton();
            b.Text = text;
            b.Size = new Size(46, 46);
            return b;
        }

        /// <summary>开关 + 右侧文字标签（返回两者）</summary>
        private Tuple<Switch, Label> MkSwitch(string text, Action<bool> onToggle)
        {
            Switch s = new Switch();
            s.Toggled += delegate { onToggle(s.On); };
            Label l = new Label();
            l.Text = text;
            l.Font = G.YaHei(13.5f, false);
            l.ForeColor = G.TextS;
            l.BackColor = Color.Transparent;
            l.AutoSize = true;
            return new Tuple<Switch, Label>(s, l);
        }

        // ---------------- 布局（照鸿蒙版的比例：预览框固定高度，缩放不改下方布局）----------------

        private void LayoutAll()
        {
            int W = ClientSize.Width, H = ClientSize.Height;
            // 记录实际客户区尺寸（对齐 ArkTS EntryAbility.curW/curH）：
            // 用户把窗口拉大/缩小后，面板是按新尺寸重排的 —— 排障时第一件要看的就是这个。
            WinW = W;
            WinH = H;
            int rightX = W - Pad - RightW;
            int leftW = rightX - Pad * 2;

            _labTitle.Location = new Point(Pad + 6, Pad);
            _labSub.Location = new Point(Pad + 8, Pad + 30);
            _badgeRun.Location = new Point(W - Pad - 150, Pad + 4);
            _badgeUsb.Location = new Point(W - Pad - 150, Pad + 26);

            int y = Pad + 56;
            // ★ 2026-10-15 修：预览框高度改成"**剩下的空间给日志卡**"，而不是只跟窗口高成正比。
            //
            //   原来是 `prevH = max(220, (H-470)*0.62)`，复算后发现左列总需求达 1086px，
            //   而默认窗口只有 800px 高 —— 于是日志卡被挤到窗口外（`logH` 直接被
            //   `Math.Max(90, ...)` 兜成 90，位置却在 y≈980，**整块看不见**）。
            //   显示卡从 156 加到 308 让这个老问题更严重了。
            //
            //   现在：先算出下面那几个卡占多少，剩下的留给"预览卡 + 日志卡"，
            //   日志卡至少 90px，预览卡在 140~260 之间自适应。
            const int CTRL_H = 92, VM_H = 120, DISP_H = 308, LOG_MIN = 90;
            int below = CTRL_H + VM_H + DISP_H;                    // 下面三个固定高度的卡
            int room = H - (Pad + 56) - below - Pad * 4 - LOG_MIN; // 留给预览卡的高度
            int prevH = room - 116;                                 // 卡高 = 预览框 + 116 的控件区
            // ⚠️ 这里**不能给 prevH 设硬下限**：room 是"算出来剩多少"，硬撑下限会把
            //    日志卡重新顶出窗口（第一版就是这么写错的，复算当场发现）。
            //    只软钳上限，避免超宽屏时预览框高得离谱。
            if (prevH > 300) prevH = 300;
            if (prevH < 20) prevH = 20;                             // 仅防负数，不保可用性
            _cPrev.SetBounds(Pad, y, leftW, prevH + 116);
            int innerW = leftW - 28;
            _prevHost.SetBounds(62, 58, innerW - 116, prevH);
            _bLeft.Location = new Point(12, 58 + (prevH - 46) / 2);
            _bRight.Location = new Point(leftW - 12 - 46, 58 + (prevH - 46) / 2);
            int cy = 58 + prevH + 18;
            Label lz = FindLabel(_cPrev, "预览缩放");
            if (lz != null) lz.Location = new Point(20, cy - 8);
            _zoom.SetBounds(96, cy - 14, 240, 26);
            _zoomVal.Location = new Point(344, cy - 8);
            _bFit.SetBounds(396, cy - 16, 56, 30);
            Label lp = FindLabel(_cPrev, "平移");
            if (lp != null) lp.Location = new Point(472, cy - 8);
            _pan.SetBounds(520, cy - 14, Math.Max(80, leftW - 700), 26);
            Label lp2b = FindLabel(_cPrev, "上下");
            if (lp2b != null) lp2b.Location = new Point(520 + Math.Max(80, leftW - 700) + 12, cy - 8);
            _panY.SetBounds(520 + Math.Max(80, leftW - 700) + 46, cy - 14, 150, 26);
            if (_panHint != null) _panHint.Location = new Point(520 + Math.Max(80, leftW - 700) + 206, cy - 4);
            _bLeft.Parent = _cPrev; _bRight.Parent = _cPrev;

            y = _cPrev.Bottom + Pad;
            _cCtrl.SetBounds(Pad, y, leftW, 92);
            int bx = 18;
            _bRun.Location = new Point(bx, 40); bx += _bRun.Width + 10;
            _bUsb.Location = new Point(bx, 40); bx += _bUsb.Width + 10;
            _bDisc.Location = new Point(bx, 40); bx += _bDisc.Width + 10;
            _bWeb.Location = new Point(bx, 40); bx += _bWeb.Width + 10;
            _bLogOpen.Location = new Point(bx, 40);

            y = _cCtrl.Bottom + Pad;
            _cVm.SetBounds(Pad, y, leftW, 120);
            Label vl = FindLabel(_cVm, "地址（可填多个，逗号分隔；点自动探测找 livepad）");
            if (vl != null) vl.Location = new Point(20, 52);
            int urlW = Math.Max(160, leftW - 20 - 8 - 104 - 6 - 84 - 6 - 56 - 18);
            _vmUrl.SetBounds(20, 72, urlW, 26);
            _bVmApply.SetBounds(_vmUrl.Right + 8, 69, 104, 31);
            _bVmProbe.SetBounds(_bVmApply.Right + 6, 69, 84, 31);
            _bVmClear.SetBounds(_bVmProbe.Right + 6, 69, 56, 31);
            _vmStat.SetBounds(20, 104, leftW - 40, 20);

            y = _cVm.Bottom + Pad;
            _cDisp.SetBounds(Pad, y, leftW, DISP_H);   // 与上面算 room 用的常量保持同一份
            _swVert.Item1.Location = new Point(24, 44);
            _swVert.Item2.Location = new Point(80, 48);
            _swNight.Item1.Location = new Point(leftW / 3 + 10, 44);
            _swNight.Item2.Location = new Point(leftW / 3 + 66, 48);
            _swRot.Item1.Location = new Point(leftW * 2 / 3, 44);
            _swRot.Item2.Location = new Point(leftW * 2 / 3 + 56, 48);

            // ---- 16 档主题：4×4 直接点按按钮（对齐鸿蒙版的胶囊按钮行）----
            _lbTheme.Location = new Point(24, 84);
            _lbThemeNote.Location = new Point(24 + _lbTheme.PreferredWidth + 10, 86);
            const int TILE_W = 150, TILE_H = 24, TILE_DX = 156, TILE_DY = 30;
            for (int ti = 0; ti < _btnTheme.Length; ti++)
            {
                if (_btnTheme[ti] == null) continue;
                _btnTheme[ti].SetBounds(24 + (ti % 4) * TILE_DX, 108 + (ti / 4) * TILE_DY,
                                        TILE_W, TILE_H);
            }

            // ---- 打印机格 + 背景（主题按钮下面一行）----
            _lbPrinterCell.Location = new Point(24, 244);
            _cbPrinterCell.SetBounds(92, 238, 150, 26);
            _lbBg.Location = new Point(258, 244);
            _cbBg.SetBounds(300, 238, 150, 26);
            // ---- 极速模式 ----
            _swBurst.Item1.Location = new Point(24, 274);
            _swBurst.Item2.Location = new Point(80, 278);

            y = _cDisp.Bottom + Pad;
            int logH = Math.Max(90, H - y - Pad);
            _cLog.SetBounds(Pad, y, leftW, logH);
            _log.SetBounds(16, 58, leftW - 32, logH - 74);

            // 右列
            int statH = 13 * 30 + 62;
            _cStat.SetBounds(rightX, Pad + 56, RightW, statH);
            for (int i = 0; i < _kvKeys.Count; i++)
            {
                int ry = 58 + i * 30;
                _kvKeys[i].Location = new Point(20, ry);
                _kvVals[i].SetBounds(RightW - 190, ry - 2, 170, 24);
            }
            y = _cStat.Bottom + Pad;
            _cPrinter.SetBounds(rightX, y, RightW, 172);
            _hint.SetBounds(20, 58, RightW - 40, 104);
        }

        private static Label FindLabel(Control parent, string text)
        {
            foreach (Control c in parent.Controls)
            {
                Label l = c as Label;
                if (l != null && l.Text == text) return l;
            }
            return null;
        }

        // ---------------- 画面 ----------------

        /// <summary>缩放后把画面复位到居中（0..1000 的 500），再让用户自己拨</summary>
        private void CenterPan()
        {
            _panPct = 500; _panYPct = 500;
            if (_pan.Value != 500) _pan.Value = 500;
            if (_panY != null && _panY.Value != 500) _panY.Value = 500;
        }

        private void PanBy(int dir)
        {
            _pan.Value = Math.Max(_pan.Min, Math.Min(_pan.Max, _pan.Value + dir * 8));
            _panPct = _pan.Value;
            ApplyZoom();
        }

        private void ApplyZoom()
        {
            if (_pic.Image == null) return;
            int iw = _pic.Image.Width, ih = _pic.Image.Height;
            int availW = _prevHost.ClientSize.Width - 4;
            int availH = _prevHost.ClientSize.Height - 4;
            if (availW < 20 || availH < 20) return;

            if (_autoFit)
            {
                double k = Math.Min(availW / (double)iw, availH / (double)ih);
                _zoomK = k;
                int v = (int)Math.Round(k * 100);
                if (v < _zoom.Min) v = _zoom.Min;
                if (v > _zoom.Max) v = _zoom.Max;
                _zoom.Value = v;
            }
            else
            {
                _zoomK = _zoom.Value / 100.0;
            }
            int dw = (int)Math.Round(iw * _zoomK);
            int dh = (int)Math.Round(ih * _zoomK);
            _pic.Size = new Size(dw, dh);



            _bLeft.Dim = _panPct <= 0;
            _bRight.Dim = _panPct >= 1000;
            _bLeft.Invalidate();
            _bRight.Invalidate();
            _zoomVal.Text = (int)Math.Round(_zoomK * 100) + "%";
        }

        // ---------------- 刷新 ----------------

        private void Refresh1()
        {
            byte[] jpg = _r.GetJpeg();
            if (jpg != null && jpg.Length != _lastJpegLen)
            {
                try
                {
                    using (MemoryStream ms = new MemoryStream(jpg))
                    {
                        Image old = _pic.Image;
                        _pic.Image = new Bitmap(ms);
                        if (old != null) old.Dispose();
                    }
                    _lastJpegLen = jpg.Length;
                    ApplyZoom();
                }
                catch (Exception) { }
            }

            // 徽章
            _badgeRun.Text = _r.UsbOpen ? "运行中" : "预览中";
            _badgeRun.ForeColor = _r.UsbOpen ? G.Green : G.TextS;
            _badgeUsb.Text = _r.UsbOpen ? "屏幕已连接" : "屏幕未连接";
            _badgeUsb.ForeColor = _r.UsbOpen ? G.Green : G.TextL;

            // 两列状态
            string[] vals = new string[]
            {
                _r.UsbOpen ? "已连接" : "未连接",
                _r.Info == null ? "—" : _r.Info.ToString(),
                _r.UsbOpen ? "BULK OUT 0x" + (_r.Info == null ? "?" : _r.Info.Pid.ToString("X4")) : "—",
                (jpg == null ? 0 : jpg.Length) + " B  " + (jpg == null ? "" : _r.Config.MaxWidth + "x" + _r.Config.MaxHeight),
                _r.Frames == 0 ? "0.0" : (_r.Frames / Math.Max(1.0, (State.NowMs() - _startMs) / 1000.0)).ToString("0.0"),
                _r.Sent + " / " + _r.Errors,
                _r.Telemetry.Fresh ? "正常 " + _r.Telemetry.AgeSec().ToString("0") + "s" : "无数据",
                _cfg.Vertical ? "竖屏 462x1920" : "横屏 1920x462",
                _r.Quality.ToString("0.00"),
                _r.RenderMs.ToString("0.0") + " / " + _r.EncodeMs.ToString("0.0") + " / " + _r.PushMs.ToString("0.0") + " ms",
                _cfg.HttpPort + (_r.HttpRunning ? "" : "（占用）"),
            };
            for (int i = 0; i < _kvVals.Count && i < vals.Length; i++)
            {
                if (_kvVals[i].Text != vals[i]) _kvVals[i].Text = vals[i];
                _kvVals[i].ForeColor = (i == 5 && _r.Errors > 0) ? G.Red
                    : (i == 0 || i == 6) ? (_r.UsbOpen || _r.Telemetry.Fresh ? G.Green : G.TextL) : G.TextW;
            }

            // 开关状态回读（可能被 /set 或 ini 改过）
            if (_swVert.Item1.On != _cfg.Vertical) _swVert.Item1.On = _cfg.Vertical;
            if (_swNight.Item1.On != _cfg.NightEnabled) _swNight.Item1.On = _cfg.NightEnabled;
            if (_swRot.Item1.On != _cfg.Rotate180) _swRot.Item1.On = _cfg.Rotate180;

            // VM 监视摘要
            string vm = _r.VmSummary;
            if (_vmStat.Text != vm)
            {
                _vmStat.Text = vm + (string.IsNullOrEmpty(_cfg.VmUrl) ? "" : "   ▸ " + _cfg.VmUrl);
                bool bad = vm.StartsWith("抓不到");
                _vmStat.ForeColor = _cfg.VmUrl == null || _cfg.VmUrl.Length == 0 ? G.TextL : (bad ? G.Red : G.Green);
            }

            // 打印机
            PrinterInfo p = _r.Telemetry.Data.Printer;
            if (p == null)
            {
                _hint.Text = "未接入 —— 桥端加 --printer http://127.0.0.1:8790/api/state 即可显示。";
                _hint.ForeColor = G.TextL;
                _cPrinter.Accent = G.TextL;
            }
            else
            {
                StringBuilder sb = new StringBuilder();
                sb.Append("状态：" + (p.StateLabel ?? p.State));
                if (p.Model != null && p.Model.Length > 0) sb.Append("    机型：" + p.Model);
                sb.Append("\r\n");
                if (p.Percent >= 0) sb.Append("进度：" + p.Percent + "%    层：" + (p.Layer >= 0 ? p.Layer + "/" + p.TotalLayer : "—"));
                if (p.RemainingSec >= 0) sb.Append("    剩余：" + (p.RemainingSec / 60) + " 分");
                sb.Append("\r\n");
                if (p.NozzleTemp >= 0) sb.Append("喷嘴 " + p.NozzleTemp + "°→" + p.NozzleTarget + "°    热床 " + p.BedTemp + "°→" + p.BedTarget + "°");
                if (p.ChamberTemp >= 0) sb.Append("    腔温 " + p.ChamberTemp + "°");
                if (p.HmsCount > 0) sb.Append("\r\n⚠ HMS 告警 " + p.HmsCount + " 条" + (p.HmsCode.Length > 0 ? "：" + p.HmsCode : ""));
                else if (p.PrintError > 0) sb.Append("\r\n⚠ 打印错误码 " + p.PrintError);
                else if (p.JobName != null && p.JobName.Length > 0) sb.Append("\r\n工件：" + p.JobName);
                _hint.Text = sb.ToString();
                bool bad = p.HmsCount > 0 || p.State == "FAILED" || p.State == "STUCK";
                _hint.ForeColor = bad ? G.Red : (p.State == "RUNNING" ? G.Green : G.TextS);
                _cPrinter.Accent = bad ? G.Red : (p.State == "RUNNING" ? G.Green : G.Orange);
            }
            _cPrinter.Invalidate();
        }

        private long _startMs = State.NowMs();

        private void AppendLog(string line)
        {
            try
            {
                if (_log == null || _log.IsDisposed) return;
                if (_log.InvokeRequired) { _log.BeginInvoke((MethodInvoker)delegate() { AppendLog(line); }); return; }
                if (_log.Lines.Length > 500) _log.Clear();
                _log.AppendText(line + "\r\n");
            }
            catch (Exception) { }
        }

        /// <summary>无人值守截图（自动化验证用：没有眼睛时确认界面真的画出来了）</summary>
        public void Shot(string path)
        {
            try
            {
                using (Bitmap bmp = new Bitmap(Width, Height))
                {
                    DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                    bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
                }
                Log.W("界面快照已写出：{0}", path);
            }
            catch (Exception ex) { Log.Err("界面快照失败：{0}", ex.Message); }
        }
    }
}
