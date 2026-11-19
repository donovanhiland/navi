namespace Navi.Core;

public enum MenuCommand
{
    Separator,
    AllInOne,
    CaptureArea,
    CaptureWindow,
    CaptureFullscreen,
    ScrollingCapture,
    CaptureText,
    SelfTimer,
    Timer3,
    Timer5,
    Timer10,
    RecordScreen,
    StopRecording,
    CloseAllCards,
    UnlockPinnedShots,
    ClosePinnedShots,
    OpenHistory,
    Settings,
    CheckForUpdates,
    Quit,
}

public sealed record MenuEntry(MenuCommand Command, string Title = "", string? Shortcut = null, IReadOnlyList<MenuEntry>? Submenu = null)
{
    public bool IsSeparator => Command == MenuCommand.Separator;
}

public sealed record MenuState(ShortcutStyle Style, bool IsRecording, bool HasPins);

public static class NaviMenuModel
{
    private static readonly MenuEntry Separator = new(MenuCommand.Separator);

    public static IReadOnlyList<MenuEntry> Build(MenuState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        string Key(NaviAction action) => KeyMap.Get(state.Style, action).Display;
        var entries = new List<MenuEntry>
        {
            new(MenuCommand.AllInOne, "All-in-One", Key(NaviAction.AllInOne)),
            new(MenuCommand.CaptureArea, "Capture Area", Key(NaviAction.CaptureArea)),
            new(MenuCommand.CaptureWindow, "Capture Window"),
            new(MenuCommand.CaptureFullscreen, "Capture Fullscreen", Key(NaviAction.CaptureFullscreen)),
            new(MenuCommand.ScrollingCapture, "Scrolling Capture", Key(NaviAction.ScrollingCapture)),
            new(MenuCommand.CaptureText, "Capture Text", Key(NaviAction.CaptureText)),
            new(MenuCommand.SelfTimer, "Self-Timer", Submenu:
            [
                new(MenuCommand.Timer3, "3 Seconds"),
                new(MenuCommand.Timer5, "5 Seconds"),
                new(MenuCommand.Timer10, "10 Seconds"),
            ]),
            Separator,
            state.IsRecording
                ? new(MenuCommand.StopRecording, "Stop Recording", Key(NaviAction.Record))
                : new(MenuCommand.RecordScreen, "Record Screen…", Key(NaviAction.Record)),
            Separator,
            new(MenuCommand.CloseAllCards, "Close All Cards"),
        };
        if (state.HasPins)
        {
            entries.Add(new(MenuCommand.UnlockPinnedShots, "Unlock Pinned Shots"));
            entries.Add(new(MenuCommand.ClosePinnedShots, "Close Pinned Shots"));
        }
        entries.AddRange(
        [
            Separator,
            new(MenuCommand.OpenHistory, "Open History", Key(NaviAction.OpenHistory)),
            Separator,
            new(MenuCommand.Settings, "Settings…", "Ctrl+,"),
            new(MenuCommand.CheckForUpdates, "Check for Updates…"),
            new(MenuCommand.Quit, "Quit Navi"),
        ]);
        return entries;
    }
}
