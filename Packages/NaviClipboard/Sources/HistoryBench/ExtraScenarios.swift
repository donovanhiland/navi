import AppKit
import Foundation
import ImageIO
@_spi(Bench) import NaviClipboard
import NaviCore

private struct Fixtures {
    let png: Data
    let tiff: Data

    @MainActor static let shared: Fixtures = {
        var random = LCG(seed: 7)
        let width = 2880
        let height = 1800
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let shade = CGFloat(random.below(256)) / 255
                context.setFillColor(CGColor(red: shade, green: CGFloat(random.below(256)) / 255, blue: shade, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return Fixtures(png: rep.representation(using: .png, properties: [:])!, tiff: rep.tiffRepresentation!)
    }()
}

@MainActor
func spin(until done: () -> Bool) {
    while !done() { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
}

@MainActor
func awaitMain(_ body: @escaping @MainActor () async -> Void) {
    var finished = false
    Task { @MainActor in
        await body()
        finished = true
    }
    spin { finished }
}

@MainActor
func extraScenarios(
    inbox: Inbox, options: BenchOptions, runs: Int,
    sample: (Int, () -> Void, () -> Int) -> [Double]
) -> [ScenarioResult] {
    var results: [ScenarioResult] = []
    let pasteboard = NSPasteboard(name: .init("history-bench-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let probe = WatcherProbe(inbox: inbox, pasteboard: pasteboard)
    var counter = 0
    let before = Set(inbox.items.map(\.id))
    func cleanup() {
        for item in inbox.items where !before.contains(item.id) { inbox.remove(item.id) }
        inbox.flush()
    }
    func record(_ name: String, _ prepare: @escaping () -> Void, _ run: @escaping () -> Int, runs count: Int? = nil) {
        guard options.wants(name) else { return }
        let times = sample(count ?? runs, prepare, run)
        results.append(ScenarioResult(name: name, milliseconds: times))
        cleanup()
    }

    let filler = String(repeating: "the report ", count: 150)
    record("watcher-text", {
        cleanup()
        counter += 1
        pasteboard.clearContents()
        pasteboard.setString("bench watcher \(counter) " + filler, forType: .string)
    }, {
        probe.check()
        return 1
    })

    let fixtures = Fixtures.shared
    let imageRuns = max(runs / 4, 5)
    record("watcher-image-png", {
        cleanup()
        counter += 1
        var png = fixtures.png
        png.append(contentsOf: withUnsafeBytes(of: counter) { Array($0) })
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }, {
        probe.check()
        return 1
    }, runs: imageRuns)

    record("watcher-image-tiff", {
        awaitMain { await probe.waitForIdle() }
        cleanup()
        counter += 1
        pasteboard.clearContents()
        pasteboard.setData(fixtures.tiff, forType: .tiff)
    }, {
        probe.check()
        return 1
    }, runs: max(imageRuns / 2, 5))
    awaitMain { await probe.waitForIdle() }

    record("watcher-image-tiff-total", {
        cleanup()
        counter += 1
        pasteboard.clearContents()
        pasteboard.setData(fixtures.tiff, forType: .tiff)
    }, {
        probe.check()
        awaitMain { await probe.waitForIdle() }
        return 1
    }, runs: max(imageRuns / 2, 5))

    let textItem = inbox.items.first { $0.fileName == nil && $0.kind == .text }
    let imageItems = inbox.items.filter { $0.fileName != nil }
    func pixelWidth(_ item: CaptureItem) -> Int {
        guard let url = inbox.fileURL(for: item), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 0 }
        return (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
    }
    let big = imageItems.first { pixelWidth($0) >= 2000 }
    let small = imageItems.first { pixelWidth($0) < 2000 }

    if let textItem {
        record("paste-text", { () }, {
            PanelProbe.paste(textItem, inbox: inbox, to: pasteboard)
            return 1
        })
    }
    if let big {
        record("paste-image", { () }, {
            PanelProbe.paste(big, inbox: inbox, to: pasteboard)
            return 1
        }, runs: imageRuns)
    }

    let model = ClipboardModel(inbox: inbox)
    for item in [small, big].compactMap({ $0 }) {
        inbox.ensureImageCaches(for: item)
        let deadline = ContinuousClock.now + .seconds(5)
        let target = inbox.rowThumbnailURL(for: item.id)
        spin { FileManager.default.fileExists(atPath: target.path) || ContinuousClock.now > deadline }
    }
    for (name, item) in [("thumbnail-small", small), ("thumbnail-large", big)] {
        guard let item else { continue }
        record(name, { () }, {
            let fresh = ClipboardModel(inbox: inbox)
            awaitMain { _ = await PanelProbe.thumbnail(fresh, item) }
            return 1
        }, runs: imageRuns * 2)
    }
    if let big {
        record("preview-large", { () }, {
            let fresh = ClipboardModel(inbox: inbox)
            awaitMain { _ = await PanelProbe.preview(fresh, big) }
            return 1
        }, runs: imageRuns * 2)
    }
    record("panel-open-model", {
        model.query = "the"
        _ = model.results
    }, { PanelProbe.open(model) })
    return results
}
