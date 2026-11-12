import AppKit
import Carbon.HIToolbox
import NaviCore
import SwiftUI
import os

@MainActor
final class InPlaceAnnotator {
    enum Action { case copy, save, stash }

    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Capture")
    private let model: AnnotateModel
    private let screen: NSScreen
    private let area: CGRect
    private let backdrop: CGImage?
    private var window: InPlaceWindow?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var fallbackKeys: [HotKey] = []
    private var colorPanelLevel: NSWindow.Level?
    private var onFinish: (((Action, AnnotateEditor.Result)?) -> Void)?

    init(
        captured: CapturedImage, backdrop: CGImage?, screen: NSScreen, area: CGRect,
        onFinish: @escaping ((Action, AnnotateEditor.Result)?) -> Void
    ) {
        let source = CGRect(
            x: (area.minX * captured.scale).rounded(), y: (area.minY * captured.scale).rounded(),
            width: CGFloat(captured.image.width), height: CGFloat(captured.image.height)
        )
        let placement = ScreenPlacement(origin: area.origin, source: backdrop == nil ? nil : source, scale: captured.scale)
        model = AnnotateModel(base: captured.image, scale: captured.scale, placement: placement)
        self.backdrop = backdrop
        self.screen = screen
        self.area = area
        self.onFinish = onFinish
    }

    func show() {
        let window = InPlaceWindow(screen: screen)
        let hosting = NSHostingView(rootView: InPlaceAnnotateView(
            model: model,
            backdrop: backdrop,
            area: area,
            onDone: { [weak self] in self?.finish(.copy) },
            onSave: { [weak self] in self?.finish(.save) },
            onStash: { [weak self] in self?.finish(.stash) },
            onCancel: { [weak self] in self?.finish(nil) }
        ))
        hosting.sizingOptions = []
        window.contentView = hosting
        self.window = window
        watchKeys()
        colorPanelLevel = NSColorPanel.shared.level
        NSColorPanel.shared.level = InPlaceWindow.overlayLevel + 1
        if !NSApp.isActive { registerFallbackKeys() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseFallbackKeys() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    private func finish(_ action: Action?) {
        guard let onFinish else { return }
        self.onFinish = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        releaseFallbackKeys()
        if let colorPanelLevel { NSColorPanel.shared.level = colorPanelLevel }
        colorPanelLevel = nil
        if action == nil { window?.animationBehavior = .none }
        window?.orderOut(nil)
        window = nil
        guard let action else {
            onFinish(nil)
            return
        }
        guard let flat = model.flatten() else {
            Self.logger.error("Could not flatten the marked-up capture")
            Toast.show("Could not copy the screenshot", on: screen)
            onFinish(nil)
            return
        }
        onFinish((action, AnnotateEditor.Result(flat: flat, base: model.base, document: model.document, pointSize: model.pointSize)))
    }

    private func watchKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.windowNumber == event.windowNumber else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
    }

    private func registerFallbackKeys() {
        let confirm: () -> Void = { [weak self] in self?.pressReturn() }
        fallbackKeys = [
            HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.pressEscape() },
            HotKey(keyCode: UInt32(kVK_Return), modifiers: 0, action: confirm),
            HotKey(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0, action: confirm),
        ].compactMap { $0 }
    }

    private func releaseFallbackKeys() {
        for key in fallbackKeys { key.unregister() }
        fallbackKeys = []
    }

    private func pressReturn() {
        if model.textEdit != nil { model.finishText() } else if model.cropRect != nil { model.applyCrop() } else { finish(.copy) }
    }

