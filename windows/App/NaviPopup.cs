using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Forms = System.Windows.Forms;

namespace Navi.App;

public enum PopupAnchor
{
    AboveLeft,
    RightOf,
}

public class NaviPopup : Window
{
    private readonly StackPanel rows = new();
    private System.Drawing.Point anchorPixels;
    private PopupAnchor anchor;
    private bool closing;

    public NaviPopup(double width)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Opacity = 0;
        FontFamily = NaviTheme.Font;
        FontSize = NaviTheme.FontSize;
        Foreground = NaviTheme.Text;
        Content = new Border
        {
            Width = width,
            Margin = new Thickness(14),
            Background = NaviTheme.Surface,
            BorderBrush = NaviTheme.SurfaceEdge,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(NaviTheme.PanelRadius),
            Padding = new Thickness(NaviTheme.PanelPadding),
            Effect = new DropShadowEffect { BlurRadius = 24, ShadowDepth = 6, Direction = 270, Opacity = 0.55, Color = Colors.Black },
            Child = rows,
        };
        Deactivated += (_, _) => Dispatcher.BeginInvoke(CloseIfNothingActive);
        PreviewKeyDown += OnKey;
    }

    public NaviPopup? Child { get; private set; }

    public NaviPopup? ParentPopup { get; private set; }

    protected StackPanel Rows => rows;

    public void ShowAt(System.Drawing.Point pixels, PopupAnchor where)
    {
        anchorPixels = pixels;
        anchor = where;
        ContentRendered += (_, _) => Place();
        Show();
    }

    public void OpenChild(NaviPopup child, FrameworkElement row)
    {
        ArgumentNullException.ThrowIfNull(child);
        ArgumentNullException.ThrowIfNull(row);
        Child?.Close();
        Child = child;
        child.ParentPopup = this;
        child.Closed += (_, _) => { if (Child == child) Child = null; };
        var dpi = VisualTreeHelper.GetDpi(this);
        var topRight = row.PointToScreen(new Point(row.ActualWidth, 0));
        child.ShowAt(new System.Drawing.Point((int)topRight.X, (int)(topRight.Y - (NaviTheme.PanelPadding + 15) * dpi.DpiScaleY)), PopupAnchor.RightOf);
    }

    public void CloseAll()
    {
        var root = this;
        while (root.ParentPopup is not null) root = root.ParentPopup;
        root.CloseTree();
    }

    protected override void OnClosed(EventArgs e)
    {
        closing = true;
        Child?.Close();
        base.OnClosed(e);
    }

    private void CloseTree()
    {
        if (closing) return;
        Child?.CloseTree();
        Close();
    }

    private void CloseIfNothingActive()
    {
        if (closing) return;
        if (IsActive || (Child?.IsActive ?? false) || (ParentPopup?.IsActive ?? false)) return;
        CloseAll();
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        var ctrlW = e.Key == Key.W && Keyboard.Modifiers == ModifierKeys.Control;
        if (e.Key != Key.Escape && !ctrlW) return;
        e.Handled = true;
        if (e.Key == Key.Escape && ParentPopup is not null) Close();
        else CloseAll();
    }

    private void Place()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var dpi = VisualTreeHelper.GetDpi(this);
        var width = (int)Math.Ceiling(ActualWidth * dpi.DpiScaleX);
        var height = (int)Math.Ceiling(ActualHeight * dpi.DpiScaleY);
        var shadow = (int)(14 * dpi.DpiScaleX);
        var area = Forms.Screen.FromPoint(anchorPixels).WorkingArea;
        var x = anchor == PopupAnchor.RightOf ? anchorPixels.X - shadow : anchorPixels.X - width + shadow;
        var y = anchor == PopupAnchor.RightOf ? anchorPixels.Y - shadow : anchorPixels.Y - height + shadow;
        x = Math.Clamp(x, area.Left - shadow, Math.Max(area.Left - shadow, area.Right - width + shadow));
        y = Math.Clamp(y, area.Top - shadow, Math.Max(area.Top - shadow, area.Bottom - height + shadow));
        Native.MoveWindow(handle, x, y);
        Opacity = 1;
        Activate();
        Native.SetForegroundWindow(handle);
    }
}
