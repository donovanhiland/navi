import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PillModel {
    enum Phase: Equatable {
        case listening
        case thinking
    }

    static let barCount = 22

    var phase: Phase = .listening
    var isLocked = false
    var levels: [Float] = Array(repeating: 0, count: PillModel.barCount)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        phase = .listening
        isLocked = false
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

private struct PillView: View {
    static let panelSize = NSSize(width: 240, height: 60)
    let model: PillModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .listening:
                if model.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Waveform(levels: model.levels)
            case .thinking:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                Text("Thinking…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .frame(width: PillView.panelSize.width, height: PillView.panelSize.height)
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 3 + CGFloat(level) * 19)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityHidden(true)
    }
}

@MainActor
final class DictationPill {
    let model = PillModel()
    private var panel: NSPanel?

    func show() {
        model.reset()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated {
                if let panel, panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: PillView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PillView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 16))
    }
}
