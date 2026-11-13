import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib

public enum PNGEncoder {
    public static func encode(_ image: CGImage, pointSize: CGSize? = nil, level: Int32 = 3) -> Data? {
        if let data = fastEncode(image, pointSize: pointSize, level: level) { return data }
        return imageIOEncode(image, pointSize: pointSize)
    }

    static func imageIOEncode(_ image: CGImage, pointSize: CGSize?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let dpi = dpi(for: image, pointSize: pointSize) {
            properties[kCGImagePropertyDPIWidth] = dpi.width
            properties[kCGImagePropertyDPIHeight] = dpi.height
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func dpi(for image: CGImage, pointSize: CGSize?) -> CGSize? {
        guard let pointSize, pointSize.width > 0, pointSize.height > 0 else { return nil }
        return CGSize(width: CGFloat(image.width) / pointSize.width * 72, height: CGFloat(image.height) / pointSize.height * 72)
    }

    static func fastEncode(_ image: CGImage, pointSize: CGSize?, level: Int32) -> Data? {
        guard image.bitsPerComponent <= 8, image.width > 0, image.height > 0 else { return nil }
        let space: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb {
            space = own
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            space = srgb
        } else {
            return nil
        }
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), renderingIntent: .defaultIntent
        ) else { return nil }
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        defer { free(buffer.data) }

        let width = Int(buffer.width), height = Int(buffer.height), stride = buffer.rowBytes
        guard let pixels = buffer.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let opaque = isOpaque(image) || allOpaque(pixels, width: width, height: height, stride: stride)
        let channels = opaque ? 3 : 4
        let rowLength = width * channels + 1
        let parts = max(1, min(height / 32, ProcessInfo.processInfo.activeProcessorCount * 2))
        let rowsPerPart = (height + parts - 1) / parts

        let results = UnsafeMutableBufferPointer<Part?>.allocate(capacity: parts)
        results.initialize(repeating: nil)
        defer { results.deinitialize().deallocate() }
        let shared = Shared(pixels: pixels, results: results)
        DispatchQueue.concurrentPerform(iterations: parts) { index in
            let pixels = shared.pixels, results = shared.results
            let first = index * rowsPerPart, end = min(height, first + rowsPerPart)
            guard first < end else {
                results[index] = Part(bytes: [], adler: 1, length: 0)
                return
            }
            results[index] = compress(
                pixels: pixels, stride: stride, width: width, rows: first ..< end, channels: channels,
                rowLength: rowLength, level: level, last: index == parts - 1
            )
        }
        var stream: [UInt8] = [0x78, 0x01]
        var adler: uLong = 1
        for index in 0 ..< parts {
            guard let part = results[index] else { return nil }
            stream.append(contentsOf: part.bytes)
            if part.length > 0 { adler = adler32_combine(adler, part.adler, Int(part.length)) }
        }
        appendBigEndian(UInt32(truncatingIfNeeded: adler), to: &stream)

        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out.reserveCapacity(stream.count + 1024)
        var header: [UInt8] = []
        appendBigEndian(UInt32(width), to: &header)
        appendBigEndian(UInt32(height), to: &header)
        header += [8, opaque ? 2 : 6, 0, 0, 0]
        appendChunk("IHDR", header, to: &out)
        if let icc = iccChunk(for: space) { appendChunk("iCCP", icc, to: &out) }
        if let cicp = cicp(for: space) { appendChunk("cICP", cicp, to: &out) }
        if let dpi = dpi(for: image, pointSize: pointSize) {
            var phys: [UInt8] = []
            appendBigEndian(UInt32((dpi.width / 0.0254).rounded(.down)), to: &phys)
            appendBigEndian(UInt32((dpi.height / 0.0254).rounded(.down)), to: &phys)
            phys.append(1)
            appendChunk("pHYs", phys, to: &out)
        }
        appendChunk("IDAT", stream, to: &out)
        appendChunk("IEND", [], to: &out)
        return Data(out)
    }

    private struct Shared<Value>: @unchecked Sendable {
        let pixels: UnsafeMutablePointer<UInt8>
        let results: UnsafeMutableBufferPointer<Value>
    }

    struct Part {
        var bytes: [UInt8]
        var adler: uLong
        var length: Int
    }

