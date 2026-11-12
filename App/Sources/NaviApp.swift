import Carbon.HIToolbox
import NaviCapture
import NaviClipboard
import NaviCore
import NaviDictation
import NaviRecording
import Sparkle
import SwiftUI
import os

@main
struct NaviApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let inbox = Inbox()
    lazy var clipboard = ClipboardFeature(inbox: inbox)
    lazy var capture = CaptureFeature(inbox: inbox)
    let recording = RecordingFeature()
    #if DEBUG
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    #else
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    lazy var dictation = DictationFeature(inbox: inbox)
    private let historyStore = HistoryShortcutStore(defaults: .standard)
    private(set) lazy var historyShortcut: KeyCombo = historyStore.load()
    private var historyHotKey: HotKey?
    private var menuHotKey: HotKey?
    private var extraHotKeys: [HotKey] = []
    private var screenshotHotKeys: [HotKey] = []
    private var pasteLastHotKey: HotKey?
    private lazy var naviMenu = NaviMenu(app: self)
    private lazy var shortcutRecorder = HistoryShortcutRecorder(
        apply: { [weak self] in self?.setHistoryShortcut($0) ?? .refused },
        onClose: { [weak self] in self?.resumeHotKeys() }
    )
    private var signalSources: [any DispatchSourceSignal] = []
    private let logger = Logger(subsystem: "com.donovanhiland.navi", category: "App")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !CaptureFeature.hasScreenAccess { CaptureFeature.requestScreenAccess(openSettings: false) }
        clipboard.start()
        clipboard.onAnnotate = { [weak self] item in self?.capture.annotate(inboxID: item.id) }
        _ = naviMenu
        registerHotKeys()
        quitCleanlyOnSignals()
        wireRecording()
        dictation.onProblem = { CaptureFeature.showMessage($0) }
        if dictation.hasChosen {
            dictation.start()
            if dictation.isEnabled { dictation.borrowFnKey() } else { dictation.giveBackFnKey() }
        }
        switch capture.settings.useNaviScreenshotKeys {
        case true?: setUseNaviScreenshotKeys(true)
        case false?: SystemScreenshotShortcuts.giveBack()
        case nil: askAboutScreenshotKeys()
        }
        if !dictation.hasChosen { askAboutTalkToType() }
        if !ClipboardFeature.hasAccessibility {
            ClipboardFeature.requestAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemScreenshotShortcuts.giveBack()
        dictation.stop()
        dictation.giveBackFnKey()
        recording.stop()
        inbox.flush()
    }

    private func askAboutTalkToType() {
        let alert = NSAlert()
        alert.messageText = "Use fn for Talk to Type?"
        alert.informativeText = """
            Hold fn, talk, and let go: Navi types what you said. While Navi runs, a tap on fn does nothing \
            else (no emoji picker). Navi puts the fn key back when it quits. You can change this in the Navi menu.
            """
        alert.addButton(withTitle: "Use fn")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        let use = alert.runModal() == .alertFirstButtonReturn
        dictation.start()
        setTalkToType(use)
    }

    func setTalkToType(_ on: Bool) {
        dictation.isEnabled = on
        if on {
            dictation.borrowFnKey()
            Task { _ = await DictationFeature.requestPermissions() }
        } else {
            dictation.giveBackFnKey()
        }
        updatePasteLastHotKey()
    }

    private func updatePasteLastHotKey() {
        pasteLastHotKey?.unregister()
        pasteLastHotKey = nil
        guard dictation.isEnabled else { return }
        pasteLastHotKey = register("Paste Last Dictation", NaviHotKeys.pasteLastDictation) { [weak self] in
            self?.dictation.pasteLastDictation()
        }
    }

    private func wireRecording() {
        recording.onError = { CaptureFeature.showMessage($0.localizedDescription) }
        capture.videoTools = VideoTools(
            trim: { [recording] url in await recording.trim(url) },
            makeGIF: { url in try await RecordingFeature.makeGIF(from: url) }
        )
        capture.onRecordRequest = { [weak self] region in
            guard let self else { return }
            let target: RecordingRegion = switch region {
            case let .display(id): .display(id)
            case let .area(id, rect): .area(id, rect)
            case let .window(id): .window(id)
            }
            recording.showRecordBar(region: target) { [weak self] result in
                self?.capture.showRecording(
                    url: result.url, videoURL: result.videoURL, isGIF: result.isGIF, duration: result.duration
                )
            }
        }
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        historyHotKey = makeHistoryHotKey(historyShortcut)
        menuHotKey = register("Navi Menu", NaviHotKeys.menu) { [weak self] in self?.naviMenu.popUpAtMouse() }
        extraHotKeys = [
            register("Capture Text", NaviHotKeys.captureText) { [weak self] in self?.capture.captureText() },
            register("Scrolling Capture", NaviHotKeys.scrollingCapture) { [weak self] in
                self?.capture.captureScrolling()
            },
            register("Record Screen", NaviHotKeys.record) { [weak self] in
                guard let self else { return }
                recording.isRecording ? recording.stop() : capture.pickRecordingRegion()
            },
        ].compactMap(\.self)
        if capture.settings.useNaviScreenshotKeys == true {
            screenshotHotKeys = makeScreenshotHotKeys()
        }
        updatePasteLastHotKey()
    }

    private func unregisterHotKeys() {
        historyHotKey?.unregister()
        menuHotKey?.unregister()
        for hotKey in extraHotKeys + screenshotHotKeys { hotKey.unregister() }
        pasteLastHotKey?.unregister()
        pasteLastHotKey = nil
        historyHotKey = nil
        menuHotKey = nil
        extraHotKeys = []
        screenshotHotKeys = []
    }

    func suspendHotKeys() {
        logger.info("Navi shortcuts suspended")
        unregisterHotKeys()
    }

    func resumeHotKeys() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            registerHotKeys()
            logger.info("Navi shortcuts resumed, History on \(self.historyShortcut.display, privacy: .public)")
        }
    }

    func changeHistoryShortcut() {
        suspendHotKeys()
        shortcutRecorder.show(current: historyShortcut)
    }

    func setHistoryShortcut(_ combo: KeyCombo) -> HistoryShortcutChange {
        if let error = combo.validate(reserved: NaviHotKeys.reserved) { return .invalid(error) }
        let wasRegistered = historyHotKey != nil
        historyHotKey?.unregister()
        historyHotKey = nil
        guard let hotKey = makeHistoryHotKey(combo) else {
            if wasRegistered { historyHotKey = makeHistoryHotKey(historyShortcut) }
            return .refused
        }
        if wasRegistered { historyHotKey = hotKey } else { hotKey.unregister() }
        historyShortcut = combo
        if combo == .defaultHistory {
            historyStore.reset()
        } else {
            historyStore.save(combo)
        }
        return .applied
    }

    private func makeHistoryHotKey(_ combo: KeyCombo) -> HotKey? {
        register("History", combo) { [weak self] in self?.clipboard.togglePanel() }
    }

    func setUseNaviScreenshotKeys(_ use: Bool) {
        capture.settings.useNaviScreenshotKeys = use
        for hotKey in screenshotHotKeys { hotKey.unregister() }
        screenshotHotKeys = []
        guard use else {
            SystemScreenshotShortcuts.giveBack()
            return
        }
        SystemScreenshotShortcuts.takeOver()
        screenshotHotKeys = makeScreenshotHotKeys()
    }

    private func makeScreenshotHotKeys() -> [HotKey] {
        [
            register("Capture Fullscreen", NaviHotKeys.fullscreen) { [weak self] in self?.capture.captureFullscreen() },
            register("Capture Area", NaviHotKeys.area) { [weak self] in self?.capture.captureArea() },
            register("All-in-One", NaviHotKeys.allInOne) { [weak self] in self?.capture.captureAllInOne() },
            register("Capture Fullscreen to Clipboard", NaviHotKeys.fullscreenToClipboard) { [weak self] in
                self?.capture.captureFullscreenToClipboard()
            },
            register("Capture Area to Clipboard", NaviHotKeys.areaToClipboard) { [weak self] in
                self?.capture.captureAreaToClipboard()
            },
        ].compactMap(\.self)
    }

    private func askAboutScreenshotKeys() {
        let alert = NSAlert()
        alert.messageText = "Use Navi for the screenshot keys?"
        alert.informativeText = """
            While Navi runs, ⇧⌘3, ⇧⌘4, and ⇧⌘5 take screenshots with Navi, and ⌃⇧⌘3 and ⌃⇧⌘4 also copy them. Navi turns off the macOS screenshot \
            keys while it runs, and turns them back on when it quits. You can change this in the Navi menu.
            """
        alert.addButton(withTitle: "Use Navi")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        setUseNaviScreenshotKeys(alert.runModal() == .alertFirstButtonReturn)
    }

    private func quitCleanlyOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func register(_ name: String, _ combo: KeyCombo, action: @escaping () -> Void) -> HotKey? {
        guard let hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers, action: action) else {
            logger.error("Could not register \(name, privacy: .public). Another app may own it.")
            return nil
        }
        return hotKey
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        clipboard.showPanel()
        return false
    }
}
