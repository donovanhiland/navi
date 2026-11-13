import AppKit
import Testing
@testable import NaviCapture

@MainActor
struct RenderPatchTests {
    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func mark(_ kind: Annotation.Kind, _ start: CGPoint, _ end: CGPoint) -> Annotation {
        var mark = Annotation(kind: kind, start: start, end: end, color: RGBA(red: 0.1, green: 0.5, blue: 1), lineWidth: 8)
        mark.points = (0 ..< 40).map { CGPoint(x: start.x + CGFloat($0) * (end.x - start.x) / 40, y: start.y + sin(CGFloat($0)) * 30) }
        mark.text = "Hello, patch Wy"
        mark.number = 3
        if kind == .image { mark.imagePNG = ImageOps.png(SpeedBench.synthetic(width: 300, height: 240), pointSize: CGSize(width: 300, height: 240)) }
        return mark
    }

    @Test(arguments: [
        Annotation.Kind.image, .arrow, .rectangle, .filledRectangle, .ellipse, .line, .pencil, .highlighter, .text, .counter, .blur, .pixelate,
    ])
    func patchMatchesAFullRender(kind: Annotation.Kind) throws {
        let base = SpeedBench.synthetic(width: 900, height: 600)
        let renderer = AnnotationRenderer()
        let others = [Self.mark(.rectangle, CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 400))]
        let live = Self.mark(kind, CGPoint(x: 300, y: 250), CGPoint(x: 640, y: 420))
        let committed = try #require(renderer.render(base: base, marks: others))
        let patch = try #require(renderer.patch(base: base, marks: others + [live], live: live))
        let full = try #require(renderer.render(base: base, marks: others + [live]))
        let expected = try #require(full.cropping(to: patch.rect))
        let got = Self.pixels(patch.image), want = Self.pixels(expected)
        var worst = 0
        for index in got.indices where got[index] != want[index] {
            worst = max(worst, abs(Int(got[index]) - Int(want[index])))
        }
        #expect(worst <= 1)
        let rest = CGRect(x: 0, y: 0, width: 900, height: 600)
        let fullPixels = Self.pixels(full), committedPixels = Self.pixels(committed)
        var outsideDiffers = false
        for y in 0 ..< 600 {
            for x in 0 ..< 900 where !patch.rect.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                let index = (y * 900 + x) * 4
                if fullPixels[index ..< index + 4] != committedPixels[index ..< index + 4] { outsideDiffers = true }
            }
        }
        #expect(!outsideDiffers, "the mark painted outside \(patch.rect) in \(rest)")
    }
}
