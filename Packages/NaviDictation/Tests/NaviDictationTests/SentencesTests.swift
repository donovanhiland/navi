import Testing
@testable import NaviDictation

struct SentencesTests {
    @Test func splitsAfterEndMarks() {
        #expect(Sentences.split("Hi there. How are you? Great!") == ["Hi there.", "How are you?", "Great!"])
        #expect(Sentences.split("no end mark at all") == ["no end mark at all"])
        #expect(Sentences.split("") == [])
    }

    @Test func keepsDotsInsideWordsAndAbbreviations() {
        #expect(Sentences.split("Go to example.com now. Then 3.5 percent.") == ["Go to example.com now.", "Then 3.5 percent."])
        #expect(Sentences.split("Bring snacks, e.g. chips. Done.") == ["Bring snacks, e.g. chips.", "Done."])
    }

    @Test func joinsWithSpacesButNotAfterLineBreaks() {
        #expect(Sentences.join(["One.", "Two."]) == "One. Two.")
        #expect(Sentences.join(["To do:\n1. Call mom\n", "Then rest."]) == "To do:\n1. Call mom\nThen rest.")
        #expect(Sentences.join(["One.", "", "Two."]) == "One. Two.")
    }

    private func token(_ text: String, _ start: Double, _ end: Double) -> Sentences.Token {
        Sentences.Token(text: text, start: start, end: end)
    }

    @Test func endSpansCoverTheEndMarkAndTheNextWordStart() throws {
        let tokens = [
            token(" Ship", 0.0, 0.3), token(" it", 0.3, 0.5), token(".", 0.5, 0.9),
            token(" Then", 0.9, 1.1), token(" rest", 1.1, 1.4),
        ]
        let spans = try #require(Sentences.endSpans(text: "Ship it. Then rest", tokens: tokens))
        #expect(spans.count == 1)
        #expect(abs(spans[0].lowerBound - 0.3) < 1e-9)
        #expect(abs(spans[0].upperBound - 0.98) < 1e-9)
    }

    @Test func tokensThatDoNotMatchTheTextGiveNothing() {
        let tokens = [token(" A", 0, 0.2), token(".", 0.2, 0.3), token(" B", 1, 1.3)]
        #expect(Sentences.endSpans(text: "A. B. C", tokens: tokens) == nil)
    }

    @Test func aDotInsideAWordIsNotASentenceEnd() throws {
        let tokens = [
            token(" example", 0, 0.3), token(".", 0.3, 0.35), token("com", 0.35, 0.6),
            token(" works", 0.6, 0.9), token(".", 0.9, 1.2), token(" Yes", 1.2, 1.5),
        ]
        let spans = try #require(Sentences.endSpans(text: "example.com works. Yes", tokens: tokens))
        #expect(spans.count == 1)
        #expect(abs(spans[0].lowerBound - 0.7) < 1e-9)
    }
}

struct LiveCutTests {
    private func audio(seconds: Double, loud: [ClosedRange<Double>]) -> [Float] {
        (0 ..< Int(seconds * 16000)).map { index in
            let time = Double(index) / 16000
            return loud.contains { $0.contains(time) } ? (index % 2 == 0 ? 0.3 : -0.3) : 0.001
        }
    }

    private func token(_ text: String, _ start: Double, _ end: Double) -> Sentences.Token {
        Sentences.Token(text: text, start: start, end: end)
    }

    @Test func cutsInTheSilenceAfterAFinishedSentence() throws {
        let samples = audio(seconds: 1.5, loud: [0 ... 0.5, 0.9 ... 1.5])
        let tokens = [
            token(" Ship", 0, 0.3), token(" it", 0.3, 0.5), token(".", 0.5, 0.9),
            token(" Then", 0.9, 1.1), token(" rest", 1.1, 1.4),
        ]
        let done = try #require(LiveDictation.finishedSentences(in: samples, after: 0, text: "Ship it. Then rest", tokens: tokens))
        #expect(done.sentences == ["Ship it."])
        #expect((Int(0.5 * 16000) ... Int(0.9 * 16000)).contains(done.cut))
    }

