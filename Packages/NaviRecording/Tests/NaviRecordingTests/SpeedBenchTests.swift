import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import Testing
@testable import NaviRecording

@Suite(.serialized)
struct SpeedBench {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["NAVI_BENCH"] != nil }
    nonisolated static var outputFolder: URL? {
        ProcessInfo.processInfo.environment["NAVI_BENCH_OUT"].map { URL(filePath: $0) }
    }

    static let width = 1600
    static let height = 1000
    static let framesPerSecond = 30
    static let seconds = 5

    struct Row {
        let name: String
        let median: Double
        let p95: Double
        let minimum: Double
    }

    static func log(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["NAVI_BENCH_LOG"] else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    static func summarize(_ name: String, _ samples: [Double]) -> Row {
        let sorted = samples.sorted()
        let row = Row(
            name: name, median: sorted[sorted.count / 2],
            p95: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], minimum: sorted[0]
        )
        log(String(format: "BENCH %-34@ median %8.2f ms  p95 %8.2f ms  min %8.2f ms", name as NSString, row.median, row.p95, row.minimum))
        return row
    }

    static func milliseconds(_ elapsed: Duration) -> Double {
        Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
    }

    @discardableResult
    static func timeAsync(_ name: String, iterations: Int = 8, warmup: Int = 1, _ body: () async throws -> Void) async -> Row {
        var failures = 0
        for _ in 0 ..< warmup {
            do { try await body() } catch { failures += 1 }
        }
        var samples: [Double] = []
        for _ in 0 ..< iterations {
            let start = ContinuousClock.now
            do { try await body() } catch { failures += 1; log("BENCH   error \(error)") }
            samples.append(milliseconds(ContinuousClock.now - start))
        }
        if failures > 0 { log("BENCH   FAILURES \(failures) in \(name)") }
        return summarize(name, samples)
    }

    static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "navi-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func baseImage() -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors = [CGColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for index in 0 ..< 8 {
            let rect = CGRect(x: 60 + index * 90, y: 80 + index * 70, width: 620, height: 380)
            context.setFillColor(CGColor(gray: index % 2 == 0 ? 0.97 : 0.14, alpha: 1))
            context.fill(rect)
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 40, width: rect.width, height: 40))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: index % 2 == 0 ? NSColor.black : NSColor.white,
            ]
            for line in 0 ..< 10 {
                ("Line \(line) of window \(index): the quick brown fox jumps over the lazy dog" as NSString)
                    .draw(at: CGPoint(x: rect.minX + 12, y: rect.maxY - 70 - CGFloat(line) * 26), withAttributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func pixelBuffer(base: CGImage, frame: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let t = CGFloat(frame)
        context.setFillColor(CGColor(srgbRed: 1, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 20 + t * 9, y: 300 + 120 * sin(t / 7), width: 180, height: 120))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.9, blue: 0.5, alpha: 1))
        context.fillEllipse(in: CGRect(x: 900 + 200 * cos(t / 11), y: 500 + 150 * sin(t / 9), width: 140, height: 140))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    static func pcm(frames: Int, channels: Int, start: Int64, frequency: Double) -> CMSampleBuffer {
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
        let samples = (0 ..< frames * channels).map { index -> Float in
            let n = Double(Int(start) + index / channels)
            return Float(sin(n * 2 * .pi * frequency / 48_000)) * 0.3
        }
        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: CMTime(value: start, timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample
        )
        return sample!
    }

    static func makeFixture(at url: URL, seconds: Int = seconds) async throws {
        log("fixture \(seconds)s start")
        defer { log("fixture \(seconds)s done") }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoMaxKeyFrameIntervalKey: 60],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        func aac(_ channels: Int) -> AVAssetWriterInput {
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000,
            ])
        }
        let system = aac(2)
        let mic = aac(1)
        [video, system, mic].forEach {
            $0.expectsMediaDataInRealTime = true
            writer.add($0)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let base = baseImage()
        for frame in 0 ..< seconds * framesPerSecond {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            adaptor.append(pixelBuffer(base: base, frame: frame), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)))
            for (input, channels, frequency) in [(system, 2, 440.0), (mic, 1, 660.0)] {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                input.append(pcm(frames: 1600, channels: channels, start: Int64(frame) * 1600, frequency: frequency))
            }
        }
        [video, system, mic].forEach { $0.markAsFinished() }
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }

    static func fixture(in folder: URL, seconds: Int = seconds) async throws -> URL {
        let url = folder.appending(path: "fixture-\(seconds).mp4")
        try await makeFixture(at: url, seconds: seconds)
        return url
    }

    static func screenFrame(_ pixels: CVPixelBuffer, frame: Int, start: CMTime) -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(framesPerSecond)),
            presentationTimeStamp: start + CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample
        )
        let buffer = sample!
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)! as NSArray
        (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return buffer
    }

    static func decodedAudio(at url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    static func frameCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        return count
    }

    @Test(.enabled(if: SpeedBench.enabled))
    func gifEncode() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = try await Self.fixture(in: folder)
        var gif: URL?
        await Self.timeAsync("gif.legacy-75-frames", iterations: 6) {
            _ = try await LegacyGIFExporter.makeGIF(from: video)
        }
        await Self.timeAsync("gif.encode-75-frames", iterations: 6) {
            gif = try await GIFExporter.makeGIF(from: video)
        }
        if let gif, let out = Self.outputFolder {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let target = out.appending(path: "out.gif")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: gif, to: target)
            let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
            Self.log("BENCH   gif frames \(CGImageSourceGetCount(source)) bytes \(try FileManager.default.attributesOfItem(atPath: gif.path)[.size] ?? 0)")
        }
    }

    static func mixdownRow(name: String, seconds: Int, saveAs: String) async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = try await fixture(in: folder, seconds: seconds)
        var work = folder.appending(path: "work.mp4")
        if seconds <= 1 {
            await timeAsync(name + "-legacy", iterations: 6) {
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.copyItem(at: video, to: work)
                await LegacyAudioMixdown.mixIntoOneTrack(at: work)
            }
        }
        await timeAsync(name, iterations: 6) {
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.copyItem(at: video, to: work)
            await AudioMixdown.mixIntoOneTrack(at: work)
        }
        let tracks = try await AVURLAsset(url: work).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        if let out = outputFolder {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let target = out.appending(path: saveAs)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: work, to: target)
            work = target
        }
        let samples = try await decodedAudio(at: work)
        let rms = (samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1))).squareRoot()
        log("BENCH   mixed samples \(samples.count) rms \(rms)")
    }

    @Test(.enabled(if: SpeedBench.enabled))
    func audioMixdown() async throws {
        try await Self.mixdownRow(name: "audio.mixdown-1s", seconds: 1, saveAs: "mixed-1s.mp4")
        if ProcessInfo.processInfo.environment["NAVI_BENCH_SKIP_MIX5"] == nil {
            try await Self.mixdownRow(name: "audio.mixdown-5s", seconds: 5, saveAs: "mixed-5s.mp4")
        }
    }

    @Test(.enabled(if: SpeedBench.enabled))
    func trimExport() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = try await Self.fixture(in: folder)
        let target = folder.appending(path: "trimmed.mp4")
        await Self.timeAsync("trim.legacy-2.5s", iterations: 6) {
            _ = try await LegacyTrim.export(video, from: 1.0, to: 3.5, outputURL: target)
        }
        await Self.timeAsync("trim.export-2.5s", iterations: 6) {
            _ = try await TrimWindow.export(video, from: 1.0, to: 3.5, outputURL: target)
        }
        let asset = AVURLAsset(url: target)
        let duration = try await asset.load(.duration).seconds
        let frames = try await Self.frameCount(of: target)
        Self.log("BENCH   trim duration \(duration) frames \(frames) audio tracks \(try await asset.loadTracks(withMediaType: .audio).count)")
    }

    @Test(.enabled(if: SpeedBench.enabled))
    func sinkPipeline() async throws {
        let tag = "sink"
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = Self.baseImage()
        let pool = (0 ..< 30).map { Self.pixelBuffer(base: base, frame: $0) }
        let total = 60
        var startSamples: [Double] = []
        var initSamples: [Double] = []
        var frameSamples: [Double] = []
        var finishSamples: [Double] = []
        var written = 0
        for round in 0 ..< 8 {
            let url = folder.appending(path: "sink-\(round).mp4")
            let start = CMClockGetTime(CMClockGetHostTimeClock())
            let frames = (0 ..< total).map { Self.screenFrame(pool[$0 % pool.count], frame: $0, start: start) }
            let begin = ContinuousClock.now
            let sink = try RecordingSink(
                url: url, width: Self.width, height: Self.height, framesPerSecond: Self.framesPerSecond,
                computerAudio: false, microphone: false
            )
            let initDone = ContinuousClock.now
            sink.handle(frames[0], of: .screen)
            let firstDone = ContinuousClock.now
            var perFrame: [Double] = []
            for index in 1 ..< total {
                try await Task.sleep(until: begin + .milliseconds(index * 1000 / Self.framesPerSecond), clock: .continuous)
                let before = ContinuousClock.now
                sink.handle(frames[index], of: .screen)
                perFrame.append(Self.milliseconds(ContinuousClock.now - before))
            }
            let allDone = ContinuousClock.now
            _ = try await sink.finish()
            let finished = ContinuousClock.now
            if round > 0 {
                startSamples.append(Self.milliseconds(firstDone - begin))
                initSamples.append(Self.milliseconds(initDone - begin))
                frameSamples += perFrame
                finishSamples.append(Self.milliseconds(finished - allDone))
            }
            written = try await Self.frameCount(of: url)
        }
        _ = Self.summarize("sink.start-to-first-frame.\(tag)", startSamples)
        _ = Self.summarize("sink.init-only.\(tag)", initSamples)
        _ = Self.summarize("sink.per-frame-handle.\(tag)", frameSamples)
        _ = Self.summarize("sink.stop-to-file.\(tag)", finishSamples)
        Self.log("BENCH   sink frames written \(written) of \(total)")
    }
}

