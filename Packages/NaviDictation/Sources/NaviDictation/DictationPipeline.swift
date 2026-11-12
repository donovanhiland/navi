import AVFoundation
import Foundation

public enum DictationPipeline {
    public enum Cleanup: String, CaseIterable, Sendable {
        case none
        case rules
        case apple
    }

    public static func clean(_ raw: String, with cleanup: Cleanup) async -> String {
        switch cleanup {
        case .none: raw
        case .rules: TextCleanup.clean(raw)
        case .apple: await TextCleaner().clean(raw)
        }
    }

    public static var appleModelIsReady: Bool { TextCleaner.modelIsAvailable }

    public enum Speech: String, CaseIterable, Sendable {
        case best
        case apple
        case parakeet
    }

    public static func prepareParakeet() async throws {
        try await ParakeetModel.shared.prepare()
    }

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

    public static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

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
