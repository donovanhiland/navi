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

    private static var displays: [SCDisplay] = []
    private static var ownApp: SCRunningApplication?
    private static var observesScreens = false

    static func prewarm() {
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            remember(content)
            if let own = try? await SCShareableContent.currentProcess { rememberOwnApp(own) }
            guard let display = content.displays.first else { return }
            let config = SCStreamConfiguration()
            config.width = 16
            config.height = 16
            config.showsCursor = false
            _ = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config
            )
        }
    }

    private static func remember(_ content: SCShareableContent) {
        displays = content.displays
        let pid = ProcessInfo.processInfo.processIdentifier
        ownApp = content.applications.first { $0.processID == pid } ?? ownApp
        watchScreens()
    }

    private static func rememberOwnApp(_ content: SCShareableContent) {
        let pid = ProcessInfo.processInfo.processIdentifier
        ownApp = content.applications.first { $0.processID == pid } ?? ownApp
    }

    private struct ImageBox: @unchecked Sendable {
        let image: CGImage?
    }

    @MainActor
    private final class FreezeCollector {
        let screens: [NSScreen]
        var images: [CapturedImage?]
        var remaining: Int
        var failed = false
        let completion: ([(NSScreen, CapturedImage)]?) -> Void

        init(screens: [NSScreen], completion: @escaping ([(NSScreen, CapturedImage)]?) -> Void) {
            self.screens = screens
            images = Array(repeating: nil, count: screens.count)
            remaining = screens.count
            self.completion = completion
        }

        func receive(_ index: Int, _ image: CGImage?) {
            if let image {
                images[index] = CapturedImage(image: image, scale: screens[index].backingScaleFactor)
            } else {
                failed = true
            }
            remaining -= 1
            guard remaining == 0 else { return }
            let pairs = zip(screens, images).compactMap { screen, image in image.map { (screen, $0) } }
            completion(failed || pairs.count != screens.count ? nil : pairs)
        }
    }

    static func startFreeze(
        hideDesktopIcons: Bool, completion: @escaping ([(NSScreen, CapturedImage)]?) -> Void
    ) -> Bool {
        guard !hideDesktopIcons, let ownApp, !displays.isEmpty,
              !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal })
        else { return false }
        let screens = NSScreen.screens
        var requests: [(SCContentFilter, SCStreamConfiguration)] = []
        for screen in screens {
            guard let id = screen.displayID, let display = displays.first(where: { $0.displayID == id }) else { return false }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.captureResolution = .best
            config.showsCursor = false
            requests.append((SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: []), config))
        }
        let collector = FreezeCollector(screens: screens, completion: completion)
        for (index, request) in requests.enumerated() {
            SCScreenshotManager.captureImage(contentFilter: request.0, configuration: request.1) { image, _ in
                let box = ImageBox(image: image)
                Task { @MainActor in collector.receive(index, box.image) }
            }
        }
        return true
    }

    private static func watchScreens() {
        guard !observesScreens else { return }
        observesScreens = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { displays = [] }
        }
    }

    private struct Source {
        let displays: [SCDisplay]
        let excluded: [SCWindow]
        let hideDesktopIcons: Bool
    }

    private static func source(hideDesktopIcons: Bool) async throws -> Source {
        let ownBundleID = Bundle.main.bundleIdentifier
        if !hideDesktopIcons, !displays.isEmpty, let own = try? await SCShareableContent.currentProcess {
            rememberOwnApp(own)
            return Source(displays: displays, excluded: own.windows.filter { $0.windowLayer != 0 }, hideDesktopIcons: false)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        remember(content)
        let excluded = content.windows.filter { window in
            let bundleID = window.owningApplication?.bundleIdentifier
            if bundleID == ownBundleID { return window.windowLayer != 0 }
            return hideDesktopIcons && bundleID == finderBundleID && window.windowLayer < 0
        }
        return Source(displays: content.displays, excluded: excluded, hideDesktopIcons: hideDesktopIcons)
    }

    static func captureAllScreens(hideDesktopIcons: Bool) async throws -> [(NSScreen, CapturedImage)] {
        let source = try await source(hideDesktopIcons: hideDesktopIcons)
        let screens = NSScreen.screens
        let tasks = screens.map { screen in
            Task { try await capture(screen, source: source) }
        }
        var result: [(NSScreen, CapturedImage)] = []
        for (screen, task) in zip(screens, tasks) {
            result.append((screen, try await task.value))
        }
        return result
    }

    static func capture(_ screen: NSScreen, hideDesktopIcons: Bool) async throws -> CapturedImage {
        try await capture(screen, source: source(hideDesktopIcons: hideDesktopIcons))
    }

    static func capture(_ screen: NSScreen, rect: CGRect, hideDesktopIcons: Bool) async throws -> CapturedImage {
        try await capture(screen, source: source(hideDesktopIcons: hideDesktopIcons), sourceRect: rect)
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
        onScreenWindows(primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    nonisolated static func onScreenWindows(primaryHeight: CGFloat) -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
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

    private static func capture(_ screen: NSScreen, source: Source, sourceRect: CGRect? = nil) async throws -> CapturedImage {
        do {
            return try await capture(screen, displays: source.displays, excluded: source.excluded, sourceRect: sourceRect)
        } catch CaptureError.noDisplay {
            displays = []
            let fresh = try await self.source(hideDesktopIcons: source.hideDesktopIcons)
            return try await capture(screen, displays: fresh.displays, excluded: fresh.excluded, sourceRect: sourceRect)
        }
    }

    private static func capture(
        _ screen: NSScreen, displays: [SCDisplay], excluded: [SCWindow], sourceRect: CGRect?
    ) async throws -> CapturedImage {
        guard let displayID = screen.displayID,
              let display = displays.first(where: { $0.displayID == displayID })
        else { throw CaptureError.noDisplay }

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
