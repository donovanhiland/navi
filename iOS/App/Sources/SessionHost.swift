@preconcurrency import AVFoundation
import Foundation
import NaviPad
import Observation
import os
@preconcurrency import Speech

@MainActor
@Observable
final class SessionHost {
    enum ModelStatus: Equatable {
        case missing
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: PadState = .off
    private(set) var micAllowed: Bool
    private(set) var model: ModelStatus
    private(set) var problem: String?

    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private let channel = DarwinChannel(prefix: PadConfig.signalPrefix)
    @ObservationIgnored private let store = PadStore(appGroup: PadConfig.appGroup)
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var live: Task<Void, Never>?
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var modelTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.donovanhiland.navi.ios", category: "Session")
    private static let meterInterval: Duration = .milliseconds(80)
    private static let meterStep = 0.02
    private static let liveInterval: Duration = .milliseconds(600)

    init() {
        micAllowed = AVAudioApplication.shared.recordPermission == .granted
        model = ParakeetModel.isDownloaded ? .loading : .missing
        if store == nil { problem = "Navi can't reach its shared storage. The App Group is missing from the signing setup." }
        channel.observe([.start, .stop, .cancel, .ping]) { [weak self] signal in
            Task { @MainActor in self?.handle(signal) }
        }
        observeAudioSession()
        publish(.off)
        #if DEBUG
        if DemoScript.isOn {
            startDemoSession()
            return
        }
        #endif
        if ParakeetModel.isDownloaded { loadModel() }
        TextCleaner.prewarm()
    }

    var isWarm: Bool { state.isWarm(at: .now) }

    func requestMic() async {
        _ = await ensurePermissions()
    }

    func startSession() async {
        #if DEBUG
        if DemoScript.isOn {
            startDemoSession()
            return
        }
        #endif
        guard await ensurePermissions() else {
            problem = "Navi needs the microphone. Turn it on in Settings › Navi."
            return
        }
        do {
            try AudioSessionSetup.activate()
            try recorder.start()
        } catch {
            Self.logger.error("Mic start failed: \(error.localizedDescription, privacy: .public)")
            problem = "The mic didn't start: \(error.localizedDescription)"
            publish(state.turnedOff(message: problem))
            return
        }
        problem = nil
        let until = Date.now.addingTimeInterval(PadState.readyLength)
        publish(state.isWarm(at: .now) ? state.extended(until: until) : state.ready(until: until))
        channel.post(.pong)
        startClock()
    }

