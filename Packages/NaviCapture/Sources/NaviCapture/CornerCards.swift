import AppKit
import Carbon.HIToolbox
import NaviCore
import SwiftUI

@MainActor
@Observable
final class Card: Identifiable {
    let id = UUID()
    let inboxID: UUID?
    private(set) var image: NSImage
    private(set) var thumbnail: NSImage
    private(set) var png: Data
    let createdAt: Date
    private(set) var dragURL: URL
    var savedURL: URL?
    private(set) var video: VideoInfo?

    struct VideoInfo {
        var mp4: URL
        var gif: URL?
        var showsGIF = false
        var duration: TimeInterval
        var current: URL { showsGIF ? (gif ?? mp4) : mp4 }
    }

    private var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Navi/\(id.uuidString)", directoryHint: .isDirectory)
    }

    init(inboxID: UUID?, image: NSImage, png: Data, createdAt: Date, video: VideoInfo? = nil) throws {
        self.inboxID = inboxID
        self.image = image
        thumbnail = Self.thumbnail(of: image)
        self.png = png
        self.createdAt = createdAt
        self.video = video
        dragURL = URL(filePath: "/")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeDragFile()
    }

    func update(image: NSImage, png: Data) {
        self.image = image
        thumbnail = Self.thumbnail(of: image)
        self.png = png
        savedURL = nil
        try? writeDragFile()
    }

    func update(video: VideoInfo) {
        self.video = video
        savedURL = nil
        try? writeDragFile()
    }

    var isVideo: Bool { video != nil }
    var fileExtension: String { video.map { $0.showsGIF ? "gif" : "mp4" } ?? "png" }

    private func writeDragFile() throws {
        let url = folder.appending(path: CaptureGeometry.fileName(for: createdAt, fileExtension: fileExtension))
        if url != dragURL, dragURL.path != "/" { try? FileManager.default.removeItem(at: dragURL) }
        dragURL = url
        try? FileManager.default.removeItem(at: url)
        if let video {
            try FileManager.default.copyItem(at: video.current, to: url)
        } else {
            try png.write(to: url, options: .atomic)
        }
    }

    private static func thumbnail(of image: NSImage) -> NSImage {
        let limit = CGSize(width: CardStack.cardSize.width * 3, height: CardStack.cardSize.height * 3)
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let factor = min(limit.width / CGFloat(source.width), limit.height / CGFloat(source.height))
        guard factor < 1 else { return image }
        let width = max(1, Int(CGFloat(source.width) * factor))
        let height = max(1, Int(CGFloat(source.height) * factor))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return image }
        return NSImage(cgImage: small, size: image.size)
    }

    var cgImage: CGImage? { image.cgImage(forProposedRect: nil, context: nil, hints: nil) }

    var scale: CGFloat {
        guard let cgImage, image.size.width > 0 else { return 1 }
        return CGFloat(cgImage.width) / image.size.width
    }
}

struct CardActions {
    let copy: (Card) -> Void
    let save: (Card) -> Void
    let showInFinder: (Card) -> Void
    let close: (Card) -> Void
    let closeAll: () -> Void
    let annotate: (Card) -> Void
    let pin: (Card) -> Void
    let copyText: (Card) -> Void
    let background: (Card) -> Void
    let trim: (Card) -> Void
    let setGIF: (Card, Bool) -> Void
}

@MainActor
final class CardStack {
    static let cardSize = CGSize(width: 220, height: 140)
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 10

    private var entries: [(card: Card, panel: NSPanel, screen: NSScreen?)] = []

    func card(forInboxID id: UUID) -> Card? {
        entries.first { $0.card.inboxID == id }?.card
    }
    private var timers: [UUID: Timer] = [:]
    private var hovered: Set<UUID> = []
    private var cardKeys: [HotKey] = []
    private var cardKeysOwner: UUID?
    var actions: CardActions?
    var autoCloseSeconds: () -> Double = { 0 }

    func show(_ card: Card, on screen: NSScreen?) {
        let panel = CardPanel(size: Self.cardSize)
        let view = CornerCardView(card: card, actions: actions) { [weak self] isHovering in
            self?.hoverChanged(card, isHovering)
        }
        panel.contentView = FirstMouseHostingView(rootView: view)
        entries.append((card, panel, screen ?? NSScreen.main))
        layout(animated: false)
        slideIn(panel)
        scheduleAutoClose(card)
    }

    func close(_ card: Card) {
        guard let index = entries.firstIndex(where: { $0.card.id == card.id }) else { return }
        let panel = entries.remove(at: index).panel
        timers.removeValue(forKey: card.id)?.invalidate()
        hovered.remove(card.id)
        if cardKeysOwner == card.id { removeCardKeys() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            var frame = panel.frame
            frame.origin.x -= Self.cardSize.width + Self.margin
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
        layout(animated: true)
    }

    func closeAll() {
        for entry in entries.reversed() { close(entry.card) }
    }

    private func slideIn(_ panel: NSPanel) {
        let target = panel.frame
        let overshoot: CGFloat = 10
        var start = target
        start.origin.x -= target.width + Self.margin
        var past = target
        past.origin.x += overshoot
        panel.setFrame(start, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(past, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(target, display: true)
                }
            }
        }
    }

