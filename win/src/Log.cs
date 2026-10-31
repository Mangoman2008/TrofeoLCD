using System;
using System.IO;
using System.Text;

namespace DshLcd
{
    /// <summary>极简双写日志：控制台 + 文件。VM 里没有屏幕可看，文件才是真正的反馈通道。</summary>
    public static class Log
    {
        private static readonly object Gate = new object();
        private static string _path;
        private static bool _echo = true;

        public static string Path { get { return _path; } }

        /// <summary>设置日志文件（每次运行覆盖，避免日志无限长大）</summary>
        /// <summary>界面订阅日志用（GUI 里那栏实时输出）。为 null 时只写文件/控制台。</summary>
        public static Action<string> Sink;

        public static void Open(string path)
        {
            _path = path;
            if (string.IsNullOrEmpty(path)) return;
            try
            {
                string dir = System.IO.Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(path,
                    "=== dshlcd " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " ===\r\n",
                    new UTF8Encoding(false));
            }
            catch (Exception) { }
        }

        public static void W(string msg)
        {
            string line = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + msg;
            lock (Gate)
            {
                if (_echo) { try { Console.WriteLine(line); } catch (Exception) { } }
                Action<string> sink = Sink;
                if (sink != null) { try { sink(line); } catch (Exception) { } }
                if (!string.IsNullOrEmpty(_path))
                {
                    try { File.AppendAllText(_path, line + "\r\n", new UTF8Encoding(false)); } catch (Exception) { }
                }
            }
        }

        public static void W(string fmt, params object[] args)
        {
            W(string.Format(fmt, args));
        }

        public static void Err(string msg) { W("[错误] " + msg); }

        public static void Err(string fmt, params object[] args) { W("[错误] " + string.Format(fmt, args)); }
    }
}
