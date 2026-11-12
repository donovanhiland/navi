import Foundation

public struct BenchCase: Codable, Sendable, Equatable {
    public var id: String
    public var category: String
    public var input: String
    public var expected: [String]
    public var spoken: String?

    public init(id: String, category: String, input: String, expected: [String], spoken: String? = nil) {
        self.id = id
        self.category = category
        self.input = input
        self.expected = expected
        self.spoken = spoken
    }
}

public struct CaseScore: Codable, Sendable, Equatable {
    public var id: String
    public var category: String
    public var output: String
    public var passed: Bool
    public var exact: Bool
    public var wordAccuracy: Double
    public var fillersLeft: Int
    public var inventedWords: [String]
    public var milliseconds: Double

    public init(
        id: String, category: String, output: String, passed: Bool, exact: Bool, wordAccuracy: Double,
        fillersLeft: Int, inventedWords: [String], milliseconds: Double
    ) {
        self.id = id
        self.category = category
        self.output = output
        self.passed = passed
        self.exact = exact
        self.wordAccuracy = wordAccuracy
        self.fillersLeft = fillersLeft
        self.inventedWords = inventedWords
        self.milliseconds = milliseconds
    }
}

public enum Scoring {
    public static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm"]

    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || "'.-_@/".contains($0)) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'.-_/")) }
            .filter { !$0.isEmpty }
    }

    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        for i in 1 ... a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1 ... b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    public static func wordErrorRate(_ hypothesis: String, reference: String) -> Double {
        let ref = words(reference)
        let hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(hyp, ref)) / Double(ref.count)
    }

    public static func score(_ benchCase: BenchCase, output: String, milliseconds: Double = 0) -> CaseScore {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let outWords = words(trimmed)
        let best = benchCase.expected.min { wordErrorRate(trimmed, reference: $0) < wordErrorRate(trimmed, reference: $1) }
            ?? ""
        let wer = wordErrorRate(trimmed, reference: best)
        let fillersLeft = outWords.filter(fillers.contains).count
        let known = Set(words(benchCase.input)).union(benchCase.expected.flatMap(words))
        let invented = outWords.filter { !known.contains($0) }
        return CaseScore(
            id: benchCase.id,
            category: benchCase.category,
            output: trimmed,
            passed: benchCase.expected.contains { words($0) == outWords } && fillersLeft == 0,
            exact: benchCase.expected.contains(trimmed),
            wordAccuracy: max(0, 1 - wer),
            fillersLeft: fillersLeft,
            inventedWords: invented,
            milliseconds: milliseconds
        )
    }
}

public struct Summary: Codable, Sendable, Equatable {
    public var name: String
    public var cases: Int
    public var passRate: Double
    public var exactRate: Double
    public var wordAccuracy: Double
    public var fillersLeft: Int
    public var inventedWords: Int
    public var p50Milliseconds: Double
    public var p95Milliseconds: Double

    public init(name: String, scores: [CaseScore]) {
        self.name = name
        cases = scores.count
        let count = Double(max(scores.count, 1))
        passRate = Double(scores.filter(\.passed).count) / count
        exactRate = Double(scores.filter(\.exact).count) / count
        wordAccuracy = scores.map(\.wordAccuracy).reduce(0, +) / count
        fillersLeft = scores.map(\.fillersLeft).reduce(0, +)
        inventedWords = scores.map(\.inventedWords.count).reduce(0, +)
        let times = scores.map(\.milliseconds).sorted()
        p50Milliseconds = Self.percentile(times, 0.5)
        p95Milliseconds = Self.percentile(times, 0.95)
    }

    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

public struct BenchRun: Codable, Sendable {
    public var engine: String
    public var date: Date
    public var overall: Summary
    public var categories: [Summary]
    public var scores: [CaseScore]

    public init(engine: String, date: Date = .now, scores: [CaseScore]) {
        self.engine = engine
        self.date = date
        self.scores = scores
        overall = Summary(name: "overall", scores: scores)
        let names = Array(Set(scores.map(\.category))).sorted()
        categories = names.map { name in Summary(name: name, scores: scores.filter { $0.category == name }) }
    }
}

public enum Report {
    public static func table(_ runs: [BenchRun]) -> String {
        guard let first = runs.first else { return "" }
        let rows = first.categories.map(\.name) + ["overall"]
        var lines: [String] = []
        let header = "category".padding(toLength: 14, withPad: " ", startingAt: 0)
            + runs.map { " | " + $0.engine.padding(toLength: 24, withPad: " ", startingAt: 0) }.joined()
        lines.append(header)
        lines.append(String(repeating: "-", count: header.count))
        lines.append(
            "".padding(toLength: 14, withPad: " ", startingAt: 0)
                + runs.map { _ in " | " + "pass  words  made-up fill".padding(toLength: 24, withPad: " ", startingAt: 0) }.joined()
        )
        for row in rows {
            var line = row.padding(toLength: 14, withPad: " ", startingAt: 0)
            for run in runs {
                let summary = row == "overall" ? run.overall : run.categories.first { $0.name == row }
                guard let summary else {
                    line += " | " + "".padding(toLength: 24, withPad: " ", startingAt: 0)
                    continue
                }
                let cell = String(
                    format: "%3.0f%%  %4.0f%%  %4d   %3d",
                    summary.passRate * 100, summary.wordAccuracy * 100, summary.inventedWords, summary.fillersLeft
                )
                line += " | " + cell.padding(toLength: 24, withPad: " ", startingAt: 0)
            }
            lines.append(line)
        }
        lines.append("")
        for run in runs {
            lines.append(String(
                format: "%@: cleanup time p50 %.0f ms, p95 %.0f ms, exact %.0f%%",
                run.engine, run.overall.p50Milliseconds, run.overall.p95Milliseconds, run.overall.exactRate * 100
            ))
        }
        return lines.joined(separator: "\n")
    }
}
