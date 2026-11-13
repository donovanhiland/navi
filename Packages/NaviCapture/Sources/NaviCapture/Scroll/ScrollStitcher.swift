import CoreGraphics
import Vision

struct ScrollStitcher {
    private(set) var frames: [CGImage] = []
    private(set) var origins: [CGPoint] = []
    private(set) var latest: CGImage?
    private(set) var accepted = 0
    private var latestOrigin: CGPoint = .zero
    private var latestIsStored = false

    @discardableResult
    mutating func add(_ frame: CGImage) -> Bool {
        guard let last = latest else {
            start(frame)
            return true
        }
        guard frame.width == last.width, frame.height == last.height,
              let delta = Self.offset(of: frame, from: last)
        else { return false }
        return append(frame, offset: delta)
    }

    @discardableResult
    mutating func append(_ frame: CGImage, offset delta: CGPoint) -> Bool {
        guard latest != nil else {
            start(frame)
            return true
        }
        guard abs(delta.x) >= 2 || abs(delta.y) >= 2,
              abs(delta.x) < CGFloat(frame.width), abs(delta.y) < CGFloat(frame.height)
        else { return false }
        latest = frame
        latestOrigin = CGPoint(x: latestOrigin.x + delta.x, y: latestOrigin.y + delta.y)
        accepted += 1
        let stored = origins.last ?? .zero
        let step = max(abs(latestOrigin.x - stored.x) / CGFloat(frame.width), abs(latestOrigin.y - stored.y) / CGFloat(frame.height))
        if step >= 0.25 {
            frames.append(frame)
            origins.append(latestOrigin)
            latestIsStored = true
        } else {
            latestIsStored = false
        }
        return true
    }

    private mutating func start(_ frame: CGImage) {
        frames = [frame]
        origins = [.zero]
        latest = frame
        latestOrigin = .zero
        latestIsStored = true
        accepted = 1
    }

    private var drawnFrames: [CGImage] {
        guard let latest, !latestIsStored else { return frames }
        return frames + [latest]
    }

    private var drawnOrigins: [CGPoint] {
        latestIsStored || latest == nil ? origins : origins + [latestOrigin]
    }

    var stitchedSize: CGSize {
        guard let first = frames.first else { return .zero }
        return Self.layout(frameSize: CGSize(width: first.width, height: first.height), origins: drawnOrigins).size
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
        let (size, positions) = Self.layout(frameSize: frameSize, origins: drawnOrigins)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for (frame, position) in zip(drawnFrames, positions) {
            let rect = CGRect(x: position.x, y: size.height - position.y - frameSize.height, width: frameSize.width, height: frameSize.height)
            context.draw(frame, in: rect)
        }
        return context.makeImage()
    }
}