    @Test func noCutWithoutARealPause() {
        let samples = audio(seconds: 1.5, loud: [0 ... 1.5])
        let tokens = [
            token(" Ship", 0, 0.3), token(" it", 0.3, 0.5), token(".", 0.5, 0.6),
            token(" Then", 0.6, 1.1), token(" rest", 1.1, 1.4),
        ]
        #expect(LiveDictation.finishedSentences(in: samples, after: 0, text: "Ship it. Then rest", tokens: tokens) == nil)
    }

    @Test func timesCountFromTheLastCut() throws {
        let samples = audio(seconds: 2.5, loud: [0 ... 0.9, 1.0 ... 1.5, 1.9 ... 2.5])
        let tokens = [
            token(" Ship", 0, 0.3), token(" it", 0.3, 0.5), token(".", 0.5, 0.9),
            token(" Then", 0.9, 1.1), token(" rest", 1.1, 1.4),
        ]
        let done = try #require(LiveDictation.finishedSentences(in: samples, after: 16000, text: "Ship it. Then rest", tokens: tokens))
        #expect((Int(1.5 * 16000) ... Int(1.9 * 16000)).contains(done.cut))
    }
}

struct TailTests {
    @Test func shortWaitWhenTheUserStoppedBeforeTheRelease() {
        #expect(!Microphone.tailIsDone(sinceRelease: .milliseconds(20), sinceSound: .milliseconds(500)))
        #expect(Microphone.tailIsDone(sinceRelease: .milliseconds(40), sinceSound: .milliseconds(500)))
        #expect(Microphone.tailIsDone(sinceRelease: .milliseconds(40), sinceSound: nil))
    }

    @Test func waitsForQuietWhileSpeechGoesOn() {
        #expect(!Microphone.tailIsDone(sinceRelease: .milliseconds(100), sinceSound: .milliseconds(50)))
        #expect(!Microphone.tailIsDone(sinceRelease: .milliseconds(300), sinceSound: .milliseconds(200)))
        #expect(Microphone.tailIsDone(sinceRelease: .milliseconds(400), sinceSound: .milliseconds(300)))
        #expect(Microphone.tailIsDone(sinceRelease: .milliseconds(600), sinceSound: .zero))
    }
}

struct SoundGateTests {
    private func sound(_ gate: inout SoundGate, _ decibels: Float) -> Bool {
        gate.isSound(decibels: decibels)
    }

    @Test func talkingFromTheFirstMomentStillCountsAsSound() {
        var gate = SoundGate()
        #expect(sound(&gate, -25) == true)
        #expect(sound(&gate, -27) == true)
    }

    @Test func softSpeechInAQuietRoomCountsAsSound() {
        var gate = SoundGate()
        _ = gate.isSound(decibels: -58)
        #expect(sound(&gate, -44) == true)
        #expect(sound(&gate, -50) == false)
    }

    @Test func digitalSilenceDoesNotMakeRoomNoiseLookLikeSpeech() {
        var gate = SoundGate()
        _ = gate.isSound(decibels: -120)
        #expect(sound(&gate, -52) == false)
    }

    @Test func speechWithinTheQuietTimeBeforeTheReleaseNeedsTheLongerQuiet() {
        #expect(!Microphone.tailIsDone(sinceRelease: .milliseconds(100), sinceSound: .milliseconds(250)))
        #expect(Microphone.tailIsDone(sinceRelease: .milliseconds(150), sinceSound: .milliseconds(300)))
    }
}

struct CleanupGateTests {
    @Test func cleanSentencesSkipTheModel() {
        #expect(!TextCleaner.needsModel("Can you send me the deck before the meeting tomorrow?"))
        #expect(!TextCleaner.needsModel("The server is down."))
    }

    @Test func messySentencesUseTheModel() {
        #expect(TextCleaner.needsModel("Let's meet at 2 actually 3."))
        #expect(TextCleaner.needsModel("Can you can you check the logs."))
        #expect(TextCleaner.needsModel("It was it was a long day."))
        #expect(TextCleaner.needsModel("To do number one call mom number two pay rent."))
        #expect(TextCleaner.needsModel("Open the file app delegate dot swift."))
        #expect(TextCleaner.needsModel("So we should probably move the launch to next week because the payments thing is not done yet."))
    }
}
