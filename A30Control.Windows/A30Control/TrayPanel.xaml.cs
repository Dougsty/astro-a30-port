using System.Windows;

namespace A30Control;

public partial class TrayPanel : Window
{
    readonly Action openWindow, quit;
    public DateTime HiddenAt { get; private set; }

    public TrayPanel(HeadsetModel model, Action openWindow, Action quit)
    {
        InitializeComponent();
        DataContext = model;
        this.openWindow = openWindow;
        this.quit = quit;
        // Clicking anywhere else closes the panel, like a flyout.
        Deactivated += (_, _) => { Hide(); HiddenAt = DateTime.Now; };
        SizeChanged += (_, _) => { if (IsVisible) PlaceNearTray(); };
    }

    public void ShowNearTray()
    {
        Show();
        UpdateLayout();
        PlaceNearTray();
        Activate();
    }

    /// Bottom-right corner of the work area (the desktop minus the taskbar), in WPF units.
    void PlaceNearTray()
    {
        var wa = SystemParameters.WorkArea;
        Left = wa.Right - ActualWidth - 12;
        Top = wa.Bottom - ActualHeight - 12;
    }

    HeadsetModel M => (HeadsetModel)DataContext;
    void TurnOff(object sender, RoutedEventArgs e) => M.TurnOff();
    void CancelTurnOff(object sender, RoutedEventArgs e) => M.CancelTurnOff();
    void OpenWindow(object sender, RoutedEventArgs e) { Hide(); openWindow(); }
    void Quit(object sender, RoutedEventArgs e) => quit();
}
