using Navi.Core;

namespace Navi.Core.Tests;

public sealed class NaviMenuModelTests
{
    private static List<string> Titles(MenuState state) =>
        NaviMenuModel.Build(state).Select(e => e.IsSeparator ? "-" : e.Title).ToList();

    [Fact]
    public void MatchesTheMacMenuOrder()
    {
        Assert.Equal(
            [
                "All-in-One", "Capture Area", "Capture Window", "Capture Fullscreen", "Scrolling Capture", "Capture Text", "Self-Timer",
                "-", "Record Screen…", "-", "Close All Cards", "-", "Open History", "-", "Settings…", "Check for Updates…", "Quit Navi",
            ],
            Titles(new MenuState(ShortcutStyle.Windows, IsRecording: false, HasPins: false)));
    }

    [Fact]
    public void RecordingSwapsInStopAndPinsAddTheirItems()
    {
        var titles = Titles(new MenuState(ShortcutStyle.Windows, IsRecording: true, HasPins: true));
        Assert.Contains("Stop Recording", titles);
        Assert.DoesNotContain("Record Screen…", titles);
        Assert.Equal(titles.IndexOf("Close All Cards") + 1, titles.IndexOf("Unlock Pinned Shots"));
        Assert.Equal(titles.IndexOf("Unlock Pinned Shots") + 1, titles.IndexOf("Close Pinned Shots"));
    }

    [Fact]
    public void ShortcutsFollowTheChosenStyle()
    {
        var windows = NaviMenuModel.Build(new MenuState(ShortcutStyle.Windows, false, false));
        var mac = NaviMenuModel.Build(new MenuState(ShortcutStyle.MacStyle, false, false));
        Assert.Equal("Win+Shift+S", windows.Single(e => e.Command == MenuCommand.CaptureArea).Shortcut);
        Assert.Equal("Ctrl+Shift+4", mac.Single(e => e.Command == MenuCommand.CaptureArea).Shortcut);
        Assert.Equal("Win+V", mac.Single(e => e.Command == MenuCommand.OpenHistory).Shortcut);
    }

    [Fact]
    public void SelfTimerOffersThreeFiveAndTenSeconds()
    {
        var timer = NaviMenuModel.Build(new MenuState(ShortcutStyle.Windows, false, false)).Single(e => e.Command == MenuCommand.SelfTimer);
        Assert.Equal(["3 Seconds", "5 Seconds", "10 Seconds"], timer.Submenu!.Select(e => e.Title));
    }
}
