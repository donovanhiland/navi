import AppKit
import Testing

@testable import NaviCapture

@MainActor
@Suite(.enabled(if: !NSScreen.screens.isEmpty))
struct WindowSpotlightTests {
    private static let size = CGSize(width: 1440, height: 900)
    private static let scale: CGFloat = 2

    private static let windows: [(id: CGWindowID, name: String, frame: CGRect, tint: CGColor)] = [
        (3, "Finder", CGRect(x: 900, y: 226, width: 480, height: 610), CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)),
        (2, "Terminal", CGRect(x: 560, y: 80, width: 640, height: 400), CGColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1)),
        (1, "Safari", CGRect(x: 70, y: 280, width: 760, height: 540), CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)),
    ]

    private struct Rig {
        let session: SelectionSession
        let view: OverlayView
        let outcome: () -> SelectionSession.Outcome?
    }

    private func makeRig() -> Rig {
        let screen = NSScreen.screens[0]
        let origin = screen.frame.origin
        let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: ScreenGrabber.finderBundleID).first?.processIdentifier ?? 0
        let onScreen = Self.windows.map {
            OnScreenWindow(
                id: $0.id, frame: $0.frame.offsetBy(dx: origin.x, dy: origin.y),
                appName: $0.name, ownerPID: $0.name == "Finder" ? finderPID : 0
            )
        }
        var result: SelectionSession.Outcome?
        let session = SelectionSession(screens: [screen], mode: .area, windows: onScreen) { result = $0 }
        let view = OverlayView(session: session, screen: screen)
        view.setFrameSize(Self.size)
        view.captured = CapturedImage(image: Self.desktop(), scale: Self.scale)
        return Rig(session: session, view: view, outcome: { result })
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    @Test func clickOnAWindowPicksThatWindow() throws {
        let rig = makeRig()
        let point = CGPoint(x: 1100, y: 600)
        rig.view.mouseMoved(with: event(.mouseMoved, at: point))
        rig.view.mouseDown(with: event(.leftMouseDown, at: point))
        rig.view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 1103, y: 603)))
        rig.view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 1103, y: 603)))
        guard case let .window(id, _) = try #require(rig.outcome()) else {
            Issue.record("Expected a window, got \(String(describing: rig.outcome()))")
            return
        }
        #expect(id == 3)
    }

    @Test func dragInsideAWindowSelectsAnArea() throws {
        let rig = makeRig()
        let start = CGPoint(x: 200, y: 700)
        rig.view.mouseDown(with: event(.leftMouseDown, at: start))
        rig.view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 400, y: 500)))
        rig.view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 400, y: 500)))
        guard case let .area(_, _, rect) = try #require(rig.outcome()) else {
            Issue.record("Expected an area, got \(String(describing: rig.outcome()))")
            return
        }
        #expect(rect.width == 200.5)
        #expect(rect.height == 200.5)
    }

    @Test func clickOnTheDesktopPicksNothing() {
        let rig = makeRig()
        let point = CGPoint(x: 40, y: 40)
        rig.view.mouseDown(with: event(.leftMouseDown, at: point))
        rig.view.mouseUp(with: event(.leftMouseUp, at: point))
        if let outcome = rig.outcome() { Issue.record("Expected nothing, got \(outcome)") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NAVI_SNAPSHOTS"] != nil))
    func frames() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var index = 0
        var mouse = CGPoint(x: 360, y: 140)

        func frame(_ rig: Rig) throws {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 30.0))
            let rep = try #require(rig.view.bitmapImageRepForCachingDisplay(in: rig.view.bounds))
            rig.view.cacheDisplay(in: rig.view.bounds, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            Self.drawCursor(at: mouse)
            NSGraphicsContext.restoreGraphicsState()
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: String(format: "spotlight-%04d.png", index)))
            index += 1
        }
        func glide(_ rig: Rig, to target: CGPoint, frames count: Int, dragging: Bool = false) throws {
            let start = mouse
            for step in 1...count {
                let t = CaptureGeometry.easeOut(CGFloat(step) / CGFloat(count))
                mouse = CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
                if dragging {
                    rig.view.mouseDragged(with: event(.leftMouseDragged, at: mouse))
                } else {
                    rig.view.mouseMoved(with: event(.mouseMoved, at: mouse))
                }
                try frame(rig)
            }
        }
        func hold(_ rig: Rig, frames count: Int) throws { for _ in 0..<count { try frame(rig) } }

        let hover = makeRig()
        try glide(hover, to: CGPoint(x: 360, y: 140), frames: 1)
        try hold(hover, frames: 12)
        try glide(hover, to: CGPoint(x: 420, y: 560), frames: 18)
        try hold(hover, frames: 20)
        try glide(hover, to: CGPoint(x: 860, y: 260), frames: 18)
        try hold(hover, frames: 20)
        try glide(hover, to: CGPoint(x: 1130, y: 560), frames: 18)
        try hold(hover, frames: 24)
        hover.view.mouseDown(with: event(.leftMouseDown, at: mouse))
        hover.view.mouseUp(with: event(.leftMouseUp, at: mouse))
        guard case .window(3, _) = hover.outcome() else {
            Issue.record("The click did not pick the Finder window")
            return
        }

        let drag = makeRig()
        mouse = CGPoint(x: 240, y: 680)
        try glide(drag, to: mouse, frames: 1)
        try hold(drag, frames: 18)
        drag.view.mouseDown(with: event(.leftMouseDown, at: mouse))
        try glide(drag, to: CGPoint(x: 826, y: 430), frames: 36, dragging: true)
        try hold(drag, frames: 30)
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
            CGColor(srgbRed: 0.98, green: 0.72, blue: 0.45, alpha: 1),
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.11, blue: 0.16, alpha: 0.85))
        context.fill(CGRect(x: 0, y: size.height - 28, width: size.width, height: 28))
        for window in windows.reversed() { drawWindow(window.frame, tint: window.tint, in: context) }
        return context.makeImage()!
    }

    private static func drawWindow(_ frame: CGRect, tint: CGColor, in context: CGContext) {
        let radius: CGFloat = 12
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: CGColor(gray: 0, alpha: 0.55))
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(tint)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        let titleBar = CGRect(x: frame.minX, y: frame.maxY - 38, width: frame.width, height: 38)
        let dark = tint.components.map { $0[0] < 0.5 } ?? true
        context.setFillColor(dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1) : CGColor(srgbRed: 0.91, green: 0.91, blue: 0.93, alpha: 1))
        context.fill(titleBar)
        let lights = [
            CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
            CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),
        ]
        for (i, light) in lights.enumerated() {
            context.setFillColor(light)
            context.fillEllipse(in: CGRect(x: frame.minX + 14 + CGFloat(i) * 20, y: titleBar.midY - 6, width: 12, height: 12))
        }
        context.setFillColor(dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.1))
        var y = titleBar.minY - 40
        var row = 0
        while y > frame.minY + 20 {
            let widths: [CGFloat] = [0.8, 0.6, 0.9, 0.45, 0.7]
            let bar = CGRect(x: frame.minX + 28, y: y, width: (frame.width - 56) * widths[row % widths.count], height: 11)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
            context.fillPath()
            y -= 28
            row += 1
        }
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.1))
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }
}
