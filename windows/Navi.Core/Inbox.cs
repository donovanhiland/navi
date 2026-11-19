using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Navi.Core;

public sealed partial class Inbox
{
    public const int DefaultLimit = 200;

    private readonly ILogger logger;
    private IReadOnlyList<CaptureItem> items = [];

    public Inbox(string directory, int limit = DefaultLimit, ILogger<Inbox>? logger = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        ArgumentOutOfRangeException.ThrowIfNegative(limit);
        Directory = directory;
        Limit = limit;
        this.logger = logger ?? NullLogger<Inbox>.Instance;
        Load();
    }

    public event EventHandler? Changed;

    public string Directory { get; }

    public int Limit { get; }

    public IReadOnlyList<CaptureItem> Items => items;

    private string HistoryPath => Path.Combine(Directory, "history.json");

    private string FilesDirectory => Path.Combine(Directory, "files");

    public CaptureItem? AddText(string text, CaptureKind kind = CaptureKind.Text, string? sourceApp = null, string? sourceBundleId = null, DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (string.IsNullOrWhiteSpace(text)) return null;
        var at = now ?? DateTimeOffset.UtcNow;
        var hash = Hash(Encoding.UTF8.GetBytes(text));
        var existing = Bump(hash, kind, at);
        if (existing is not null) return existing;
        var item = new CaptureItem(Guid.NewGuid(), kind, at, at, 1, false, text, null, sourceApp, sourceBundleId, hash);
        Insert(item);
        return item;
    }

    public CaptureItem? AddFile(byte[] data, string fileExtension, CaptureKind kind, string? sourceApp = null, string? sourceBundleId = null, bool deduplicate = true, DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(data);
        ArgumentException.ThrowIfNullOrWhiteSpace(fileExtension);
        var at = now ?? DateTimeOffset.UtcNow;
        var hash = Hash(data);
        if (deduplicate)
        {
            var existing = Bump(hash, kind, at);
            if (existing is not null) return existing;
        }
        var id = Guid.NewGuid();
        var name = $"{HistoryJson.IdString(id)}.{fileExtension}";
        try
        {
            System.IO.Directory.CreateDirectory(FilesDirectory);
            WriteAtomic(Path.Combine(FilesDirectory, name), data);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LogFileWriteFailed(logger, name, error);
            return null;
        }
        var item = new CaptureItem(id, kind, at, at, 1, false, null, name, sourceApp, sourceBundleId, hash);
        Insert(item);
        return item;
    }

    public bool UpdateFile(Guid id, byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        var item = Find(id);
        var path = item is null ? null : FilePath(item);
        if (item is null || path is null) return false;
        try
        {
            WriteAtomic(path, data);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LogFileWriteFailed(logger, path, error);
            return false;
        }
        Replace(item with { ContentHash = Hash(data) }, sort: false);
        return true;
    }

    public void Touch(Guid id, DateTimeOffset? now = null)
    {
        var item = Find(id);
        if (item is null) return;
        Replace(item with { LastUsedAt = now ?? DateTimeOffset.UtcNow }, sort: true);
    }

    public void TogglePin(Guid id)
    {
        var item = Find(id);
        if (item is null) return;
        var changed = items.Select(x => x.Id == id ? x with { Pinned = !x.Pinned } : x).ToList();
        Commit(Trim(Sorted(changed)));
    }

    public void Remove(Guid id)
    {
        var item = Find(id);
        if (item is null) return;
        DeleteFiles(item);
        Commit(items.Where(x => x.Id != id).ToList());
    }

    public void ClearUnpinned()
    {
        foreach (var item in items.Where(x => !x.Pinned)) DeleteFiles(item);
        Commit(items.Where(x => x.Pinned).ToList());
    }

    public IReadOnlyList<CaptureItem> Search(string query)
    {
        ArgumentNullException.ThrowIfNull(query);
        var trimmed = query.Trim();
        if (trimmed.Length == 0) return items;
        return items.Where(x => Contains(x.Text, trimmed) || Contains(x.SourceApp, trimmed)).ToList();
    }

