import AppKit
import NaviCore
import CoreImage
import CoreImage.CIFilterBuiltins

@MainActor
final class AnnotationRenderer {
    private var effectsBase: CGImage?
    private var blurred: CGImage?
    private var pixelated: CGImage?

    func render(base: CGImage, marks: [Annotation], selection: UUID? = nil, region: CGRect? = nil) -> CGImage? {
        let width = base.width, height = base.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let area = region ?? full
        guard area.width >= 1, area.height >= 1, let context = CGContext(
            data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: area.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -area.minX, y: -area.minY)
        if region != nil, let piece = base.cropping(to: area) {
            Self.draw(piece, in: area, context: context)
        } else {
            Self.draw(base, in: full, context: context)
        }

        let effects = marks.filter { $0.kind == .blur || $0.kind == .pixelate }
        if !effects.isEmpty { prepareEffects(for: base) }
        for mark in effects {
            guard let image = mark.kind == .blur ? blurred : pixelated else { continue }
            context.saveGState()
            context.clip(to: CaptureGeometry.rect(from: mark.start, to: mark.end))
            if region != nil, let piece = image.cropping(to: area) {
                Self.draw(piece, in: area, context: context)
            } else {
                Self.draw(image, in: full, context: context)
            }
            context.restoreGState()
        }

        let spots = marks.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            context.saveGState()
            context.addRect(full)
            for spot in spots {
                let rect = CaptureGeometry.rect(from: spot.start, to: spot.end)
                let radius = min(12 * CGFloat(spot.lineWidth) / 4, rect.width / 2, rect.height / 2)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
            context.setFillColor(CGColor(gray: 0, alpha: 0.55))
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for mark in marks { draw(mark, context: context) }
        if let selection, let mark = marks.first(where: { $0.id == selection }) {
            drawSelection(of: mark, imageWidth: CGFloat(width), context: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    struct Patch {
        let image: CGImage
        let rect: CGRect
    }

    func patch(base: CGImage, marks: [Annotation], live: Annotation) -> Patch? {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let margin = max(CGFloat(live.lineWidth) * 4, CGFloat(live.fontSize)) + 48
        let rect = paintedBounds(of: live).insetBy(dx: -margin, dy: -margin).integral.intersection(full)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let image = render(base: base, marks: marks, region: rect)
        else { return nil }
        return Patch(image: image, rect: rect)
    }

    private func paintedBounds(of mark: Annotation) -> CGRect {
        switch mark.kind {
        case .text:
            let size = ((mark.text ?? "") as NSString).size(withAttributes: textAttributes(for: mark))
            return CGRect(origin: mark.start, size: size).union(mark.bounds)
        case .arrow, .line:
            return CaptureGeometry.rect(from: mark.start, to: mark.end)
        default:
            return mark.bounds.isNull ? CGRect(origin: mark.start, size: .zero) : mark.bounds
        }
    }

    private func textAttributes(for mark: Annotation) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: CGFloat(mark.fontSize), weight: .bold),
            .foregroundColor: NSColor(cgColor: mark.color.cgColor) ?? .red,
            .strokeColor: NSColor.white,
            .strokeWidth: -2.5,
        ]
    }

    private func drawSelection(of mark: Annotation, imageWidth: CGFloat, context: CGContext) {
        let blue = CGColor(srgbRed: 0.2, green: 0.55, blue: 1, alpha: 1)
        let line = max(2, imageWidth / 800)
        context.saveGState()
        context.setLineWidth(line)
        context.setStrokeColor(.white)
        let outline = mark.isBox ? mark.box : mark.bounds.insetBy(dx: -6, dy: -6)
        if mark.kind != .arrow, mark.kind != .line {
            context.stroke(outline)
            context.setStrokeColor(blue)
            context.setLineDash(phase: 0, lengths: [line * 4, line * 3])
            context.stroke(outline)
            context.setLineDash(phase: 0, lengths: [])
        }
        context.setStrokeColor(blue)
        for handle in mark.handles {
            let radius = max(6, imageWidth / 220) * (handle.isEdge ? 0.7 : 1)
            let center = mark.point(of: handle)
            let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(.white)
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot)
        }
        context.restoreGState()
    }

