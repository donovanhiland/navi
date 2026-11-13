import CoreGraphics
import Foundation
import ImageIO

enum ImageCaches {
    static let rowPixels = 400
    static let cardPixels = 960
    static let queue = DispatchQueue(label: "com.donovanhiland.navi.image-caches", qos: .utility)

    nonisolated static func build(file: URL, row: URL, card: URL) {
        let stamp = modified(file)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              max(width, height) > rowPixels
        else { return }
        var written: [URL] = []
        let large = max(width, height) > cardPixels
        guard let base = thumbnail(source, pixels: large ? cardPixels : rowPixels) else { return }
        if large, writePNG(base, to: card) { written.append(card) }
        let small = large ? scaled(base, pixels: rowPixels) : base
        if let small, writePNG(small, to: row) { written.append(row) }
        if modified(file) != stamp {
            for url in written { try? FileManager.default.removeItem(at: url) }
        }
    }

    private nonisolated static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private nonisolated static func thumbnail(_ source: CGImageSource, pixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func scaled(_ image: CGImage, pixels: Int) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > pixels else { return image }
        let factor = Double(pixels) / Double(longSide)
        let width = max(Int((Double(image.width) * factor).rounded()), 1)
        let height = max(Int((Double(image.height) * factor).rounded()), 1)
        let spaces = [image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for space in spaces {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let result = context.makeImage() { return result }
        }
        return nil
    }

    private nonisolated static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let data = PNGEncoder.encode(image) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
