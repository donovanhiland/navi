import AppKit
import Testing

@testable import NaviCapture

@MainActor
@Suite(.enabled(if: !NSScreen.screens.isEmpty && ProcessInfo.processInfo.environment["NAVI_ACCURACY_DEMO"] != nil))
struct SelectionAccuracyDemoTests {
    private static let size = CGSize(width: 1440, height: 900)
    private static let scale: CGFloat = 2
    private static let front = CGRect(x: 300, y: 200, width: 840, height: 520)
    private static let text = "Domain name"
    private static let textOrigin = CGPoint(x: 420, y: 470)
    private static let font = NSFont.systemFont(ofSize: 44, weight: .bold)

    @Test func recordFrames() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_ACCURACY_DEMO"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desktop = Self.desktop()
        let ink = try #require(Self.inkBounds(of: desktop))
        let letterWidth = "D".size(withAttributes: [.font: Self.font]).width
        let letter = try #require(Self.inkBounds(of: desktop, maxX: Self.textOrigin.x + letterWidth))

        let hidden = CGRect(x: letter.minX + 2, y: letter.maxY - 2 - 200, width: 400, height: 200)
        let screen = NSScreen.screens[0]
        let origin = screen.frame.origin
        let windows = [
            OnScreenWindow(id: 1, frame: Self.front.offsetBy(dx: origin.x, dy: origin.y), appName: "Safari", ownerPID: 0),
            OnScreenWindow(id: 2, frame: hidden.offsetBy(dx: origin.x, dy: origin.y), appName: "Notes", ownerPID: 0),
        ]
        var outcome: SelectionSession.Outcome?
        let session = SelectionSession(screens: [screen], mode: .area, windows: windows) { outcome = $0 }
        let view = OverlayView(session: session, screen: screen)
        view.setFrameSize(Self.size)
        view.captured = CapturedImage(image: desktop, scale: Self.scale)

        let start = CGPoint(x: ink.minX - 1.5, y: ink.maxY + 1.5)
        let end = CGPoint(x: ink.maxX + 1.5, y: ink.minY - 1.5)
        var mouse = CGPoint(x: start.x - 140, y: start.y + 90)
        var index = 0

        func write(_ rep: NSBitmapImageRep) throws {
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: String(format: "frame-%04d.png", index)))
            index += 1
        }
        func frame() throws {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 60.0))
            let overlay = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: overlay)
            let rep = try Self.canvas()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.cgContext.draw(desktop, in: CGRect(origin: .zero, size: Self.size))
            overlay.draw(in: CGRect(origin: .zero, size: Self.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            Self.drawCursor(at: mouse)
            NSGraphicsContext.restoreGraphicsState()
            try write(rep)
        }
        func glide(to target: CGPoint, frames count: Int, dragging: Bool = false) throws {
            let from = mouse
            for step in 1...count {
                let t = CaptureGeometry.easeOut(CGFloat(step) / CGFloat(count))
                mouse = CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)
                let type: NSEvent.EventType = dragging ? .leftMouseDragged : .mouseMoved
                let event = Self.event(type, at: mouse)
                if dragging { view.mouseDragged(with: event) } else { view.mouseMoved(with: event) }
                try frame()
            }
        }
        func hold(frames count: Int) throws { for _ in 0..<count { try frame() } }

        try glide(to: mouse, frames: 1)
        try hold(frames: 10)
        try glide(to: start, frames: 30)
        try hold(frames: 30)
        view.mouseDown(with: Self.event(.leftMouseDown, at: mouse))
        try glide(to: end, frames: 40, dragging: true)
        try hold(frames: 24)
        view.mouseUp(with: Self.event(.leftMouseUp, at: mouse))

        guard case let .area(captured, _, _) = try #require(outcome) else {
            Issue.record("Expected an area, got \(String(describing: outcome))")
            return
        }
        let cropURL = folder.appending(path: "crop.png")
        let cropRep = NSBitmapImageRep(cgImage: captured.image)
        try #require(cropRep.representation(using: .png, properties: [:])).write(to: cropURL)
        let result = try Self.resultFrame(crop: captured.image)
        for _ in 0..<75 { try write(result) }
    }

    private static func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private static func canvas() throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        return rep
    }

    private static func resultFrame(crop: CGImage) throws -> NSBitmapImageRep {
        let rep = try canvas()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = graphics
        NSColor(white: 0.1, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        let zoom: CGFloat = 2
        let center = CGPoint(x: 625, y: 440)
        let shown = CGSize(width: CGFloat(crop.width) / scale * zoom, height: CGFloat(crop.height) / scale * zoom)
        let rect = CGRect(x: center.x - shown.width / 2, y: center.y - shown.height / 2, width: shown.width, height: shown.height)
        let context = graphics.cgContext
        context.interpolationQuality = .none
        context.draw(crop, in: rect)
        NSColor(white: 1, alpha: 0.35).setStroke()
        NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
        let caption = "The shot (\(crop.width) × \(crop.height) px), shown 2×"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ]
        let captionSize = caption.size(withAttributes: attributes)
        caption.draw(at: CGPoint(x: center.x - captionSize.width / 2, y: rect.maxY + 28), withAttributes: attributes)
        return rep
    }

    private static func drawCursor(at point: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: point.x - 11, y: point.y))
        path.line(to: CGPoint(x: point.x + 11, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - 11))
        path.line(to: CGPoint(x: point.x, y: point.y + 11))
        NSColor.black.setStroke()
        path.lineWidth = 3.5
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private static func desktop() -> CGImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        let colors = [
            CGColor(srgbRed: 0.55, green: 0.45, blue: 0.95, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.55, blue: 0.75, alpha: 1),
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        context.addPath(CGPath(roundedRect: front, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: textOrigin, withAttributes: [.font: font, .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private static func inkBounds(of image: CGImage, maxX limit: CGFloat = .infinity) -> CGRect? {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, maxX = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for x in 0..<min(width, Int(min(limit * scale, CGFloat(width)))) {
                let i = (row * width + x) * 4
                if data[i] < 128, data[i + 1] < 128, data[i + 2] < 128 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minRow = min(minRow, row); maxRow = max(maxRow, row)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(height - 1 - maxRow) / scale,
            width: CGFloat(maxX + 1 - minX) / scale, height: CGFloat(maxRow + 1 - minRow) / scale
        )
    }
}
