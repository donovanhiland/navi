import Testing
@testable import NaviDictation

@Suite("WordLearner")
struct WordLearnerTests {
    let dictionary: Set<String> = ["meeting", "monday", "the", "this", "urgent", "hello", "iphone"]
    func knows(_ word: String) -> Bool { dictionary.contains(word.lowercased()) }

    @Test("names in the middle of a sentence are candidates")
    func midSentenceNames() {
        #expect(WordLearner.candidates(in: "ship it with Donovan and Parakeet today") == ["Donovan", "Parakeet"])
    }

    @Test("the first word of a sentence is not a candidate unless it has inner capitals")
    func sentenceStart() {
        #expect(WordLearner.candidates(in: "Donovan said hi. Parakeet works") == [])
        #expect(WordLearner.candidates(in: "FluidAudio works") == ["FluidAudio"])
    }

    @Test("product spellings are kept: inner capitals, acronyms, iPhone and macOS")
    func productSpellings() {
        let found = WordLearner.candidates(in: "we use PyTorch, NVIDIA, macOS, eBay and TensorRT here")
        #expect(found == ["PyTorch", "NVIDIA", "macOS", "eBay", "TensorRT"])
    }

    @Test("code identifiers and long type names are skipped")
    func codeIdentifiers() {
        #expect(WordLearner.candidates(in: "call isKnownWord or VocabularyBoostingSession now") == [])
    }

    @Test("links, paths, emails and snake case are skipped")
    func linksAndPaths() {
        let text = "see https://Example.com and ~/Library/Navi or kev@Navi.app and some_Thing"
        #expect(WordLearner.candidates(in: text) == [])
    }

    @Test("punctuation and possessives come off")
    func punctuation() {
        #expect(WordLearner.candidates(in: "a note for Donovan's team (Navi).") == ["Donovan", "Navi"])
    }

    @Test("short words and numbers are skipped")
    func shortWords() {
        #expect(WordLearner.candidates(in: "a Kev and M4 and 2026 and API") == [])
    }

    @Test("text that looks like code is skipped whole")
    func codeText() {
        let texts = ["func go() { Parakeet() }", "func go() { Parakeet() }"]
        #expect(WordLearner.sightings(in: texts, isKnownWord: knows).isEmpty)
    }

    @Test("a word must show up in two items, and dictionary words are dropped")
    func sightings() {
        let texts = [
            "ask Donovan about the Monday meeting",
            "then Donovan wants Parakeet on Monday",
            "the Parakeet model is URGENT",
            "only Zephyrine once",
        ]
        let found = WordLearner.sightings(in: texts, isKnownWord: knows)
        #expect(found == [.init(text: "Donovan", count: 2), .init(text: "Parakeet", count: 2)])
    }

    @Test("the most used spelling wins")
    func spelling() {
        let texts = ["use FluidAudio", "use FluidAudio again", "use FLUIDAUDIO"]
        let found = WordLearner.sightings(in: texts, isKnownWord: knows)
        #expect(found == [.init(text: "FluidAudio", count: 3)])
    }
}
