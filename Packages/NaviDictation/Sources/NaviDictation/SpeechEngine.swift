@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import Speech

protocol SpeechEngine: Sendable {
    func transcribe(audio: AsyncStream<AudioChunk>) async throws -> String
}

enum SpeechEngines {
    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "SpeechEngine")

    static func best() async -> any SpeechEngine {
        if await ParakeetModel.shared.isLoaded { return ParakeetEngine() }
        warmUpParakeet()
        return await apple()
    }

    static func warmUpParakeet() {
        Task.detached(priority: .utility) { try? await ParakeetModel.shared.prepare() }
    }

    static func apple() async -> any SpeechEngine {
        if #available(macOS 26.0, *), let engine = await AnalyzerEngine.makeIfReady() {
            return engine
        }
        return RecognizerEngine(locale: .current)
    }
}

@available(macOS 26.0, *)
struct AnalyzerEngine: SpeechEngine {
    let locale: Locale

    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "AnalyzerEngine")
    private static let download = OSAllocatedUnfairLock(initialState: false)

    static func makeIfReady() async -> AnalyzerEngine? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return AnalyzerEngine(locale: locale)
        case .supported, .downloading:
            startDownload(for: transcriber)
            return nil
        case .unsupported:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func startDownload(for transcriber: SpeechTranscriber) {
        let shouldStart = download.withLock { running -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        Task.detached {
            defer { download.withLock { $0 = false } }
            do {
                try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
            } catch {
                logger.error("Speech model download failed: \(error.localizedDescription)")
            }
        }
    }

    func transcribe(audio: AsyncStream<AudioChunk>) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { () -> String in
            var segments: [String] = []
            for try await result in transcriber.results {
                segments.append(String(result.text.characters))
            }
            return segments.joined(separator: " ")
        }

        do {
            try await analyzer.start(inputSequence: inputs)
            var converter = AudioFormatConverter(target: targetFormat)
            for await chunk in audio {
                if let converted = converter.convert(chunk.buffer) {
                    inputContinuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            inputContinuation.finish()
            if Task.isCancelled {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                throw CancellationError()
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value
        } catch {
            inputContinuation.finish()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

struct AudioFormatConverter {
    private let target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(target: AVAudioFormat?) {
        self.target = target
    }

    mutating func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target, buffer.format != target else { return buffer }
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            sourceFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

struct RecognizerEngine: SpeechEngine {
    let locale: Locale

    func transcribe(audio: AsyncStream<AudioChunk>) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else { throw DictationError.speechUnavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let job = RecognitionJob(request: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.begin(recognizer: recognizer, continuation: continuation)
                Task.detached {
                    for await chunk in audio { job.append(chunk) }
                    job.endAudio()
                }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

private final class RecognitionJob: @unchecked Sendable {
    private struct TaskBox: @unchecked Sendable {
        let task: SFSpeechRecognitionTask
    }

    private struct State {
        var continuation: CheckedContinuation<String, any Error>?
        var task: TaskBox?
        var finished = false
        var cancelled = false
    }

    private let request: SFSpeechAudioBufferRecognitionRequest
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func begin(recognizer: SFSpeechRecognizer, continuation: CheckedContinuation<String, any Error>) {
        let alreadyCancelled = state.withLock { state -> Bool in
            state.continuation = continuation
            return state.cancelled
        }
        if alreadyCancelled {
            finish(.failure(CancellationError()))
            return
        }
        let task = recognizer.recognitionTask(with: request) { [self] result, error in
            if let result, result.isFinal {
                finish(.success(result.bestTranscription.formattedString))
            } else if let error {
                finish(.failure(error))
            }
        }
        let box = TaskBox(task: task)
        state.withLock { $0.task = box }
    }

    func append(_ chunk: AudioChunk) {
        request.append(chunk.buffer)
    }

    func endAudio() {
        request.endAudio()
    }

    func cancel() {
        let task = state.withLock { state -> TaskBox? in
            state.cancelled = true
            return state.task
        }
        request.endAudio()
        task?.task.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<String, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<String, any Error>? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            state.finished = true
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
