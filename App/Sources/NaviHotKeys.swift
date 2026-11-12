import Carbon.HIToolbox
import NaviCore

enum NaviHotKeys {
    static let menu = KeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | shiftKey | optionKey))
    static let captureText = KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey | optionKey))
    static let scrollingCapture = KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey))
    static let record = KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey | optionKey))
    static let pasteLastDictation = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey | optionKey))
    static let fullscreen = KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey))
    static let area = KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey))
    static let allInOne = KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey))
    static let fullscreenToClipboard = KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | controlKey))
    static let areaToClipboard = KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | controlKey))

    static let reserved: [String: KeyCombo] = [
        "Navi Menu": menu,
        "Capture Text": captureText,
        "Scrolling Capture": scrollingCapture,
        "Record Screen": record,
        "Paste Last Dictation": pasteLastDictation,
        "Capture Fullscreen": fullscreen,
        "Capture Area": area,
        "All-in-One": allInOne,
        "Capture Fullscreen to Clipboard": fullscreenToClipboard,
        "Capture Area to Clipboard": areaToClipboard,
    ]
}