    private static func compress(
        pixels: UnsafeMutablePointer<UInt8>, stride: Int, width: Int, rows: Range<Int>, channels: Int,
        rowLength: Int, level: Int32, last: Bool
    ) -> Part? {
        let length = rows.count * rowLength
        var filtered = [UInt8](repeating: 0, count: length)
        filtered.withUnsafeMutableBufferPointer { output in
            guard let base = output.baseAddress else { return }
            for y in rows {
                let target = base + (y - rows.lowerBound) * rowLength
                let row = pixels + y * stride
                target[0] = 2
                if channels == 4 {
                    if y == 0 {
                        (target + 1).update(from: row, count: width * 4)
                    } else {
                        let above = row - stride
                        for i in 0 ..< width * 4 { target[1 + i] = row[i] &- above[i] }
                    }
                } else if y == 0 {
                    for x in 0 ..< width {
                        target[1 + x * 3] = row[x * 4]
                        target[2 + x * 3] = row[x * 4 + 1]
                        target[3 + x * 3] = row[x * 4 + 2]
                    }
                } else {
                    let above = row - stride
                    for x in 0 ..< width {
                        target[1 + x * 3] = row[x * 4] &- above[x * 4]
                        target[2 + x * 3] = row[x * 4 + 1] &- above[x * 4 + 1]
                        target[3 + x * 3] = row[x * 4 + 2] &- above[x * 4 + 2]
                    }
                }
            }
        }
        var stream = z_stream()
        guard deflateInit2_(
            &stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        let capacity = Int(deflateBound(&stream, uLong(length))) + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let status: Int32 = filtered.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                stream.next_in = input.baseAddress
                stream.avail_in = uInt(length)
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(capacity)
                return deflate(&stream, last ? Z_FINISH : Z_SYNC_FLUSH)
            }
        }
        guard stream.avail_in == 0, status == (last ? Z_STREAM_END : Z_OK), stream.avail_out > 0 else { return nil }
        output.removeLast(Int(stream.avail_out))
        let adler = filtered.withUnsafeBufferPointer { adler32(1, $0.baseAddress, uInt(length)) }
        return Part(bytes: output, adler: adler, length: length)
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
    }

    private static func allOpaque(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) -> Bool {
        let parts = max(1, min(height, ProcessInfo.processInfo.activeProcessorCount))
        let rowsPerPart = (height + parts - 1) / parts
        let flags = UnsafeMutableBufferPointer<Bool>.allocate(capacity: parts)
        flags.initialize(repeating: true)
        defer { flags.deallocate() }
        let shared = Shared(pixels: pixels, results: flags)
        DispatchQueue.concurrentPerform(iterations: parts) { index in
            let pixels = shared.pixels, flags = shared.results
            let first = index * rowsPerPart, end = min(height, first + rowsPerPart)
            guard first < end else { return }
            for y in first ..< end {
                let row = pixels + y * stride
                var all: UInt8 = 0xFF
                for x in 0 ..< width { all &= row[x * 4 + 3] }
                if all != 0xFF {
                    flags[index] = false
                    return
                }
            }
        }
        return !flags.contains(false)
    }

    private static func iccChunk(for space: CGColorSpace) -> [UInt8]? {
        guard let icc = space.copyICCData() as Data? else { return nil }
        var size = compressBound(uLong(icc.count))
        var packed = [UInt8](repeating: 0, count: Int(size))
        let status = icc.withUnsafeBytes { source in
            compress2(&packed, &size, source.bindMemory(to: UInt8.self).baseAddress, uLong(icc.count), 9)
        }
        guard status == Z_OK else { return nil }
        return Array("ICC Profile".utf8) + [0, 0] + packed.prefix(Int(size))
    }

    private static func cicp(for space: CGColorSpace) -> [UInt8]? {
        switch space.name {
        case CGColorSpace.sRGB: [1, 13, 0, 1]
        case CGColorSpace.displayP3: [12, 13, 0, 1]
        default: nil
        }
    }

    private static func appendBigEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func appendChunk(_ type: String, _ body: [UInt8], to out: inout [UInt8]) {
        appendBigEndian(UInt32(body.count), to: &out)
        let typeBytes = Array(type.utf8)
        out += typeBytes
        out += body
        var crc = crc32(0, typeBytes, 4)
        if !body.isEmpty { crc = body.withUnsafeBufferPointer { crc32(crc, $0.baseAddress, uInt(body.count)) } }
        appendBigEndian(UInt32(truncatingIfNeeded: crc), to: &out)
    }
}
