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

    static func insert(_ text: String, pasteboard: NSPasteboard = .general) async {
        let saved = save(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NaviPasteboard.ownType)
        pasteboard.setData(Data(), forType: transientType)
        let ourChangeCount = pasteboard.changeCount

        try? await Task.sleep(for: .milliseconds(30))
        pressCommandV()
        try? await Task.sleep(for: restoreDelay)

        guard pasteboard.changeCount == ourChangeCount else { return }
        restore(saved, to: pasteboard)
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
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
