import AppKit

extension NSScreen {
    var recordingDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

struct ResolvedRegion {
    var displayID: CGDirectDisplayID
    var displayFrame: CGRect
    var scale: CGFloat
    var frame: CGRect

    @MainActor
    static func resolve(_ region: RecordingRegion) -> ResolvedRegion? {
        switch region {
        case .display(let id):
            guard let screen = screen(for: id) else { return nil }
            return ResolvedRegion(displayID: id, displayFrame: screen.frame, scale: screen.backingScaleFactor, frame: screen.frame)
        case .area(let id, let local):
            guard let screen = screen(for: id) else { return nil }
            return ResolvedRegion(
                displayID: id, displayFrame: screen.frame, scale: screen.backingScaleFactor,
                frame: RecordingMath.cocoaRect(forLocal: local, displayFrame: screen.frame)
            )
        case .window(let id):
            guard let frame = windowFrame(id) else { return nil }
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
                ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen, let displayID = screen.recordingDisplayID else { return nil }
            return ResolvedRegion(displayID: displayID, displayFrame: screen.frame, scale: screen.backingScaleFactor, frame: frame)
        }
    }

    @MainActor
    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.recordingDisplayID == id }
    }

    @MainActor
    private static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo),
              let primary = NSScreen.screens.first
        else { return nil }
        return RecordingMath.flip(bounds, primaryHeight: primary.frame.height)
    }
}
