import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnotateCanvas: View {
    enum Layout {
        case fitted
        case actualSize
    }

    @Bindable var model: AnnotateModel
    let layout: Layout
    var setsHoverCursor = true

    var body: some View {
        GeometryReader { proxy in
            let pixels = model.pixelSize
            let fit = fit(in: proxy.size, pixels: pixels)
            let shown = CGSize(width: pixels.width * fit, height: pixels.height * fit)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let image = model.rendered {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: shown.width, height: shown.height)
                            .shadow(color: .black.opacity(layout == .fitted ? 0.25 : 0), radius: 12, y: 4)
                    }
                    if let patch = model.patch {
                        Image(decorative: patch.image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: patch.rect.width * fit, height: patch.rect.height * fit)
                            .offset(x: patch.rect.minX * fit, y: patch.rect.minY * fit)
                    }
                    if let mark = model.selectedMark, model.cropRect == nil, model.textEdit == nil {
                        MarkOutline(mark: mark, fit: fit)
                    }
                    if let crop = model.cropRect {
                        cropOverlay(crop, fit: fit, shown: shown)
                    }
                }
                .frame(width: shown.width, height: shown.height, alignment: .topLeading)
                .contentShape(HandleReach(spots: model.handleSpots.map { CGPoint(x: $0.x * fit, y: $0.y * fit) }))
                .gesture(drawGesture(fit: fit))
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        let point = pixel(location, fit: fit)
                        model.pointerMoved(to: point)
                        if setsHoverCursor { model.pointer(at: point).cursor.set() }
                    case .ended:
                        model.pointerMoved(to: nil)
                        if setsHoverCursor { NSCursor.arrow.set() }
                    }
                }
                .onChange(of: model.tool) { model.hoverPointer?.cursor.set() }
                .onChange(of: model.selection) { model.hoverPointer?.cursor.set() }
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                    loadDroppedImage(providers)
                    return true
                }
                if let edit = model.textEdit, let frame = model.editingFrame {
                    textBox(edit, frame: frame, fit: fit)
                }
            }
            .frame(width: shown.width, height: shown.height, alignment: .topLeading)
            .frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: layout == .fitted ? .center : .topLeading
            )
        }
    }

    private func fit(in size: CGSize, pixels: CGSize) -> CGFloat {
        switch layout {
        case .actualSize:
            1 / model.scale
        case .fitted:
            min(1 / model.scale, (size.width - 40) / pixels.width, (size.height - 40) / pixels.height)
        }
    }

    private func drawGesture(fit: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = pixel(value.startLocation, fit: fit)
                let point = pixel(value.location, fit: fit)
                if value.translation == .zero {
                    model.pointerDown(at: start)
                } else {
                    model.pointerDragged(from: start, to: point)
                }
                model.dragPointer(at: point).cursor.set()
            }
            .onEnded { value in
                let end = pixel(value.location, fit: fit)
                model.pointerUp(from: pixel(value.startLocation, fit: fit), to: end)
                model.pointerMoved(to: end)
                model.pointer(at: end).cursor.set()
            }
    }

    private func pixel(_ point: CGPoint, fit: CGFloat) -> CGPoint {
        CGPoint(x: point.x / fit, y: point.y / fit)
    }

    private func cropOverlay(_ crop: CGRect, fit: CGFloat, shown: CGSize) -> some View {
        let rect = CGRect(x: crop.minX * fit, y: crop.minY * fit, width: crop.width * fit, height: crop.height * fit)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: shown))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.white)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            HStack(spacing: 6) {
                Button("Cancel", action: model.cancelCrop)
                Button("Crop", action: model.applyCrop)
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .offset(x: rect.minX, y: min(rect.maxY + 6, shown.height - 26))
        }
    }

    private func textBox(_ edit: AnnotateModel.TextEdit, frame: CGRect, fit: CGFloat) -> some View {
        let caret = edit.fontSize * 0.25
        let size = CGSize(width: (frame.width + caret) * fit, height: frame.height * fit)
        return TextBoxView(
            model: model, text: edit.text, fontSize: edit.fontSize, color: edit.color,
            wrap: edit.width ?? model.textWrapLimit, fit: fit,
            size: CGSize(width: frame.width + caret, height: frame.height)
        )
            .id(edit.session)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(-4)
                    .allowsHitTesting(false)
            )
            .padding(.leading, frame.minX * fit)
            .padding(.top, frame.minY * fit)
    }

    private func loadDroppedImage(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                    guard let url = url as? URL else { return }
                    Task { @MainActor in
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                        else { return }
                        model.addImage(image)
                    }
                }
                return
            }
        }
    }
}

