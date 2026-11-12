import CoreGraphics
import Foundation

public enum RecordingRegion: Sendable, Equatable {
    case display(CGDirectDisplayID)
    case area(CGDirectDisplayID, CGRect)
    case window(CGWindowID)
}

public struct RecordingResult: Sendable, Equatable {
    public let url: URL
    public let isGIF: Bool
    public let videoURL: URL
    public let duration: TimeInterval

    public init(url: URL, isGIF: Bool, videoURL: URL, duration: TimeInterval) {
        self.url = url
        self.isGIF = isGIF
        self.videoURL = videoURL
        self.duration = duration
    }
}

public struct RecordingOptions: Sendable, Equatable {
    public var framesPerSecond: Int = 30
    public var microphone = false
    public var computerAudio = false
    public var camera = false
    public var showClicks = true
    public var showKeystrokes = false
    public var hideDesktopIcons = false
    public var muteNotifications = false

    public init() {}
}

public enum RecordingError: Error, Sendable, LocalizedError {
    case noScreenAccess
    case busy
    case noDisplay
    case noWindow
    case noFrames
    case writerFailed(String)
    case gifFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noScreenAccess: "Navi needs Screen Recording permission."
        case .busy: "Navi is still finishing the last recording."
        case .noDisplay: "The display is not available."
        case .noWindow: "The window is not available."
        case .noFrames: "The recording has no video frames."
        case .writerFailed(let reason): "Writing the video failed: \(reason)"
        case .gifFailed(let reason): "Making the GIF failed: \(reason)"
        }
    }
}
