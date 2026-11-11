using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;

namespace A30Control;

/// "Start with Windows": HKCU\…\Run\A30Control, launched with --autostart (tray only, no window).
static class Autostart
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string AutostartArg = "--autostart";

    public static bool IsEnabled => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("A30Control") is string;

    public static void Set(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(Key);
        if (on) k.SetValue("A30Control", $"\"{Environment.ProcessPath}\" {AutostartArg}");
        else k.DeleteValue("A30Control", throwOnMissingValue: false);
    }
}

/// Calls back with the process name of every newly focused window (EQ per app). Must be created on
/// the UI thread: out-of-context WinEvent hooks are delivered through its message loop.
sealed class ForegroundWatcher
{
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll")]
    static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint tid, uint flags);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    const uint EVENT_SYSTEM_FOREGROUND = 3;
    readonly WinEventProc proc;   // keeps the delegate alive for the hook

    public ForegroundWatcher(Action<string> onProcess)
    {
        proc = (_, _, hwnd, _, _, _, _) =>
        {
            GetWindowThreadProcessId(hwnd, out var pid);
            try { using var p = Process.GetProcessById((int)pid); onProcess(p.ProcessName); }
            catch { }
        };
        SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, 0);
    }
}

static class Dark
{
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// Dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE = 20, Windows 10 2004+).
    public static void TitleBar(Window w)
    {
        int on = 1;
        DwmSetWindowAttribute(new WindowInteropHelper(w).Handle, 20, ref on, sizeof(int));
    }
}
