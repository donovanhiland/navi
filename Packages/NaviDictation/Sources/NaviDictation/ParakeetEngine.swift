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
        let layers = await manager.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        let tokens = (result.tokenTimings ?? []).map {
            Sentences.Token(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), tokens)
    }
}

struct ParakeetEngine: SpeechEngine {
    func transcribe(audio: AsyncStream<AudioChunk>) async throws -> String {
        var buffers: [AVAudioPCMBuffer] = []
        for await chunk in audio { buffers.append(chunk.buffer) }
        try Task.checkCancellation()
        let samples = try Self.samples(of: buffers)
        guard samples.count > 1600 else { return "" }
        return try await ParakeetModel.shared.transcribe(samples)
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
