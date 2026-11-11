using System.Windows;

namespace A30Control;

public partial class App : Application
{
    public static bool Quitting { get; private set; }

    Mutex? single;
    EventWaitHandle? showSignal;
    HeadsetModel? model;
    TrayIcon? tray;
    TrayPanel? panel;
    MainWindow? window;
    ForegroundWatcher? foreground;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Only one client can hold the headset's control channel: a second copy exits at once.
        single = new Mutex(true, @"Local\A30Control", out bool first);
        if (!first)
        {
            // Already running (maybe hidden in the tray overflow): ask that copy to show its window.
            try { EventWaitHandle.OpenExisting(@"Local\A30Control.Show").Set(); } catch { }
            Shutdown();
            return;
        }
        showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\A30Control.Show");
        new Thread(() => { while (showSignal.WaitOne()) Dispatcher.Invoke(OpenWindow); }) { IsBackground = true }.Start();
        DispatcherUnhandledException += (_, ex) => { Log.Write("unhandled: " + ex.Exception); ex.Handled = true; };
        Log.Write("A30 Control starting");
        model = new HeadsetModel();
        tray = new TrayIcon(model, TogglePanel, OpenWindow, Quit);
        model.Notify = tray.Toast;
        model.RequestQuit = Quit;
        foreground = new ForegroundWatcher(model.AppActivated);
        model.Start();
        // Started by hand (Start menu, setup's last page, double-click): show the window, since new tray
        // icons land in the hidden overflow on Windows 11. At login (--autostart) stay in the tray.
        if (!e.Args.Contains(Autostart.AutostartArg)) OpenWindow();
    }

    void TogglePanel()
    {
        panel ??= new TrayPanel(model!, OpenWindow, Quit);
        if (panel.IsVisible) panel.Hide();
        // The click on the tray icon deactivates (hides) the panel first; don't reopen it right away.
        else if ((DateTime.Now - panel.HiddenAt).TotalMilliseconds > 300) panel.ShowNearTray();
    }

    void OpenWindow()
    {
        panel?.Hide();
        window ??= new MainWindow(model!);
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    void Quit()
    {
        Quitting = true;
        model?.Shutdown();
        tray?.Dispose();
        Shutdown();
    }
}
