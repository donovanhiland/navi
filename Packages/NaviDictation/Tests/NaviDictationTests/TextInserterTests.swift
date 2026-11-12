import AppKit
import NaviCore
import Testing
@testable import NaviDictation

@MainActor
struct TextInserterTests {
    @Test func restoreKeepsContentsAndMarksThemAsNavis() {
        let pasteboard = NSPasteboard(name: .init("navi-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old copy", forType: .string)

        let saved = TextInserter.save(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictation", forType: .string)
        TextInserter.restore(saved, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "old copy")
        #expect(pasteboard.types?.contains(NaviPasteboard.ownType) == true)
    }

    @Test func restoreOfEmptyPasteboardLeavesItEmpty() {
        let pasteboard = NSPasteboard(name: .init("navi-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        TextInserter.restore(TextInserter.save(pasteboard), to: pasteboard)

        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
    }
}
