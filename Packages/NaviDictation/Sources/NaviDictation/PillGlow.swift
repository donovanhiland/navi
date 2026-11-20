import CoreGraphics
import Foundation

public enum PillGlowStyle: String, CaseIterable, Sendable {
    case dotMatrix
    case dotMatrixAccent
    case embers
    case embersAccent

    public static let standard = PillGlowStyle.dotMatrix

    public var title: String {
        switch self {
        case .dotMatrix: "Dot Matrix"
        case .dotMatrixAccent: "Dot Matrix, Accent"
        case .embers: "Embers"
        case .embersAccent: "Embers, Accent"
        }
    }

    var usesAccent: Bool { self == .dotMatrixAccent || self == .embersAccent }
    var hasEmbers: Bool { self == .embers || self == .embersAccent }
}

struct GlowDot: Equatable {
    var center: CGPoint
    var size: CGFloat
    var hue: Double
    var saturation: Double
    var opacity: Double
}

struct BandSmoother {
    static let rise: Float = 0.7
    static let fall: Float = 0.15
    static let gain: Float = 1.6

    private(set) var values: [Float] = Array(repeating: 0, count: SpectrumBands.count)

    mutating func push(_ bands: [Float]) {
        values = values.indices.map { index in
            let target = min(1, (index < bands.count ? bands[index] : 0) * Self.gain)
            let current = values[index]
            let rate = target > current ? Self.rise : Self.fall
            return current + (target - current) * rate
        }
    }

    mutating func reset() {
        values = Array(repeating: 0, count: SpectrumBands.count)
    }
}

enum GlowLayout {
    static let pitch: CGFloat = 4
    static let quietFloor = 0.08
    static let thinkingRows = 3
    static let emberRate = 24.0
    static let emberLife = 0.85
    static let emberSlots = 24

    struct Palette {
        let style: PillGlowStyle
        let accentHue: Double

        func hue(_ x: Double, _ time: Double) -> Double {
            style.usesAccent ? accentHue : (x * 0.83 + time * 0.11).truncatingRemainder(dividingBy: 1)
        }

        func saturation(_ fall: Double) -> Double {
            style.usesAccent ? 0.76 - 0.44 * fall : 1 - 0.2 * fall
        }
    }

    static func band(_ bands: [Float], at x: Double) -> Double {
        guard bands.count > 1 else { return Double(bands.first ?? 0) }
        let position = min(1, abs(x - 0.5) * 2) * Double(bands.count - 1)
        let index = Int(position)
        let next = min(bands.count - 1, index + 1)
        let mix = position - Double(index)
        return Double(bands[index]) * (1 - mix) + Double(bands[next]) * mix
    }

    static func listening(bands: [Float], size: CGSize, time: Double, palette: Palette) -> [GlowDot] {
        let columns = Int(size.width / pitch)
        let rows = Int(size.height / pitch)
        guard columns > 0, rows > 0 else { return [] }
        let top = size.height - CGFloat(rows) * pitch
        var dots: [GlowDot] = []
        for column in 0 ..< columns {
            let x = (Double(column) + 0.5) / Double(columns)
            let amplitude = band(bands, at: x) * pow(sin(Double.pi * x), 0.6)
            let height = quietFloor + amplitude * 0.95
            for row in 0 ..< rows {
                let y = Double(row + 1) / Double(rows)
                let fall = max(0, 1 - (1 - y) / height)
                guard fall > 0 else { continue }
                let jitter = 0.75 + 0.25 * sin(Double(column) * 12.9898 + Double(row) * 78.233 + time * 6)
                let opacity = min(1, pow(fall, 1.6) * jitter * (0.35 + amplitude))
                guard opacity >= 0.04 else { continue }
                dots.append(GlowDot(
                    center: CGPoint(x: (CGFloat(column) + 0.5) * pitch, y: top + (CGFloat(row) + 0.5) * pitch),
                    size: 1.6 + 0.8 * fall,
                    hue: palette.hue(x, time),
                    saturation: palette.saturation(fall),
                    opacity: opacity
                ))
            }
        }
        return dots
    }

    static func embers(bands: [Float], size: CGSize, time: Double, palette: Palette) -> [GlowDot] {
        let newest = Int((time * emberRate).rounded(.down))
        return (max(0, newest - emberSlots + 1) ... max(0, newest)).compactMap { slot in
            let age = time - Double(slot) / emberRate
            let life = 1 - age / emberLife
            let x = noise(slot, 1)
            guard age >= 0, life > 0, noise(slot, 2) < band(bands, at: x) * 0.9 else { return nil }
            let speed = 18 + 48 * noise(slot, 3)
            let y = Double(size.height) - 4 - speed * age
            guard y > 0 else { return nil }
            let drift = sin(time * 3 + Double(slot)) * 2
            return GlowDot(
                center: CGPoint(x: x * Double(size.width) + drift, y: y),
                size: 1.6,
                hue: palette.hue(noise(slot, 4), time),
                saturation: palette.saturation(0.5),
                opacity: life
            )
        }
    }

    static func thinking(size: CGSize, time: Double, palette: Palette) -> [GlowDot] {
        let columns = Int(size.width / pitch)
        let rows = Int(size.height / pitch)
        guard columns > 0, rows >= thinkingRows else { return [] }
        let top = size.height - CGFloat(rows) * pitch
        let sweep = (time * 0.6).truncatingRemainder(dividingBy: 1.4) - 0.2
        var dots: [GlowDot] = []
        for column in 0 ..< columns {
            let x = (Double(column) + 0.5) / Double(columns)
            let near = exp(-pow((x - sweep) / 0.12, 2))
            for step in 0 ..< thinkingRows {
                let row = rows - thinkingRows + step
                let fall = Double(step + 1) / Double(thinkingRows)
                let shimmer = 0.7 + 0.3 * sin(Double(column) * 3.1 + Double(row) * 7 + time * 9)
                dots.append(GlowDot(
                    center: CGPoint(x: (CGFloat(column) + 0.5) * pitch, y: top + (CGFloat(row) + 0.5) * pitch),
                    size: 1.8,
                    hue: palette.hue(x, time),
                    saturation: palette.saturation(fall),
                    opacity: (0.08 + near * 0.9) * fall * shimmer
                ))
            }
        }
        return dots
    }

    static func noise(_ slot: Int, _ salt: Int) -> Double {
        let value = sin(Double(slot) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }
}
