import Foundation

public enum TextCleanup {
    private static let stutterWords = ["i", "a", "the", "to", "and", "so", "it", "we", "in", "of"]

    private static let finalPeriodMinimumWords = 3

    public static func clean(_ input: String, addsFinalPeriod: Bool = true) -> String {
        var text = input.replacingOccurrences(of: "\n", with: " ")
        text = removeFillers(from: text)
        text = removeStutters(from: text)
        text = tidySpacingAndPunctuation(text)
        text = capitalize(text)
        if addsFinalPeriod { text = addFinalPeriod(to: text) }
        return text
    }

    static func removeFillers(from text: String) -> String {
        var text = text
        text = replace(#"(?:,\s*)?\b(?:um+|uh+|erm|er|hmm+)\b(?:\s*,)?"#, in: text, with: " ")
        text = replace(#",\s*(?:like|you know)\s*,"#, in: text, with: " ")
        text = replace(#"(^|[.!?]\s+)(?:like|you know),\s*"#, in: text, with: "$1")
        return text
    }

    static func removeStutters(from text: String) -> String {
        let words = stutterWords.joined(separator: "|")
        return replace(#"\b(\#(words))(?:\s+\1\b)+"#, in: text, with: "$1")
    }

    static func tidySpacingAndPunctuation(_ text: String) -> String {
        var text = text
        text = replace(#"\s+"#, in: text, with: " ")
        text = replace(#"\s+([,.?!;:])"#, in: text, with: "$1")
        text = replace(#",(?:\s*,)+"#, in: text, with: ",")
        text = replace(#"([.?!]),"#, in: text, with: "$1")
        text = replace(#"^[\s,;:]+"#, in: text, with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capitalize(_ text: String) -> String {
        let text = replace(#"(?<![\w.])i(?=$|[\s,?!;:'’]|\.(?!\w))"#, in: text, with: "I")
        var result = ""
        var capitalizeNext = true
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if capitalizeNext, character.isLetter {
                result.append(contentsOf: character.uppercased())
                capitalizeNext = false
                continue
            }
            result.append(character)
            if ".?!".contains(character) {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let endsAbbreviation = result.lowercased().hasSuffix("i.e.") || result.lowercased().hasSuffix("e.g.")
                if (next == nil || next?.isWhitespace == true), !endsAbbreviation { capitalizeNext = true }
            } else if !character.isWhitespace, !character.isPunctuation || character == "," {
                capitalizeNext = false
            }
        }
        return result
    }

    static func addFinalPeriod(to text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        return wordCount >= finalPeriodMinimumWords ? text + "." : text
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(
            of: pattern, with: template, options: [.regularExpression, .caseInsensitive],
            range: text.startIndex..<text.endIndex
        )
    }
}
