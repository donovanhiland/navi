import AppKit
import NaviCore
import Vision

enum TextRecognizer {
    private static let warmedKey = "capture.textModelWarmedFor"

    static func prewarmIfNeeded(defaults: UserDefaults = .standard) {
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        guard defaults.string(forKey: warmedKey) != build else { return }
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(20))
            guard let image = await warmUpImage() else { return }
            try? VNImageRequestHandler(cgImage: image).perform([request()])
            UserDefaults.standard.set(build, forKey: warmedKey)
        }
    }

    @MainActor
    static func warmUpImage() -> CGImage? {
        let width = 1600, height = 1000
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let words = [
            "Done", "Manage", "View all", "Clear", "Settings", "Report 2", "Role and Use Cases",
            "The quick brown fox jumps over the lazy dog.", "PRD-46F51QS", "5h", "7h ago", "GitHub Email and Mail",
            "Learning Knowledge", "https://example.com/a?b=1", "1.", "2.", "func capture() -> CGImage?",
        ]
        let sizes: [CGFloat] = [11, 13, 15, 17, 22, 28]
        let gaps = [24, 30, 38, 44]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var y = height - 40, line = 0
        while y > 20 {
            for column in 0 ..< 2 {
                let word = words[(line + column * 5) % words.count] as NSString
                word.draw(at: CGPoint(x: column * width / 2 + 24 + (line % 4) * 30, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: sizes[line % sizes.count], weight: line % 3 == 0 ? .semibold : .regular),
                    .foregroundColor: column == 0 ? NSColor.black : NSColor(white: 0.85, alpha: 1),
                ])
            }
            y -= gaps[line % gaps.count]
            line += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func request() -> VNRecognizeTextRequest {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        return text
    }

    static func recognize(_ image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let text = request()
            let codes = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            try? handler.perform([text, codes])
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
            return joined(lines: lines, payloads: payloads)
        }.value
    }

    static func joined(lines: [String], payloads: [String]) -> String {
        var seen = Set<String>()
        return (lines + payloads).filter { seen.insert($0).inserted }.joined(separator: "\n")
    }
}

@MainActor
enum NaviPasteboardBridge {
    static func write(_ image: NSImage) {
        NaviPasteboard.write(image: image)
    }

    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NaviPasteboard.ownType)
    }
}

@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ message: String, on screen: NSScreen? = NSScreen.underMouse) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        let size = CGSize(width: min(label.intrinsicContentSize.width + 32, 520), height: 34)
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let panel = NSPanel(
            contentRect: CGRect(x: visible.midX - size.width / 2, y: visible.minY + 60, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = size.height / 2
        label.frame = CGRect(x: 16, y: (size.height - 18) / 2, width: size.width - 32, height: 18)
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard Self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            }
        }
    }
}
