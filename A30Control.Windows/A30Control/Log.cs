using System.IO;

namespace A30Control;

/// %APPDATA%\A30Control\a30.log, rotated at 1 MB — the file Doug sends back when something fails.
static class Log
{
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "A30Control");
    public static string FilePath => Path.Combine(Dir, "a30.log");
    static readonly object Gate = new();

    public static void Write(string s)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var fi = new FileInfo(FilePath);
                if (fi.Exists && fi.Length > 1_000_000) File.Move(FilePath, FilePath + ".1", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {s}{Environment.NewLine}");
            }
            catch { }   // logging must never take the app down
        }
    }
}
