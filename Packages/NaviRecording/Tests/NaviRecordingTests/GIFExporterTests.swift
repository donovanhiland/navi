import AVFoundation
import CoreVideo
import ImageIO
import Testing
@testable import NaviRecording

@Suite("GIFExporter")
struct GIFExporterTests {
    private func makeVideo(seconds: Double, width: Int, height: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "navi-test-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 8 % 256), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    @Test func gifHasTheRightFrameCountSizeAndLoops() async throws {
        let video = try await makeVideo(seconds: 1, width: 1600, height: 900)
        defer { try? FileManager.default.removeItem(at: video) }
        let gif = try await GIFExporter.makeGIF(from: video)
        defer { try? FileManager.default.removeItem(at: gif) }

        #expect(gif.pathExtension == "gif")
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 15)
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(first.width == 800)
        #expect(first.height == 450)
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(gifProperties?[kCGImagePropertyGIFLoopCount] as? Int == 0)
    }

    @Test func longerVideoKeepsEveryFrameAndDelay() async throws {
        let video = try await makeVideo(seconds: 3, width: 640, height: 400)
        defer { try? FileManager.default.removeItem(at: video) }
        let gif = try await GIFExporter.makeGIF(from: video)
        defer { try? FileManager.default.removeItem(at: gif) }

        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 45)
        for index in 0..<CGImageSourceGetCount(source) {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            #expect(image.width == 640)
            #expect(image.height == 400)
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let delay = (frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            #expect(abs((delay ?? 0) - 1.0 / 15) < 0.01)
        }
    }
}
