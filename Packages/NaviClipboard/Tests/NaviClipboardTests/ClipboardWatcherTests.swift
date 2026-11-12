import AppKit
import Foundation
import NaviCore
import Testing
@testable import NaviClipboard

@MainActor
final class ClipboardWatcherTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "NaviClipboardTests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: .init("navi-test-\(UUID().uuidString)"))
    lazy var inbox = Inbox(directory: directory)

    isolated deinit {
        inbox.flush()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func savesACopy() {
        let watcher = ClipboardWatcher(inbox: inbox, pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        watcher.check()
        #expect(inbox.items.map(\.text) == ["hello"])
    }

    @Test func skipsWhatNaviWroteItself() {
        let watcher = ClipboardWatcher(inbox: inbox, pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("restored", forType: .string)
        pasteboard.setData(Data(), forType: NaviPasteboard.ownType)
        watcher.check()
        #expect(inbox.items.isEmpty)
    }
}
