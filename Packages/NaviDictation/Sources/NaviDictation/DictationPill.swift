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
    var liveText = ""
    var levels: [Float] = Array(repeating: 0, count: PillModel.barCount)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        phase = .listening
        isLocked = false
        liveText = ""
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

struct PillView: View {
    static let panelSize = NSSize(width: 240, height: 80)
    static let bottomInset: CGFloat = 13
    static let spacing: CGFloat = 8
    let model: PillModel

    private var showsWords: Bool { model.phase == .listening && !model.liveText.isEmpty }

    var body: some View {
        VStack(spacing: 4) {
            if showsWords {
                LiveTextLine(text: model.liveText, width: rowWidth)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(spacing: Self.spacing) {
                switch model.phase {
                case .listening:
                    if model.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: showsWords ? 8 : 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Waveform(levels: model.levels, compact: showsWords)
                case .thinking:
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("Thinking…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, showsWords ? 7 : 6)
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.18), value: showsWords)
        .padding(.bottom, Self.bottomInset)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .bottom)
    }

    private var rowWidth: CGFloat { Waveform.width }
}

private struct LiveTextLine: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(width: width, alignment: .center)
    }
}

private struct Waveform: View {
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2
    static let width = CGFloat(PillModel.barCount) * barWidth + CGFloat(PillModel.barCount - 1) * barSpacing
    static let compactBarCount = 12
    static let compactBarWidth: CGFloat = 2
    static let compactHeight: CGFloat = 8
    let levels: [Float]
    let compact: Bool

    var body: some View {
        let shown = compact ? Array(levels.suffix(Self.compactBarCount)) : levels
        let height = compact ? Self.compactHeight : 22
        let barWidth = compact ? Self.compactBarWidth : Self.barWidth
        HStack(spacing: Self.barSpacing) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(compact ? 0.7 : 1))
                    .frame(width: barWidth, height: 2 + CGFloat(level) * (height - 2))
            }
        }
        .frame(height: height)
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
        self.panel?.orderOut(nil)
        let panel = makePanel()
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
