import Accelerate
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BackgroundRenderer {
    static func render(_ image: CGImage, style: BackgroundStyle, scale: CGFloat) -> CGImage? {
        var content = image
        if style.autoBalance, let balanced = balanced(image) { content = balanced }
        let contentSize = CGSize(width: content.width, height: content.height)
        let padding = CGFloat(style.padding) * scale
        let size = BackgroundLayout.canvasSize(content: contentSize, padding: padding, ratio: style.aspect.ratio)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(
            x: ((size.width - contentSize.width) / 2).rounded(), y: ((size.height - contentSize.height) / 2).rounded(),
            width: contentSize.width, height: contentSize.height
        )
        let radius = CGFloat(style.cornerRadius) * scale
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let full = CGRect(origin: .zero, size: size)
        let softFill: Bool
        switch style.fill {
        case .gradient, .solid, .none: softFill = true
        case .image: softFill = false
        }
        if !softFill { drawFill(style.fill, in: full, context: context) }
        if softFill || style.shadow {
            let layer = SoftLayer(size: size)
            if softFill { layer.draw { drawFill(style.fill, in: CGRect(origin: .zero, size: size), context: $0) } }
            if style.shadow {
                layer.draw { small in
                    let away = size.width * 2
                    small.setShadow(
                        offset: CGSize(width: -away / SoftLayer.factor, height: -10 * scale / SoftLayer.factor),
                        blur: 40 * scale / SoftLayer.factor, color: CGColor(gray: 0, alpha: 0.45)
                    )
                    small.translateBy(x: away, y: 0)
                    small.addPath(path)
                    small.setFillColor(CGColor(gray: 0, alpha: 1))
                    small.fillPath()
                }
            }
            layer.composite(into: context, replacing: softFill)
        }
        if style.shadow {
            context.saveGState()
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(content, in: rect)
        context.restoreGState()
        return context.makeImage()
    }

    static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * factor).rounded())), height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private final class SoftLayer {
        static let factor: CGFloat = 4
        let size: CGSize
        let context: CGContext?

        init(size: CGSize) {
            self.size = size
            context = CGContext(
                data: nil, width: max(1, Int((size.width / Self.factor).rounded(.up))),
                height: max(1, Int((size.height / Self.factor).rounded(.up))), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }

        func draw(_ body: (CGContext) -> Void) {
            guard let context else { return }
            context.saveGState()
            context.scaleBy(x: 1 / Self.factor, y: 1 / Self.factor)
            body(context)
            context.restoreGState()
        }

        func composite(into target: CGContext, replacing: Bool) {
            guard let context, let small = context.data else { return }
            var source = vImage_Buffer(
                data: small, height: vImagePixelCount(context.height), width: vImagePixelCount(context.width),
                rowBytes: context.bytesPerRow
            )
            if replacing, let data = target.data, target.bitsPerPixel == 32 {
                var destination = vImage_Buffer(
                    data: data, height: vImagePixelCount(target.height), width: vImagePixelCount(target.width),
                    rowBytes: target.bytesPerRow
                )
                vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
                return
            }
            guard var destination = try? vImage_Buffer(
                width: target.width, height: target.height, bitsPerPixel: 32
            ) else { return }
            defer { destination.free() }
            vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
            guard var format = vImage_CGImageFormat(
                bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ), let image = vImageCreateCGImageFromBuffer(
                &destination, &format, nil, nil, vImage_Flags(kvImageNoFlags), nil
            )?.takeRetainedValue() else { return }
            target.draw(image, in: CGRect(origin: .zero, size: size))
        }
    }

    private static func drawFill(_ fill: BackgroundStyle.Fill, in rect: CGRect, context: CGContext) {
        switch fill {
        case .none:
            break
        case let .solid(color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case let .gradient(index):
            let (from, to) = BackgroundStyle.gradients[index % BackgroundStyle.gradients.count]
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1]
            ) else { return }
            context.drawLinearGradient(
                gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: []
            )
        case let .image(path):
            guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return }
            let fill = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * fill, height: CGFloat(image.height) * fill)
            context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    private static func balanced(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let rect = AutoBalance.balancedRect(width: width, height: height) { x, y in
            let index = (y * width + x) * 4
            return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
        }
        return image.cropping(to: rect)
    }
}

