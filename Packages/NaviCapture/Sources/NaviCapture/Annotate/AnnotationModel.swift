import CoreGraphics
import Foundation

public enum AnnotationTool: String, CaseIterable, Codable, Sendable {
    case select, arrow, rectangle, filledRectangle, ellipse, line, pencil, highlighter
    case text, counter, blur, pixelate, spotlight, crop

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .filledRectangle: "Filled rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .counter: "Counter"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .spotlight: "Spotlight"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .filledRectangle: "rectangle.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .blur: "drop"
        case .pixelate: "squareshape.split.3x3"
        case .spotlight: "camera.metering.spot"
        case .crop: "crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .filledRectangle: "f"
        case .ellipse: "o"
        case .line: "l"
        case .pencil: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .blur: "b"
        case .pixelate: "x"
        case .spotlight: "s"
        case .crop: "c"
        }
    }

    static func forShortcut(_ key: String) -> AnnotationTool? {
        guard key.count == 1, let character = key.lowercased().first else { return nil }
        return allCases.first { $0.shortcut == character }
    }

    var help: String {
        switch self {
        case .select: "Select: click a mark to move it, drag its handles to resize it"
        case .counter: "Counter: click to add numbered steps"
        case .blur: "Blur: hide what is in the box"
        case .pixelate: "Pixelate: hide what is in the box with big pixels"
        case .spotlight: "Spotlight: darken everything outside the box"
        case .highlighter: "Highlighter: see-through marker"
        default: title
        }
    }

    var dragsShape: Bool {
        switch self {
        case .select, .text, .counter, .crop: false
        default: true
        }
    }
}

public struct RGBA: Codable, Hashable, Sendable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    public static let red = RGBA(red: 0.96, green: 0.23, blue: 0.23)
}

public struct Annotation: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case arrow, rectangle, filledRectangle, ellipse, line, pencil, highlighter
        case text, counter, blur, pixelate, spotlight, image
    }

    public var id = UUID()
    public var kind: Kind
    public var start: CGPoint
    public var end: CGPoint
    public var points: [CGPoint] = []
    public var color: RGBA
    public var lineWidth: Double
    public var text: String?
    public var number: Int?
    public var fontSize: Double = 32
    public var imagePNG: Data?

    public var bounds: CGRect {
        switch kind {
        case .pencil, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -lineWidth, dy: -lineWidth)
        case .counter:
            let radius = fontSize * 0.8
            return CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
        case .text:
            let lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            let longest = lines.map(\.count).max() ?? 0
            return CGRect(
                x: start.x, y: start.y,
                width: max(fontSize, Double(longest) * fontSize * 0.6), height: Double(max(lines.count, 1)) * fontSize * 1.25
            )
        default:
            return CaptureGeometry.rect(from: start, to: end).insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
    }

    public enum Handle: CaseIterable, Sendable {
        case start, end
        case startXEndY, endXStartY
        case top, bottom, left, right

        public var isEdge: Bool {
            switch self {
            case .top, .bottom, .left, .right: true
            default: false
            }
        }
    }

    public var isBox: Bool {
        switch kind {
        case .rectangle, .filledRectangle, .ellipse, .blur, .pixelate, .spotlight, .image: true
        default: false
        }
    }

    public var handles: [Handle] {
        if isBox { return Handle.allCases }
        if kind == .arrow || kind == .line { return [.start, .end] }
        return []
    }

    public var box: CGRect { CaptureGeometry.rect(from: start, to: end) }

    public func point(of handle: Handle) -> CGPoint {
        switch handle {
        case .start: start
        case .end: end
        case .startXEndY: CGPoint(x: start.x, y: end.y)
        case .endXStartY: CGPoint(x: end.x, y: start.y)
        case .top: CGPoint(x: box.midX, y: box.minY)
        case .bottom: CGPoint(x: box.midX, y: box.maxY)
        case .left: CGPoint(x: box.minX, y: box.midY)
        case .right: CGPoint(x: box.maxX, y: box.midY)
        }
    }

    public func handle(at point: CGPoint, tolerance: Double) -> Handle? {
        let corner = handles.filter { !$0.isEdge }.first {
            hypot(self.point(of: $0).x - point.x, self.point(of: $0).y - point.y) <= tolerance
        }
        if let corner { return corner }
        guard isBox else { return nil }
        let r = box
        let alongX = point.x >= r.minX - tolerance && point.x <= r.maxX + tolerance
        let alongY = point.y >= r.minY - tolerance && point.y <= r.maxY + tolerance
        if alongY, abs(point.x - r.minX) <= tolerance { return .left }
        if alongY, abs(point.x - r.maxX) <= tolerance { return .right }
        if alongX, abs(point.y - r.minY) <= tolerance { return .top }
        if alongX, abs(point.y - r.maxY) <= tolerance { return .bottom }
        return nil
    }

    public func resized(_ handle: Handle, to point: CGPoint) -> Annotation {
        var copy = self
        if handle.isEdge {
            copy.start = CGPoint(x: box.minX, y: box.minY)
            copy.end = CGPoint(x: box.maxX, y: box.maxY)
        }
        switch handle {
        case .start: copy.start = point
        case .end: copy.end = point
        case .startXEndY:
            copy.start.x = point.x
            copy.end.y = point.y
        case .endXStartY:
            copy.end.x = point.x
            copy.start.y = point.y
        case .top: copy.start.y = point.y
        case .bottom: copy.end.y = point.y
        case .left: copy.start.x = point.x
        case .right: copy.end.x = point.x
        }
        return copy
    }

    public var usesFontSize: Bool { kind == .text || kind == .counter }

    public func moved(by offset: CGVector) -> Annotation {
        applying(CGAffineTransform(translationX: offset.dx, y: offset.dy), scale: 1)
    }

    public func applying(_ transform: CGAffineTransform, scale: Double) -> Annotation {
        var copy = self
        copy.start = start.applying(transform)
        copy.end = end.applying(transform)
        copy.points = points.map { $0.applying(transform) }
        copy.lineWidth = lineWidth * scale
        copy.fontSize = fontSize * scale
        return copy
    }
}

