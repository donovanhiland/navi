import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AnnotateEditor: NSObject, NSWindowDelegate {
    struct Result {
        let flat: CGImage
        let base: CGImage
        let document: AnnotationDocument
        let pointSize: CGSize
    }

    private let model: AnnotateModel
    private var window: NSWindow?
    private var keyMonitor: Any?
    private let onDone: (Result) -> Void
    private let onClose: () -> Void

    init(base: CGImage, document: AnnotationDocument, scale: CGFloat, onDone: @escaping (Result) -> Void, onClose: @escaping () -> Void) {
        model = AnnotateModel(base: base, document: document, scale: scale)
        self.onDone = onDone
        self.onClose = onClose
        super.init()
    }

    func show() {
        let visible = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let image = model.pointSize
        let fit = min(1, (visible.width * 0.85) / image.width, (visible.height * 0.85 - 100) / image.height)
        let size = CGSize(width: max(760, image.width * fit), height: max(420, image.height * fit + 100))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Annotate"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: AnnotateView(
            model: model,
            onDone: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.window?.close() }
        ))
        window.center()
        self.window = window
        watchKeys()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        guard let flat = model.flatten() else { return }
        onDone(Result(flat: flat, base: model.base, document: model.document, pointSize: model.pointSize))
        window?.close()
    }

    private func watchKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.windowNumber == event.windowNumber else { return false }
                return AnnotateKeys.handle(event, model: self.model)
            }
            return handled ? nil : event
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window = nil
        onClose()
    }
}

struct AnnotateView: View {
    @Bindable var model: AnnotateModel
    let onDone: () -> Void
    let onCancel: () -> Void
    @State private var tips: TooltipCenter

    init(model: AnnotateModel, tips: TooltipCenter = TooltipCenter(), onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        _tips = State(initialValue: tips)
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            AnnotateToolbar(model: model, onDone: onDone, onCancel: onCancel)
                .padding(.leading, 66)
            Divider()
            AnnotateCanvas(model: model, layout: .fitted)
                .background(Color.black.opacity(0.2))
        }
        .frame(minWidth: 760, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .tooltipLayer(tips)
    }
}

struct AnnotateToolbar: View {
    @Bindable var model: AnnotateModel
    let onDone: () -> Void
    let onCancel: () -> Void
    var doneTitle = "Done"
    var doneModifiers: EventModifiers? = .command
    var showsDragThumbnail = true
    var onSave: (() -> Void)?
    var onStash: (() -> Void)?

