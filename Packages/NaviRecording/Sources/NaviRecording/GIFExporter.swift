import AVFoundation
import CoreVideo
import ImageIO
import os
import UniformTypeIdentifiers

enum GIFExporter {
    static let framesPerPiece = 6

    static func makeGIF(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.gifFailed("the file has no video")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let plan = RecordingMath.gifPlan(duration: duration, naturalSize: naturalSize)
        let builder = PieceBuilder(delay: plan.frameDelay, size: framesPerPiece)

        if transform.isIdentity {
            try await BlockingWork.run {
                try readFrames(asset: asset, track: track, plan: plan, into: builder)
            }
        } else {
            try await generateFrames(asset: asset, plan: plan, into: builder)
        }
        let pieces = await BlockingWork.run { builder.finish() }
        guard !pieces.isEmpty, let gif = GIFSplicer.join(pieces) else {
            throw RecordingError.gifFailed("no frames could be read")
        }

        let outputURL = videoURL.deletingPathExtension().appendingPathExtension("gif")
        try? FileManager.default.removeItem(at: outputURL)
        do {
            try gif.write(to: outputURL, options: .atomic)
        } catch {
            throw RecordingError.gifFailed("could not create the file")
        }
        return outputURL
    }

    private static func readFrames(
        asset: AVAsset, track: AVAssetTrack, plan: RecordingMath.GIFPlan, into builder: PieceBuilder
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: plan.width,
            kCVPixelBufferHeightKey as String: plan.height,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw RecordingError.gifFailed(reader.error?.localizedDescription ?? "no frames could be read")
        }

        var target = 0
        var previous: CMSampleBuffer?
        var cached: (sample: CMSampleBuffer, image: CGImage)?

        func emit(_ sample: CMSampleBuffer) {
            if let cached, cached.sample === sample {
                builder.add(cached.image)
            } else if let pixels = CMSampleBufferGetImageBuffer(sample), let image = Self.image(from: pixels) {
                cached = (sample, image)
                builder.add(image)
            } else if let cached {
                builder.add(cached.image)
            }
        }

        while let sample = output.copyNextSampleBuffer() {
            if let previous {
                let boundary = (previous.presentationTimeStamp.seconds + sample.presentationTimeStamp.seconds) / 2
                while target < plan.times.count, plan.times[target] <= boundary {
                    emit(previous)
                    target += 1
                }
            }
            previous = sample
        }
        if let previous {
            while target < plan.times.count {
                emit(previous)
                target += 1
            }
        }
        if reader.status == .failed, target == 0 {
            throw RecordingError.gifFailed(reader.error?.localizedDescription ?? "no frames could be read")
        }
    }

    private static func image(from pixels: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let data = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = CVImageBufferGetColorSpace(pixels)?.takeUnretainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(
            width: CVPixelBufferGetWidth(pixels), height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func generateFrames(asset: AVAsset, plan: RecordingMath.GIFPlan, into builder: PieceBuilder) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: plan.width, height: plan.height)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let times = plan.times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var added = 0
        var previous: CGImage?
        for await result in generator.images(for: times) {
            guard let image = (try? result.image) ?? previous else { continue }
            builder.add(image)
            previous = image
            added += 1
        }
        while added < plan.times.count, let previous {
            builder.add(previous)
            added += 1
        }
    }

    fileprivate static func encode(_ images: [CGImage], delay: Double) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, images.count, nil
        ) else { return Data() }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ] as CFDictionary
        for image in images {
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

private final class PieceBuilder: @unchecked Sendable {
    private let size: Int
    private let delay: Double
    private let group = DispatchGroup()
    private let limit = DispatchSemaphore(value: max(ProcessInfo.processInfo.activeProcessorCount, 2))
    private let results = OSAllocatedUnfairLock(initialState: [Int: Data]())
    private var current: [CGImage] = []
    private var lead: CGImage?
    private var index = 0

    init(delay: Double, size: Int) {
        self.delay = delay
        self.size = size
    }

    func add(_ image: CGImage) {
        current.append(image)
        if current.count == size { flush() }
    }

    func finish() -> [Data] {
        flush()
        group.wait()
        return results.withLock { pieces in pieces.keys.sorted().map { pieces[$0] ?? Data() } }
    }

    private func flush() {
        guard !current.isEmpty else { return }
        let frames = (lead.map { [$0] } ?? []) + current
        lead = current.last
        current = []
        let piece = index
        index += 1
        limit.wait()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [delay, results, limit, group] in
            let data = GIFExporter.encode(frames, delay: delay)
            results.withLock { $0[piece] = data }
            limit.signal()
            group.leave()
        }
    }
}

