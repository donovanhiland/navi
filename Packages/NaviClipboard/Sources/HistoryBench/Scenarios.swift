import AppKit
import Foundation
import NaviClipboard
import NaviCore

@MainActor
func runBench(_ options: BenchOptions, packageRoot: URL) throws -> BenchReport {
    let sizes = try options.sizes.map { try benchmarkSize($0, options: options) }
    return BenchReport(
        recorded: ISO8601DateFormatter().string(from: .now),
        commit: gitShortCommit(in: packageRoot),
        machine: Machine(
            cpu: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString
        ),
        seed: options.seed,
        corpus: options.corpus.rawValue,
        iterations: options.iterations,
        sizes: sizes
    )
}

@MainActor
private func benchmarkSize(_ count: Int, options: BenchOptions) throws -> SizeResult {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "history-bench-\(count)-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try HistorySeeder.write(count: count, seed: options.seed, corpus: options.corpus, to: directory)
    let hugeDirectory = FileManager.default.temporaryDirectory.appending(
        path: "history-bench-huge-\(count)-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: hugeDirectory) }
    try seedHugeHistory(count, options: options, in: hugeDirectory)
    let bytes = try fileSize(directory.appending(path: "history.json"))
    let limit = count + 100
    let inbox = Inbox(directory: directory, limit: limit)
    guard inbox.items.count == count else {
        throw BenchError.seeding(expected: count, found: inbox.items.count)
    }
    let runs = options.iterations * max(1, 1000 / count)
    var scenarios: [ScenarioResult] = []

    var previous: Inbox?
    let load = sample(runs, prepare: { settle(&previous) }, run: { _ in
        let loaded = Inbox(directory: directory, limit: limit)
        previous = loaded
        return loaded.items.count
    })
    settle(&previous)
    scenarios.append(ScenarioResult(name: "load", milliseconds: load.milliseconds))

    let filler = String(repeating: "the report ", count: 150)
    var added: UUID?
    var counter = 0
    let add = sample(runs, prepare: {
        if let id = added {
            inbox.remove(id)
            inbox.flush()
            added = nil
        }
    }, run: { _ in
        counter += 1
        added = inbox.add(text: "bench add \(counter) " + filler)?.id
        return 1
    })
    if let id = added { inbox.remove(id) }
    inbox.flush()
    scenarios.append(ScenarioResult(name: "add", milliseconds: add.milliseconds))

    let saveFlush = sample(runs, prepare: {
        if let id = added {
            inbox.remove(id)
            inbox.flush()
            added = nil
        }
    }, run: { _ in
        counter += 1
        added = inbox.add(text: "bench add \(counter) " + filler)?.id
        inbox.flush()
        return 1
    })
    if let id = added { inbox.remove(id) }
    inbox.flush()
    scenarios.append(ScenarioResult(name: "save-flush", milliseconds: saveFlush.milliseconds))

    var addedLarge: UUID?
    var largeCounter = 0
    let addLarge = sample(runs, prepare: {
        if let id = addedLarge {
            inbox.remove(id)
            inbox.flush()
            addedLarge = nil
        }
    }, run: { _ in
        largeCounter += 1
        addedLarge = inbox.add(text: "bench large \(largeCounter) " + hugeText)?.id
        return 1
    })
    if let id = addedLarge { inbox.remove(id) }
    inbox.flush()
    scenarios.append(ScenarioResult(name: "add-large-mixed", milliseconds: addLarge.milliseconds))

    let queries = SearchQueries(options.corpus)
    for (name, query) in queries.warm {
        let result = sample(runs, prepare: { () }, run: { _ in inbox.search(query).count })
        scenarios.append(ScenarioResult(name: name, milliseconds: result.milliseconds, matches: result.count))
    }
    func coldSearch(_ name: String, _ query: String, in directory: URL) -> ScenarioResult {
        var deferred = 0
        var last: Inbox?
        let cold = sample(runs, prepare: { () -> Inbox in
            settle(&last)
            let fresh = Inbox(directory: directory, limit: limit)
            last = fresh
            return fresh
        }, run: { fresh in
            let found = fresh.search(query).count
            deferred = fresh.deferredSearchItems
            return found
        })
        settle(&last)
        return ScenarioResult(name: name, milliseconds: cold.milliseconds, matches: cold.count, deferred: deferred)
    }
    for (name, query) in queries.cold { scenarios.append(coldSearch(name, query, in: directory)) }
    scenarios.append(coldSearch("search-cold-huge", "привет", in: hugeDirectory))
    let warmup = sample(runs, prepare: { Inbox(directory: directory, limit: limit) }, run: { fresh in
        while !fresh.isSearchReady { RunLoop.main.run(mode: .default, before: .now + 0.0005) }
        return 1
    })
    scenarios.append(ScenarioResult(name: "search-warmup", milliseconds: warmup.milliseconds))

    let model = ClipboardModel(inbox: inbox)
    let results = sample(runs, prepare: { () }, run: { _ in
        model.query = ""
        _ = model.results
        model.query = queries.results
        return model.results.count
    })
    scenarios.append(ScenarioResult(name: "results", milliseconds: results.milliseconds, matches: results.count))
    let repeated = sample(runs, prepare: { () }, run: { _ in model.results.count })
    scenarios.append(ScenarioResult(name: "results-repeat", milliseconds: repeated.milliseconds, matches: repeated.count))

    return SizeResult(items: count, historyKB: Double(bytes) / 1024, scenarios: scenarios)
}

@MainActor
private func seedHugeHistory(_ count: Int, options: BenchOptions, in directory: URL) throws {
    try HistorySeeder.write(count: count, seed: options.seed, corpus: options.corpus, to: directory)
    let inbox = Inbox(directory: directory, limit: count + 100)
    inbox.add(text: "bench huge " + hugeText)
    inbox.flush()
}

private let hugeText = String(repeating: "Привет мир 日本語のテキスト 😀 ", count: 40_000)

@MainActor
private func settle(_ inbox: inout Inbox?) {
    while let current = inbox, !current.isSearchReady { RunLoop.main.run(mode: .default, before: .now + 0.0005) }
    inbox = nil
}

private let warmUpRuns = 3

@MainActor
private func sample<Input>(
    _ iterations: Int, prepare: () -> Input, run: (Input) -> Int
) -> (milliseconds: [Double], count: Int) {
    var milliseconds: [Double] = []
    var count = 0
    for index in 0..<(warmUpRuns + iterations) {
        let input = prepare()
        let start = ContinuousClock.now
        count = run(input)
        let elapsed = ContinuousClock.now - start
        if index >= warmUpRuns { milliseconds.append(millis(elapsed)) }
    }
    return (milliseconds, count)
}

private func millis(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func fileSize(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
}

private struct SearchQueries {
    let warm: [(String, String)]
    let cold: [(String, String)]
    let results: String

    init(_ corpus: Corpus) {
        switch corpus {
        case .ascii:
            warm = [
                ("search-common", "the"), ("search-rare", "quartz"), ("search-none", "zzqxv"),
                ("search-accent-on-ascii", "ação"),
            ]
            cold = [("search-cold", "the")]
            results = "the"
        case .mixed:
            warm = [
                ("search-mixed-cyrillic", "привет"), ("search-mixed-japanese", "テキスト"),
                ("search-mixed-arabic", "مرحبا"), ("search-mixed-hindi", "नमस्ते"), ("search-mixed-emoji", "😀"),
                ("search-mixed-accent", "acao"), ("search-mixed-none", "zzqxv"),
            ]
            cold = [
                ("search-mixed-cold-cyrillic", "привет"), ("search-mixed-cold-japanese", "テキスト"),
                ("search-mixed-cold-arabic", "مرحبا"), ("search-mixed-cold-hindi", "नमस्ते"),
                ("search-mixed-cold-emoji", "😀"),
            ]
            results = "привет"
        }
    }
}
