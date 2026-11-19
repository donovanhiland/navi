namespace Navi.Core;

public enum ShortcutStyle
{
    Windows,
    MacStyle,
}

public enum NaviAction
{
    CaptureArea,
    CaptureWindow,
    CaptureFullscreen,
    AllInOne,
    ScrollingCapture,
    CaptureText,
    Record,
    OpenHistory,
    MenuAtMouse,
}

[Flags]
public enum KeyModifiers
{
    None = 0,
    Ctrl = 1,
    Alt = 2,
    Shift = 4,
    Win = 8,
}

public sealed record Shortcut(KeyModifiers Modifiers, string Key, string? Then = null)
{
    public string Display
    {
        get
        {
            var parts = new List<string>(5);
            if (Modifiers.HasFlag(KeyModifiers.Win)) parts.Add("Win");
            if (Modifiers.HasFlag(KeyModifiers.Ctrl)) parts.Add("Ctrl");
            if (Modifiers.HasFlag(KeyModifiers.Alt)) parts.Add("Alt");
            if (Modifiers.HasFlag(KeyModifiers.Shift)) parts.Add("Shift");
            parts.Add(Key);
            var combo = string.Join('+', parts);
            return Then is null ? combo : $"{combo}, {Then}";
        }
    }
}

public static class KeyMap
{
    private const KeyModifiers CtrlAltShift = KeyModifiers.Ctrl | KeyModifiers.Alt | KeyModifiers.Shift;
    private const KeyModifiers CtrlShift = KeyModifiers.Ctrl | KeyModifiers.Shift;
    private const KeyModifiers WinShift = KeyModifiers.Win | KeyModifiers.Shift;

    private static readonly IReadOnlyDictionary<NaviAction, Shortcut> Shared = new Dictionary<NaviAction, Shortcut>
    {
        [NaviAction.ScrollingCapture] = new(CtrlAltShift, "4"),
        [NaviAction.CaptureText] = new(CtrlAltShift, "T"),
        [NaviAction.Record] = new(CtrlAltShift, "5"),
        [NaviAction.OpenHistory] = new(KeyModifiers.Win, "V"),
        [NaviAction.MenuAtMouse] = new(CtrlAltShift, "N"),
    };

    private static readonly IReadOnlyDictionary<NaviAction, Shortcut> WindowsKeys = Merge(new Dictionary<NaviAction, Shortcut>
    {
        [NaviAction.CaptureArea] = new(WinShift, "S"),
        [NaviAction.CaptureWindow] = new(WinShift, "S", "Space"),
        [NaviAction.CaptureFullscreen] = new(KeyModifiers.None, "PrtSc"),
        [NaviAction.AllInOne] = new(KeyModifiers.Ctrl, "PrtSc"),
    });

    private static readonly IReadOnlyDictionary<NaviAction, Shortcut> MacKeys = Merge(new Dictionary<NaviAction, Shortcut>
    {
        [NaviAction.CaptureArea] = new(CtrlShift, "4"),
        [NaviAction.CaptureWindow] = new(CtrlShift, "4", "Space"),
        [NaviAction.CaptureFullscreen] = new(CtrlShift, "3"),
        [NaviAction.AllInOne] = new(CtrlShift, "5"),
    });

    public static IReadOnlyDictionary<NaviAction, Shortcut> For(ShortcutStyle style) => style switch
    {
        ShortcutStyle.Windows => WindowsKeys,
        ShortcutStyle.MacStyle => MacKeys,
        _ => throw new ArgumentOutOfRangeException(nameof(style), style, "Unknown shortcut style."),
    };

    public static Shortcut Get(ShortcutStyle style, NaviAction action) => For(style)[action];

    private static Dictionary<NaviAction, Shortcut> Merge(Dictionary<NaviAction, Shortcut> own)
    {
        var all = new Dictionary<NaviAction, Shortcut>(Shared);
        foreach (var (action, shortcut) in own) all[action] = shortcut;
        return all;
    }
}
