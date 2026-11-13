import Foundation

struct SearchCache {
    struct Key: Sendable {
        let bytes: [UInt8]
    }

    struct Outcome {
        var indices: [Int] = []
        var built: [(UUID, Key)] = []
        var deferred = 0
    }

    private(set) var keys: [UUID: Key] = [:]

    mutating func remove(_ id: UUID) {
        keys[id] = nil
    }

    mutating func prepare(_ item: CaptureItem) {
        keys[item.id] = Self.makeKey(text: item.text, sourceApp: item.sourceApp)
    }

    mutating func install(_ built: [UUID: Key], for items: [CaptureItem]) {
        for item in items {
            if let key = built[item.id], keys[item.id] == nil { keys[item.id] = key }
        }
    }

    func covers(_ items: [CaptureItem]) -> Bool {
        keys.count >= items.count
    }

    mutating func search(
        _ query: String, in items: [CaptureItem], budget: Duration
    ) -> (items: [CaptureItem], deferred: Int) {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return (items, 0) }
        let deadline = ContinuousClock.now + budget
        let chunks = Self.chunkCount(for: items.count)
        let outcomes = Self.scan(items: items, keys: keys, needle: needle, deadline: deadline, chunks: chunks)
        var found: [CaptureItem] = []
        found.reserveCapacity(outcomes.reduce(0) { $0 + $1.indices.count })
        var deferred = 0
        for outcome in outcomes {
            for index in outcome.indices { found.append(items[index]) }
            for (id, key) in outcome.built { keys[id] = key }
            deferred += outcome.deferred
        }
        return (found, deferred)
    }

    private static let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)

    private static func chunkCount(for items: Int) -> Int {
        items < 800 ? 1 : min(cores, items / 200)
    }

    private static func scan(
        items: [CaptureItem], keys: [UUID: Key], needle: [UInt8], deadline: ContinuousClock.Instant, chunks: Int
    ) -> [Outcome] {
        let slots = Slots(count: chunks)
        let count = items.count
        let body: @Sendable (Int) -> Void = { chunk in
            let low = count * chunk / chunks
            let high = count * (chunk + 1) / chunks
            slots.set(chunk, scanRange(low..<high, items: items, keys: keys, needle: needle, deadline: deadline))
        }
        if chunks == 1 {
            body(0)
        } else {
            DispatchQueue.concurrentPerform(iterations: chunks, execute: body)
        }
        return slots.outcomes
    }

    private static func scanRange(
        _ range: Range<Int>, items: [CaptureItem], keys: [UUID: Key], needle: [UInt8], deadline: ContinuousClock.Instant
    ) -> Outcome {
        var outcome = Outcome()
        var outOfTime = false
        needle.withUnsafeBufferPointer { needleBuffer in
            let needlePointer = needleBuffer.baseAddress!
            items.withUnsafeBufferPointer { all in
                for index in range {
                    if let key = keys[all[index].id] {
                        let hit = key.bytes.withUnsafeBufferPointer {
                            contains($0, needlePointer, needleBuffer.count)
                        }
                        if hit { outcome.indices.append(index) }
                        continue
                    }
                    if isHuge(all[index]) || outOfTime || ContinuousClock.now >= deadline {
                        if !isHuge(all[index]) { outOfTime = true }
                        outcome.deferred += 1
                        continue
                    }
                    let key = makeKey(text: all[index].text, sourceApp: all[index].sourceApp)
                    outcome.built.append((all[index].id, key))
                    let hit = key.bytes.withUnsafeBufferPointer { contains($0, needlePointer, needleBuffer.count) }
                    if hit { outcome.indices.append(index) }
                }
            }
        }
        return outcome
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        guard let base = haystack.baseAddress else { return false }
        return SearchKernel.contains(base, haystack.count, needle, count)
    }

    private final class Slots: @unchecked Sendable {
        private let pointer: UnsafeMutablePointer<Outcome>
        private let count: Int

        init(count: Int) {
            self.count = count
            pointer = .allocate(capacity: count)
            pointer.initialize(repeating: Outcome(), count: count)
        }

        deinit {
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }

        func set(_ index: Int, _ outcome: Outcome) {
            pointer[index] = outcome
        }

        var outcomes: [Outcome] { Array(UnsafeBufferPointer(start: pointer, count: count)) }
    }

    static func makeKey(text: String?, sourceApp: String?) -> Key {
        var first = fold(text ?? "")
        first.append(SearchKernel.separator)
        first.append(contentsOf: fold(sourceApp ?? ""))
        return Key(bytes: first)
    }

    static func makeKeys(for items: [CaptureItem]) -> [Key] {
        let count = items.count
        let chunks = max(1, min(cores, count / 64))
        let slots = KeySlots(count: count)
        let work: @Sendable (Int) -> Void = { chunk in
            items.withUnsafeBufferPointer { all in
                for index in (count * chunk / chunks)..<(count * (chunk + 1) / chunks) {
                    slots.set(index, makeKey(text: all[index].text, sourceApp: all[index].sourceApp))
                }
            }
        }
        if chunks == 1 { work(0) } else { DispatchQueue.concurrentPerform(iterations: chunks, execute: work) }
        return slots.keys
    }

    private final class KeySlots: @unchecked Sendable {
        private let pointer: UnsafeMutablePointer<Key>
        private let count: Int

        init(count: Int) {
            self.count = count
            pointer = .allocate(capacity: count)
            pointer.initialize(repeating: Key(bytes: []), count: count)
        }

        deinit {
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }

        func set(_ index: Int, _ key: Key) {
            pointer[index] = key
        }

        var keys: [Key] { Array(UnsafeBufferPointer(start: pointer, count: count)) }
    }

    static func fold(_ string: String) -> [UInt8] {
        let original = string
        var string = string
        return string.withUTF8 { bytes in
            if SearchKernel.isASCII(bytes) {
                return [UInt8](unsafeUninitializedCapacity: bytes.count) { buffer, initialized in
                    if let base = buffer.baseAddress { SearchKernel.appendLowercasedASCII(bytes, to: base) }
                    initialized = bytes.count
                }
            }
            return Array(foldedWithFoundation(string: original).utf8)
        }
    }

    static func foldedWithFoundation(string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func isHuge(_ item: CaptureItem) -> Bool {
        (item.text?.utf8.count ?? 0) + (item.sourceApp?.utf8.count ?? 0) > Inbox.inlineKeyLimit
    }
}
