import AppKit
import Carbon.HIToolbox
import NaviCore

@MainActor
final class FnKeyMonitor {
    private var gesture = FnGesture()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var tickTask: Task<Void, Never>?
    private let onAction: @MainActor (FnGesture.Action) -> Void
    private let onIdleEscape: @MainActor () -> Void

    init(
        onAction: @escaping @MainActor (FnGesture.Action) -> Void,
        onIdleEscape: @escaping @MainActor () -> Void
    ) {
        self.onAction = onAction
        self.onIdleEscape = onIdleEscape
    }

    private(set) var isRunning = false
    private var shortcutHotKey: HotKey?
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var isLocked: Bool { gesture.isLocked }

    var tapToggles: Bool {
        get { gesture.tapToggles }
        set { gesture.tapToggles = newValue }
    }

    var trigger: DictationTrigger = .standard

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        isRunning = true
        if let combo = trigger.shortcut {
            shortcutHotKey = HotKey(
                keyCode: combo.keyCode, modifiers: combo.modifiers,
                action: { [weak self] in self?.triggerChanged(down: true, othersHeld: false, at: Self.now) },
                onRelease: { [weak self] in self?.triggerChanged(down: false, othersHeld: false, at: Self.now) }
            )
        } else {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let flags = event.modifierFlags.rawValue
                let time = event.timestamp
                MainActor.assumeIsolated { self?.flagsChanged(flags: flags, at: time) }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let flags = event.modifierFlags.rawValue
                let time = event.timestamp
                MainActor.assumeIsolated { self?.flagsChanged(flags: flags, at: time) }
                return event
            }
        }
        if trigger.shortcut != nil, shortcutHotKey == nil {
            stop()
            return false
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !SyntheticKey.isNavi(event.cgEvent) else { return }
            let combo = KeyCombo.from(keyCode: event.keyCode, cocoaFlags: event.modifierFlags)
            MainActor.assumeIsolated { self?.keyPressed(combo) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !SyntheticKey.isNavi(event.cgEvent) else { return event }
            let combo = KeyCombo.from(keyCode: event.keyCode, cocoaFlags: event.modifierFlags)
            MainActor.assumeIsolated { self?.keyPressed(combo) }
            return event
        }
        return true
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        shortcutHotKey?.unregister()
        shortcutHotKey = nil
        isRunning = false
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

    private func keyPressed(_ combo: KeyCombo) {
        if combo.keyCode == UInt32(kVK_Escape) {
            escapePressed()
            return
        }
        if combo == trigger.shortcut { return }
        let actions = gesture.keyPressed()
        guard !actions.isEmpty else { return }
        scheduleTick()
        for action in actions { onAction(action) }
    }

    private func escapePressed() {
        let actions = gesture.escapePressed()
        guard !actions.isEmpty else {
            onIdleEscape()
            return
        }
        scheduleTick()
        for action in actions { onAction(action) }
    }

    private func flagsChanged(flags: UInt, at time: TimeInterval) {
        guard let state = trigger.state(flags: flags) else { return }
        triggerChanged(down: state.down, othersHeld: state.othersHeld, at: time)
    }

    private func triggerChanged(down: Bool, othersHeld: Bool, at time: TimeInterval) {
        let actions = gesture.handle(fnDown: down, othersHeld: othersHeld, at: time)
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
