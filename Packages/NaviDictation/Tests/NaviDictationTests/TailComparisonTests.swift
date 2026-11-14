@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import NaviDictation

@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAVI_TAIL_OUT"] != nil))
struct TailComparison {
    struct Trial: Codable {
        var sentence: Int
        var voice: String
        var gain: Int
        var policy: String
        var latencyMs: Int
        var earlyMs: Int
        var keptMs: Int
        var waitMs: Int
        var text: String
        var full: String
    }

    static let rate = 16000.0
    static let buffer = 0.01

    static func decibels(_ s: ArraySlice<Float>) -> Float {
        let sum = s.reduce(Float(0)) { $0 + $1 * $1 }
        return 20 * log10(max((sum / Float(max(s.count, 1))).squareRoot(), 0.000_001))
    }

    static func stop(dbs: [Float], ends: [Double], release: Double, latency: Double, current: Bool) -> (stop: Double, wait: Double) {
        var gate = SoundGate()
        var lastSound: Double?
        var index = 0
        var now = release
        while true {
            while index < ends.count, ends[index] + latency <= now {
                let sound = current ? gate.isSound(decibels: dbs[index]) : Microphone.loudness(decibels: dbs[index]) >= Microphone.soundLevel
                if sound { lastSound = ends[index] + latency }
                index += 1
            }
            let since = Duration.milliseconds(Int(((now - release) * 1000).rounded()))
            let soundAgo = lastSound.map { Duration.milliseconds(Int(((now - $0) * 1000).rounded())) }
            let done = current
                ? Microphone.tailIsDone(sinceRelease: since, sinceSound: soundAgo)
                : (since >= .milliseconds(40) && (since >= .milliseconds(600) || soundAgo.map { $0 >= .milliseconds(200) } ?? true))
            if done || index >= ends.count {
                return (index > 0 ? ends[index - 1] : 0, (now - release) * 1000)
            }
            now += 0.01
        }
    }

    @Test func compare() async throws {
        let sentences: [(String, String)] = [
            ("Can you send me the report by Friday afternoon", ""),
            ("Let's meet at the coffee shop near the station", ""),
            ("Please remember to water the plants tomorrow", ""),
            ("I think we should ship the new build tonight", ""),
            ("Call mom and tell her I will be late", ""),
            ("Add milk eggs and bread to the shopping list", ""),
            ("The meeting moved to Thursday at [[slnc 180]] noon", ""),
            ("Send it to [[slnc 150]] Sarah", ""),
            ("Turn off the lights in the [[slnc 160]] kitchen", ""),
        ]
        try await ParakeetModel.shared.prepare()
        let dir = FileManager.default.temporaryDirectory.appending(path: "tail-main")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rng = SystemRandomNumberGenerator()
        var trials: [Trial] = []
        var cache: [String: String] = [:]
        for (si, (spoken, _)) in sentences.enumerated() {
            for voice in ["Samantha", "Daniel", "Karen"] {
                let file = dir.appending(path: "\(si)-\(voice).aiff")
                let say = Process()
                say.executableURL = URL(filePath: "/usr/bin/say")
                say.arguments = ["-v", voice, "-o", file.path, spoken]
                try say.run(); say.waitUntilExit()
                let f = try AVAudioFile(forReading: file)
                let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
                try f.read(into: buf)
                var speech = try AudioConverter().resampleBuffer(buf)
                var end = speech.count
                while end > 0, abs(speech[end - 1]) < 0.01 { end -= 1 }
                speech = Array(speech[0..<end])
                for gain in [0, -12, -20] {
                    let scale = Float(pow(10, Double(gain) / 20))
                    let lead = Int(0.3 * Self.rate)
                    var clip = [Float](repeating: 0, count: lead) + speech.map { $0 * scale } + [Float](repeating: 0, count: Int(1.5 * Self.rate))
                    for i in clip.indices { clip[i] += Float.random(in: -0.003...0.003, using: &rng) }
                    let speechEnd = Double(lead + speech.count) / Self.rate
                    let size = Int(Self.buffer * Self.rate)
                    let starts = Array(stride(from: 0, to: clip.count - size, by: size))
                    let ends = starts.map { Double($0 + size) / Self.rate }
                    let dbs = starts.map { Self.decibels(clip[$0 ..< $0 + size]) }

                    func transcript(_ stop: Double) async throws -> String {
                        let count = min(clip.count, Int((stop * Self.rate).rounded()))
                        let key = "\(si)-\(voice)-\(gain)-\(count)"
                        if let hit = cache[key] { return hit }
                        let text = count > 1600 ? try await ParakeetModel.shared.transcribe(Array(clip[0..<count])) : ""
                        cache[key] = text
                        return text
                    }
                    let full = try await transcript(Double(clip.count) / Self.rate)

                    for latencyMs in [10, 150] {
                        let latency = Double(latencyMs) / 1000
                        for earlyMs in [-300, -100, 0, 100, 200, 300, 500] {
                            let release = speechEnd - Double(earlyMs) / 1000
                            let results = [
                                ("before: -40 dB, quiet 200", Self.stop(dbs: dbs, ends: ends, release: release, latency: latency, current: false)),
                                ("after: room floor, quiet 300 if talking", Self.stop(dbs: dbs, ends: ends, release: release, latency: latency, current: true)),
                            ]
                            for (name, r) in results {
                                trials.append(Trial(sentence: si, voice: voice, gain: gain, policy: name, latencyMs: latencyMs,
                                                    earlyMs: earlyMs, keptMs: Int(((r.stop - release) * 1000).rounded()),
                                                    waitMs: Int(r.wait.rounded()), text: try await transcript(r.stop), full: full))
                            }
                        }
                    }
                }
            }
        }
        try JSONEncoder().encode(trials).write(to: URL(filePath: ProcessInfo.processInfo.environment["NAVI_TAIL_OUT"]!))
        print("TRIALS \(trials.count) unique \(cache.count)")
    }
}
