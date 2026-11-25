import AppKit
import CoreGraphics

struct SpaceWindow: Equatable, Sendable {
    let pid: pid_t
    let layer: Int
    let alpha: Double
}

@MainActor
enum FocusHandoff {
    static func pick(previous: pid_t?, own: pid_t, windows: [SpaceWindow]) -> pid_t? {
        let owners = windows.filter { $0.layer == 0 && $0.alpha > 0 && $0.pid != own }.map(\.pid)
        if let previous, owners.contains(previous) { return previous }
        return owners.first
    }

    static func appOnThisSpace(preferring previous: NSRunningApplication?) -> NSRunningApplication? {
        let chosen = pick(
            previous: previous?.processIdentifier, own: ProcessInfo.processInfo.processIdentifier,
            windows: windowsOnThisSpace()
        )
        guard let chosen else { return nil }
        if chosen == previous?.processIdentifier { return previous }
        return NSRunningApplication(processIdentifier: chosen)
    }

    @discardableResult
    static func giveBack(to previous: NSRunningApplication?) -> NSRunningApplication? {
        let app = appOnThisSpace(preferring: previous)
        if NSApp.isActive { app?.activate() }
        return app ?? previous
    }

    private static func windowsOnThisSpace() -> [SpaceWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int
            else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return SpaceWindow(pid: pid, layer: layer, alpha: alpha)
        }
    }
}
