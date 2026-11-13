import AppKit
import SwiftUI
import Testing
@testable import NaviCapture

@MainActor
@Suite(.enabled(if: SpeedBench.enabled && !NSScreen.screens.isEmpty), .serialized)
struct UIPathBench {
    static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    static func flush(_ windows: [NSWindow]) {
        for window in windows { window.displayIfNeeded() }
        CATransaction.flush()
    }

    static func overlayWindows() -> [NSWindow] {
        NSApp.windows.filter { $0 is OverlayWindow && $0.isVisible }
    }

    @Test func selectionOpensDragsAndCloses() async throws {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
        let frozen = SpeedBench.screen(width: Int(screen.frame.width * screen.backingScaleFactor), height: Int(screen.frame.height * screen.backingScaleFactor))
        let windows = ScreenGrabber.onScreenWindows()
        var sessions: [SelectionSession] = []
        _ = SpeedBench.time("select-open-to-drawn", iterations: 12) {
            let session = SelectionSession(screens: NSScreen.screens, mode: .area, windows: windows) { _ in }
            session.begin()
            Self.flush(Self.overlayWindows())
            sessions.append(session)
            session.finish(.cancelled)
        }
        var made: SelectionSession?
        _ = SpeedBench.time("select-part-init", iterations: 12) {
            made = SelectionSession(screens: NSScreen.screens, mode: .area, windows: windows) { _ in }
            made?.finish(.cancelled)
        }
        _ = SpeedBench.time("select-part-windowlist", iterations: 12) { _ = ScreenGrabber.onScreenWindows() }
        var laps: [String: [Double]] = [:]
        func lap(_ name: String, _ start: inout ContinuousClock.Instant) {
            let d = ContinuousClock.now - start
            laps[name, default: []].append(Double(d.components.attoseconds) / 1e15)
            start = .now
        }
        for _ in 0 ..< 12 {
            var t = ContinuousClock.now
            let session = SelectionSession(screens: NSScreen.screens, mode: .area, windows: windows) { _ in }
            lap("init", &t)
            session.begin()
            lap("begin", &t)
            for window in Self.overlayWindows() { window.displayIfNeeded() }
            lap("display", &t)
            CATransaction.flush()
            lap("flush", &t)
            session.finish(.cancelled)
            lap("finish", &t)
        }
        for (name, values) in laps.sorted(by: { $0.key < $1.key }) {
            print("BENCH   lap \(name) median \(String(format: "%.2f", values.sorted()[values.count / 2])) ms")
        }
        var pending: SelectionSession?
        _ = SpeedBench.time("select-part-begin", iterations: 12) {
            pending?.finish(.cancelled)
            pending = SelectionSession(screens: NSScreen.screens, mode: .area, windows: windows) { _ in }
            let start = ContinuousClock.now
            pending?.begin()
            _ = start
        }
        pending?.finish(.cancelled)
        _ = SpeedBench.time("select-freeze-swap", iterations: 12) {
            let session = SelectionSession(screens: NSScreen.screens, mode: .area, windows: windows) { _ in }
            session.begin()
            Self.flush(Self.overlayWindows())
            session.freeze([(screen, CapturedImage(image: frozen, scale: screen.backingScaleFactor))])
            Self.flush(Self.overlayWindows())
            session.finish(.cancelled)
        }
        let session = SelectionSession(screens: [screen], mode: .area, windows: windows) { _ in }
        session.begin()
        session.freeze([(screen, CapturedImage(image: frozen, scale: screen.backingScaleFactor))])
        let window = try #require(Self.overlayWindows().first as? OverlayWindow)
        Self.flush([window])
        var point = CGPoint(x: 300, y: 300)
        _ = SpeedBench.time("hover-frame", iterations: 120) {
            point.x += 3
            point.y += 1
            window.overlayView.mouseMoved(with: Self.mouse(.mouseMoved, at: point, in: window))
            Self.flush([window])
        }
        window.overlayView.mouseDown(with: Self.mouse(.leftMouseDown, at: point, in: window))
        _ = SpeedBench.time("drag-frame", iterations: 120) {
            point.x += 4
            point.y -= 2
            window.overlayView.mouseDragged(with: Self.mouse(.leftMouseDragged, at: point, in: window))
            Self.flush([window])
        }
        session.finish(.cancelled)
        _ = sessions
    }

