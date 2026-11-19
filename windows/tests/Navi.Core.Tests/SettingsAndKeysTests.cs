using Navi.Core;

namespace Navi.Core.Tests;

public sealed class SettingsAndKeysTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "NaviSettings-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
    }

    [Fact]
    public void DefaultsMatchTheMacApp()
    {
        var s = new SettingsStore(directory).Current;
        Assert.True(s.CopyToClipboard);
        Assert.False(s.EditAfterCapture);
        Assert.True(s.ShowWordsWhileTalking);
        Assert.False(s.KeepMicrophoneReady);
        Assert.False(s.TapToStartAndStop);
        Assert.Equal(ShortcutStyle.Windows, s.ShortcutStyle);
        Assert.Equal(TalkKey.RightAlt, s.TalkKey);
    }

    [Fact]
    public void ChangesAreKeptAndAnnounced()
    {
        var store = new SettingsStore(directory);
        NaviSettings? seen = null;
        store.Changed += (_, s) => seen = s;
        store.Update(s => s with { ShortcutStyle = ShortcutStyle.MacStyle, KeepMicrophoneReady = true });
        Assert.Equal(ShortcutStyle.MacStyle, seen?.ShortcutStyle);
        var reopened = new SettingsStore(directory).Current;
        Assert.Equal(ShortcutStyle.MacStyle, reopened.ShortcutStyle);
        Assert.True(reopened.KeepMicrophoneReady);
    }

    [Fact]
    public void MissingFieldsFallBackToDefaults()
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "settings.json"), """{ "editAfterCapture": true }""");
        var s = new SettingsStore(directory).Current;
        Assert.True(s.EditAfterCapture);
        Assert.True(s.CopyToClipboard);
    }

    [Fact]
    public void BrokenSettingsFileFallsBackToDefaults()
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "settings.json"), "nope");
        Assert.Equal(new NaviSettings(), new SettingsStore(directory).Current);
    }

    [Fact]
    public void UnchangedUpdateDoesNotAnnounce()
    {
        var store = new SettingsStore(directory);
        var count = 0;
        store.Changed += (_, _) => count++;
        store.Update(s => s);
        Assert.Equal(0, count);
    }

    [Theory]
    [InlineData(NaviAction.CaptureArea, "Win+Shift+S", "Ctrl+Shift+4")]
    [InlineData(NaviAction.CaptureWindow, "Win+Shift+S, Space", "Ctrl+Shift+4, Space")]
    [InlineData(NaviAction.CaptureFullscreen, "PrtSc", "Ctrl+Shift+3")]
    [InlineData(NaviAction.AllInOne, "Ctrl+PrtSc", "Ctrl+Shift+5")]
    [InlineData(NaviAction.ScrollingCapture, "Ctrl+Alt+Shift+4", "Ctrl+Alt+Shift+4")]
    [InlineData(NaviAction.CaptureText, "Ctrl+Alt+Shift+T", "Ctrl+Alt+Shift+T")]
    [InlineData(NaviAction.Record, "Ctrl+Alt+Shift+5", "Ctrl+Alt+Shift+5")]
    [InlineData(NaviAction.OpenHistory, "Win+V", "Win+V")]
    [InlineData(NaviAction.MenuAtMouse, "Ctrl+Alt+Shift+N", "Ctrl+Alt+Shift+N")]
    public void BothKeyStylesCoverEveryAction(NaviAction action, string windows, string mac)
    {
        Assert.Equal(windows, KeyMap.Get(ShortcutStyle.Windows, action).Display);
        Assert.Equal(mac, KeyMap.Get(ShortcutStyle.MacStyle, action).Display);
    }

    [Fact]
    public void EveryActionHasAShortcutInEachStyle()
    {
        foreach (var style in Enum.GetValues<ShortcutStyle>())
        {
            Assert.Equal(Enum.GetValues<NaviAction>().Length, KeyMap.For(style).Count);
        }
    }
}
