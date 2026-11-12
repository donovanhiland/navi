import AppKit
import NaviCore
import os

@MainActor
public final class DictationFeature {
    private static let enabledKey = "dictation.enabled"
    private static let keepReadyKey = "dictation.keepMicrophoneReady"
    nonisolated private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Dictation")

    private let inbox: Inbox
    private let pill = DictationPill()
    private let microphone = Microphone()
    private var monitor: FnKeyMonitor?
    private var session: Session?
    private var isProcessing = false
    private var isStarted = false
    private var levelTimer: Timer?

    public var onProblem: (@MainActor (String) -> Void)?

    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if isStarted { newValue ? attachMonitor() : detachMonitor() }
            updateMicrophone()
        }
    }

    public var keepsMicrophoneReady: Bool {
        get { UserDefaults.standard.object(forKey: Self.keepReadyKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.keepReadyKey)
            updateMicrophone()
        }
    }

    public var hasChosen: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) != nil }

    public init(inbox: Inbox) {
        self.inbox = inbox
    }

    public func start() {
        isStarted = true
        SpeechEngines.warmUpParakeet()
        TextCleaner.prewarm()
        if isEnabled { attachMonitor() }
        updateMicrophone()
    }

    public func stop() {
        isStarted = false
        detachMonitor()
        microphone.close()
    }

    private func updateMicrophone() {
        let microphone = microphone
        let usable = isStarted && isEnabled && DictationPermissions.microphone == .granted
        guard session == nil, !isProcessing else { return }
        guard usable else {
            microphone.close()
            return
        }
        if keepsMicrophoneReady {
            guard !microphone.isRunning else { return }
            Task.detached(priority: .userInitiated) {
                do { try microphone.open() } catch {
                    Self.logger.error("Could not keep the microphone ready: \(error.localizedDescription)")
                }
            }
        } else {
            microphone.pause()
            Task.detached(priority: .utility) {
                do { try microphone.prepare() } catch {
                    Self.logger.error("Could not set up the microphone: \(error.localizedDescription)")
                }
            }
        }
    }

    public func borrowFnKey() { SystemFnKey.takeOver() }

    public func giveBackFnKey() { SystemFnKey.giveBack() }

    public var isFnKeyBorrowed: Bool { SystemFnKey.isTakenOver }

    public static var hasPermissions: Bool { DictationPermissions.allGranted }

    public static func requestPermissions() async -> Bool { await DictationPermissions.requestAll() }

    private func attachMonitor() {
        if monitor == nil {
            monitor = FnKeyMonitor { [weak self] action in self?.handle(action) }
        }
        monitor?.start()
    }

    private func detachMonitor() {
        monitor?.stop()
        monitor = nil
        cancelSession()
    }

    private func handle(_ action: FnGesture.Action) {
        switch action {
        case .begin: begin()
        case .lock: lock()
        case .commit: commit()
        case .cancel: cancelSession()
        }
    }

    private struct Session {
        let id = UUID()
        let transcription: Task<String, any Error>
        let pressedAt: ContinuousClock.Instant
        let sourceApp: String?
        let sourceBundleID: String?
    }

    private func begin() {
        guard session == nil, !isProcessing else {
            monitor?.reset()
            return
        }
        guard DictationPermissions.microphone == .granted, DictationPermissions.speechRecognition != .denied else {
            askForPermissions()
            return
        }
        guard DictationPermissions.speechRecognition == .granted else {
            askForPermissions()
            return
        }

        pill.show()
        startLevelTimer()
        TextCleaner.prewarm()

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let transcription = Task.detached { () -> String in
            let engine = await SpeechEngines.best()
            if engine is ParakeetEngine { return try await LiveDictation().transcribe(audio: stream) }
            let raw = try await engine.transcribe(audio: stream)
            return await TextCleaner().clean(raw)
        }
        let app = NSWorkspace.shared.frontmostApplication
        let session = Session(
            transcription: transcription, pressedAt: .now,
            sourceApp: app?.localizedName, sourceBundleID: app?.bundleIdentifier
        )
        self.session = session

        let microphone = microphone
        if microphone.isRunning {
            microphone.beginCapture(into: continuation, includePreRoll: true)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try microphone.open()
            } catch {
                await MainActor.run {
                    Self.logger.error("Could not start the microphone: \(error.localizedDescription)")
                    continuation.finish()
                    self?.cancelSession()
                    self?.onProblem?("Navi could not start the microphone.")
                }
                return
            }
            await MainActor.run {
                guard let self, self.session?.id == session.id else {
                    continuation.finish()
                    return
                }
                microphone.beginCapture(into: continuation, includePreRoll: false)
                Self.logger.info("Microphone ready \((ContinuousClock.now - session.pressedAt).milliseconds) ms after the press")
            }
        }
    }

    private func lock() {
        guard session != nil else { return }
        pill.model.isLocked = true
    }

    private func commit() {
        guard let session else { return }
        self.session = nil
        levelTimer?.invalidate()
        levelTimer = nil
        pill.model.phase = .thinking
        isProcessing = true
        let released = ContinuousClock.now

        Task {
            defer {
                isProcessing = false
                updateMicrophone()
            }
            await microphone.waitForReleaseTail(releasedAt: released)
            let tail = ContinuousClock.now - released
            microphone.endCapture()
            let text: String
            do {
                text = try await session.transcription.value
            } catch {
                Self.logger.error("Speech failed: \(error.localizedDescription)")
                text = ""
            }
            pill.hide()
            Self.logger.info(
                "Release to text: \((ContinuousClock.now - released).milliseconds) ms (tail \(tail.milliseconds) ms)"
            )
            guard !text.isEmpty else { return }
            guard TextInserter.hasAccessibility else {
                TextInserter.requestAccessibility()
                onProblem?("Navi needs the Accessibility permission to type your text.")
                inbox.add(text: text, kind: .dictation, sourceApp: session.sourceApp, sourceBundleID: session.sourceBundleID)
                return
            }
            await TextInserter.insert(text)
            inbox.add(text: text, kind: .dictation, sourceApp: session.sourceApp, sourceBundleID: session.sourceBundleID)
        }
    }

    private func cancelSession() {
        guard let session else {
            if !isProcessing { pill.hide() }
            return
        }
        self.session = nil
        levelTimer?.invalidate()
        levelTimer = nil
        microphone.endCapture()
        session.transcription.cancel()
        pill.hide()
        updateMicrophone()
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        let microphone = microphone
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let level = microphone.level
            MainActor.assumeIsolated { self?.pill.model.push(level: level) }
        }
    }
    private func askForPermissions() {
        monitor?.reset()
        Task {
            if await DictationPermissions.requestAll() {
                return
            }
            onProblem?("Dictation needs the Microphone and Speech Recognition permissions. Turn them on in System Settings > Privacy & Security.")
        }
    }
}

extension TextInserter {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
