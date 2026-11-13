import Foundation

enum BlockingWork {
    static func run<T: Sendable>(_ body: sending @escaping () throws -> T) async throws -> T {
        let work = Work(body)
        return try await withCheckedThrowingContinuation { continuation in
            start { continuation.resume(with: Result { try work.body() }) }
        }
    }

    static func run<T: Sendable>(_ body: sending @escaping () -> T) async -> T {
        let work = Work(body)
        return await withCheckedContinuation { continuation in
            start { continuation.resume(returning: work.body()) }
        }
    }

    private static func start(_ block: @escaping @Sendable () -> Void) {
        let thread = Thread(block: block)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private final class Work<Body>: @unchecked Sendable {
        let body: Body
        init(_ body: Body) { self.body = body }
    }
}