    public byte[]? FileData(Guid id)
    {
        var item = Find(id);
        var path = item is null ? null : FilePath(item);
        if (path is null || !File.Exists(path)) return null;
        try
        {
            return File.ReadAllBytes(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LogFileReadFailed(logger, path, error);
            return null;
        }
    }

    public string? FilePath(CaptureItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        return item.FileName is null ? null : Path.Combine(FilesDirectory, item.FileName);
    }

    public string PreviewPath(Guid id) => Path.Combine(FilesDirectory, $"{HistoryJson.IdString(id)}.preview.png");

    public string MarkupPath(Guid id) => Path.Combine(FilesDirectory, $"{HistoryJson.IdString(id)}.navi");

    internal static string Hash(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

    private static bool Contains(string? text, string query) =>
        text is not null && CultureInfo.CurrentCulture.CompareInfo.IndexOf(text, query, CompareOptions.IgnoreCase) >= 0;

    private static List<CaptureItem> Sorted(IEnumerable<CaptureItem> list) =>
        list.OrderByDescending(x => x.Pinned).ThenByDescending(x => x.LastUsedAt).ToList();

    private static void WriteAtomic(string path, byte[] data)
    {
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, data);
        File.Move(temp, path, overwrite: true);
    }

    private CaptureItem? Find(Guid id) => items.FirstOrDefault(x => x.Id == id);

    private CaptureItem? Bump(string hash, CaptureKind kind, DateTimeOffset now)
    {
        var existing = items.FirstOrDefault(x => x.ContentHash == hash && x.Kind == kind);
        if (existing is null) return null;
        var bumped = existing with { LastUsedAt = now, CopyCount = existing.CopyCount + 1 };
        Replace(bumped, sort: true);
        return bumped;
    }

    private void Insert(CaptureItem item) => Commit(Trim(Sorted([.. items, item])));

    private void Replace(CaptureItem item, bool sort)
    {
        var changed = items.Select(x => x.Id == item.Id ? item : x);
        Commit(sort ? Sorted(changed) : changed.ToList());
    }

    private List<CaptureItem> Trim(List<CaptureItem> sorted)
    {
        var unpinned = 0;
        var kept = new List<CaptureItem>(sorted.Count);
        foreach (var item in sorted)
        {
            if (item.Pinned || ++unpinned <= Limit)
            {
                kept.Add(item);
            }
            else
            {
                DeleteFiles(item);
            }
        }
        return kept;
    }

    private void Commit(IReadOnlyList<CaptureItem> next)
    {
        items = next;
        Save();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void DeleteFiles(CaptureItem item)
    {
        TryDelete(MarkupPath(item.Id), isDirectory: true);
        TryDelete(PreviewPath(item.Id), isDirectory: false);
        var path = FilePath(item);
        if (path is not null) TryDelete(path, isDirectory: false);
    }

    private void TryDelete(string path, bool isDirectory)
    {
        try
        {
            if (isDirectory && System.IO.Directory.Exists(path)) System.IO.Directory.Delete(path, recursive: true);
            else if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LogDeleteFailed(logger, path, error);
        }
    }

    private void Load()
    {
        if (!File.Exists(HistoryPath)) return;
        try
        {
            items = Sorted(HistoryJson.Decode(File.ReadAllText(HistoryPath)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            LogLoadFailed(logger, HistoryPath, error);
        }
    }

    private void Save()
    {
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            WriteAtomic(HistoryPath, Encoding.UTF8.GetBytes(HistoryJson.Encode(items)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LogSaveFailed(logger, HistoryPath, error);
        }
    }

    [LoggerMessage(Level = LogLevel.Error, Message = "Could not write capture file {Path}")]
    private static partial void LogFileWriteFailed(ILogger logger, string path, Exception error);

    [LoggerMessage(Level = LogLevel.Error, Message = "Could not read capture file {Path}")]
    private static partial void LogFileReadFailed(ILogger logger, string path, Exception error);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Could not delete {Path}")]
    private static partial void LogDeleteFailed(ILogger logger, string path, Exception error);

    [LoggerMessage(Level = LogLevel.Error, Message = "Could not read history {Path}")]
    private static partial void LogLoadFailed(ILogger logger, string path, Exception error);

    [LoggerMessage(Level = LogLevel.Error, Message = "Could not save history {Path}")]
    private static partial void LogSaveFailed(ILogger logger, string path, Exception error);
}
