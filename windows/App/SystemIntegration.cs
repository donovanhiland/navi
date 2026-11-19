using System.IO;
using System.Diagnostics;
using System.Security;
using Microsoft.Win32;
using Navi.Core;

namespace Navi.App;

public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void Apply(bool enabled)
    {
        var name = NaviPaths.AppName(Program.IsDev);
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (enabled && Environment.ProcessPath is { } exe) key.SetValue(name, $"\"{exe}\"");
            else key.DeleteValue(name, throwOnMissingValue: false);
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
        {
            ErrorLog.Write($"Could not change Start with Windows: {error.Message}");
        }
    }
}

public static class MicrophoneAccess
{
    private const string ConsentKey = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    public static bool IsAllowed()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(ConsentKey);
            return !string.Equals(key?.GetValue("Value") as string, "Deny", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
        {
            ErrorLog.Write($"Could not read microphone access: {error.Message}");
            return false;
        }
    }

    public static void OpenSettings() => Shell.Open("ms-settings:privacy-microphone");
}

public static class Shell
{
    public static void Open(string target)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            ErrorLog.Write($"Could not open {target}: {error.Message}");
        }
    }
}
