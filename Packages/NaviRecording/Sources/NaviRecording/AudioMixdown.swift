import AVFoundation
import os

enum AudioMixdown {
    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Recording")

    static func mixIntoOneTrack(at url: URL) async {
        let temp = url.deletingLastPathComponent().appending(path: "mix-\(UUID().uuidString).mp4")
        do {
            let asset = AVURLAsset(url: url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard audioTracks.count > 1, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }
            let videoFormat = try await videoTrack.load(.formatDescriptions).first
            try await Task.detached(priority: .userInitiated) {
                try copy(asset: asset, video: videoTrack, videoFormat: videoFormat, audio: audioTracks, to: temp)
            }.value
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            logger.error("Audio mixdown failed, keeping two tracks: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static func copy(
        asset: AVAsset, video: AVAssetTrack, videoFormat: CMFormatDescription?,
        audio: [AVAssetTrack], to url: URL
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(videoOut)
        reader.add(audioOut)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        writer.add(videoIn)
        writer.add(audioIn)

        guard reader.startReading() else { throw reader.error ?? RecordingError.writerFailed("reader did not start") }
        guard writer.startWriting() else { throw writer.error ?? RecordingError.writerFailed("writer did not start") }
        writer.startSession(atSourceTime: .zero)

        var pendingVideo = videoOut.copyNextSampleBuffer()
        var pendingAudio = audioOut.copyNextSampleBuffer()
        while pendingVideo != nil || pendingAudio != nil {
            let useVideo: Bool
            if let v = pendingVideo, let a = pendingAudio {
                useVideo = v.presentationTimeStamp <= a.presentationTimeStamp
            } else {
                useVideo = pendingVideo != nil
            }
            let input = useVideo ? videoIn : audioIn
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? RecordingError.writerFailed("writer failed") }
                Thread.sleep(forTimeInterval: 0.002)
            }
            if useVideo, let sample = pendingVideo {
                input.append(sample)
                pendingVideo = videoOut.copyNextSampleBuffer()
            } else if let sample = pendingAudio {
                input.append(sample)
                pendingAudio = audioOut.copyNextSampleBuffer()
            }
        }
        videoIn.markAsFinished()
        audioIn.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? RecordingError.writerFailed("finish failed") }
    }
}
