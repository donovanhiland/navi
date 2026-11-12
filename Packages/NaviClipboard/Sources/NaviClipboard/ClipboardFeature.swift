import AppKit
import NaviCore

@MainActor
public final class ClipboardFeature {
    private let inbox: Inbox
    private let watcher: ClipboardWatcher
    private let model: ClipboardModel
    private lazy var panel: ClipboardPanelController = {
        let panel = ClipboardPanelController(model: model) { [weak self] item in
            self?.paste(item)
        }
        panel.onAnnotate = { [weak self] item in self?.onAnnotate?(item) }
        return panel
    }()

    public var onAnnotate: ((CaptureItem) -> Void)?

    public init(inbox: Inbox) {
        self.inbox = inbox
        watcher = ClipboardWatcher(inbox: inbox)
        model = ClipboardModel(inbox: inbox)
    }

    public func start() {
        watcher.start()
        model.keepThumbnailsWarm()
        Task { @MainActor [weak self] in self?.panel.prepare() }
    }

    public func showPanel() {
        if !panel.isVisible { panel.show() }
    }

    public func togglePanel() {
        if panel.isVisible { panel.hide() } else { panel.show() }
    }

    public static var hasAccessibility: Bool { Paster.hasAccessibility }

    public static func requestAccessibility() { Paster.requestAccessibility() }

    private func paste(_ item: CaptureItem) {
        let changeCount = Paster.write(item, inbox: inbox, to: .general)
        watcher.markOwnChange(changeCount)
        inbox.touch(item.id)
        guard Paster.hasAccessibility else {
            Paster.requestAccessibility()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            Paster.pressCommandV()
        }
    }
}
