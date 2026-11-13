import Foundation

enum HistoryCodec {
    static func decode(_ data: Data) -> [CaptureItem]? {
        data.withUnsafeBytes { raw -> [CaptureItem]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress, bytes.count >= 2 else { return nil }
            var start = 0
            while start < bytes.count, isSpace(base[start]) { start += 1 }
            var end = bytes.count
            while end > start, isSpace(base[end - 1]) { end -= 1 }
            guard end - start >= 2, base[start] == UInt8(ascii: "["), base[end - 1] == UInt8(ascii: "]") else { return nil }
            let body = (start + 1)..<(end - 1)
            let ranges = split(bytes, body)
            let slots = Slots(count: ranges.count)
            if ranges.count == 1 {
                slots.set(0, parse(bytes, ranges[0]))
                return slots.joined()
            }
            let shared = SharedBytes(value: bytes)
            DispatchQueue.concurrentPerform(iterations: ranges.count) { index in
                slots.set(index, parse(shared.value, ranges[index]))
            }
            return slots.joined()
        }
    }

    private static func split(_ bytes: UnsafeBufferPointer<UInt8>, _ body: Range<Int>) -> [Range<Int>] {
        let pieces = min(ProcessInfo.processInfo.activeProcessorCount * 4, max(body.count / (96 * 1024), 1))
        guard pieces > 1, let base = bytes.baseAddress else { return [body] }
        let separator: [UInt8] = Array("},{\"".utf8)
        var ranges: [Range<Int>] = []
        var start = body.lowerBound
        for piece in 1..<pieces {
            let from = max(start, body.lowerBound + body.count * piece / pieces)
            guard from < body.upperBound,
                  let found = memmem(base + from, body.upperBound - from, separator, separator.count)
            else { break }
            let brace = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            ranges.append(start..<(brace + 1))
            start = brace + 2
        }
        ranges.append(start..<body.upperBound)
        return ranges
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Piece? {
        var reader = Reader(bytes: bytes, position: range.lowerBound, end: range.upperBound)
        var piece = Piece(capacity: max(range.count / 1000, 4))
        reader.skipSpace()
        if reader.atEnd { return piece }
        while true {
            guard let item = reader.item() else {
                piece.destroy()
                return nil
            }
            piece.append(item)
            reader.skipSpace()
            if reader.atEnd { return piece }
            guard reader.consume(UInt8(ascii: ",")) else {
                piece.destroy()
                return nil
            }
            reader.skipSpace()
        }
    }

    fileprivate struct Piece {
        var base: UnsafeMutablePointer<CaptureItem>
        var count = 0
        var capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            base = .allocate(capacity: capacity)
        }

        mutating func append(_ item: CaptureItem) {
            if count == capacity {
                let grown = UnsafeMutablePointer<CaptureItem>.allocate(capacity: capacity * 2)
                grown.moveInitialize(from: base, count: count)
                base.deallocate()
                base = grown
                capacity *= 2
            }
            (base + count).initialize(to: item)
            count += 1
        }

        func destroy() {
            base.deinitialize(count: count)
            base.deallocate()
        }
    }

    @inline(__always) fileprivate static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    fileprivate struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var position: Int
        let end: Int

        var atEnd: Bool { position >= end }

