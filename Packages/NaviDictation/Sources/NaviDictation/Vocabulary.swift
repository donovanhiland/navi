import Foundation

public struct BoostTerm: Equatable, Sendable {
    public let text: String
    public let soundsLike: [String]
}

public struct VocabularyTerm: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable {
        case added
        case learned
    }

    public let id: UUID
    public let text: String
    public let soundsLike: [String]
    public let source: Source
    public let sightings: Int
    public let lastSeenAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        soundsLike: [String] = [],
        source: Source,
        sightings: Int = 0,
        lastSeenAt: Date
    ) {
        self.id = id
        self.text = text
        self.soundsLike = soundsLike
        self.source = source
        self.sightings = sightings
        self.lastSeenAt = lastSeenAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        soundsLike = try container.decodeIfPresent([String].self, forKey: .soundsLike) ?? []
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .added
        sightings = try container.decodeIfPresent(Int.self, forKey: .sightings) ?? 0
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt) ?? .distantPast
    }

    var key: String { Vocabulary.key(text) }

    func with(source: Source? = nil, sightings: Int? = nil, lastSeenAt: Date? = nil) -> VocabularyTerm {
        VocabularyTerm(
            id: id,
            text: text,
            soundsLike: soundsLike,
            source: source ?? self.source,
            sightings: sightings ?? self.sightings,
            lastSeenAt: lastSeenAt ?? self.lastSeenAt
        )
    }
}

public struct Vocabulary: Codable, Equatable, Sendable {
    public static let engineLimit = 64
    public static let learnedLimit = 200
    public static let forgottenLimit = 500
    public static let maxTermLength = 64
    public static let minTermLength = 3

    public let terms: [VocabularyTerm]
    public let forgotten: [String]

    public static let empty = Vocabulary(terms: [], forgotten: [])

    public init(terms: [VocabularyTerm], forgotten: [String] = []) {
        self.terms = terms
        self.forgotten = forgotten
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terms = try container.decodeIfPresent([VocabularyTerm].self, forKey: .terms) ?? []
        forgotten = try container.decodeIfPresent([String].self, forKey: .forgotten) ?? []
    }

    public var added: [VocabularyTerm] { terms.filter { $0.source == .added } }

    public var learned: [VocabularyTerm] { Self.ranked(terms.filter { $0.source == .learned }) }

    public var boostTerms: [BoostTerm] {
        (added + learned).prefix(Self.engineLimit).map { BoostTerm(text: $0.text, soundsLike: $0.soundsLike) }
    }

    public static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func cleaned(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count >= minTermLength else { return nil }
        return String(words.prefix(maxTermLength))
    }

    public func adding(_ text: String, soundsLike: [String] = [], now: Date = .now) -> Vocabulary {
        guard let text = Self.cleaned(text) else { return self }
        let key = Self.key(text)
        let spellings = soundsLike.compactMap(Self.cleaned).filter { Self.key($0) != key }
        let existing = terms.first { $0.key == key }
        if let existing, existing.source == .added, existing.text == text, existing.soundsLike == spellings {
            return self
        }
        let term = VocabularyTerm(
            id: existing?.id ?? UUID(),
            text: text,
            soundsLike: spellings,
            source: .added,
            sightings: existing?.sightings ?? 0,
            lastSeenAt: now
        )
        let others = terms.filter { $0.key != key }
        return Vocabulary(terms: others + [term], forgotten: forgotten.filter { $0 != key })
    }

    public func removing(_ id: UUID) -> Vocabulary {
        guard let term = terms.first(where: { $0.id == id }) else { return self }
        let remembered = term.source == .learned ? Array((forgotten + [term.key]).suffix(Self.forgottenLimit)) : forgotten
        return Vocabulary(terms: terms.filter { $0.id != id }, forgotten: remembered)
    }

    public func learning(_ sightings: [WordLearner.Sighting], now: Date = .now) -> Vocabulary {
        var byKey = Dictionary(terms.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let blocked = Set(forgotten)
        for sighting in sightings {
            let key = Self.key(sighting.text)
            guard !blocked.contains(key), Self.cleaned(sighting.text) != nil else { continue }
            if let existing = byKey[key] {
                byKey[key] = existing.with(sightings: max(existing.sightings, sighting.count), lastSeenAt: now)
            } else {
                byKey[key] = VocabularyTerm(text: sighting.text, source: .learned, sightings: sighting.count, lastSeenAt: now)
            }
        }
        let keptAdded = terms.compactMap { byKey[$0.key] }.filter { $0.source == .added }
        let allLearned = byKey.values.filter { $0.source == .learned }
        let keptLearned = Self.ranked(allLearned, newestFirst: true).prefix(Self.learnedLimit)
        let originalOrder = Dictionary(terms.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        let learnedInOrder = keptLearned.sorted {
            (originalOrder[$0.key] ?? Int.max, $0.text) < (originalOrder[$1.key] ?? Int.max, $1.text)
        }
        return Vocabulary(terms: keptAdded + learnedInOrder, forgotten: forgotten)
    }

    static func ranked(_ terms: [VocabularyTerm], newestFirst: Bool = false) -> [VocabularyTerm] {
        terms.sorted { left, right in
            if newestFirst, left.lastSeenAt != right.lastSeenAt { return left.lastSeenAt > right.lastSeenAt }
            if left.sightings != right.sightings { return left.sightings > right.sightings }
            if left.lastSeenAt != right.lastSeenAt { return left.lastSeenAt > right.lastSeenAt }
            return left.text < right.text
        }
    }
}
