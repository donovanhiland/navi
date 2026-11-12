import Testing
@testable import NaviDictation

@Suite("FnGesture")
struct FnGestureTests {
    @Test("hold then release begins and commits")
    func hold() {
        var gesture = FnGesture()
        #expect(gesture.handle(fnDown: true, othersHeld: false, at: 1.0) == [.begin])
        #expect(gesture.isActive)
        #expect(gesture.handle(fnDown: false, othersHeld: false, at: 2.0) == [.commit])
        #expect(!gesture.isActive)
    }

    @Test("double tap locks, and a later tap commits on release")
    func doubleTapLock() {
        var gesture = FnGesture()
        #expect(gesture.handle(fnDown: true, othersHeld: false, at: 1.00) == [.begin])
        #expect(gesture.handle(fnDown: false, othersHeld: false, at: 1.10).isEmpty)
        #expect(gesture.handle(fnDown: true, othersHeld: false, at: 1.30) == [.lock])
        #expect(gesture.isLocked)
        #expect(gesture.handle(fnDown: false, othersHeld: false, at: 1.40).isEmpty)
        #expect(gesture.isLocked)
        #expect(gesture.handle(fnDown: true, othersHeld: false, at: 5.0).isEmpty)
        #expect(gesture.handle(fnDown: false, othersHeld: false, at: 5.1) == [.commit])
        #expect(!gesture.isActive)
        #expect(!gesture.isLocked)
    }

    @Test("a lone short tap is cancelled after the double-tap window")
    func loneTap() {
        var gesture = FnGesture()
        _ = gesture.handle(fnDown: true, othersHeld: false, at: 1.0)
        _ = gesture.handle(fnDown: false, othersHeld: false, at: 1.1)
        #expect(gesture.tickDeadline == 1.1 + gesture.doubleTapWindow)
        #expect(gesture.tick(at: 1.3) == nil)
        #expect(gesture.tick(at: 1.6) == .cancel)
        #expect(!gesture.isActive)
        #expect(gesture.tickDeadline == nil)
    }

    @Test("a second press after the window starts a new session")
    func lateSecondTap() {
        var gesture = FnGesture()
        _ = gesture.handle(fnDown: true, othersHeld: false, at: 1.0)
        _ = gesture.handle(fnDown: false, othersHeld: false, at: 1.1)
        #expect(gesture.handle(fnDown: true, othersHeld: false, at: 3.0) == [.cancel, .begin])
    }

    @Test("fn with another modifier does not start")
    func modifierBlocksStart() {
        var gesture = FnGesture()
        #expect(gesture.handle(fnDown: true, othersHeld: true, at: 1.0).isEmpty)
        #expect(!gesture.isActive)
        #expect(gesture.handle(fnDown: false, othersHeld: false, at: 1.5).isEmpty)
        #expect(gesture.handle(fnDown: true, othersHeld: false, at: 2.0) == [.begin])
    }

    @Test("a modifier pressed while holding cancels, and release does nothing")
    func modifierCancels() {
        var gesture = FnGesture()
        _ = gesture.handle(fnDown: true, othersHeld: false, at: 1.0)
        #expect(gesture.handle(fnDown: true, othersHeld: true, at: 1.5) == [.cancel])
        #expect(gesture.handle(fnDown: false, othersHeld: false, at: 2.0).isEmpty)
        #expect(!gesture.isActive)
    }

    @Test("a hold just under the threshold counts as a tap")
    func thresholdEdge() {
        var gesture = FnGesture()
        _ = gesture.handle(fnDown: true, othersHeld: false, at: 1.0)
        #expect(gesture.handle(fnDown: false, othersHeld: false, at: 1.29).isEmpty)
        var other = FnGesture()
        _ = other.handle(fnDown: true, othersHeld: false, at: 1.0)
        #expect(other.handle(fnDown: false, othersHeld: false, at: 1.31) == [.commit])
    }

    @Test("fn with another key, like fn+delete, cancels and waits for fn up")
    func keyChordCancels() {
        var gesture = FnGesture()
        #expect(gesture.handle(fnDown: true, othersHeld: false, at: 1.0) == [.begin])
        #expect(gesture.keyPressed() == [.cancel])
        #expect(!gesture.isActive)
        #expect(gesture.handle(fnDown: false, othersHeld: false, at: 1.5).isEmpty)
        #expect(gesture.handle(fnDown: true, othersHeld: false, at: 3.0) == [.begin])
    }

    @Test("typing while locked does not end the lock")
    func typingWhileLocked() {
        var gesture = FnGesture()
        _ = gesture.handle(fnDown: true, othersHeld: false, at: 1.00)
        _ = gesture.handle(fnDown: false, othersHeld: false, at: 1.10)
        _ = gesture.handle(fnDown: true, othersHeld: false, at: 1.30)
        _ = gesture.handle(fnDown: false, othersHeld: false, at: 1.40)
        #expect(gesture.keyPressed().isEmpty)
        #expect(gesture.isLocked)
    }
}
