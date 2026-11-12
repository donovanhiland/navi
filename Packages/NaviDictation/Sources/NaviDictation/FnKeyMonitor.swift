import AppKit

@MainActor
final class FnKeyMonitor {
    private var gesture = FnGesture()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var tickTask: Task<Void, Never>?
    private let onAction: @MainActor (FnGesture.Action) -> Void

    init(onAction: @escaping @MainActor (FnGesture.Action) -> Void) {
        self.onAction = onAction
    }

    var isRunning: Bool { globalMonitor != nil }
    var isLocked: Bool { gesture.isLocked }

    func start() {
        guard globalMonitor == nil else { return }
        let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let fnDown = event.modifierFlags.contains(.function)
            let othersHeld = !event.modifierFlags.intersection(others).isEmpty
            let time = event.timestamp
            MainActor.assumeIsolated { self?.flagsChanged(fnDown: fnDown, othersHeld: othersHeld, at: time) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let fnDown = event.modifierFlags.contains(.function)
            let othersHeld = !event.modifierFlags.intersection(others).isEmpty
            let time = event.timestamp
            MainActor.assumeIsolated { self?.flagsChanged(fnDown: fnDown, othersHeld: othersHeld, at: time) }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyPressed() }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.keyPressed() }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalMonitor = nil
        localMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        tickTask?.cancel()
        tickTask = nil
        gesture.reset()
    }

    func reset() {
        tickTask?.cancel()
        tickTask = nil
        gesture.reset()
    }

    private func keyPressed() {
        let actions = gesture.keyPressed()
        guard !actions.isEmpty else { return }
        scheduleTick()
        for action in actions { onAction(action) }
    }

    private func flagsChanged(fnDown: Bool, othersHeld: Bool, at time: TimeInterval) {
        let actions = gesture.handle(fnDown: fnDown, othersHeld: othersHeld, at: time)
        scheduleTick()
        for action in actions { onAction(action) }
    }

    private func scheduleTick() {
        tickTask?.cancel()
        tickTask = nil
        guard let deadline = gesture.tickDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay) + .milliseconds(10))
            guard !Task.isCancelled, let self else { return }
            if let action = gesture.tick(at: ProcessInfo.processInfo.systemUptime) { onAction(action) }
        }
    }
}
