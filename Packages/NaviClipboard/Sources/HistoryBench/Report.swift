import Foundation

struct ScenarioResult: Codable {
    let name: String
    let medianMs: Double
    let p95Ms: Double
    let minMs: Double
    let matches: Int?
    let deferred: Int?

    init(name: String, milliseconds: [Double], matches: Int? = nil, deferred: Int? = nil) {
        self.deferred = deferred
        let sorted = milliseconds.sorted()
        self.name = name
        medianMs = Statistics.median(sorted)
        p95Ms = Statistics.percentile(sorted, 0.95)
        minMs = sorted.first ?? 0
        self.matches = matches
    }
}

struct SizeResult: Codable {
    let items: Int
    let historyKB: Double
    let scenarios: [ScenarioResult]
}

struct Machine: Codable {
    let cpu: String
    let macOS: String
}

struct BenchReport: Codable {
    let recorded: String
    let commit: String
    let machine: Machine
    let seed: UInt64
    let corpus: String
    let iterations: Int
    let sizes: [SizeResult]

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func save(in packageRoot: URL) throws -> URL {
        let folder = packageRoot.appending(path: "Bench/results", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = String(recorded.replacingOccurrences(of: ":", with: ".").dropLast())
        let url = folder.appending(path: "\(stamp)-\(commit).json")
        try (json() + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func table() -> String {
        var lines = [
            "History benchmark · commit \(commit) · \(machine.cpu) · macOS \(machine.macOS) · seed \(seed) · corpus \(corpus) · \(iterations) runs",
        ]
        for size in sizes {
            lines.append("")
            lines.append("\(size.items) items · history.json \(String(format: "%.0f", size.historyKB)) KB")
            lines.append(Self.row("scenario", "median ms", "p95 ms", "min ms", "matches", "deferred", left: true))
            for scenario in size.scenarios {
                lines.append(Self.row(
                    scenario.name,
                    Self.ms(scenario.medianMs), Self.ms(scenario.p95Ms), Self.ms(scenario.minMs),
                    scenario.matches.map(String.init) ?? "-", scenario.deferred.map(String.init) ?? "-"
                ))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ name: String, _ median: String, _ p95: String, _ minimum: String, _ matches: String, _ deferred: String, left: Bool = false) -> String {
        [
            pad(name, 16, alignRight: !left), pad(median, 11), pad(p95, 11), pad(minimum, 11), pad(matches, 9), pad(deferred, 10),
        ].joined()
    }

    private static func pad(_ text: String, _ width: Int, alignRight: Bool = true) -> String {
        let spaces = String(repeating: " ", count: max(width - text.count, 0))
        return alignRight ? spaces + text : text + spaces
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

enum Statistics {
    static func median(_ sorted: [Double]) -> Double {
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func gitShortCommit(in directory: URL) -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "rev-parse", "--short", "HEAD"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "unknown" }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "unknown" : text
}
