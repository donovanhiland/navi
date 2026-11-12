import Foundation

struct Comment {
    let start: String.Index
    let end: String.Index
    let line: Int
}

struct Lexer {
    let text: String
    var index: String.Index
    var line = 1
    var comments: [Comment] = []

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    var atEnd: Bool { index >= text.endIndex }

    func peek(_ offset: Int = 0) -> Character? {
        var i = index
        for _ in 0..<offset {
            guard i < text.endIndex else { return nil }
            i = text.index(after: i)
        }
        return i < text.endIndex ? text[i] : nil
    }

    func starts(with prefix: String) -> Bool {
        text[index...].hasPrefix(prefix)
    }

    mutating func advance(_ count: Int = 1) {
        for _ in 0..<count where index < text.endIndex {
            if text[index] == "\n" { line += 1 }
            index = text.index(after: index)
        }
    }

    mutating func scanCode(untilCloseParen: Bool) {
        var depth = 0
        while !atEnd {
            if starts(with: "//") {
                let start = index, startLine = line
                while !atEnd, peek() != "\n" { advance() }
                comments.append(Comment(start: start, end: index, line: startLine))
            } else if starts(with: "/*") {
                let start = index, startLine = line
                var nesting = 0
                repeat {
                    if starts(with: "/*") {
                        nesting += 1
                        advance(2)
                    } else if starts(with: "*/") {
                        nesting -= 1
                        advance(2)
                    } else {
                        advance()
                    }
                } while nesting > 0 && !atEnd
                comments.append(Comment(start: start, end: index, line: startLine))
            } else if peek() == "\"" || (peek() == "#" && rawStringStarts()) {
                scanString()
            } else if untilCloseParen, peek() == "(" {
                depth += 1
                advance()
            } else if untilCloseParen, peek() == ")" {
                if depth == 0 {
                    advance()
                    return
                }
                depth -= 1
                advance()
            } else {
                advance()
            }
        }
    }

    func rawStringStarts() -> Bool {
        var offset = 0
        while peek(offset) == "#" { offset += 1 }
        return peek(offset) == "\""
    }

    mutating func scanString() {
        var hashes = 0
        while peek() == "#" {
            hashes += 1
            advance()
        }
        let multiline = starts(with: "\"\"\"")
        advance(multiline ? 3 : 1)
        let closing = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
        let escape = "\\" + String(repeating: "#", count: hashes)
        while !atEnd {
            if starts(with: escape) {
                advance(escape.count)
                if peek() == "(" {
                    advance()
                    scanCode(untilCloseParen: true)
                } else {
                    advance()
                }
            } else if starts(with: closing) {
                advance(closing.count)
                return
            } else {
                advance()
            }
        }
    }
}

func comments(in text: String) -> [Comment] {
    var lexer = Lexer(text)
    lexer.scanCode(untilCloseParen: false)
    return lexer.comments
}

func isAllowed(_ comment: Comment, in text: String, path: String) -> Bool {
    if comment.line == 1, path.hasSuffix("Package.swift"),
        text[comment.start..<comment.end].hasPrefix("// swift-tools-version") {
        return true
    }
    let header = text.split(separator: "\n", omittingEmptySubsequences: false)
        .prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    let isLicense = header.contains { $0.contains("Copyright") } && header.contains { $0.contains("License") }
    return isLicense && comment.line <= header.count
}

let removedLine = "\u{0}"

func stripped(_ text: String, path: String) -> String {
    var result = text
    for comment in comments(in: text).reversed() where !isAllowed(comment, in: text, path: path) {
        var start = comment.start
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard text[previous] == " " || text[previous] == "\t" else { break }
            start = previous
        }
        var end = comment.end
        var replacement = ""
        if start == text.startIndex || text[text.index(before: start)] == "\n" {
            while end < text.endIndex, text[end] == " " || text[end] == "\t" { end = text.index(after: end) }
            if end == text.endIndex || text[end] == "\n" {
                replacement = removedLine
            } else {
                end = comment.end
                start = comment.start
            }
        }
        let lower = result.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: start))
        let upper = result.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: end))
        result.replaceSubrange(lower..<upper, with: replacement)
    }
    var output: [String] = []
    var afterRemoval = false
    for line in result.components(separatedBy: "\n") {
        if line == removedLine {
            afterRemoval = true
            continue
        }
        if afterRemoval {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let last = output.last?.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, last == nil || last == "" || last!.hasSuffix("{") || last!.hasSuffix("(") {
                continue
            }
            if trimmed.hasPrefix("}") || trimmed.hasPrefix(")") || trimmed.hasPrefix("]") {
                while output.last?.trimmingCharacters(in: .whitespaces) == "" { output.removeLast() }
            }
        }
        afterRemoval = false
        output.append(line)
    }
    return output.joined(separator: "\n")
}

func swiftFiles(_ arguments: [String]) -> [String] {
    if !arguments.isEmpty { return arguments }
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    git.arguments = ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.swift"]
    let pipe = Pipe()
    git.standardOutput = pipe
    try! git.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    git.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        .filter { FileManager.default.fileExists(atPath: $0) }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let fix = arguments.first == "--fix"
if fix { arguments.removeFirst() }

var found = 0
for path in swiftFiles(arguments) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    if fix {
        let output = stripped(text, path: path)
        if output != text { try! output.write(toFile: path, atomically: true, encoding: .utf8) }
        continue
    }
    for comment in comments(in: text) where !isAllowed(comment, in: text, path: path) {
        let first = text[comment.start..<comment.end].split(separator: "\n").first ?? ""
        print("\(path):\(comment.line): comment not allowed: \(first.prefix(80))")
        found += 1
    }
}
if found > 0 {
    print("\(found) comment(s). Remove them, or run: swift scripts/comments.swift --fix")
    exit(1)
}
