using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Navi.App;

public sealed class NaviSwitch : Border
{
    private static readonly Duration Slide = new(TimeSpan.FromMilliseconds(150));
    private readonly TranslateTransform knobOffset = new();

    public NaviSwitch(bool isOn)
    {
        Width = 30;
        Height = 17;
        CornerRadius = new CornerRadius(8.5);
        VerticalAlignment = VerticalAlignment.Center;
        Margin = new Thickness(12, 0, 0, 0);
        Child = new Ellipse
        {
            Width = 13,
            Height = 13,
            Fill = Brushes.White,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(2, 0, 0, 0),
            RenderTransform = knobOffset,
        };
        Apply(isOn, animate: false);
    }

    public void Apply(bool isOn, bool animate = true)
    {
        Background = isOn ? NaviTheme.Accent : NaviTheme.SwitchOff;
        var target = isOn ? 13.0 : 0.0;
        if (animate) knobOffset.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(target, Slide) { EasingFunction = new QuadraticEase() });
        else knobOffset.X = target;
    }
}

public sealed class NaviSegments : Border
{
    public NaviSegments(IReadOnlyList<string> labels, int selected)
    {
        ArgumentNullException.ThrowIfNull(labels);
        Background = NaviTheme.SegmentTrack;
        CornerRadius = new CornerRadius(6);
        Padding = new Thickness(2);
        Margin = new Thickness(12, 2, 0, 2);
        VerticalAlignment = VerticalAlignment.Center;
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        for (var i = 0; i < labels.Count; i++)
        {
            var on = i == selected;
            panel.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(8, 1, 8, 1),
                Margin = new Thickness(i == 0 ? 0 : 2, 0, 0, 0),
                Background = on ? NaviTheme.SwitchOff : Brushes.Transparent,
                Child = new TextBlock { Text = labels[i], FontSize = NaviTheme.SmallFontSize, Foreground = on ? Brushes.White : NaviTheme.Dim },
            });
        }
        Child = panel;
    }
}
