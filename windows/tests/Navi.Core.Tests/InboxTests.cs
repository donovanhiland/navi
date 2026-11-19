using Navi.Core;

namespace Navi.Core.Tests;

public sealed class InboxTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "NaviTests-" + Guid.NewGuid().ToString("N"));
    private readonly DateTimeOffset start = DateTimeOffset.FromUnixTimeSeconds(1_000_000);

    public void Dispose()
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
    }

    [Fact]
    public void NewestTextComesFirst()
    {
        var inbox = new Inbox(directory);
        inbox.AddText("one", now: start);
        inbox.AddText("two", now: start.AddSeconds(1));
        Assert.Equal(["two", "one"], inbox.Items.Select(x => x.Text));
    }

    [Fact]
    public void BlankTextIsIgnored()
    {
        var inbox = new Inbox(directory);
        Assert.Null(inbox.AddText("  \n "));
        Assert.Empty(inbox.Items);
    }

    [Fact]
    public void DuplicateTextMovesToTopWithoutCopy()
    {
        var inbox = new Inbox(directory);
        var first = inbox.AddText("one", now: start);
        inbox.AddText("two", now: start.AddSeconds(1));
        var again = inbox.AddText("one", now: start.AddSeconds(2));
        Assert.Equal(first!.Id, again!.Id);
        Assert.Equal(["one", "two"], inbox.Items.Select(x => x.Text));
        Assert.Equal(2, inbox.Items[0].CopyCount);
        Assert.Equal(start, inbox.Items[0].CreatedAt);
        Assert.Equal(start.AddSeconds(2), inbox.Items[0].LastUsedAt);
    }

    [Fact]
    public void PasteMovesItemToTopWithoutCountingACopy()
    {
        var inbox = new Inbox(directory);
        var first = inbox.AddText("one", now: start)!;
        inbox.AddText("two", now: start.AddSeconds(1));
        inbox.Touch(first.Id, start.AddSeconds(2));
        Assert.Equal(["one", "two"], inbox.Items.Select(x => x.Text));
        Assert.Equal(1, inbox.Items[0].CopyCount);
    }

    [Fact]
    public void PinnedItemsStayOnTopAndSurviveTheLimit()
    {
        var inbox = new Inbox(directory, limit: 2);
        var pinned = inbox.AddText("keep", now: start)!;
        inbox.TogglePin(pinned.Id);
        inbox.AddText("a", now: start.AddSeconds(1));
        inbox.AddText("b", now: start.AddSeconds(2));
        inbox.AddText("c", now: start.AddSeconds(3));
        Assert.Equal(["keep", "c", "b"], inbox.Items.Select(x => x.Text));
    }

    [Fact]
    public void SearchIgnoresCase()
    {
        var inbox = new Inbox(directory);
        inbox.AddText("Hello World", now: start);
        inbox.AddText("other", now: start.AddSeconds(1));
        Assert.Equal(["Hello World"], inbox.Search("hello").Select(x => x.Text));
        Assert.Equal(2, inbox.Search("").Count);
    }

    [Fact]
    public void HistorySurvivesRestart()
    {
        var inbox = new Inbox(directory);
        inbox.AddText("saved", now: start);
        var reopened = new Inbox(directory);
        Assert.Equal(["saved"], reopened.Items.Select(x => x.Text));
    }

    [Fact]
    public void RemovingAnImageDeletesItsFile()
    {
        var inbox = new Inbox(directory);
        var item = inbox.AddFile([1, 2, 3], "png", CaptureKind.Image)!;
        var path = inbox.FilePath(item)!;
        Assert.True(File.Exists(path));
        inbox.Remove(item.Id);
        Assert.False(File.Exists(path));
        Assert.Empty(inbox.Items);
    }

    [Fact]
    public void ClearKeepsPinnedItems()
    {
        var inbox = new Inbox(directory);
        var pinned = inbox.AddText("keep", now: start)!;
        inbox.TogglePin(pinned.Id);
        inbox.AddText("drop", now: start.AddSeconds(1));
        inbox.ClearUnpinned();
        Assert.Equal(["keep"], inbox.Items.Select(x => x.Text));
    }

    [Fact]
    public void UpdatingAFileKeepsTheItemAndRemovingDeletesMarkup()
    {
        var inbox = new Inbox(directory);
        var item = inbox.AddFile([1, 2, 3], "png", CaptureKind.Screenshot)!;
        Assert.True(inbox.UpdateFile(item.Id, [4, 5]));
        Assert.Equal([4, 5], File.ReadAllBytes(inbox.FilePath(item)!));
        Assert.Equal(item.Id, inbox.Items[0].Id);
        Assert.NotEqual(item.ContentHash, inbox.Items[0].ContentHash);

        var markup = inbox.MarkupPath(item.Id);
        Directory.CreateDirectory(markup);
        inbox.Remove(item.Id);
        Assert.False(Directory.Exists(markup));
    }

    [Fact]
    public void CapturesOfTheSamePixelsStaySeparateWhenNotDeduplicated()
    {
        var inbox = new Inbox(directory);
        var first = inbox.AddFile([9, 9], "png", CaptureKind.Screenshot, deduplicate: false, now: start)!;
        var second = inbox.AddFile([9, 9], "png", CaptureKind.Screenshot, deduplicate: false, now: start.AddSeconds(1))!;
        Assert.NotEqual(first.Id, second.Id);
        Assert.Equal(2, inbox.Items.Count);
    }

    [Fact]
    public void FileNamesUseUppercaseIdsLikeTheMac()
    {
        var inbox = new Inbox(directory);
        var item = inbox.AddFile([1], "png", CaptureKind.Image)!;
        Assert.Equal(HistoryJson.IdString(item.Id) + ".png", item.FileName);
    }

    [Fact]
    public void ChangedFiresOnEveryChange()
    {
        var inbox = new Inbox(directory);
        var count = 0;
        inbox.Changed += (_, _) => count++;
        var item = inbox.AddText("one", now: start)!;
        inbox.TogglePin(item.Id);
        inbox.Remove(item.Id);
        Assert.Equal(3, count);
    }

    [Fact]
    public void BrokenHistoryFileStartsEmpty()
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "history.json"), "{ not json");
        var inbox = new Inbox(directory);
        Assert.Empty(inbox.Items);
    }
}
