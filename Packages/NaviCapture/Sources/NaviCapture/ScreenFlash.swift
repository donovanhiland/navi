import AppKit

@MainActor
enum ScreenFlash {
    static func show(_ captured: CapturedImage, on screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contents = captured.image
        window.contentView = view
        window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            window.orderOut(nil)
        }
    }
}
