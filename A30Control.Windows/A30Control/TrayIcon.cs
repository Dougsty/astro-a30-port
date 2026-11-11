using System.Drawing;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace A30Control;

/// Notification-area icon: Doug's artwork with status dots (green charging, red low battery,
/// orange mic muted), tooltip with name and battery, left click = panel, right click = menu.
sealed class TrayIcon : IDisposable
{
    readonly Forms.NotifyIcon icon = new();
    readonly HeadsetModel model;
    readonly Bitmap baseImage;
    string? badgeKey;

    public TrayIcon(HeadsetModel model, Action togglePanel, Action openWindow, Action quit)
    {
        this.model = model;
        using (var s = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/tray.png")).Stream)
        using (var tmp = new Bitmap(s))
            baseImage = new Bitmap(tmp);   // GDI+ needs the stream alive unless copied
        icon.MouseUp += (_, e) => { if (e.Button == Forms.MouseButtons.Left) togglePanel(); };
        icon.BalloonTipClicked += (_, _) => openWindow();
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open window", null, (_, _) => openWindow());
        menu.Items.Add("Quit", null, (_, _) => quit());
        icon.ContextMenuStrip = menu;
        model.PropertyChanged += (_, _) => Refresh();
        Refresh();
        icon.Visible = true;
    }

    void Refresh()
    {
        var tip = model.TrayTooltip;
        icon.Text = tip.Length > 127 ? tip[..127] : tip;
        var (charging, low, mic) = model.Badges;
        var key = $"{charging}{low}{mic}";
        if (key == badgeKey) return;
        badgeKey = key;
        using var bmp = new Bitmap(baseImage);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            void Dot(Color c, int x, int y)
            {
                using var b = new SolidBrush(c);
                using var p = new Pen(Color.Black, 2);
                g.FillEllipse(b, x, y, 13, 13);
                g.DrawEllipse(p, x, y, 13, 13);
            }
            if (charging) Dot(Color.FromArgb(0x3C, 0xCF, 0x4E), 18, 18);
            else if (low) Dot(Color.FromArgb(0xFF, 0x3B, 0x30), 18, 18);
            if (mic) Dot(Color.FromArgb(0xFF, 0x9F, 0x0A), 18, 1);
        }
        var h = bmp.GetHicon();
        var old = icon.Icon;
        using (var tmp = Icon.FromHandle(h)) icon.Icon = (Icon)tmp.Clone();
        DestroyIcon(h);
        old?.Dispose();
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    public void Toast(string title, string body) => icon.ShowBalloonTip(5000, title, body, Forms.ToolTipIcon.None);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
