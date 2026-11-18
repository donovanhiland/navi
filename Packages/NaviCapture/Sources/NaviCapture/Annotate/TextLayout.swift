import AppKit
import Synchronization

enum TextLayout {
    static let lineHeight = 1.25
    static let unbounded = 10_000_000.0

    static func font(size: Double) -> NSFont {
        NSFont.systemFont(ofSize: CGFloat(size), weight: .bold)
    }

    static func attributes(fontSize: Double, color: RGBA) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = CGFloat(fontSize * lineHeight)
        paragraph.maximumLineHeight = CGFloat(fontSize * lineHeight)
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font(size: fontSize),
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .red,
            .paragraphStyle: paragraph,
        ]
    }

    struct Laid {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
    }

    static func lay(_ text: String, fontSize: Double, color: RGBA = .red, wrap: Double?) -> Laid {
        let storage = NSTextStorage(string: text, attributes: attributes(fontSize: fontSize, color: color))
        let container = NSTextContainer(size: CGSize(width: max(1, wrap ?? unbounded), height: unbounded))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return Laid(storage: storage, manager: manager, container: container)
    }

    static func size(of text: String, fontSize: Double, wrap: Double?, fixed: Bool) -> CGSize {
        let key = Key(text: text, fontSize: fontSize, wrap: wrap, fixed: fixed)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let laid = lay(text.isEmpty ? " " : text, fontSize: fontSize, wrap: wrap)
        let used = laid.manager.usedRect(for: laid.container)
        let lineCount = max(1, (used.height / (fontSize * lineHeight)).rounded())
        let width = fixed ? (wrap ?? used.width) : (text.isEmpty ? 0 : used.width.rounded(.up))
        let size = CGSize(width: width, height: lineCount * fontSize * lineHeight)
        cache.withLock { cache in
            if cache.count > 512 { cache.removeAll() }
            cache[key] = size
        }
        return size
    }

    static func draw(_ text: String, at origin: CGPoint, fontSize: Double, color: RGBA, wrap: Double?) {
        let laid = lay(text, fontSize: fontSize, color: color, wrap: wrap)
        let glyphs = laid.manager.glyphRange(for: laid.container)
        laid.manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    private struct Key: Hashable {
        let text: String
        let fontSize: Double
        let wrap: Double?
        let fixed: Bool
    }

    private static let cache = Mutex<[Key: CGSize]>([:])
}

enum TextSize: Double, CaseIterable {
    case small = 14, medium = 20, large = 28, extraLarge = 40

    var label: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        case .extraLarge: "XL"
        }
    }

    var title: String {
        switch self {
        case .small: "Small text"
        case .medium: "Medium text"
        case .large: "Large text"
        case .extraLarge: "Extra large text"
        }
    }
}
