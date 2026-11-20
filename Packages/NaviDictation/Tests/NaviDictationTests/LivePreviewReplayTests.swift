@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import NaviDictation

@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAVI_LIVE_OUT"] != nil))
struct LivePreviewReplay {
    static let sentence = "I keep thinking about why people pay for the product and I think the main reason is that it saves them time every single day. They open it in the morning, they capture a few screenshots, they mark them up, and they send them to the team without thinking about it. The second reason is trust, because everything stays on their own Mac and nothing goes to the cloud."

    static let visibleWords = 6

    struct Update: Codable {
        let seconds: Double
        let text: String
        let invented: Bool
    }

    struct Report: Codable {
        let audioSeconds: Double
        let firstUpdateSeconds: Double?
        let updates: [Update]
        let inventedShare: Double
        let finalText: String
        let finalRecall: Double
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Double, String)] = []
        let start = ContinuousClock.now

        func add(_ text: String) {
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            lock.withLock { items.append((seconds, text)) }
        }

        var all: [(Double, String)] { lock.withLock { items } }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    static func appears(_ run: [String], in reference: [String]) -> Bool {
        guard !run.isEmpty, run.count <= reference.count else { return run.isEmpty }
        return (0 ... reference.count - run.count).contains { Array(reference[$0 ..< $0 + run.count]) == run }
    }

    static func recall(_ heard: [String], _ reference: [String]) -> Double {
        var dp = Array(repeating: Array(repeating: 0, count: heard.count + 1), count: reference.count + 1)
        for i in 0 ..< reference.count {
            for j in 0 ..< heard.count {
                dp[i + 1][j + 1] = reference[i] == heard[j] ? dp[i][j] + 1 : max(dp[i][j + 1], dp[i + 1][j])
            }
        }
        return Double(dp[reference.count][heard.count]) / Double(max(reference.count, 1))
    }

    @Test("live words arrive while talking and are words that were said")
    func replay() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "navi-live-replay")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "speech.caf")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=LEF32@48000", Self.sentence]
        try say.run()
        say.waitUntilExit()

        try await ParakeetModel.shared.prepare()
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate / 10)
        let audioSeconds = Double(audio.length) / format.sampleRate
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let collector = Collector()
        let transcription = Task.detached {
            try await LiveDictation(onPartial: { collector.add($0) }).transcribe(audio: stream)
        }
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            try audio.read(into: buffer)
            if buffer.frameLength == 0 { break }
            continuation.yield(AudioChunk(buffer: buffer))
            try await Task.sleep(for: .milliseconds(100))
        }
        continuation.finish()
        let final = try await transcription.value

        let reference = Self.words(Self.sentence)
        let updates = collector.all.map { seconds, text in
            Update(seconds: seconds, text: text, invented: !Self.appears(Array(Self.words(text).suffix(Self.visibleWords)), in: reference))
        }
        let invented = Double(updates.filter(\.invented).count) / Double(max(updates.count, 1))
        let report = Report(
            audioSeconds: audioSeconds,
            firstUpdateSeconds: updates.first?.seconds,
            updates: updates,
            inventedShare: invented,
            finalText: final,
            finalRecall: Self.recall(Self.words(final), reference)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let out = ProcessInfo.processInfo.environment["NAVI_LIVE_OUT"] ?? ""
        try encoder.encode(report).write(to: URL(filePath: out))

        #expect(updates.count >= Int(audioSeconds / 2))
        #expect((report.firstUpdateSeconds ?? .infinity) < 2)
        #expect(invented <= 0.05)
        #expect(report.finalRecall >= 0.9)
    }
}
