namespace Navi.Core;

public enum CaptureKind
{
    Text,
    Image,
    Screenshot,
    Recording,
    Dictation,
    File,
}

public sealed record CaptureItem(
    Guid Id,
    CaptureKind Kind,
    DateTimeOffset CreatedAt,
    DateTimeOffset LastUsedAt,
    int CopyCount,
    bool Pinned,
    string? Text,
    string? FileName,
    string? SourceApp,
    string? SourceBundleId,
    string ContentHash);
