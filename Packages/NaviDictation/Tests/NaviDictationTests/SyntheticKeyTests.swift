import CoreGraphics
import Testing
@testable import NaviDictation

@Suite("Synthetic keys")
struct SyntheticKeyTests {
    @Test("Navi's own paste is recognized, other keys are not")
    func marker() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        #expect(!SyntheticKey.isNavi(userData: event.getIntegerValueField(.eventSourceUserData)))
        SyntheticKey.mark(event)
        #expect(SyntheticKey.isNavi(userData: event.getIntegerValueField(.eventSourceUserData)))
        #expect(!SyntheticKey.isNavi(userData: nil))
        #expect(SyntheticKey.isNavi(userData: 0, processID: Int64(getpid())))
        #expect(!SyntheticKey.isNavi(userData: 0, processID: 1))
    }
}
