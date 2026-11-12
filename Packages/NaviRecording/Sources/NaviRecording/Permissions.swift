import AppKit
import AVFoundation

enum Permissions {
    static func microphone() async -> Bool {
        await authorize(.audio, pane: "Privacy_Microphone")
    }

    static func camera() async -> Bool {
        await authorize(.video, pane: "Privacy_Camera")
    }

    @MainActor
    private static func authorize(_ type: AVMediaType, pane: String) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: type)
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
    }
}