        mutating func skipSpace() {
            while position < end, HistoryCodec.isSpace(bytes[position]) { position += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard position < end, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        mutating func item() -> CaptureItem? {
            guard consume(UInt8(ascii: "{")) else { return nil }
            var id: UUID?
            var kind: CaptureKind?
            var createdAt: Double?
            var lastUsedAt: Double?
            var copyCount: Int?
            var pinned: Bool?
            var text: String?
            var fileName: String?
            var sourceApp: String?
            var sourceBundleID: String?
            var contentHash: String?
            skipSpace()
            if consume(UInt8(ascii: "}")) { return nil }
            while true {
                skipSpace()
                guard let key = rawKey() else { return nil }
                skipSpace()
                guard consume(UInt8(ascii: ":")) else { return nil }
                skipSpace()
                switch key {
                case .id:
                    guard let value = stringBytes() else { return nil }
                    id = HistoryCodec.uuid(value)
                    if id == nil { return nil }
                case .kind:
                    guard let value = string() else { return nil }
                    kind = CaptureKind(rawValue: value)
                    if kind == nil { return nil }
                case .createdAt:
                    guard let value = number() else { return nil }
                    createdAt = value
                case .lastUsedAt:
                    guard let value = number() else { return nil }
                    lastUsedAt = value
                case .copyCount:
                    guard let value = integer() else { return nil }
                    copyCount = value
                case .pinned:
                    guard let value = bool() else { return nil }
                    pinned = value
                case .text:
                    guard let value = optionalString() else { return nil }
                    text = value.value
                case .fileName:
                    guard let value = optionalString() else { return nil }
                    fileName = value.value
                case .sourceApp:
                    guard let value = optionalString() else { return nil }
                    sourceApp = value.value
                case .sourceBundleID:
                    guard let value = optionalString() else { return nil }
                    sourceBundleID = value.value
                case .contentHash:
                    guard let value = string() else { return nil }
                    contentHash = value
                case .unknown:
                    guard skipValue() else { return nil }
                }
                skipSpace()
                if consume(UInt8(ascii: ",")) { continue }
                if consume(UInt8(ascii: "}")) { break }
                return nil
            }
            guard let id, let kind, let createdAt, let pinned, let contentHash else { return nil }
            let created = Date(timeIntervalSinceReferenceDate: createdAt)
            return CaptureItem(
                id: id, kind: kind, createdAt: created,
                lastUsedAt: lastUsedAt.map { Date(timeIntervalSinceReferenceDate: $0) } ?? created,
                copyCount: copyCount ?? 1, pinned: pinned, text: text, fileName: fileName,
                sourceApp: sourceApp, sourceBundleID: sourceBundleID, contentHash: contentHash
            )
        }

        enum Key { case id, kind, createdAt, lastUsedAt, copyCount, pinned, text, fileName, sourceApp, sourceBundleID, contentHash, unknown }

        mutating func rawKey() -> Key? {
            guard consume(UInt8(ascii: "\"")) else { return nil }
            let start = position
            while position < end, bytes[position] != UInt8(ascii: "\"") {
                if bytes[position] == UInt8(ascii: "\\") { return nil }
                position += 1
            }
            guard position < end else { return nil }
            let name = UnsafeBufferPointer(rebasing: bytes[start..<position])
            position += 1
            return Key(name)
        }

        mutating func stringBytes() -> UnsafeBufferPointer<UInt8>? {
            guard consume(UInt8(ascii: "\"")) else { return nil }
            let start = position
            while position < end {
                let byte = bytes[position]
                if byte == UInt8(ascii: "\"") {
                    let slice = UnsafeBufferPointer(rebasing: bytes[start..<position])
                    position += 1
                    return slice
                }
                if byte == UInt8(ascii: "\\") { return nil }
                position += 1
            }
            return nil
        }

        mutating func string() -> String? {
            guard consume(UInt8(ascii: "\"")) else { return nil }
            let start = position
            guard let base = bytes.baseAddress else { return nil }
            let found = Self.firstQuoteOrBackslash(base + start, end - start)
            guard found < end - start else { return nil }
            if base[start + found] == UInt8(ascii: "\"") {
                position = start + found + 1
                return String(decoding: UnsafeBufferPointer(start: base + start, count: found), as: UTF8.self)
            }
            return unescaped(from: start)
        }

        private mutating func unescaped(from start: Int) -> String? {
            var out: [UInt8] = []
            out.reserveCapacity(end - start)
            var index = start
            while index < end {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    position = index + 1
                    return String(decoding: out, as: UTF8.self)
                }
                guard byte == UInt8(ascii: "\\") else {
                    out.append(byte)
                    index += 1
                    continue
                }
                guard index + 1 < end else { return nil }
                index += 2
                switch bytes[index - 1] {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard var unit = hex4(at: index) else { return nil }
                    index += 4
                    if (0xD800..<0xDC00).contains(unit) {
                        guard index + 6 <= end, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u"),
                              let low = hex4(at: index + 2), (0xDC00..<0xE000).contains(low)
                        else { return nil }
                        unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        index += 6
                    } else if (0xDC00..<0xE000).contains(unit) {
                        return nil
                    }
                    guard let scalar = Unicode.Scalar(unit) else { return nil }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: return nil
                }
            }
            return nil
        }

        private func hex4(at index: Int) -> UInt32? {
            guard index + 4 <= end else { return nil }
            var value: UInt32 = 0
            for offset in 0..<4 {
                guard let digit = HistoryCodec.hexValue(bytes[index + offset]) else { return nil }
                value = value << 4 | UInt32(digit)
            }
            return value
        }

        private static func firstQuoteOrBackslash(_ base: UnsafePointer<UInt8>, _ count: Int) -> Int {
            let quote = SIMD16<UInt8>(repeating: 0x22)
            let slash = SIMD16<UInt8>(repeating: 0x5C)
            var index = 0
            while index + 16 <= count {
                let chunk = UnsafeRawPointer(base + index).loadUnaligned(as: SIMD16<UInt8>.self)
                if any((chunk .== quote) .| (chunk .== slash)) { break }
                index += 16
            }
            while index < count, base[index] != 0x22, base[index] != 0x5C { index += 1 }
            return index
        }

        mutating func optionalString() -> (value: String?, ())? {
            if matchLiteral("null") { return (nil, ()) }
            guard let value = string() else { return nil }
            return (value, ())
        }

        mutating func bool() -> Bool? {
            if matchLiteral("true") { return true }
            if matchLiteral("false") { return false }
            return nil
        }

        mutating func matchLiteral(_ literal: StaticString) -> Bool {
            let count = literal.utf8CodeUnitCount
            guard position + count <= end, memcmp(bytes.baseAddress! + position, literal.utf8Start, count) == 0 else { return false }
            position += count
            return true
        }

        mutating func integer() -> Int? {
            let start = position
            if position < end, bytes[position] == UInt8(ascii: "-") { position += 1 }
            let digits = position
            var value = 0
            while position < end, bytes[position] >= 0x30, bytes[position] <= 0x39 {
                let (scaled, overflow) = value.multipliedReportingOverflow(by: 10)
                guard !overflow else { return nil }
                value = scaled + Int(bytes[position] - 0x30)
                position += 1
            }
            guard position > digits else { position = start; return nil }
            if position < end, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[position]) { return nil }
            return bytes[start] == UInt8(ascii: "-") ? -value : value
        }

