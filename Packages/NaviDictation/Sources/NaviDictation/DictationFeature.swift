import AppKit
import NaviCore
import Observation
import os

@MainActor
public final class DictationFeature {
    private static let enabledKey = "dictation.enabled"
    private static let keepReadyKey = "dictation.keepMicrophoneReady"
    private static let tapTogglesKey = "dictation.tapToToggle"
    private static let liveTextKey = "dictation.liveText"
    private static let learnWordsKey = "dictation.learnWords"
    private static let learnDelay: Duration = .seconds(5)
    nonisolated private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Dictation")

    private let inbox: Inbox
    private let pill = DictationPill()
    private let microphone = Microphone()
    private var monitor: FnKeyMonitor?
    private var session: Session?
    private var isProcessing = false
    private var processing: Task<Void, Never>?
    private var isStarted = false
    private var levelTimer: Timer?
    private var learnTask: Task<Void, Never>?

    public let vocabulary = VocabularyStore()

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

    public var tapToggles: Bool {
        get { UserDefaults.standard.object(forKey: Self.tapTogglesKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.tapTogglesKey)
            monitor?.tapToggles = newValue
        }
    }

    public var showsLiveText: Bool {
        get { UserDefaults.standard.object(forKey: Self.liveTextKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.liveTextKey) }
    }

    public var learnsWords: Bool {
        get { UserDefaults.standard.object(forKey: Self.learnWordsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.learnWordsKey)
            if newValue { learnSoon() }
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
        vocabulary.applyToEngine()
        watchHistory()
        if isEnabled { attachMonitor() }
        updateMicrophone()
    }

    private func watchHistory() {
        guard isStarted else { return }
        withObservationTracking {
            _ = inbox.items
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchHistory() }
        }
        learnSoon()
    }

    private func learnSoon() {
        guard isStarted, learnsWords else { return }
        learnTask?.cancel()
        learnTask = Task { [weak self] in
            try? await Task.sleep(for: Self.learnDelay)
            guard !Task.isCancelled, let self, self.learnsWords else { return }
            let texts = self.inbox.items.filter { $0.kind == .text }.compactMap(\.text)
            self.vocabulary.learn(from: texts)
        }
    }

    public func stop() {
        isStarted = false
        learnTask?.cancel()
        learnTask = nil
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

    public func pasteLastDictation() {
        guard session == nil, !isProcessing else { return }
        let last = inbox.items.filter { $0.kind == .dictation }.max { $0.createdAt < $1.createdAt }
        guard let text = last?.text else {
            onProblem?("No dictation yet.")
            return
        }
        guard TextInserter.hasAccessibility else {
            TextInserter.requestAccessibility()
            onProblem?("Navi needs the Accessibility permission to type your text.")
            return
        }
        Task { await TextInserter.insert(text) }
    }

    public func borrowFnKey() { SystemFnKey.takeOver() }

    public func giveBackFnKey() { SystemFnKey.giveBack() }

    public var isFnKeyBorrowed: Bool { SystemFnKey.isTakenOver }

    public static var hasPermissions: Bool { DictationPermissions.allGranted }

    public static func requestPermissions() async -> Bool { await DictationPermissions.requestAll() }

    private func attachMonitor() {
        if monitor == nil {
            monitor = FnKeyMonitor(
                onAction: { [weak self] action in self?.handle(action) },
                onIdleEscape: { [weak self] in self?.cancelProcessing() }
            )
        }
        monitor?.tapToggles = tapToggles
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
        let id: UUID
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

        let id = UUID()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        var onPartial: PartialHandler?
        if showsLiveText {
            onPartial = { [weak self] text in
                Task { @MainActor in self?.showLiveText(text, for: id) }
            }
        }
        let transcription = Task.detached { () -> String in
            let engine = await SpeechEngines.best()
            if engine is ParakeetEngine {
                return try await LiveDictation(onPartial: onPartial).transcribe(audio: stream)
            }
            let raw = try await engine.transcribe(audio: stream, onPartial: onPartial)
            return await TextCleaner().clean(raw)
        }
        let app = NSWorkspace.shared.frontmostApplication
        let session = Session(
            id: id, transcription: transcription, pressedAt: .now,
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

    private func showLiveText(_ text: String, for id: UUID) {
        guard session?.id == id else { return }
        pill.model.liveText = text
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

        processing = Task {
            defer {
                isProcessing = false
                processing = nil
                updateMicrophone()
            }
            await microphone.waitForReleaseTail(releasedAt: released)
            let tail = ContinuousClock.now - released
            microphone.endCapture()
            let text: String
            do {
                let transcription = session.transcription
                text = try await withTaskCancellationHandler {
                    try await transcription.value
                } onCancel: {
                    transcription.cancel()
                }
            } catch {
                Self.logger.error("Speech failed: \(error.localizedDescription)")
                text = ""
            }
            guard !Task.isCancelled else { return }
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

    private func cancelProcessing() {
        guard let processing else { return }
        processing.cancel()
        pill.hide()
        Self.logger.info("Dictation cancelled with Esc while processing")
    }

    private func cancelSession() {
        guard let session else {
            if isProcessing { cancelProcessing() } else { pill.hide() }
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
