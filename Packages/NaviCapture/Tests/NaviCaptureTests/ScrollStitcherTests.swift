import CoreGraphics
import Testing

@testable import NaviCapture

@Suite struct ScrollStitcherTests {
    private func noise(width: Int = 200, height: Int = 600) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 42
        for index in 0 ..< width * height {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let value = UInt8(truncatingIfNeeded: seed >> 33)
            bytes[index * 4] = value
            bytes[index * 4 + 1] = value &+ 40
            bytes[index * 4 + 2] = value &+ 90
            bytes[index * 4 + 3] = 255
        }
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test func layoutCoversEveryFrame() {
        let (size, positions) = ScrollStitcher.layout(
            frameSize: CGSize(width: 100, height: 50),
            origins: [.zero, CGPoint(x: 0, y: 30), CGPoint(x: 0, y: 70)]
        )
        #expect(size == CGSize(width: 100, height: 120))
        #expect(positions.last == CGPoint(x: 0, y: 70))
    }

    @Test func layoutHandlesScrollingUpAndLeft() {
        let (size, positions) = ScrollStitcher.layout(
            frameSize: CGSize(width: 100, height: 50), origins: [.zero, CGPoint(x: -20, y: -10)]
        )
        #expect(size == CGSize(width: 120, height: 60))
        #expect(positions == [CGPoint(x: 20, y: 10), .zero])
    }

    @Test func stitchesFramesScrolledDown() throws {
        let page = noise()
        var stitcher = ScrollStitcher()
        for top in [0, 100, 220] {
            stitcher.add(try #require(page.cropping(to: CGRect(x: 0, y: top, width: 150, height: 300))))
        }
        #expect(stitcher.origins == [.zero, CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 220)])
        let result = try #require(stitcher.stitched())
        #expect(result.width == 150)
        #expect(result.height == 520)
    }

    @Test func skipsFramesThatDidNotMove() throws {
        let frame = try #require(noise().cropping(to: CGRect(x: 0, y: 0, width: 150, height: 300)))
        var stitcher = ScrollStitcher()
        let first = stitcher.add(frame)
        let second = stitcher.add(frame)
        #expect(first)
        #expect(!second)
        #expect(stitcher.frames.count == 1)
    }
}
