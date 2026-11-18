import AppKit
import SwiftUI
import Testing

@testable import NaviCapture

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAVI_TEXT_FRAMES"] != nil))
struct TextDemoTests {
    static let windowSize = CGSize(width: 1000, height: 560)
    static let fps = 30.0
    static let toolbarHeight: CGFloat = 47

    struct Beat {
        var to: CGPoint?
        var travel = 0.4
        var drag = false
        var action: ((AnnotateModel, TextDemoTests.Context) -> Void)?
        var hold = 0.3
    }

    final class Context {
        let view: NSView
        init(view: NSView) { self.view = view }

        var textView: NSTextView? {
            func find(_ view: NSView) -> NSTextView? {
                if let host = view as? TextBoxHost { return host.textView }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return find(view)
        }
    }

    static let image = CGSize(width: 1800, height: 900)
    static var fit: CGFloat {
        let canvas = CGSize(width: windowSize.width, height: windowSize.height - toolbarHeight)
        return min(0.5, (canvas.width - 40) / image.width, (canvas.height - 40) / image.height)
    }

    static var origin: CGPoint {
        let canvas = CGSize(width: windowSize.width, height: windowSize.height - toolbarHeight)
        return CGPoint(
            x: (canvas.width - image.width * fit) / 2,
            y: toolbarHeight + (canvas.height - image.height * fit) / 2
        )
    }

    static func screen(_ pixel: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + pixel.x * fit, y: origin.y + pixel.y * fit)
    }

    static func pixel(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - origin.x) / fit, y: (screen.y - origin.y) / fit)
    }

    static func typing(_ text: String) -> [Beat] {
        text.map { character in
            Beat(action: { _, context in
                guard let textView = context.textView else { return }
                textView.insertText(String(character), replacementRange: textView.selectedRange())
            }, hold: 0.045)
        }
    }

    static func script() -> [Beat] {
        let click = CGPoint(x: 1010, y: 300)
        var beats: [Beat] = [
            Beat(to: CGPoint(x: 600, y: 200), travel: 0, hold: 0.6),
            Beat(to: CGPoint(x: 325, y: 23), travel: 0.6, action: { model, _ in model.tool = .text }, hold: 0.5),
            Beat(to: screen(click), travel: 0.7, action: { model, _ in
                model.pointerDown(at: click)
                model.pointerUp(from: click, to: click)
            }, hold: 0.5),
        ]
        beats += typing("The Save button is cut off on the right side of this dialog")
        beats.append(Beat(hold: 0.8))
        beats.append(Beat(to: CGPoint(x: 613, y: 23), travel: 0.6, action: { model, _ in model.textSize = .large }, hold: 0.7))
        beats.append(Beat(to: CGPoint(x: 526, y: 23), travel: 0.4, action: { model, _ in
            model.color = RGBA(red: 0, green: 0.48, blue: 1)
        }, hold: 0.7))
        beats.append(Beat(action: { model, _ in model.finishText() }, hold: 0.9))
        return beats
    }

    static func handleBeats(_ model: AnnotateModel) -> [Beat] {
        guard let mark = model.selectedMark else { return [] }
        let right = mark.point(of: .right)
        let narrow = CGPoint(x: mark.bounds.minX + mark.bounds.width * 0.55, y: right.y)
        return [
            Beat(to: screen(right), travel: 0.6, action: { model, _ in model.pointerDown(at: right) }, hold: 0.3),
            Beat(to: screen(narrow), travel: 1.2, drag: true, action: { model, _ in
                model.pointerUp(from: right, to: narrow)
            }, hold: 0.8),
        ]
    }

    @Test func recordFrames() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_TEXT_FRAMES"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = AnnotateModel(base: try Self.demoPicture(), scale: 2)
        model.tool = .arrow
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: Self.windowSize),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: AnnotateView(model: model, onDone: {}, onCancel: {}))
        window.contentView = view
        window.orderFrontRegardless()
        let context = Context(view: view)

        var frame = 0
        var cursor = CGPoint(x: 600, y: 200)
        func shoot(_ seconds: Double, moving from: CGPoint? = nil, to target: CGPoint? = nil, drag: CGPoint? = nil) async throws {
            let count = max(1, Int((seconds * Self.fps).rounded()))
            for step in 0..<count {
                if let from, let target {
                    let t = Double(step + 1) / Double(count)
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    cursor = CGPoint(x: from.x + (target.x - from.x) * eased, y: from.y + (target.y - from.y) * eased)
                    if let drag { model.pointerDragged(from: drag, to: Self.pixel(cursor)) }
                }
                try await Task.sleep(for: .milliseconds(8))
                try capture(view: view, cursor: cursor, model: model, to: folder.appending(path: String(format: "frame-%04d.png", frame)))
                frame += 1
            }
        }

        func play(_ beats: [Beat]) async throws {
            var pressed: CGPoint?
            for beat in beats {
                if let target = beat.to, beat.travel > 0 {
                    try await shoot(beat.travel, moving: cursor, to: target, drag: beat.drag ? pressed : nil)
                } else if let target = beat.to {
                    cursor = target
                }
                model.pointerMoved(to: Self.pixel(cursor))
                beat.action?(model, context)
                if beat.to != nil, !beat.drag { pressed = Self.pixel(cursor) }
                if beat.hold > 0 { try await shoot(beat.hold) }
            }
        }

        try await play(Self.script())
        try await play(Self.handleBeats(model))

        if let mark = model.selectedMark {
            let corner = mark.point(of: .end)
            let bigger = CGPoint(x: mark.bounds.minX + mark.bounds.width * 1.35, y: mark.bounds.minY + mark.bounds.height * 1.35)
            try await play([
                Beat(to: Self.screen(corner), travel: 0.6, action: { model, _ in model.pointerDown(at: corner) }, hold: 0.3),
                Beat(to: Self.screen(bigger), travel: 1.2, drag: true, action: { model, _ in
                    model.pointerUp(from: corner, to: bigger)
                }, hold: 1.5),
            ])
        }
        window.close()
    }

    private func capture(view: NSView, cursor point: CGPoint, model: AnnotateModel, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let pointer = point.y < Self.toolbarHeight ? NSCursor.arrow : model.dragPointer(at: Self.pixel(point)).cursor
        let image = pointer.image
        let hotSpot = pointer.hotSpot
        image.draw(in: CGRect(
            x: point.x - hotSpot.x, y: view.bounds.height - point.y - (image.size.height - hotSpot.y),
            width: image.size.width, height: image.size.height
        ))
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    private static func demoPicture() throws -> CGImage {
        let width = Int(image.width), height = Int(image.height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dialog = CGRect(x: 160, y: 140, width: 860, height: 560)
        context.setFillColor(.white)
        context.addPath(CGPath(roundedRect: dialog, cornerWidth: 24, cornerHeight: 24, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        for line in 0..<4 {
            let bar = CGRect(x: dialog.minX + 56, y: dialog.minY + 80 + CGFloat(line) * 64, width: line == 3 ? 380 : 700, height: 24)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.fillPath()
        }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.48, blue: 1, alpha: 1))
        let button = CGRect(x: dialog.maxX - 150, y: dialog.maxY - 110, width: 220, height: 64)
        context.addPath(CGPath(roundedRect: button, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.fillPath()
        return try #require(context.makeImage())
    }
}
