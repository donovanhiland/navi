import CoreGraphics
import Foundation

public struct BackgroundStyle: Codable, Equatable, Sendable {
    public enum Fill: Codable, Equatable, Sendable {
        case none
        case gradient(Int)
        case solid(RGBA)
        case image(String)
    }

    public enum Aspect: String, Codable, CaseIterable, Sendable {
        case auto, wide, standard, square, tall

        var title: String {
            switch self {
            case .auto: "Auto"
            case .wide: "16:9"
            case .standard: "4:3"
            case .square: "1:1"
            case .tall: "9:16"
            }
        }

        var ratio: CGFloat? {
            switch self {
            case .auto: nil
            case .wide: 16.0 / 9
            case .standard: 4.0 / 3
            case .square: 1
            case .tall: 9.0 / 16
            }
        }
    }

    public var fill: Fill = .gradient(0)
    public var padding: Double = 64
    public var cornerRadius: Double = 10
    public var shadow = true
    public var aspect: Aspect = .auto
    public var autoBalance = false

    public init() {}

    static let gradients: [(RGBA, RGBA)] = [
        (RGBA(red: 0.40, green: 0.49, blue: 0.98), RGBA(red: 0.77, green: 0.38, blue: 0.93)),
        (RGBA(red: 0.98, green: 0.55, blue: 0.36), RGBA(red: 0.96, green: 0.29, blue: 0.51)),
        (RGBA(red: 0.20, green: 0.83, blue: 0.68), RGBA(red: 0.13, green: 0.52, blue: 0.86)),
        (RGBA(red: 0.99, green: 0.84, blue: 0.40), RGBA(red: 0.98, green: 0.51, blue: 0.29)),
        (RGBA(red: 0.13, green: 0.14, blue: 0.20), RGBA(red: 0.29, green: 0.31, blue: 0.42)),
        (RGBA(red: 0.92, green: 0.93, blue: 0.96), RGBA(red: 0.78, green: 0.81, blue: 0.88)),
        (RGBA(red: 0.55, green: 0.85, blue: 0.98), RGBA(red: 0.67, green: 0.55, blue: 0.98)),
        (RGBA(red: 0.36, green: 0.80, blue: 0.40), RGBA(red: 0.11, green: 0.55, blue: 0.48)),
    ]
}

enum BackgroundLayout {
    static func canvasSize(content: CGSize, padding: CGFloat, ratio: CGFloat?) -> CGSize {
        var size = CGSize(width: content.width + padding * 2, height: content.height + padding * 2)
        guard let ratio, ratio > 0 else { return size }
        if size.width / size.height < ratio {
            size.width = (size.height * ratio).rounded()
        } else {
            size.height = (size.width / ratio).rounded()
        }
        return size
    }
}

enum AutoBalance {
    static func balancedRect(width: Int, height: Int, tolerance: Int = 8, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 2, height > 2 else { return full }
        let edge = pixel(0, 0)
        func plain(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return abs(Int(p.0) - Int(edge.0)) <= tolerance && abs(Int(p.1) - Int(edge.1)) <= tolerance
                && abs(Int(p.2) - Int(edge.2)) <= tolerance && abs(Int(p.3) - Int(edge.3)) <= tolerance
        }
        func rowPlain(_ y: Int) -> Bool { (0 ..< width).allSatisfy { plain($0, y) } }
        func columnPlain(_ x: Int) -> Bool { (0 ..< height).allSatisfy { plain(x, $0) } }

        var top = 0
        while top < height, rowPlain(top) { top += 1 }
        guard top < height else { return full }
        var bottom = 0
        while bottom < height - top, rowPlain(height - 1 - bottom) { bottom += 1 }
        var left = 0
        while left < width, columnPlain(left) { left += 1 }
        var right = 0
        while right < width - left, columnPlain(width - 1 - right) { right += 1 }

        let margin = min(top, bottom, left, right)
        return CGRect(
            x: left - margin, y: top - margin,
            width: width - left - right + margin * 2, height: height - top - bottom + margin * 2
        )
    }
}

@MainActor
enum BackgroundPresets {
    private static let key = "capture.backgroundPresets"
    private static let lastKey = "capture.backgroundLast"

    static var all: [String: BackgroundStyle] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: BackgroundStyle].self, from: data)) ?? [:]
    }

    static func save(_ style: BackgroundStyle, as name: String) {
        var presets = all
        presets[name] = style
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: key)
    }

    static func delete(_ name: String) {
        var presets = all
        presets[name] = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: key)
    }

    static var last: BackgroundStyle {
        get {
            UserDefaults.standard.data(forKey: lastKey).flatMap { try? JSONDecoder().decode(BackgroundStyle.self, from: $0) }
                ?? BackgroundStyle()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lastKey) }
    }
}
