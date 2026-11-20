import AVFoundation
import FluidAudio
import Testing
@testable import NaviDictation

@Suite("Parakeet samples")
struct ParakeetSamplesTests {
    private func buffer(rate: Double, seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    @Test("audio after an input format change is kept")
    func mixedFormats() throws {
        let buffers = [
            buffer(rate: 48000, seconds: 1),
            buffer(rate: 48000, seconds: 1),
            buffer(rate: 24000, seconds: 1),
            buffer(rate: 16000, seconds: 1),
        ]
        let samples = try ParakeetEngine.samples(of: buffers)
        #expect(abs(samples.count - 64000) < 400)
    }

    @Test("short audio is padded to Parakeet's minimum, longer audio is left alone")
    func padding() {
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16000)
        #expect(ParakeetModel.padded(Array(repeating: 1, count: 2000)).count == minimum)
        #expect(ParakeetModel.padded(Array(repeating: 1, count: minimum + 5)).count == minimum + 5)
    }

    @Test("no buffers give no samples")
    func empty() throws {
        #expect(try ParakeetEngine.samples(of: []).isEmpty)
    }
}
