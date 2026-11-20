import Testing
@testable import NaviDictation

@Suite("TextCleanup")
struct TextCleanupTests {
    @Test("removes um and uh with their commas")
    func removesSounds() {
        #expect(TextCleanup.clean("um I think we should go") == "I think we should go.")
        #expect(TextCleanup.clean("Uh, I think we should go") == "I think we should go.")
        #expect(TextCleanup.clean("we should, um, go there today") == "We should go there today.")
        #expect(TextCleanup.clean("we should um go there today") == "We should go there today.")
        #expect(TextCleanup.clean("Hmm, that works for me") == "That works for me.")
    }

    @Test("removes like and you know only when they are filler")
    func removesWordFillers() {
        #expect(TextCleanup.clean("it was, like, really big") == "It was really big.")
        #expect(TextCleanup.clean("Like, I do not know what to do") == "I do not know what to do.")
        #expect(TextCleanup.clean("I was, you know, tired all day") == "I was tired all day.")
        #expect(TextCleanup.clean("We stopped. You know, it was late") == "We stopped. It was late.")
    }

    @Test("keeps real uses of like and you know")
    func keepsRealWords() {
        #expect(TextCleanup.clean("I like pizza a lot") == "I like pizza a lot.")
        #expect(TextCleanup.clean("it looks like rain today") == "It looks like rain today.")
        #expect(TextCleanup.clean("do you know the way") == "Do you know the way.")
        #expect(TextCleanup.clean("Do you know where it is?") == "Do you know where it is?")
    }

    @Test("does not touch words that only contain a filler")
    func keepsWordsWithFillerInside() {
        #expect(TextCleanup.clean("the umbrella is under the umpire seat") == "The umbrella is under the umpire seat.")
        #expect(TextCleanup.clean("her answer was clear") == "Her answer was clear.")
    }

    @Test("removes stuttered small words")
    func removesStutters() {
        #expect(TextCleanup.clean("I I think the the plan is good") == "I think the plan is good.")
        #expect(TextCleanup.clean("that that is fine with me") == "That that is fine with me.")
    }

    @Test("fixes spacing and punctuation")
    func fixesSpacing() {
        #expect(TextCleanup.clean("hello   there , how are you ?") == "Hello there, how are you?")
        #expect(TextCleanup.clean(", leading comma here today") == "Leading comma here today.")
    }

    @Test("capitalizes sentences and the word I")
    func capitalizes() {
        #expect(TextCleanup.clean("i think i'm ready. i'll go. what about you? fine") == "I think I'm ready. I'll go. What about you? Fine.")
        #expect(TextCleanup.clean("we met on tuesday. it went well") == "We met on tuesday. It went well.")
    }

    @Test("does not capitalize after a dot inside a word, a number, or an abbreviation")
    func keepsDotsInside() {
        #expect(TextCleanup.clean("visit example.com for details") == "Visit example.com for details.")
        #expect(TextCleanup.clean("it costs 3.5 dollars per unit") == "It costs 3.5 dollars per unit.")
        #expect(TextCleanup.clean("use it, i.e. the first one") == "Use it, i.e. the first one.")
        #expect(TextCleanup.clean("pick one, e.g. the red one") == "Pick one, e.g. the red one.")
    }

    @Test("adds a final period only to longer text without end punctuation")
    func finalPeriod() {
        #expect(TextCleanup.clean("yes") == "Yes")
        #expect(TextCleanup.clean("sounds good to me") == "Sounds good to me.")
        #expect(TextCleanup.clean("sounds good to me!") == "Sounds good to me!")
        #expect(TextCleanup.clean("sounds good to me", addsFinalPeriod: false) == "Sounds good to me")
    }

    @Test("empty and filler-only input gives empty text")
    func emptyInput() {
        #expect(TextCleanup.clean("") == "")
        #expect(TextCleanup.clean("   \n ") == "")
        #expect(TextCleanup.clean("um, uh") == "")
    }

    @Test("model answers that are empty or far off in length are rejected")
    func plausibility() {
        let basic = "Please send me the report by Friday."
        #expect(TextCleaner.isPlausible("Please send me the report by Friday.", comparedTo: basic))
        #expect(!TextCleaner.isPlausible("", comparedTo: basic))
        #expect(!TextCleaner.isPlausible("Sure! Here is a long answer about reports and why Friday matters for every team.", comparedTo: basic))
        #expect(!TextCleaner.isPlausible("Report.", comparedTo: basic))
    }

    @Test("model answers with words the speaker never said are rejected")
    func newWords() {
        let basic = "I think we should ship the new build on Monday because QA needs two more days."
        #expect(TextCleaner.isPlausible("I think we should ship the new build on Monday, because QA needs two more days.", comparedTo: basic))
        #expect(TextCleaner.isPlausible("We should ship the new build on Monday because QA needs two more days.", comparedTo: basic))
        #expect(!TextCleaner.isPlausible("I believe we ought to release the latest version on Monday since testers want extra days.", comparedTo: basic))
    }
}
