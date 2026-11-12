@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import os

struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

enum DictationError: Error, LocalizedError {
    case noMicrophone
    case speechUnavailable

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone input is available."
        case .speechUnavailable: "On-device speech recognition is not available for this language."
        }
    }
}

struct PreRollBuffer<Chunk> {
    let capacity: Int
    private(set) var chunks: [(chunk: Chunk, frames: Int)] = []
    private(set) var frames = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ chunk: Chunk, frames count: Int) {
        chunks.append((chunk, count))
        frames += count
        while let first = chunks.first, frames - first.frames >= capacity {
            frames -= first.frames
            chunks.removeFirst()
        }
    }

    mutating func drain() -> [Chunk] {
        defer {
            chunks = []
            frames = 0
        }
        return chunks.map(\.chunk)
    }
}

final class Microphone: @unchecked Sendable {
    static let preRoll: Double = 0.45
    static let quietToEnd: Duration = .milliseconds(200)
    static let minimumTail: Duration = .milliseconds(40)
    static let maximumTail: Duration = .milliseconds(600)
    static let soundLevel: Float = 0.45

    private struct State: @unchecked Sendable {
        var running = false
        var unit: AudioUnit?
        var format: AVAudioFormat?
        var sink: AsyncStream<AudioChunk>.Continuation?
        var preRoll = PreRollBuffer<AVAudioPCMBuffer>(capacity: 0)
        var level: Float = 0
        var lastSound: ContinuousClock.Instant?
    }

    private let setup = NSRecursiveLock()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Microphone")
    private let listenerQueue = DispatchQueue(label: "com.donovanhiland.navi.microphone")
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let (wasRunning, wasPrepared) = state.withLockUnchecked { ($0.running, $0.unit != nil) }
            guard wasPrepared else { return }
            Self.logger.info("Default input changed; setting up the microphone again")
            close()
            do {
                if wasRunning { try open() } else { try prepare() }
            } catch {
                Self.logger.error("Could not set up the new input: \(error.localizedDescription)")
            }
        }
        defaultInputListener = listener
        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener)
    }

    deinit {
        if let defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, defaultInputListener
            )
        }
        close()
    }

    var isRunning: Bool { state.withLock { $0.running } }

    var level: Float { state.withLock { $0.level } }

    func prepare() throws {
        setup.lock()
        defer { setup.unlock() }
        guard state.withLockUnchecked({ $0.unit == nil }) else { return }
        let (unit, format) = try Self.makeInputUnit(context: Unmanaged.passUnretained(self).toOpaque())
        state.withLockUnchecked {
            $0.unit = unit
            $0.format = format
            $0.preRoll = PreRollBuffer(capacity: Int(format.sampleRate * Self.preRoll))
        }
    }

    func open() throws {
        setup.lock()
        defer { setup.unlock() }
        guard !isRunning else { return }
        try prepare()
        guard let unit = state.withLockUnchecked({ $0.unit }) else { throw DictationError.noMicrophone }
        try Self.check(AudioOutputUnitStart(unit), "start the input")
        state.withLock { $0.running = true }
    }

    func pause() {
        setup.lock()
        defer { setup.unlock() }
        let (wasRunning, unit, sink) = state.withLockUnchecked { state in
            defer {
                state.running = false
                state.sink = nil
                state.level = 0
                _ = state.preRoll.drain()
            }
            return (state.running, state.unit, state.sink)
        }
        sink?.finish()
        if wasRunning, let unit { AudioOutputUnitStop(unit) }
    }

    func close() {
        setup.lock()
        defer { setup.unlock() }
        pause()
        let unit = state.withLockUnchecked { state -> AudioUnit? in
            defer {
                state.unit = nil
                state.format = nil
            }
            return state.unit
        }
        guard let unit else { return }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func beginCapture(into sink: AsyncStream<AudioChunk>.Continuation, includePreRoll: Bool) {
        let kept = state.withLockUnchecked { state -> [AVAudioPCMBuffer] in
            state.sink = sink
            let kept = state.preRoll.drain()
            return includePreRoll ? kept : []
        }
        for buffer in kept { sink.yield(AudioChunk(buffer: buffer)) }
    }

    func waitForReleaseTail(releasedAt released: ContinuousClock.Instant) async {
        while true {
            let now = ContinuousClock.now
            let lastSound = state.withLock { $0.lastSound }
            if Self.tailIsDone(sinceRelease: now - released, sinceSound: lastSound.map { now - $0 }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func tailIsDone(sinceRelease: Duration, sinceSound: Duration?) -> Bool {
        if sinceRelease < minimumTail { return false }
        if sinceRelease >= maximumTail { return true }
        guard let sinceSound else { return true }
        return sinceSound >= quietToEnd
    }

    func endCapture() {
        let sink = state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            defer { state.sink = nil }
            return state.sink
        }
        sink?.finish()
    }

    private static func makeInputUnit(context: UnsafeMutableRawPointer) throws -> (AudioUnit, AVAudioFormat) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw DictationError.noMicrophone }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "create the input unit")
        guard let unit = created else { throw DictationError.noMicrophone }
        do {
            var on: UInt32 = 1
            var off: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize), "turn input on")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize), "turn output off")

            var device = try defaultInputDevice()
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                UInt32(MemoryLayout<AudioObjectID>.size)
            ), "pick the input device")

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "read the input format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
            else { throw DictationError.noMicrophone }
            var client = format.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set the input format")

            var callback = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: context)
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "set the input callback")
            try check(AudioUnitInitialize(unit), "set up the input unit")
            return (unit, format)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private static func defaultInputDevice() throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultInputAddress
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ), "find the default input")
        guard device != kAudioObjectUnknown else { throw DictationError.noMicrophone }
        return device
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        logger.error("Could not \(step): OSStatus \(status)")
        throw DictationError.noMicrophone
    }

    private static let inputCallback: AURenderCallback = { context, flags, timeStamp, bus, frames, _ in
        let microphone = Unmanaged<Microphone>.fromOpaque(context).takeUnretainedValue()
        return microphone.render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32, frames: UInt32
    ) -> OSStatus {
        guard let (unit, format) = state.withLockUnchecked({ state in state.unit.flatMap { unit in state.format.map { (unit, $0) } } }),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        receive(buffer)
        return noErr
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        let level = Self.loudness(of: buffer)
        let now = ContinuousClock.now
        let sink = state.withLockUnchecked { state -> AsyncStream<AudioChunk>.Continuation? in
            state.level = level
            if level >= Self.soundLevel { state.lastSound = now }
            if state.sink == nil { state.preRoll.append(buffer, frames: Int(buffer.frameLength)) }
            return state.sink
        }
        sink?.yield(AudioChunk(buffer: buffer))
    }

    static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0 ..< Int(buffer.frameLength) {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, min(1, (decibels + 50) / 50))
        return normalized.squareRoot()
    }
}
