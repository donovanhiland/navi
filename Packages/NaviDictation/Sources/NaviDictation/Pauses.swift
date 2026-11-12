import Foundation

enum Pauses {
    static let frame = 320

    static func speechLevel(_ samples: ArraySlice<Float>) -> Float {
        var levels: [Float] = []
        var start = samples.startIndex
        while start + frame <= samples.endIndex {
            levels.append(rms(samples[start ..< start + frame]))
            start += frame
        }
        guard !levels.isEmpty else { return 0 }
        levels.sort()
        return levels[min(levels.count - 1, levels.count * 9 / 10)]
    }

    static func quietest(in samples: ArraySlice<Float>, range: Range<Int>, window: Int = 1600) -> (middle: Int, level: Float)? {
        let lower = max(range.lowerBound, samples.startIndex)
        let upper = min(range.upperBound, samples.endIndex)
        guard upper - lower >= window else { return nil }
        var best: (middle: Int, level: Float)?
        var start = lower
        while start + window <= upper {
            var level: Float = 0
            var frameStart = start
            while frameStart + frame <= start + window {
                level = max(level, rms(samples[frameStart ..< frameStart + frame]))
                frameStart += frame
            }
            if best == nil || level < best!.level { best = (start + window / 2, level) }
            start += frame
        }
        return best
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
