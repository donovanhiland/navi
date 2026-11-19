using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Navi.Core;

public enum TalkKey
{
    RightAlt,
    RightCtrl,
}

public sealed record NaviSettings
{
    public bool CopyToClipboard { get; init; } = true;
    public bool EditAfterCapture { get; init; }
    public bool HideDesktopIcons { get; init; }
    public bool BorrowScreenshotKeys { get; init; } = true;
    public ShortcutStyle ShortcutStyle { get; init; } = ShortcutStyle.Windows;
    public bool TalkToType { get; init; } = true;
    public TalkKey TalkKey { get; init; } = TalkKey.RightAlt;
    public bool TapToStartAndStop { get; init; }
    public bool ShowWordsWhileTalking { get; init; } = true;
    public bool KeepMicrophoneReady { get; init; }
    public bool BetterCleanup { get; init; }
    public bool StartWithWindows { get; init; } = true;
    public string? SaveFolder { get; init; }
}

public sealed partial class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly ILogger logger;

    public SettingsStore(string directory, ILogger<SettingsStore>? logger = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        Path = System.IO.Path.Combine(directory, "settings.json");
        this.logger = logger ?? NullLogger<SettingsStore>.Instance;
        Current = Load();
    }

    public event EventHandler<NaviSettings>? Changed;

    public string Path { get; }

    public NaviSettings Current { get; private set; }

    public void Update(Func<NaviSettings, NaviSettings> change)
    {
        ArgumentNullException.ThrowIfNull(change);
        var next = change(Current);
        if (next == Current) return;
        Current = next;
        Save();
        Changed?.Invoke(this, next);
    }

    private NaviSettings Load()
    {
        if (!File.Exists(Path)) return new NaviSettings();
        try
        {
            return JsonSerializer.Deserialize<NaviSettings>(File.ReadAllText(Path), Options) ?? new NaviSettings();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            LogLoadFailed(logger, Path, error);
            return new NaviSettings();
        }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            var temp = Path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(Current, Options));
            File.Move(temp, Path, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LogSaveFailed(logger, Path, error);
        }
    }

    [LoggerMessage(Level = LogLevel.Error, Message = "Could not read settings {Path}")]
    private static partial void LogLoadFailed(ILogger logger, string path, Exception error);

    [LoggerMessage(Level = LogLevel.Error, Message = "Could not save settings {Path}")]
    private static partial void LogSaveFailed(ILogger logger, string path, Exception error);
}
