import CoreGraphics
import Testing

@testable import NaviCapture

@Suite struct ImageOpsTests {
    private func redBlue() -> CGImage {
        var bytes: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let context = CGContext(
            data: &bytes, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [[UInt8]] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0 ..< $0 + 4]) }
    }

    @Test func rotateClockwisePutsTheLeftSideOnTop() throws {
        let rotated = try #require(ImageOps.apply(.rotateClockwise, to: redBlue()))
        #expect(rotated.width == 1 && rotated.height == 2)
        let result = pixels(rotated)
        #expect(result[0][0] > 200 && result[0][2] < 50)
        #expect(result[1][2] > 200 && result[1][0] < 50)
    }

    @Test func flipHorizontalSwapsSides() throws {
        let flipped = try #require(ImageOps.apply(.flipHorizontal, to: redBlue()))
        let result = pixels(flipped)
        #expect(result[0][2] > 200)
        #expect(result[1][0] > 200)
    }

    @MainActor
    @Test func rendererKeepsTheImageSize() throws {
        let image = try #require(ImageOps.apply(.resize(50), to: redBlue()))
        let mark = Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 80, y: 40), color: .red, lineWidth: 4)
        let rendered = try #require(AnnotationRenderer().render(base: image, marks: [mark]))
        #expect(rendered.width == image.width && rendered.height == image.height)
    }
}
