// Adapted from Hex, ios/HEXMobile/ParakeetTranscriber.swift
// https://github.com/anomalyco/hex at 53164934130a (2026-11-07)
//
// MIT License. Copyright (c) 2026 Christopher Langton.
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute,
// sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions: The above copyright notice and this
// permission notice shall be included in all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os

actor ParakeetModel {
    static let shared = ParakeetModel()
    static let version: AsrModelVersion = .v3

    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Parakeet")
    private var manager: AsrManager?
    private var loading: Task<AsrManager, any Error>?
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    var isLoaded: Bool { manager != nil }

    @discardableResult
    func prepare() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: Self.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            let manager = try await task.value
            self.manager = manager
            loading = nil
            Self.logger.info("Parakeet is ready")
            return manager
        } catch {
            loading = nil
            Self.logger.error("Parakeet could not load: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribeWithTimes(samples).text
    }

    func transcribeWithTimes(_ samples: [Float]) async throws -> (text: String, tokens: [Sentences.Token]) {
        let manager = try await prepare()
        await takeTurn()
        defer { endTurn() }
        return try await run(samples, on: manager)
    }

    func preview(_ samples: [Float]) async -> String? {
        guard let manager, !isBusy else { return nil }
        isBusy = true
        defer { endTurn() }
        return try? await run(samples, on: manager, boosts: false).text
    }

    private func run(_ samples: [Float], on manager: AsrManager, boosts: Bool = true) async throws -> (text: String, tokens: [Sentences.Token]) {
        let layers = await manager.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        let timings = result.tokenTimings ?? []
        let tokens = timings.map {
            Sentences.Token(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        let text = boosts ? await boosted(result.text, timings: timings, samples: samples) : result.text
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), tokens)
    }

    static let boostConfig = VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50,
        spotterRescueEnabled: false
    )

    private var boostTerms: [BoostTerm] = []
    private var boosting: VocabularyBoostingSession?
    private var ctcLoading: Task<CtcModels, any Error>?

    var boostedTermCount: Int { boosting?.vocabulary.terms.count ?? 0 }

    func setVocabulary(_ terms: [BoostTerm]) async {
        guard terms != boostTerms else { return }
        boostTerms = terms
        guard !terms.isEmpty else {
            boosting = nil
            Self.logger.info("Vocabulary off: the list is empty")
            return
        }
        do {
            let models = try await ctcModels()
            let context = CustomVocabularyContext(terms: terms.map {
                CustomVocabularyTerm(text: $0.text, aliases: $0.soundsLike.isEmpty ? nil : $0.soundsLike)
            })
            let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: models, config: Self.boostConfig)
            guard terms == boostTerms else { return }
            boosting = session
            Self.logger.info("Vocabulary ready: \(session.vocabulary.terms.count) of \(terms.count) terms")
        } catch {
            if terms == boostTerms { boostTerms = [] }
            Self.logger.error("Vocabulary could not load: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ctcModels() async throws -> CtcModels {
        if let ctcLoading { return try await ctcLoading.value }
        let task = Task { try await CtcModels.downloadAndLoad(variant: .ctc110m) }
        ctcLoading = task
        do {
            return try await task.value
        } catch {
            ctcLoading = nil
            throw error
        }
    }

    private func boosted(_ text: String, timings: [TokenTiming], samples: [Float]) async -> String {
        guard let boosting, !timings.isEmpty else { return text }
        let start = ContinuousClock.now
        guard let output = await boosting.rescore(text: text, tokenTimings: timings, audioSamples: samples) else {
            return text
        }
        let applied = output.replacements.filter(\.shouldReplace)
        if output.wasModified {
            let swaps = applied.map { "\($0.originalWord) -> \($0.replacementWord ?? "")" }.joined(separator: ", ")
            Self.logger.info("Vocabulary in \((ContinuousClock.now - start).milliseconds) ms: \(swaps, privacy: .private)")
        }
        return output.text
    }

    private func takeTurn() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

private final class BufferStore: @unchecked Sendable {
    private let buffers = OSAllocatedUnfairLock(uncheckedState: [AVAudioPCMBuffer]())

    func append(_ buffer: AVAudioPCMBuffer) {
        buffers.withLock { $0.append(buffer) }
    }

    var all: [AVAudioPCMBuffer] { buffers.withLock { $0 } }
}

struct ParakeetEngine: SpeechEngine {
    func transcribe(audio: AsyncStream<AudioChunk>, onPartial: PartialHandler?) async throws -> String {
        let store = BufferStore()
        let preview = onPartial.map { onPartial in
            Task.detached(priority: .userInitiated) { await Self.runPreviews(of: { store.all }, onPartial: onPartial) }
        }
        for await chunk in audio { store.append(chunk.buffer) }
        preview?.cancel()
        try Task.checkCancellation()
        let samples = try Self.samples(of: store.all)
        guard samples.count > 1600 else { return "" }
        return try await ParakeetModel.shared.transcribe(samples)
    }

    static func runPreviews(of buffers: @Sendable () -> [AVAudioPCMBuffer], onPartial: PartialHandler) async {
        let converter = AudioConverter()
        var lastCount = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: LiveText.previewInterval)
            let buffers = buffers()
            guard buffers.count != lastCount, let format = buffers.first?.format else { continue }
            lastCount = buffers.count
            let (start, clipped) = LiveText.tailStart(
                frameCounts: buffers.map { Int($0.frameLength) },
                sampleRate: format.sampleRate,
                window: LiveText.previewWindow
            )
            guard let joined = join(Array(buffers[start...])),
                  let samples = try? converter.resampleBuffer(joined),
                  Double(samples.count) >= LiveText.minimumAudio * 16000,
                  let text = await ParakeetModel.shared.preview(samples),
                  !Task.isCancelled
            else { continue }
            onPartial(LiveText.trimmed(text, clipped: clipped))
        }
    }

    static func samples(of buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        guard let joined = join(buffers) else { return [] }
        return try AudioConverter().resampleBuffer(joined)
    }

    static func join(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        let total = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard total > 0, let joined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        var offset = 0
        for buffer in buffers where buffer.format == format {
            let frames = Int(buffer.frameLength)
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(joined.mutableAudioBufferList)
            for index in 0 ..< min(source.count, target.count) {
                guard let from = source[index].mData, let to = target[index].mData else { continue }
                memcpy(to.advanced(by: offset * bytesPerFrame), from, frames * bytesPerFrame)
            }
            offset += frames
        }
        joined.frameLength = AVAudioFrameCount(offset)
        return joined
    }
}
