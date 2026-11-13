import AVFoundation
import AppKit
import NaviCore
import ScreenCaptureKit
import os

public enum CaptureRegion: Sendable {
    case display(CGDirectDisplayID)
    case area(CGDirectDisplayID, CGRect)
    case window(CGWindowID)
}

public struct VideoTools {
    public var trim: @MainActor (URL) async -> URL?
    public var makeGIF: @MainActor (URL) async throws -> URL

    public init(trim: @escaping @MainActor (URL) async -> URL?, makeGIF: @escaping @MainActor (URL) async throws -> URL) {
        self.trim = trim
        self.makeGIF = makeGIF
    }
}

@MainActor
public final class CaptureFeature {
    public let settings: CaptureSettings
    public var onRecordRequest: ((CaptureRegion) -> Void)?
    public var videoTools: VideoTools?

    private let inbox: Inbox
    private let cards = CardStack()
    private let pins = PinBoard()
    private var session: SelectionSession?
    private var scrollSession: ScrollCaptureSession?
    private var inPlaceEditor: InPlaceAnnotator?
    private var editorStage: InPlaceAnnotator.Stage?
    private var frozenScreens: [(NSScreen, CapturedImage)] = []
    private var editors: [UUID: AnyObject] = [:]
    private var isBusy = false
    private var copiesNextShot = false
    private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Capture")

