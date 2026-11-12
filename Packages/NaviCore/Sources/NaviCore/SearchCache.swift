import Foundation

struct SearchCache {
    struct Key: Sendable {
        let text: [UInt8]
        let sourceApp: [UInt8]
    }

    private(set) var keys: [UUID: Key] = [:]

    mutating func remove(_ id: UUID) {
        keys[id] = nil
    }

    mutating func prepare(_ item: CaptureItem) {
        _ = key(for: item)
    }

    mutating func install(_ built: [UUID: Key], for items: [CaptureItem]) {
        for item in items where keys[item.id] == nil {
            if let key = built[item.id] { keys[item.id] = key }
        }
    }

    func covers(_ items: [CaptureItem]) -> Bool {
        items.allSatisfy { keys[$0.id] != nil }
    }

    mutating func search(
        _ query: String, in items: [CaptureItem], budget: Duration
    ) -> (items: [CaptureItem], deferred: Int) {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return (items, 0) }
        let deadline = ContinuousClock.now + budget
        var outOfTime = false
        var deferred = 0
        let found = items.filter { item in
            let key: Key
            if let cached = keys[item.id] {
                key = cached
            } else if Self.isHuge(item) {
                deferred += 1
                return false
            } else if outOfTime || ContinuousClock.now >= deadline {
                outOfTime = true
                deferred += 1
                return false
            } else {
                key = self.key(for: item)
            }
            return Self.contains(key.text, needle) || Self.contains(key.sourceApp, needle)
        }
        return (found, deferred)
    }

    static func makeKey(text: String?, sourceApp: String?) -> Key {
        Key(text: Self.fold(text ?? ""), sourceApp: Self.fold(sourceApp ?? ""))
    }

    private static func fold(_ string: String) -> [UInt8] {
        Array(string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
    }

    private mutating func key(for item: CaptureItem) -> Key {
        if let cached = keys[item.id] { return cached }
        let key = Self.makeKey(text: item.text, sourceApp: item.sourceApp)
        keys[item.id] = key
        return key
    }

    private static func isHuge(_ item: CaptureItem) -> Bool {
        (item.text?.utf8.count ?? 0) + (item.sourceApp?.utf8.count ?? 0) > Inbox.inlineKeyLimit
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }
}
