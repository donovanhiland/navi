import AVFoundation
@preconcurrency import Speech

public enum DictationPermissions {
    public enum Status: Sendable, Equatable {
        case notDetermined
        case granted
        case denied
    }

    public static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public static var speechRecognition: Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public static var allGranted: Bool { microphone == .granted && speechRecognition == .granted }

    public static func requestMicrophone() async -> Bool {
        if microphone == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        return microphone == .granted
    }

    public static func requestSpeechRecognition() async -> Bool {
        if speechRecognition == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        return speechRecognition == .granted
    }

    public static func requestAll() async -> Bool {
        let microphone = await requestMicrophone()
        let speech = await requestSpeechRecognition()
        return microphone && speech
    }
}
