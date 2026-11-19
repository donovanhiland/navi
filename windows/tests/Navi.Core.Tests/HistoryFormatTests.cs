using System.Text.Json;
using Navi.Core;

namespace Navi.Core.Tests;

public sealed class HistoryFormatTests
{
    private static readonly string Fixture = Path.Combine(AppContext.BaseDirectory, "shared-fixtures", "history", "history.json");
    private static readonly string WrittenByWindows = Path.Combine(AppContext.BaseDirectory, "shared-fixtures", "history", "written-by-windows.json");

    [Fact]
    public void ReadsTheSharedMacHistoryFixture()
    {
        var items = HistoryJson.Decode(File.ReadAllText(Fixture));
        Assert.Equal(5, items.Count);
        Assert.Equal(CaptureKind.Screenshot, items[0].Kind);
        Assert.True(items[0].Pinned);
        Assert.Equal(784_000_000.25, HistoryJson.ToAppleSeconds(items[0].CreatedAt));
        Assert.Equal("com.apple.Safari", items[0].SourceBundleId);
        Assert.Equal("Hello from the Mac\nsecond line", items[1].Text);
        Assert.Equal(3, items[1].CopyCount);
        Assert.Equal(CaptureKind.Dictation, items[2].Kind);
        Assert.Equal(1, items[3].CopyCount);
        Assert.Equal(items[3].CreatedAt, items[3].LastUsedAt);
        Assert.Equal(CaptureKind.File, items[4].Kind);
        Assert.Equal("report \"final\".pdf", items[4].Text);
    }

    [Fact]
    public void WritesTheCommittedWindowsFixtureByteForByte()
    {
        var items = HistoryJson.Decode(File.ReadAllText(Fixture));
        Assert.Equal(File.ReadAllText(WrittenByWindows).TrimEnd('\n'), HistoryJson.Encode(items));
    }

    [Fact]
    public void AppleSecondsCountFrom2001()
    {
        Assert.Equal(new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero), HistoryJson.FromAppleSeconds(0));
        Assert.Equal(978_307_200, HistoryJson.AppleReferenceDate.ToUnixTimeSeconds());
    }

    [Fact]
    public void WritesTheSameShapeTheMacWrites()
    {
        var id = Guid.Parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8");
        var at = HistoryJson.FromAppleSeconds(784_000_050);
        var item = new CaptureItem(id, CaptureKind.Text, at, at, 1, false, "hi", null, null, "com.example.App", "abc");
        using var doc = JsonDocument.Parse(HistoryJson.Encode([item]));
        var o = doc.RootElement[0];
        Assert.Equal("6BA7B810-9DAD-11D1-80B4-00C04FD430C8", o.GetProperty("id").GetString());
        Assert.Equal("text", o.GetProperty("kind").GetString());
        Assert.Equal(JsonValueKind.Number, o.GetProperty("createdAt").ValueKind);
        Assert.Equal(784_000_050, o.GetProperty("createdAt").GetDouble());
        Assert.Equal("com.example.App", o.GetProperty("sourceBundleID").GetString());
        Assert.False(o.TryGetProperty("fileName", out _));
        Assert.False(o.TryGetProperty("sourceApp", out _));
        Assert.Equal(
            ["id", "kind", "createdAt", "lastUsedAt", "copyCount", "pinned", "text", "sourceBundleID", "contentHash"],
            o.EnumerateObject().Select(p => p.Name));
    }

    [Fact]
    public void RoundTripsTheFixture()
    {
        var items = HistoryJson.Decode(File.ReadAllText(Fixture));
        var again = HistoryJson.Decode(HistoryJson.Encode(items));
        Assert.Equal(items, again);
    }

    [Fact]
    public void RejectsAnUnknownKind()
    {
        const string json = """[{"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","kind":"hologram","createdAt":0,"pinned":false,"contentHash":"x"}]""";
        Assert.Throws<JsonException>(() => HistoryJson.Decode(json));
    }

    [Fact]
    public void HashIsLowercaseSha256LikeTheMac()
    {
        Assert.Equal("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", Inbox.Hash("test"u8.ToArray()));
    }
}
