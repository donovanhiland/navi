import Testing
@testable import NaviDictation

@Suite("LiveText")
struct LiveTextTests {
    @Test("short audio is read whole and not clipped")
    func shortAudio() {
        let start = LiveText.tailStart(frameCounts: [100, 100, 100], sampleRate: 100, window: 10)
        #expect(start.index == 0)
        #expect(!start.clipped)
    }

    @Test("long audio keeps only the newest window")
    func longAudio() {
        let start = LiveText.tailStart(frameCounts: Array(repeating: 100, count: 20), sampleRate: 100, window: 5)
        #expect(start.index == 15)
        #expect(start.clipped)
    }

    @Test("audio exactly one window long is not clipped")
    func exactWindow() {
        let start = LiveText.tailStart(frameCounts: [250, 250], sampleRate: 100, window: 5)
        #expect(start.index == 0)
        #expect(!start.clipped)
    }

    @Test("no buffers or no sample rate reads from the start")
    func empty() {
        #expect(LiveText.tailStart(frameCounts: [], sampleRate: 100, window: 5).index == 0)
        #expect(LiveText.tailStart(frameCounts: [100], sampleRate: 0, window: 5).index == 0)
    }

    @Test("clipped text drops the first word, which may be cut")
    func trimmed() {
        #expect(LiveText.trimmed("lo there friend", clipped: true) == "there friend")
        #expect(LiveText.trimmed(" hello there ", clipped: false) == "hello there")
        #expect(LiveText.trimmed("hello", clipped: true) == "")
    }

    @Test("finished segments come before the current guess")
    func combine() {
        #expect(LiveText.combine(finished: ["Hello there.", " How are"], volatile: "you doing ") == "Hello there. How are you doing")
        #expect(LiveText.combine(finished: [], volatile: "") == "")
        #expect(LiveText.combine(finished: ["One."], volatile: "") == "One.")
    }

    @Test("buffers of different sample rates count by their length in seconds")
    func mixedRates() {
        let start = LiveText.tailStart(durations: [1, 1, 1, 1, 1, 1], window: 3)
        #expect(start.index == 3)
        #expect(start.clipped)
    }
    @Test("only words two previews agree on are shown")
    func stable() {
        #expect(LiveText.stable(previous: "ship it on Mund", current: "ship it on Monday bec") == "ship it on")
        #expect(LiveText.stable(previous: "ship it on Monday bec", current: "ship it on Monday, because QA") == "ship it on Monday,")
        #expect(LiveText.stable(previous: "", current: "hello there") == "")
        #expect(LiveText.stable(previous: "hello", current: "Hello there") == "Hello")
    }
    @Test("agreement still works when the window slides and old words fall off the front")
    func stableSlidingWindow() {
        let previous = "the launch to Monday because QA needs two"
        let current = "Monday because QA needs two more days and"
        #expect(LiveText.stable(previous: previous, current: current) == "Monday because QA needs two")
    }
    @Test("words before the agreed part that the last read did not have are not shown")
    func stableOnlyAgreedRun() {
        #expect(LiveText.stable(previous: "please keep the report", current: "invented words keep the report") == "keep the report")
        #expect(LiveText.stable(previous: "so I think so I think", current: "so I think so I think so yes") == "so I think so")
    }
    @Test("words that only guess the end of the phrase are held back")
    func stableDropsInvented() {
        let previous = "first we need to get the"
        let current = "first we need to finish the report"
        #expect(LiveText.stable(previous: previous, current: current) == "first we need to")
    }
}
