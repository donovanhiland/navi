import AppKit
import SwiftUI
import Testing

@testable import NaviCapture

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAVI_FRAME_DEMO"] != nil))
struct FrameAdjustDemoTests {
    static let screen = CGSize(width: 1440, height: 900)
    static let fps = 30.0
    static let area = CGRect(x: 430, y: 210, width: 430, height: 250)

    enum Drag {
        case none
        case handle(CaptureGeometry.FrameHandle)
        case grip
    }

    struct Step {
        let to: CGPoint
        let seconds: Double
        var drag: Drag = .none
    }

    static let steps: [Step] = [
        Step(to: CGPoint(x: 640, y: 340), seconds: 0.8),
        Step(to: CGPoint(x: 862, y: 462), seconds: 0.6),
        Step(to: CGPoint(x: 862, y: 462), seconds: 0.5),
        Step(to: CGPoint(x: 1010, y: 560), seconds: 1.0, drag: .handle(.bottomRight)),
        Step(to: CGPoint(x: 1010, y: 560), seconds: 0.5),
        Step(to: CGPoint(x: 720, y: 186), seconds: 0.7),
        Step(to: CGPoint(x: 720, y: 186), seconds: 0.4),
        Step(to: CGPoint(x: 630, y: 126), seconds: 1.0, drag: .grip),
        Step(to: CGPoint(x: 630, y: 126), seconds: 0.5),
        Step(to: CGPoint(x: 630, y: 151), seconds: 0.5),
        Step(to: CGPoint(x: 630, y: 151), seconds: 0.4),
        Step(to: CGPoint(x: 630, y: 90), seconds: 0.8, drag: .handle(.top)),
        Step(to: CGPoint(x: 630, y: 90), seconds: 0.5),
        Step(to: CGPoint(x: 341, y: 325), seconds: 0.6),
        Step(to: CGPoint(x: 341, y: 325), seconds: 0.3),
        Step(to: CGPoint(x: 400, y: 325), seconds: 0.7, drag: .handle(.left)),
        Step(to: CGPoint(x: 400, y: 325), seconds: 0.4),
        Step(to: CGPoint(x: 640, y: 330), seconds: 0.6),
        Step(to: CGPoint(x: 640, y: 330), seconds: 1.2),
    ]

    @Test func recordFrames() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_FRAME_DEMO"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backdrop = try EditorSnapshotTests.backdrop(size: CGSize(width: Self.screen.width * 2, height: Self.screen.height * 2))
        let model = try Self.model(backdrop: backdrop)
        let view = NSHostingView(rootView: Self.view(model: model, backdrop: backdrop, reveal: 0))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(origin: .zero, size: Self.screen)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        var reveal: CGFloat = 0
        var cursor = Self.steps[0].to
        var frame = 0
        for step in Self.steps {
            let from = cursor
            let start = model.placement?.frame(pointSize: model.pointSize) ?? Self.area
            if case .none = step.drag {} else { model.beginReframe() }
            let count = max(1, Int(step.seconds * Self.fps))
            for index in 1...count {
                let t = Double(index) / Double(count)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                cursor = CGPoint(x: from.x + (step.to.x - from.x) * eased, y: from.y + (step.to.y - from.y) * eased)
                switch step.drag {
                case .none: break
                case let .handle(handle):
                    let bounds = CGRect(origin: .zero, size: Self.screen)
                    model.reframe(to: CaptureGeometry.resized(start, handle: handle, to: cursor, within: bounds, minSize: 8), screen: backdrop)
                case .grip:
                    let offset = CGVector(dx: cursor.x - from.x, dy: cursor.y - from.y)
                    model.reframe(to: CaptureGeometry.moved(start, by: offset, within: CGRect(origin: .zero, size: Self.screen)), screen: backdrop)
                }
                let hole = model.placement?.frame(pointSize: model.pointSize) ?? Self.area
                reveal = Self.nextReveal(reveal, hole: hole, cursor: cursor, dragging: !Self.isNone(step.drag))
                view.rootView = Self.view(model: model, backdrop: backdrop, reveal: reveal)
                view.layoutSubtreeIfNeeded()
                let image = Self.cursorImage(for: step.drag, at: cursor, hole: hole)
                try Self.writeFrame(view: view, cursor: cursor, image: image, to: folder.appending(path: String(format: "frame-%04d.png", frame)))
                frame += 1
            }
        }
    }

    private static func isNone(_ drag: Drag) -> Bool {
        if case .none = drag { return true }
        return false
    }

    private static func nextReveal(_ reveal: CGFloat, hole: CGRect, cursor: CGPoint, dragging: Bool) -> CGFloat {
        let near = InPlaceAnnotateView.isNearFrame(cursor, hole: hole)
        let target: CGFloat = dragging || near ? 1 : 0
        let step = CGFloat(1 / (0.18 * fps))
        return target > reveal ? min(target, reveal + step) : max(target, reveal - step)
    }

    private static func cursorImage(for drag: Drag, at point: CGPoint, hole: CGRect) -> NSCursor {
        switch drag {
        case let .handle(handle): return FrameAdjuster.cursor(for: handle)
        case .grip: return .closedHand
        case .none:
            let tab = FrameAdjuster.moveTabZone(of: hole)
            if abs(point.x - tab.midX) < 40, abs(point.y - tab.midY) < tab.height / 2 { return .openHand }
            if let handle = CaptureGeometry.frameHandle(of: hole, near: point, tolerance: FrameAdjuster.grab) {
                return FrameAdjuster.cursor(for: handle)
            }
            return hole.contains(point) ? .crosshair : .arrow
        }
    }

    private static func model(backdrop: CGImage) throws -> AnnotateModel {
        let pixels = CGRect(x: area.minX * 2, y: area.minY * 2, width: area.width * 2, height: area.height * 2)
        let placement = ScreenPlacement(origin: area.origin, source: pixels, scale: 2)
        let model = AnnotateModel(base: try #require(backdrop.cropping(to: pixels)), scale: 2, placement: placement)
        model.tool = .arrow
        model.pointerDown(at: CGPoint(x: 120, y: 420))
        model.pointerDragged(from: CGPoint(x: 120, y: 420), to: CGPoint(x: 360, y: 230))
        model.pointerUp(from: CGPoint(x: 120, y: 420), to: CGPoint(x: 360, y: 230))
        model.tool = .rectangle
        model.pointerDown(at: CGPoint(x: 400, y: 110))
        model.pointerDragged(from: CGPoint(x: 400, y: 110), to: CGPoint(x: 780, y: 300))
        model.pointerUp(from: CGPoint(x: 400, y: 110), to: CGPoint(x: 780, y: 300))
        model.tool = .rectangle
        return model
    }

    private static func view(model: AnnotateModel, backdrop: CGImage, reveal: CGFloat) -> InPlaceAnnotateView {
        InPlaceAnnotateView(model: model, backdrop: backdrop, area: area, onDone: {}, onSave: {}, onStash: {}, onCancel: {}, revealOverride: reveal)
    }

    private static func writeFrame(view: NSView, cursor point: CGPoint, image cursor: NSCursor, to url: URL) throws {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let size = cursor.image.size
        let hot = cursor.hotSpot
        cursor.image.draw(in: CGRect(x: point.x - hot.x, y: screen.height - point.y - (size.height - hot.y), width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
