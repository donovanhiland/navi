import AppKit
import os

@MainActor
public final class RecordingFeature {
    private enum State {
        case idle
        case choosing
        case starting
        case recording
        case stopping
    }

    public var onError: ((any Error) -> Void)?

    private var state = State.idle
    private var bar: RecordBarController?
    private var onFinish: ((RecordingResult) -> Void)?
    private var wantsGIF = false
    private var stopRequestedWhileStarting = false

    private let recorder = ScreenRecorder()
    private let bubble = CameraBubble()
    private var overlay: InputOverlay?
    private var pill: StopPill?
    private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Recording")

    public init() {
        recorder.onUnexpectedStop = { [weak self] _ in self?.stop() }
    }

    public var isRecording: Bool { state == .starting || state == .recording }

    public static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    public func showRecordBar(region: RecordingRegion, onFinish: @escaping (RecordingResult) -> Void) {
        guard state == .idle || state == .choosing else {
            onError?(RecordingError.busy)
            return
        }
        guard Self.hasScreenAccess else {
            _ = CGRequestScreenCaptureAccess()
            onError?(RecordingError.noScreenAccess)
            return
        }
        closeBar()
        bubble.hide()
        guard let bar = RecordBarController(region: region, options: RecordingOptions()) else {
            onError?(RecordingError.noDisplay)
            return
        }
        self.bar = bar
        self.onFinish = onFinish
        state = .choosing

        bar.model.onCancel = { [weak self] in self?.cancelBar() }
        bar.model.onStart = { [weak self] format in self?.begin(format) }
        bar.model.onCameraChange = { [weak self] isOn in self?.cameraOptionChanged(isOn) }
        bar.show()
    }

    public func stop() {
        switch state {
        case .starting:
            stopRequestedWhileStarting = true
        case .recording:
            finish()
        default:
            break
        }
    }

    public nonisolated static func makeGIF(from url: URL) async throws -> URL {
        try await GIFExporter.makeGIF(from: url)
    }

    public func trim(_ url: URL) async -> URL? {
        await TrimWindow.trim(url)
    }

    private func cancelBar() {
        guard state == .choosing else { return }
        closeBar()
        bubble.hide()
        onFinish = nil
        state = .idle
    }

    private func closeBar() {
        bar?.close()
        bar = nil
    }

    private func cameraOptionChanged(_ isOn: Bool) {
        guard let bar else { return }
        guard isOn else {
            bubble.hide()
            return
        }
        guard let region = bar.model.cocoaFrame else { return }
        Task {
            let shown = await bubble.show(inside: region)
            guard shown else {
                bar.model.options.camera = false
                return
            }
            let stillWanted = state == .starting || state == .recording
                || (state == .choosing && self.bar?.model.options.camera == true)
            if !stillWanted { bubble.hide() }
        }
    }

    private func begin(_ format: RecordingFormat) {
        guard state == .choosing, let bar else { return }
        let region = bar.model.region
        var options = bar.model.options
        let frame = bar.model.cocoaFrame ?? .zero
        let excluded = bar.windowIDs
        closeBar()
        state = .starting
        wantsGIF = format == .gif
        stopRequestedWhileStarting = false
        if wantsGIF {
            options.microphone = false
            options.computerAudio = false
        }

        let stopAction: @MainActor () -> Void = { [weak self] in self?.stop() }
        Task {
            do {
                if options.microphone, !(await Permissions.microphone()) { options.microphone = false }

                let overlay = InputOverlay(keyPillArea: frame)
                self.overlay = overlay
                overlay.start(clicks: options.showClicks, keystrokes: options.showKeystrokes)

                let pill = StopPill(onClick: stopAction)
                self.pill = pill
                var excludedIDs = excluded
                if let id = pill.windowID { excludedIDs.insert(id) }

                try await recorder.start(ScreenRecorder.Settings(
                    region: region, options: options, outputURL: try Self.newFileURL(),
                    excludedWindowIDs: excludedIDs, recordsAudio: !wantsGIF
                ))
                state = .recording
                pill.startTimer()
                if stopRequestedWhileStarting { finish() }
            } catch {
                logger.error("Could not start: \(error.localizedDescription)")
                teardownOverlays()
                state = .idle
                onFinish = nil
                onError?(error)
            }
        }
    }

    private func finish() {
        guard state == .recording else { return }
        state = .stopping
        teardownOverlays()
        let isGIF = wantsGIF
        let onFinish = self.onFinish
        self.onFinish = nil

        Task {
            do {
                let output = try await recorder.stop()
                var result = RecordingResult(url: output.url, isGIF: false, videoURL: output.url, duration: output.duration)
                if isGIF {
                    let gif = try await Self.makeGIF(from: output.url)
                    result = RecordingResult(url: gif, isGIF: true, videoURL: output.url, duration: output.duration)
                }
                state = .idle
                onFinish?(result)
            } catch {
                logger.error("Could not finish: \(error.localizedDescription)")
                state = .idle
                onError?(error)
            }
        }
    }

    private func teardownOverlays() {
        pill?.remove()
        pill = nil
        overlay?.stop()
        overlay = nil
        bubble.hide()
    }

    private static func newFileURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "NaviRecordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: RecordingMath.fileName(for: Date(), fileExtension: "mp4"))
    }
}
