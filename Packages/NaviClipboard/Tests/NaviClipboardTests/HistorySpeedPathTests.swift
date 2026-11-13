import AppKit
import Foundation
import NaviCore
import Testing
@testable import NaviClipboard

@MainActor
final class HistorySpeedPathTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "NaviClipboardTests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: .init("navi-speed-\(UUID().uuidString)"))
    lazy var inbox = Inbox(directory: directory)
    let start = Date(timeIntervalSince1970: 1_000_000)

    isolated deinit {
        inbox.flush()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private func picture(width: Int, height: Int) throws -> (png: Data, tiff: Data) {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        return (try #require(rep.representation(using: .png, properties: [:])), try #require(rep.tiffRepresentation))
    }

    @Test func aTiffOnlyCopyBecomesAPngItem() async throws {
        let watcher = ClipboardWatcher(inbox: inbox, pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setData(try picture(width: 64, height: 48).tiff, forType: .tiff)
        watcher.check()
        await watcher.waitForIdle()
        let item = try #require(inbox.items.first)
        #expect(item.kind == .image && item.fileName?.hasSuffix(".png") == true)
        let data = try #require(inbox.fileData(for: item.id))
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(NSBitmapImageRep(data: data)?.pixelsWide == 64)
    }

    @Test func pastingAPngItemWritesPngNowAndTiffOnDemand() throws {
        let png = try picture(width: 80, height: 60).png
        let item = try #require(inbox.add(fileData: png, fileExtension: "png", kind: .screenshot, now: start))
        _ = Paster.write(item, inbox: inbox, to: pasteboard)
        #expect(pasteboard.data(forType: .png) == png)
        let tiff = try #require(pasteboard.data(forType: .tiff))
        #expect(NSBitmapImageRep(data: tiff)?.pixelsWide == 80)
        #expect(NSImage(pasteboard: pasteboard)?.representations.first?.pixelsWide == 80)
    }

    @Test func pastingTextAndRecordingsStillWorks() throws {
        let text = try #require(inbox.add(text: "hello", now: start))
        _ = Paster.write(text, inbox: inbox, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test func bigImagesGetRowAndCardCachesAndTheModelUsesThem() async throws {
        let big = try picture(width: 2000, height: 1200).png
        let item = try #require(inbox.add(fileData: big, fileExtension: "png", kind: .screenshot, now: start))
        let row = inbox.rowThumbnailURL(for: item.id)
        let card = inbox.cardImageURL(for: item.id)
        for _ in 0..<200 where !(FileManager.default.fileExists(atPath: row.path) && FileManager.default.fileExists(atPath: card.path)) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(atPath: row.path) && FileManager.default.fileExists(atPath: card.path))
        let model = ClipboardModel(inbox: inbox)
        let thumbnail = try #require(await model.thumbnail(for: item))
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 400)
        let preview = try #require(await model.previewImage(for: item))
        #expect(abs(max(preview.size.width, preview.size.height) - 2000) < 1)
        var rect = CGRect(origin: .zero, size: preview.size)
        let decoded = try #require(preview.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        #expect(max(decoded.width, decoded.height) == 960)
    }

    @Test func markupInvalidatesTheCaches() async throws {
        let item = try #require(inbox.add(
            fileData: try picture(width: 1200, height: 800).png, fileExtension: "png", kind: .screenshot, now: start
        ))
        let row = inbox.rowThumbnailURL(for: item.id)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: row.path) { try await Task.sleep(for: .milliseconds(25)) }
        #expect(FileManager.default.fileExists(atPath: row.path))
        let before = try Data(contentsOf: row)
        #expect(inbox.updateFile(item.id, data: try picture(width: 1000, height: 1000).png))
        for _ in 0..<200 {
            if let now = try? Data(contentsOf: row), now != before { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let after = try Data(contentsOf: row)
        #expect(after != before)
        let size = try #require(NSBitmapImageRep(data: after))
        #expect(size.pixelsWide == 400 && size.pixelsHigh == 400)
    }

    @Test func removingAnImageRemovesItsCaches() async throws {
        let item = try #require(inbox.add(
            fileData: try picture(width: 1200, height: 800).png, fileExtension: "png", kind: .screenshot, now: start
        ))
        let row = inbox.rowThumbnailURL(for: item.id)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: row.path) { try await Task.sleep(for: .milliseconds(25)) }
        inbox.remove(item.id)
        inbox.flush()
        #expect(!FileManager.default.fileExists(atPath: row.path))
        #expect(!FileManager.default.fileExists(atPath: inbox.cardImageURL(for: item.id).path))
    }

    @Test func listHeightMatchesTheRowsShown() {
        inbox.add(text: "a clip", now: start)
        inbox.add(fileData: Data([1, 2, 3]), fileExtension: "png", kind: .screenshot, now: start + 1)
        let model = ClipboardModel(inbox: inbox)
        #expect(model.listHeight == model.listHeight(for: model.results))
        model.query = "nothing like this"
        #expect(model.listHeight == model.listHeight(for: model.results))
        #expect(model.contentHeight == Metrics.headerHeight + model.listHeight + Metrics.footerHeight)
    }
}
