import Foundation
import QuartzCore
import os

@MainActor
enum CaptureTiming {
    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "Timing")
    private static var clocks: [String: ContinuousClock.Instant] = [:]

    static func start(_ clock: String) {
        clocks[clock] = .now
    }

    static func mark(_ clock: String, _ step: String) {
        guard let started = clocks[clock] else { return }
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        logger.info("\(clock, privacy: .public) → \(step, privacy: .public): \(String(format: "%.1f", ms), privacy: .public) ms")
    }

    static func markOnScreen(_ clock: String, _ step: String) {
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { mark(clock, step) } }
        CATransaction.flush()
    }
}
