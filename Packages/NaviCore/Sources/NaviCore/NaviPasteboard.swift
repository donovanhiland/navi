import AppKit

public enum NaviPasteboard {
    public static let ownType = NSPasteboard.PasteboardType("com.donovanhiland.navi.own")

    @MainActor
    @discardableResult
    public static func write(image: NSImage, to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setData(Data(), forType: ownType)
        return pasteboard.changeCount
    }
}
