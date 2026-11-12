import AVFoundation
import Foundation

/// Public entry points to the dictation pipeline, used by the benchmark.
public enum DictationPipeline {
    /// A way to clean up raw speech-to-text output.
    public enum Cleanup: String, CaseIterable, Sendable {
        /// The raw text, unchanged.
        case none
        /// Rule-based cleanup only (fillers, stutters, spacing, capitals, final period).
        case rules
        /// What the app ships: rules, then Apple's on-device model when it is ready.
        case apple
    }

    public static func clean(_ raw: String, with cleanup: Cleanup) async -> String {
        switch cleanup {
        case .none: raw
        case .rules: TextCleanup.clean(raw)
        case .apple: await TextCleaner().clean(raw)
        }
    }

    /// True when Apple's on-device model can run now.
    public static var appleModelIsReady: Bool { TextCleaner.modelIsAvailable }

    /// A speech-to-text engine.
    public enum Speech: String, CaseIterable, Sendable {
        /// What the app picks: Parakeet when loaded, else Apple.
        case best
        /// Apple's `SpeechAnalyzer` (or `SFSpeechRecognizer`).
        case apple
        /// Parakeet TDT v3 through FluidAudio, like Hex. Downloads the model the first time.
        case parakeet
    }

    /// Downloads (first time) and loads Parakeet. Returns when it is ready.
    public static func prepareParakeet() async throws {
        try await ParakeetModel.shared.prepare()
    }

    /// Plays an audio file into live dictation at real speed, like a person talking, then `pause`
    /// seconds of quiet, and then ends the stream, like a release. Returns the cleaned text and the
    /// time from the release to the text.
    public static func dictateLive(file url: URL, pause: Double = 0) async throws -> (text: String, milliseconds: Double) {
        let file = try AVAudioFile(forReading: url)
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let live = Task { try await LiveDictation().transcribe(audio: stream) }
        let format = file.processingFormat
        let frames: AVAudioFrameCount = 1024
        let start = ContinuousClock.now
        var played = 0.0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            continuation.yield(AudioChunk(buffer: buffer))
            played += Double(buffer.frameLength) / format.sampleRate
            try await Task.sleep(until: start + .milliseconds(Int(played * 1000)), clock: .continuous)
        }
        var quiet = 0.0
        while quiet < pause, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            buffer.frameLength = frames
            continuation.yield(AudioChunk(buffer: buffer))
            quiet += Double(frames) / format.sampleRate
            played += Double(frames) / format.sampleRate
            try await Task.sleep(until: start + .milliseconds(Int(played * 1000)), clock: .continuous)
        }
        let released = ContinuousClock.now
        continuation.finish()
        let text = try await live.value
        let elapsed = ContinuousClock.now - released
        return (text, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }

    /// The length of an audio file, in seconds.
    public static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Transcribes an audio file with the same engines and audio path the app uses for the mic.
    public static func transcribe(file url: URL, with speech: Speech = .best) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let format = file.processingFormat
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            continuation.yield(AudioChunk(buffer: buffer))
        }
        continuation.finish()
        let engine: any SpeechEngine = switch speech {
        case .best: await SpeechEngines.best()
        case .apple: await SpeechEngines.apple()
        case .parakeet: ParakeetEngine()
        }
        return try await engine.transcribe(audio: stream)
    }
}
