import AppKit
import NaviCapture
import NaviClipboard
import NaviCore
import NaviDictation

@MainActor
final class NaviMenu: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(app: AppDelegate) {
        self.app = app
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Navi")
        menu.delegate = self
        statusItem.menu = menu
    }

    func popUpAtMouse() {
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let capture = app.capture
        let settings = capture.settings

        menu.addItem(item("All-in-One", key: "5", [.command, .shift]) { capture.captureAllInOne() })
        menu.addItem(item("Capture Area", key: "4", [.command, .shift]) { capture.captureArea() })
        menu.addItem(item("Capture Window") { capture.captureWindow() })
        menu.addItem(item("Capture Fullscreen", key: "3", [.command, .shift]) { capture.captureFullscreen() })
        menu.addItem(item("Scrolling Capture", key: "4", [.command, .shift, .option]) { capture.captureScrolling() })
        menu.addItem(item("Capture Text", key: "t", [.command, .shift, .option]) { capture.captureText() })
        let timer = NSMenuItem(title: "Self-Timer", action: nil, keyEquivalent: "")
        timer.submenu = NSMenu()
        for seconds in [3, 5, 10] {
            timer.submenu?.addItem(item("\(seconds) Seconds") { capture.captureArea(timer: seconds) })
        }
        menu.addItem(timer)
        menu.addItem(.separator())
        if app.recording.isRecording {
            menu.addItem(item("Stop Recording", key: "5", [.command, .shift, .option]) { [app] in app.recording.stop() })
        } else {
            menu.addItem(item("Record Screen…", key: "5", [.command, .shift, .option]) { capture.pickRecordingRegion() })
        }
        menu.addItem(item("Talk to Type (Hold fn)", on: app.dictation.isEnabled) { [app] in
            app.setTalkToType(!app.dictation.isEnabled)
        })
        if app.dictation.isEnabled {
            menu.addItem(item("Keep Microphone Ready", on: app.dictation.keepsMicrophoneReady) { [app] in
                app.dictation.keepsMicrophoneReady.toggle()
            })
        }
        menu.addItem(.separator())
        menu.addItem(item("Close All Cards") { capture.closeAllCards() })
        if capture.hasPins {
            menu.addItem(item("Unlock Pinned Shots") { capture.unlockPins() })
            menu.addItem(item("Close Pinned Shots") { capture.closeAllPins() })
        }
        menu.addItem(.separator())
        menu.addItem(item("Hide Desktop Icons", on: settings.hideDesktopIcons) {
            settings.hideDesktopIcons.toggle()
        })
        menu.addItem(item("Copy Screenshots to Clipboard", on: settings.copyToClipboard) {
            settings.copyToClipboard.toggle()
        })
        menu.addItem(item("Edit Screenshots Before Copying", on: settings.editAfterCapture) {
            settings.editAfterCapture.toggle()
        })
        menu.addItem(item("Use Navi for Screenshot Keys", on: settings.useNaviScreenshotKeys == true) { [app] in
            app.setUseNaviScreenshotKeys(settings.useNaviScreenshotKeys != true)
        })
        menu.addItem(.separator())
        menu.addItem(shortcutItem("Open History", app.historyShortcut) { [app] in app.clipboard.togglePanel() })
        menu.addItem(item("Change History Shortcut…") { [app] in app.changeHistoryShortcut() })
        menu.addItem(item("Clear History") { [app] in app.inbox.clearUnpinned() })
        menu.addItem(.separator())
        menu.addItem(item("Accessibility Permission…") { ClipboardFeature.requestAccessibility() })
        menu.addItem(item("Screen Recording Permission…") { CaptureFeature.requestScreenAccess() })
        menu.addItem(item("Microphone and Speech Permission…") {
            Task { _ = await DictationFeature.requestPermissions() }
        })
        menu.addItem(.separator())
        menu.addItem(item("Check for Updates…") { [app] in app.updater.checkForUpdates(nil) })
        menu.addItem(item("Quit Navi", key: "q", .command) { NSApp.terminate(nil) })
    }

    private func shortcutItem(
        _ title: String, _ combo: KeyCombo, action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        guard combo.keyName.count == 1 else { return item("\(title) (\(combo.display))", action: action) }
        return item(title, key: combo.keyName.lowercased(), combo.cocoaModifiers, action: action)
    }

    private func item(
        _ title: String, key: String = "", _ modifiers: NSEvent.ModifierFlags = [], on: Bool? = nil,
        action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = ActionMenuItem(title: title, action: action)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
        if let on { item.state = on ? .on : .off }
        return item
    }
}

@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
