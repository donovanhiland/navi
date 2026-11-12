@preconcurrency import AVFoundation
import Foundation
import os

final class LiveDictation: Sendable {
    static let passInterval: Double = 1.0
    static let minimumPassAudio: Double = 2.0
    static let quietForPass: Double = 0.3

    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Dictation")
    static let sampleRate = 16_000.0

    private struct State: @unchecked Sendable {
        var buffers: [AVAudioPCMBuffer] = []
        var seconds: Double = 0
        var lastSound: Double = 0
        var finished: [String] = []
        var cut = 0
        var rest: (sentences: [String], end: Double)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let cleaner = SentenceCleaner()

    func transcribe(audio: AsyncStream<AudioChunk>) async throws -> String {
        let passes = Task.detached(priority: .userInitiated) { [self] in await runPasses() }
        defer { passes.cancel() }
        for await chunk in audio {
            let buffer = chunk.buffer
            let loud = Microphone.loudness(of: buffer) >= Microphone.soundLevel
            state.withLockUnchecked {
                $0.buffers.append(buffer)
                $0.seconds += Double(buffer.frameLength) / buffer.format.sampleRate
                if loud { $0.lastSound = $0.seconds }
            }
        }
        let released = ContinuousClock.now
        passes.cancel()
        await passes.value
        try Task.checkCancellation()

        let snapshot = state.withLockUnchecked { $0 }
        var sentences = snapshot.finished
        var reused = false
        if let rest = snapshot.rest, snapshot.lastSound <= rest.end {
            sentences += rest.sentences
            reused = true
        } else {
            let samples = try ParakeetEngine.samples(of: snapshot.buffers)
            guard samples.count > 1600 else { return "" }
            if samples.count - snapshot.cut > 1600 {
                let text = try await ParakeetModel.shared.transcribe(Array(samples[min(snapshot.cut, samples.count)...]))
                sentences += Sentences.split(text)
            }
        }
        let heard = ContinuousClock.now
        let text = await cleaner.clean(sentences)
        let message = "Live: \(snapshot.finished.count) of \(sentences.count) sentences done before the release\(reused ? ", last pass reused" : ""); speech \((heard - released).milliseconds) ms, cleanup \((ContinuousClock.now - heard).milliseconds) ms"
        Self.logger.info("\(message, privacy: .public)")
        return text
    }

    private func runPasses() async {
        var lastPass: Double = 0
        var lastPassSound: Double = -1
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let snapshot = state.withLockUnchecked { $0 }
            let afterCut = snapshot.seconds - Double(snapshot.cut) / Self.sampleRate
            let onTimer = snapshot.seconds - lastPass >= Self.passInterval && afterCut >= Self.minimumPassAudio
            let wentQuiet = snapshot.seconds - snapshot.lastSound >= Self.quietForPass
                && snapshot.lastSound > lastPassSound && snapshot.lastSound > 0
            guard onTimer || wentQuiet else { continue }
            lastPass = snapshot.seconds
            lastPassSound = snapshot.lastSound
            do {
                try await pass(over: snapshot.buffers, seconds: snapshot.seconds, cut: snapshot.cut, endsQuiet: wentQuiet)
            } catch {
                Self.logger.error("Live pass failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func pass(over buffers: [AVAudioPCMBuffer], seconds: Double, cut: Int, endsQuiet: Bool) async throws {
        let start = ContinuousClock.now
        let samples = try ParakeetEngine.samples(of: buffers)
        guard samples.count - cut > 1600 else { return }
        let (text, tokens) = try await ParakeetModel.shared.transcribeWithTimes(Array(samples[cut...]))
        let all = Sentences.split(text)
        let done = Self.finishedSentences(in: samples, after: cut, text: text, tokens: tokens)
        let rest = Array(all.dropFirst(done?.sentences.count ?? 0))
        let applied = state.withLockUnchecked { state -> Bool in
            guard state.cut == cut else { return false }
            if let done {
                state.finished += done.sentences
                state.cut = done.cut
            }
            state.rest = (rest, seconds)
            return true
        }
        Self.logger.debug(
            "Pass at \(seconds, format: .fixed(precision: 1)) s\(endsQuiet ? " (quiet)" : ""), \((ContinuousClock.now - start).milliseconds) ms: \(all.count) sentences, \(done?.sentences.count ?? 0) done"
        )
        guard applied else { return }
        for sentence in endsQuiet ? all : all.dropLast() { await cleaner.prepare(sentence) }
    }
}

extension LiveDictation {
    static let pauseLevel: Float = 0.12

    static func finishedSentences(
        in samples: [Float], after cut: Int, text: String, tokens: [Sentences.Token]
    ) -> (sentences: [String], cut: Int)? {
        guard let spans = Sentences.endSpans(text: text, tokens: tokens), !spans.isEmpty else { return nil }
        let tail = samples[cut...]
        let speech = Pauses.speechLevel(tail)
        guard speech > 0 else { return nil }
        for index in spans.indices.reversed() {
            let span = spans[index]
            let range = cut + Int(span.lowerBound * sampleRate) ..< cut + Int(span.upperBound * sampleRate)
            guard let pause = Pauses.quietest(in: tail, range: range), pause.level <= speech * pauseLevel else { continue }
            return (Array(Sentences.split(text).prefix(index + 1)), pause.middle)
        }
        return nil
    }
}

actor SentenceCleaner {
    private let cleaner: TextCleaner
    private var results: [String: Task<String, Never>] = [:]

    init(cleaner: TextCleaner = TextCleaner()) {
        self.cleaner = cleaner
    }

    func prepare(_ sentence: String) {
        guard results[sentence] == nil else { return }
        let cleaner = cleaner
        results[sentence] = Task { await cleaner.cleanSentence(sentence) }
    }

    func clean(_ sentences: [String]) async -> String {
        for sentence in sentences { prepare(sentence) }
        var cleaned: [String] = []
        for sentence in sentences {
            guard let task = results[sentence] else { continue }
            cleaned.append(await task.value)
        }
        return Sentences.join(cleaned)
    }
}

extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
