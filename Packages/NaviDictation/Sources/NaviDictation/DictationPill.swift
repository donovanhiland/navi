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

    var phase: Phase = .listening
    var isLocked = false
    var liveText = ""
    var showsWords = true
    var glowStyle = PillGlowStyle.standard
    private var smoother = BandSmoother()
    var bands: [Float] { smoother.values }

    func push(bands: [Float]) {
        smoother.push(bands)
    }

    func reset() {
        phase = .listening
        isLocked = false
        liveText = ""
        smoother.reset()
    }
}

struct PillView: View {
    static let pillWidth: CGFloat = 240
    static let compactHeight: CGFloat = 34
    static let expandedHeight: CGFloat = 56
    static let wordsRowHeight: CGFloat = 26
    static let glowStripHeight: CGFloat = 30
    static let horizontalPadding: CGFloat = 16
    static let panelSize = NSSize(width: 264, height: 96)
    static let bottomInset: CGFloat = 13
    let model: PillModel
    var time: Double?

    private var isExpanded: Bool { model.showsWords || !model.liveText.isEmpty }

    var body: some View {
        let height = isExpanded ? Self.expandedHeight : Self.compactHeight
        let radius = isExpanded ? 20.0 : Self.compactHeight / 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(.black.opacity(0.88))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PillGlowView(
                    bands: model.bands, style: model.glowStyle,
                    isThinking: model.phase == .thinking, time: time
                )
                .frame(height: isExpanded ? Self.glowStripHeight : Self.compactHeight)
            }
            row
                .frame(height: isExpanded ? Self.wordsRowHeight : Self.compactHeight)
        }
        .frame(width: Self.pillWidth, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isExpanded)
        .padding(.bottom, Self.bottomInset)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .bottom)
    }

    @ViewBuilder private var row: some View {
        Group {
            if model.phase == .thinking {
                PlaceholderLine(text: "Thinking…")
            } else if isExpanded {
                if model.liveText.isEmpty {
                    PlaceholderLine(text: "Listening…")
                } else {
                    LiveTextLine(text: model.liveText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.horizontalPadding)
    }
}

private struct PlaceholderLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
    }
}

private struct LiveTextLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.head)
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