    private static let drawingTools: [AnnotationTool] = [
        .select, .arrow, .rectangle, .filledRectangle, .ellipse, .line, .pencil, .highlighter, .text, .counter,
    ]
    private static let effectTools: [AnnotationTool] = [.blur, .pixelate, .spotlight, .crop]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                toolGroups
                styleGroup
                historyGroup
                Spacer(minLength: 16)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    toolGroups
                    Spacer(minLength: 16)
                    actions
                }
                HStack(spacing: 10) {
                    styleGroup
                    historyGroup
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { toolGroups }
                HStack(spacing: 10) {
                    styleGroup
                    historyGroup
                    Spacer(minLength: 16)
                    actions
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var toolGroups: some View {
        ToolGroup { ForEach(Self.drawingTools, id: \.self, content: toolButton) }
        ToolGroup { ForEach(Self.effectTools, id: \.self, content: toolButton) }
    }

    private var styleGroup: some View {
        ToolGroup {
            ColorWell(model: model)
                .tooltip(Tip(title: "Color"))
            ForEach(StrokeSize.allCases, id: \.self) { size in
                IconButton(isOn: model.strokeSize == size, style: .subtle) {
                    model.strokeSize = size
                } label: {
                    Capsule().frame(width: 14, height: size.previewHeight)
                }
                .tooltip(Tip(title: "\(size.title) line"))
            }
            Menu {
                Button("Rotate Left") { model.apply(.rotateCounterclockwise) }
                Button("Rotate Right") { model.apply(.rotateClockwise) }
                Button("Flip Horizontal") { model.apply(.flipHorizontal) }
                Button("Flip Vertical") { model.apply(.flipVertical) }
                Divider()
                ForEach([0.5, 0.75, 1.5, 2], id: \.self) { factor in
                    Button("Resize to \(Int(factor * 100))%") { model.apply(.resize(factor)) }
                }
            } label: {
                Image(systemName: "rotate.right").frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .tooltip(Tip(title: "Rotate, flip, resize"))
        }
    }

    private var historyGroup: some View {
        ToolGroup {
            IconButton(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .tooltip(Tip(title: "Undo", shortcut: "⌘Z"))
            IconButton(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .tooltip(Tip(title: "Redo", shortcut: "⇧⌘Z"))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if showsDragThumbnail { dragMe }
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
            if let onStash {
                Button("Stash", action: onStash)
                    .buttonStyle(.bordered)
                    .help("Keep it in the history (⇧⌘V) without copying it")
            }
            if let onSave {
                Button("Save", action: onSave)
                    .buttonStyle(.bordered)
                    .help("Save to the save folder (⌘S)")
            }
            if let doneModifiers {
                Button(doneTitle, action: onDone)
                    .keyboardShortcut(.return, modifiers: doneModifiers)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(doneTitle, action: onDone)
                    .buttonStyle(.borderedProminent)
            }
        }
        .fixedSize()
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        IconButton(isOn: model.tool == tool) { model.tool = tool } label: {
            Image(systemName: tool.symbol)
        }
        .tooltip(Tip(title: tool.title, shortcut: tool.shortcut.uppercased()))
        .accessibilityHint(tool.help)
    }

    private var dragMe: some View {
        Group {
            if let image = model.rendered {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.08)
            }
        }
            .frame(width: 36, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
            .onDrag {
                guard let flat = model.flatten(), let png = ImageOps.png(flat, pointSize: model.pointSize) else {
                    return NSItemProvider()
                }
                let folder = FileManager.default.temporaryDirectory.appending(path: "Navi/\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: CaptureGeometry.fileName(for: .now, fileExtension: "png"))
                try? png.write(to: url)
                let provider = NSItemProvider(object: url as NSURL)
                provider.suggestedName = url.deletingPathExtension().lastPathComponent
                return provider
            }
            .tooltip(Tip(title: "Drag into any app"))
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(.sRGB, red: model.color.red, green: model.color.green, blue: model.color.blue) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                model.color = RGBA(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            }
        )
    }
}

private struct ToolGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 1) { content }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
            .fixedSize()
    }
}

private struct IconButton<Label: View>: View {
    enum Style { case accent, subtle }

    var isOn = false
    var style = Style.accent
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: 7).fill(background))
                .contentShape(Rectangle())
        }
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if isOn { return style == .accent ? .white : .primary }
        return .primary.opacity(isEnabled ? 0.85 : 0.3)
    }

    private var background: Color {
        if isOn { return style == .accent ? .accentColor : .primary.opacity(0.16) }
        return .primary.opacity(isHovered && isEnabled ? 0.08 : 0)
    }
}

private struct ColorWell: View {
    @Bindable var model: AnnotateModel
    @State private var isOpen = false

    static let presets: [RGBA] = [
        .red,
        RGBA(red: 1, green: 0.58, blue: 0),
        RGBA(red: 1, green: 0.8, blue: 0),
        RGBA(red: 0.2, green: 0.78, blue: 0.35),
        RGBA(red: 0, green: 0.48, blue: 1),
        RGBA(red: 0.69, green: 0.32, blue: 0.87),
        RGBA(red: 1, green: 1, blue: 1),
        RGBA(red: 0, green: 0, blue: 0),
    ]

    var body: some View {
        Button { isOpen.toggle() } label: {
            Circle()
                .fill(model.color.swiftUI)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .frame(width: 16, height: 16)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { palette }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 4), spacing: 8) {
                ForEach(Self.presets, id: \.self) { color in
                    Button { model.color = color; isOpen = false } label: {
                        Circle()
                            .fill(color.swiftUI)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                                .opacity(model.color == color ? 1 : 0))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                ColorPicker("More…", selection: Binding(
                    get: { model.color.swiftUI },
                    set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        model.color = RGBA(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                    }
                ), supportsOpacity: false)
                Spacer()
                Button {
                    isOpen = false
                    let model = model
                    NSColorSampler().show { picked in
                        guard let rgb = picked?.usingColorSpace(.sRGB) else { return }
                        let color = RGBA(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                        Task { @MainActor in model.color = color }
                    }
                } label: { Image(systemName: "eyedropper") }
                    .help("Pick a color from the screen")
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 152)
    }
}

private extension RGBA {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

private extension StrokeSize {
    var previewHeight: CGFloat {
        switch self {
        case .small: 1.5
        case .medium: 3
        case .large: 5
        }
    }
}
