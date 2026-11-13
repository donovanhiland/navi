import AppKit
import SwiftUI

@MainActor
final class ScrollCaptureSession {
    private let screen: NSScreen
    private let rect: CGRect
    private let hideDesktopIcons: Bool
    private let completion: (CGImage?, CGFloat) -> Void
    private var stitcher = ScrollStitcher()
    private var outline: NSWindow?
    private var controls: NSPanel?
    private let status = ScrollStatus()
    private var loop: Task<Void, Never>?
    private var scale: CGFloat = 2
    private static let maxPixels: CGFloat = 40000

    init(screen: NSScreen, rect: CGRect, hideDesktopIcons: Bool, completion: @escaping (CGImage?, CGFloat) -> Void) {
        self.screen = screen
        self.rect = rect
        self.hideDesktopIcons = hideDesktopIcons
        self.completion = completion
    }

    func begin() {
        showOutline()
        showControls()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func tick() async {
        guard let captured = try? await ScreenGrabber.capture(screen, rect: rect, hideDesktopIcons: hideDesktopIcons) else { return }
        scale = captured.scale
        let frame = captured.image
        guard let last = stitcher.latest else {
            stitcher.append(frame, offset: .zero)
            status.frames = 1
            return
        }
        guard last.width == frame.width, last.height == frame.height else { return }
        let offset = await Task.detached(priority: .userInitiated) { ScrollStitcher.offset(of: frame, from: last) }.value
        guard let offset, stitcher.append(frame, offset: offset) else { return }
        status.frames = stitcher.accepted
        let size = stitcher.stitchedSize
        status.size = "\(Int(size.width)) × \(Int(size.height))"
        if max(size.width, size.height) > Self.maxPixels { finish(keep: true) }
        if status.autoScroll { scrollDown() }
    }

    private func scrollDown() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = CGPoint(x: screen.frame.minX + rect.midX, y: primaryHeight - screen.frame.maxY + rect.midY)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-rect.height / 3), wheel2: 0, wheel3: 0)
        event?.location = global
        event?.post(tap: .cghidEventTap)
    }

    private func showOutline() {
        let frame = CGRect(
            x: screen.frame.minX + rect.minX - 2, y: screen.frame.maxY - rect.maxY - 2,
            width: rect.width + 4, height: rect.height + 4
        )
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let border = NSView(frame: CGRect(origin: .zero, size: frame.size))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.systemBlue.cgColor
        border.layer?.borderWidth = 2
        window.contentView = border
        window.orderFrontRegardless()
        outline = window
    }

    private func showControls() {
        let size = CGSize(width: 420, height: 44)
        var origin = CGPoint(x: screen.frame.minX + rect.midX - size.width / 2, y: screen.frame.maxY - rect.maxY - size.height - 12)
        if origin.y < screen.frame.minY + 8 { origin.y = screen.frame.maxY - rect.minY + 12 }
        if origin.y + size.height > screen.frame.maxY { origin.y = screen.frame.minY + 40 }
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstMouseHostingView(rootView: ScrollControls(
            status: status,
            onDone: { [weak self] in self?.finish(keep: true) },
            onCancel: { [weak self] in self?.finish(keep: false) }
        ))
        panel.orderFrontRegardless()
        controls = panel
    }

    private func finish(keep: Bool) {
        loop?.cancel()
        loop = nil
        outline?.orderOut(nil)
        controls?.orderOut(nil)
        outline = nil
        controls = nil
        completion(keep ? stitcher.stitched() : nil, scale)
    }
}

@MainActor
@Observable
final class ScrollStatus {
    var frames = 0
    var size = ""
    var autoScroll = false
}

private struct ScrollControls: View {
    @Bindable var status: ScrollStatus
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.and.down.text.horizontal")
            Text(status.frames < 2 ? "Scroll the area now" : "\(status.frames) frames · \(status.size)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 4)
            Toggle("Auto-scroll", isOn: $status.autoScroll)
                .toggleStyle(.button)
                .controlSize(.small)
            Button("Cancel", action: onCancel).controlSize(.small)
            Button("Done", action: onDone)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
enum Countdown {
    static func run(seconds: Int, on screen: NSScreen?) async {
        guard seconds > 0 else { return }
        let frame = (screen ?? NSScreen.main)?.frame ?? .zero
        let size = CGSize(width: 160, height: 160)
        let panel = NSPanel(
            contentRect: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 96, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 32
        label.frame = CGRect(x: 0, y: 20, width: size.width, height: 116)
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()
        for remaining in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(remaining)"
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(80))
    }
}
