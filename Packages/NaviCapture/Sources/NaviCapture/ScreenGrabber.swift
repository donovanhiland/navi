import AppKit
import ScreenCaptureKit

struct CapturedImage {
    let image: CGImage
    let scale: CGFloat
}

struct OnScreenWindow {
    let id: CGWindowID
    let frame: CGRect
    var appName: String = ""
    var ownerPID: pid_t = 0

    func offsetBy(dx: CGFloat, dy: CGFloat) -> OnScreenWindow {
        OnScreenWindow(id: id, frame: frame.offsetBy(dx: dx, dy: dy), appName: appName, ownerPID: ownerPID)
    }
}

enum CaptureError: Error {
    case noDisplay
    case noWindow
}

@MainActor
enum ScreenGrabber {
    static let finderBundleID = "com.apple.finder"

    static func captureAllScreens(hideDesktopIcons: Bool) async throws -> [(NSScreen, CapturedImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [(NSScreen, CapturedImage)] = []
        for screen in NSScreen.screens {
            result.append((screen, try await capture(screen, content: content, hideDesktopIcons: hideDesktopIcons)))
        }
        return result
    }

    static func capture(_ screen: NSScreen, hideDesktopIcons: Bool) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return try await capture(screen, content: content, hideDesktopIcons: hideDesktopIcons)
    }

    static func capture(_ screen: NSScreen, rect: CGRect, hideDesktopIcons: Bool) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return try await capture(screen, content: content, hideDesktopIcons: hideDesktopIcons, sourceRect: rect)
    }

    static func captureWindow(id: CGWindowID) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = false
        config.shouldBeOpaque = false
        config.backgroundColor = .clear
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, scale: scale)
    }

    static func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width > 20, bounds.height > 20
            else { return nil }
            return OnScreenWindow(
                id: number,
                frame: CaptureGeometry.flip(bounds, primaryHeight: primaryHeight),
                appName: info[kCGWindowOwnerName as String] as? String ?? "",
                ownerPID: info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            )
        }
    }

    private static func capture(
        _ screen: NSScreen, content: SCShareableContent, hideDesktopIcons: Bool, sourceRect: CGRect? = nil
    ) async throws -> CapturedImage {
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw CaptureError.noDisplay }

        let ownBundleID = Bundle.main.bundleIdentifier
        let excluded = content.windows.filter { window in
            let bundleID = window.owningApplication?.bundleIdentifier
            if bundleID == ownBundleID { return window.windowLayer != 0 }
            return hideDesktopIcons && bundleID == finderBundleID && window.windowLayer < 0
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        if let sourceRect {
            config.sourceRect = sourceRect
            config.width = Int(sourceRect.width * scale)
            config.height = Int(sourceRect.height * scale)
        } else {
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
        }
        config.captureResolution = .best
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, scale: scale)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}
