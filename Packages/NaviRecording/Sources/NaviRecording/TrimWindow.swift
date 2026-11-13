import AppKit
import AVFoundation
import AVKit
import os

@MainActor
final class TrimWindow: NSObject, NSWindowDelegate {
    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Recording")
    private static var open: [TrimWindow] = []

    private let sourceURL: URL
    private let window: NSWindow
    private let playerView = AVPlayerView()
    private let playerItem: AVPlayerItem
    private var continuation: CheckedContinuation<Bool, Never>?

    private init(url: URL) {
        sourceURL = url
        playerItem = AVPlayerItem(url: url)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        super.init()
        window.title = "Trim recording"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = playerView
        window.center()
        playerView.controlsStyle = .inline
        playerView.player = AVPlayer(playerItem: playerItem)
    }

    static func trim(_ url: URL) async -> URL? {
        let controller = TrimWindow(url: url)
        open.append(controller)
        defer { open.removeAll { $0 === controller } }
        return await controller.run()
    }

    private func run() async -> URL? {
        guard let duration = try? await playerItem.asset.load(.duration).seconds, duration > 0 else { return nil }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard playerView.canBeginTrimming else {
            window.close()
            return nil
        }
        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation = continuation
            playerView.beginTrimming { [weak self] result in
                MainActor.assumeIsolated { self?.finish(result == .okButton) }
            }
        }
        window.close()
        guard accepted else { return nil }

        let start = playerItem.reversePlaybackEndTime
        let end = playerItem.forwardPlaybackEndTime
        let range = TrimRange.resolve(start: start.isNumeric ? start.seconds : nil,
                                      end: end.isNumeric ? end.seconds : nil, duration: duration)
        guard let range else { return sourceURL }
        do {
            return try await Self.export(
                sourceURL, from: range.start, to: range.end,
                outputURL: sourceURL.deletingLastPathComponent()
                    .appending(path: RecordingMath.fileName(for: Date(), fileExtension: "mp4"))
            )
        } catch {
            Self.logger.error("Trim export failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func finish(_ accepted: Bool) {
        continuation?.resume(returning: accepted)
        continuation = nil
    }

    func windowWillClose(_ notification: Notification) {
        finish(false)
    }

    nonisolated static func export(_ url: URL, from start: Double, to end: Double, outputURL: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.writerFailed("no export session")
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try await session.export(to: outputURL, as: .mp4)
        return outputURL
    }
}

enum TrimRange {
    static func resolve(start: Double?, end: Double?, duration: Double, tolerance: Double = 0.05) -> (start: Double, end: Double)? {
        let s = min(max(start ?? 0, 0), duration)
        let e = min(max(end ?? duration, 0), duration)
        guard e - s > tolerance else { return nil }
        if s <= tolerance, e >= duration - tolerance { return nil }
        return (s, e)
    }
}
