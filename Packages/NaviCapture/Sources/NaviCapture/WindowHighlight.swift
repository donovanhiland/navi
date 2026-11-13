import AppKit

@MainActor
final class WindowHighlight {
    var onChange: (() -> Void)?

    private(set) var frame: CGRect?
    private(set) var alpha: CGFloat = 0
    private(set) var window: OnScreenWindow?
    private var icon: NSImage?

    private var fromFrame: CGRect = .zero
    private var toFrame: CGRect = .zero
    private var fromAlpha: CGFloat = 0
    private var toAlpha: CGFloat = 0
    private var startTime: CFTimeInterval = 0
    private var timer: Timer?

    private static let glideDuration: CFTimeInterval = 0.14
    private static let cornerRadius: CGFloat = 12
    static let purple = NSColor(srgbRed: 0.545, green: 0.361, blue: 0.965, alpha: 1)

    func show(_ window: OnScreenWindow?, rect: CGRect?) {
        guard window?.id != self.window?.id else { return }
        self.window = window
        icon = window.flatMap { NSRunningApplication(processIdentifier: $0.ownerPID)?.icon }
        let current = frame ?? rect ?? .zero
        fromFrame = current
        fromAlpha = alpha
        if let rect {
            toFrame = rect
            toAlpha = 1
        } else {
            toFrame = current
            toAlpha = 0
        }
        if frame == nil { frame = toFrame }
        startTime = CACurrentMediaTime()
        startTimer()
    }

    func hideNow() {
        timer?.invalidate()
        timer = nil
        window = nil
        icon = nil
        frame = nil
        alpha = 0
        toAlpha = 0
        onChange?()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let progress = CGFloat((CACurrentMediaTime() - startTime) / Self.glideDuration)
        let eased = CaptureGeometry.easeOut(progress)
        frame = CaptureGeometry.interpolate(fromFrame, toFrame, progress: eased)
        alpha = fromAlpha + (toAlpha - fromAlpha) * eased
        if progress >= 1 {
            timer?.invalidate()
            timer = nil
            if toAlpha == 0 { frame = nil }
        }
        onChange?()
    }

    var holePath: CGPath? {
        guard let frame, alpha > 0 else { return nil }
        return CGPath(roundedRect: frame, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    func drawLabel(in bounds: CGRect, scale: CGFloat) {
        guard let frame, let window, alpha > 0 else { return }
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let sizeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6 * alpha),
        ]
        let name = (window.appName.isEmpty ? "Window" : window.appName) as NSString
        let size = "\(Int(frame.width * scale)) × \(Int(frame.height * scale))" as NSString
        let nameSize = name.size(withAttributes: nameAttributes)
        let sizeSize = size.size(withAttributes: sizeAttributes)
        let iconSide: CGFloat = 18
        let padding: CGFloat = 8
        let gap: CGFloat = 7
        let width = padding + (icon == nil ? 0 : iconSide + gap) + nameSize.width + gap + sizeSize.width + padding
        let height: CGFloat = 30

        let visible = frame.intersection(bounds)
        guard !visible.isNull, visible.height > height + 8, visible.width > width + 8 else { return }
        let origin = CGPoint(x: (visible.midX - width / 2).rounded(), y: (visible.maxY - 14 - height).rounded())
        let pill = CGRect(origin: origin, size: CGSize(width: width, height: height))

        NSColor(srgbRed: 0.086, green: 0.078, blue: 0.118, alpha: 0.85 * alpha).setFill()
        let path = NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9)
        path.fill()
        NSColor.white.withAlphaComponent(0.12 * alpha).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x = pill.minX + padding
        if let icon {
            icon.draw(in: CGRect(x: x, y: pill.midY - iconSide / 2, width: iconSide, height: iconSide), from: .zero, operation: .sourceOver, fraction: alpha)
            x += iconSide + gap
        }
        name.draw(at: CGPoint(x: x, y: pill.midY - nameSize.height / 2), withAttributes: nameAttributes)
        x += nameSize.width + gap
        size.draw(at: CGPoint(x: x, y: pill.midY - sizeSize.height / 2), withAttributes: sizeAttributes)
    }
}
