import Foundation

struct CaptureRouter<Chunk, Sink> {
    private(set) var captures: [(id: UUID, sink: Sink)] = []
    var preRoll: PreRollBuffer<Chunk>

    init(preRollCapacity: Int) {
        preRoll = PreRollBuffer(capacity: preRollCapacity)
    }

    var isCapturing: Bool { !captures.isEmpty }

    var ids: [UUID] { captures.map(\.id) }

    mutating func begin(id: UUID, sink: Sink, includePreRoll: Bool) -> [(sink: Sink, chunk: Chunk)] {
        captures.append((id, sink))
        let kept = preRoll.drain()
        return includePreRoll ? kept.map { (sink, $0) } : []
    }

    mutating func end(id: UUID) -> Sink? {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return nil }
        return captures.remove(at: index).sink
    }

    mutating func endAll() -> [Sink] {
        defer { captures = [] }
        return captures.map(\.sink)
    }

    mutating func receive(_ chunk: Chunk, frames: Int) -> [(sink: Sink, chunk: Chunk)] {
        guard !captures.isEmpty else {
            preRoll.append(chunk, frames: frames)
            return []
        }
        return captures.map { ($0.sink, chunk) }
    }
}
