import Foundation

struct EncodedItems {
    struct Entry {
        let item: CaptureItem
        let bytes: [UInt8]
    }

    private var entries: [UUID: Entry] = [:]

    mutating func encode(_ items: [CaptureItem]) -> Data {
        var next: [UUID: Entry] = [:]
        next.reserveCapacity(items.count)
        var pieces: [[UInt8]] = []
        pieces.reserveCapacity(items.count)
        var total = items.isEmpty ? 2 : 1 + items.count
        for item in items {
            let bytes: [UInt8]
            if let cached = entries[item.id], cached.item == item {
                bytes = cached.bytes
                next[item.id] = cached
            } else {
                bytes = Self.encodeItem(item)
                next[item.id] = Entry(item: item, bytes: bytes)
            }
            pieces.append(bytes)
            total += bytes.count
        }
        entries = next
        var data = Data(count: total)
        data.withUnsafeMutableBytes { raw in
            var cursor = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            cursor.pointee = UInt8(ascii: "[")
            cursor += 1
            for (index, bytes) in pieces.enumerated() {
                if index > 0 {
                    cursor.pointee = UInt8(ascii: ",")
                    cursor += 1
                }
                bytes.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress { cursor.update(from: base, count: source.count) }
                }
                cursor += bytes.count
            }
            cursor.pointee = UInt8(ascii: "]")
        }
        return data
    }

    static func encodeItem(_ item: CaptureItem) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(400 + (item.text?.utf8.count ?? 0) + (item.text?.utf8.count ?? 0) / 16)
        out.append(contentsOf: Array("{\"id\":\"".utf8))
        out.append(contentsOf: Array(item.id.uuidString.utf8))
        out.append(contentsOf: Array("\",\"kind\":\"".utf8))
        out.append(contentsOf: Array(item.kind.rawValue.utf8))
        out.append(contentsOf: Array("\",\"createdAt\":".utf8))
        out.append(contentsOf: Array("\(item.createdAt.timeIntervalSinceReferenceDate)".utf8))
        out.append(contentsOf: Array(",\"lastUsedAt\":".utf8))
        out.append(contentsOf: Array("\(item.lastUsedAt.timeIntervalSinceReferenceDate)".utf8))
        out.append(contentsOf: Array(",\"copyCount\":\(item.copyCount),\"pinned\":\(item.pinned)".utf8))
        field("text", item.text, into: &out)
        field("fileName", item.fileName, into: &out)
        field("sourceApp", item.sourceApp, into: &out)
        field("sourceBundleID", item.sourceBundleID, into: &out)
        out.append(contentsOf: Array(",\"contentHash\":".utf8))
        appendString(item.contentHash, into: &out)
        out.append(UInt8(ascii: "}"))
        return out
    }

    private static func field(_ name: String, _ value: String?, into out: inout [UInt8]) {
        guard let value else { return }
        out.append(UInt8(ascii: ","))
        out.append(UInt8(ascii: "\""))
        out.append(contentsOf: Array(name.utf8))
        out.append(UInt8(ascii: "\""))
        out.append(UInt8(ascii: ":"))
        appendString(value, into: &out)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func appendString(_ string: String, into out: inout [UInt8]) {
        var string = string
        out.append(UInt8(ascii: "\""))
        string.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return }
            var runStart = 0
            var index = 0
            let quote = SIMD16<UInt8>(repeating: 0x22)
            let slash = SIMD16<UInt8>(repeating: 0x5C)
            let control = SIMD16<UInt8>(repeating: 0x20)
            while index < bytes.count {
                while index + 16 <= bytes.count {
                    let chunk = UnsafeRawPointer(base + index).loadUnaligned(as: SIMD16<UInt8>.self)
                    if any((chunk .== quote) .| (chunk .== slash) .| (chunk .< control)) { break }
                    index += 16
                }
                guard index < bytes.count else { break }
                let byte = base[index]
                if byte != 0x22, byte != 0x5C, byte >= 0x20 {
                    index += 1
                    continue
                }
                out.append(contentsOf: UnsafeBufferPointer(start: base + runStart, count: index - runStart))
                switch byte {
                case 0x22: out.append(contentsOf: [0x5C, 0x22])
                case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
                case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
                case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
                case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
                case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
                case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
                default:
                    out.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 15)]])
                }
                index += 1
                runStart = index
            }
            out.append(contentsOf: UnsafeBufferPointer(start: base + runStart, count: bytes.count - runStart))
        }
        out.append(UInt8(ascii: "\""))
    }
}
