import Accelerate
import Foundation

struct SpectrumBands: Sendable {
    static let count = 32
    static let fftSize = 1024
    static let lowestHertz: Float = 90
    static let highestHertz: Float = 7000
    static let quietDecibels: Float = -75
    static let loudDecibels: Float = -25

    static func edges(sampleRate: Double, count: Int = Self.count) -> [Range<Int>] {
        let binWidth = Float(sampleRate) / Float(fftSize)
        let lastBin = fftSize / 2 - 1
        let ratio = highestHertz / lowestHertz
        return (0 ..< count).map { band in
            let low = lowestHertz * pow(ratio, Float(band) / Float(count))
            let high = lowestHertz * pow(ratio, Float(band + 1) / Float(count))
            let start = min(lastBin, max(1, Int((low / binWidth).rounded(.down))))
            let end = min(lastBin + 1, max(start + 1, Int((high / binWidth).rounded(.up))))
            return start ..< end
        }
    }

    static func level(decibels: Float) -> Float {
        max(0, min(1, (decibels - quietDecibels) / (loudDecibels - quietDecibels)))
    }
}

final class SpectrumAnalyzer: @unchecked Sendable {
    private let transform: vDSP.DiscreteFourierTransform<Float>?
    private let window: [Float]
    private var samples: [Float]
    private var edges: [Range<Int>] = []
    private var edgeRate: Double = 0

    init() {
        transform = try? vDSP.DiscreteFourierTransform(
            count: SpectrumBands.fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self
        )
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: SpectrumBands.fftSize, isHalfWindow: false)
        samples = Array(repeating: 0, count: SpectrumBands.fftSize)
    }

    func reset() {
        samples = Array(repeating: 0, count: SpectrumBands.fftSize)
    }

    func bands(adding newSamples: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Float] {
        append(newSamples)
        return bands(sampleRate: sampleRate)
    }

    func bands(adding newSamples: [Float], sampleRate: Double) -> [Float] {
        newSamples.withUnsafeBufferPointer { bands(adding: $0, sampleRate: sampleRate) }
    }

    private func append(_ newSamples: UnsafeBufferPointer<Float>) {
        let size = SpectrumBands.fftSize
        if newSamples.count >= size {
            samples = Array(newSamples.suffix(size))
        } else {
            samples = Array(samples.dropFirst(newSamples.count)) + Array(newSamples)
        }
    }

    private func bands(sampleRate: Double) -> [Float] {
        guard let transform, sampleRate > 0 else { return Array(repeating: 0, count: SpectrumBands.count) }
        if sampleRate != edgeRate {
            edges = SpectrumBands.edges(sampleRate: sampleRate)
            edgeRate = sampleRate
        }
        let windowed = vDSP.multiply(samples, window)
        let zeros = [Float](repeating: 0, count: SpectrumBands.fftSize)
        let (real, imaginary) = transform.transform(real: windowed, imaginary: zeros)
        let scale = 2 / (Float(SpectrumBands.fftSize) * 0.5)
        return edges.map { range in
            var peak: Float = 0
            for bin in range {
                let magnitude = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot() * scale
                peak = max(peak, magnitude)
            }
            return SpectrumBands.level(decibels: 20 * log10(max(peak, 1e-7)))
        }
    }
}
