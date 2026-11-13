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
    public var dictationLimit: Int

    @ObservationIgnored private let writer: HistoryWriter
    @ObservationIgnored private var doomedFiles: [URL] = []
    @ObservationIgnored private var pendingHashes: Set<UUID> = []
    @ObservationIgnored private var imageCachesChecked: Set<UUID> = []
    @ObservationIgnored private var filesDirectoryReady = false
    @ObservationIgnored private var searchCache = SearchCache()
    @ObservationIgnored var searchBudget: Duration = .milliseconds(2.5)
    public private(set) var searchKeysVersion = 0
    @ObservationIgnored public private(set) var deferredSearchItems = 0
    @ObservationIgnored private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Inbox")

    public static var defaultDirectory: URL {
        let name = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Navi Dev" : "Navi"
        return URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    public convenience init(directory: URL = Inbox.defaultDirectory, limit: Int = 200, dictationLimit: Int = 200) {
        self.init(directory: directory, limit: limit, dictationLimit: dictationLimit, beforeDeleting: nil)
    }

    init(directory: URL, limit: Int, dictationLimit: Int = 200, beforeDeleting: (@Sendable () -> Void)?) {
        self.directory = directory
        self.limit = limit
        self.dictationLimit = dictationLimit
        self.writer = HistoryWriter(directory: directory, beforeDeleting: beforeDeleting)
        load()
        warmSearch(items)
    }

    public func flush() {
        resolvePendingHashes()
        writer.flush()
    }

    @discardableResult
    public func add(
        text: String, kind: CaptureKind = .text, sourceApp: String? = nil, sourceBundleID: String? = nil, now: Date = .now
    ) -> CaptureItem? {
        guard Self.hasContent(text) else { return nil }
        if text.utf8.count > Self.deferredHashLimit { return addLarge(text: text, kind: kind, sourceApp: sourceApp, sourceBundleID: sourceBundleID, now: now) }
        let hash = Self.hash(text)
        if let existing = bump(hash: hash, kind: kind, now: now) { return existing }
        let item = CaptureItem(
            id: UUID(), kind: kind, createdAt: now, lastUsedAt: now, copyCount: 1, pinned: false,
            text: text, fileName: nil, sourceApp: sourceApp, sourceBundleID: sourceBundleID, contentHash: hash
        )
        insert(item)
        return item
    }

    private func addLarge(
        text: String, kind: CaptureKind, sourceApp: String?, sourceBundleID: String?, now: Date
    ) -> CaptureItem? {
        let length = text.utf8.count
        let found = items.withUnsafeBufferPointer { buffer -> Int? in
            for position in buffer.indices where buffer[position].kind == kind && buffer[position].text?.utf8.count == length {
                if buffer[position].text == text { return position }
            }
            return nil
        }
        if let index = found {
            items[index].lastUsedAt = now
            items[index].copyCount += 1
            let item = items[index]
            reposition(index)
            save()
            return item
        }
        let item = CaptureItem(
            id: UUID(), kind: kind, createdAt: now, lastUsedAt: now, copyCount: 1, pinned: false,
            text: text, fileName: nil, sourceApp: sourceApp, sourceBundleID: sourceBundleID, contentHash: ""
        )
        pendingHashes.insert(item.id)
        insert(item)
        Task.detached(priority: .utility) { [weak self] in
            let hash = Self.hash(text)
            await self?.finishHash(item.id, hash)
        }
        return item
    }

    private func finishHash(_ id: UUID, _ hash: String) {
        guard pendingHashes.remove(id) != nil, let index = index(of: id) else { return }
        items[index].contentHash = hash
        save()
    }

    private func resolvePendingHashes() {
        for id in pendingHashes {
            guard let index = index(of: id), let text = items[index].text else { continue }
            items[index].contentHash = Self.hash(text)
        }
        if !pendingHashes.isEmpty { save() }
        pendingHashes = []
    }

    @discardableResult
    public func add(
        fileData: Data, fileExtension: String, kind: CaptureKind,
        sourceApp: String? = nil, sourceBundleID: String? = nil, deduplicate: Bool = true, now: Date = .now
    ) -> CaptureItem? {
        let id = UUID()
        let name = "\(id.uuidString).\(fileExtension)"
        let url = filesDirectory.appending(path: name)
        if !filesDirectoryReady {
            do {
                try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
                filesDirectoryReady = true
            } catch {
                logger.error("Could not write capture file: \(error.localizedDescription)")
                return nil
            }
        }
        let hash = Self.hash(fileData)
        if deduplicate, let existing = bump(hash: hash, kind: kind, now: now) { return existing }
        do {
            try fileData.write(to: url)
        } catch {
            do {
                try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
                try fileData.write(to: url)
            } catch {
                logger.error("Could not write capture file: \(error.localizedDescription)")
                return nil
            }
        }
        let item = CaptureItem(
            id: id, kind: kind, createdAt: now, lastUsedAt: now, copyCount: 1, pinned: false,
            text: nil, fileName: name, sourceApp: sourceApp, sourceBundleID: sourceBundleID, contentHash: hash
        )
        insert(item)
        ensureImageCaches(for: item)
        return item
    }

    @discardableResult
    public func updateFile(_ id: UUID, data: Data) -> Bool {
        guard let index = index(of: id),
              let url = fileURL(for: items[index])
        else { return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not update capture file: \(error.localizedDescription)")
            return false
        }
        items[index].contentHash = Self.hash(data)
        try? FileManager.default.removeItem(at: rowThumbnailURL(for: id))
        try? FileManager.default.removeItem(at: cardImageURL(for: id))
        imageCachesChecked.remove(id)
        save()
        ensureImageCaches(for: items[index])
        return true
    }

    public func touch(_ id: UUID, now: Date = .now) {
        guard let index = index(of: id) else { return }
        items[index].lastUsedAt = now
        reposition(index)
        save()
    }

    public func togglePin(_ id: UUID) {
        guard let index = index(of: id) else { return }
        items[index].pinned.toggle()
        reposition(index)
        trimAndSave()
    }

    public func remove(_ id: UUID) {
        guard let index = index(of: id) else { return }
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
        guard let position = index(of: id), let url = fileURL(for: items[position]) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func fileURL(for item: CaptureItem) -> URL? {
        item.fileName.map { filesDirectory.appending(path: $0) }
    }

    public func rowThumbnailURL(for id: UUID) -> URL {
        filesDirectory.appending(path: "\(id.uuidString).row.png")
    }

    public func cardImageURL(for id: UUID) -> URL {
        filesDirectory.appending(path: "\(id.uuidString).card.png")
    }

    public func ensureImageCaches(for item: CaptureItem) {
        guard item.kind.isImage, let file = fileURL(for: item), !imageCachesChecked.contains(item.id) else { return }
        imageCachesChecked.insert(item.id)
        let row = rowThumbnailURL(for: item.id)
        let card = cardImageURL(for: item.id)
        if FileManager.default.fileExists(atPath: row.path) { return }
        ImageCaches.queue.async { ImageCaches.build(file: file, row: row, card: card) }
    }

    public func previewURL(for id: UUID) -> URL {
        filesDirectory.appending(path: "\(id.uuidString).preview.png")
    }

    public func markupURL(for id: UUID) -> URL {
        filesDirectory.appending(path: "\(id.uuidString).navi", directoryHint: .isDirectory)
    }

    private var historyURL: URL { directory.appending(path: "history.json") }
    private var filesDirectory: URL { directory.appending(path: "files", directoryHint: .isDirectory) }

    private func index(of id: UUID) -> Int? {
        items.withUnsafeBufferPointer { buffer in
            for position in buffer.indices where buffer[position].id == id { return position }
            return nil
        }
    }

    private func index(hash: String, kind: CaptureKind) -> Int? {
        items.withUnsafeBufferPointer { buffer in
            for position in buffer.indices where buffer[position].kind == kind && buffer[position].contentHash == hash {
                return position
            }
            return nil
        }
    }

    private func bump(hash: String, kind: CaptureKind, now: Date) -> CaptureItem? {
        guard let index = index(hash: hash, kind: kind) else { return nil }
        items[index].lastUsedAt = now
        items[index].copyCount += 1
        let item = items[index]
        reposition(index)
        save()
        return item
    }

    private func insert(_ item: CaptureItem) {
        let index = items.withUnsafeBufferPointer { buffer -> Int in
            for position in buffer.indices where !buffer[position].pinned && buffer[position].lastUsedAt < item.lastUsedAt {
                return position
            }
            return buffer.count
        }
        items.insert(item, at: index)
        if (item.text?.utf8.count ?? 0) <= Self.inlineKeyLimit {
            searchCache.prepare(item)
        } else {
            warmSearch([item])
        }
        trimAndSave()
    }

    private func trimAndSave() {
        var unpinnedCount = 0
        var dictationCount = 0
        var dropped: [Int] = []
        let limit = self.limit
        let dictationLimit = self.dictationLimit
        items.withUnsafeBufferPointer { all in
            for index in all.indices {
                if all[index].pinned { continue }
                let withinLimit: Bool
                if all[index].kind == .dictation {
                    dictationCount += 1
                    withinLimit = dictationCount <= dictationLimit
                } else {
                    unpinnedCount += 1
                    withinLimit = unpinnedCount <= limit
                }
                if !withinLimit { dropped.append(index) }
            }
        }
        for index in dropped.reversed() {
            discard(items[index])
            items.remove(at: index)
        }
        save()
    }

    private static func isOrdered(_ lhs: CaptureItem, before rhs: CaptureItem) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        return lhs.lastUsedAt > rhs.lastUsedAt
    }

    private func reposition(_ index: Int) {
        let moved = items[index]
        let count = items.count - 1
        let target = items.withUnsafeBufferPointer { all -> Int in
            func element(_ position: Int) -> CaptureItem { all[position < index ? position : position + 1] }
            var low = 0
            var high = count
            while low < high {
                let middle = (low + high) / 2
                if Self.isOrdered(element(middle), before: moved) { low = middle + 1 } else { high = middle }
            }
            let tieStart = low
            high = count
            while low < high {
                let middle = (low + high) / 2
                if Self.isOrdered(moved, before: element(middle)) { high = middle } else { low = middle + 1 }
            }
            return min(max(index, tieStart), low)
        }
        guard target != index else { return }
        items.remove(at: index)
        items.insert(moved, at: target)
    }

    private func sort() {
        let ordered = items.withUnsafeBufferPointer { buffer -> Bool in
            for position in buffer.indices.dropFirst() where Self.isOrdered(buffer[position], before: buffer[position - 1]) {
                return false
            }
            return true
        }
        if ordered { return }
        let snapshot = items
        let order = snapshot.withUnsafeBufferPointer { Self.sortedOrder($0) }
        items = order.map { snapshot[$0] }
    }

    private nonisolated static func sortedOrder(_ buffer: UnsafeBufferPointer<CaptureItem>) -> [Int] {
        struct Key {
            let pinned: Bool
            let time: Double
            let index: Int
        }
        var keys = buffer.indices.map {
            Key(pinned: buffer[$0].pinned, time: buffer[$0].lastUsedAt.timeIntervalSinceReferenceDate, index: $0)
        }
        keys.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.time != rhs.time { return lhs.time > rhs.time }
            return lhs.index < rhs.index
        }
        return keys.map(\.index)
    }

    private func discard(_ item: CaptureItem) {
        searchCache.remove(item.id)
        pendingHashes.remove(item.id)
        doomedFiles.append(markupURL(for: item.id))
        doomedFiles.append(previewURL(for: item.id))
        doomedFiles.append(rowThumbnailURL(for: item.id))
        doomedFiles.append(cardImageURL(for: item.id))
        imageCachesChecked.remove(item.id)
        if let url = fileURL(for: item) { doomedFiles.append(url) }
    }

    nonisolated static let inlineKeyLimit = 16 * 1024
    nonisolated static let deferredHashLimit = 256 * 1024

    private func warmSearch(_ items: [CaptureItem]) {
        guard !items.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let batch = 2000
            var start = 0
            while start < items.count {
                let slice = Array(items[start..<min(start + batch, items.count)])
                let keys = SearchCache.makeKeys(for: slice)
                var built: [UUID: SearchCache.Key] = [:]
                built.reserveCapacity(slice.count)
                for (item, key) in zip(slice, keys) { built[item.id] = key }
                guard let self else { return }
                await self.installSearchKeys(built)
                start += batch
            }
        }
    }

    var searchKeyCount: Int { searchCache.keys.count }

    private func installSearchKeys(_ built: [UUID: SearchCache.Key]) {
        searchCache.install(built, for: items)
        searchKeysVersion += 1
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL, options: .mappedIfSafe) else { return }
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
        data.withUnsafeBytes { hex(digest($0)) }
    }

    private nonisolated static func hash(_ text: String) -> String {
        var text = text
        return text.withUTF8 { hex(digest(UnsafeRawBufferPointer($0))) }
    }

    static func hashForTesting(_ text: String) -> String { hash(text) }

    private nonisolated static func digest(_ bytes: UnsafeRawBufferPointer) -> SHA256.Digest {
        var hasher = SHA256()
        hasher.update(bufferPointer: bytes)
        return hasher.finalize()
    }

    private static func hasContent(_ text: String) -> Bool {
        let blank = CharacterSet.whitespacesAndNewlines
        return text.unicodeScalars.contains { !blank.contains($0) }
    }

    private nonisolated static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return digest.withUnsafeBytes { bytes in
            String(unsafeUninitializedCapacity: bytes.count * 2) { buffer in
                for (index, byte) in bytes.enumerated() {
                    buffer[index * 2] = digits[Int(byte >> 4)]
                    buffer[index * 2 + 1] = digits[Int(byte & 15)]
                }
                return bytes.count * 2
            }
        }
    }
}
