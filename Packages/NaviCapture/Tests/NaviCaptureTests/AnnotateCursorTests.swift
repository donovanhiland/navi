import CoreGraphics
import Testing

@testable import NaviCapture

@MainActor
@Suite struct AnnotateCursorTests {
    private func makeModel() throws -> AnnotateModel {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        return AnnotateModel(base: image, scale: 1)
    }

    private func draw(_ tool: AnnotationTool, in model: AnnotateModel, from start: CGPoint, to end: CGPoint) {
        model.tool = tool
        model.pointerDown(at: start)
        model.pointerDragged(from: start, to: end)
        model.pointerUp(from: start, to: end)
    }

    @Test func drawingShowsACrosshairEvenOverAnOldHandle() throws {
        let model = try makeModel()
        draw(.rectangle, in: model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        model.tool = .rectangle
        let start = CGPoint(x: 200, y: 100)
        let overOldCorner = CGPoint(x: 150, y: 150)
        model.pointerDown(at: start)
        model.pointerDragged(from: start, to: overOldCorner)
        #expect(model.dragPointer(at: overOldCorner) == .crosshair)
    }

    @Test func resizingKeepsTheResizeArrowsAwayFromTheHandle() throws {
        let model = try makeModel()
        let corner = CGPoint(x: 150, y: 150)
        draw(.rectangle, in: model, from: CGPoint(x: 50, y: 50), to: corner)
        model.pointerDown(at: corner)
        let farAway = CGPoint(x: 300, y: 280)
        model.pointerDragged(from: corner, to: farAway)
        #expect(model.dragPointer(at: farAway) == .resize(.bottomRight))
    }

    @Test func movingAMarkShowsAClosedHand() throws {
        let model = try makeModel()
        draw(.line, in: model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        let middle = CGPoint(x: 100, y: 100)
        model.pointerDown(at: middle)
        let moved = CGPoint(x: 120, y: 120)
        model.pointerDragged(from: middle, to: moved)
        #expect(model.dragPointer(at: moved) == .closedHand)
    }

    @Test func afterDrawingThePointerMatchesTheNewMark() throws {
        let model = try makeModel()
        let end = CGPoint(x: 150, y: 150)
        draw(.rectangle, in: model, from: CGPoint(x: 50, y: 50), to: end)
        model.pointerMoved(to: end)
        #expect(model.tool == .select)
        #expect(model.hoverPointer == .resize(.bottomRight))
        model.pointerMoved(to: CGPoint(x: 300, y: 250))
        #expect(model.hoverPointer == .arrow)
    }

    @Test func noHoverPointerOffTheImage() throws {
        let model = try makeModel()
        model.pointerMoved(to: nil)
        #expect(model.hoverPointer == nil)
    }
}
