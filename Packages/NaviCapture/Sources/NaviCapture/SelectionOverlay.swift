import AppKit
import Carbon.HIToolbox
import NaviCore

@MainActor
final class SelectionSession {
    enum Mode { case area, window }

    enum Purpose: Equatable {
        case screenshot, text, scroll, record
    }

    enum Outcome {
        case area(CapturedImage, NSScreen, rect: CGRect)
        case window(CGWindowID, NSScreen)
        case fullscreen(NSScreen)
        case cancelled
    }

    private(set) var mode: Mode
    var purpose: Purpose = .screenshot {
        didSet {
            if purpose == .text || purpose == .scroll { mode = .area }
            refresh()
            if purpose == .record, oldValue != .record, hasHeldSelection { confirmHeldSelection() }
        }
    }

    var timer = 0
    var showsModeBar = false
    var canRecord = false
    var holdsSelection = false
    private weak var heldOverlay: OverlayView?
    var hasHeldSelection: Bool { heldOverlay != nil }
    private var modeBar: ModeBarPanel?
    let windows: [OnScreenWindow]
    private var overlays: [OverlayWindow] = []
    private var keyMonitor: Any?
    private var sessionKeys: [HotKey] = []
    private var completion: ((Outcome) -> Void)?

    init(screens: [NSScreen], mode: Mode, windows: [OnScreenWindow], completion: @escaping (Outcome) -> Void) {
        self.mode = mode
        self.windows = windows
        self.completion = completion
        overlays = screens.map { screen in
            OverlayWindow(screen: screen, view: OverlayView(session: nil, screen: screen))
        }
        for overlay in overlays { overlay.overlayView.session = self }
    }

    func freeze(_ images: [(NSScreen, CapturedImage)]) {
        for (screen, captured) in images {
            overlays.first { $0.overlayView.screen == screen }?.overlayView.captured = captured
        }
    }

    func begin() {
        let mouseScreen = NSScreen.underMouse
        for overlay in overlays {
            overlay.orderFrontRegardless()
            if overlay.overlayView.screen == mouseScreen {
                overlay.makeKey()
                overlay.makeFirstResponder(overlay.overlayView)
                overlay.overlayView.placeMouse(at: NSEvent.mouseLocation)
            }
        }
        if showsModeBar, let mouseScreen {
            let bar = ModeBarPanel(session: self, screen: mouseScreen)
            bar.orderFrontRegardless()
            modeBar = bar
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape: finish(.cancelled)
            case kVK_Space: toggleMode()
            case kVK_Return, kVK_ANSI_KeypadEnter: confirmHeldSelection()
            default: break
            }
            return nil
        }
        sessionKeys = [
            HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.finish(.cancelled) },
            HotKey(keyCode: UInt32(kVK_Space), modifiers: 0) { [weak self] in self?.toggleMode() },
            HotKey(keyCode: UInt32(kVK_Return), modifiers: 0) { [weak self] in self?.confirmHeldSelection() },
            HotKey(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0) { [weak self] in self?.confirmHeldSelection() },
        ].compactMap { $0 }
        refresh()
    }

    func toggleMode() {
        guard purpose == .screenshot || purpose == .record else { return }
        setMode(mode == .area ? .window : .area)
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        for overlay in overlays { overlay.overlayView.resetDrag() }
        heldOverlay = nil
        refresh()
    }

    func holdChanged(_ overlay: OverlayView?) {
        if let overlay {
            for other in overlays where other.overlayView !== overlay { other.overlayView.resetDrag() }
        }
        heldOverlay = overlay
        refresh()
    }

    func confirmHeldSelection() {
        heldOverlay?.finishSelection()
    }

    var hint: String {
        if hasHeldSelection {
            let verb = switch purpose {
            case .screenshot: "capture"
            case .text: "copy the text"
            case .scroll: "start scrolling"
            case .record: "open the record bar"
            }
            return "Return to \(verb)  ·  Drag inside to move, corners to resize  ·  Esc to cancel"
        }
        let action = switch purpose {
        case .screenshot: mode == .area ? "Click a window or drag an area" : "Click a window"
        case .text: "Drag over text to copy it"
        case .scroll: "Drag over the area to scroll"
        case .record: mode == .area ? "Click a window or drag an area to record" : "Click a window to record"
        }
        let space = purpose == .text || purpose == .scroll ? "" : (mode == .area ? "  ·  Space for window" : "  ·  Space for area")
        return action + space + "  ·  Esc to cancel"
    }

    func refresh() {
        (mode == .area ? NSCursor.crosshair : OverlayView.cameraCursor).set()
        modeBar?.refresh()
        for overlay in overlays {
            overlay.overlayView.needsDisplay = true
            overlay.invalidateCursorRects(for: overlay.overlayView)
        }
    }

    var keepsOverlayUntilDone = false

    func hideEarly() {
        guard !keepsOverlayUntilDone else { return }
        for overlay in overlays { overlay.orderOut(nil) }
        modeBar?.orderOut(nil)
        CATransaction.flush()
    }

    func finish(_ outcome: Outcome) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for key in sessionKeys { key.unregister() }
        sessionKeys = []
        if case .cancelled = outcome {
            for overlay in overlays { overlay.animationBehavior = .none }
            modeBar?.animationBehavior = .none
        }
        for overlay in overlays { overlay.orderOut(nil) }
        modeBar?.orderOut(nil)
        overlays = []
        modeBar = nil
        let completion = completion
        self.completion = nil
        completion?(outcome)
    }
}

