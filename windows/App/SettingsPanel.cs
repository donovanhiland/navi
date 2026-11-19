using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Navi.Core;

namespace Navi.App;

public sealed class SettingsPanel : NaviPopup
{
    private static readonly string[] StyleLabels = ["Windows", "Mac-style"];
    private static readonly string[] TalkKeyLabels = ["Right Alt", "Right Ctrl"];

    private readonly SettingsStore store;
    private readonly Inbox inbox;
    private bool cleared;

    public SettingsPanel(SettingsStore store, Inbox inbox)
        : base(NaviTheme.SettingsWidth)
    {
        this.store = store ?? throw new ArgumentNullException(nameof(store));
        this.inbox = inbox ?? throw new ArgumentNullException(nameof(inbox));
        store.Changed += OnSettingsChanged;
        Closed += (_, _) => store.Changed -= OnSettingsChanged;
        Build();
    }

    private void OnSettingsChanged(object? sender, NaviSettings settings) => Build();

    private void Build()
    {
        var s = store.Current;
        Rows.Children.Clear();
        Add(PanelRows.Section("Capture"));
        Add(Toggle("Copy Screenshots to Clipboard", s.CopyToClipboard, x => x with { CopyToClipboard = !x.CopyToClipboard }));
        Add(Toggle("Edit Screenshots Before Copying", s.EditAfterCapture, x => x with { EditAfterCapture = !x.EditAfterCapture }));
        Add(Toggle("Hide Desktop Icons in Shots", s.HideDesktopIcons, x => x with { HideDesktopIcons = !x.HideDesktopIcons }));
        Add(Toggle("Use PrtSc and Win+Shift+S", s.BorrowScreenshotKeys, x => x with { BorrowScreenshotKeys = !x.BorrowScreenshotKeys }));
        Add(Segments("Shortcut Style", StyleLabels, (int)s.ShortcutStyle, x => x with { ShortcutStyle = Next(x.ShortcutStyle) }));
        Add(PanelRows.Separator());
        Add(PanelRows.Section("Talk to Type"));
        Add(Toggle("Talk to Type", s.TalkToType, x => x with { TalkToType = !x.TalkToType }));
        Add(Segments("Talk Key", TalkKeyLabels, (int)s.TalkKey, x => x with { TalkKey = Next(x.TalkKey) }));
        Add(Toggle("Tap Key to Start and Stop", s.TapToStartAndStop, x => x with { TapToStartAndStop = !x.TapToStartAndStop }));
        Add(Toggle("Show Words While Talking", s.ShowWordsWhileTalking, x => x with { ShowWordsWhileTalking = !x.ShowWordsWhileTalking }));
        Add(Toggle("Keep Microphone Ready", s.KeepMicrophoneReady, x => x with { KeepMicrophoneReady = !x.KeepMicrophoneReady }));
        Add(Toggle("Better Cleanup (1 GB download)", s.BetterCleanup, x => x with { BetterCleanup = !x.BetterCleanup }));
        Add(PanelRows.Separator());
        Add(PanelRows.Section("History"));
        Add(PanelRows.Row("History Shortcut", ShortcutWithButton(KeyMap.Get(s.ShortcutStyle, NaviAction.OpenHistory).Display), onClick: null));
        Add(PanelRows.Row("Clear History", PanelRows.SmallButton(cleared ? "Cleared" : "Clear"), ClearHistory));
        Add(PanelRows.Note("Pinned items stay."));
        Add(PanelRows.Separator());
        Add(PanelRows.Section("General"));
        Add(Toggle("Start with Windows", s.StartWithWindows, x => x with { StartWithWindows = !x.StartWithWindows }));
        Add(PanelRows.Separator());
        Add(PanelRows.Section("Permissions"));
        var mic = MicrophoneAccess.IsAllowed();
        var micStatus = PanelRows.Shortcut(mic ? "Allowed" : "Off");
        micStatus.Foreground = mic ? NaviTheme.Good : NaviTheme.Dim;
        Add(PanelRows.Row("Microphone", micStatus, MicrophoneAccess.OpenSettings));
        Add(PanelRows.Note("Screen capture, paste, and the keyboard need no permission on Windows."));
    }

    private static ShortcutStyle Next(ShortcutStyle style) => style == ShortcutStyle.Windows ? ShortcutStyle.MacStyle : ShortcutStyle.Windows;

    private static TalkKey Next(TalkKey key) => key == TalkKey.RightAlt ? TalkKey.RightCtrl : TalkKey.RightAlt;

    private static StackPanel ShortcutWithButton(string shortcut)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(PanelRows.Shortcut(shortcut));
        var change = PanelRows.SmallButton("Change…");
        change.Opacity = 0.5;
        change.ToolTip = "Comes with the clipboard step (W1)";
        panel.Children.Add(change);
        return panel;
    }

    private void Add(UIElement element) => Rows.Children.Add(element);

    private Border Toggle(string title, bool isOn, Func<NaviSettings, NaviSettings> flip)
    {
        var sw = new NaviSwitch(isOn);
        return PanelRows.Row(title, sw, () =>
        {
            sw.Apply(!isOn);
            var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(160) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                store.Update(flip);
            };
            timer.Start();
        });
    }

    private Border Segments(string title, IReadOnlyList<string> labels, int selected, Func<NaviSettings, NaviSettings> next) =>
        PanelRows.Row(title, new NaviSegments(labels, selected), () => store.Update(next));

    private void ClearHistory()
    {
        inbox.ClearUnpinned();
        cleared = true;
        Build();
    }
}
