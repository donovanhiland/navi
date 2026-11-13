import Foundation
import Testing
@testable import NaviCore

@MainActor
final class InboxTests {
    private var opened: [Inbox] = []
    let directory = FileManager.default.temporaryDirectory.appending(path: "NaviTests-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_000_000)

    isolated deinit {
        opened.forEach { $0.flush() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func make(
        directory: URL, limit: Int = 200, dictationLimit: Int = 200, beforeDeleting: (@Sendable () -> Void)? = nil
    ) -> Inbox {
        let inbox = Inbox(directory: directory, limit: limit, dictationLimit: dictationLimit, beforeDeleting: beforeDeleting)
        opened.append(inbox)
        return inbox
    }

    @Test func newestTextComesFirst() {
        let inbox = make(directory: directory)
        inbox.add(text: "one", now: start)
        inbox.add(text: "two", now: start + 1)
        #expect(inbox.items.map(\.text) == ["two", "one"])
    }

    @Test func blankTextIsIgnored() {
        let inbox = make(directory: directory)
        #expect(inbox.add(text: "  \n ") == nil)
        #expect(inbox.items.isEmpty)
    }

    @Test func duplicateTextMovesToTopWithoutCopy() {
        let inbox = make(directory: directory)
        let first = inbox.add(text: "one", now: start)
        inbox.add(text: "two", now: start + 1)
        let again = inbox.add(text: "one", now: start + 2)
        #expect(again?.id == first?.id)
        #expect(inbox.items.map(\.text) == ["one", "two"])
        #expect(inbox.items[0].copyCount == 2)
        #expect(inbox.items[0].createdAt == start)
        #expect(inbox.items[0].lastUsedAt == start + 2)
    }

    @Test func pasteMovesItemToTopWithoutCountingACopy() throws {
        let inbox = make(directory: directory)
        let first = try #require(inbox.add(text: "one", now: start))
        inbox.add(text: "two", now: start + 1)
        inbox.touch(first.id, now: start + 2)
        #expect(inbox.items.map(\.text) == ["one", "two"])
        #expect(inbox.items[0].copyCount == 1)
    }

    @Test func readsHistoryFromBeforeCopyCounts() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = """
        [{"id":"\(UUID().uuidString)","kind":"text","createdAt":0,"pinned":false,"text":"old","contentHash":"x"}]
        """
        try Data(old.utf8).write(to: directory.appending(path: "history.json"))
        let inbox = make(directory: directory)
        #expect(inbox.items.first?.copyCount == 1)
        #expect(inbox.items.first?.lastUsedAt == inbox.items.first?.createdAt)
    }

    @Test func pinnedItemsStayOnTopAndSurviveTheLimit() throws {
        let inbox = make(directory: directory, limit: 2)
        let pinned = try #require(inbox.add(text: "keep", now: start))
        inbox.togglePin(pinned.id)
        inbox.add(text: "a", now: start + 1)
        inbox.add(text: "b", now: start + 2)
        inbox.add(text: "c", now: start + 3)
        #expect(inbox.items.map(\.text) == ["keep", "c", "b"])
    }

    @Test func dictationsHaveTheirOwnLimit() {
        let inbox = make(directory: directory, limit: 2, dictationLimit: 1)
        inbox.add(text: "clip a", now: start)
        inbox.add(text: "clip b", now: start + 1)
        inbox.add(text: "said one", kind: .dictation, now: start + 2)
        inbox.add(text: "said two", kind: .dictation, now: start + 3)
        #expect(inbox.items.map(\.text) == ["said two", "clip b", "clip a"])
    }

    @Test func searchIgnoresCase() {
        let inbox = make(directory: directory)
        inbox.add(text: "Hello World", now: start)
        inbox.add(text: "other", now: start + 1)
        #expect(inbox.search("hello").map(\.text) == ["Hello World"])
        #expect(inbox.search("").count == 2)
    }

    @Test func historySurvivesRestart() {
        let inbox = make(directory: directory)
        inbox.add(text: "saved", now: start)
        inbox.flush()
        let reopened = make(directory: directory)
        #expect(reopened.items.map(\.text) == ["saved"])
    }

    @Test func removingAnImageDeletesItsFile() throws {
        let inbox = make(directory: directory)
        let item = try #require(inbox.add(fileData: Data([1, 2, 3]), fileExtension: "png", kind: .image))
        let url = try #require(inbox.fileURL(for: item))
        #expect(FileManager.default.fileExists(atPath: url.path))
        inbox.remove(item.id)
        inbox.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(inbox.items.isEmpty)
    }

    @Test func clearKeepsPinnedItems() throws {
        let inbox = make(directory: directory)
        let pinned = try #require(inbox.add(text: "keep", now: start))
        inbox.togglePin(pinned.id)
        inbox.add(text: "drop", now: start + 1)
        inbox.clearUnpinned()
        #expect(inbox.items.map(\.text) == ["keep"])
    }

    @Test func updatingAFileKeepsTheItemAndRemovingDeletesMarkup() throws {
        let inbox = make(directory: directory)
        let item = try #require(inbox.add(fileData: Data([1, 2, 3]), fileExtension: "png", kind: .screenshot))
        #expect(inbox.updateFile(item.id, data: Data([4, 5])))
        let url = try #require(inbox.fileURL(for: item))
        #expect(try Data(contentsOf: url) == Data([4, 5]))
        #expect(inbox.items.first?.id == item.id)
        #expect(inbox.items.first?.contentHash != item.contentHash)

        let markup = inbox.markupURL(for: item.id)
        try FileManager.default.createDirectory(at: markup, withIntermediateDirectories: true)
        inbox.remove(item.id)
        inbox.flush()
        #expect(!FileManager.default.fileExists(atPath: markup.path))
    }

    @Test func sameCaptureTwiceMakesTwoItemsWhenNotDeduplicated() throws {
        let inbox = make(directory: directory)
        let png = Data([1, 2, 3])
        let first = try #require(inbox.add(fileData: png, fileExtension: "png", kind: .screenshot, deduplicate: false, now: start))
        let second = try #require(inbox.add(fileData: png, fileExtension: "png", kind: .screenshot, deduplicate: false, now: start + 1))
        #expect(first.id != second.id)
        #expect(inbox.items.map(\.id) == [second.id, first.id])
        #expect(inbox.fileData(for: second.id) == png)
    }

    @Test func sameFileTwiceIsDeduplicatedByDefault() throws {
        let inbox = make(directory: directory)
        let first = try #require(inbox.add(fileData: Data([1, 2, 3]), fileExtension: "png", kind: .image, now: start))
        let again = try #require(inbox.add(fileData: Data([1, 2, 3]), fileExtension: "png", kind: .image, now: start + 1))
        #expect(again.id == first.id)
        #expect(inbox.items.count == 1)
    }

    private func diskItems() throws -> [CaptureItem] {
        try JSONDecoder().decode([CaptureItem].self, from: Data(contentsOf: directory.appending(path: "history.json")))
    }

    @Test func flushWritesFileThatRoundTrips() throws {
        let inbox = make(directory: directory)
        inbox.add(text: "one", now: start)
        inbox.flush()
        #expect(try diskItems() == inbox.items)
    }

    @Test func rapidAddsThenFlushMatchMemory() throws {
        let inbox = make(directory: directory, limit: 1000)
        for index in 0..<300 { inbox.add(text: "item \(index)", now: start + Double(index)) }
        inbox.flush()
        #expect(inbox.items.count == 300)
        #expect(try diskItems() == inbox.items)
        #expect(make(directory: directory, limit: 1000).items == inbox.items)
    }

    @Test func removeAfterAddsFlushesLatestState() throws {
        let inbox = make(directory: directory)
        let first = inbox.add(text: "one", now: start)
        inbox.add(text: "two", now: start + 1)
        inbox.remove(first!.id)
        inbox.flush()
        #expect(try diskItems().map(\.text) == ["two"])
    }

    @Test func imageFileExistsOnDiskAfterFlush() throws {
        let inbox = make(directory: directory)
        let item = try #require(inbox.add(fileData: Data([1, 2, 3]), fileExtension: "png", kind: .screenshot))
        inbox.flush()
        let reopened = make(directory: directory)
        #expect(reopened.items == inbox.items)
        #expect(reopened.fileData(for: item.id) == Data([1, 2, 3]))
    }

    @Test func removedFileIsDeletedAndNotReferenced() throws {
        let inbox = make(directory: directory)
        let item = try #require(inbox.add(fileData: Data([9]), fileExtension: "png", kind: .screenshot))
        let url = try #require(inbox.fileURL(for: item))
        inbox.remove(item.id)
        inbox.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try diskItems().isEmpty)
    }

    @Test func filesOfAFailedSaveAreDeletedByTheNextSave() throws {
        let inbox = make(directory: directory)
        let item = try #require(inbox.add(fileData: Data([9]), fileExtension: "png", kind: .screenshot))
        let url = try #require(inbox.fileURL(for: item))
        inbox.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        inbox.remove(item.id)
        inbox.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        inbox.add(text: "next", now: start)
        inbox.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fileIsDeletedOnlyAfterJSONIsWritten() throws {
        let probe = Probe()
        let inbox = make(directory: directory, beforeDeleting: { probe.check() })
        let item = try #require(inbox.add(fileData: Data([9]), fileExtension: "png", kind: .screenshot))
        inbox.flush()
        let url = try #require(inbox.fileURL(for: item))
        probe.watch(directory: directory, file: url)
        inbox.remove(item.id)
        inbox.flush()
        let seen = probe.observations
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0.fileStillExists && !$0.jsonReferencesFile })
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func addRemoveBurstsLeaveDiskEqualToMemory() throws {
        let inbox = make(directory: directory, limit: 5)
        for index in 0..<60 {
            let item = inbox.add(fileData: Data([UInt8(index)]), fileExtension: "png", kind: .screenshot,
                                 deduplicate: false, now: start + Double(index))
            if index % 3 == 0, let item { inbox.remove(item.id) }
        }
        inbox.flush()
        #expect(try diskItems() == inbox.items)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "files").path)
        #expect(Set(files) == Set(inbox.items.compactMap(\.fileName)))
    }
}

private final class Probe: @unchecked Sendable {
    struct Observation { var fileStillExists: Bool, jsonReferencesFile: Bool }
    private let lock = NSLock()
    private var target: (directory: URL, file: URL)?
    private var seen: [Observation] = []

