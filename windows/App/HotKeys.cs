using System.Runtime.InteropServices;
using System.Windows.Interop;
using Navi.Core;

namespace Navi.App;

public sealed class HotKeys : IDisposable
{
    private readonly HwndSource window;
    private readonly Dictionary<int, NaviAction> registered = [];
    private int nextId = 1;

    public HotKeys()
    {
        window = new HwndSource(new HwndSourceParameters("Navi hot keys") { Width = 0, Height = 0, WindowStyle = 0 });
        window.AddHook(Hook);
    }

    public event EventHandler<NaviAction>? Pressed;

    public bool Register(NaviAction action, Shortcut shortcut)
    {
        ArgumentNullException.ThrowIfNull(shortcut);
        if (!TryVirtualKey(shortcut.Key, out var vk))
        {
            ErrorLog.Write($"No virtual key for {shortcut.Display}");
            return false;
        }
        var id = nextId++;
        if (!Native.RegisterHotKey(window.Handle, id, Modifiers(shortcut.Modifiers) | Native.ModNoRepeat, vk))
        {
            ErrorLog.Write($"Could not register {shortcut.Display} (error {Marshal.GetLastPInvokeError()}). Another app may own it.");
            return false;
        }
        registered[id] = action;
        return true;
    }

    public void UnregisterAll()
    {
        foreach (var id in registered.Keys) Native.UnregisterHotKey(window.Handle, id);
        registered.Clear();
    }

    public void Dispose()
    {
        UnregisterAll();
        window.RemoveHook(Hook);
        window.Dispose();
    }

    private static uint Modifiers(KeyModifiers modifiers) =>
        (modifiers.HasFlag(KeyModifiers.Alt) ? Native.ModAlt : 0)
        | (modifiers.HasFlag(KeyModifiers.Ctrl) ? Native.ModControl : 0)
        | (modifiers.HasFlag(KeyModifiers.Shift) ? Native.ModShift : 0)
        | (modifiers.HasFlag(KeyModifiers.Win) ? Native.ModWin : 0);

    private static bool TryVirtualKey(string key, out uint vk)
    {
        vk = key switch
        {
            "PrtSc" => 0x2C,
            "Space" => 0x20,
            _ when key.Length == 1 && char.IsAsciiLetterOrDigit(key[0]) => char.ToUpperInvariant(key[0]),
            _ => 0,
        };
        return vk != 0;
    }

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WmHotKey && registered.TryGetValue(wParam.ToInt32(), out var action))
        {
            handled = true;
            Pressed?.Invoke(this, action);
        }
        return IntPtr.Zero;
    }
}
