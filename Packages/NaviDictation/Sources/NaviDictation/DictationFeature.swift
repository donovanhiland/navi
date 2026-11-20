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
    private let triggerStore = DictationTriggerStore(defaults: .standard)
    private var isSuspended = false
    private let pill = DictationPill()
    private let microphone = Microphone()
    private var monitor: FnKeyMonitor?
    private var session: Session?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var lastJob: Task<Void, Never>?
    private var isProcessing: Bool { !jobs.isEmpty }
    private var isStarted = false
    private var levelTimer: Timer?
    private var learnTask: Task<Void, Never>?

    public let vocabulary = VocabularyStore()

    public var onProblem: (@MainActor (String) -> Void)?

    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if isStarted, !isSuspended { newValue ? attachMonitor() : detachMonitor() }
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

    public private(set) lazy var trigger: DictationTrigger = triggerStore.load()

    public func setTrigger(_ newValue: DictationTrigger) {
        guard newValue != trigger else { return }
        trigger = newValue
        triggerStore.save(newValue)
        Self.logger.info("Talk to Type key is now \(newValue.name, privacy: .public)")
        guard monitor != nil else { return }
        detachMonitor()
        attachMonitor()
    }

    public var needsFnKey: Bool { isEnabled && trigger.usesFnKey }

    public func suspendTrigger() {
        isSuspended = true
        detachMonitor()
    }

    public func resumeTrigger() {
        isSuspended = false
        if isStarted, isEnabled { attachMonitor() }
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
        microphone.onCaptureLost { [weak self] ids in
            Task { @MainActor in self?.captureLost(ids) }
        }
    }

    private func captureLost(_ ids: [UUID]) {
        var lost = false
        for id in ids {
            if session?.id == id {
                cancelSession()
                monitor?.reset()
                lost = true
            }
            if let job = jobs[id] {
                job.cancel()
                lost = true
            }
        }
        guard lost else { return }
        onProblem?("The microphone stopped, so nothing was typed. Try again.")
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
        guard !isSuspended else { return }
        if monitor == nil {
            monitor = FnKeyMonitor(
                onAction: { [weak self] action in self?.handle(action) },
                onIdleEscape: { [weak self] in self?.cancelProcessing(reason: "Esc") }
            )
        }
        let trigger = trigger
        monitor?.tapToggles = tapToggles
        monitor?.trigger = trigger
        if monitor?.start() == false {
            Self.logger.error("Could not register \(trigger.name, privacy: .public) for Talk to Type")
            onProblem?("Navi could not use \(trigger.name) for Talk to Type. Another app may own it.")
        }
    }

    private func detachMonitor() {
        monitor?.stop()
        monitor = nil
        cancelProcessing(reason: "Talk to Type turned off")
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

    private struct Heard: Sendable {
        let text: String
        let engine: String
    }

    private struct Session {
        let id: UUID
        let transcription: Task<Heard, any Error>
        let pressedAt: ContinuousClock.Instant
        let sourceApp: String?
        let sourceBundleID: String?
    }

    private func begin() {
        guard session == nil else {
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
        let transcription = Task.detached { () -> Heard in
            let engine = await SpeechEngines.best()
            let name = String(describing: type(of: engine))
            if engine is ParakeetEngine {
                return Heard(text: try await LiveDictation(onPartial: onPartial).transcribe(audio: stream), engine: name)
            }
            let raw = try await engine.transcribe(audio: stream, onPartial: onPartial)
            return Heard(text: await TextCleaner().clean(raw), engine: name)
        }
        let app = NSWorkspace.shared.frontmostApplication
        let session = Session(
            id: id, transcription: transcription, pressedAt: .now,
            sourceApp: app?.localizedName, sourceBundleID: app?.bundleIdentifier
        )
        self.session = session

        let microphone = microphone
        if microphone.isRunning {
            microphone.beginCapture(id: id, into: continuation, includePreRoll: true)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try microphone.open()
            } catch {
                await MainActor.run {
                    Self.logger.error("Could not start the microphone: \(error.localizedDescription)")
                    continuation.finish()
                    guard let self, self.session?.id == session.id else { return }
                    self.cancelSession()
                    self.monitor?.reset()
                    self.onProblem?("Navi could not start the microphone.")
                }
                return
            }
            await MainActor.run {
                guard let self, self.session?.id == session.id else {
                    continuation.finish()
                    self?.updateMicrophone()
                    return
                }
                microphone.beginCapture(id: session.id, into: continuation, includePreRoll: true)
                Self.logger.info("Microphone ready \((ContinuousClock.now - session.pressedAt).milliseconds) ms after the press")
            }
        }
    }

    private func showLiveText(_ text: String, for id: UUID) {
        guard session?.id == id, !text.isEmpty else { return }
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
        let previous = lastJob
        let released = ContinuousClock.now
        let job = Task {
            await self.process(session, released: released, after: previous)
            await previous?.value
        }
        jobs[session.id] = job
        lastJob = job
    }

    private func process(_ session: Session, released: ContinuousClock.Instant, after previous: Task<Void, Never>?) async {
        let id = session.id
        defer {
            jobs[id] = nil
            if jobs.isEmpty {
                lastJob = nil
                if self.session == nil { pill.hide() }
                updateMicrophone()
            }
        }
        await microphone.waitForReleaseTail(releasedAt: released)
        let tail = ContinuousClock.now - released
        microphone.endCapture(id: id)
        let heard: Heard
        do {
            let transcription = session.transcription
            heard = try await withTaskCancellationHandler {
                try await transcription.value
            } onCancel: {
                transcription.cancel()
            }
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Speech failed: \(error.localizedDescription)")
            onProblem?("Navi could not turn your speech into text. Try again.")
            return
        }
        await previous?.value
        guard !Task.isCancelled else { return }
        if self.session == nil, jobs.keys.allSatisfy({ $0 == id }) { pill.hide() }
        Self.logger.info(
            "Release to text: \((ContinuousClock.now - released).milliseconds) ms (tail \(tail.milliseconds) ms), engine \(heard.engine, privacy: .public), \(heard.text.split(whereSeparator: \.isWhitespace).count) words"
        )
        let text = heard.text
        guard !text.isEmpty else { return }
        guard TextInserter.hasAccessibility else {
            TextInserter.requestAccessibility()
            onProblem?("Navi needs the Accessibility permission to type your text.")
            inbox.add(text: text, kind: .dictation, sourceApp: session.sourceApp, sourceBundleID: session.sourceBundleID)
            return
        }
        guard await TextInserter.insert(text) else { return }
        inbox.add(text: text, kind: .dictation, sourceApp: session.sourceApp, sourceBundleID: session.sourceBundleID)
    }

    private func cancelProcessing(reason: String) {
        guard isProcessing else { return }
        jobs.values.forEach { $0.cancel() }
        if session == nil { pill.hide() }
        Self.logger.info("Dictation cancelled while processing: \(reason, privacy: .public)")
    }

    private func cancelSession() {
        guard let session else {
            if isProcessing { cancelProcessing(reason: "Esc") } else { pill.hide() }
            return
        }
        self.session = nil
        levelTimer?.invalidate()
        levelTimer = nil
        microphone.endCapture(id: session.id)
        session.transcription.cancel()
        if isProcessing {
            pill.model.phase = .thinking
        } else {
            pill.hide()
        }
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
