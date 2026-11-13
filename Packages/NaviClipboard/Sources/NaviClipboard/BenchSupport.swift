import AppKit
import NaviCore

@_spi(Bench) @MainActor
public final class WatcherProbe {
    private let watcher: ClipboardWatcher

    public init(inbox: Inbox, pasteboard: NSPasteboard) {
        watcher = ClipboardWatcher(inbox: inbox, pasteboard: pasteboard)
    }

    public func check() {
        watcher.check()
    }

    public func waitForIdle() async {
        await watcher.waitForIdle()
    }
}

@_spi(Bench) @MainActor
public enum PanelProbe {
    public static func paste(_ item: CaptureItem, inbox: Inbox, to pasteboard: NSPasteboard) {
        _ = Paster.write(item, inbox: inbox, to: pasteboard)
        inbox.touch(item.id)
    }

    public static func open(_ model: ClipboardModel) -> Int {
        model.reset()
        return model.results.count + Int(model.contentHeight)
    }

    public static func thumbnail(_ model: ClipboardModel, _ item: CaptureItem) async -> Bool {
        await model.thumbnail(for: item) != nil
    }

    public static func preview(_ model: ClipboardModel, _ item: CaptureItem) async -> Bool {
        await model.previewImage(for: item) != nil
    }
}
