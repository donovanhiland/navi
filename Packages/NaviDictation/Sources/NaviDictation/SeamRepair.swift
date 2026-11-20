import Foundation

enum SeamRepair {
    static let shortestPhrase = 2
    static let longestPhrase = 6
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
    private static let openers: Set<Character> = ["\"", "“", "‘", "(", "[", "{", "«"]
    private static let stops: Set<Character> = [",", ".", ";", ":", "!", "?", "…"]
    private static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "point", "double", "triple",
    ]

    static func collapsingRepeats(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var index = 0
        while index < words.count {
            if let length = repeatLength(in: words, at: index) {
                let ending = trailingMarks(of: words[index + 2 * length - 1])
                words[index + length - 1] = core(of: words[index + length - 1]) + ending
                words.removeSubrange(index + length ..< index + 2 * length)
            } else {
                index += 1
            }
        }
        return words.joined(separator: " ")
    }

    private static func repeatLength(in words: [String], at index: Int) -> Int? {
        let longest = min(longestPhrase, (words.count - index) / 2)
        guard longest >= shortestPhrase else { return nil }
        return (shortestPhrase ... longest).reversed().first { length in
            let phrase = words[index ..< index + length].map(normalized)
            let matches = (0 ..< length).allSatisfy { offset in
                phrase[offset] == normalized(words[index + length + offset])
            }
            return matches && looksLikeSeam(words, at: index, length: length, phrase: phrase)
        }
    }

    private static func looksLikeSeam(_ words: [String], at index: Int, length: Int, phrase: [String]) -> Bool {
        guard Set(phrase).count > 1, !isPeriodic(phrase), !phrase.contains(where: isNumber) else { return false }
        guard !words[index ..< index + 2 * length].contains(where: hasQuoteOrBracket) else { return false }
        guard !endsClause(words[index + length - 1]) else { return false }
        if index > 0, normalized(words[index - 1]) == phrase[length - 1] { return false }
        let after = index + 2 * length
        return after >= words.count || normalized(words[after]) != phrase[0]
    }

    private static func isPeriodic(_ phrase: [String]) -> Bool {
        (1 ..< phrase.count).contains { unit in
            phrase.count % unit == 0 && phrase.indices.allSatisfy { phrase[$0] == phrase[$0 % unit] }
        }
    }

    private static func hasQuoteOrBracket(_ word: String) -> Bool {
        (word.first.map(openers.contains) ?? false)
            || trailingMarks(of: word).contains { closers.contains($0) && $0 != "'" && $0 != "’" }
    }

    private static func isNumber(_ word: String) -> Bool {
        numberWords.contains(word) || (!word.isEmpty && word.allSatisfy(\.isNumber))
    }

    private static func endsClause(_ word: String) -> Bool {
        var trimmed = Substring(word)
        while let last = trimmed.last, closers.contains(last) { trimmed = trimmed.dropLast() }
        return trimmed.last.map(stops.contains) ?? false
    }

    private static func trailingMarks(of word: String) -> String {
        String(word.reversed().prefix { stops.contains($0) || closers.contains($0) }.reversed())
    }

    private static func core(of word: String) -> String {
        String(word.dropLast(trailingMarks(of: word).count))
    }

    private static func normalized(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }
}
