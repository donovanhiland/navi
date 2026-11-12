import Testing

@testable import NaviCapture

@MainActor
struct TooltipTests {
    @Test func firstTipWaitsBeforeShowing() {
        let tips = TooltipCenter()
        tips.hover("arrow", inside: true)
        #expect(tips.activeID == nil)
    }

    @Test func firstTipShowsAfterTheDelay() async {
        let tips = TooltipCenter()
        tips.hover("arrow", inside: true)
        #expect(await eventually { tips.activeID == "arrow" })
    }

    @Test func movingToTheNextButtonSwitchesAtOnce() {
        let tips = TooltipCenter(activeID: "arrow")
        tips.hover("arrow", inside: false)
        tips.hover("rectangle", inside: true)
        #expect(tips.activeID == "rectangle")
    }

    @Test func aLateLeaveFromTheOldButtonKeepsTheNewTip() async throws {
        let tips = TooltipCenter(activeID: "rectangle")
        tips.hover("arrow", inside: false)
        try await Task.sleep(for: TooltipCenter.hideDelay + .milliseconds(100))
        #expect(tips.activeID == "rectangle")
    }

    @Test func leavingHidesTheTip() async {
        let tips = TooltipCenter(activeID: "arrow")
        tips.hover("arrow", inside: false)
        #expect(tips.activeID == "arrow")
        #expect(await eventually { tips.activeID == nil })
    }

    @Test func aClickHidesTheTipAtOnce() {
        let tips = TooltipCenter(activeID: "arrow")
        tips.dismiss()
        #expect(tips.activeID == nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