struct HandleReach: Shape {
    static let radius: CGFloat = 10
    let spots: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for spot in spots {
            path.addEllipse(in: CGRect(
                x: spot.x - Self.radius, y: spot.y - Self.radius, width: Self.radius * 2, height: Self.radius * 2
            ))
        }
        return path
    }
}

private struct MarkOutline: View {
    let mark: Annotation
    let fit: CGFloat

    var body: some View {
        let lineGap = mark.isBox ? CGFloat(mark.lineWidth) / 2 * fit + 3 : (mark.kind == .text ? 4 : 6)
        let outline = (mark.hasFrame ? mark.box : mark.bounds)
            .applying(CGAffineTransform(scaleX: fit, y: fit))
            .insetBy(dx: -lineGap, dy: -lineGap)
        ZStack(alignment: .topLeading) {
            if mark.kind != .arrow, mark.kind != .line {
                Rectangle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .frame(width: outline.width, height: outline.height)
                    .offset(x: outline.minX, y: outline.minY)
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: outline.width, height: outline.height)
                    .offset(x: outline.minX, y: outline.minY)
            }
            ForEach(mark.handles, id: \.self) { handle in
                let point = handlePoint(handle, outline: outline)
                let size: CGFloat = handle.isEdge ? 7 : 9
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: size, height: size)
                    .offset(x: point.x - size / 2, y: point.y - size / 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func handlePoint(_ handle: Annotation.Handle, outline: CGRect) -> CGPoint {
        guard mark.hasFrame else {
            let point = mark.point(of: handle)
            return CGPoint(x: point.x * fit, y: point.y * fit)
        }
        let mark = mark.point(of: handle)
        let box = self.mark.box
        let x = mark.x < box.midX - 0.5 ? outline.minX : (mark.x > box.midX + 0.5 ? outline.maxX : outline.midX)
        let y = mark.y < box.midY - 0.5 ? outline.minY : (mark.y > box.midY + 0.5 ? outline.maxY : outline.midY)
        return CGPoint(x: x, y: y)
    }
}

private struct TextBoxView: NSViewRepresentable {
    let model: AnnotateModel
    let text: String
    let fontSize: Double
    let color: RGBA
    let wrap: Double
    let fit: CGFloat
    let size: CGSize

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TextBoxHost {
        let host = TextBoxHost()
        host.textView.delegate = context.coordinator
        return host
    }

    func updateNSView(_ host: TextBoxHost, context: Context) {
        host.update(text: text, fontSize: fontSize, color: color, wrap: wrap, size: size, fit: fit)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: AnnotateModel

        init(model: AnnotateModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, model.textEdit != nil,
                  !textView.hasMarkedText()
            else { return }
            model.textEdit?.text = textView.string
        }
    }
}

final class TextBoxHost: NSView {
    let textView: NSTextView
    private var fit: CGFloat = 1
    private var style: (Double, RGBA)?

    override init(frame: NSRect) {
        textView = NSTextView(usingTextLayoutManager: false)
        super.init(frame: frame)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        addSubview(textView)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(textView)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self.textView else { return }
            window.makeFirstResponder(self.textView)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScale()
    }

    func update(text: String, fontSize: Double, color: RGBA, wrap: Double, size: CGSize, fit: CGFloat) {
        if self.fit != fit {
            self.fit = fit
            applyScale()
        }
        textView.textContainer?.size = CGSize(width: max(1, wrap), height: TextLayout.unbounded)
        textView.frame = CGRect(origin: .zero, size: size)
        if textView.string != text, !textView.hasMarkedText() { textView.string = text }
        if style.map({ $0.0 != fontSize || $0.1 != color }) ?? true {
            style = (fontSize, color)
            let attributes = TextLayout.attributes(fontSize: fontSize, color: color)
            textView.typingAttributes = attributes
            textView.insertionPointColor = NSColor(cgColor: color.cgColor) ?? .red
        }
        let attributes = textView.typingAttributes
        if let storage = textView.textStorage, storage.length > 0, !textView.hasMarkedText() {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    private func applyScale() {
        guard fit > 0 else { return }
        setBoundsSize(NSSize(width: frame.width / fit, height: frame.height / fit))
    }
}