final class OverlayWindow: NSPanel {
    let overlayView: OverlayView

    init(screen: NSScreen, view: OverlayView) {
        overlayView = view
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        container.layer?.contentsGravity = .resize
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
}

final class OverlayView: NSView {
    weak var session: SelectionSession?
    let screen: NSScreen
    var captured: CapturedImage? {
        didSet {
            superview?.layer?.contents = captured?.image
            needsDisplay = true
            guard captured != nil, let pending = pendingFinish else { return }
            pendingFinish = nil
            pending()
        }
    }

    private var pendingFinish: (() -> Void)?

    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var pressPoint: CGPoint?
    private var dragBegan = false
    static let clickSlop: CGFloat = 5
    private let highlight = WindowHighlight()

    private static let dim = NSColor.black.withAlphaComponent(0.35)

    static let cameraCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "Camera")?
            .withSymbolConfiguration(config)
        else { return .arrow }
        let pad: CGFloat = 2
        let size = CGSize(width: symbol.size.width + pad * 2, height: symbol.size.height + pad * 2)
        let tinted = { (color: NSColor) in
            NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        let white = tinted(.white)
        let black = tinted(.black)
        let image = NSImage(size: size, flipped: false) { _ in
            for dx in [-1.5, 0, 1.5] {
                for dy in [-1.5, 0, 1.5] where dx != 0 || dy != 0 {
                    white.draw(at: CGPoint(x: pad + dx, y: pad + dy), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            black.draw(at: CGPoint(x: pad, y: pad), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }()
    private static let accent = NSColor.systemBlue

    init(session: SelectionSession?, screen: NSScreen) {
        self.session = session
        self.screen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        highlight.onChange = { [weak self] in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mode: SelectionSession.Mode { session?.mode ?? .area }
    private var imageSize: CGSize {
        if let captured { return CGSize(width: captured.image.width, height: captured.image.height) }
        return CGSize(width: bounds.width * screen.backingScaleFactor, height: bounds.height * screen.backingScaleFactor)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: session?.finish(.cancelled)
        case kVK_Space: session?.toggleMode()
        case kVK_Return, kVK_ANSI_KeypadEnter: session?.confirmHeldSelection()
        default: super.keyDown(with: event)
        }
    }

    func resetDrag() {
        dragStart = nil
        dragCurrent = nil
        pressPoint = nil
        dragBegan = false
        isHolding = false
        moveStart = nil
        updateHighlight()
        needsDisplay = true
    }

    private var isHolding = false
    private var moveStart: (point: CGPoint, rect: CGRect)?
    private static let cornerGrab: CGFloat = 10

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .area ? .crosshair : Self.cameraCursor)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        updateHighlight()
        needsDisplay = true
    }

    func placeMouse(at screenPoint: CGPoint) {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard bounds.contains(point) else { return }
        mouse = point
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = location(of: event)
        mouse = point
        cursor(at: point).set()
        updateHighlight()
        needsDisplay = true
    }

    private var picksHoveredWindow: Bool {
        guard mode == .area, !isHolding, moveStart == nil else { return false }
        return session?.purpose == .screenshot || session?.purpose == .record
    }

    private var clickTarget: OnScreenWindow? {
        guard picksHoveredWindow, !dragBegan, let point = pressPoint ?? mouse else { return nil }
        return hoveredWindow(at: point)
    }

    private func updateHighlight() {
        if dragBegan || !picksHoveredWindow {
            if highlight.window != nil { highlight.hideNow() }
            return
        }
        let target = clickTarget
        highlight.show(target, rect: target.map { $0.frame.intersection(bounds) })
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard mode == .area else { return OverlayView.cameraCursor }
        guard isHolding, let selection else { return .crosshair }
        if CaptureGeometry.oppositeCorner(of: selection, near: point, tolerance: Self.cornerGrab) != nil { return .crosshair }
        return selection.contains(point) ? .openHand : .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        mouse = point
        switch mode {
        case .window:
            if let window = hoveredWindow(at: point) { session?.finish(.window(window.id, screen)) }
        case .area:
            if isHolding, let selection {
                if let anchor = CaptureGeometry.oppositeCorner(of: selection, near: point, tolerance: Self.cornerGrab) {
                    dragStart = anchor
                    dragCurrent = point
                    needsDisplay = true
                    return
                }
                if selection.contains(point) {
                    moveStart = (point, selection)
                    NSCursor.closedHand.set()
                    return
                }
                session?.holdChanged(nil)
                isHolding = false
            }
            pressPoint = point
            dragBegan = false
            dragStart = snapped(point)
            dragCurrent = dragStart
            updateHighlight()
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, dragStart != nil else { return }
        let point = location(of: event)
        mouse = point
        if let move = moveStart {
            let rect = CaptureGeometry.moved(
                move.rect, by: CGVector(dx: point.x - move.point.x, dy: point.y - move.point.y), within: bounds
            )
            dragStart = rect.origin
            dragCurrent = CGPoint(x: rect.maxX, y: rect.maxY)
            needsDisplay = true
            return
        }
        if let pressPoint, !dragBegan, !CaptureGeometry.isClick(from: pressPoint, to: point, threshold: Self.clickSlop) {
            dragBegan = true
            updateHighlight()
        }
        dragCurrent = snapped(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .area, pressPoint != nil, !dragBegan, picksHoveredWindow {
            let target = clickTarget
            resetDrag()
            if let target {
                highlight.hideNow()
                session?.finish(.window(target.id, screen))
            } else if session?.holdsSelection == true, session?.purpose != .record {
                session?.holdChanged(nil)
            }
            return
        }
        guard mode == .area, let selection else { return }
        moveStart = nil
        guard selection.width >= 2, selection.height >= 2 else {
            resetDrag()
            if session?.holdsSelection == true, session?.purpose != .record { session?.holdChanged(nil) }
            return
        }
        if session?.holdsSelection == true {
            isHolding = true
            session?.holdChanged(self)
            cursor(at: location(of: event)).set()
            return
        }
        finishSelection()
    }

    func finishSelection() {
        guard mode == .area, let selection, selection.width >= 2, selection.height >= 2 else { return }
        resetDrag()
        session?.hideEarly()
        let finish = { [weak self] in
            guard let self, let captured else { return }
            let pixels = CaptureGeometry.pixelRect(forSelection: selection, viewSize: bounds.size, imageSize: imageSize)
            guard let cropped = captured.image.cropping(to: pixels) else { return }
            let area = CaptureGeometry.viewRect(forPixels: pixels, viewSize: bounds.size, imageSize: imageSize)
            let topLeft = CGRect(x: area.minX, y: bounds.height - area.maxY, width: area.width, height: area.height)
            session?.finish(.area(CapturedImage(image: cropped, scale: captured.scale), screen, rect: topLeft))
        }
        if captured == nil { pendingFinish = finish } else { finish() }
    }

    private func location(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private var selection: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CaptureGeometry.rect(from: dragStart, to: dragCurrent)
    }

    private var visibleSelection: CGRect? {
        if picksHoveredWindow, !dragBegan { return nil }
        return selection
    }

    private var croppedArea: CGRect? {
        guard let selection = visibleSelection else { return nil }
        let pixels = CaptureGeometry.pixelRect(forSelection: selection, viewSize: bounds.size, imageSize: imageSize)
        return CaptureGeometry.viewRect(forPixels: pixels, viewSize: bounds.size, imageSize: imageSize)
    }

    private var localWindows: [OnScreenWindow] {
        let origin = screen.frame.origin
        return (session?.windows ?? []).map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
    }

    private func hoveredWindow(at point: CGPoint) -> OnScreenWindow? {
        localWindows.first { $0.frame.contains(point) }
    }

    private func snapped(_ point: CGPoint) -> CGPoint {
        CaptureGeometry.snap(point, toWindows: localWindows.map(\.frame), bounds: bounds, tolerance: 6)
    }

    private var magnifierPoint: CGPoint? {
        guard let mouse else { return nil }
        if moveStart != nil || isHolding && dragStart == nil { return mouse }
        if let dragCurrent, dragStart != nil { return dragCurrent }
        return snapped(mouse)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high

        let hole: CGRect? = switch mode {
        case .area: croppedArea
        case .window: mouse.flatMap { hoveredWindow(at: $0)?.frame }
        }

        if hole == nil, picksHoveredWindow, !dragBegan, highlight.frame != nil {
            highlight.drawDim(in: context, bounds: bounds, color: Self.dim)
            highlight.drawRing(in: context)
            highlight.drawLabel(in: bounds, scale: imageSize.width / max(bounds.width, 1))
        } else {
            context.saveGState()
            context.setFillColor(Self.dim.cgColor)
            context.addRect(bounds)
            if let hole { context.addRect(hole) }
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }

        switch mode {
        case .area:
            if let selection = visibleSelection, let area = croppedArea {
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(1)
                context.stroke(area.insetBy(dx: -0.5, dy: -0.5))
                if isHolding { drawCornerHandles(of: area, in: context) }
                drawSizeLabel(for: selection)
            }
            if let point = magnifierPoint, let captured { drawMagnifier(at: point, image: captured.image, in: context) }
        case .window:
            if let hole {
                context.setFillColor(Self.accent.withAlphaComponent(0.18).cgColor)
                context.fill(hole)
                context.setStrokeColor(Self.accent.cgColor)
                context.setLineWidth(3)
                context.stroke(hole.insetBy(dx: 1.5, dy: 1.5))
            }
        }

        if mouse != nil { drawModeTag() }
    }

    private func drawCornerHandles(of rect: CGRect, in context: CGContext) {
        let size: CGFloat = 8
        for corner in [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ] {
            let dot = CGRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: dot)
            context.setStrokeColor(Self.accent.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: dot)
        }
    }

    private func drawSizeLabel(for selection: CGRect) {
        let pixels = CaptureGeometry.pixelRect(forSelection: selection, viewSize: bounds.size, imageSize: imageSize)
        let text = "\(Int(pixels.width)) × \(Int(pixels.height))"
        var origin = CGPoint(x: selection.minX, y: selection.minY - 26)
        if origin.y < 4 { origin.y = selection.maxY + 6 }
        drawPill(text, at: origin)
    }

    private func drawModeTag() {
        guard let text = session?.hint else { return }
        let size = Self.pillSize(text)
        drawPill(text, at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.height - 70))
    }

    private func drawMagnifier(at point: CGPoint, image: CGImage, in context: CGContext) {
        let pixelCount = 15
        let diameter: CGFloat = 120
        let cell = diameter / CGFloat(pixelCount)
        let pixel = CaptureGeometry.pixel(at: point, viewSize: bounds.size, imageSize: imageSize)
        let half = pixelCount / 2
        let source = CGRect(x: pixel.x - half, y: pixel.y - half, width: pixelCount, height: pixelCount)

        var frame = CGRect(x: point.x + 24, y: point.y - 24 - diameter, width: diameter, height: diameter)
        if frame.maxX > bounds.width { frame.origin.x = point.x - 24 - diameter }
        if frame.minY < 30 { frame.origin.y = point.y + 24 }

        context.saveGState()
        context.addEllipse(in: frame)
        context.clip()
        context.setFillColor(NSColor.black.cgColor)
        context.fill(frame)
        if let crop = image.cropping(to: source) {
            let dx = CGFloat(max(0, -source.minX)) * cell
            let dy = CGFloat(max(0, -source.minY)) * cell
            let drawRect = CGRect(
                x: frame.minX + dx,
                y: frame.maxY - dy - CGFloat(crop.height) * cell,
                width: CGFloat(crop.width) * cell,
                height: CGFloat(crop.height) * cell
            )
            context.interpolationQuality = .none
            context.draw(crop, in: drawRect)
        }
        let center = CGRect(x: frame.midX - cell / 2, y: frame.midY - cell / 2, width: cell, height: cell)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(center)
        context.restoreGState()

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: frame.insetBy(dx: 1, dy: 1))

        let label = "\(pixel.x), \(pixel.y)"
        let size = Self.pillSize(label)
        drawPill(label, at: CGPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 4))
    }

    private static let pillAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private static func pillSize(_ text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: pillAttributes)
        return CGSize(width: size.width + 12, height: size.height + 6)
    }

    private func drawPill(_ text: String, at origin: CGPoint) {
        let size = Self.pillSize(text)
        let rect = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), withAttributes: Self.pillAttributes)
    }
}
