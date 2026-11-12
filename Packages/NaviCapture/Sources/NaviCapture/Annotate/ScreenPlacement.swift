import CoreGraphics

struct ScreenPlacement: Equatable, Sendable {
    let origin: CGPoint
    let source: CGRect?
    let scale: CGFloat

    var canReframe: Bool { source != nil }

    func frame(pointSize: CGSize) -> CGRect {
        CGRect(origin: origin, size: pointSize)
    }

    func after(_ edit: ImageEdit) -> ScreenPlacement {
        guard case let .crop(rect) = edit else {
            return ScreenPlacement(origin: origin, source: nil, scale: scale)
        }
        return ScreenPlacement(
            origin: CGPoint(x: origin.x + rect.minX / scale, y: origin.y + rect.minY / scale),
            source: source.map { CGRect(origin: CGPoint(x: $0.minX + rect.minX, y: $0.minY + rect.minY), size: rect.size) },
            scale: scale
        )
    }

    func reframed(to frame: CGRect, screenPixels: CGSize) -> (placement: ScreenPlacement, shift: CGVector)? {
        guard let source else { return nil }
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .integral
            .intersection(CGRect(origin: .zero, size: screenPixels))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        let placement = ScreenPlacement(
            origin: CGPoint(x: pixels.minX / scale, y: pixels.minY / scale), source: pixels, scale: scale
        )
        return (placement, CGVector(dx: source.minX - pixels.minX, dy: source.minY - pixels.minY))
    }
}
