using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace A30Control.Views;

public partial class ExtrasView : UserControl
{
    public ExtrasView() => InitializeComponent();
    HeadsetModel M => (HeadsetModel)DataContext;

    void SaveProfile(object sender, RoutedEventArgs e)
    {
        if (AskWindow.Ask(Window.GetWindow(this), "Profile name") is string n) M.SaveProfile(n);
    }

    void AddApp(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title = "Choose a game or app",
            Filter = "Programs (*.exe)|*.exe",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        };
        if (dlg.ShowDialog(Window.GetWindow(this)) == true) M.AddAppRule(dlg.FileName);
    }
}
