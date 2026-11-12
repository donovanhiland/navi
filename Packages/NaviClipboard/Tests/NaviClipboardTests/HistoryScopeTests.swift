import Foundation
import NaviCore
import Testing
@testable import NaviClipboard

@MainActor
final class HistoryScopeTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "NaviClipboardTests-\(UUID().uuidString)")
    lazy var inbox = Inbox(directory: directory)
    let start = Date(timeIntervalSince1970: 1_000_000)

    isolated deinit {
        inbox.flush()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() -> ClipboardModel {
        inbox.add(text: "a clip", now: start)
        inbox.add(text: "said this", kind: .dictation, now: start + 1)
        inbox.add(fileData: Data([1, 2, 3]), fileExtension: "png", kind: .screenshot, now: start + 2)
        return ClipboardModel(inbox: inbox)
    }

    @Test func eachScopeListsItsKinds() {
        let model = makeModel()
        #expect(model.results.map(\.kind) == [.screenshot, .dictation, .text])
        model.scope = .text
        #expect(model.results.map(\.kind) == [.text])
        model.scope = .images
        #expect(model.results.map(\.kind) == [.screenshot])
        model.scope = .dictation
        #expect(model.results.map(\.text) == ["said this"])
    }

    @Test func searchWorksInsideAScope() {
        let model = makeModel()
        model.scope = .dictation
        model.query = "clip"
        #expect(model.results.isEmpty)
        model.query = "said"
        #expect(model.results.count == 1)
    }

    @Test func tabWrapsAroundAndOpeningGoesBackToAll() {
        let model = makeModel()
        model.cycleScope(by: -1)
        #expect(model.scope == .dictation)
        model.cycleScope(by: 1)
        #expect(model.scope == .all)
        model.cycleScope(by: 1)
        #expect(model.scope == .text)
        model.reset()
        #expect(model.scope == .all)
    }
}
