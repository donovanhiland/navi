import AppKit
import NaviCore
import os

/// Talk to type. Hold fn (Globe) to talk; release to type the text at the cursor in the front app.
/// Double-tap fn to lock hands-free mode; one fn tap ends it.
///
/// While listening, a small pill with a live waveform shows at the bottom of the screen with the mouse.
/// Speech runs on the Mac (`SpeechAnalyzer` on macOS 26 and newer, `SFSpeechRecognizer` before that).
/// A cleanup pass removes filler words and fixes punctuation (rules, then Apple Foundation Models for
/// sentences that need more). With Parakeet, speech and cleanup run while the user talks
/// (`LiveDictation`), so the release waits only for the last sentence. The text is pasted with ⌘V, so
/// Navi needs the Accessibility permission.
/// Each result is also added to the Inbox as a `.dictation` item.
///
/// How the app uses it:
/// ```swift
/// let dictation = DictationFeature(inbox: inbox)
/// dictation.onProblem = { message in ... }   // optional: show the message to the user
/// dictation.start()                          // at launch
/// dictation.borrowFnKey()                    // optional: stop macOS from acting on fn
/// // at quit:
/// dictation.stop()
/// dictation.giveBackFnKey()
/// ```
/// Call `DictationFeature.requestPermissions()` early (for example from a menu item) so the Microphone
/// and Speech Recognition prompts do not appear in the middle of a first dictation.
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

    /// Called with a short message when dictation cannot work (missing permission, no microphone).
    public var onProblem: (@MainActor (String) -> Void)?

    /// The user's choice to use dictation. Saved between launches. It starts as `true`.
    /// Changing it while the feature runs turns the fn key listener on or off.
    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if isStarted { newValue ? attachMonitor() : detachMonitor() }
            updateMicrophone()
        }
    }

    /// Hex's "Keep ready" mode: the microphone stays open between dictations, so a press records at
    /// once, including the moment just before it. macOS shows the microphone indicator while it is on.
    /// Off (the default, like Wispr Flow): the microphone is set up ahead of time and starts on each
    /// press, with no indicator in between. Saved; starts as `false`.
    public var keepsMicrophoneReady: Bool {
        get { UserDefaults.standard.object(forKey: Self.keepReadyKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.keepReadyKey)
            updateMicrophone()
        }
    }

    /// False until the user turns talk to type on or off for the first time.
    public var hasChosen: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) != nil }

    public init(inbox: Inbox) {
        self.inbox = inbox
    }

    /// Starts listening for the fn key when `isEnabled` is true.
    public func start() {
        isStarted = true
        SpeechEngines.warmUpParakeet()
        TextCleaner.prewarm()
        if isEnabled { attachMonitor() }
        updateMicrophone()
    }

    /// Stops listening and drops a session that is running. Does not give back the fn key.
    public func stop() {
        isStarted = false
        detachMonitor()
        microphone.close()
    }

    /// Keeps the microphone in the right state between dictations: open (Keep ready), set up but off
    /// (warm, the default), or taken down (talk to type off, or no Microphone permission).
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

    // MARK: fn key setting

    /// Sets the macOS fn key action to "Do Nothing" while Navi runs. Keeps a backup of the old value.
    public func borrowFnKey() { SystemFnKey.takeOver() }

    /// Puts the macOS fn key action back exactly as it was.
    public func giveBackFnKey() { SystemFnKey.giveBack() }

    /// True when Navi holds the fn key setting.
    public var isFnKeyBorrowed: Bool { SystemFnKey.isTakenOver }

    // MARK: Permissions

    /// True when Microphone and Speech Recognition are granted.
    public static var hasPermissions: Bool { DictationPermissions.allGranted }

    /// Shows the macOS prompts for Microphone and Speech Recognition. Returns true when both are granted.
    public static func requestPermissions() async -> Bool { await DictationPermissions.requestAll() }

    // MARK: Monitor

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

    // MARK: Session

    /// One run of listening: the mic, the audio stream, and the speech task.
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
        // Speech Recognition not decided yet: ask now and skip this press. Later presses work.
        guard DictationPermissions.speechRecognition == .granted else {
            askForPermissions()
            return
        }

        // The pill first, so the press feels instant. The rest catches up behind it.
        pill.show()
        startLevelTimer()
        TextCleaner.prewarm()

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        // The cleaned text. Parakeet works while the user talks; Apple's engines clean up after.
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
            // Keep ready: recording already runs, with the moment before the press.
            microphone.beginCapture(into: continuation, includePreRoll: true)
            return
        }
        // Release when idle (or not ready yet): open the microphone off the main thread.
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
                // Released before the microphone was ready: nothing to record (like Hex).
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

    /// The user is done talking: keep the end of the last word, stop the capture, and type the text.
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
                // The text is not lost: it goes to the history.
                inbox.add(text: text, kind: .dictation, sourceApp: session.sourceApp, sourceBundleID: session.sourceBundleID)
                return
            }
            await TextInserter.insert(text)
            inbox.add(text: text, kind: .dictation, sourceApp: session.sourceApp, sourceBundleID: session.sourceBundleID)
        }
    }

    /// Drops the session and the audio. Nothing is typed.
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
