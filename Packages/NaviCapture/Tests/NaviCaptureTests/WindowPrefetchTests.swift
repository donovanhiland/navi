import CoreGraphics
import Synchronization
import Testing

@testable import NaviCapture

@MainActor
@Suite struct WindowPrefetchTests {
    final class Calls: Sendable {
        let ids = Mutex<[CGWindowID]>([])
    }

    private static func image() throws -> CapturedImage {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return CapturedImage(image: try #require(context.makeImage()), scale: 1)
    }

    private func settle() async throws {
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func hoveringAWindowCapturesItOnce() async throws {
        let calls = Calls()
        let image = try Self.image()
        let prefetch = WindowPrefetch { id in
            calls.ids.withLock { $0.append(id) }
            return image
        }
        prefetch.want(7)
        prefetch.want(7)
        try await settle()
        #expect(prefetch.readyImage(for: 7) != nil)
        #expect(prefetch.readyImage(for: 8) == nil)
        #expect(calls.ids.withLock { $0 } == [7])
    }

    @Test func movingQuicklyAcrossWindowsOnlyCapturesWhereThePointerStops() async throws {
        let calls = Calls()
        let image = try Self.image()
        let prefetch = WindowPrefetch { id in
            calls.ids.withLock { $0.append(id) }
            return image
        }
        prefetch.want(1)
        prefetch.want(2)
        prefetch.want(3)
        try await settle()
        #expect(calls.ids.withLock { $0 } == [3])
        #expect(prefetch.readyImage(for: 3) != nil)
        #expect(prefetch.readyImage(for: 1) == nil)
    }

    @Test func aClickBeforeTheCaptureEndsGetsThePendingCapture() async throws {
        let image = try Self.image()
        let prefetch = WindowPrefetch { _ in image }
        prefetch.want(5)
        let pending = try #require(prefetch.pending(for: 5))
        #expect(prefetch.pending(for: 6) == nil)
        _ = try await pending.value
    }

    @Test func resetForgetsTheWindow() async throws {
        let image = try Self.image()
        let prefetch = WindowPrefetch { _ in image }
        prefetch.want(5)
        try await settle()
        prefetch.reset()
        #expect(prefetch.readyImage(for: 5) == nil)
        #expect(prefetch.pending(for: 5) == nil)
    }
}
