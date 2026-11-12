import AppKit
import NaviCore
import SwiftUI
import Testing

@testable import NaviClipboard

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAVI_HISTORY_SNAPSHOTS"] != nil))
final class HistorySnapshotTests {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_HISTORY_SNAPSHOTS"] ?? "/tmp")
    let directory = FileManager.default.temporaryDirectory.appending(path: "NaviHistorySnapshots-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: .init("navi-snap-\(UUID().uuidString)"))
    let start = Date(timeIntervalSince1970: 1_000_000)

    isolated deinit {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private func picture(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Data {
        let context = CGContext(
            data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.fill(CGRect(x: 40, y: 220, width: 360, height: 40))
        context.fill(CGRect(x: 40, y: 160, width: 240, height: 24))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    private func seed(_ inbox: Inbox) {
        var time = start
        func next() -> Date { time += 60; return time }
        inbox.add(text: "https://github.com/donovanhiland/navi/pulls", sourceApp: "Arc", now: next())
        inbox.add(text: "Can we move standup to 10:30 tomorrow?", kind: .dictation, now: next())
        inbox.add(fileData: picture(0.35, 0.55, 0.85), fileExtension: "png", kind: .screenshot, now: next())
        inbox.add(text: "swift test --filter HistoryScope", sourceApp: "Terminal", now: next())
        inbox.add(text: "Thanks, that fixed it. I will ship it tonight.", kind: .dictation, now: next())
        inbox.add(fileData: picture(0.85, 0.45, 0.35), fileExtension: "png", kind: .image, now: next())
        inbox.add(text: "let scope = HistoryScope.all", sourceApp: "Xcode", now: next())
        inbox.add(text: "Remind me to check the nightly release.", kind: .dictation, now: next())
    }

    private func render(_ model: ClipboardModel, name: String) async throws {
        for item in model.results where item.fileName != nil { _ = await model.thumbnail(for: item) }
        let root = ClipboardListView(model: model, onChoose: { _ in }, onQuit: {})
            .background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(x: 0, y: 0, width: Metrics.width, height: model.contentHeight)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
    }

    @Test func scopes() async throws {
        let inbox = Inbox(directory: directory.appending(path: "scopes"))
        seed(inbox)
        let model = ClipboardModel(inbox: inbox)
        model.maxListHeight = 600
        for scope in HistoryScope.allCases {
            model.scope = scope
            try await render(model, name: "scope-\(scope.title.lowercased())")
        }
        inbox.flush()
    }

    @Test func dictationAfterRestore() async throws {
        for marked in [false, true] {
            let inbox = Inbox(directory: directory.appending(path: "restore-\(marked)"))
            let watcher = ClipboardWatcher(inbox: inbox, pasteboard: pasteboard)
            pasteboard.clearContents()
            pasteboard.setString("an older copy", forType: .string)
            watcher.check()
            pasteboard.clearContents()
            pasteboard.setString("the clip you copied before dictating", forType: .string)
            watcher.check()
            inbox.add(text: "This is what I just said.", kind: .dictation)
            pasteboard.clearContents()
            pasteboard.setString("the clip you copied before dictating", forType: .string)
            if marked { pasteboard.setData(Data(), forType: NaviPasteboard.ownType) }
            watcher.check()
            let model = ClipboardModel(inbox: inbox)
            try await render(model, name: marked ? "restore-after" : "restore-before")
            inbox.flush()
        }
    }
}
