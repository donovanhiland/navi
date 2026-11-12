@preconcurrency import AVFoundation
import Foundation
import os

/// Parakeet and cleanup while the user still talks, so the release waits for little or nothing.
///
/// About once a second, and each time the user goes quiet, Parakeet transcribes the audio after the
/// last finished sentence. A sentence is finished when another sentence follows it with a real pause
/// in between: its text is kept, it is cleaned in the background, and later passes start after it.
/// The cut goes in the middle of the pause, so no word is split.
///
/// Each pass also starts cleaning every sentence that another one follows; when it ends in quiet,
/// the last sentence too. If the user says nothing more before the release, that pass is the final
/// text: the release skips Parakeet, and the cleanup is done or nearly done.
final class LiveDictation: Sendable {
    /// How often a pass runs while the user talks, in seconds of new audio.
    static let passInterval: Double = 1.0
    /// A pass on a timer needs at least this much audio after the last finished sentence, in seconds.
    static let minimumPassAudio: Double = 2.0
    /// Quiet this long, after speech, starts a pass at once, in seconds.
    static let quietForPass: Double = 0.3

    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Dictation")
    static let sampleRate = 16_000.0

    /// The audio so far, and what the passes found.
    private struct State: @unchecked Sendable {
        var buffers: [AVAudioPCMBuffer] = []
        var seconds: Double = 0
        /// The end of the last loud buffer, in seconds from the start.
        var lastSound: Double = 0
        var finished: [String] = []
        /// Where the audio after the finished sentences starts, as a 16 kHz sample index.
        var cut = 0
        /// The newest pass's sentences after `cut`, and the end of the audio it heard, in seconds.
        var rest: (sentences: [String], end: Double)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let cleaner = SentenceCleaner()

    /// Reads the mic audio until the stream ends, then returns the cleaned text.
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
        // A pass that is running now hears almost everything; wait for it rather than start again.
        passes.cancel()
        await passes.value
        try Task.checkCancellation()

        let snapshot = state.withLockUnchecked { $0 }
        var sentences = snapshot.finished
        var reused = false
        if let rest = snapshot.rest, snapshot.lastSound <= rest.end {
            // Nothing but quiet since the newest pass: its text is the final text.
            sentences += rest.sentences
            reused = true
        } else {
            let samples = try ParakeetEngine.samples(of: snapshot.buffers)
            // Less than a tenth of a second is a tap, not speech.
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

    /// Runs passes until cancelled: once a second while the user talks, and at once when they go quiet.
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

    /// Transcribes the audio after `cut`, keeps the finished sentences, and starts their cleanup.
    private func pass(over buffers: [AVAudioPCMBuffer], seconds: Double, cut: Int, endsQuiet: Bool) async throws {
        let start = ContinuousClock.now
        let samples = try ParakeetEngine.samples(of: buffers)
        guard samples.count - cut > 1600 else { return }
        let (text, tokens) = try await ParakeetModel.shared.transcribeWithTimes(Array(samples[cut...]))
        let all = Sentences.split(text)
        let done = Self.finishedSentences(in: samples, after: cut, text: text, tokens: tokens)
        let rest = Array(all.dropFirst(done?.sentences.count ?? 0))
        let applied = state.withLockUnchecked { state -> Bool in
            // Another pass moved on already; this pass is too late to count.
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
        // Clean every sentence that another one follows: its text rarely changes in later passes.
        // When the user is quiet, the last one may be the end, so clean it ahead of time too.
        for sentence in endsQuiet ? all : all.dropLast() { await cleaner.prepare(sentence) }
    }
}

extension LiveDictation {
    /// How much quieter than speech a pause must be: 0.12 of the speech loudness, about -18 dB.
    static let pauseLevel: Float = 0.12

    /// The sentences of a pass that are done, and the sample index of the pause after the last one.
    /// A sentence is done when another sentence follows it and the audio near its end mark has a
    /// real pause (100 ms much quieter than speech). The cut goes in the middle of that pause.
    /// `text` and `tokens` are Parakeet's result for `samples[cut...]`. Pure.
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

/// Cleans sentences once, in the background, and keeps the result for the release.
actor SentenceCleaner {
    private let cleaner: TextCleaner
    private var results: [String: Task<String, Never>] = [:]

    init(cleaner: TextCleaner = TextCleaner()) {
        self.cleaner = cleaner
    }

    /// Starts cleaning a sentence, unless it is cleaned or being cleaned already.
    func prepare(_ sentence: String) {
        guard results[sentence] == nil else { return }
        let cleaner = cleaner
        results[sentence] = Task { await cleaner.cleanSentence(sentence) }
    }

    /// The cleaned text of all the sentences. New ones are cleaned at the same time.
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
