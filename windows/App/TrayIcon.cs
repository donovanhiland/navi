using System.Drawing;
using System.Drawing.Drawing2D;
using Forms = System.Windows.Forms;

namespace Navi.App;

public sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon notifyIcon;
    private readonly Icon icon;
    private readonly IntPtr iconHandle;

    public TrayIcon(string tooltip)
    {
        (icon, iconHandle) = DrawIcon();
        notifyIcon = new Forms.NotifyIcon { Icon = icon, Text = tooltip, Visible = true };
        notifyIcon.MouseUp += (_, e) =>
        {
            if (e.Button is Forms.MouseButtons.Left or Forms.MouseButtons.Right) Clicked?.Invoke(this, Forms.Cursor.Position);
        };
    }

    public event EventHandler<Point>? Clicked;

    public void Dispose()
    {
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        icon.Dispose();
        Native.DestroyIcon(iconHandle);
    }

    private static (Icon Icon, IntPtr Handle) DrawIcon()
    {
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var star = new GraphicsPath();
            star.AddBezier(16, 2, 16.8f, 9.3f, 20.7f, 13.2f, 28, 14);
            star.AddBezier(28, 14, 20.7f, 14.8f, 16.8f, 18.7f, 16, 26);
            star.AddBezier(16, 26, 15.2f, 18.7f, 11.3f, 14.8f, 4, 14);
            star.AddBezier(4, 14, 11.3f, 13.2f, 15.2f, 9.3f, 16, 2);
            star.CloseFigure();
            g.FillPath(Brushes.White, star);
            g.FillEllipse(Brushes.White, 23, 23, 7, 7);
        }
        var handle = bitmap.GetHicon();
        return (Icon.FromHandle(handle), handle);
    }
}
