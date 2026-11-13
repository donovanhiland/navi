import Foundation

enum SearchKernel {
    static let separator: UInt8 = 0xFF

    static func isASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var index = 0
        var seen = SIMD16<UInt8>(repeating: 0)
        while index + 64 <= bytes.count {
            let raw = UnsafeRawPointer(base + index)
            seen |= raw.loadUnaligned(as: SIMD16<UInt8>.self)
            seen |= raw.loadUnaligned(fromByteOffset: 16, as: SIMD16<UInt8>.self)
            seen |= raw.loadUnaligned(fromByteOffset: 32, as: SIMD16<UInt8>.self)
            seen |= raw.loadUnaligned(fromByteOffset: 48, as: SIMD16<UInt8>.self)
            index += 64
        }
        if seen.max() >= 0x80 { return false }
        var tail: UInt8 = 0
        while index < bytes.count {
            tail |= base[index]
            index += 1
        }
        return tail < 0x80
    }

    static func appendLowercasedASCII(_ bytes: UnsafeBufferPointer<UInt8>, to destination: UnsafeMutablePointer<UInt8>) {
        guard let base = bytes.baseAddress else { return }
        let upperFloor = SIMD16<UInt8>(repeating: 65)
        let span = SIMD16<UInt8>(repeating: 26)
        let bit = SIMD16<UInt8>(repeating: 0x20)
        var index = 0
        while index + 16 <= bytes.count {
            let chunk = UnsafeRawPointer(base + index).loadUnaligned(as: SIMD16<UInt8>.self)
            let isUpper = (chunk &- upperFloor) .< span
            let lowered = chunk.replacing(with: chunk | bit, where: isUpper)
            UnsafeMutableRawPointer(destination + index).storeBytes(of: lowered, as: SIMD16<UInt8>.self)
            index += 16
        }
        while index < bytes.count {
            let byte = base[index]
            destination[index] = (byte &- 65) < 26 ? byte | 0x20 : byte
            index += 1
        }
    }

    static func contains(
        _ haystack: UnsafePointer<UInt8>, _ haystackCount: Int, _ needle: UnsafePointer<UInt8>, _ needleCount: Int
    ) -> Bool {
        if needleCount > haystackCount { return false }
        if needleCount == 0 { return true }
        if needleCount == 1 { return memchr(haystack, Int32(needle[0]), haystackCount) != nil }
        let first = SIMD16<UInt8>(repeating: needle[0])
        let last = SIMD16<UInt8>(repeating: needle[needleCount - 1])
        let starts = haystackCount - needleCount + 1
        let middle = needleCount - 2
        var index = 0
        while index + 16 <= starts {
            let head = UnsafeRawPointer(haystack + index).loadUnaligned(as: SIMD16<UInt8>.self)
            let tail = UnsafeRawPointer(haystack + index + needleCount - 1).loadUnaligned(as: SIMD16<UInt8>.self)
            let candidates = (head .== first) .& (tail .== last)
            if any(candidates) {
                for lane in 0..<16 where candidates[lane] {
                    if middle == 0 || memcmp(haystack + index + lane + 1, needle + 1, middle) == 0 { return true }
                }
            }
            index += 16
        }
        while index < starts {
            if haystack[index] == needle[0],
               memcmp(haystack + index, needle, needleCount) == 0 { return true }
            index += 1
        }
        return false
    }
}