    func endSession(message: String? = nil) {
        stopListeningTasks()
        finishing?.cancel()
        clock?.cancel()
        recorder.stop()
        do { try AudioSessionSetup.deactivate() } catch {
            Self.logger.error("Session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
        publish(state.turnedOff(message: message))
    }

    func loadModel() {
        guard model != .ready, modelTask == nil else { return }
        model = .loading
        modelTask = Task {
            defer { modelTask = nil }
            do {
                try await ParakeetModel.shared.prepare()
                model = .ready
            } catch {
                Self.logger.error("Parakeet load failed: \(error.localizedDescription, privacy: .public)")
                model = .failed(error.localizedDescription)
            }
        }
    }

    private func handle(_ signal: PadSignal) {
        switch signal {
        case .ping: if state.isWarm(at: .now) { channel.post(.pong) }
        case .start: beginListening()
        case .stop: finishListening()
        case .cancel: cancelListening()
        case .pong, .changed: break
        }
    }

    private func beginListening() {
        #if DEBUG
        if DemoScript.isOn {
            beginDemoListening()
            return
        }
        #endif
        guard state.isWarm(at: .now), recorder.isRunning else {
            publish(state.turnedOff())
            return
        }
        guard state.acceptsStart else { return }
        finishing?.cancel()
        recorder.beginCapture()
        let now = Date.now
        publish(state.listening(at: now, until: now.addingTimeInterval(PadState.readyLength)))
        meter = Task { [weak self] in await self?.runMeter() }
        live = Task { [weak self] in await self?.runLivePasses() }
    }

    private func finishListening() {
        guard state.phase == .listening else { return }
        #if DEBUG
        if DemoScript.isOn {
            finishDemoListening()
            return
        }
        #endif
        stopListeningTasks()
        let audio = recorder.endCapture()
        publish(state.cleaning())
        finishing = Task { [weak self] in
            do {
                let transcript = try await Transcriber.finish(audio)
                guard let self, !Task.isCancelled else { return }
                if transcript.cleaned.isEmpty {
                    publish(state.failed("Didn't hear anything"))
                } else {
                    publish(state.done(raw: transcript.raw, cleaned: transcript.cleaned, id: UUID()))
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                Self.logger.error("Transcribe failed: \(error.localizedDescription, privacy: .public)")
                publish(state.failed("Couldn't turn that into text"))
            }
        }
    }

    private func cancelListening() {
        guard state.phase == .listening || state.phase == .cleaning else { return }
        stopListeningTasks()
        finishing?.cancel()
        _ = recorder.endCapture()
        publish(state.cancelled())
    }

    private func stopListeningTasks() {
        meter?.cancel()
        live?.cancel()
    }

    private func runMeter() async {
        while !Task.isCancelled, state.phase == .listening {
            let level = recorder.level
            if abs(level - state.level) >= Self.meterStep { publish(state.withLevel(level)) }
            try? await Task.sleep(for: Self.meterInterval)
        }
    }

    private func runLivePasses() async {
        while !Task.isCancelled, state.phase == .listening {
            try? await Task.sleep(for: Self.liveInterval)
            guard model == .ready, !Task.isCancelled else { continue }
            let audio = recorder.recent(seconds: Transcriber.liveWindowSeconds)
            do {
                let started = ContinuousClock.now
                let words = try await Transcriber.livePass(audio)
                let took = ContinuousClock.now - started
                Self.logger.info("Live pass \(audio.seconds, privacy: .public) s audio, \(took, privacy: .public), \(words.count, privacy: .public) chars, level \(self.recorder.level, privacy: .public)")
                guard !Task.isCancelled, !words.isEmpty else { continue }
                publish(state.heard(words))
            } catch {
                Self.logger.error("Live pass failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if state.phase != .off, !state.isWarm(at: .now) {
                    endSession(message: "Mic turned off after 15 minutes")
                    return
                }
            }
        }
    }

    private func publish(_ next: PadState) {
        state = next
        guard let store else { return }
        do {
            try store.write(next)
        } catch {
            Self.logger.error("State write failed: \(error.localizedDescription, privacy: .public)")
        }
        channel.post(.changed)
    }

    private func ensurePermissions() async -> Bool {
        let mic: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: mic = true
        case .denied: mic = false
        default: mic = await AVAudioApplication.requestRecordPermission()
        }
        micAllowed = mic
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await Self.requestSpeechAuthorization()
        }
        return mic
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.endSession(message: "The mic stopped for a call or another app") }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endSession(message: "The mic stopped. Start it again.") }
        })
    }
}

#if DEBUG
extension SessionHost {
    fileprivate func startDemoSession() {
        micAllowed = true
        model = .ready
        problem = nil
        do {
            try AudioSessionSetup.activate()
            if !recorder.isRunning { try recorder.start() }
        } catch {
            Self.logger.error("Demo mic start failed: \(error.localizedDescription, privacy: .public)")
        }
        let until = Date.now.addingTimeInterval(PadState.readyLength)
        publish(state.isWarm(at: .now) ? state.extended(until: until) : state.ready(until: until))
        channel.post(.pong)
    }

    fileprivate func beginDemoListening() {
        guard state.acceptsStart else { return }
        finishing?.cancel()
        let now = Date.now
        publish(state.listening(at: now, until: now.addingTimeInterval(PadState.readyLength)))
        live = Task { [weak self] in await self?.runDemoWords() }
    }

    private func runDemoWords() async {
        let words = DemoScript.words
        for count in 1...words.count {
            try? await Task.sleep(for: DemoScript.wordStep)
            guard !Task.isCancelled, state.phase == .listening else { return }
            publish(state.heard(words.prefix(count).joined(separator: " ")).withLevel(DemoScript.level(at: count)))
        }
        while !Task.isCancelled, state.phase == .listening {
            try? await Task.sleep(for: Self.meterInterval)
            publish(state.withLevel(0.12))
        }
    }

    fileprivate func finishDemoListening() {
        stopListeningTasks()
        publish(state.heard(DemoScript.raw).cleaning())
        finishing = Task { [weak self] in
            try? await Task.sleep(for: DemoScript.cleanupTime)
            guard let self, !Task.isCancelled else { return }
            publish(state.done(raw: DemoScript.raw, cleaned: DemoScript.cleaned, id: UUID()))
        }
    }
}
#endif
