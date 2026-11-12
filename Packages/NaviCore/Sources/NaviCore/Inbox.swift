import CryptoKit
import Foundation
import Observation
import os

@MainActor
@Observable
public final class Inbox {
    public private(set) var items: [CaptureItem] = [] {
        didSet { itemsVersion &+= 1 }
    }
    @ObservationIgnored public private(set) var itemsVersion = 0
    public let directory: URL
    public var limit: Int

    @ObservationIgnored private let writer: HistoryWriter
    @ObservationIgnored private var doomedFiles: [URL] = []
    @ObservationIgnored private var searchCache = SearchCache()
    @ObservationIgnored var searchBudget: Duration = .milliseconds(6)
    public private(set) var searchKeysVersion = 0
    @ObservationIgnored public private(set) var deferredSearchItems = 0
    @ObservationIgnored private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Inbox")

    public static var defaultDirectory: URL {
        let name = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Navi Dev" : "Navi"
        return URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    public convenience init(directory: URL = Inbox.defaultDirectory, limit: Int = 200) {
        self.init(directory: directory, limit: limit, beforeDeleting: nil)
    }

    init(directory: URL, limit: Int, beforeDeleting: (@Sendable () -> Void)?) {
        self.directory = directory
        self.limit = limit
        self.writer = HistoryWriter(directory: directory, beforeDeleting: beforeDeleting)
        load()
        warmSearch(items)
    }

    public func flush() {
        writer.flush()
    }

    @discardableResult
    public func add(
        text: String, kind: CaptureKind = .text, sourceApp: String? = nil, sourceBundleID: String? = nil, now: Date = .now
    ) -> CaptureItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hash = Self.hash(Data(text.utf8))
        if let existing = bump(hash: hash, kind: kind, now: now) { return existing }
        let item = CaptureItem(
            id: UUID(), kind: kind, createdAt: now, lastUsedAt: now, copyCount: 1, pinned: false,
            text: text, fileName: nil, sourceApp: sourceApp, sourceBundleID: sourceBundleID, contentHash: hash
        )
        insert(item)
        return item
    }

    @discardableResult
    public func add(
        fileData: Data, fileExtension: String, kind: CaptureKind,
        sourceApp: String? = nil, sourceBundleID: String? = nil, deduplicate: Bool = true, now: Date = .now
    ) -> CaptureItem? {
        let hash = Self.hash(fileData)
        if deduplicate, let existing = bump(hash: hash, kind: kind, now: now) { return existing }
        let id = UUID()
        let name = "\(id.uuidString).\(fileExtension)"
        do {
            try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            try fileData.write(to: filesDirectory.appending(path: name), options: .atomic)
        } catch {
            logger.error("Could not write capture file: \(error.localizedDescription)")
            return nil
        }
        let item = CaptureItem(
            id: id, kind: kind, createdAt: now, lastUsedAt: now, copyCount: 1, pinned: false,
            text: nil, fileName: name, sourceApp: sourceApp, sourceBundleID: sourceBundleID, contentHash: hash
        )
        insert(item)
        return item
    }

    @discardableResult
    public func updateFile(_ id: UUID, data: Data) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let url = fileURL(for: items[index])
        else { return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not update capture file: \(error.localizedDescription)")
            return false
        }
        items[index].contentHash = Self.hash(data)
        save()
        return true
    }

    public func touch(_ id: UUID, now: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastUsedAt = now
        sortAndSave()
    }

    public func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        trimSortAndSave()
    }

    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        discard(items[index])
        items.remove(at: index)
        save()
    }

    public func clearUnpinned() {
        for item in items where !item.pinned { discard(item) }
        items.removeAll { !$0.pinned }
        save()
    }

    public func search(_ query: String) -> [CaptureItem] {
        _ = searchKeysVersion
        let items = self.items
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        let found = searchCache.search(query, in: items, budget: searchBudget)
        deferredSearchItems = found.deferred
        return found.items
    }

    public var isSearchReady: Bool { searchCache.covers(items) }

    public func fileData(for id: UUID) -> Data? {
        guard let item = items.first(where: { $0.id == id }), let url = fileURL(for: item) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func fileURL(for item: CaptureItem) -> URL? {
        item.fileName.map { filesDirectory.appending(path: $0) }
    }

    public func previewURL(for id: UUID) -> URL {
        filesDirectory.appending(path: "\(id.uuidString).preview.png")
    }

    public func markupURL(for id: UUID) -> URL {
        filesDirectory.appending(path: "\(id.uuidString).navi", directoryHint: .isDirectory)
    }

    private var historyURL: URL { directory.appending(path: "history.json") }
    private var filesDirectory: URL { directory.appending(path: "files", directoryHint: .isDirectory) }

    private func bump(hash: String, kind: CaptureKind, now: Date) -> CaptureItem? {
        guard let index = items.firstIndex(where: { $0.contentHash == hash && $0.kind == kind }) else { return nil }
        items[index].lastUsedAt = now
        items[index].copyCount += 1
        let item = items[index]
        sortAndSave()
        return item
    }

    private func insert(_ item: CaptureItem) {
        let index = items.firstIndex { !$0.pinned && $0.lastUsedAt < item.lastUsedAt } ?? items.count
        items.insert(item, at: index)
        if (item.text?.utf8.count ?? 0) <= Self.inlineKeyLimit {
            searchCache.prepare(item)
        } else {
            warmSearch([item])
        }
        trimAndSave()
    }

    private func sortAndSave() {
        sort()
        save()
    }

    private func trimSortAndSave() {
        sort()
        trimAndSave()
    }

    private func trimAndSave() {
        var unpinnedCount = 0
        var kept: [CaptureItem] = []
        for item in items {
            if item.pinned {
                kept.append(item)
                continue
            }
            unpinnedCount += 1
            if unpinnedCount <= limit {
                kept.append(item)
            } else {
                discard(item)
            }
        }
        items = kept
        save()
    }

    private func sort() {
        items.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
    }

    private func discard(_ item: CaptureItem) {
        searchCache.remove(item.id)
        doomedFiles.append(markupURL(for: item.id))
        doomedFiles.append(previewURL(for: item.id))
        if let url = fileURL(for: item) { doomedFiles.append(url) }
    }

    nonisolated static let inlineKeyLimit = 16 * 1024

    private func warmSearch(_ items: [CaptureItem]) {
        let snapshot = items.map { ($0.id, $0.text, $0.sourceApp) }
        guard !snapshot.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let chunk = 500
            var start = 0
            while start < snapshot.count {
                var built: [UUID: SearchCache.Key] = [:]
                for (id, text, sourceApp) in snapshot[start..<min(start + chunk, snapshot.count)] {
                    built[id] = SearchCache.makeKey(text: text, sourceApp: sourceApp)
                }
                guard let self else { return }
                await self.installSearchKeys(built)
                start += chunk
            }
        }
    }

    var searchKeyCount: Int { searchCache.keys.count }

    private func installSearchKeys(_ built: [UUID: SearchCache.Key]) {
        searchCache.install(built, for: items)
        searchKeysVersion += 1
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        do {
            items = try CaptureItem.decodeHistory(from: data)
            sort()
        } catch {
            logger.error("Could not read history: \(error.localizedDescription)")
        }
    }

    private func save() {
        writer.write(items, deleting: doomedFiles)
        doomedFiles = []
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
