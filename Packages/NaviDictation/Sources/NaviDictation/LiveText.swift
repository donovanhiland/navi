import Foundation

enum LiveText {
    static let previewWindow: TimeInterval = 10
    static let previewInterval: Duration = .milliseconds(300)
    static let minimumAudio: TimeInterval = 0.5

    static func tailStart(frameCounts: [Int], sampleRate: Double, window: TimeInterval) -> (index: Int, clipped: Bool) {
        guard sampleRate > 0 else { return (0, false) }
        return tailStart(durations: frameCounts.map { Double($0) / sampleRate }, window: window)
    }

    static func tailStart(durations: [TimeInterval], window: TimeInterval) -> (index: Int, clipped: Bool) {
        var total: TimeInterval = 0
        for index in durations.indices.reversed() {
            total += durations[index]
            if total >= window - 1e-9 { return (index, index > 0) }
        }
        return (0, false)
    }

    static let agreementContext = 3

    static func stable(previous: String, current: String) -> String {
        let shown = current.split(whereSeparator: \.isWhitespace).map(String.init)
        let now = shown.map(normalized)
        let before = previous.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
        guard !before.isEmpty else { return "" }
        for end in now.indices.reversed() where !now[end].isEmpty {
            let context = Array(now[max(0, end - agreementContext + 1) ... end])
            let matches = matchEnds(of: context, in: before)
            guard !matches.isEmpty else { continue }
            let start = matches.map { earliestAgreement(now, end: end, before, other: $0) }.min() ?? end
            return shown[start ... end].joined(separator: " ")
        }
        return ""
    }

    private static func matchEnds(of run: [String], in words: [String]) -> [Int] {
        guard run.count <= words.count else { return [] }
        return (0 ... words.count - run.count)
            .filter { Array(words[$0 ..< $0 + run.count]) == run }
            .map { $0 + run.count - 1 }
    }

    private static func earliestAgreement(_ now: [String], end: Int, _ before: [String], other: Int) -> Int {
        var start = end
        var other = other
        while start > 0, other > 0, now[start - 1] == before[other - 1] {
            start -= 1
            other -= 1
        }
        return start
    }

    private static func normalized(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }

    static func trimmed(_ text: String, clipped: Bool) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clipped else { return text }
        guard let space = text.firstIndex(where: \.isWhitespace) else { return "" }
        return text[space...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func combine(finished: [String], volatile: String) -> String {
        (finished + [volatile])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
