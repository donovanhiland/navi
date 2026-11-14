import Foundation
import Testing
@testable import NaviDictation

@Suite("Vocabulary")
struct VocabularyTests {
    let day = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("adding a word keeps it and trims spaces")
    func add() {
        let vocabulary = Vocabulary.empty.adding("  Navi   Dev ", now: day)
        #expect(vocabulary.terms.map(\.text) == ["Navi Dev"])
        #expect(vocabulary.terms.first?.source == .added)
    }

    @Test("too short words are ignored and long ones are cut")
    func limits() {
        #expect(Vocabulary.empty.adding("ab").terms.isEmpty)
        let long = String(repeating: "x", count: 100)
        #expect(Vocabulary.empty.adding(long).terms.first?.text.count == Vocabulary.maxTermLength)
    }

    @Test("adding the same word twice keeps one, with the newest spelling")
    func addTwice() {
        let vocabulary = Vocabulary.empty.adding("navi").adding("Navi", soundsLike: ["navy", "Navi"])
        #expect(vocabulary.terms.map(\.text) == ["Navi"])
        #expect(vocabulary.terms.first?.soundsLike == ["navy"])
    }

    @Test("learning adds words not seen before")
    func learn() {
        let vocabulary = Vocabulary.empty.learning([.init(text: "Parakeet", count: 3)], now: day)
        #expect(vocabulary.learned.map(\.text) == ["Parakeet"])
        #expect(vocabulary.learned.first?.sightings == 3)
    }

    @Test("learning never turns an added word into a learned one")
    func learnKeepsAdded() {
        let vocabulary = Vocabulary.empty.adding("Navi", now: day).learning([.init(text: "navi", count: 4)], now: day)
        #expect(vocabulary.terms.count == 1)
        #expect(vocabulary.terms.first?.source == .added)
        #expect(vocabulary.terms.first?.text == "Navi")
        #expect(vocabulary.terms.first?.sightings == 4)
    }

    @Test("learned words stay after they leave the history")
    func learnedWordsStay() {
        let first = Vocabulary.empty.learning([.init(text: "Parakeet", count: 2)], now: day)
        let later = first.learning([.init(text: "FluidAudio", count: 2)], now: day.addingTimeInterval(60))
        #expect(Set(later.learned.map(\.text)) == ["Parakeet", "FluidAudio"])
    }

    @Test("sightings never go down")
    func sightingsKeepMax() {
        let first = Vocabulary.empty.learning([.init(text: "Parakeet", count: 5)], now: day)
        let later = first.learning([.init(text: "Parakeet", count: 2)], now: day)
        #expect(later.learned.first?.sightings == 5)
    }

    @Test("a removed learned word is not learned again")
    func forget() {
        let learned = Vocabulary.empty.learning([.init(text: "Parakeet", count: 2)], now: day)
        let removed = learned.removing(learned.terms[0].id)
        #expect(removed.terms.isEmpty)
        #expect(removed.learning([.init(text: "parakeet", count: 9)], now: day).terms.isEmpty)
    }

    @Test("adding a forgotten word by hand brings it back")
    func addForgotten() {
        let learned = Vocabulary.empty.learning([.init(text: "Parakeet", count: 2)], now: day)
        let removed = learned.removing(learned.terms[0].id).adding("Parakeet")
        #expect(removed.forgotten.isEmpty)
        #expect(removed.added.map(\.text) == ["Parakeet"])
    }

    @Test("removing an added word does not block it from being learned")
    func removeAdded() {
        let added = Vocabulary.empty.adding("Parakeet")
        let removed = added.removing(added.terms[0].id)
        #expect(removed.forgotten.isEmpty)
    }

    @Test("the engine gets added words first, then the most seen learned words, at most 64")
    func boostOrder() {
        let sightings = (0 ..< 100).map { WordLearner.Sighting(text: "Word\(String(format: "%03d", $0))", count: $0 + 2) }
        let vocabulary = Vocabulary.empty.adding("Navi").learning(sightings, now: day)
        let boost = vocabulary.boostTerms
        #expect(boost.count == Vocabulary.engineLimit)
        #expect(boost.first?.text == "Navi")
        #expect(boost[1].text == "Word099")
    }

    @Test("learned words are capped, oldest dropped first")
    func learnedCap() {
        var vocabulary = Vocabulary.empty
        for index in 0 ..< Vocabulary.learnedLimit + 10 {
            let sighting = WordLearner.Sighting(text: "Term\(String(format: "%04d", index))", count: 2)
            vocabulary = vocabulary.learning([sighting], now: day.addingTimeInterval(Double(index)))
        }
        #expect(vocabulary.learned.count == Vocabulary.learnedLimit)
        #expect(!vocabulary.learned.contains { $0.text == "Term0000" })
        #expect(vocabulary.learned.contains { $0.text == "Term0209" })
    }

    @Test("old files without new fields still load")
    func decodesOldFiles() throws {
        let json = #"{"terms":[{"text":"Navi"}]}"#
        let vocabulary = try JSONDecoder().decode(Vocabulary.self, from: Data(json.utf8))
        #expect(vocabulary.terms.first?.text == "Navi")
        #expect(vocabulary.terms.first?.source == .added)
        #expect(vocabulary.forgotten.isEmpty)
    }

    @Test("saves and loads the same list")
    func roundTrip() throws {
        let vocabulary = Vocabulary.empty.adding("Navi", soundsLike: ["navy"], now: day)
            .learning([.init(text: "Parakeet", count: 2)], now: day)
        let data = try JSONEncoder().encode(vocabulary)
        #expect(try JSONDecoder().decode(Vocabulary.self, from: data) == vocabulary)
    }
}
