import CoreGraphics
import Testing
@testable import NaviCapture

@Suite struct FrameHandleTests {
    private static let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    private func handle(_ x: CGFloat, _ y: CGFloat) -> CaptureGeometry.FrameHandle? {
        CaptureGeometry.frameHandle(of: Self.rect, near: CGPoint(x: x, y: y), tolerance: 8)
    }

    @Test func cornersWinOverEdges() {
        #expect(handle(102, 98) == .topLeft)
        #expect(handle(298, 97) == .topRight)
        #expect(handle(95, 204) == .bottomLeft)
        #expect(handle(305, 196) == .bottomRight)
    }

    @Test func edgesGrabOnEitherSideOfTheLine() {
        #expect(handle(200, 94) == .top)
        #expect(handle(200, 105) == .top)
        #expect(handle(200, 203) == .bottom)
        #expect(handle(96, 150) == .left)
        #expect(handle(303, 150) == .right)
    }

    @Test func insideAndFarAwayGrabNothing() {
        #expect(handle(200, 150) == nil)
        #expect(handle(200, 220) == nil)
        #expect(handle(330, 150) == nil)
    }

    @Test @MainActor func theMoveTabStaysClearOfTheTopEdge() {
        let frame = CGRect(x: 200, y: 300, width: 400, height: 200)
        let tab = FrameAdjuster.moveTabZone(of: frame)
        #expect(tab.maxY < frame.minY - FrameAdjuster.grab)
        #expect(tab.midX == frame.midX)
        #expect(CaptureGeometry.frameHandle(of: frame, near: CGPoint(x: frame.midX, y: frame.minY - 3), tolerance: FrameAdjuster.grab) == .top)
        #expect(!tab.contains(CGPoint(x: frame.midX, y: frame.minY - FrameAdjuster.grab)))
    }

    @Test @MainActor func theMoveTabGoesInsideAtTheTopOfTheScreen() {
        let frame = CGRect(x: 200, y: 10, width: 400, height: 200)
        let tab = FrameAdjuster.moveTabZone(of: frame)
        #expect(tab.minY > frame.minY + 4)
        #expect(tab.maxY < frame.maxY)
    }

    @Test func draggingAHandleMovesOnlyItsEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let resize = { (handle: CaptureGeometry.FrameHandle, x: CGFloat, y: CGFloat) in
            CaptureGeometry.resized(Self.rect, handle: handle, to: CGPoint(x: x, y: y), within: bounds, minSize: 8)
        }
        #expect(resize(.right, 400, 999) == CGRect(x: 100, y: 100, width: 300, height: 100))
        #expect(resize(.left, 50, 0) == CGRect(x: 50, y: 100, width: 250, height: 100))
        #expect(resize(.top, 0, 40) == CGRect(x: 100, y: 40, width: 200, height: 160))
        #expect(resize(.bottom, 0, 150) == CGRect(x: 100, y: 100, width: 200, height: 50))
        #expect(resize(.topLeft, 80, 90) == CGRect(x: 80, y: 90, width: 220, height: 110))
        #expect(resize(.bottomRight, 320, 230) == CGRect(x: 100, y: 100, width: 220, height: 130))
    }

    @Test func resizingStopsAtTheMinimumSizeAndTheScreenEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(CaptureGeometry.resized(Self.rect, handle: .left, to: CGPoint(x: 900, y: 0), within: bounds, minSize: 8)
            == CGRect(x: 292, y: 100, width: 8, height: 100))
        #expect(CaptureGeometry.resized(Self.rect, handle: .bottom, to: CGPoint(x: 0, y: 20), within: bounds, minSize: 8)
            == CGRect(x: 100, y: 100, width: 200, height: 8))
        #expect(CaptureGeometry.resized(Self.rect, handle: .bottomRight, to: CGPoint(x: 1200, y: 900), within: bounds, minSize: 8)
            == CGRect(x: 100, y: 100, width: 900, height: 700))
    }
}

@Suite struct ScreenPlacementTests {
    private static let placement = ScreenPlacement(
        origin: CGPoint(x: 100, y: 50), source: CGRect(x: 200, y: 100, width: 400, height: 200), scale: 2
    )

    @Test func theFrameIsTheSourceInPoints() {
        #expect(Self.placement.frame(pointSize: CGSize(width: 200, height: 100)) == CGRect(x: 100, y: 50, width: 200, height: 100))
    }

