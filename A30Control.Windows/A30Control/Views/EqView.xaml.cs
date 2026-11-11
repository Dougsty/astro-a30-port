using System.Windows;
using System.Windows.Controls;

namespace A30Control.Views;

public partial class EqView : UserControl
{
    public EqView() => InitializeComponent();
    HeadsetModel M => (HeadsetModel)DataContext;
    void Revert(object sender, RoutedEventArgs e) => M.RevertEq();
    void ResetFlat(object sender, RoutedEventArgs e) => M.ResetFlat();

    void SaveCurve(object sender, RoutedEventArgs e)
    {
        if (AskWindow.Ask(Window.GetWindow(this), "Save the Custom curve as") is string n) M.SaveCurrentEq(n);
    }
}
