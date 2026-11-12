import AppKit
import AVFoundation

@MainActor
final class CameraBubble {
    private static let diameter: CGFloat = 160

    private var panel: NSPanel?
    private var session: SessionBox?

    var isVisible: Bool { panel != nil }

    func show(inside region: CGRect) async -> Bool {
        guard panel == nil else { return true }
        guard await Permissions.camera(), let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        guard panel == nil else { return true }

        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        let size = Self.diameter
        let origin = CGPoint(x: region.maxX - size - 24, y: region.minY + 24)
        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: CGSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        panel.contentView = view
        panel.orderFrontRegardless()

        let box = SessionBox(session)
        box.start()
        self.session = box
        self.panel = panel
        return true
    }

    func hide() {
        session?.stop()
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class SessionBox: @unchecked Sendable {
    private let session: AVCaptureSession
    private let queue = DispatchQueue(label: "co.navi.recording.camera")

    init(_ session: AVCaptureSession) { self.session = session }

    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }
}
