import AppKit
import Carbon.HIToolbox
import NaviCore
import SwiftUI

enum HistoryShortcutChange: Equatable {
    case applied
    case invalid(KeyComboError)
    case refused

    var message: String? {
        switch self {
        case .applied: nil
        case .invalid(.needsModifier), .invalid(.shiftOnly): "Use ⌘, ⌥ or ⌃ in the shortcut."
        case let .invalid(.inUse(name)): "Navi already uses this for \(name)."
        case .refused: "macOS or another app already uses this shortcut."
        }
    }
}

@Observable
@MainActor
final class RecorderState {
    var current: KeyCombo = .defaultHistory
    var message: String?
    var held: UInt32 = 0
    var accepted: KeyCombo?
    var shakes = 0
}

private let modifierSymbols: [(bit: UInt32, symbol: String)] = [
    (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘"),
]

private struct Keycap: View {
    let text: String?
    var tint: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Text(text ?? "")
            .font(.system(size: 20, weight: .medium, design: .rounded))
            .foregroundStyle(tint ?? .primary)
            .frame(minWidth: 40, minHeight: 40)
            .padding(.horizontal, text.map { $0.count > 2 ? 8 : 0 } ?? 0)
            .background(shape.fill((tint ?? .primary).opacity(tint == nil ? 0.07 : 0.16)))
            .overlay(shape.strokeBorder((tint ?? .primary).opacity(text == nil ? 0.15 : 0.25),
                                        style: StrokeStyle(lineWidth: 0.5, dash: text == nil ? [3, 3] : [])))
    }
}

private struct ShortcutField: View {
    let state: RecorderState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 8) {
            HStack(spacing: 6) { caps }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(shape.fill(.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(ringColor.opacity(state.accepted == nil && !reduceMotion && pulse ? 0.35 : 1), lineWidth: 2))
        .modifier(Shake(trigger: state.shakes, enabled: !reduceMotion))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var ringColor: Color { state.message != nil ? .red : .accentColor }

    private var caption: String {
        if state.accepted != nil { return "Saved" }
        return state.held == 0 ? "Type a new shortcut" : "Now press a key"
    }

    @ViewBuilder private var caps: some View {
        if let accepted = state.accepted {
            ForEach(Self.parts(accepted), id: \.self) { Keycap(text: $0, tint: .accentColor) }
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 4)
        } else if state.held != 0 {
            ForEach(Self.symbols(state.held), id: \.self) { Keycap(text: $0) }
            Keycap(text: nil)
        } else {
            ForEach(Self.parts(state.current), id: \.self) { Keycap(text: $0) }.opacity(0.45)
        }
    }

    private static func symbols(_ modifiers: UInt32) -> [String] {
        modifierSymbols.filter { modifiers & $0.bit != 0 }.map(\.symbol)
    }

    private static func parts(_ combo: KeyCombo) -> [String] {
        symbols(combo.modifiers) + [combo.keyName]
    }
}

private struct Shake: ViewModifier {
    let trigger: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, offset in
                view.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    for target in [-8.0, 8.0, -6.0, 6.0, -3.0, 0.0] { LinearKeyframe(target, duration: 0.06) }
                }
            }
        } else {
            content
        }
    }
}

private struct RecorderView: View {
    let state: RecorderState
    let onReset: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Label("History shortcut", systemImage: "keyboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ShortcutField(state: state)
            errorRow
            HStack {
                Button("Reset to Default", action: onReset)
                    .buttonStyle(.link)
                    .disabled(state.current == .defaultHistory || state.accepted != nil)
                Spacer()
                Button(action: onCancel) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        Text("esc")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)))
                    }
                }
                .buttonStyle(.plain)
                .disabled(state.accepted != nil)
            }
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 360)
    }

    private var errorRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let message = state.message {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.red)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
    }
}

private final class RecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HistoryShortcutRecorder: NSObject, NSWindowDelegate {
    private let apply: (KeyCombo) -> HistoryShortcutChange
    private let onClose: () -> Void
    private let state = RecorderState()
    private var panel: NSPanel?
    private var monitor: Any?
    private var closing = false

    init(apply: @escaping (KeyCombo) -> HistoryShortcutChange, onClose: @escaping () -> Void) {
        self.apply = apply
        self.onClose = onClose
    }

    func show(current: KeyCombo) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        state.current = current
        state.message = nil
        state.held = 0
        state.accepted = nil
        closing = false
        let hosting = NSHostingView(rootView: RecorderView(
            state: state,
            onReset: { [weak self] in self?.attempt(.defaultHistory) },
            onCancel: { [weak self] in self?.finish() }
        ))
        let size = hosting.fittingSize
        let container = NaviPanelBackground.make(cornerRadius: 12)
        container.frame = CGRect(origin: .zero, size: size)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        let panel = RecorderPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard !closing else { return true }
        if event.type == .flagsChanged {
            let held = KeyCombo.from(keyCode: 0, cocoaFlags: event.modifierFlags).modifiers
            if held & ~state.held != 0 { state.message = nil }
            state.held = held
            return false
        }
        if event.keyCode == UInt16(kVK_Escape) {
            finish()
        } else {
            attempt(KeyCombo.from(keyCode: event.keyCode, cocoaFlags: event.modifierFlags))
        }
        return true
    }

    private func attempt(_ combo: KeyCombo) {
        let change = apply(combo)
        if change == .applied {
            closing = true
            state.message = nil
            state.accepted = combo
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.finish(fade: true)
            }
        } else {
            state.message = change.message
            state.shakes += 1
        }
    }

    private func finish(fade: Bool = false) {
        guard let panel else { return }
        self.panel = nil
        closing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.delegate = nil
        onClose()
        if fade, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in panel.close() }
            }
        } else {
            panel.close()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        finish()
    }
}
