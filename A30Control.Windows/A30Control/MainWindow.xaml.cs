using System.ComponentModel;
using System.Windows;

namespace A30Control;

public partial class MainWindow : Window
{
    public MainWindow(HeadsetModel model)
    {
        InitializeComponent();
        DataContext = model;
        SourceInitialized += (_, _) => Dark.TitleBar(this);
    }

    void CancelTurnOff(object sender, RoutedEventArgs e) => ((HeadsetModel)DataContext).CancelTurnOff();

    /// Closing hides the window; the app stays in the tray (Quit is in the tray menu/panel).
    protected override void OnClosing(CancelEventArgs e)
    {
        if (!App.Quitting) { e.Cancel = true; Hide(); }
        base.OnClosing(e);
    }
}
