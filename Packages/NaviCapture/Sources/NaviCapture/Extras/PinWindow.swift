import AppKit
import SwiftUI

@MainActor
final class PinBoard {
    private var pins: [PinPanel] = []

    var hasLockedPins: Bool { pins.contains { $0.isLocked } }
    var isEmpty: Bool { pins.isEmpty }

    func pin(_ image: NSImage, near screen: NSScreen?) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let fit = min(1, visible.width * 0.5 / image.size.width, visible.height * 0.5 / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let offset = CGFloat(pins.count % 8) * 24
        let origin = CGPoint(x: visible.midX - size.width / 2 + offset, y: visible.midY - size.height / 2 - offset)
        let panel = PinPanel(image: image, frame: CGRect(origin: origin, size: size)) { [weak self] panel in
            self?.pins.removeAll { $0 === panel }
        }
        pins.append(panel)
        panel.orderFrontRegardless()
    }

    func unlockAll() {
        for pin in pins { pin.setLocked(false) }
    }

    func closeAll() {
        for pin in pins { pin.close() }
    }
}

final class PinPanel: NSPanel {
    private(set) var isLocked = false
    private let onClose: (PinPanel) -> Void
    private let image: NSImage

    init(image: NSImage, frame: CGRect, onClose: @escaping (PinPanel) -> Void) {
        self.image = image
        self.onClose = onClose
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = image.size
        minSize = CGSize(width: 60, height: 60 * image.size.height / max(image.size.width, 1))
        let view = FirstMouseHostingView(rootView: PinView(image: image, onClose: { [weak self] in self?.close() }))
        view.menu = makeMenu()
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose(self)
    }

    func setLocked(_ locked: Bool) {
        isLocked = locked
        ignoresMouseEvents = locked
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        var frame = self.frame
        let newWidth = min(max(frame.width * factor, minSize.width), 4000)
        let newHeight = newWidth * image.size.height / max(image.size.width, 1)
        frame.origin.x += (frame.width - newWidth) / 2
        frame.origin.y += (frame.height - newHeight) / 2
        frame.size = CGSize(width: newWidth, height: newHeight)
        setFrame(frame, display: true)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [1.0, 0.75, 0.5, 0.25] {
            let item = NSMenuItem(title: "\(Int(value * 100))%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            sub.addItem(item)
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(withTitle: "Lock (Clicks Go Through)", action: #selector(lock), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        alphaValue = sender.representedObject as? Double ?? 1
    }

    @objc private func lock() { setLocked(true) }

    @objc private func copyImage() {
        NaviPasteboardBridge.write(image)
    }

    @objc private func actualSize() {
        var frame = self.frame
        frame.size = image.size
        setFrame(frame, display: true, animate: true)
    }

    @objc private func closePin() { close() }
}

private struct PinView: View {
    let image: NSImage
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.2)))
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Close. Right-click for opacity and lock.")
            }
        }
        .onHover { hovering = $0 }
    }
}
