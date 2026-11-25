import Foundation
import Testing

@testable import NaviCapture

@MainActor
@Suite struct FocusHandoffTests {
    private let navi: pid_t = 1

    @Test func keepsThePreviousAppWhenItHasAWindowHere() {
        let windows = [
            SpaceWindow(pid: 7, layer: 0, alpha: 1),
            SpaceWindow(pid: 3, layer: 0, alpha: 1),
        ]
        #expect(FocusHandoff.pick(previous: 3, own: navi, windows: windows) == 3)
    }

    @Test func picksTheTopWindowHereWhenThePreviousAppIsOnAnotherSpace() {
        let windows = [
            SpaceWindow(pid: 9, layer: 25, alpha: 1),
            SpaceWindow(pid: navi, layer: 0, alpha: 1),
            SpaceWindow(pid: 7, layer: 0, alpha: 0),
            SpaceWindow(pid: 5, layer: 0, alpha: 1),
            SpaceWindow(pid: 4, layer: 0, alpha: 1),
        ]
        #expect(FocusHandoff.pick(previous: 3, own: navi, windows: windows) == 5)
    }

    @Test func picksNothingOnAnEmptySpace() {
        let windows = [
            SpaceWindow(pid: 9, layer: 25, alpha: 1),
            SpaceWindow(pid: navi, layer: 0, alpha: 1),
        ]
        #expect(FocusHandoff.pick(previous: 3, own: navi, windows: windows) == nil)
    }

    @Test func neverPicksNaviItself() {
        let windows = [SpaceWindow(pid: navi, layer: 0, alpha: 1)]
        #expect(FocusHandoff.pick(previous: navi, own: navi, windows: windows) == nil)
    }
}