    private func draw(_ mark: Annotation, context: CGContext) {
        let width = CGFloat(mark.lineWidth)
        context.setStrokeColor(mark.color.cgColor)
        context.setFillColor(mark.color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let rect = CaptureGeometry.rect(from: mark.start, to: mark.end)

        switch mark.kind {
        case .arrow:
            drawArrow(from: mark.start, to: mark.end, width: width, context: context)
        case .line:
            context.move(to: mark.start)
            context.addLine(to: mark.end)
            context.strokePath()
        case .rectangle:
            context.addPath(CGPath(roundedRect: rect, cornerWidth: width, cornerHeight: width, transform: nil))
            context.strokePath()
        case .filledRectangle:
            context.addPath(CGPath(roundedRect: rect, cornerWidth: width, cornerHeight: width, transform: nil))
            context.fillPath()
        case .ellipse:
            context.strokeEllipse(in: rect)
        case .pencil:
            stroke(mark.points, context: context)
        case .highlighter:
            context.saveGState()
            context.setBlendMode(.multiply)
            context.setStrokeColor(mark.color.cgColor.copy(alpha: 0.45) ?? mark.color.cgColor)
            context.setLineWidth(width * 4)
            context.setLineCap(.square)
            stroke(mark.points, context: context)
            context.restoreGState()
        case .text:
            (mark.text ?? "").draw(at: mark.start, withAttributes: textAttributes(for: mark))
        case .counter:
            let radius = CGFloat(mark.fontSize) * 0.8
            let circle = CGRect(x: mark.start.x - radius, y: mark.start.y - radius, width: radius * 2, height: radius * 2)
            context.fillEllipse(in: circle)
            let label = "\(mark.number ?? 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: CGFloat(mark.fontSize), weight: .heavy),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
        case .image:
            guard let data = mark.imagePNG,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 6), blur: 20, color: CGColor(gray: 0, alpha: 0.4))
            Self.draw(image, in: rect, context: context)
            context.restoreGState()
        case .blur, .pixelate, .spotlight:
            break
        }
    }

    private func stroke(_ points: [CGPoint], context: CGContext) {
        guard let first = points.first else { return }
        context.move(to: first)
        for point in points.dropFirst() { context.addLine(to: point) }
        if points.count == 1 { context.addLine(to: first) }
        context.strokePath()
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, context: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let headLength = min(length * 0.6, max(width * 4.5, 18))
        let headWidth = headLength * 0.9
        let base = CGPoint(x: end.x - cos(angle) * headLength * 0.8, y: end.y - sin(angle) * headLength * 0.8)
        context.move(to: start)
        context.addLine(to: base)
        context.strokePath()
        let back = CGPoint(x: end.x - cos(angle) * headLength, y: end.y - sin(angle) * headLength)
        let normal = CGVector(dx: -sin(angle) * headWidth / 2, dy: cos(angle) * headWidth / 2)
        context.move(to: end)
        context.addLine(to: CGPoint(x: back.x + normal.dx, y: back.y + normal.dy))
        context.addLine(to: CGPoint(x: back.x - normal.dx, y: back.y - normal.dy))
        context.closePath()
        context.fillPath()
    }

    private func prepareEffects(for base: CGImage) {
        guard effectsBase !== base else { return }
        let effects = Self.effects(for: base)
        effectsBase = base
        blurred = effects.blurred
        pixelated = effects.pixelated
    }

    func prewarmEffects(for base: CGImage) {
        guard effectsBase !== base else { return }
        let box = SendableImage(image: base)
        Task { [weak self] in
            let made = await Task.detached(priority: .utility) { () -> SendableEffects in
                let effects = AnnotationRenderer.effects(for: box.image)
                return SendableEffects(blurred: effects.blurred, pixelated: effects.pixelated)
            }.value
            guard let self, effectsBase !== box.image else { return }
            effectsBase = box.image
            blurred = made.blurred
            pixelated = made.pixelated
        }
    }

    private struct SendableImage: @unchecked Sendable {
        let image: CGImage
    }

    private struct SendableEffects: @unchecked Sendable {
        let blurred: CGImage?
        let pixelated: CGImage?
    }

    private nonisolated static let sharedContext = CIContext()

    nonisolated static func effects(for base: CGImage) -> (blurred: CGImage?, pixelated: CGImage?) {
        let input = CIImage(cgImage: base)
        let extent = input.extent
        let size = Double(max(base.width, base.height))

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = Float(max(10, size / 120))
        let blurred = blur.outputImage.flatMap { sharedContext.createCGImage($0.cropped(to: extent), from: extent) }

        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = input.clampedToExtent()
        pixellate.scale = Float(max(10, size / 90))
        let pixelated = pixellate.outputImage.flatMap { sharedContext.createCGImage($0.cropped(to: extent), from: extent) }
        return (blurred, pixelated)
    }

    nonisolated static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

enum ImageOps {
    static func apply(_ edit: ImageEdit, to image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        if case let .crop(rect) = edit {
            return image.cropping(to: rect.integral.intersection(CGRect(origin: .zero, size: size)))
        }
        let (transform, newSize) = edit.transform(for: size)
        guard let context = CGContext(
            data: nil, width: Int(newSize.width), height: Int(newSize.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: newSize.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform)
        AnnotationRenderer.draw(image, in: CGRect(origin: .zero, size: size), context: context)
        return context.makeImage()
    }

    static func png(_ image: CGImage, pointSize: CGSize) -> Data? {
        PNGEncoder.encode(image, pointSize: pointSize)
    }
}
