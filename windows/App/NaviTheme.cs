using System.Windows;
using System.Windows.Media;

namespace Navi.App;

public static class NaviTheme
{
    public static readonly Color AccentColor = Color.FromRgb(0x3B, 0x82, 0xF6);

    public static readonly Brush Surface = Frozen(new SolidColorBrush(Color.FromArgb(0xF2, 0x2A, 0x2B, 0x2F)));
    public static readonly Brush SurfaceEdge = Frozen(new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)));
    public static readonly Brush Accent = Frozen(new SolidColorBrush(AccentColor));
    public static readonly Brush Text = Frozen(new SolidColorBrush(Color.FromRgb(0xEE, 0xEE, 0xEE)));
    public static readonly Brush TextOnAccent = Brushes.White;
    public static readonly Brush Dim = Frozen(new SolidColorBrush(Color.FromRgb(0x99, 0x99, 0x99)));
    public static readonly Brush SectionTitle = Frozen(new SolidColorBrush(Color.FromRgb(0x8D, 0x8E, 0x94)));
    public static readonly Brush Divider = Frozen(new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)));
    public static readonly Brush SwitchOff = Frozen(new SolidColorBrush(Color.FromRgb(0x4A, 0x4B, 0x50)));
    public static readonly Brush SegmentTrack = Frozen(new SolidColorBrush(Color.FromRgb(0x1A, 0x1B, 0x1E)));
    public static readonly Brush ButtonFill = Frozen(new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)));
    public static readonly Brush Good = Frozen(new SolidColorBrush(Color.FromRgb(0x4A, 0xDE, 0x80)));

    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");

    public const double FontSize = 13;
    public const double SmallFontSize = 11.5;
    public const double PanelRadius = 10;
    public const double RowRadius = 6;
    public const double PanelPadding = 5;
    public const double RowHeight = 24;
    public const double MenuWidth = 300;
    public const double SettingsWidth = 340;

    public static readonly Thickness RowPadding = new(10, 0, 10, 0);

    private static SolidColorBrush Frozen(SolidColorBrush brush)
    {
        brush.Freeze();
        return brush;
    }
}
