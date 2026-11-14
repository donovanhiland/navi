import AppKit
import Foundation
import NaviCore
import Observation
import os

@MainActor
@Observable
public final class VocabularyStore {
    public typealias Apply = @Sendable ([BoostTerm]) async -> Void

    public private(set) var vocabulary: Vocabulary
    @ObservationIgnored public let url: URL
    @ObservationIgnored private let apply: Apply
    @ObservationIgnored private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Vocabulary")

    public static var defaultURL: URL {
        Inbox.defaultDirectory.appending(path: "vocabulary.json", directoryHint: .notDirectory)
    }

    public convenience init(url: URL = VocabularyStore.defaultURL) {
        self.init(url: url, apply: { await ParakeetModel.shared.setVocabulary($0) })
    }

    init(url: URL, apply: @escaping Apply) {
        self.url = url
        self.apply = apply
        vocabulary = Self.load(from: url, logger: logger)
    }

    public var added: [VocabularyTerm] { vocabulary.added }

    public var learned: [VocabularyTerm] { vocabulary.learned }

    public var boostedCount: Int { vocabulary.boostTerms.count }

    @discardableResult
    public func add(_ text: String, soundsLike: [String] = []) -> Bool {
        let next = vocabulary.adding(text, soundsLike: soundsLike)
        guard next != vocabulary else { return false }
        update(next)
        return true
    }

    public func remove(_ id: UUID) {
        update(vocabulary.removing(id))
    }

    public func learn(from texts: [String]) {
        learn(from: texts) { SystemDictionary.knows($0) }
    }

    func learn(from texts: [String], isKnownWord: (String) -> Bool) {
        let sightings = WordLearner.sightings(in: texts, isKnownWord: isKnownWord)
        guard !sightings.isEmpty else { return }
        update(vocabulary.learning(sightings))
    }

    public func applyToEngine() {
        let terms = vocabulary.boostTerms
        let apply = apply
        Task.detached(priority: .utility) { await apply(terms) }
    }

    private func update(_ next: Vocabulary) {
        guard next != vocabulary else { return }
        let engineChanged = next.boostTerms != vocabulary.boostTerms
        vocabulary = next
        save()
        if engineChanged { applyToEngine() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(vocabulary).write(to: url, options: .atomic)
        } catch {
            logger.error("Could not save the vocabulary: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from url: URL, logger: Logger) -> Vocabulary {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Vocabulary.self, from: Data(contentsOf: url))
        } catch {
            logger.error("Could not read the vocabulary: \(error.localizedDescription, privacy: .public)")
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return .empty
        }
    }
}

@MainActor
public enum SystemDictionary {
    public static func knows(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word.lowercased(), startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}
