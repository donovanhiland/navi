import Foundation

public enum WordLearner {
    public struct Sighting: Equatable, Sendable {
        public let text: String
        public let count: Int

        public init(text: String, count: Int) {
            self.text = text
            self.count = count
        }
    }

    static let minimumSightings = 2
    static let minimumLength = 4
    static let maximumLength = 24
    static let maximumTextLength = 20_000
    static let codeMarkers = ["{", "}", "</", "();", "==", "=>", "->", "#include", "import "]
    static let chunkMarkers: [String] = ["://", "@", "/", "\\", "_", "=", "<", ">", "|", "`", "$", "#", "~", "*", "+"]
    static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]“”‘’«»…")
    static let sentenceEnders: Set<Character> = [".", "!", "?"]

    public static func sightings(in texts: [String], isKnownWord: (String) -> Bool) -> [Sighting] {
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        for text in texts where !looksLikeCode(text) {
            for word in candidates(in: text) {
                let key = word.lowercased()
                counts[key, default: 0] += 1
                spellings[key, default: [:]][word, default: 0] += 1
            }
        }
        var known: [String: Bool] = [:]
        return counts
            .filter { $0.value >= minimumSightings }
            .compactMap { key, count -> Sighting? in
                guard let spelling = spellings[key]?.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else {
                    return nil
                }
                let isKnown = known[key] ?? isKnownWord(spelling)
                known[key] = isKnown
                return isKnown ? nil : Sighting(text: spelling, count: count)
            }
            .sorted { ($1.count, $0.text) < ($0.count, $1.text) }
    }

    static func looksLikeCode(_ text: String) -> Bool {
        codeMarkers.contains { text.contains($0) }
    }

    static func candidates(in text: String) -> Set<String> {
        var found: Set<String> = []
        var atSentenceStart = true
        for line in text.prefix(maximumTextLength).split(whereSeparator: \.isNewline) {
            atSentenceStart = true
            for chunk in line.split(whereSeparator: \.isWhitespace) {
                let raw = String(chunk)
                defer { atSentenceStart = endsSentence(raw) }
                guard let word = word(in: raw), isCandidate(word, atSentenceStart: atSentenceStart) else { continue }
                found.insert(word)
            }
        }
        return found
    }

    static func endsSentence(_ chunk: String) -> Bool {
        let trimmed = chunk.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’"))
        return trimmed.last.map(sentenceEnders.contains) ?? false
    }

    static func word(in chunk: String) -> String? {
        guard !chunkMarkers.contains(where: { chunk.contains($0) }) else { return nil }
        var word = chunk.trimmingCharacters(in: edgePunctuation)
        for suffix in ["'s", "’s"] where word.hasSuffix(suffix) {
            word = String(word.dropLast(suffix.count))
        }
        guard (minimumLength ... maximumLength).contains(word.count) else { return nil }
        guard word.first?.isLetter == true, word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        guard !word.hasSuffix("-"), !word.contains("--"), word.filter(\.isLetter).count >= 3 else { return nil }
        return word
    }

    static func isCandidate(_ word: String, atSentenceStart: Bool) -> Bool {
        let letters = Array(word.filter(\.isLetter))
        guard let first = letters.first else { return false }
        let uppercase = letters.filter(\.isUppercase).count
        if uppercase == letters.count { return letters.count >= minimumLength }
        let humps = zip(letters, letters.dropFirst()).filter { $0.isLowercase && $1.isUppercase }.count
        if first.isLowercase {
            guard humps == 1 else { return false }
            let prefix = letters.prefix { $0.isLowercase }
            let rest = letters.dropFirst(prefix.count)
            return prefix.count <= 2 || rest.allSatisfy(\.isUppercase)
        }
        if humps == 1 { return true }
        guard humps == 0 else { return false }
        return !atSentenceStart && uppercase == 1
    }
}
