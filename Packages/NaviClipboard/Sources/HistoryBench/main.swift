import Foundation

let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

do {
    let options = try BenchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    let report = try runBench(options, packageRoot: packageRoot)
    if options.json {
        print(try report.json())
    } else {
        print(report.table())
    }
    if options.save {
        let url = try report.save(in: packageRoot)
        if !options.json { print("Saved \(url.lastPathComponent)") }
    }
} catch {
    print("history-bench: \(error)")
    exit(1)
}
