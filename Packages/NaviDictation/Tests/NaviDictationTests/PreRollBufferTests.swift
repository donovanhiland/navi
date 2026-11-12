import Testing

@testable import NaviDictation

@Suite("Pre-roll buffer")
struct PreRollBufferTests {
    @Test("keeps at least the capacity, dropping whole chunks from the front")
    func keepsTheNewestAudio() {
        var buffer = PreRollBuffer<Int>(capacity: 100)
        for chunk in 1 ... 10 { buffer.append(chunk, frames: 30) }
        #expect(buffer.chunks.map(\.chunk) == [7, 8, 9, 10])
        #expect(buffer.frames == 120)
    }

    @Test("drain hands back the chunks oldest first and empties the buffer")
    func drain() {
        var buffer = PreRollBuffer<Int>(capacity: 50)
        buffer.append(1, frames: 20)
        buffer.append(2, frames: 20)
        #expect(buffer.drain() == [1, 2])
        #expect(buffer.drain().isEmpty)
        #expect(buffer.frames == 0)
    }

    @Test("a zero capacity keeps nothing")
    func zeroCapacity() {
        var buffer = PreRollBuffer<Int>(capacity: 0)
        buffer.append(1, frames: 10)
        buffer.append(2, frames: 10)
        #expect(buffer.chunks.isEmpty)
    }
}