    private func layout(animated: Bool) {
        var countOnScreen: [ObjectIdentifier: Int] = [:]
        for entry in entries {
            let screen = entry.screen.flatMap { NSScreen.screens.contains($0) ? $0 : nil } ?? NSScreen.main
            let key = screen.map(ObjectIdentifier.init) ?? ObjectIdentifier(NSScreen.self)
            let index = countOnScreen[key, default: 0]
            countOnScreen[key] = index + 1
            let visible = screen?.visibleFrame ?? .zero
            let origin = CGPoint(
                x: visible.minX + Self.margin,
                y: visible.minY + Self.margin + CGFloat(index) * (Self.cardSize.height + Self.gap)
            )
            let frame = CGRect(origin: origin, size: Self.cardSize)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    entry.panel.animator().setFrame(frame, display: true)
                }
            } else {
                entry.panel.setFrame(frame, display: true)
            }
        }
    }

    private func hoverChanged(_ card: Card, _ isHovering: Bool) {
        if isHovering { hovered.insert(card.id) } else { hovered.remove(card.id) }
        if isHovering {
            addCardKeys(for: card)
        } else if cardKeysOwner == card.id {
            removeCardKeys()
        }
        if !isHovering { scheduleAutoClose(card) }
    }

    private func addCardKeys(for card: Card) {
        removeCardKeys()
        guard let actions else { return }
        let command = UInt32(cmdKey)
        cardKeysOwner = card.id
        cardKeys = [
            HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: command) { actions.copy(card) },
            HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: command) { actions.save(card) },
            HotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: command) { actions.close(card) },
            HotKey(keyCode: UInt32(kVK_ANSI_E), modifiers: command) {
                card.isVideo ? actions.trim(card) : actions.annotate(card)
            },
            HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: command) { if !card.isVideo { actions.pin(card) } },
        ].compactMap(\.self)
    }

    private func removeCardKeys() {
        for key in cardKeys { key.unregister() }
        cardKeys = []
        cardKeysOwner = nil
    }

    private func scheduleAutoClose(_ card: Card) {
        timers.removeValue(forKey: card.id)?.invalidate()
        let seconds = autoCloseSeconds()
        guard seconds > 0 else { return }
        timers[card.id] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovered.contains(card.id) else { return }
                self.close(card)
            }
        }
    }
}

final class CardPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct CornerCardView: View {
    let card: Card
    let actions: CardActions?
    let onHover: (Bool) -> Void

    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        ZStack {
            Color(white: 0.16)
            Image(nsImage: card.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .blur(radius: isHovering ? 8 : 0)
            if let video = card.video, !isHovering {
                Text(Self.duration(video.duration) + (video.showsGIF ? "  GIF" : ""))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
            }
            if isHovering { hoverLayer.transition(.opacity) }
        }
        .frame(width: CardStack.cardSize.width, height: CardStack.cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            onHover(hovering)
        }
        .onDrag {
            let provider = NSItemProvider(object: card.dragURL as NSURL)
            provider.suggestedName = card.dragURL.deletingPathExtension().lastPathComponent
            return provider
        }
        .contextMenu {
            if let video = card.video {
                Button("Trim…") { actions?.trim(card) }
                Button(video.showsGIF ? "Use MP4" : "Convert to GIF") { actions?.setGIF(card, !video.showsGIF) }
            } else {
                Button("Annotate") { actions?.annotate(card) }
                Button("Pin to Screen") { actions?.pin(card) }
                Button("Copy Text") { actions?.copyText(card) }
                Button("Background…") { actions?.background(card) }
            }
            Divider()
            Button("Show in Finder") { actions?.showInFinder(card) }
            Button("Close") { actions?.close(card) }
            Button("Close All Cards") { actions?.closeAll() }
        }
    }

    private var hoverLayer: some View {
        ZStack {
            Color.white.opacity(0.15)
            VStack(spacing: 6) {
                bigButton(copied ? "Copied" : "Copy") {
                    actions?.copy(card)
                    copied = true
                }
                bigButton("Save") { actions?.save(card) }
                if let video = card.video {
                    HStack(spacing: 4) {
                        formatButton("MP4", on: !video.showsGIF) { actions?.setGIF(card, false) }
                        formatButton("GIF", on: video.showsGIF) { actions?.setGIF(card, true) }
                    }
                }
            }
            VStack {
                HStack {
                    if !card.isVideo {
                        cornerButton("pin", help: "Pin to screen (⌘P)") { actions?.pin(card) }
                    }
                    Spacer()
                    cornerButton("xmark", help: "Close (⌘W)") { actions?.close(card) }
                }
                Spacer()
                HStack {
                    if card.isVideo {
                        cornerButton("scissors", help: "Trim (⌘E)") { actions?.trim(card) }
                    } else {
                        cornerButton("pencil.tip", help: "Annotate (⌘E)") { actions?.annotate(card) }
                    }
                    Spacer()
                    cornerButton("folder", help: "Show in Finder") { actions?.showInFinder(card) }
                }
            }
            .padding(6)
        }
    }

    private func formatButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.black : .white)
                .frame(width: 40, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white : .white.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 84, height: 26)
                .background(Capsule().fill(.white.opacity(0.92)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func cornerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.85)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
