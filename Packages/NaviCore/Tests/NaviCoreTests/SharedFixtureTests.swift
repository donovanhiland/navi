import Foundation
import Testing
@testable import NaviCore

struct SharedFixtureTests {
    static let folder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "shared-fixtures/history")

    @Test(arguments: ["history.json", "written-by-windows.json"])
    func readsTheSharedHistoryFixture(name: String) throws {
        let data = try Data(contentsOf: Self.folder.appending(path: name))
        let items = try CaptureItem.decodeHistory(from: data)
        #expect(items == (try JSONDecoder().decode([CaptureItem].self, from: data)))
        #expect(items.count == 5)
        #expect(items[0].kind == .screenshot)
        #expect(items[0].pinned)
        #expect(items[0].createdAt.timeIntervalSinceReferenceDate == 784_000_000.25)
        #expect(items[0].sourceBundleID == "com.apple.Safari")
        #expect(items[1].text == "Hello from the Mac\nsecond line")
        #expect(items[1].copyCount == 3)
        #expect(items[2].kind == .dictation)
        #expect(items[3].copyCount == 1)
        #expect(items[3].lastUsedAt == items[3].createdAt)
        #expect(items[4].kind == .file)
        #expect(items[4].text == "report \"final\".pdf")
    }
}
