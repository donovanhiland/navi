import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NaviCore

struct PNGEncoderTests {
    static func image(width: Int, height: Int, space: CFString, alpha: Bool, seed: UInt64 = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: space)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        var state = seed
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 1000) / 1000
        }
        if !alpha {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        for _ in 0 ..< 60 {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: alpha ? next() : 1))
            context.fill(CGRect(x: next() * CGFloat(width), y: next() * CGFloat(height), width: next() * CGFloat(width) / 2, height: next() * CGFloat(height) / 2))
        }
        return context.makeImage()!
    }

    static func rgba(_ image: CGImage, space: CGColorSpace) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func decode(_ data: Data) -> (CGImage, [CFString: Any])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (image, properties)
    }

    @Test(arguments: [("kCGColorSpaceDisplayP3", false), ("kCGColorSpaceSRGB", false), ("kCGColorSpaceDisplayP3", true), ("kCGColorSpaceSRGB", true)])
    func pixelsMatchTheOldEncoder(name: String, alpha: Bool) throws {
        let space = name as CFString
        let source = Self.image(width: 701, height: 413, space: space, alpha: alpha)
        let fast = try #require(PNGEncoder.fastEncode(source, pointSize: CGSize(width: 350.5, height: 206.5), level: 3))
        let reference = try #require(PNGEncoder.imageIOEncode(source, pointSize: nil))
        let (fastImage, properties) = try #require(Self.decode(fast))
        let (referenceImage, _) = try #require(Self.decode(reference))
        #expect(fastImage.width == 701 && fastImage.height == 413)
        #expect(fastImage.colorSpace?.name == CGColorSpace(name: space)?.name)
        #expect(fastImage.colorSpace?.copyICCData() as Data? == CGColorSpace(name: space)?.copyICCData() as Data?)
        #expect((properties[kCGImagePropertyDPIWidth] as? Double).map { abs($0 - 144) < 0.01 } == true)
        let compare = CGColorSpace(name: space)!
        #expect(Self.rgba(fastImage, space: compare) == Self.rgba(referenceImage, space: compare))
        #expect(Self.rgba(fastImage, space: compare) == Self.rgba(source, space: compare))
    }

    @Test func opaqueImagesDropTheAlphaChannel() throws {
        let data = try #require(PNGEncoder.encode(Self.image(width: 64, height: 64, space: CGColorSpace.sRGB, alpha: false)))
        #expect(data[25] == 2)
        let clear = try #require(PNGEncoder.encode(Self.image(width: 64, height: 64, space: CGColorSpace.sRGB, alpha: true)))
        #expect(clear[25] == 6)
    }

    @Test(arguments: [(1, 1), (1, 300), (300, 1), (5, 33), (2000, 70)])
    func oddSizesRoundTrip(width: Int, height: Int) throws {
        let source = Self.image(width: width, height: height, space: CGColorSpace.sRGB, alpha: true, seed: UInt64(width * height))
        let data = try #require(PNGEncoder.fastEncode(source, pointSize: nil, level: 3))
        let (decoded, properties) = try #require(Self.decode(data))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        #expect(Self.rgba(decoded, space: space) == Self.rgba(source, space: space))
        #expect(properties[kCGImagePropertyDPIWidth] == nil || (properties[kCGImagePropertyDPIWidth] as? Double) == 72)
    }

    @Test func grayImagesStillEncode() throws {
        let context = CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        let data = try #require(PNGEncoder.encode(context.makeImage()!))
        #expect(Self.decode(data) != nil)
    }
}