enum GIFSplicer {
    static func join(_ pieces: [Data]) -> Data? {
        var output = Data()
        for (index, piece) in pieces.enumerated() {
            guard let blocks = blocks(of: piece) else { return nil }
            if index == 0 {
                var header = blocks.header
                header[header.startIndex + 10] &= 0x7F & ~0x07
                output += header
            }
            output += blocks.body(isFirstPiece: index == 0)
        }
        output.append(0x3B)
        return output
    }

    struct Parsed {
        var header: Data
        var globalTable: Data?
        var parts: [Part]

        enum Part {
            case application(Data)
            case other(Data)
            case image(descriptor: Data, localTable: Data?, rest: Data)
        }

        func body(isFirstPiece: Bool) -> Data {
            var out = Data()
            var skip = Set<Int>()
            if !isFirstPiece, let firstImage = parts.firstIndex(where: { if case .image = $0 { true } else { false } }) {
                skip.insert(firstImage)
                var before = firstImage - 1
                while before >= 0, case .other = parts[before] {
                    skip.insert(before)
                    before -= 1
                }
            }
            for (index, part) in parts.enumerated() where !skip.contains(index) {
                switch part {
                case .application(let data):
                    if isFirstPiece { out += data }
                case .other(let data):
                    out += data
                case .image(let descriptor, let localTable, let rest):
                    if localTable == nil, let globalTable {
                        var patched = descriptor
                        patched[patched.startIndex + 9] |= 0x80 | (header[header.startIndex + 10] & 0x07)
                        out += patched
                        out += globalTable
                    } else {
                        out += descriptor
                        if let localTable { out += localTable }
                    }
                    out += rest
                }
            }
            return out
        }
    }

    static func blocks(of data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        guard bytes.count > 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return nil }
        var position = 13
        let packed = bytes[10]
        var globalTable: Data?
        if packed & 0x80 != 0 {
            let size = 3 * (1 << (Int(packed & 0x07) + 1))
            guard position + size <= bytes.count else { return nil }
            globalTable = Data(bytes[position ..< position + size])
            position += size
        }
        let header = Data(bytes[0 ..< 13])
        var parts: [Parsed.Part] = []

        func skipSubBlocks(_ at: inout Int) -> Bool {
            while at < bytes.count {
                let length = Int(bytes[at])
                at += 1 + length
                if length == 0 { return true }
            }
            return false
        }

        while position < bytes.count {
            switch bytes[position] {
            case 0x3B:
                return Parsed(header: header, globalTable: globalTable, parts: parts)
            case 0x21:
                let start = position
                guard position + 2 < bytes.count else { return nil }
                let label = bytes[position + 1]
                position += 2
                guard skipSubBlocks(&position) else { return nil }
                let slice = Data(bytes[start ..< position])
                parts.append(label == 0xFF ? .application(slice) : .other(slice))
            case 0x2C:
                guard position + 10 <= bytes.count else { return nil }
                let descriptor = Data(bytes[position ..< position + 10])
                let flags = bytes[position + 9]
                position += 10
                var local: Data?
                if flags & 0x80 != 0 {
                    let size = 3 * (1 << (Int(flags & 0x07) + 1))
                    guard position + size <= bytes.count else { return nil }
                    local = Data(bytes[position ..< position + size])
                    position += size
                }
                let restStart = position
                position += 1
                guard skipSubBlocks(&position), position <= bytes.count else { return nil }
                parts.append(.image(descriptor: descriptor, localTable: local, rest: Data(bytes[restStart ..< position])))
            default:
                return nil
            }
        }
        return nil
    }
}
