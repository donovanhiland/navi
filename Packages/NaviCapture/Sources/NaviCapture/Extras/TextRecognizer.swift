import AppKit
import NaviCore
import Vision

enum TextRecognizer {
    static func recognize(_ image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
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