    public init(inbox: Inbox, settings: CaptureSettings = CaptureSettings()) {
        self.inbox = inbox
        self.settings = settings
        cards.autoCloseSeconds = { [weak settings] in settings?.autoCloseSeconds ?? 0 }
        cards.actions = CardActions(
            copy: { [weak self] in self?.copy($0) },
            save: { [weak self] in self?.save($0, thenClose: true) },
            showInFinder: { [weak self] in self?.showInFinder($0) },
            close: { [weak self] in self?.cards.close($0) },
            closeAll: { [weak self] in self?.cards.closeAll() },
            annotate: { [weak self] in self?.annotate($0) },
            pin: { [weak self] in self?.pin($0) },
            copyText: { [weak self] in self?.copyText(from: $0) },
            background: { [weak self] in self?.openBackground($0) },
            trim: { [weak self] in self?.trim($0) },
            setGIF: { [weak self] in self?.setGIF($0, $1) }
        )
        if Self.hasScreenAccess { ScreenGrabber.prewarm() }
        TextRecognizer.prewarmIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = NSColorPanel.shared }
        prepareAhead(after: 2.5)
    }

    public static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    public static func requestScreenAccess(openSettings: Bool = true) {
        Task { @MainActor in
            _ = CGRequestScreenCaptureAccess()
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard openSettings, !CGPreflightScreenCaptureAccess(),
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    public func captureArea() { startSelection(.area, purpose: .screenshot) }

    public func captureAreaToClipboard() {
        copiesNextShot = true
        startSelection(.area, purpose: .screenshot)
    }

    public func captureFullscreenToClipboard() {
        copiesNextShot = true
        captureFullscreen()
    }

    public func captureWindow() { startSelection(.window, purpose: .screenshot) }

    public func captureAllInOne() { startSelection(.area, purpose: .screenshot, modeBar: true) }

    public func captureText() { startSelection(.area, purpose: .text) }

    public func captureScrolling() { startSelection(.area, purpose: .scroll) }

    public func captureArea(timer seconds: Int) { startSelection(.area, purpose: .screenshot, timer: seconds) }

    public func pickRecordingRegion() { startSelection(.area, purpose: .record) }

    public func captureFullscreen() {
        guard begin() else {
            copiesNextShot = false
            return
        }
        guard let screen = NSScreen.underMouse else {
            isBusy = false
            copiesNextShot = false
            return
        }
        captureFullscreen(on: screen, timer: 0, sourceApp: NSWorkspace.shared.frontmostApplication)
    }

    public func closeAllCards() { cards.closeAll() }

    public static func showMessage(_ message: String) { Toast.show(message) }

    public var hasPins: Bool { !pins.isEmpty }

    public func unlockPins() { pins.unlockAll() }

    public func closeAllPins() { pins.closeAll() }

    public func showRecording(url: URL, videoURL: URL, isGIF: Bool, duration: TimeInterval) {
        Task {
            let thumbnail = await Self.thumbnail(of: videoURL)
            let item: CaptureItem? = (try? Data(contentsOf: videoURL)).flatMap { data in
                inbox.add(fileData: data, fileExtension: "mp4", kind: .recording, sourceApp: "Navi", deduplicate: false)
            }
            let size = thumbnail.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 320, height: 200)
            let image = thumbnail.map { Self.image($0, pointSize: size) } ?? NSImage(size: size)
            let png = thumbnail.flatMap { ImageOps.png($0, pointSize: size) } ?? Data()
            if let id = item?.id, !png.isEmpty { try? png.write(to: inbox.previewURL(for: id), options: .atomic) }
            let video = Card.VideoInfo(mp4: videoURL, gif: isGIF ? url : nil, showsGIF: isGIF, duration: duration)
            do {
                let card = try Card(inboxID: item?.id, image: image, png: png, createdAt: .now, video: video)
                cards.show(card, on: NSScreen.underMouse)
            } catch {
                logger.error("Could not make the recording card: \(error.localizedDescription)")
            }
        }
    }

    private static func thumbnail(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 880, height: 560)
        return try? await generator.image(at: .zero).image
    }

    private func begin() -> Bool {
        guard !isBusy else { return false }
        guard Self.hasScreenAccess else {
            Self.requestScreenAccess()
            return false
        }
        isBusy = true
        return true
    }

    private func startSelection(
        _ mode: SelectionSession.Mode, purpose: SelectionSession.Purpose, modeBar: Bool = false, timer: Int = 0
    ) {
        if purpose == .record, onRecordRequest == nil { return }
        CaptureTiming.start("select")
        guard begin() else {
            copiesNextShot = false
            return
        }
        let freeze = PendingFreeze()
        let fastFreeze = ScreenGrabber.startFreeze(hideDesktopIcons: settings.hideDesktopIcons) { [weak self] screens in
            self?.frozeFast(screens, freeze)
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let listing = Task.detached(priority: .userInitiated) { ScreenGrabber.onScreenWindows(primaryHeight: primaryHeight) }
        let session = SelectionSession(screens: NSScreen.screens, mode: mode, windows: []) { [weak self] outcome in
            guard let self else { return }
            let session = self.session
            selectionEnded(
                outcome, purpose: session?.purpose ?? purpose, timer: session?.timer ?? timer, previousApp: previousApp
            )
        }
        Task { [weak session] in
            let windows = await listing.value
            session?.updateWindows(windows)
        }
        session.purpose = purpose
        session.timer = timer
        session.showsModeBar = modeBar
        session.holdsSelection = modeBar
        session.canRecord = onRecordRequest != nil
        session.keepsOverlayUntilDone = purpose == .screenshot && timer == 0 && settings.editAfterCapture
        self.session = session
        freeze.session = session
        CaptureTiming.mark("select", "session made")
        session.begin(revealAfterFreeze: fastFreeze)
        CaptureTiming.mark("select", "overlay set up")
        if !fastFreeze { freezeSlowly(session) }
    }

    private func prepareAhead(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, session == nil else { return }
            cards.prepare()
            guard settings.editAfterCapture, let screen = NSScreen.underMouse ?? NSScreen.main else { return }
            if editorStage?.screen != screen { editorStage = InPlaceAnnotator.Stage(screen: screen) }
        }
    }

    @MainActor
    private final class PendingFreeze {
        weak var session: SelectionSession?
    }

    private func frozeFast(_ screens: [(NSScreen, CapturedImage)]?, _ freeze: PendingFreeze) {
        guard let session = freeze.session, session === self.session else { return }
        guard let screens else {
            freezeSlowly(session)
            return
        }
        frozenScreens = screens
        session.freeze(screens)
        CaptureTiming.mark("select", "frozen screen ready")
    }

    private func freezeSlowly(_ session: SelectionSession) {
        Task { [weak self, weak session] in
            guard let self else { return }
            do {
                let screens = try await ScreenGrabber.captureAllScreens(hideDesktopIcons: settings.hideDesktopIcons)
                guard let session else { return }
                frozenScreens = screens
                session.freeze(screens)
                CaptureTiming.mark("select", "frozen screen ready")
            } catch {
                logger.error("Could not freeze the screen: \(error.localizedDescription)")
                session?.finish(.cancelled)
            }
        }
    }

    private func selectionEnded(
        _ outcome: SelectionSession.Outcome, purpose: SelectionSession.Purpose, timer: Int, previousApp: NSRunningApplication?
    ) {
        CaptureTiming.mark("shot", "selection ended")
        session = nil
        prepareAhead(after: 1)
        let frozen = frozenScreens
        frozenScreens = []
        if case let (.area(captured, screen, rect), .screenshot) = (outcome, purpose), timer == 0, settings.editAfterCapture {
            let backdrop = frozen.first { $0.0 == screen }?.1.image
            editInPlace(captured, backdrop: backdrop, on: screen, rect: rect, sourceApp: previousApp)
            return
        }
        previousApp?.activate()
        switch (outcome, purpose) {
        case (.cancelled, _):
            isBusy = false
            copiesNextShot = false

        case let (.fullscreen(screen), .record):
            isBusy = false
            if let id = screen.displayID { onRecordRequest?(.display(id)) }
        case let (.fullscreen(screen), _):
            captureFullscreen(on: screen, timer: timer, sourceApp: previousApp)

        case let (.area(_, screen, rect), .record):
            isBusy = false
            if let id = screen.displayID { onRecordRequest?(.area(id, rect)) }
        case let (.window(id, _), .record):
            isBusy = false
            onRecordRequest?(.window(id))

        case let (.area(captured, screen, _), .text):
            isBusy = false
            Task { await copyText(captured.image, on: screen) }

        case let (.area(_, screen, rect), .scroll):
            startScrolling(on: screen, rect: rect, sourceApp: previousApp)

        case let (.area(captured, screen, rect), .screenshot):
            guard timer > 0 else {
                isBusy = false
                deliver(captured, on: screen, sourceApp: previousApp)
                return
            }
            Task {
                defer { isBusy = false }
                await Countdown.run(seconds: timer, on: screen)
                do {
                    let live = try await ScreenGrabber.capture(screen, rect: rect, hideDesktopIcons: settings.hideDesktopIcons)
                    deliver(live, on: screen, sourceApp: previousApp)
                } catch {
                    logger.error("Timer capture failed: \(error.localizedDescription)")
                }
            }

        case let (.window(id, screen), _):
            Task {
                defer { isBusy = false }
                await Self.waitUntilActive(previousApp)
                await Countdown.run(seconds: timer, on: screen)
                do {
                    let captured = try await ScreenGrabber.captureWindow(id: id)
                    deliver(captured, on: screen, sourceApp: previousApp)
                } catch {
                    logger.error("Window capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func waitUntilActive(_ app: NSRunningApplication?) async {
        guard let app else { return }
        for _ in 0 ..< 15 {
            if app.isActive { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func captureFullscreen(on screen: NSScreen, timer: Int, sourceApp: NSRunningApplication?) {
        Task {
            defer { isBusy = false }
            await Countdown.run(seconds: timer, on: screen)
            do {
                let captured = try await ScreenGrabber.capture(screen, hideDesktopIcons: settings.hideDesktopIcons)
                ScreenFlash.show(captured, on: screen)
                deliver(captured, on: screen, sourceApp: sourceApp)
            } catch {
                logger.error("Fullscreen capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func startScrolling(on screen: NSScreen, rect: CGRect, sourceApp: NSRunningApplication?) {
        let scroll = ScrollCaptureSession(screen: screen, rect: rect, hideDesktopIcons: settings.hideDesktopIcons) {
            [weak self] image, scale in
            guard let self else { return }
            scrollSession = nil
            isBusy = false
            if let image { deliver(CapturedImage(image: image, scale: scale), on: screen, sourceApp: sourceApp) }
        }
        scrollSession = scroll
        scroll.begin()
    }

    private func editInPlace(
        _ captured: CapturedImage, backdrop: CGImage?, on screen: NSScreen, rect: CGRect, sourceApp: NSRunningApplication?
    ) {
        let editor = InPlaceAnnotator(captured: captured, backdrop: backdrop, screen: screen, area: rect) { [weak self] result in
            guard let self else { return }
            inPlaceEditor = nil
            isBusy = false
            sourceApp?.activate()
            if let (action, result) = result {
                deliverEdited(result, action: action, on: screen, sourceApp: sourceApp)
            } else {
                copiesNextShot = false
            }
        }
        inPlaceEditor = editor
        let stage = editorStage
        editorStage = nil
        editor.show(on: stage)
    }

    private func deliverEdited(
        _ result: AnnotateEditor.Result, action: InPlaceAnnotator.Action, on screen: NSScreen, sourceApp: NSRunningApplication?
    ) {
        copiesNextShot = false
        let image = Self.image(result.flat, pointSize: result.pointSize)
        if action == .copy {
            NaviPasteboard.write(image: image)
            Toast.show("Copied", on: screen)
        }
        guard let png = ImageOps.png(result.flat, pointSize: result.pointSize) else {
            logger.error("Could not encode the edited capture as PNG")
            return
        }
        let item = inbox.add(
            fileData: png, fileExtension: "png", kind: .screenshot,
            sourceApp: sourceApp?.localizedName, sourceBundleID: sourceApp?.bundleIdentifier, deduplicate: false
        )
        if let id = item?.id {
            do {
                try MarkupStore.save(base: result.base, document: result.document, to: inbox.markupURL(for: id))
            } catch {
                logger.error("Could not save the markup: \(error.localizedDescription)")
            }
        }
        switch action {
        case .copy:
            break
        case .save:
            let createdAt = Date.now
            let folder = settings.saveFolder
            let url = CaptureGeometry.uniqueURL(
                in: folder, name: CaptureGeometry.fileName(for: createdAt, fileExtension: "png")
            ) { FileManager.default.fileExists(atPath: $0.path) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
                Toast.show("Saved to \(folder.lastPathComponent)", on: screen)
            } catch {
                logger.error("Could not save the capture: \(error.localizedDescription)")
                NSSound.beep()
            }
        case .stash:
            Toast.show("Stashed. ⇧⌘V to find it", on: screen)
        }
    }

    private func deliver(_ captured: CapturedImage, on screen: NSScreen, sourceApp: NSRunningApplication?) {
        let pointSize = CGSize(
            width: CGFloat(captured.image.width) / captured.scale,
            height: CGFloat(captured.image.height) / captured.scale
        )
        let started = ContinuousClock.now
        let image = captured.image
        let encoding = Task.detached(priority: .userInitiated) {
            ImageOps.png(image, pointSize: pointSize)
        }
        let copies = copiesNextShot || settings.copyToClipboard
        copiesNextShot = false
        Task {
            let encoded = await encoding.value
            defer { if copies { NaviPasteboard.write(image: Self.image(image, pointSize: pointSize)) } }
            guard let png = encoded else {
                logger.error("Could not encode the capture as PNG")
                return
            }
            let item = inbox.add(
                fileData: png, fileExtension: "png", kind: .screenshot,
                sourceApp: sourceApp?.localizedName, sourceBundleID: sourceApp?.bundleIdentifier, deduplicate: false
            )
            do {
                let card = try Card(inboxID: item?.id, image: Self.image(image, pointSize: pointSize), png: png, createdAt: .now)
                cards.show(card, on: screen)
                CaptureTiming.markOnScreen("shot", "card shown")
            } catch {
                logger.error("Could not make the corner card: \(error.localizedDescription)")
            }
            let elapsed = ContinuousClock.now - started
            logger.info("Capture to card: \(Int(elapsed / .milliseconds(1))) ms")
        }
    }

    private static func image(_ cgImage: CGImage, pointSize: CGSize) -> NSImage {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(bitmap)
        return image
    }

    private func copy(_ card: Card) {
        if card.isVideo {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([card.dragURL as NSURL])
            pasteboard.setData(Data(), forType: NaviPasteboard.ownType)
        } else {
            NaviPasteboard.write(image: card.image)
        }
        if let id = card.inboxID { inbox.touch(id) }
        if !NSEvent.modifierFlags.contains(.option) { cards.close(card) }
    }

    @discardableResult
    private func save(_ card: Card, thenClose: Bool) -> URL? {
        if let saved = card.savedURL, FileManager.default.fileExists(atPath: saved.path) {
            if thenClose { cards.close(card) }
            return saved
        }
        let folder = settings.saveFolder
        let url = CaptureGeometry.uniqueURL(
            in: folder, name: CaptureGeometry.fileName(for: card.createdAt, fileExtension: card.fileExtension)
        ) { FileManager.default.fileExists(atPath: $0.path) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: card.dragURL, to: url)
        } catch {
            logger.error("Could not save the capture: \(error.localizedDescription)")
            NSSound.beep()
            return nil
        }
        card.savedURL = url
        if thenClose { cards.close(card) }
        return url
    }

    private func showInFinder(_ card: Card) {
        guard let url = save(card, thenClose: false) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func annotate(inboxID id: UUID) {
        if let card = cards.card(forInboxID: id) {
            annotate(card)
            return
        }
        guard let data = inbox.fileData(for: id),
              let bitmap = NSBitmapImageRep(data: data), let flat = bitmap.cgImage
        else { return }
        let scale = bitmap.size.width > 0 ? CGFloat(bitmap.pixelsWide) / bitmap.size.width : 1
        var base = flat
        var document = AnnotationDocument()
        if let saved = MarkupStore.load(from: inbox.markupURL(for: id)) { (base, document) = saved }
        let token = UUID()
        let editor = AnnotateEditor(base: base, document: document, scale: scale) { [weak self] result in
            self?.applyMarkup(result, toInboxID: id)
        } onClose: { [weak self] in
            self?.editors[token] = nil
        }
        editors[token] = editor
        editor.show()
    }

    private func applyMarkup(_ result: AnnotateEditor.Result, toInboxID id: UUID) {
        guard let png = ImageOps.png(result.flat, pointSize: result.pointSize) else { return }
        if settings.copyToClipboard { NaviPasteboard.write(image: Self.image(result.flat, pointSize: result.pointSize)) }
        inbox.updateFile(id, data: png)
        do {
            try MarkupStore.save(base: result.base, document: result.document, to: inbox.markupURL(for: id))
        } catch {
            logger.error("Could not save the markup: \(error.localizedDescription)")
        }
    }

    private func annotate(_ card: Card) {
        guard let current = card.cgImage else { return }
        var base = current
        var document = AnnotationDocument()
        if let id = card.inboxID, inbox.fileData(for: id) == card.png,
           let saved = MarkupStore.load(from: inbox.markupURL(for: id)) {
            (base, document) = saved
        }
        let token = UUID()
        let editor = AnnotateEditor(base: base, document: document, scale: card.scale) { [weak self] result in
            self?.applyMarkup(result, to: card)
        } onClose: { [weak self] in
            self?.editors[token] = nil
        }
        editors[token] = editor
        editor.show()
    }

    private func applyMarkup(_ result: AnnotateEditor.Result, to card: Card) {
        guard let png = ImageOps.png(result.flat, pointSize: result.pointSize) else { return }
        let image = Self.image(result.flat, pointSize: result.pointSize)
        card.update(image: image, png: png)
        if settings.copyToClipboard { NaviPasteboard.write(image: image) }
        guard let id = card.inboxID else { return }
        inbox.updateFile(id, data: png)
        do {
            try MarkupStore.save(base: result.base, document: result.document, to: inbox.markupURL(for: id))
        } catch {
            logger.error("Could not save the markup: \(error.localizedDescription)")
        }
    }

    private func trim(_ card: Card) {
        guard var video = card.video, let tools = videoTools else { return }
        Task {
            guard let trimmed = await tools.trim(video.mp4) else { return }
            video.mp4 = trimmed
            video.duration = (try? await AVURLAsset(url: trimmed).load(.duration).seconds) ?? video.duration
            if video.showsGIF {
                video.gif = try? await tools.makeGIF(trimmed)
                if video.gif == nil { video.showsGIF = false }
            } else {
                video.gif = nil
            }
            card.update(video: video)
            if let id = card.inboxID, let data = try? Data(contentsOf: trimmed) { inbox.updateFile(id, data: data) }
        }
    }

    private func setGIF(_ card: Card, _ gif: Bool) {
        guard var video = card.video, video.showsGIF != gif else { return }
        if !gif || video.gif != nil {
            video.showsGIF = gif
            card.update(video: video)
            return
        }
        guard let tools = videoTools else { return }
        Toast.show("Making a GIF…")
        Task {
            do {
                video.gif = try await tools.makeGIF(video.mp4)
                video.showsGIF = true
                card.update(video: video)
                Toast.show("GIF ready. It has no sound and loops.")
            } catch {
                Toast.show("Could not make the GIF")
            }
        }
    }

    private func pin(_ card: Card) {
        pins.pin(card.image, near: NSScreen.underMouse)
    }

    private func copyText(from card: Card) {
        guard let image = card.cgImage else { return }
        Task { await copyText(image, on: NSScreen.underMouse) }
    }

    private func copyText(_ image: CGImage, on screen: NSScreen?) async {
        let text = await TextRecognizer.recognize(image)
        guard !text.isEmpty else {
            Toast.show("No text found", on: screen)
            return
        }
        NaviPasteboardBridge.write(text)
        inbox.add(text: text, sourceApp: "Navi OCR")
        let preview = text.replacingOccurrences(of: "\n", with: " ")
        Toast.show("Copied: \(preview.prefix(60))\(preview.count > 60 ? "…" : "")", on: screen)
    }

    private func openBackground(_ card: Card) {
        guard let image = card.cgImage else { return }
        let scale = card.scale
        let token = UUID()
        let editor = BackgroundEditor(image: image, scale: scale) { [weak self] result in
            guard let self else { return }
            let pointSize = CGSize(width: CGFloat(result.width) / scale, height: CGFloat(result.height) / scale)
            guard let png = ImageOps.png(result, pointSize: pointSize) else { return }
            card.update(image: Self.image(result, pointSize: pointSize), png: png)
            if let id = card.inboxID {
                inbox.updateFile(id, data: png)
                try? FileManager.default.removeItem(at: inbox.markupURL(for: id))
            }
        } onClose: { [weak self] in
            self?.editors[token] = nil
        }
        editors[token] = editor
        editor.show()
    }
}
