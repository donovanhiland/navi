import AppKit
import Carbon.HIToolbox
import NaviCore

@MainActor
enum Paster {
    static func write(_ item: CaptureItem, inbox: Inbox, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        if item.kind == .recording, let url = inbox.fileURL(for: item) {
            pasteboard.writeObjects([url as NSURL])
        } else if let url = inbox.fileURL(for: item), let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        } else if let text = item.text {
            pasteboard.setString(text, forType: .string)
        }
        return pasteboard.changeCount
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
