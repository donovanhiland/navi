import CoreGraphics
import Foundation
import Testing

@testable import NaviDictation

struct SpectrumTests {
    static let sampleRate = 48_000.0

    static func sine(hertz: Double, amplitude: Float, count: Int = SpectrumBands.fftSize) -> [Float] {
        (0 ..< count).map { amplitude * Float(sin(2 * Double.pi * hertz * Double($0) / sampleRate)) }
    }

    @Test func silenceGivesNoBands() {
        let bands = SpectrumAnalyzer().bands(adding: [Float](repeating: 0, count: 1024), sampleRate: Self.sampleRate)
        #expect(bands.count == SpectrumBands.count)
        #expect(bands.allSatisfy { $0 == 0 })
    }

    @Test func toneLightsItsOwnBand() throws {
        let hertz = 1000.0
        let bands = SpectrumAnalyzer().bands(adding: Self.sine(hertz: hertz, amplitude: 0.3), sampleRate: Self.sampleRate)
        let edges = SpectrumBands.edges(sampleRate: Self.sampleRate)
        let bin = Int(hertz / (Self.sampleRate / Double(SpectrumBands.fftSize)))
        let expected = try #require(edges.firstIndex { $0.contains(bin) })
        let loudest = try #require(bands.indices.max { bands[$0] < bands[$1] })
        #expect(abs(loudest - expected) <= 1)
        #expect(bands[loudest] > 0.8)
        #expect(bands[0] < 0.3)
        #expect(bands[SpectrumBands.count - 1] < 0.3)
    }

    @Test func shortChunksAddUp() {
        let analyzer = SpectrumAnalyzer()
        let tone = Self.sine(hertz: 500, amplitude: 0.3)
        var bands: [Float] = []
        for start in stride(from: 0, to: tone.count, by: 256) {
            bands = analyzer.bands(adding: Array(tone[start ..< start + 256]), sampleRate: Self.sampleRate)
        }
        #expect((bands.max() ?? 0) > 0.8)
    }

    @Test func edgesCoverEveryBandInOrder() {
        for rate in [16_000.0, 44_100, 48_000] {
            let edges = SpectrumBands.edges(sampleRate: rate)
            #expect(edges.count == SpectrumBands.count)
            #expect(edges.allSatisfy { !$0.isEmpty && $0.lowerBound >= 1 && $0.upperBound <= SpectrumBands.fftSize / 2 })
            #expect(zip(edges, edges.dropFirst()).allSatisfy { $0.lowerBound <= $1.lowerBound })
        }
    }
}

struct BandSmootherTests {
    @Test func risesFastAndFallsSlowly() {
        var smoother = BandSmoother()
        let loud = [Float](repeating: 0.5, count: SpectrumBands.count)
        smoother.push(loud)
        let afterRise = smoother.values[0]
        #expect(afterRise > 0.5)
        smoother.push([Float](repeating: 0, count: SpectrumBands.count))
        let afterOneFall = smoother.values[0]
        #expect(afterOneFall < afterRise)
        #expect(afterOneFall > afterRise * 0.8)
    }

    @Test func neverGoesPastOne() {
        var smoother = BandSmoother()
        for _ in 0 ..< 20 { smoother.push([Float](repeating: 1, count: SpectrumBands.count)) }
        #expect(smoother.values.allSatisfy { $0 <= 1 })
    }

    @Test func shortInputCountsAsQuiet() {
        var smoother = BandSmoother()
        smoother.push([1])
        #expect(smoother.values[0] > 0)
        #expect(smoother.values[1] == 0)
    }
}

struct GlowLayoutTests {
    static let size = CGSize(width: 240, height: 30)
    static let rainbow = GlowLayout.Palette(style: .dotMatrix, accentHue: 0.6)
    static let accent = GlowLayout.Palette(style: .dotMatrixAccent, accentHue: 0.6)

    static func topOfDots(_ dots: [GlowDot]) -> CGFloat {
        dots.map(\.center.y).min() ?? size.height
    }

    @Test func quietShowsOnlyALowLine() {
        let quiet = [Float](repeating: 0, count: SpectrumBands.count)
        let dots = GlowLayout.listening(bands: quiet, size: Self.size, time: 1, palette: Self.rainbow)
        #expect(!dots.isEmpty)
        #expect(Self.topOfDots(dots) > Self.size.height - GlowLayout.pitch * 2)
    }

    @Test func loudReachesTheTopAndStaysInside() {
        let loud = [Float](repeating: 1, count: SpectrumBands.count)
        let dots = GlowLayout.listening(bands: loud, size: Self.size, time: 1, palette: Self.rainbow)
        #expect(Self.topOfDots(dots) < GlowLayout.pitch * 2)
        #expect(dots.allSatisfy { $0.center.y >= 0 && $0.center.y <= Self.size.height && $0.center.x >= 0 && $0.center.x <= Self.size.width })
        #expect(dots.allSatisfy { (0 ... 1).contains($0.opacity) })
    }

    @Test func lowPitchSitsInTheMiddle() {
        var bands = [Float](repeating: 0, count: SpectrumBands.count)
        bands[0] = 1
        #expect(GlowLayout.band(bands, at: 0.5) == 1)
        #expect(GlowLayout.band(bands, at: 0) == 0)
        #expect(GlowLayout.band(bands, at: 1) == 0)
    }

    @Test func accentKeepsOneHue() {
        let loud = [Float](repeating: 0.8, count: SpectrumBands.count)
        let accent = GlowLayout.listening(bands: loud, size: Self.size, time: 3, palette: Self.accent)
        #expect(Set(accent.map(\.hue)) == [0.6])
        let rainbow = GlowLayout.listening(bands: loud, size: Self.size, time: 3, palette: Self.rainbow)
        #expect(Set(rainbow.map(\.hue)).count > 10)
    }

    @Test func embersNeedSound() {
        let quiet = [Float](repeating: 0, count: SpectrumBands.count)
        let loud = [Float](repeating: 1, count: SpectrumBands.count)
        let palette = GlowLayout.Palette(style: .embers, accentHue: 0.6)
        #expect(GlowLayout.embers(bands: quiet, size: Self.size, time: 5, palette: palette).isEmpty)
        let sparks = GlowLayout.embers(bands: loud, size: Self.size, time: 5, palette: palette)
        #expect(!sparks.isEmpty)
        #expect(sparks.allSatisfy { $0.center.y > 0 && $0.center.y < Self.size.height && $0.opacity > 0 })
    }

    @Test func thinkingSweepsAcross() {
        func brightestX(at time: Double) -> CGFloat {
            let dots = GlowLayout.thinking(size: Self.size, time: time, palette: Self.rainbow)
            return dots.max { $0.opacity < $1.opacity }?.center.x ?? 0
        }
        #expect(brightestX(at: 0.5) < brightestX(at: 1.2))
        let dots = GlowLayout.thinking(size: Self.size, time: 0.5, palette: Self.rainbow)
        #expect(dots.allSatisfy { $0.center.y > Self.size.height - GlowLayout.pitch * CGFloat(GlowLayout.thinkingRows) })
    }

    @Test func styleNamesRoundTrip() {
        for style in PillGlowStyle.allCases {
            #expect(PillGlowStyle(rawValue: style.rawValue) == style)
        }
        #expect(PillGlowStyle.standard == .dotMatrix)
    }
}