    var observations: [Observation] { lock.withLock { seen } }

    func watch(directory: URL, file: URL) { lock.withLock { target = (directory, file) } }

    func check() {
        lock.lock()
        defer { lock.unlock() }
        guard let target else { return }
        let data = (try? Data(contentsOf: target.directory.appending(path: "history.json"))) ?? Data()
        let items = (try? JSONDecoder().decode([CaptureItem].self, from: data)) ?? []
        seen.append(Observation(
            fileStillExists: FileManager.default.fileExists(atPath: target.file.path),
            jsonReferencesFile: items.contains { $0.fileName == target.file.lastPathComponent }
        ))
    }
}

@MainActor
struct InboxFastPathTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "NaviTests-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func sha(_ text: String) -> String {
        Inbox.hashForTesting(text)
    }

    @Test func largeTextGetsItsHashAfterTheBackgroundHashLands() async throws {
        let inbox = Inbox(directory: directory)
        let big = String(repeating: "Привет мир ", count: 30_000)
        #expect(big.utf8.count > Inbox.deferredHashLimit)
        let item = try #require(inbox.add(text: big, now: start))
        #expect(item.contentHash.isEmpty)
        while inbox.items[0].contentHash.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(inbox.items[0].contentHash == sha(big))
        inbox.flush()
        let reloaded = Inbox(directory: directory)
        #expect(reloaded.items[0].contentHash == sha(big))
    }

    @Test func flushResolvesAHashThatIsStillPending() throws {
        let inbox = Inbox(directory: directory)
        let big = String(repeating: "abc ", count: 100_000)
        _ = try #require(inbox.add(text: big, now: start))
        inbox.flush()
        let reloaded = Inbox(directory: directory)
        #expect(reloaded.items[0].contentHash == sha(big))
    }

    @Test func largeTextCopiedAgainMovesToTheTopWithoutADuplicate() throws {
        let inbox = Inbox(directory: directory)
        let big = String(repeating: "abc ", count: 100_000)
        let first = try #require(inbox.add(text: big, now: start))
        inbox.add(text: "small", now: start + 1)
        let again = try #require(inbox.add(text: big, now: start + 2))
        #expect(again.id == first.id)
        #expect(inbox.items.map(\.text?.count) == [big.count, 5])
        #expect(inbox.items[0].copyCount == 2)
        inbox.add(text: big + "x", now: start + 3)
        #expect(inbox.items.count == 3)
    }

    @Test func movingItemsMatchesAFullStableSort() throws {
        var generator = SystemRandomNumberGenerator()
        let inbox = Inbox(directory: directory, limit: 1000)
        var ids: [UUID] = []
        for index in 0..<60 {
            ids.append(try #require(inbox.add(text: "item \(index)", now: start + Double(index % 7))?.id))
        }
        for round in 0..<400 {
            let id = ids.randomElement(using: &generator)!
            switch round % 3 {
            case 0: inbox.touch(id, now: start + Double(Int.random(in: 0..<12, using: &generator)))
            case 1: inbox.togglePin(id)
            default: inbox.add(text: "item \(ids.firstIndex(of: id)!)", now: start + Double(Int.random(in: 0..<12, using: &generator)))
            }
            let expected = inbox.items.enumerated().sorted { lhs, rhs in
                if lhs.element.pinned != rhs.element.pinned { return lhs.element.pinned }
                return lhs.element.lastUsedAt > rhs.element.lastUsedAt
            }.map(\.element.id)
            #expect(inbox.items.map(\.id) == expected, "round \(round)")
        }
    }

    @Test func asciiFoldMatchesTheSystemFold() {
        let all = String(decoding: (0..<128).map { UInt8($0) }, as: UTF8.self)
        let samples = [all, "The QUICK brown Fox 0123 JUMPS ~!@#", "", "Z", "aZ[`{@"]
        for sample in samples {
            #expect(String(decoding: SearchCache.fold(sample), as: UTF8.self) == SearchCache.foldedWithFoundation(string: sample))
        }
    }

    @Test func searchKernelAgreesWithMemmem() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcab ")
        for _ in 0..<2000 {
            let hay = (0..<Int.random(in: 0..<80, using: &generator)).map { _ in UInt8(ascii: Unicode.Scalar(String(alphabet.randomElement(using: &generator)!))!) }
            let needle = (0..<Int.random(in: 1..<6, using: &generator)).map { _ in UInt8(ascii: Unicode.Scalar(String(alphabet.randomElement(using: &generator)!))!) }
            let expected = hay.withUnsafeBytes { h in needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil } }
            let found = hay.withUnsafeBufferPointer { h in needle.withUnsafeBufferPointer { n in
                SearchKernel.contains(h.baseAddress ?? UnsafePointer(bitPattern: 1)!, h.count, n.baseAddress!, n.count)
            } }
            #expect(found == expected)
        }
    }
}
