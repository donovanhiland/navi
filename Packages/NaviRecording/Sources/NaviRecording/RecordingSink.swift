import AVFoundation
import CoreMedia
import ScreenCaptureKit
import os

final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "co.navi.recording.samples", qos: .userInitiated)

    var onStreamStopped: (@Sendable (Error?) -> Void)?

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var firstTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private var finished = false
    private var loggedAudioFailure = false
    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Recording")

    init(url: URL, width: Int, height: Int, framesPerSecond: Int, computerAudio: Bool, microphone: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingMath.videoBitRate(width: width, height: height, framesPerSecond: framesPerSecond),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        videoInput = video
        writer.add(video)

        func audioInput(channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        if computerAudio {
            let input = audioInput(channels: 2)
            writer.add(input)
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }
        if microphone {
            let input = audioInput(channels: Self.microphoneChannels())
            writer.add(input)
            microphoneInput = input
        } else {
            microphoneInput = nil
        }

        super.init()
        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "could not start")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        handle(sampleBuffer, of: type)
    }

    func handle(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, writer.status == .writing else { return }
        switch type {
        case .screen: appendVideo(sampleBuffer)
        case .audio: appendAudio(sampleBuffer, to: systemAudioInput)
        case .microphone: appendAudio(sampleBuffer, to: microphoneInput)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStreamStopped?(error)
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw),
              status == .complete || status == .started
        else { return }

        let time = sampleBuffer.presentationTimeStamp
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            firstTime = time
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        if videoInput.append(sampleBuffer) { lastVideoTime = time }
    }

    static func microphoneChannels() -> Int {
        guard let format = AVCaptureDevice.default(for: .audio)?.activeFormat.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return 1 }
        return min(max(Int(description.pointee.mChannelsPerFrame), 1), 2)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard sessionStarted, let input, input.isReadyForMoreMediaData,
              CMSampleBufferDataIsReady(sampleBuffer),
              sampleBuffer.presentationTimeStamp >= firstTime
        else { return }
        if !input.append(sampleBuffer), !loggedAudioFailure {
            loggedAudioFailure = true
            Self.logger.error("An audio buffer was refused: \(self.writer.error?.localizedDescription ?? "no error", privacy: .public)")
        }
    }

    func finish() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.finishOnQueue(continuation) }
        }
    }

    private func finishOnQueue(_ continuation: CheckedContinuation<TimeInterval, any Error>) {
        finished = true
        guard sessionStarted, writer.status == .writing else {
            let failure = writer.status == .failed
                ? RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
                : RecordingError.noFrames
            writer.cancelWriting()
            continuation.resume(throwing: failure)
            return
        }

        var end = lastVideoTime
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if now > end, (now - end).seconds < 86_400 { end = now }
        writer.endSession(atSourceTime: end)
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        let duration = max((end - firstTime).seconds, 0)
        writer.finishWriting { [self] in
            if writer.status == .completed {
                continuation.resume(returning: duration)
            } else {
                continuation.resume(throwing: RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown error"))
            }
        }
    }
}