@MainActor
final class BackgroundEditor: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onClose: () -> Void

    init(image: CGImage, scale: CGFloat, onApply: @escaping (CGImage) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
        let view = BackgroundView(image: image, scale: scale) { [weak self] result in
            if let result { onApply(result) }
            self?.window?.close()
        }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Background"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
    }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose()
    }
}

private struct BackgroundView: View {
    let image: CGImage
    let scale: CGFloat
    let finish: (CGImage?) -> Void
    private let previewImage: CGImage
    private let previewScale: CGFloat

    init(image: CGImage, scale: CGFloat, finish: @escaping (CGImage?) -> Void) {
        self.image = image
        self.scale = scale
        self.finish = finish
        let factor = min(1, 1600 / CGFloat(max(image.width, image.height)))
        if factor < 1, let small = BackgroundRenderer.scaled(image, by: factor) {
            previewImage = small
            previewScale = scale * CGFloat(small.width) / CGFloat(image.width)
        } else {
            previewImage = image
            previewScale = scale
        }
    }

    @State private var style = BackgroundPresets.last
    @State private var presets = BackgroundPresets.all
    @State private var presetName = ""

    private var rendered: CGImage? { BackgroundRenderer.render(previewImage, style: style, scale: previewScale) }

    var body: some View {
        HStack(spacing: 0) {
            preview
            Divider()
            controls.frame(width: 260)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var preview: some View {
        ZStack {
            Color.black.opacity(0.25)
            if let rendered {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            }
        }
    }

    private var controls: some View {
        Form {
            Section("Background") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 4), spacing: 8) {
                    ForEach(BackgroundStyle.gradients.indices, id: \.self) { index in
                        let (from, to) = BackgroundStyle.gradients[index]
                        swatch(selected: style.fill == .gradient(index)) {
                            LinearGradient(colors: [color(from), color(to)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        } action: { style.fill = .gradient(index) }
                    }
                    swatch(selected: style.fill == .none) {
                        Image(systemName: "nosign").foregroundStyle(.secondary)
                    } action: { style.fill = .none }
                    swatch(selected: { if case .image = style.fill { true } else { false } }()) {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    } action: { pickImage() }
                }
                ColorPicker("Solid color", selection: solidBinding, supportsOpacity: false)
            }
            Section("Layout") {
                LabeledContent("Padding") {
                    Slider(value: $style.padding, in: 0 ... 200)
                }
                LabeledContent("Corners") {
                    Slider(value: $style.cornerRadius, in: 0 ... 40)
                }
                Toggle("Shadow", isOn: $style.shadow)
                Toggle("Auto balance", isOn: $style.autoBalance)
                    .help("Evens out plain margins so the content sits in the middle")
                Picker("Aspect ratio", selection: $style.aspect) {
                    ForEach(BackgroundStyle.Aspect.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Presets") {
                ForEach(presets.keys.sorted(), id: \.self) { name in
                    HStack {
                        Button(name) { if let preset = presets[name] { style = preset } }
                            .buttonStyle(.link)
                        Spacer()
                        Button {
                            BackgroundPresets.delete(name)
                            presets = BackgroundPresets.all
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Preset name", text: $presetName)
                    Button("Save") {
                        let name = presetName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        BackgroundPresets.save(style, as: name)
                        presets = BackgroundPresets.all
                        presetName = ""
                    }
                }
            }
            Section {
                HStack {
                    Button("Cancel") { finish(nil) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Apply") {
                        BackgroundPresets.last = style
                        finish(BackgroundRenderer.render(image, style: style, scale: scale))
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func swatch<Content: View>(
        selected: Bool, @ViewBuilder content: () -> Content, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
    }

    private func color(_ rgba: RGBA) -> Color {
        Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue)
    }

    private var solidBinding: Binding<Color> {
        Binding(
            get: { if case let .solid(rgba) = style.fill { color(rgba) } else { .white } },
            set: { value in
                guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                style.fill = .solid(RGBA(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent))
            }
        )
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        style.fill = .image(url.path)
    }
}
