import DictationEval
import Foundation
import NaviDictation


let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let casesURL = packageRoot.appending(path: "Bench/cases.json")

struct CaseFile: Decodable { let cases: [BenchCase] }
struct OutputFile: Decodable {
    let engine: String
    let outputs: [String: String]
}

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}
@MainActor func values(_ name: String) -> [String] {
    var found: [String] = []
    while let index = arguments.firstIndex(of: name), index + 1 < arguments.count {
        found.append(arguments[index + 1])
        arguments.removeSubrange(index ... index + 1)
    }
    return found
}

if flag("--latency") {
    try await Latency.run(verbose: flag("--failures"))
    exit(0)
}

let useAudio = flag("--audio")
let speeches = (values("--speech").first ?? "apple,parakeet")
    .split(separator: ",")
    .compactMap { DictationPipeline.Speech(rawValue: String($0)) }
let save = flag("--save")
let vocabulary = (values("--vocabulary").first ?? "").split(separator: ",").map(String.init)
let showFailures = flag("--failures")
let scoreFiles = values("--score")
let engines = (values("--engines").first ?? "rules,apple")
    .split(separator: ",")
    .compactMap { DictationPipeline.Cleanup(rawValue: String($0)) }

let cases = try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: casesURL)).cases
print("\(cases.count) cases from \(casesURL.path)")
if engines.contains(.apple), !DictationPipeline.appleModelIsReady {
    print("Note: Apple's model is not ready on this Mac, so \"apple\" gives the rules result.")
}

var inputSets: [(name: String, inputs: [String: String])] = []
if useAudio {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dictation-bench-audio")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for benchCase in cases {
        let file = folder.appending(path: "\(benchCase.id).aiff")
        guard !FileManager.default.fileExists(atPath: file.path) || benchCase.spoken != nil else { continue }
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", file.path, benchCase.spoken ?? benchCase.input]
        try say.run()
        say.waitUntilExit()
    }
    for speech in speeches {
        if speech == .parakeet {
            print("Loading Parakeet (downloads about 0.5 GB the first time)…")
            try await DictationPipeline.prepareParakeet()
            if !vocabulary.isEmpty {
                print("Loading the vocabulary (downloads about 100 MB the first time)…")
                let count = await DictationPipeline.setVocabulary(vocabulary)
                print("Vocabulary: \(count) of \(vocabulary.count) terms")
            }
        }
        print("Transcribing \(cases.count) cases with \(speech.rawValue)…")
        var heardByCase: [String: String] = [:]
        var errorRates: [Double] = []
        var times: [Double] = []
        for benchCase in cases {
            let spoken = benchCase.spoken ?? benchCase.input
            let file = folder.appending(path: "\(benchCase.id).aiff")
            let start = ContinuousClock.now
            do {
                let heard = try await DictationPipeline.transcribe(file: file, with: speech)
                heardByCase[benchCase.id] = heard
                errorRates.append(Scoring.wordErrorRate(heard, reference: spoken))
            } catch {
                print("  \(benchCase.id): speech failed: \(error.localizedDescription)")
                heardByCase[benchCase.id] = ""
                errorRates.append(1)
            }
            let elapsed = ContinuousClock.now - start
            times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        let average = errorRates.reduce(0, +) / Double(max(errorRates.count, 1))
        let sorted = times.sorted()
        print(String(
            format: "  %@: speech word error rate %.1f%% · speech time p50 %.0f ms, p95 %.0f ms",
            speech.rawValue, average * 100, Summary.percentile(sorted, 0.5), Summary.percentile(sorted, 0.95)
        ))
        inputSets.append((speech.rawValue, heardByCase))
    }
    print("")
} else {
    inputSets.append(("typed", Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0.input) })))
}

var runs: [BenchRun] = []
for (source, inputs) in inputSets {
  for engine in engines {
    var scores: [CaseScore] = []
    for benchCase in cases {
        let input = inputs[benchCase.id] ?? benchCase.input
        let start = ContinuousClock.now
        let output = await DictationPipeline.clean(input, with: engine)
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        scores.append(Scoring.score(benchCase, output: output, milliseconds: milliseconds))
    }
    runs.append(BenchRun(engine: useAudio ? "\(source)→\(engine.rawValue)" : engine.rawValue, scores: scores))
  }
}
for path in scoreFiles {
    let file = try JSONDecoder().decode(OutputFile.self, from: Data(contentsOf: URL(filePath: path)))
    let scores = cases.compactMap { benchCase in
        file.outputs[benchCase.id].map { Scoring.score(benchCase, output: $0) }
    }
    runs.append(BenchRun(engine: file.engine, scores: scores))
}

print(Report.table(runs))
print("\npass = right words and no fillers · words = word accuracy · made-up = words never said · fill = fillers left")

if showFailures {
    for run in runs {
        print("\n== \(run.engine): cases that did not pass")
        for score in run.scores where !score.passed {
            let benchCase = cases.first { $0.id == score.id }
            print("- \(score.id)")
            let source = run.engine.components(separatedBy: "→").first ?? ""
            let input = inputSets.first { $0.name == source }?.inputs[score.id] ?? benchCase?.input ?? ""
            print("    in:   \(input)")
            print("    got:  \(score.output.replacingOccurrences(of: "\n", with: "⏎"))")
            print("    want: \(benchCase?.expected.first?.replacingOccurrences(of: "\n", with: "⏎") ?? "")")
            if !score.inventedWords.isEmpty { print("    made-up: \(score.inventedWords.joined(separator: ", "))") }
        }
    }
}

if save {
    let folder = packageRoot.appending(path: "Bench/results")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let stamp = ISO8601DateFormatter().string(from: .now).prefix(16).replacingOccurrences(of: ":", with: ".")
    for run in runs {
        let url = folder.appending(path: "\(stamp) \(run.engine).json")
        try encoder.encode(run).write(to: url)
        print("Saved \(url.lastPathComponent)")
    }
}
