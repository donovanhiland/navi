import Foundation
import Testing
@testable import NaviDictation

@Suite("Capture router")
struct CaptureRouterTests {
    typealias Router = CaptureRouter<Int, String>

    private func labels(_ yields: [(sink: String, chunk: Int)]) -> [String] {
        yields.map { "\($0.sink):\($0.chunk)" }
    }

    @Test("kept audio goes first, in order, then live audio")
    func preRollFirst() {
        var router = Router(preRollCapacity: 100)
        _ = router.receive(1, frames: 10)
        _ = router.receive(2, frames: 10)
        let begin = router.begin(id: UUID(), sink: "a", includePreRoll: true)
        #expect(labels(begin) == ["a:1", "a:2"])
        #expect(labels(router.receive(3, frames: 10)) == ["a:3"])
    }

    @Test("without the kept audio, it is dropped, not sent later")
    func preRollDropped() {
        var router = Router(preRollCapacity: 100)
        _ = router.receive(1, frames: 10)
        #expect(router.begin(id: UUID(), sink: "a", includePreRoll: false).isEmpty)
        #expect(router.preRoll.chunks.isEmpty)
    }

    @Test("a new capture while the old one finishes its tail: both get the audio")
    func overlap() {
        var router = Router(preRollCapacity: 100)
        let first = UUID()
        _ = router.begin(id: first, sink: "a", includePreRoll: false)
        _ = router.begin(id: UUID(), sink: "b", includePreRoll: false)
        #expect(labels(router.receive(1, frames: 10)) == ["a:1", "b:1"])
        #expect(router.end(id: first) == "a")
        #expect(labels(router.receive(2, frames: 10)) == ["b:2"])
    }

    @Test("ending an old capture leaves the new one alone, and ends only once")
    func endIsScoped() {
        var router = Router(preRollCapacity: 100)
        let first = UUID()
        let second = UUID()
        _ = router.begin(id: first, sink: "a", includePreRoll: false)
        _ = router.begin(id: second, sink: "b", includePreRoll: false)
        #expect(router.end(id: first) == "a")
        #expect(router.end(id: first) == nil)
        #expect(router.ids == [second])
    }

    @Test("with no capture, audio is kept for the next press")
    func idleKeepsPreRoll() {
        var router = Router(preRollCapacity: 100)
        let id = UUID()
        _ = router.begin(id: id, sink: "a", includePreRoll: false)
        _ = router.end(id: id)
        #expect(router.receive(1, frames: 10).isEmpty)
        #expect(router.preRoll.chunks.map(\.chunk) == [1])
    }

    @Test("ending everything finishes old and new captures")
    func endAll() {
        var router = Router(preRollCapacity: 100)
        _ = router.begin(id: UUID(), sink: "a", includePreRoll: false)
        _ = router.begin(id: UUID(), sink: "b", includePreRoll: false)
        #expect(router.endAll() == ["a", "b"])
        #expect(!router.isCapturing)
    }
}
