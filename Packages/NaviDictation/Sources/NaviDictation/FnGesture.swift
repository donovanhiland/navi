import Foundation

public struct FnGesture: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case begin
        case commit
        case cancel
        case lock
    }

    enum Phase: Equatable, Sendable {
        case idle
        case holding(since: TimeInterval)
        case tapped(at: TimeInterval)
        case lockedHeld
        case locked
        case endingLock
        case ignoringUntilUp
    }

    public var holdThreshold: TimeInterval = 0.30
    public var doubleTapWindow: TimeInterval = 0.40

    private(set) var phase: Phase = .idle

    public init() {}

    public var isActive: Bool {
        switch phase {
        case .idle, .ignoringUntilUp: false
        default: true
        }
    }

    public var isLocked: Bool {
        switch phase {
        case .lockedHeld, .locked, .endingLock: true
        default: false
        }
    }

    public mutating func handle(fnDown: Bool, othersHeld: Bool, at time: TimeInterval) -> [Action] {
        var actions: [Action] = []
        if let expired = tick(at: time) { actions.append(expired) }

        switch (phase, fnDown) {
        case (.idle, true):
            if othersHeld {
                phase = .ignoringUntilUp
            } else {
                phase = .holding(since: time)
                actions.append(.begin)
            }
        case let (.holding(since), false):
            if time - since >= holdThreshold {
                phase = .idle
                actions.append(.commit)
            } else {
                phase = .tapped(at: time)
            }
        case (.holding, true):
            if othersHeld {
                phase = .ignoringUntilUp
                actions.append(.cancel)
            }
        case (.tapped, true):
            if othersHeld {
                phase = .ignoringUntilUp
                actions.append(.cancel)
            } else {
                phase = .lockedHeld
                actions.append(.lock)
            }
        case (.lockedHeld, false):
            phase = .locked
        case (.locked, true):
            phase = .endingLock
        case (.endingLock, false):
            phase = .idle
            actions.append(.commit)
        case (.ignoringUntilUp, false):
            phase = .idle
        default:
            break
        }
        return actions
    }

    public mutating func keyPressed() -> [Action] {
        switch phase {
        case .holding:
            phase = .ignoringUntilUp
            return [.cancel]
        case .tapped:
            phase = .idle
            return [.cancel]
        default:
            return []
        }
    }

    public mutating func tick(at time: TimeInterval) -> Action? {
        guard case let .tapped(at) = phase, time - at >= doubleTapWindow else { return nil }
        phase = .idle
        return .cancel
    }

    public var tickDeadline: TimeInterval? {
        guard case let .tapped(at) = phase else { return nil }
        return at + doubleTapWindow
    }

    public mutating func reset() {
        phase = .idle
    }
}
