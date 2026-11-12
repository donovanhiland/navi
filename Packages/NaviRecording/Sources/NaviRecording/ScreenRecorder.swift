import AppKit
import CoreMedia
import os
import ScreenCaptureKit

@MainActor
final class ScreenRecorder {
    struct Settings: Sendable {
        var region: RecordingRegion
        var options: RecordingOptions
        var outputURL: URL
        var excludedWindowIDs: Set<CGWindowID>
        var recordsAudio: Bool
    }

    struct Output: Sendable {
        let url: URL
        let duration: TimeInterval
    }

    static let finderBundleID = "com.apple.finder"
    static let notificationCenterBundleID = "com.apple.notificationcenterui"

    var onUnexpectedStop: (@MainActor (Error?) -> Void)?

    private(set) var isRunning = false
    private var stream: SCStream?
    private var sink: RecordingSink?
    private var settings: Settings?
    private var refreshTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Recording")

    func start(_ settings: Settings) async throws {
        guard !isRunning else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = try Self.makeFilter(settings, content: content)
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        let pointSize: CGSize
        switch settings.region {
        case .area(_, let rect):
            configuration.sourceRect = rect
            pointSize = rect.size
        case .display, .window:
            pointSize = filter.contentRect.size
        }
        let size = RecordingMath.videoPixelSize(points: pointSize, scale: scale)
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.options.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.captureResolution = .best

        let wantsComputerAudio = settings.recordsAudio && settings.options.computerAudio
        let wantsMicrophone = settings.recordsAudio && settings.options.microphone
        if wantsComputerAudio {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }
        if wantsMicrophone {
            configuration.captureMicrophone = true
        }

        let sink = try RecordingSink(
            url: settings.outputURL, width: size.width, height: size.height,
            framesPerSecond: settings.options.framesPerSecond,
            computerAudio: wantsComputerAudio, microphone: wantsMicrophone
        )
        sink.onStreamStopped = { [weak self] error in
            Task { @MainActor in self?.streamStopped(error) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        if wantsComputerAudio {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
        }
        if wantsMicrophone {
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.sink = sink
        self.settings = settings
        isRunning = true
        startFilterRefresh()
    }

    func stop() async throws -> Output {
        refreshTask?.cancel()
        refreshTask = nil
        guard let stream, let sink, let settings else { throw RecordingError.noFrames }
        self.stream = nil
        self.sink = nil
        self.settings = nil
        isRunning = false
        try? await stream.stopCapture()
        let duration = try await sink.finish()
        if settings.recordsAudio, settings.options.computerAudio, settings.options.microphone {
            await AudioMixdown.mixIntoOneTrack(at: settings.outputURL)
        }
        return Output(url: settings.outputURL, duration: duration)
    }

    private func streamStopped(_ error: Error?) {
        guard isRunning else { return }
        logger.error("Stream stopped: \(error?.localizedDescription ?? "no error")")
        onUnexpectedStop?(error)
    }

    private static func makeFilter(_ settings: Settings, content: SCShareableContent) throws -> SCContentFilter {
        switch settings.region {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecordingError.noWindow }
            return SCContentFilter(desktopIndependentWindow: window)
        case .display(let displayID), .area(let displayID, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.noDisplay
            }
            let excluded = content.windows.filter { window in
                if settings.excludedWindowIDs.contains(window.windowID) { return true }
                let bundleID = window.owningApplication?.bundleIdentifier
                if settings.options.hideDesktopIcons, bundleID == finderBundleID, window.windowLayer < 0 { return true }
                if settings.options.muteNotifications, bundleID == notificationCenterBundleID { return true }
                return false
            }
            return SCContentFilter(display: display, excludingWindows: excluded)
        }
    }

    private func startFilterRefresh() {
        guard let settings, settings.options.muteNotifications else { return }
        if case .window = settings.region { return }
        refreshTask = Task { [weak self] in
            var known = Self.notificationWindowIDs()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                let current = Self.notificationWindowIDs()
                if current != known {
                    known = current
                    await self.refreshFilter()
                }
            }
        }
    }

    private func refreshFilter() async {
        guard let stream, let settings else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try await stream.updateContentFilter(try Self.makeFilter(settings, content: content))
        } catch {
            logger.error("Filter refresh failed: \(error.localizedDescription)")
        }
    }

    private static func notificationWindowIDs() -> Set<CGWindowID> {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundleID).map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return Set(list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }
}
