import AppKit
import Carbon.HIToolbox
import NaviCore

@MainActor
enum TextInserter {
    static let restoreDelay: Duration = .milliseconds(600)

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    struct SavedItem {
        let entries: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private struct PendingRestore {
        let id: UUID
        let saved: [SavedItem]
        let changeCount: Int
        let task: Task<Void, Never>
    }

    private static var pending: PendingRestore?
    static let pasteGap: Duration = .milliseconds(200)
    private static var lastPaste: ContinuousClock.Instant?

    @discardableResult
    static func insert(_ text: String, pasteboard: NSPasteboard = .general) async -> Bool {
        if let lastPaste {
            try? await Task.sleep(until: lastPaste + pasteGap, clock: .continuous)
            guard !Task.isCancelled else { return false }
        }
        let saved = takeSaved(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NaviPasteboard.ownType)
        pasteboard.setData(Data(), forType: transientType)
        let ourChangeCount = pasteboard.changeCount

        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else {
            if pasteboard.changeCount == ourChangeCount { restore(saved, to: pasteboard) }
            return false
        }
        pressCommandV()
        lastPaste = .now
        scheduleRestore(saved, changeCount: ourChangeCount, pasteboard: pasteboard)
        return true
    }

    private static func takeSaved(from pasteboard: NSPasteboard) -> [SavedItem] {
        guard let waiting = pending else { return save(pasteboard) }
        waiting.task.cancel()
        pending = nil
        return pasteboard.changeCount == waiting.changeCount ? waiting.saved : save(pasteboard)
    }

    private static func scheduleRestore(_ saved: [SavedItem], changeCount: Int, pasteboard: NSPasteboard) {
        let id = UUID()
        let task = Task { @MainActor in
            try? await Task.sleep(for: restoreDelay)
            guard !Task.isCancelled, pending?.id == id else { return }
            pending = nil
            guard pasteboard.changeCount == changeCount else { return }
            restore(saved, to: pasteboard)
        }
        pending = PendingRestore(id: id, saved: saved, changeCount: changeCount, task: task)
    }

    static func save(_ pasteboard: NSPasteboard) -> [SavedItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            SavedItem(entries: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    static func restore(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in saved.entries { item.setData(entry.data, forType: entry.type) }
            return item
        }
        items[0].setData(Data(), forType: NaviPasteboard.ownType)
        pasteboard.writeObjects(items)
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        SyntheticKey.mark(down)
        SyntheticKey.mark(up)
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
