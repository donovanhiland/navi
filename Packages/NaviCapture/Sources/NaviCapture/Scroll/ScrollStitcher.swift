import CoreGraphics
import Vision

struct ScrollStitcher {
    private(set) var frames: [CGImage] = []
    private(set) var origins: [CGPoint] = []

    @discardableResult
    mutating func add(_ frame: CGImage) -> Bool {
        guard let last = frames.last else {
            frames = [frame]
            origins = [.zero]
            return true
        }
        guard frame.width == last.width, frame.height == last.height,
              let delta = Self.offset(of: frame, from: last)
        else { return false }
        return append(frame, offset: delta)
    }

    @discardableResult
    mutating func append(_ frame: CGImage, offset delta: CGPoint) -> Bool {
        guard let lastOrigin = origins.last else {
            frames = [frame]
            origins = [.zero]
            return true
        }
        guard abs(delta.x) >= 2 || abs(delta.y) >= 2,
              abs(delta.x) < CGFloat(frame.width), abs(delta.y) < CGFloat(frame.height)
        else { return false }
        frames.append(frame)
        origins.append(CGPoint(x: lastOrigin.x + delta.x, y: lastOrigin.y + delta.y))
        return true
    }

    var stitchedSize: CGSize {
        guard let first = frames.first else { return .zero }
        return Self.layout(frameSize: CGSize(width: first.width, height: first.height), origins: origins).size
    }

    static func offset(of frame: CGImage, from reference: CGImage) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: frame)
        do {
            try VNImageRequestHandler(cgImage: reference).perform([request])
        } catch {
            return nil
        }
        guard let transform = request.results?.first?.alignmentTransform else { return nil }
        return CGPoint(x: transform.tx.rounded(), y: (-transform.ty).rounded())
    }

    static func layout(frameSize: CGSize, origins: [CGPoint]) -> (size: CGSize, positions: [CGPoint]) {
        guard !origins.isEmpty else { return (.zero, []) }
        let minX = origins.map(\.x).min() ?? 0, minY = origins.map(\.y).min() ?? 0
        let maxX = (origins.map(\.x).max() ?? 0) + frameSize.width
        let maxY = (origins.map(\.y).max() ?? 0) + frameSize.height
        let positions = origins.map { CGPoint(x: $0.x - minX, y: $0.y - minY) }
        return (CGSize(width: maxX - minX, height: maxY - minY), positions)
    }

    func stitched() -> CGImage? {
        guard let first = frames.first else { return nil }
        let frameSize = CGSize(width: first.width, height: first.height)
        let (size, positions) = Self.layout(frameSize: frameSize, origins: origins)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for (frame, position) in zip(frames, positions) {
            let rect = CGRect(x: position.x, y: size.height - position.y - frameSize.height, width: frameSize.width, height: frameSize.height)
            context.draw(frame, in: rect)
        }
        return context.makeImage()
    }
}
