import Foundation

enum Sentences {
    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".?!".contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard next == nil || next!.isWhitespace else { continue }
            let lower = current.lowercased()
            if lower.hasSuffix("i.e.") || lower.hasSuffix("e.g.") { continue }
            appendTrimmed(current, to: &sentences)
            current = ""
        }
        appendTrimmed(current, to: &sentences)
        return sentences
    }

    static func join(_ sentences: [String]) -> String {
        sentences.filter { !$0.isEmpty }.reduce(into: "") { result, sentence in
            if result.isEmpty || result.hasSuffix("\n") {
                result += sentence
            } else {
                result += " " + sentence
            }
        }
    }

    struct Token: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    static func endSpans(text: String, tokens: [Token]) -> [ClosedRange<Double>]? {
        let sentences = split(text)
        var spans: [ClosedRange<Double>] = []
        for index in tokens.indices.dropLast() {
            let token = tokens[index].text.trimmingCharacters(in: .whitespaces)
            guard let last = token.last, ".?!".contains(last) else { continue }
            let next = tokens[index + 1]
            guard next.text.hasPrefix(" ") || next.text.hasPrefix("▁") else { continue }
            let lower = token.lowercased()
            if lower.hasSuffix("i.e.") || lower.hasSuffix("e.g.") { continue }
            spans.append(max(0, tokens[index].start - 0.2) ... next.start + 0.08)
        }
        guard spans.count == max(sentences.count - 1, 0) else { return nil }
        return spans
    }

    private static func appendTrimmed(_ piece: String, to sentences: inout [String]) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
    }
}
