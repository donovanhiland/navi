using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Navi.Core;

public static class HistoryJson
{
    public static readonly DateTimeOffset AppleReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public static double ToAppleSeconds(DateTimeOffset date) => (date - AppleReferenceDate).TotalSeconds;

    public static DateTimeOffset FromAppleSeconds(double seconds) => AppleReferenceDate.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond));

    public static string Encode(IEnumerable<CaptureItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        var records = items.Select(ToRecord).ToList();
        return JsonSerializer.Serialize(records, Options);
    }

    public static IReadOnlyList<CaptureItem> Decode(string json)
    {
        var records = JsonSerializer.Deserialize<List<HistoryRecord>>(json, Options)
            ?? throw new JsonException("history.json holds no list.");
        return records.Select(FromRecord).ToList();
    }

    public static string KindName(CaptureKind kind) => kind switch
    {
        CaptureKind.Text => "text",
        CaptureKind.Image => "image",
        CaptureKind.Screenshot => "screenshot",
        CaptureKind.Recording => "recording",
        CaptureKind.Dictation => "dictation",
        CaptureKind.File => "file",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown capture kind."),
    };

    public static CaptureKind ParseKind(string name) => name switch
    {
        "text" => CaptureKind.Text,
        "image" => CaptureKind.Image,
        "screenshot" => CaptureKind.Screenshot,
        "recording" => CaptureKind.Recording,
        "dictation" => CaptureKind.Dictation,
        "file" => CaptureKind.File,
        _ => throw new JsonException($"Unknown capture kind \"{name}\"."),
    };

    public static string IdString(Guid id) => id.ToString("D", CultureInfo.InvariantCulture).ToUpperInvariant();

    private static HistoryRecord ToRecord(CaptureItem item) => new(
        IdString(item.Id),
        KindName(item.Kind),
        ToAppleSeconds(item.CreatedAt),
        ToAppleSeconds(item.LastUsedAt),
        item.CopyCount,
        item.Pinned,
        item.Text,
        item.FileName,
        item.SourceApp,
        item.SourceBundleId,
        item.ContentHash);

    private static CaptureItem FromRecord(HistoryRecord record)
    {
        if (string.IsNullOrEmpty(record.Id) || !Guid.TryParse(record.Id, out var id))
        {
            throw new JsonException($"Item has a bad id \"{record.Id}\".");
        }
        if (record.Kind is null) throw new JsonException($"Item {record.Id} has no kind.");
        if (record.CreatedAt is not { } created) throw new JsonException($"Item {record.Id} has no createdAt.");
        if (record.Pinned is not { } pinned) throw new JsonException($"Item {record.Id} has no pinned.");
        if (record.ContentHash is null) throw new JsonException($"Item {record.Id} has no contentHash.");
        var createdAt = FromAppleSeconds(created);
        return new CaptureItem(
            id,
            ParseKind(record.Kind),
            createdAt,
            record.LastUsedAt is { } used ? FromAppleSeconds(used) : createdAt,
            record.CopyCount ?? 1,
            pinned,
            record.Text,
            record.FileName,
            record.SourceApp,
            record.SourceBundleId,
            record.ContentHash);
    }

    private sealed record HistoryRecord(
        string? Id,
        string? Kind,
        double? CreatedAt,
        double? LastUsedAt,
        int? CopyCount,
        bool? Pinned,
        string? Text,
        string? FileName,
        string? SourceApp,
        [property: JsonPropertyName("sourceBundleID")] string? SourceBundleId,
        string? ContentHash);
}
