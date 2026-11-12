import AppKit
import CoreGraphics
import os

@MainActor
final class InputOverlay {
    private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Recording")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var context: Unmanaged<TapContext>?
    private var showsClicks = false
    private var showsKeys = false
    private let keyPillArea: CGRect
    private var keyPill: KeyPill?

    init(keyPillArea: CGRect) {
        self.keyPillArea = keyPillArea
    }

    static var hasKeyAccess: Bool { CGPreflightListenEventAccess() }

    func start(clicks: Bool, keystrokes: Bool) {
        guard tap == nil, clicks || keystrokes else { return }
        var wantsKeys = keystrokes
        if keystrokes, !Self.hasKeyAccess {
            _ = CGRequestListenEventAccess()
            wantsKeys = false
            logger.notice("Input Monitoring is missing. Showing clicks only.")
        }
        guard clicks || wantsKeys else { return }
        showsClicks = clicks
        showsKeys = wantsKeys

        var types: [CGEventType] = []
        if clicks { types += [.leftMouseDown, .rightMouseDown, .otherMouseDown] }
        if wantsKeys { types.append(.keyDown) }
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        let context = Unmanaged.passRetained(TapContext(owner: self))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: tapCallback, userInfo: context.toOpaque()
        ) else {
            context.release()
            logger.error("Could not create the event tap.")
            return
        }
        context.takeUnretainedValue().tap = tap
        self.context = context
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        context?.takeUnretainedValue().owner = nil
        context?.release()
        context = nil
        tap = nil
        source = nil
        keyPill?.close()
        keyPill = nil
    }

    fileprivate func click(atQuartz point: CGPoint) {
        guard showsClicks, let primary = NSScreen.screens.first else { return }
        let cocoa = CGPoint(x: point.x, y: primary.frame.height - point.y)
        ClickRipple.show(at: cocoa)
    }

    fileprivate func key(code: Int64, flags: CGEventFlags, character: String?) {
        guard showsKeys, let text = KeyLabel.text(keyCode: code, flags: flags, character: character) else { return }
        if keyPill == nil { keyPill = KeyPill(area: keyPillArea) }
        keyPill?.show(text)
    }
}

private final class TapContext: @unchecked Sendable {
    nonisolated(unsafe) var owner: InputOverlay?
    nonisolated(unsafe) var tap: CFMachPort?

    init(owner: InputOverlay) { self.owner = owner }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
    let location = event.location
    let flags = event.flags
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let character = type == .keyDown ? NSEvent(cgEvent: event)?.charactersIgnoringModifiers : nil
    MainActor.assumeIsolated {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            context.owner?.click(atQuartz: location)
        case .keyDown:
            if !isRepeat { context.owner?.key(code: code, flags: flags, character: character) }
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
private enum ClickRipple {
    private static let size: CGFloat = 90

    static func show(at point: CGPoint) {
        let panel = NSPanel(
            contentRect: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        view.wantsLayer = true
        let circle = CAShapeLayer()
        circle.frame = view.bounds
        circle.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 6, dy: 6), transform: nil)
        circle.fillColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        circle.strokeColor = NSColor.systemYellow.cgColor
        circle.lineWidth = 3
        view.layer?.addSublayer(circle)
        panel.contentView = view
        panel.orderFrontRegardless()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        circle.add(group, forKey: "ripple")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            panel.orderOut(nil)
        }
    }
}

@MainActor
private final class KeyPill {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let area: CGRect
    private var hideTask: Task<Void, Never>?

    init(area: CGRect) {
        self.area = area
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        background.layer?.cornerRadius = 14
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ text: String) {
        hideTask?.cancel()
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: max(label.frame.width + 36, 64), height: label.frame.height + 20)
        label.frame.origin = CGPoint(x: (size.width - label.frame.width) / 2, y: 10)
        let origin = CGPoint(x: area.midX - size.width / 2, y: area.minY + 48)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask = Task { @MainActor [panel] in
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
            }
        }
    }

    func close() {
        hideTask?.cancel()
        panel.orderOut(nil)
    }
}
