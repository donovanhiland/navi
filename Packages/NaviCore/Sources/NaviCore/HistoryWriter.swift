import Foundation
import os

final class HistoryWriter: Sendable {
    private struct State {
        var pending: [CaptureItem]?
        var doomed: [URL] = []
        var drainQueued = false
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "com.donovanhiland.navi.history-writer", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let encoded = OSAllocatedUnfairLock(initialState: EncodedItems())
    private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Inbox")
    private static let signposter = OSSignposter(subsystem: "com.donovanhiland.navi", category: "History")

    private let beforeDeleting: (@Sendable () -> Void)?

    init(directory: URL, beforeDeleting: (@Sendable () -> Void)? = nil) {
        self.directory = directory
        self.beforeDeleting = beforeDeleting
    }

    func write(_ items: [CaptureItem], deleting files: [URL] = []) {
        let (needsDrain, replaced) = state.withLock { state -> (Bool, [CaptureItem]?) in
            let replaced = state.pending
            state.pending = items
            state.doomed += files
            defer { state.drainQueued = true }
            return (!state.drainQueued, replaced)
        }
        if let replaced { queue.async { withExtendedLifetime(replaced) {} } }
        if needsDrain { queue.async { self.drain() } }
    }

    func flush() {
        queue.sync {}
    }

    private func drain() {
        while let (items, doomed) = state.withLock({ state -> ([CaptureItem], [URL])? in
            guard let items = state.pending else {
                state.drainQueued = false
                return nil
            }
            defer { state.pending = nil; state.doomed = [] }
            return (items, state.doomed)
        }) {
            let saved = persist(items)
            beforeDeleting?()
            guard saved else {
                state.withLock { $0.doomed = doomed + $0.doomed }
                continue
            }
            let referenced = Set(items.compactMap(\.fileName))
            for url in doomed where !referenced.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func persist(_ items: [CaptureItem]) -> Bool {
        let interval = Self.signposter.beginInterval("InboxSave")
        defer { Self.signposter.endInterval("InboxSave", interval) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = encoded.withLock { $0.encode(items) }
            try data.write(to: directory.appending(path: "history.json"), options: .atomic)
            return true
        } catch {
            logger.error("Could not save history: \(error.localizedDescription)")
            return false
        }
    }
}
