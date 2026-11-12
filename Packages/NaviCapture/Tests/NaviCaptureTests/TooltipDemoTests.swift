import AppKit
import SwiftUI
import Testing

@testable import NaviCapture

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAVI_TOOLTIP_FRAMES"] != nil))
struct TooltipDemoTests {
    static let windowSize = CGSize(width: 1000, height: 560)
    static let fps = 30.0
    static let rowY: CGFloat = 55
    static let recordedHeight: CGFloat = 160

    static let buttons: [(x: CGFloat, tip: Tip)] = {
        let tools: [(CGFloat, AnnotationTool)] = [
            (94, .select), (122, .arrow), (151, .rectangle), (180, .filledRectangle), (209, .ellipse),
            (239, .line), (268, .pencil), (296, .highlighter), (325, .text), (354, .counter),
            (396, .blur), (426, .pixelate), (454, .spotlight), (484, .crop),
        ]
        var list = tools.map { (x: $0.0, tip: Tip(title: $0.1.title, shortcut: $0.1.shortcut.uppercased())) }
        list.append((x: 526, tip: Tip(title: "Color")))
        list += StrokeSize.allCases.enumerated().map { (x: 555 + CGFloat($0.offset) * 29, tip: Tip(title: "\($0.element.title) line")) }
        list.append((x: 640, tip: Tip(title: "Rotate, flip, resize")))
        list.append((x: 684, tip: Tip(title: "Undo", shortcut: "⌘Z")))
        list.append((x: 713, tip: Tip(title: "Redo", shortcut: "⇧⌘Z")))
        return list
    }()

    static let path: [(point: CGPoint, travel: Double, pause: Double)] = {
        var path: [(CGPoint, Double, Double)] = [(CGPoint(x: 330, y: 140), 0, 0.4)]
        path.append((CGPoint(x: 122, y: rowY), 0.5, 1.1))
        for x: CGFloat in [151, 180, 209, 239, 268, 296, 325, 354, 396, 426, 454, 484] {
            path.append((CGPoint(x: x, y: rowY), 0.16, 0.3))
        }
        for x: CGFloat in [526, 555, 584, 613, 640, 684, 713] {
            path.append((CGPoint(x: x, y: rowY), 0.2, 0.45))
        }
        path.append((CGPoint(x: 600, y: 140), 0.45, 1.0))
        path.append((CGPoint(x: 325, y: rowY), 0.5, 1.4))
        path.append((CGPoint(x: 400, y: 140), 0.45, 0.8))
        return path.map { (point: $0.0, travel: $0.1, pause: $0.2) }
    }()

    @Test func recordFrames() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_TOOLTIP_FRAMES"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = AnnotateModel(base: try Self.demoPicture(), scale: 2)
        model.tool = .arrow
        let tips = TooltipCenter()
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: Self.windowSize),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: AnnotateView(model: model, tips: tips, onDone: {}, onCancel: {}))
        window.contentView = view
        window.orderFrontRegardless()

        let duration = Self.path.reduce(0) { $0 + $1.travel + $1.pause }
        let cursor = NSCursor.arrow.image
        var hovered: String?
        let start = Date.now
        for frame in 0..<Int(duration * Self.fps) {
            let time = Double(frame) / Self.fps
            let wait = start.addingTimeInterval(time).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) } else { await Task.yield() }
            let point = Self.cursorPoint(at: time)
            let under = Self.buttons.first { abs($0.x - point.x) < 14 && abs(Self.rowY - point.y) < 13 }?.tip.id
            if under != hovered {
                if let hovered { tips.hover(hovered, inside: false) }
                if let under { tips.hover(under, inside: true) }
                hovered = under
            }
            view.layoutSubtreeIfNeeded()
            let top = view.isFlipped ? 0 : view.bounds.height - Self.recordedHeight
            let recorded = CGRect(x: 0, y: top, width: view.bounds.width, height: Self.recordedHeight)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: recorded))
            view.cacheDisplay(in: recorded, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let hotSpot = NSCursor.arrow.hotSpot
            cursor.draw(in: CGRect(
                x: point.x - hotSpot.x, y: Self.recordedHeight - point.y - (cursor.size.height - hotSpot.y),
                width: cursor.size.width, height: cursor.size.height
            ))
            NSGraphicsContext.restoreGraphicsState()
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: String(format: "frame-%04d.png", frame)))
        }
        window.close()
    }

    private static func cursorPoint(at time: Double) -> CGPoint {
        var elapsed = 0.0
        var from = path[0].point
        for step in path {
            if time < elapsed + step.travel {
                let t = (time - elapsed) / step.travel
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                return CGPoint(x: from.x + (step.point.x - from.x) * eased, y: from.y + (step.point.y - from.y) * eased)
            }
            elapsed += step.travel
            if time < elapsed + step.pause { return step.point }
            elapsed += step.pause
            from = step.point
        }
        return from
    }

    private static func demoPicture() throws -> CGImage {
        let width = 1800, height = 900
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let gradient = try #require(CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(srgbRed: 0.36, green: 0.42, blue: 0.95, alpha: 1),
                CGColor(srgbRed: 0.72, green: 0.38, blue: 0.86, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        ))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let cards = [
            CGRect(x: 180, y: 420, width: 620, height: 320),
            CGRect(x: 900, y: 420, width: 720, height: 320),
            CGRect(x: 180, y: 140, width: 1440, height: 200),
        ]
        for card in cards {
            context.setFillColor(CGColor(gray: 1, alpha: 0.9))
            context.addPath(CGPath(roundedRect: card, cornerWidth: 28, cornerHeight: 28, transform: nil))
            context.fillPath()
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            for line in 0..<3 {
                let bar = CGRect(x: card.minX + 48, y: card.maxY - 80 - CGFloat(line) * 56,
                                 width: card.width * (line == 2 ? 0.45 : 0.7), height: 22)
                context.addPath(CGPath(roundedRect: bar, cornerWidth: 11, cornerHeight: 11, transform: nil))
                context.fillPath()
            }
        }
        return try #require(context.makeImage())
    }
}
