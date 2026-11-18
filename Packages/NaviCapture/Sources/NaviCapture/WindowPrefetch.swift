import AppKit

@MainActor
final class WindowPrefetch {
    struct Ready {
        let id: CGWindowID
        let image: CapturedImage
    }

    static let settle: Duration = .milliseconds(80)

    private(set) var id: CGWindowID?
    private(set) var ready: Ready?
    private var task: Task<CapturedImage, Error>?
    private let capture: @Sendable (CGWindowID) async throws -> CapturedImage

    init(capture: @escaping @Sendable (CGWindowID) async throws -> CapturedImage = { try await ScreenGrabber.captureWindow(id: $0) }) {
        self.capture = capture
    }

    func want(_ next: CGWindowID?) {
        guard next != id else { return }
        task?.cancel()
        id = next
        ready = nil
        task = nil
        guard let next else { return }
        let capture = capture
        let task = Task<CapturedImage, Error> {
            try await Task.sleep(for: Self.settle)
            return try await capture(next)
        }
        self.task = task
        Task { [weak self] in
            guard let image = try? await task.value, let self, self.id == next else { return }
            self.ready = Ready(id: next, image: image)
        }
    }

    func readyImage(for window: CGWindowID) -> CapturedImage? {
        ready?.id == window ? ready?.image : nil
    }

    func pending(for window: CGWindowID) -> Task<CapturedImage, Error>? {
        id == window ? task : nil
    }

    func reset() { want(nil) }
}
