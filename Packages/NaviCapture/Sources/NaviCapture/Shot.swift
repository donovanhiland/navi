import AppKit

enum ShotSource {
    case frozen(CapturedImage, rect: CGRect)
    case screen
    case rect(CGRect)
    case window(CGWindowID, frame: CGRect?)

    var waitsForApp: Bool {
        if case .window = self { return true }
        return false
    }

    var reframes: Bool {
        if case .window = self { return false }
        return true
    }

    var usesOwnBackdrop: Bool {
        if case .screen = self { return true }
        return false
    }

    var flashes: Bool {
        if case .screen = self { return true }
        return false
    }

    var failureLabel: String {
        switch self {
        case .frozen: "Area capture failed"
        case .screen: "Fullscreen capture failed"
        case .rect: "Timer capture failed"
        case .window: "Window capture failed"
        }
    }

    func editArea(imageSize: CGSize, screenFrame: CGRect, scale: CGFloat) -> CGRect {
        switch self {
        case let .frozen(_, rect), let .rect(rect):
            return rect
        case .screen:
            return CGRect(origin: .zero, size: screenFrame.size)
        case let .window(_, frame):
            let window = frame ?? CGRect(
                x: screenFrame.midX - imageSize.width / 2, y: screenFrame.midY - imageSize.height / 2,
                width: imageSize.width, height: imageSize.height
            )
            return CaptureGeometry.windowArea(window: window, imageSize: imageSize, screen: screenFrame, scale: scale)
        }
    }
}

struct ShotRequest {
    let source: ShotSource
    let screen: NSScreen
    var timer = 0
    var edits = false
    var backdrop: CGImage?
    var copies = false
    var sourceApp: NSRunningApplication?
    var session: SelectionSession?
    var prefetched: Task<CapturedImage, Error>?
}
