import AVFoundation
import AppKit
import NaviCore
import ScreenCaptureKit
import os

@MainActor
protocol OpenEditor: AnyObject {
    func show()
    func focus()
}

extension AnnotateEditor: OpenEditor {}
extension BackgroundEditor: OpenEditor {}

private struct EditorKey: Hashable {
    enum Kind { case markup, background }
    let id: UUID
    let kind: Kind
}

private enum MarkupTarget {
    case new(NSRunningApplication?)
    case existing(UUID)
}

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
    private var editors: [EditorKey: any OpenEditor] = [:]
    private var isBusy = false
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

    public func captureAreaToClipboard() { startSelection(.area, purpose: .screenshot, copies: true) }

    public func captureFullscreenToClipboard() { captureFullscreen(copies: true) }

    public func captureWindow() { startSelection(.window, purpose: .screenshot) }

    public func captureAllInOne() { startSelection(.area, purpose: .screenshot, modeBar: true) }

    public func captureText() { startSelection(.area, purpose: .text) }

    public func captureScrolling() { startSelection(.area, purpose: .scroll) }

    public func captureArea(timer seconds: Int) { startSelection(.area, purpose: .screenshot, timer: seconds) }

    public func pickRecordingRegion() { startSelection(.area, purpose: .record) }

    public func captureFullscreen() { captureFullscreen(copies: false) }

    private func captureFullscreen(copies: Bool) {
        guard begin() else { return }
        guard let screen = NSScreen.underMouse else {
            isBusy = false
            return
        }
        shoot(ShotRequest(
            source: .screen, screen: screen, edits: editsInPlace(purpose: .screenshot, timer: 0), copies: copies,
            sourceApp: NSWorkspace.shared.frontmostApplication
        ))
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
            let shot = thumbnail.map { CapturedImage(image: $0, scale: 1) }
            let size = shot?.pointSize ?? CGSize(width: 320, height: 200)
            let image = shot?.nsImage ?? NSImage(size: size)
            let png = shot?.png() ?? Data()
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
        _ mode: SelectionSession.Mode, purpose: SelectionSession.Purpose, modeBar: Bool = false, timer: Int = 0,
        copies: Bool = false
    ) {
        if purpose == .record, onRecordRequest == nil { return }
        CaptureTiming.start("select")
        guard begin() else { return }
        let freeze = PendingFreeze()
        let fastFreeze = ScreenGrabber.startFreeze(hideDesktopIcons: settings.hideDesktopIcons) { [weak self] screens in
            self?.frozeFast(screens, freeze)
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let listing = Task.detached(priority: .userInitiated) { ScreenGrabber.onScreenWindows(primaryHeight: primaryHeight) }
        let session = SelectionSession(screens: NSScreen.screens, mode: mode) { [weak self] outcome in
            guard let self else { return }
            let session = self.session
            selectionEnded(
                outcome, purpose: session?.purpose ?? purpose, timer: session?.timer ?? timer,
                previousApp: previousApp, copies: copies, session: session
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
        session.editsAfterCapture = settings.editAfterCapture
        self.session = session
        freeze.session = session
        CaptureTiming.mark("select", "session made")
        session.begin(revealAfterFreeze: fastFreeze)
        CaptureTiming.mark("select", "overlay set up")
        if !fastFreeze { freezeSlowly(session) }
    }

    private func editsInPlace(purpose: SelectionSession.Purpose, timer: Int) -> Bool {
        purpose == .screenshot && timer == 0 && settings.editAfterCapture
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
                guard let session, session === self.session else { return }
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
        _ outcome: SelectionSession.Outcome, purpose: SelectionSession.Purpose, timer: Int,
        previousApp: NSRunningApplication?, copies: Bool, session ending: SelectionSession?
    ) {
        CaptureTiming.mark("shot", "selection ended")
        session = nil
        prepareAhead(after: 1)
        let frozen = frozenScreens
        frozenScreens = []
        let backdrop = { (screen: NSScreen) in frozen.first { $0.0 == screen }?.1.image }
        if editsInPlace(purpose: purpose, timer: timer) {
            switch outcome {
            case let .area(captured, screen, rect):
                shoot(ShotRequest(
                    source: .frozen(captured, rect: rect), screen: screen, edits: true, backdrop: backdrop(screen),
                    copies: copies, sourceApp: previousApp
                ))
                return
            case let .window(id, screen):
                ending?.holdOverlay()
                previousApp?.activate()
                let frame = ending?.windows.first { $0.id == id }?.frame
                shoot(ShotRequest(
                    source: .window(id, frame: frame), screen: screen, edits: true, backdrop: backdrop(screen),
                    copies: copies, sourceApp: previousApp, session: ending
                ))
                return
            case let .fullscreen(screen):
                if let shot = frozen.first(where: { $0.0 == screen })?.1 {
                    let whole = CGRect(origin: .zero, size: screen.frame.size)
                    shoot(ShotRequest(
                        source: .frozen(shot, rect: whole), screen: screen, edits: true, backdrop: shot.image,
                        copies: copies, sourceApp: previousApp
                    ))
                } else {
                    ending?.holdOverlay()
                    shoot(ShotRequest(
                        source: .screen, screen: screen, edits: true, copies: copies, sourceApp: previousApp,
                        session: ending
                    ))
                }
                return
            case .cancelled:
                break
            }
        }
        previousApp?.activate()
        switch (outcome, purpose) {
        case (.cancelled, _):
            isBusy = false

        case let (.fullscreen(screen), .record):
            isBusy = false
            if let id = screen.displayID { onRecordRequest?(.display(id)) }
        case let (.fullscreen(screen), _):
            shoot(ShotRequest(source: .screen, screen: screen, timer: timer, copies: copies, sourceApp: previousApp))

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
            startScrolling(on: screen, rect: rect, copies: copies, sourceApp: previousApp)

        case let (.area(captured, screen, rect), .screenshot):
            shoot(ShotRequest(
                source: timer > 0 ? .rect(rect) : .frozen(captured, rect: rect), screen: screen, timer: timer,
                copies: copies, sourceApp: previousApp
            ))

        case let (.window(id, screen), _):
            shoot(ShotRequest(
                source: .window(id, frame: nil), screen: screen, timer: timer, copies: copies, sourceApp: previousApp
            ))
        }
    }

    private static func waitUntilActive(_ app: NSRunningApplication?) async {
        guard let app else { return }
        for _ in 0 ..< 15 {
            if app.isActive { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func shoot(_ request: ShotRequest) {
        if case let .frozen(captured, _) = request.source {
            route(captured, request)
            return
        }
        Task {
            let watchdog = request.session.map(Self.releaseLater)
            defer {
                watchdog?.cancel()
                request.session?.releaseOverlay()
            }
            if request.source.waitsForApp { await Self.waitUntilActive(request.sourceApp) }
            await Countdown.run(seconds: request.timer, on: request.screen)
            do {
                route(try await grab(request), request)
            } catch {
                logger.error("\(request.source.failureLabel): \(error.localizedDescription)")
                endWithoutShot()
            }
        }
    }

    private func grab(_ request: ShotRequest) async throws -> CapturedImage {
        let hideIcons = settings.hideDesktopIcons
        switch request.source {
        case let .frozen(captured, _): return captured
        case .screen: return try await ScreenGrabber.capture(request.screen, hideDesktopIcons: hideIcons)
        case let .rect(rect): return try await ScreenGrabber.capture(request.screen, rect: rect, hideDesktopIcons: hideIcons)
        case let .window(id, _): return try await ScreenGrabber.captureWindow(id: id)
        }
    }

    private func route(_ captured: CapturedImage, _ request: ShotRequest) {
        guard request.edits else {
            isBusy = false
            if request.source.flashes { ScreenFlash.show(captured, on: request.screen) }
            deliver(captured, on: request.screen, sourceApp: request.sourceApp, copies: request.copies)
            return
        }
        let area = request.source.editArea(
            imageSize: captured.pointSize, screenFrame: request.screen.frame, scale: captured.scale
        )
        editInPlace(
            captured, backdrop: request.source.usesOwnBackdrop ? captured.image : request.backdrop,
            on: request.screen, rect: area, reframes: request.source.reframes, sourceApp: request.sourceApp
        )
    }

    private static func releaseLater(_ session: SelectionSession?) -> Task<Void, Never> {
        Task { [weak session] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            session?.releaseOverlay()
        }
    }

    private func endWithoutShot() {
        isBusy = false
    }

    private func startScrolling(on screen: NSScreen, rect: CGRect, copies: Bool, sourceApp: NSRunningApplication?) {
        let scroll = ScrollCaptureSession(screen: screen, rect: rect, hideDesktopIcons: settings.hideDesktopIcons) {
            [weak self] image, scale in
            guard let self else { return }
            scrollSession = nil
            isBusy = false
            if let image {
                deliver(CapturedImage(image: image, scale: scale), on: screen, sourceApp: sourceApp, copies: copies)
            }
        }
        scrollSession = scroll
        scroll.begin()
    }

    private func editInPlace(
        _ captured: CapturedImage, backdrop: CGImage?, on screen: NSScreen, rect: CGRect, reframes: Bool = true,
        sourceApp: NSRunningApplication?
    ) {
        let editor = InPlaceAnnotator(
            captured: captured, backdrop: backdrop, screen: screen, area: rect, reframes: reframes
        ) { [weak self] result in
            guard let self else { return }
            inPlaceEditor = nil
            isBusy = false
            prepareAhead(after: 1)
            sourceApp?.activate()
            if let (action, result) = result {
                deliverEdited(result, action: action, on: screen, sourceApp: sourceApp)
            }
        }
        inPlaceEditor = editor
        let stage = editorStage
        editorStage = nil
        editor.show(on: stage)
    }

    private func deliverEdited(
        _ result: MarkupResult, action: InPlaceAnnotator.Action, on screen: NSScreen, sourceApp: NSRunningApplication?
    ) {
        if action == .copy {
            NaviPasteboard.write(image: result.flatImage)
            Toast.show("Copied", on: screen)
        }
        let createdAt = Date.now
        Task {
            let encoding = Task.detached(priority: .userInitiated) { result.encoded() }
            guard let encoded = await encoding.value else {
                logger.error("Could not encode the edited capture as PNG")
                return
            }
            storeMarkup(result, encoded, target: .new(sourceApp))
            switch action {
            case .copy:
                break
            case .save:
                let written = saveToFolder(createdAt: createdAt, fileExtension: "png") {
                    try encoded.flat.write(to: $0, options: .atomic)
                }
                if written != nil { Toast.show("Saved to \(settings.saveFolder.lastPathComponent)", on: screen) }
            case .stash:
                Toast.show("Stashed. ⇧⌘V to find it", on: screen)
            }
        }
    }

    @discardableResult
    private func storeMarkup(_ result: MarkupResult, _ encoded: EncodedMarkup, target: MarkupTarget) -> UUID? {
        let id: UUID?
        switch target {
        case let .new(sourceApp):
            id = inbox.add(
                fileData: encoded.flat, fileExtension: "png", kind: .screenshot,
                sourceApp: sourceApp?.localizedName, sourceBundleID: sourceApp?.bundleIdentifier, deduplicate: false
            )?.id
        case let .existing(existing):
            inbox.updateFile(existing, data: encoded.flat)
            id = existing
        }
        guard let id else { return nil }
        do {
            try MarkupStore.save(basePNG: encoded.base, document: result.document, to: inbox.markupURL(for: id))
        } catch {
            logger.error("Could not save the markup: \(error.localizedDescription)")
        }
        return id
    }

    private func deliver(_ captured: CapturedImage, on screen: NSScreen, sourceApp: NSRunningApplication?, copies forced: Bool) {
        let started = ContinuousClock.now
        let encoding = Task.detached(priority: .userInitiated) { captured.png() }
        let copies = forced || settings.copyToClipboard
        Task {
            let encoded = await encoding.value
            let image = captured.nsImage
            defer { if copies { NaviPasteboard.write(image: image) } }
            guard let png = encoded else {
                logger.error("Could not encode the capture as PNG")
                return
            }
            let item = inbox.add(
                fileData: png, fileExtension: "png", kind: .screenshot,
                sourceApp: sourceApp?.localizedName, sourceBundleID: sourceApp?.bundleIdentifier, deduplicate: false
            )
            do {
                let card = try Card(inboxID: item?.id, image: image, png: png, createdAt: .now)
                cards.show(card, on: screen)
                CaptureTiming.markOnScreen("shot", "card shown")
            } catch {
                logger.error("Could not make the corner card: \(error.localizedDescription)")
            }
            let elapsed = ContinuousClock.now - started
            logger.info("Capture to card: \(Int(elapsed / .milliseconds(1))) ms")
        }
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
        guard let url = saveToFolder(createdAt: card.createdAt, fileExtension: card.fileExtension, write: {
            try FileManager.default.copyItem(at: card.dragURL, to: $0)
        }) else { return nil }
        card.savedURL = url
        if thenClose { cards.close(card) }
        return url
    }

    private func saveToFolder(createdAt: Date, fileExtension: String, write: (URL) throws -> Void) -> URL? {
        let folder = settings.saveFolder
        let url = CaptureGeometry.uniqueURL(
            in: folder, name: CaptureGeometry.fileName(for: createdAt, fileExtension: fileExtension)
        ) { FileManager.default.fileExists(atPath: $0.path) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(url)
        } catch {
            logger.error("Could not save the capture: \(error.localizedDescription)")
            NSSound.beep()
            return nil
        }
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
        openMarkup(key: id, flat: flat, flatData: data, scale: scale, inboxID: id) { [weak self] in
            self?.applyMarkup($0, toInboxID: id)
        }
    }

    private func annotate(_ card: Card) {
        guard let flat = card.cgImage else { return }
        openMarkup(key: card.inboxID ?? card.id, flat: flat, flatData: card.png, scale: card.scale, inboxID: card.inboxID) {
            [weak self] in
            self?.applyMarkup($0, to: card)
        }
    }

    private func openMarkup(
        key: UUID, flat: CGImage, flatData: Data, scale: CGFloat, inboxID: UUID?,
        onDone: @escaping (MarkupResult) -> Void
    ) {
        present(EditorKey(id: key, kind: .markup)) { onClose in
            var base = flat
            var document = AnnotationDocument()
            if let id = inboxID, inbox.fileData(for: id) == flatData,
               let saved = MarkupStore.load(from: inbox.markupURL(for: id)) {
                (base, document) = saved
            }
            return AnnotateEditor(base: base, document: document, scale: scale, onDone: onDone, onClose: onClose)
        }
    }

    private func present(_ key: EditorKey, make: (_ onClose: @escaping () -> Void) -> any OpenEditor) {
        if let open = editors[key] {
            open.focus()
            return
        }
        let editor = make { [weak self] in self?.editors[key] = nil }
        editors[key] = editor
        editor.show()
    }

    private func applyMarkup(_ result: MarkupResult, toInboxID id: UUID) {
        guard let encoded = result.encoded() else { return }
        if settings.copyToClipboard { NaviPasteboard.write(image: result.flatImage) }
        storeMarkup(result, encoded, target: .existing(id))
    }

    private func applyMarkup(_ result: MarkupResult, to card: Card) {
        guard let encoded = result.encoded() else { return }
        let image = result.flatImage
        card.update(image: image, png: encoded.flat)
        if settings.copyToClipboard { NaviPasteboard.write(image: image) }
        guard let id = card.inboxID else { return }
        storeMarkup(result, encoded, target: .existing(id))
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
        present(EditorKey(id: card.inboxID ?? card.id, kind: .background)) { onClose in
            BackgroundEditor(image: image, scale: scale, onApply: { [weak self] result in
                guard let self else { return }
                let shot = CapturedImage(image: result, scale: scale)
                guard let png = shot.png() else { return }
                card.update(image: shot.nsImage, png: png)
                if let id = card.inboxID {
                    inbox.updateFile(id, data: png)
                    try? FileManager.default.removeItem(at: inbox.markupURL(for: id))
                }
            }, onClose: onClose)
        }
    }
}