    @Test func aCropKeepsThePixelsWhereTheyAreOnScreen() {
        let cropped = Self.placement.after(.crop(CGRect(x: 40, y: 20, width: 100, height: 60)))
        #expect(cropped.origin == CGPoint(x: 120, y: 60))
        #expect(cropped.source == CGRect(x: 240, y: 120, width: 100, height: 60))
    }

    @Test func otherImageEditsLockTheFrame() {
        for edit: ImageEdit in [.rotateClockwise, .flipHorizontal, .resize(0.5)] {
            let edited = Self.placement.after(edit)
            #expect(edited.origin == Self.placement.origin)
            #expect(edited.source == nil)
            #expect(!edited.canReframe)
        }
    }

    @Test func reframingGivesTheNewSourceAndHowFarTheMarksMove() throws {
        let screen = CGSize(width: 2880, height: 1800)
        let moved = try #require(Self.placement.reframed(to: CGRect(x: 90, y: 60, width: 250, height: 100), screenPixels: screen))
        #expect(moved.placement.source == CGRect(x: 180, y: 120, width: 500, height: 200))
        #expect(moved.placement.origin == CGPoint(x: 90, y: 60))
        #expect(moved.shift == CGVector(dx: 20, dy: -20))
    }

    @Test func reframingStaysInsideTheScreenImage() throws {
        let screen = CGSize(width: 1000, height: 600)
        let moved = try #require(Self.placement.reframed(to: CGRect(x: -10, y: 250, width: 300, height: 100), screenPixels: screen))
        #expect(moved.placement.source == CGRect(x: 0, y: 500, width: 580, height: 100))
    }

    @Test func aLockedFrameCannotBeReframed() {
        let locked = Self.placement.after(.rotateClockwise)
        #expect(locked.reframed(to: CGRect(x: 0, y: 0, width: 50, height: 50), screenPixels: CGSize(width: 1000, height: 600)) == nil)
    }
}

@MainActor
@Suite struct AnnotateModelReframeTests {
    private static func screen() -> CGImage {
        let context = CGContext(
            data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func model() -> (AnnotateModel, CGImage) {
        let screen = Self.screen()
        let source = CGRect(x: 100, y: 100, width: 200, height: 100)
        let placement = ScreenPlacement(origin: CGPoint(x: 50, y: 50), source: source, scale: 2)
        return (AnnotateModel(base: screen.cropping(to: source)!, scale: 2, placement: placement), screen)
    }

    private func drawRectangle(on model: AnnotateModel) {
        model.tool = .rectangle
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        model.pointerUp(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
    }

    @Test func reframingChangesTheBaseAndKeepsMarksOnTheirPixels() throws {
        let (model, screen) = model()
        drawRectangle(on: model)
        model.beginReframe()
        model.reframe(to: CGRect(x: 40, y: 45, width: 150, height: 60), screen: screen)
        #expect(model.pixelSize == CGSize(width: 300, height: 120))
        #expect(model.placement?.source == CGRect(x: 80, y: 90, width: 300, height: 120))
        let mark = try #require(model.document.annotations.first)
        #expect(mark.start == CGPoint(x: 30, y: 20))
        #expect(mark.end == CGPoint(x: 80, y: 50))
    }

    @Test func oneUndoPutsTheWholeDragBack() {
        let (model, screen) = model()
        model.beginReframe()
        model.reframe(to: CGRect(x: 40, y: 45, width: 150, height: 60), screen: screen)
        model.reframe(to: CGRect(x: 30, y: 45, width: 160, height: 60), screen: screen)
        model.undo()
        #expect(model.pixelSize == CGSize(width: 200, height: 100))
        #expect(model.placement?.source == CGRect(x: 100, y: 100, width: 200, height: 100))
        model.redo()
        #expect(model.placement?.source == CGRect(x: 60, y: 90, width: 320, height: 120))
    }

    @Test func aCropMovesTheFrameSoThePixelsStayPut() {
        let (model, _) = model()
        model.apply(.crop(CGRect(x: 20, y: 10, width: 100, height: 60)))
        #expect(model.placement?.origin == CGPoint(x: 60, y: 55))
        #expect(model.placement?.source == CGRect(x: 120, y: 110, width: 100, height: 60))
    }
}