extension SpeedBench {
    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    static func compareGIFs(_ ua: URL, _ ub: URL) throws {
        let a = try #require(CGImageSourceCreateWithURL(ua as CFURL, nil))
        let b = try #require(CGImageSourceCreateWithURL(ub as CFURL, nil))
        Self.log("COMPARE gif frames \(CGImageSourceGetCount(a)) vs \(CGImageSourceGetCount(b))")
        #expect(CGImageSourceGetCount(a) == CGImageSourceGetCount(b))
        var worstMean = 0.0
        var worstMax = 0
        var means: [Double] = []
        for index in 0 ..< min(CGImageSourceGetCount(a), CGImageSourceGetCount(b)) {
            let x = Self.rgba(try #require(CGImageSourceCreateImageAtIndex(a, index, nil)))
            let y = Self.rgba(try #require(CGImageSourceCreateImageAtIndex(b, index, nil)))
            #expect(x.count == y.count)
            var sum = 0
            var peak = 0
            for k in 0 ..< min(x.count, y.count) {
                let d = abs(Int(x[k]) - Int(y[k]))
                sum += d
                peak = max(peak, d)
            }
            let mean = Double(sum) / Double(x.count)
            means.append(mean)
            worstMean = max(worstMean, mean)
            worstMax = max(worstMax, peak)
            let delayA = (CGImageSourceCopyPropertiesAtIndex(a, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delayB = (CGImageSourceCopyPropertiesAtIndex(b, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            #expect((delayA?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) == (delayB?[kCGImagePropertyGIFUnclampedDelayTime] as? Double))
        }
        means.sort()
        Self.log("COMPARE gif per-frame mean abs diff: median \(means[means.count / 2]) worst \(worstMean); worst pixel diff \(worstMax)")
        let pa = CGImageSourceCopyProperties(a, nil) as? [CFString: Any]
        let pb = CGImageSourceCopyProperties(b, nil) as? [CFString: Any]
        let loopA = (pa?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        let loopB = (pb?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        #expect(loopA == loopB)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NAVI_BENCH_COMPARE"] != nil))
    func compareOutputs() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = try await Self.fixture(in: folder)
        let legacyCopy = folder.appending(path: "legacy.mp4")
        try FileManager.default.copyItem(at: video, to: legacyCopy)
        let legacyGIF = try await LegacyGIFExporter.makeGIF(from: legacyCopy)
        let newCopy = folder.appending(path: "new.mp4")
        try FileManager.default.copyItem(at: video, to: newCopy)
        let newGIF = try await GIFExporter.makeGIF(from: newCopy)
        try Self.compareGIFs(legacyGIF, newGIF)

        let trimA = try await LegacyTrim.export(video, from: 1.0, to: 3.5, outputURL: folder.appending(path: "ta.mp4"))
        let trimB = try await TrimWindow.export(video, from: 1.0, to: 3.5, outputURL: folder.appending(path: "tb.mp4"))
        for url in [trimA, trimB] {
            let asset = AVURLAsset(url: url)
            let audio = try await asset.loadTracks(withMediaType: .audio).count
            let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
            Self.log("COMPARE trim \(url.lastPathComponent) duration \(try await asset.load(.duration).seconds) frames \(try await Self.frameCount(of: url)) audio tracks \(audio) size \(size.map { "\($0.width)x\($0.height)" } ?? "none")")
        }
        let samplesA = try await Self.decodedAudio(at: trimA)
        let samplesB = try await Self.decodedAudio(at: trimB)
        Self.log("COMPARE trim audio samples \(samplesA.count) vs \(samplesB.count)")

        let short = try await Self.fixture(in: folder, seconds: 1)
        let mixA = folder.appending(path: "mixA.mp4")
        let mixB = folder.appending(path: "mixB.mp4")
        try FileManager.default.copyItem(at: short, to: mixA)
        try FileManager.default.copyItem(at: short, to: mixB)
        await LegacyAudioMixdown.mixIntoOneTrack(at: mixA)
        await AudioMixdown.mixIntoOneTrack(at: mixB)
        let x = try await Self.decodedAudio(at: mixA)
        let y = try await Self.decodedAudio(at: mixB)
        let count = min(x.count, y.count)
        var error = 0.0
        var peak = 0.0
        var energy = 0.0
        for k in 0 ..< count {
            let d = Double(abs(x[k] - y[k]))
            error += d * d
            peak = max(peak, d)
            energy += Double(x[k] * x[k])
        }
        Self.log("COMPARE mix samples \(x.count) vs \(y.count) rms diff \((error / Double(max(count, 1))).squareRoot()) peak diff \(peak) ref rms \((energy / Double(max(count, 1))).squareRoot())")
        let assetA = AVURLAsset(url: mixA)
        let assetB = AVURLAsset(url: mixB)
        Self.log("COMPARE mix durations \(try await assetA.load(.duration).seconds) vs \(try await assetB.load(.duration).seconds); video frames \(try await Self.frameCount(of: mixA)) vs \(try await Self.frameCount(of: mixB))")
    }
}
