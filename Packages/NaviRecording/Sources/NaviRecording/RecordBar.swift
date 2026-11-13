import AppKit
import Observation
import SwiftUI

enum RecordingFormat {
    case gif
    case video
}

@MainActor
@Observable
final class RecordBarModel {
    var options: RecordingOptions
    private(set) var region: RecordingRegion
    var widthText = ""
    var heightText = ""

    private let displayID: CGDirectDisplayID
    private let displayFrame: CGRect
    private let scale: CGFloat
    private var windowFrame: CGRect?

    @ObservationIgnored var onRegionChange: (() -> Void)?
    @ObservationIgnored var onCameraChange: ((Bool) -> Void)?
    @ObservationIgnored var onStart: ((RecordingFormat) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    var canResize: Bool {
        if case .window = region { return false }
        return true
    }

    init?(region: RecordingRegion, options: RecordingOptions) {
        guard let resolved = ResolvedRegion.resolve(region) else { return nil }
        self.region = region
        self.options = options
        displayID = resolved.displayID
        displayFrame = resolved.displayFrame
        scale = resolved.scale
        if case .window = region { windowFrame = resolved.frame }
        syncSizeText()
    }

    var cocoaFrame: CGRect? { ResolvedRegion.resolve(region)?.frame }

    func toggleMicrophone() {
        if options.microphone {
            options.microphone = false
            return
        }
        Task {
            options.microphone = await Permissions.microphone()
        }
    }

    func useFullscreen() {
        region = .display(displayID)
        syncSizeText()
        onRegionChange?()
    }

    func applyTypedSize() {
        guard canResize, let width = Int(widthText), let height = Int(heightText), width > 0, height > 0 else {
            syncSizeText()
            return
        }
        let current = localArea
        let area = RecordingMath.resizedArea(current, toPixelWidth: width, height: height, scale: scale, displaySize: displayFrame.size)
        region = .area(displayID, area)
        syncSizeText()
        onRegionChange?()
    }

    func start(_ format: RecordingFormat) {
        applyTypedSize()
        onStart?(format)
    }

    private var localArea: CGRect {
        switch region {
        case .area(_, let rect): rect
        case .display, .window: CGRect(origin: .zero, size: displayFrame.size)
        }
    }

    private func syncSizeText() {
        let size: CGSize
        switch region {
        case .window: size = windowFrame?.size ?? .zero
        default: size = localArea.size
        }
        widthText = String(Int((size.width * scale).rounded()))
        heightText = String(Int((size.height * scale).rounded()))
    }
}

struct RecordBarView: View {
    @Bindable var model: RecordBarModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                iconButton(
                    model.options.microphone ? "mic.fill" : "mic.slash.fill",
                    help: model.options.microphone ? "Microphone on" : "Microphone off",
                    dimmed: !model.options.microphone
                ) { model.toggleMicrophone() }
                divider
                optionsMenu
                divider
                sizeFields
                divider
                iconButton("arrow.up.left.and.arrow.down.right", help: "Record the whole display", dimmed: false) {
                    model.useFullscreen()
                }
            }
            .frame(height: 44)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            row("Record GIF") {
                Text("GIF")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.white, in: RoundedRectangle(cornerRadius: 5))
            } action: { model.start(.gif) }
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            row("Record Video") {
                Image(systemName: "video.fill").font(.system(size: 16))
            } action: { model.start(.video) }
        }
        .frame(width: 300)
        .background(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.options.camera) { _, isOn in model.onCameraChange?(isOn) }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Computer audio", isOn: $model.options.computerAudio)
            Toggle("Camera", isOn: $model.options.camera)
            Toggle("Show clicks", isOn: $model.options.showClicks)
            Toggle("Show keystrokes", isOn: $model.options.showKeystrokes)
            Toggle("Hide desktop icons", isOn: $model.options.hideDesktopIcons)
            Toggle("Mute notifications", isOn: $model.options.muteNotifications)
            Divider()
            Picker("Frame rate", selection: $model.options.framesPerSecond) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17))
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Recording options")
    }

    private var sizeFields: some View {
        HStack(spacing: 6) {
            sizeField($model.widthText, label: "Width in pixels")
            Text("×").foregroundStyle(.secondary)
            sizeField($model.heightText, label: "Height in pixels")
        }
        .frame(maxWidth: .infinity)
        .disabled(!model.canResize)
        .opacity(model.canResize ? 1 : 0.6)
    }

    private func sizeField(_ text: Binding<String>, label: String) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 56)
            .padding(.vertical, 4)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 5))
            .onSubmit { model.applyTypedSize() }
            .accessibilityLabel(label)
    }

    private func iconButton(_ symbol: String, help: String, dimmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(dimmed ? Color(white: 0.5) : .white)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func row<Trailing: View>(
        _ title: String, @ViewBuilder trailing: () -> Trailing, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                trailing()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private final class BarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

@MainActor
final class RecordBarController {
    let model: RecordBarModel
    private let barPanel: BarPanel
    private let outlinePanel: NSPanel
    private let hosting: NSHostingView<RecordBarView>
    private var escapeMonitor: Any?

    init?(region: RecordingRegion, options: RecordingOptions) {
        guard let model = RecordBarModel(region: region, options: options) else { return nil }
        self.model = model

        hosting = NSHostingView(rootView: RecordBarView(model: model))
        let size = hosting.fittingSize
        barPanel = BarPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        barPanel.contentView = hosting
        Self.configure(barPanel, level: .floating, hasShadow: true)

        outlinePanel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        outlinePanel.contentView = OutlineView()
        outlinePanel.ignoresMouseEvents = true
        Self.configure(outlinePanel, level: .floating, hasShadow: false)

        model.onRegionChange = { [weak self] in self?.layout() }
        barPanel.onCancel = { [weak model] in model?.onCancel?() }
    }

    private static func configure(_ panel: NSPanel, level: NSWindow.Level, hasShadow: Bool) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = hasShadow
        panel.level = level
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    var windowIDs: Set<CGWindowID> {
        Set([barPanel, outlinePanel].compactMap { $0.windowNumber > 0 ? CGWindowID(exactly: $0.windowNumber) : nil })
    }

    func show() {
        layout()
        outlinePanel.orderFrontRegardless()
        barPanel.makeKeyAndOrderFront(nil)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { model?.onCancel?() }
                return nil
            }
            return event
        }
    }

    func close() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        barPanel.orderOut(nil)
        outlinePanel.orderOut(nil)
    }

    private func layout() {
        guard let region = model.cocoaFrame else { return }
        outlinePanel.setFrame(region.insetBy(dx: -3, dy: -3), display: true)
        let screen = NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? region
        barPanel.setFrame(RecordingMath.barFrame(region: region, barSize: barPanel.frame.size, visible: visible), display: true)
    }
}
