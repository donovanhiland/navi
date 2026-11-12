import Foundation

/// Splits dictated text into sentences and finds where finished sentences end in the audio. Pure.
///
/// Live dictation uses this to keep sentences that are done while the user still talks: their text
/// is cleaned ahead of time, and only the audio after them is transcribed at the release.
enum Sentences {
    /// The sentences of `text`, split after `.`, `?`, or `!` and a space. Text with no end mark is one
    /// sentence. Empty pieces are dropped.
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

    /// Joins cleaned sentences with a space, or with nothing after a line break.
    static func join(_ sentences: [String]) -> String {
        sentences.filter { !$0.isEmpty }.reduce(into: "") { result, sentence in
            if result.isEmpty || result.hasSuffix("\n") {
                result += sentence
            } else {
                result += " " + sentence
            }
        }
    }

    /// A word or word piece with its time in the clip, in seconds.
    struct Token: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    /// Where each sentence but the last ends, as a span of time (seconds) that holds the pause after
    /// it. Parakeet gives the end mark its own token, timed over the pause, and the next word starts
    /// where it ends, so the span covers the end mark and the very start of the next word. Nil when
    /// the tokens do not line up with the sentences of `text`.
    static func endSpans(text: String, tokens: [Token]) -> [ClosedRange<Double>]? {
        let sentences = split(text)
        var spans: [ClosedRange<Double>] = []
        for index in tokens.indices.dropLast() {
            let token = tokens[index].text.trimmingCharacters(in: .whitespaces)
            guard let last = token.last, ".?!".contains(last) else { continue }
            let next = tokens[index + 1]
            // A dot inside a word ("example.com") has no space before the next piece.
            guard next.text.hasPrefix(" ") || next.text.hasPrefix("▁") else { continue }
            let lower = token.lowercased()
            if lower.hasSuffix("i.e.") || lower.hasSuffix("e.g.") { continue }
            spans.append(max(0, tokens[index].start - 0.2) ... next.start + 0.08)
        }
        // Every sentence but the last ends at one of these; otherwise the text and tokens differ.
        guard spans.count == max(sentences.count - 1, 0) else { return nil }
        return spans
    }

    private static func appendTrimmed(_ piece: String, to sentences: inout [String]) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
    }
}
