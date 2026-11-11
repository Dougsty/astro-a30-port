using System.Windows;
using System.Windows.Controls;

namespace A30Control.Views;

public partial class SettingsView : UserControl
{
    public SettingsView() => InitializeComponent();
    HeadsetModel M => (HeadsetModel)DataContext;

    void Rename(object sender, RoutedEventArgs e)
    {
        if (AskWindow.Ask(Window.GetWindow(this), "Headset name (shown in Bluetooth)", M.Name) is string n) M.Rename(n);
    }

    void TurnOff(object sender, RoutedEventArgs e) => M.TurnOff();

    /// Two confirmations: a warning, then typing RESET.
    void FactoryReset(object sender, RoutedEventArgs e)
    {
        var w = Window.GetWindow(this);
        if (MessageBox.Show(w, "This erases all headset settings; you may need to re-pair it.", "Factory reset the headset?",
                            MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        if (AskWindow.Ask(w, "Type RESET to confirm", mustType: "RESET") == "RESET") M.FactoryReset();
    }
}
