import AVFoundation
import CoreVideo
import Testing
@testable import NaviRecording

@Suite("AudioMixdown")
struct AudioMixdownTests {
    private func pcmBuffer(frames: Int, channels: Int, start: Int64) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        let samples = (0..<frames * channels).map { Float(sin(Double($0 / channels) * 0.05)) * 0.2 }
        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: CMTime(value: start, timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample
        )
        return try #require(sample)
    }

    private func makeTwoTrackVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "navi-mix-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        func aac(_ channels: Int) -> AVAssetWriterInput {
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 96_000,
            ])
        }
        let system = aac(2)
        let mic = aac(1)
        [video, system, mic].forEach { writer.add($0) }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<30 {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        for chunk in 0..<10 {
            for (input, channels) in [(system, 2), (mic, 1)] {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                input.append(try pcmBuffer(frames: 4800, channels: channels, start: Int64(chunk) * 4800))
            }
        }
        [video, system, mic].forEach { $0.markAsFinished() }
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    @Test func twoAudioTracksBecomeOne() async throws {
        let url = try await makeTwoTrackVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(before.count == 2)

        await AudioMixdown.mixIntoOneTrack(at: url)

        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.15)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("mix-") }
        #expect(leftovers.isEmpty)
    }
}
