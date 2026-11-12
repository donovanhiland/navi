import AppKit

@MainActor
final class StopPill {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var startDate = Date()
    private var timerTask: Task<Void, Never>?
    private let onClick: @MainActor () -> Void

    init(onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.toolTip = "Stop recording"
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.systemRed.cgColor
            button.layer?.cornerRadius = 5
        }
        setTitle(seconds: 0)
    }

    var windowID: CGWindowID? {
        item.button?.window.map { CGWindowID($0.windowNumber) }
    }

    func startTimer() {
        startDate = Date()
        setTitle(seconds: 0)
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.setTitle(seconds: Date().timeIntervalSince(self.startDate))
            }
        }
    }

    func remove() {
        timerTask?.cancel()
        NSStatusBar.system.removeStatusItem(item)
    }

    private func setTitle(seconds: TimeInterval) {
        item.button?.attributedTitle = NSAttributedString(
            string: " ● \(RecordingMath.elapsedLabel(seconds)) ",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            ]
        )
    }

    @objc private func clicked() { onClick() }
}
