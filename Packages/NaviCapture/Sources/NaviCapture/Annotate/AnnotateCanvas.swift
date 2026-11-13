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
    @FocusState private var isTyping: Bool

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
                    if let mark = model.selectedMark, model.cropRect == nil {
                        MarkOutline(mark: mark, fit: fit)
                    }
                    if let crop = model.cropRect {
                        cropOverlay(crop, fit: fit, shown: shown)
                    }
                }
                .frame(width: shown.width, height: shown.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(drawGesture(fit: fit))
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        let point = pixel(location, fit: fit)
                        model.pointerMoved(to: point)
                        model.cursor(at: point).set()
                    case .ended:
                        model.pointerMoved(to: nil)
                        NSCursor.arrow.set()
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                    loadDroppedImage(providers)
                    return true
                }
                if let edit = model.textEdit {
                    textField(fit: fit)
                        .task(id: "\(edit.point.x),\(edit.point.y)") { isTyping = true }
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
            }
            .onEnded { value in
                model.pointerUp(from: pixel(value.startLocation, fit: fit), to: pixel(value.location, fit: fit))
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

    private func textField(fit: CGFloat) -> some View {
        let point = model.textEdit?.point ?? .zero
        let fontSize = model.textEditFontSize * fit
        let color = Color(.sRGB, red: model.color.red, green: model.color.green, blue: model.color.blue)
        return TextField("", text: Binding(
            get: { model.textEdit?.text ?? "" },
            set: { model.textEdit?.text = $0 }
        ), axis: .vertical)
            .textFieldStyle(.plain)
            .focused($isTyping)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.clear)
            .tint(color)
            .frame(minWidth: 120, maxWidth: 400, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1).padding(-3))
            .offset(x: point.x * fit, y: point.y * fit)
            .onSubmit(model.finishText)
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

private struct MarkOutline: View {
    let mark: Annotation
    let fit: CGFloat

    var body: some View {
        let lineGap = mark.isBox ? CGFloat(mark.lineWidth) / 2 * fit + 3 : 6
        let outline = (mark.isBox ? mark.box : mark.bounds)
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
        guard mark.isBox else {
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