    private func pressEscape() {
        if model.textEdit != nil { model.finishText() } else if model.cropRect != nil { model.cancelCrop() } else { finish(nil) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let code = event.keyCode
        let isReturn = code == AnnotateKeys.returnKey || code == AnnotateKeys.keypadEnter
        let plain = AnnotateKeys.modifiers(of: event).isEmpty
        if model.textEdit == nil, model.cropRect != nil, plain {
            if isReturn { model.applyCrop(); return true }
            if code == AnnotateKeys.escape { model.cancelCrop(); return true }
        }
        if model.textEdit == nil, plain {
            if isReturn { finish(.copy); return true }
            if code == AnnotateKeys.escape { finish(nil); return true }
        }
        if model.textEdit == nil, AnnotateKeys.modifiers(of: event) == .command, code == UInt16(kVK_ANSI_S) {
            finish(.save)
            return true
        }
        return AnnotateKeys.handle(event, model: model)
    }
}

private final class InPlaceWindow: NSWindow {
    static let overlayLevel = NSWindow.Level.popUpMenu

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = Self.overlayLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct InPlaceAnnotateView: View {
    @Bindable var model: AnnotateModel
    let backdrop: CGImage?
    let area: CGRect
    let onDone: () -> Void
    let onSave: () -> Void
    let onStash: () -> Void
    let onCancel: () -> Void
    var revealOverride: CGFloat?
    @State private var toolbarSize = CGSize(width: 900, height: 44)
    @State private var reveal: CGFloat = 0
    @State private var pointer: CGPoint?
    @State private var isDraggingFrame = false

    static let space = "InPlaceScreen"
    private static let dim = Color.black.opacity(0.42)
    private static let revealDistance: CGFloat = 24
    private static let toolbarGap: CGFloat = 10
    private static let screenMargin: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let hole = model.placement?.frame(pointSize: model.pointSize) ?? CGRect(origin: area.origin, size: model.pointSize)
            let toolbarOrigin = CaptureGeometry.toolbarOrigin(
                below: hole, toolbar: toolbarSize, in: proxy.size, gap: Self.toolbarGap, margin: Self.screenMargin
            )
            ZStack(alignment: .topLeading) {
                if let backdrop {
                    Image(decorative: backdrop, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                dim(around: hole, in: proxy.size)
                AnnotateCanvas(model: model, layout: .actualSize)
                    .frame(width: hole.width, height: hole.height)
                    .offset(x: hole.minX, y: hole.minY)
                frameAdjuster(hole: hole, screen: proxy.size)
                toolbar
                    .offset(x: toolbarOrigin.x, y: toolbarOrigin.y)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.space))
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                if case let .active(point) = phase { pointer = point } else { pointer = nil }
                updateReveal(hole: hole)
            }
        }
        .ignoresSafeArea()
    }

    private func frameAdjuster(hole: CGRect, screen: CGSize) -> some View {
        FrameAdjuster(
            frame: hole,
            pixelSize: model.pixelSize,
            screenSize: screen,
            canAdjust: backdrop != nil && model.placement?.canReframe == true,
            reveal: revealOverride ?? reveal,
            onDragging: { dragging in
                if dragging { model.beginReframe() }
                isDraggingFrame = dragging
                updateReveal(hole: hole)
            },
            onChange: { frame in
                if let backdrop { model.reframe(to: frame, screen: backdrop) }
            }
        )
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }

    private func updateReveal(hole: CGRect) {
        let near = pointer.map { Self.isNearFrame($0, hole: hole) } ?? false
        let target: CGFloat = isDraggingFrame || near ? 1 : 0
        guard target != reveal else { return }
        withAnimation(.easeOut(duration: 0.18)) { reveal = target }
    }

    static func isNearFrame(_ point: CGPoint, hole: CGRect) -> Bool {
        let nearLine = hole.insetBy(dx: -revealDistance, dy: -revealDistance).contains(point)
            && !hole.insetBy(dx: revealDistance, dy: revealDistance).contains(point)
        return nearLine || FrameAdjuster.moveTabZone(of: hole).insetBy(dx: -4, dy: -4).contains(point)
    }

    private func dim(around hole: CGRect, in size: CGSize) -> some View {
        Rectangle()
            .fill(Self.dim)
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .frame(width: hole.width, height: hole.height)
                    .offset(x: hole.minX, y: hole.minY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        .onTapGesture {}
        .onHover { inside in if inside { NSCursor.arrow.set() } }
    }

    private var toolbar: some View {
        AnnotateToolbar(
            model: model, onDone: onDone, onCancel: onCancel, doneTitle: "Copy", doneModifiers: nil,
            showsDragThumbnail: false, onSave: onSave, onStash: onStash
        )
            .fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { toolbarSize = $0 }
    }
}
