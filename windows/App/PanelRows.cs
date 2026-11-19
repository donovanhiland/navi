using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Navi.App;

public static class PanelRows
{
    public static Border Row(string title, UIElement? right, Action? onClick, bool enabled = true)
    {
        var label = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, Foreground = enabled ? NaviTheme.Text : NaviTheme.Dim };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(label);
        if (right is not null)
        {
            Grid.SetColumn(right, 1);
            grid.Children.Add(right);
        }
        var row = new Border
        {
            MinHeight = NaviTheme.RowHeight,
            Padding = NaviTheme.RowPadding,
            CornerRadius = new CornerRadius(NaviTheme.RowRadius),
            Background = Brushes.Transparent,
            Child = grid,
            Focusable = false,
        };
        if (!enabled || onClick is null) return row;
        row.Cursor = Cursors.Arrow;
        row.MouseEnter += (_, _) => Highlight(row, label, right, on: true);
        row.MouseLeave += (_, _) => Highlight(row, label, right, on: false);
        row.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            onClick();
        };
        return row;
    }

    public static TextBlock Shortcut(string? text) => new()
    {
        Text = text ?? string.Empty,
        Foreground = NaviTheme.Dim,
        FontSize = NaviTheme.SmallFontSize,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(12, 0, 0, 0),
    };

    public static TextBlock Section(string title) => new()
    {
        Text = title,
        Foreground = NaviTheme.SectionTitle,
        FontSize = 11,
        FontWeight = FontWeights.SemiBold,
        Padding = new Thickness(10, 6, 10, 2),
    };

    public static Border Separator() => new()
    {
        Height = 1,
        Background = NaviTheme.Divider,
        Margin = new Thickness(8, 4, 8, 4),
    };

    public static TextBlock Note(string text) => new()
    {
        Text = text,
        Foreground = NaviTheme.SectionTitle,
        FontSize = NaviTheme.SmallFontSize,
        TextWrapping = TextWrapping.Wrap,
        Padding = new Thickness(10, 2, 10, 6),
    };

    public static Border SmallButton(string text) => new()
    {
        Background = NaviTheme.ButtonFill,
        CornerRadius = new CornerRadius(5),
        Padding = new Thickness(8, 0, 8, 1),
        Margin = new Thickness(6, 2, 0, 2),
        VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock { Text = text, FontSize = NaviTheme.SmallFontSize, Foreground = NaviTheme.Text },
    };

    private static void Highlight(Border row, TextBlock label, UIElement? right, bool on)
    {
        row.Background = on ? NaviTheme.Accent : Brushes.Transparent;
        label.Foreground = on ? NaviTheme.TextOnAccent : NaviTheme.Text;
        if (right is TextBlock text) text.Foreground = on ? NaviTheme.TextOnAccent : NaviTheme.Dim;
    }
}
