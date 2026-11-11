using System.Windows;
using System.Windows.Controls;

namespace A30Control;

static class AskWindow
{
    /// Text prompt. With `mustType`, the OK button stays disabled until exactly that text is typed.
    public static string? Ask(Window? owner, string title, string initial = "", string? mustType = null)
    {
        var box = new TextBox { Text = initial, Margin = new Thickness(0, 10, 0, 14), Padding = new Thickness(4) };
        var ok = new Button
        {
            Content = mustType == null ? "Save" : "Factory reset", IsDefault = true, Width = 110,
            Margin = new Thickness(0, 0, 8, 0), IsEnabled = mustType == null || initial == mustType,
        };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Width = 90 };
        if (mustType != null) box.TextChanged += (_, _) => ok.IsEnabled = box.Text == mustType;
        var w = new Window
        {
            Title = "A30 Control", Owner = owner, ShowInTaskbar = false,
            SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = owner == null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            Content = new StackPanel
            {
                Margin = new Thickness(18), Width = 340,
                Children =
                {
                    new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap },
                    box,
                    new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { ok, cancel } },
                },
            },
        };
        ok.Click += (_, _) => w.DialogResult = true;
        w.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        if (w.ShowDialog() != true) return null;
        var v = box.Text.Trim();
        return v.Length == 0 ? null : v;
    }
}