public struct AnnotationDocument: Codable, Equatable, Sendable {
    public var annotations: [Annotation] = []
    public var nextCounter = 1

    public init() {}

    public func hit(_ point: CGPoint, tolerance: Double) -> Annotation? {
        annotations.last { $0.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
    }

    public mutating func apply(_ transform: CGAffineTransform, scale: Double = 1) {
        annotations = annotations.map { $0.applying(transform, scale: scale) }
    }
}

public enum ImageEdit: Equatable, Sendable {
    case rotateClockwise, rotateCounterclockwise, flipHorizontal, flipVertical
    case crop(CGRect)
    case resize(Double)

    public func transform(for size: CGSize) -> (CGAffineTransform, CGSize) {
        switch self {
        case .rotateClockwise:
            return (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0), CGSize(width: size.height, height: size.width))
        case .rotateCounterclockwise:
            return (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width), CGSize(width: size.height, height: size.width))
        case .flipHorizontal:
            return (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0), size)
        case .flipVertical:
            return (CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height), size)
        case let .crop(rect):
            return (CGAffineTransform(translationX: -rect.minX, y: -rect.minY), rect.size)
        case let .resize(factor):
            return (
                CGAffineTransform(scaleX: factor, y: factor),
                CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
            )
        }
    }

    var markScale: Double {
        if case let .resize(factor) = self { return factor }
        return 1
    }
}

public struct UndoStack<Value> {
    private var past: [Value] = []
    private var future: [Value] = []

    public init() {}

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public mutating func record(_ value: Value) {
        past.append(value)
        future.removeAll()
    }

    public mutating func undo(current: Value) -> Value? {
        guard let value = past.popLast() else { return nil }
        future.append(current)
        return value
    }

    public mutating func redo(current: Value) -> Value? {
        guard let value = future.popLast() else { return nil }
        past.append(current)
        return value
    }
}