    @Test func editorOpens() async throws {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        let backdrop = SpeedBench.screen(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale))
        let area = CGRect(x: 200, y: 150, width: 700, height: 450)
        let piece = try #require(backdrop.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)))
        _ = SpeedBench.time("editor-open-to-drawn", iterations: 10) {
            let editor = InPlaceAnnotator(
                captured: CapturedImage(image: piece, scale: scale), backdrop: backdrop, screen: screen, area: area
            ) { _ in }
            editor.show()
            let shown = NSApp.windows.filter { $0.level == .popUpMenu && $0.isVisible }
            Self.flush(shown)
            for window in shown { window.orderOut(nil) }
            withExtendedLifetime(editor) {}
        }
        var stages = (0 ..< 13).map { _ in InPlaceAnnotator.Stage(screen: screen) }
        _ = SpeedBench.time("editor-open-staged", iterations: 10) {
            let editor = InPlaceAnnotator(
                captured: CapturedImage(image: piece, scale: scale), backdrop: backdrop, screen: screen, area: area
            ) { _ in }
            editor.show(on: stages.removeLast())
            let shown = NSApp.windows.filter { $0.level == .popUpMenu && $0.isVisible }
            Self.flush(shown)
            for window in shown { window.orderOut(nil) }
            withExtendedLifetime(editor) {}
        }
    }

    @Test func editorSwapCost() async throws {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        let backdrop = SpeedBench.screen(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale))
        let area = CGRect(x: 200, y: 150, width: 700, height: 450)
        let piece = try #require(backdrop.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)))
        func view(_ model: AnnotateModel, _ backdrop: CGImage?) -> InPlaceAnnotateView {
            InPlaceAnnotateView(model: model, backdrop: backdrop, area: area, onDone: {}, onSave: {}, onStash: {}, onCancel: {})
        }
        let tiny = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        _ = SpeedBench.time("editor-fresh-hosting", iterations: 10) {
            let model = AnnotateModel(base: piece, scale: scale)
            let hosting = NSHostingView(rootView: view(model, backdrop))
            hosting.frame = screen.frame
            hosting.layoutSubtreeIfNeeded()
        }
        var hostings: [NSHostingView<InPlaceAnnotateView>] = []
        for _ in 0 ..< 13 {
            let hosting = NSHostingView(rootView: view(AnnotateModel(base: tiny, scale: scale), nil))
            hosting.frame = screen.frame
            hosting.layoutSubtreeIfNeeded()
            hostings.append(hosting)
        }
        var index = 0
        _ = SpeedBench.time("editor-swap-into-prebuilt", iterations: 10) {
            let model = AnnotateModel(base: piece, scale: scale)
            hostings[index].rootView = view(model, backdrop)
            hostings[index].layoutSubtreeIfNeeded()
            index += 1
        }
        _ = SpeedBench.time("editor-model-only", iterations: 10) { _ = AnnotateModel(base: piece, scale: scale) }
    }

    @Test func cardShows() async throws {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
        let image = SpeedBench.screen(width: 2000, height: 1300)
        let png = try #require(ImageOps.png(image, pointSize: CGSize(width: 1000, height: 650)))
        let stack = CardStack()
        var cards: [Card] = []
        _ = SpeedBench.time("card-show", iterations: 10) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            bitmap.size = CGSize(width: 1000, height: 650)
            let nsImage = NSImage(size: bitmap.size)
            nsImage.addRepresentation(bitmap)
            guard let card = try? Card(inboxID: nil, image: nsImage, png: png, createdAt: .now) else { return }
            stack.show(card, on: screen)
            for window in NSApp.windows where window is CardPanel { window.displayIfNeeded() }
            CATransaction.flush()
            cards.append(card)
        }
        stack.closeAll()
        _ = SpeedBench.time("pasteboard-image-write", iterations: 10) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            bitmap.size = CGSize(width: 1000, height: 650)
            let nsImage = NSImage(size: bitmap.size)
            nsImage.addRepresentation(bitmap)
            let board = NSPasteboard(name: NSPasteboard.Name("navi-bench"))
            board.clearContents()
            board.writeObjects([nsImage])
        }
    }
}
