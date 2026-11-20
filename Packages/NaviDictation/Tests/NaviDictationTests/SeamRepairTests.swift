import Testing
@testable import NaviDictation

@Suite("Seam repair")
struct SeamRepairTests {
    @Test("a phrase repeated where two chunks meet is kept once")
    func repeats() {
        #expect(SeamRepair.collapsingRepeats("the main reason people reason people pay") == "the main reason people pay")
        #expect(SeamRepair.collapsingRepeats("that is the main Is the main reason people pay for the product?") == "that is the main reason people pay for the product?")
    }

    @Test("single repeated words and text without repeats stay as they are")
    func keeps() {
        #expect(SeamRepair.collapsingRepeats("we had had enough") == "we had had enough")
        #expect(SeamRepair.collapsingRepeats("no no, not that one") == "no no, not that one")
        #expect(SeamRepair.collapsingRepeats("ship it on Monday because QA needs time") == "ship it on Monday because QA needs time")
        #expect(SeamRepair.collapsingRepeats("") == "")
    }

    @Test("repeats the speaker meant are kept")
    func meantRepeats() {
        #expect(SeamRepair.collapsingRepeats("I said no way. No way can we ship today.") == "I said no way. No way can we ship today.")
        #expect(SeamRepair.collapsingRepeats("call five five five five one two three") == "call five five five five one two three")
        #expect(SeamRepair.collapsingRepeats("New York, New York is great") == "New York, New York is great")
        #expect(SeamRepair.collapsingRepeats("they pay for it. Pay for it monthly") == "they pay for it. Pay for it monthly")
        #expect(SeamRepair.collapsingRepeats("it went on and on and on") == "it went on and on and on")
        #expect(SeamRepair.collapsingRepeats("bye bye bye bye") == "bye bye bye bye")
        #expect(SeamRepair.collapsingRepeats("go now go now go now go now") == "go now go now go now go now")
        #expect(SeamRepair.collapsingRepeats("I said no way no way no way no way today") == "I said no way no way no way no way today")
        #expect(SeamRepair.collapsingRepeats("one two three one two three") == "one two three one two three")
        #expect(SeamRepair.collapsingRepeats("dial four five four five now") == "dial four five four five now")
        #expect(SeamRepair.collapsingRepeats("I said \"no way.\" No way can we ship today.") == "I said \"no way.\" No way can we ship today.")
    }

    @Test("quotes, brackets and numbers inside a repeat leave it alone")
    func quotesAndNumbers() {
        #expect(SeamRepair.collapsingRepeats("He said \"no way\" no way") == "He said \"no way\" no way")
        #expect(SeamRepair.collapsingRepeats("(we ship) we ship today") == "(we ship) we ship today")
        #expect(SeamRepair.collapsingRepeats("one hundred and one hundred and five") == "one hundred and one hundred and five")
    }

    @Test("the removed copy's punctuation stays")
    func punctuationKept() {
        #expect(SeamRepair.collapsingRepeats("it's fine it's fine, really") == "it's fine, really")
        #expect(SeamRepair.collapsingRepeats("we should ship it we should ship it. Then we rest") == "we should ship it. Then we rest")
    }
}
