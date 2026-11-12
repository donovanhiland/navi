import AppKit

@MainActor
enum AnnotateKeys {
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    private static let delete: UInt16 = 51
    private static let forwardDelete: UInt16 = 117

    static func handle(_ event: NSEvent, model: AnnotateModel) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased()
        let code = event.keyCode
        let flags = modifiers(of: event)
        if model.textEdit != nil {
            guard code == escape else { return false }
            model.finishText()
            return true
        }
        if flags.isEmpty, let key, let tool = AnnotationTool.forShortcut(key) {
            model.tool = tool
            return true
        }
        if key == "z", flags == .command { model.undo(); return true }
        if key == "z", flags == [.command, .shift] { model.redo(); return true }
        if code == delete || code == forwardDelete, flags.isEmpty, model.selection != nil {
            model.deleteSelection()
            return true
        }
        return false
    }

    static func modifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
    }
}
