import Foundation
import DictationEval
import NaviDictation

enum Latency {
    static let texts: [(name: String, text: String)] = [
        ("short", "Can you send me the deck before the meeting tomorrow?"),
        ("medium", """
            Um so I looked at the build this morning and it fails on the release step because the signing \
            key is missing, so I think we should add the key to the secrets and then run it again before lunch.
            """),
        ("long", """
            Okay so here's the plan for this week. First I want to finish the dictation speed work, because right \
            now it takes a few seconds after I let go of the key, and that feels slow compared to Wispr Flow. \
            Then uh I want to look at the screenshot editor again, the crop tool still feels a little off when you \
            drag the corner fast. After that we can ship a new build to everyone, and I'll write up the notes. \
            Oh and remind me to check the history list with five thousand items, I think search got slower.
            """),
        ("very long", """
            Alright so I've been thinking about how the home window should work. The idea is that every capture \
            ends up in one place, so clips, screenshots, recordings, and the text from dictation all show up in \
            one list, newest first. Um I want filters at the top for each kind, and a search box that finds text \
            inside screenshots too, using the text we already pull out with Vision. Each row should show a small \
            picture, the app it came from, and when it was made. When you click a row, the right side shows a big \
            preview with the buttons you'd expect, like copy, save, show in Finder, and open in the editor. For \
            recordings it should play the video right there. I also think we need a way to pin things so they \
            stay at the top, and maybe folders later, but not for the first version. Keyboard support matters a \
            lot, so arrow keys move through the list, return copies, and command delete removes the item. Let's \
            keep it fast even with thousands of items, so the list has to load lazily and the pictures should be \
            small thumbnails that we make once and keep on disk.
            """),
    ]

    static func run(verbose: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dictation-bench-latency")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        print("Loading Parakeet…")
        try await DictationPipeline.prepareParakeet()
        _ = await DictationPipeline.clean("warm up the model", with: .apple)

        print("")
        print(pad("clip", 10), pad("words", 6), pad("audio s", 8), pad("speech ms", 10), pad("cleanup ms", 11), pad("after ms", 9), pad("live ms", 8), pad("live+pause ms", 14), "word errors after / live")
        for (name, text) in texts {
            let file = folder.appending(path: "\(name).aiff")
            if !FileManager.default.fileExists(atPath: file.path) {
                let say = Process()
                say.executableURL = URL(filePath: "/usr/bin/say")
                say.arguments = ["-o", file.path, text]
                try say.run()
                say.waitUntilExit()
            }
            let seconds = try DictationPipeline.duration(of: file)

            var speechTimes: [Double] = []
            var cleanupTimes: [Double] = []
            var heard = ""
            var cleaned = ""
            for _ in 0 ..< 3 {
                var start = ContinuousClock.now
                heard = try await DictationPipeline.transcribe(file: file, with: .parakeet)
                speechTimes.append(milliseconds(since: start))
                start = ContinuousClock.now
                cleaned = await DictationPipeline.clean(heard, with: .apple)
                cleanupTimes.append(milliseconds(since: start))
            }
            let live = try await DictationPipeline.dictateLive(file: file)
            let paused = try await DictationPipeline.dictateLive(file: file, pause: 0.5)
            let speech = median(speechTimes)
            let cleanup = median(cleanupTimes)
            if verbose { print("  heard: \(heard)\n  after: \(cleaned)\n  live:  \(paused.text)") }
            let words = heard.split(separator: " ").count
            print(
                pad(name, 10), pad("\(words)", 6), pad(String(format: "%.1f", seconds), 8),
                pad(String(format: "%.0f", speech), 10), pad(String(format: "%.0f", cleanup), 11),
                pad(String(format: "%.0f", speech + cleanup), 9), pad(String(format: "%.0f", live.milliseconds), 8),
                pad(String(format: "%.0f", paused.milliseconds), 14),
                String(
                    format: "%.1f%% / %.1f%%",
                    Scoring.wordErrorRate(cleaned, reference: text) * 100,
                    Scoring.wordErrorRate(paused.text, reference: text) * 100
                )
            )
        }
        print("\nspeech = Parakeet on the whole clip after the release · cleanup = rules + Apple's model, per sentence · after = both, all after the release (median of 3)\nlive = what ships: the clip plays at real speed, then the time from its end to the text (no release tail)\nlive+pause = the same with half a second of quiet before the release, as when people finish talking\nword errors = against the script, which keeps its um and uh, so neither is 0")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
    }
}
