import AppKit
import Foundation
import Testing
@testable import NaviCapture

@MainActor
struct SpeedBench {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["NAVI_BENCH"] != nil }

    struct Row {
        let name: String
        let median: Double
        let p95: Double
        let minimum: Double
    }

    static func time(_ name: String, iterations: Int = 15, warmup: Int = 2, _ body: () -> Void) -> Row {
        for _ in 0 ..< warmup { body() }
        var samples: [Double] = []
        for _ in 0 ..< iterations {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        let row = Row(
            name: name, median: samples[samples.count / 2],
            p95: samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))], minimum: samples[0]
        )
        print(String(format: "BENCH %-34@ median %8.2f ms  p95 %8.2f ms  min %8.2f ms", name as NSString, row.median, row.p95, row.minimum))
        return row
    }

    static func timeAsync(_ name: String, iterations: Int = 8, warmup: Int = 1, _ body: () async -> Void) async -> Row {
        for _ in 0 ..< warmup { await body() }
        var samples: [Double] = []
        for _ in 0 ..< iterations {
            let start = ContinuousClock.now
            await body()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        let row = Row(
            name: name, median: samples[samples.count / 2],
            p95: samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))], minimum: samples[0]
        )
        print(String(format: "BENCH %-34@ median %8.2f ms  p95 %8.2f ms  min %8.2f ms", name as NSString, row.median, row.p95, row.minimum))
        return row
    }

    static func screen(width: Int, height: Int) -> CGImage {
        if let path = ProcessInfo.processInfo.environment["NAVI_BENCH_IMAGE"],
           let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            if image.width == width, image.height == height { return image }
            return scaled(image, width: width, height: height)
        }
        return synthetic(width: width, height: height)
    }

    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func synthetic(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SystemRandomNumberGenerator.Seeded(seed: 7)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for index in 0 ..< 14 {
            let x = CGFloat(generator.next() % UInt64(width * 3 / 4))
            let y = CGFloat(generator.next() % UInt64(height * 3 / 4))
            let rect = CGRect(x: x, y: y, width: CGFloat(width) / 3, height: CGFloat(height) / 3)
            context.setFillColor(CGColor(gray: index % 2 == 0 ? 1 : 0.12, alpha: 1))
            context.fill(rect)
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 44, width: rect.width, height: 44))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22),
                .foregroundColor: index % 2 == 0 ? NSColor.black : NSColor.white,
            ]
            for line in 0 ..< Int(rect.height / 30) - 2 {
                let text = "Line \(line) of window \(index): the quick brown fox jumps over the lazy dog 0123456789"
                (text as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.maxY - 80 - CGFloat(line) * 30), withAttributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func mark(_ kind: Annotation.Kind, start: CGPoint, end: CGPoint) -> Annotation {
        Annotation(kind: kind, start: start, end: end, color: RGBA(red: 1, green: 0.2, blue: 0.2), lineWidth: 6)
    }

    static func marks(width: Int, height: Int, effects: Bool) -> [Annotation] {
        let w = CGFloat(width), h = CGFloat(height)
        var marks: [Annotation] = [
            mark(.arrow, start: CGPoint(x: w * 0.1, y: h * 0.1), end: CGPoint(x: w * 0.4, y: h * 0.3)),
            mark(.rectangle, start: CGPoint(x: w * 0.5, y: h * 0.1), end: CGPoint(x: w * 0.8, y: h * 0.3)),
            mark(.ellipse, start: CGPoint(x: w * 0.2, y: h * 0.5), end: CGPoint(x: w * 0.3, y: h * 0.7)),
            mark(.line, start: CGPoint(x: w * 0.6, y: h * 0.6), end: CGPoint(x: w * 0.9, y: h * 0.9)),
            mark(.counter, start: CGPoint(x: w * 0.7, y: h * 0.5), end: CGPoint(x: w * 0.7, y: h * 0.5)),
        ]
        var text = mark(.text, start: CGPoint(x: w * 0.3, y: h * 0.8), end: CGPoint(x: w * 0.3, y: h * 0.8))
        text.text = "Look here"
        marks.append(text)
        var pencil = mark(.pencil, start: .zero, end: .zero)
        pencil.points = (0 ..< 200).map { CGPoint(x: w * 0.1 + CGFloat($0) * 3, y: h * 0.4 + sin(CGFloat($0) / 10) * 40) }
        marks.append(pencil)
        if effects {
            marks.append(mark(.blur, start: CGPoint(x: w * 0.05, y: h * 0.6), end: CGPoint(x: w * 0.25, y: h * 0.75)))
            marks.append(mark(.pixelate, start: CGPoint(x: w * 0.75, y: h * 0.05), end: CGPoint(x: w * 0.95, y: h * 0.2)))
        }
        return marks
    }

    @Test(.enabled(if: SpeedBench.enabled))
    func capturePipeline() async throws {
        let sizes = [(3024, 1964, "3k"), (5120, 2880, "5k")]
        for (width, height, label) in sizes {
            let image = Self.screen(width: width, height: height)
            let crop = CGRect(x: width / 6, y: height / 6, width: width * 2 / 3, height: height * 2 / 3)
            let area = image.cropping(to: crop)!
            let point = CGSize(width: CGFloat(area.width) / 2, height: CGFloat(area.height) / 2)
            var bytes = 0
            _ = Self.time("png-encode-area-\(label)") { bytes = ImageOps.png(area, pointSize: point)?.count ?? 0 }
            print("BENCH   png bytes \(bytes)")
            _ = Self.time("png-encode-full-\(label)") { _ = ImageOps.png(image, pointSize: point) }
            let png = ImageOps.png(area, pointSize: point) ?? Data()
            _ = Self.time("card-make-\(label)") {
                let bitmap = NSBitmapImageRep(cgImage: area)
                bitmap.size = point
                let nsImage = NSImage(size: point)
                nsImage.addRepresentation(bitmap)
                _ = try? Card(inboxID: nil, image: nsImage, png: png, createdAt: .now)
            }
        }
    }

    @Test(.enabled(if: SpeedBench.enabled))
    func markupRender() async throws {
        for (width, height, label) in [(3024, 1964, "3k"), (5120, 2880, "5k")] {
            let image = Self.screen(width: width, height: height)
            let renderer = AnnotationRenderer()
            let plain = Self.marks(width: width, height: height, effects: false)
            let effects = Self.marks(width: width, height: height, effects: true)
            _ = Self.time("markup-frame-plain-\(label)") { _ = renderer.render(base: image, marks: plain) }
            _ = renderer.render(base: image, marks: effects)
            _ = Self.time("markup-frame-effects-\(label)") { _ = renderer.render(base: image, marks: effects) }
            let arrow = Self.mark(.arrow, start: CGPoint(x: width / 3, y: height / 3), end: CGPoint(x: width / 2, y: height / 2))
            _ = Self.time("markup-drag-full-\(label)") { _ = renderer.render(base: image, marks: effects + [arrow]) }
            _ = Self.time("markup-drag-patch-\(label)") { _ = renderer.patch(base: image, marks: effects + [arrow], live: arrow) }
            _ = Self.time("markup-effects-first-\(label)", iterations: 6) {
                _ = AnnotationRenderer().render(base: image, marks: effects)
            }
        }
    }

    @Test(.enabled(if: SpeedBench.enabled))
    func markupStoreAndBackground() async throws {
        let image = Self.screen(width: 3024, height: 1964)
        let folder = FileManager.default.temporaryDirectory.appending(path: "navi-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var document = AnnotationDocument()
        document.annotations = Self.marks(width: 3024, height: 1964, effects: true)
        _ = Self.time("markup-store-save-3k", iterations: 8) {
            try? MarkupStore.save(base: image, document: document, to: folder)
        }
        var style = BackgroundStyle()
        if let out = ProcessInfo.processInfo.environment["NAVI_BENCH_OUT"], let rendered = BackgroundRenderer.render(image, style: style, scale: 2) {
            try? ImageOps.png(rendered, pointSize: CGSize(width: rendered.width, height: rendered.height))?.write(to: URL(filePath: out))
        }
        _ = Self.time("background-render-3k") { _ = BackgroundRenderer.render(image, style: style, scale: 2) }
        style.autoBalance = true
        let padded = BackgroundRenderer.render(image, style: BackgroundStyle(), scale: 2)!
        _ = Self.time("background-autobalance-3k", iterations: 6) {
            _ = BackgroundRenderer.render(padded, style: style, scale: 2)
        }
    }

    @Test(.enabled(if: SpeedBench.enabled))
    func scrollAndText() async throws {
        let tall = Self.screen(width: 1600, height: 4000)
        let frameHeight = 900
        let frames = stride(from: 0, to: 3000, by: 300).map {
            tall.cropping(to: CGRect(x: 0, y: $0, width: 1600, height: frameHeight))!
        }
        _ = Self.time("scroll-register-frame", iterations: 9) {
            _ = ScrollStitcher.offset(of: frames[1], from: frames[0])
        }
        var stitcher = ScrollStitcher()
        for frame in frames { stitcher.add(frame) }
        _ = Self.time("scroll-stitch-10") { _ = stitcher.stitched() }
        let screen = Self.screen(width: 3024, height: 1964)
        let area = screen.cropping(to: CGRect(x: 400, y: 300, width: 1600, height: 1000))!
        _ = await Self.timeAsync("ocr-area", iterations: 5) { _ = await TextRecognizer.recognize(area) }
    }
}

extension SystemRandomNumberGenerator {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11
        }
    }
}