        mutating func number() -> Double? {
            let start = position
            while position < end {
                let byte = bytes[position]
                guard (byte >= 0x30 && byte <= 0x39) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") else { break }
                position += 1
            }
            guard position > start, position - start <= 40 else { return nil }
            return Double(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self))
        }

        mutating func skipValue() -> Bool {
            guard position < end else { return false }
            switch bytes[position] {
            case UInt8(ascii: "\""):
                return string() != nil
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while position < end {
                    let byte = bytes[position]
                    if byte == UInt8(ascii: "\"") {
                        guard string() != nil else { return false }
                        continue
                    }
                    position += 1
                    if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
                    if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                        depth -= 1
                        if depth == 0 { return true }
                    }
                }
                return false
            default:
                if matchLiteral("null") || matchLiteral("true") || matchLiteral("false") { return true }
                return number() != nil
            }
        }
    }

    fileprivate static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    fileprivate static func uuid(_ text: UnsafeBufferPointer<UInt8>) -> UUID? {
        guard text.count == 36 else { return nil }
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var index = 0
        var failed = false
        withUnsafeMutableBytes(of: &raw) { out in
            var position = 0
            while position < 36 {
                if position == 8 || position == 13 || position == 18 || position == 23 {
                    if text[position] != UInt8(ascii: "-") { failed = true; return }
                    position += 1
                    continue
                }
                guard let high = hexValue(text[position]), let low = hexValue(text[position + 1]) else { failed = true; return }
                out[index] = high << 4 | low
                index += 1
                position += 2
            }
        }
        return failed ? nil : UUID(uuid: raw)
    }

    private struct SharedBytes: @unchecked Sendable {
        let value: UnsafeBufferPointer<UInt8>
    }

    private final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [Piece?]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ piece: Piece?) {
            lock.lock()
            slots[index] = piece
            lock.unlock()
        }

        func joined() -> [CaptureItem]? {
            guard slots.allSatisfy({ $0 != nil }) else {
                for case let piece? in slots { piece.destroy() }
                return nil
            }
            let pieces = slots.compactMap { $0 }
            let total = pieces.reduce(0) { $0 + $1.count }
            return [CaptureItem](unsafeUninitializedCapacity: total) { buffer, initialized in
                var offset = 0
                for piece in pieces {
                    if piece.count > 0 { (buffer.baseAddress! + offset).moveInitialize(from: piece.base, count: piece.count) }
                    piece.base.deallocate()
                    offset += piece.count
                }
                initialized = total
            }
        }
    }
}

extension HistoryCodec.Reader.Key {
    init(_ name: UnsafeBufferPointer<UInt8>) {
        func equals(_ literal: StaticString) -> Bool {
            name.count == literal.utf8CodeUnitCount && memcmp(name.baseAddress!, literal.utf8Start, name.count) == 0
        }
        guard name.baseAddress != nil else { self = .unknown; return }
        if equals("text") { self = .text }
        else if equals("id") { self = .id }
        else if equals("kind") { self = .kind }
        else if equals("createdAt") { self = .createdAt }
        else if equals("lastUsedAt") { self = .lastUsedAt }
        else if equals("copyCount") { self = .copyCount }
        else if equals("pinned") { self = .pinned }
        else if equals("fileName") { self = .fileName }
        else if equals("sourceApp") { self = .sourceApp }
        else if equals("sourceBundleID") { self = .sourceBundleID }
        else if equals("contentHash") { self = .contentHash }
        else { self = .unknown }
    }
}
