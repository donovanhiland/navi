import AppKit
import NaviCore
import Observation
import SwiftUI

enum Metrics {
    static let width: CGFloat = 450
    static let searchHeight: CGFloat = 44
    static let scopeHeight: CGFloat = 26
    static let headerHeight: CGFloat = searchHeight + scopeHeight
    static let textRowHeight: CGFloat = 24
    static let imageRowHeight: CGFloat = 50
    static let listPadding: CGFloat = 5
    static let footerRowHeight: CGFloat = 24
    static let footerHeight: CGFloat = 1 + footerRowHeight * 2 + listPadding * 2
    static let previewMaxWidth: CGFloat = 480
    static let previewMaxHeight: CGFloat = 360

    static func rowHeight(for item: CaptureItem) -> CGFloat {
        item.fileName == nil ? textRowHeight : imageRowHeight
    }
}

public enum HistoryScope: CaseIterable, Sendable {
    case all, text, images, dictation

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        case .dictation: "Dictation"
        }
    }

    func includes(_ kind: CaptureKind) -> Bool {
        switch self {
        case .all: true
        case .text: kind == .text
        case .images: kind == .image || kind == .screenshot || kind == .recording
        case .dictation: kind == .dictation
        }
    }
}

@MainActor
@Observable
public final class ClipboardModel {
    let inbox: Inbox
    public var query = "" {
        didSet { select(0) }
    }
    public var scope = HistoryScope.all {
        didSet { select(0) }
    }
    var selection = 0 {
        didSet { onSelectionChange?() }
    }
    var maxListHeight: CGFloat = 600

    @ObservationIgnored var onSelectionChange: (() -> Void)?
    @ObservationIgnored var visibleRect = CGRect.zero
    private(set) var opens = 0
    @ObservationIgnored var selectedByHover = false
    @ObservationIgnored var lastHoverLocation: CGPoint?

    @ObservationIgnored private let images = NSCache<NSString, NSImage>()
    @ObservationIgnored private var decoding: [NSString: Task<CGImage?, Never>] = [:]
    @ObservationIgnored private var appIcons: [String: NSImage] = [:]
    @ObservationIgnored private var lastSearch: (
        query: String, scope: HistoryScope, items: Int, keys: Int, results: [CaptureItem]
    )?

    public init(inbox: Inbox) {
        self.inbox = inbox
    }

    public var results: [CaptureItem] {
        let query = self.query
        let scope = self.scope
        _ = inbox.items
        let items = inbox.itemsVersion, keys = inbox.searchKeysVersion
        if let lastSearch, lastSearch.query == query, lastSearch.scope == scope,
           lastSearch.items == items, lastSearch.keys == keys {
            return lastSearch.results
        }
        let interval = HistorySignpost.signposter.beginInterval("Search")
        var results = inbox.search(query)
        if scope != .all { results.removeAll { !scope.includes($0.kind) } }
        HistorySignpost.signposter.endInterval("Search", interval)
        lastSearch = (query, scope, items, keys, results)
        return results
    }

    var selectedItem: CaptureItem? { item(at: selection) }

    func item(at index: Int) -> CaptureItem? {
        let results = results
        return results.indices.contains(index) ? results[index] : nil
    }

    func listHeight(for results: [CaptureItem]) -> CGFloat {
        let rows = results.isEmpty
            ? Metrics.textRowHeight
            : results.reduce(0) { $0 + Metrics.rowHeight(for: $1) }
        return min(rows + Metrics.listPadding * 2, maxListHeight)
    }

    var contentHeight: CGFloat {
        Metrics.headerHeight + listHeight(for: results) + Metrics.footerHeight
    }

    private func rowSpan(at index: Int, in results: [CaptureItem]) -> ClosedRange<CGFloat>? {
        guard results.indices.contains(index) else { return nil }
        let top = results[..<index].reduce(Metrics.listPadding) { $0 + Metrics.rowHeight(for: $1) }
        return top...(top + Metrics.rowHeight(for: results[index]))
    }

    func scrollAnchor(for index: Int, in results: [CaptureItem]) -> UnitPoint? {
        guard let span = rowSpan(at: index, in: results) else { return nil }
        if span.lowerBound < visibleRect.minY { return .top }
        if span.upperBound > visibleRect.maxY { return .bottom }
        return nil
    }

    var selectedRowMidY: CGFloat? {
        guard let span = rowSpan(at: selection, in: results) else { return nil }
        return Metrics.headerHeight + (span.lowerBound + span.upperBound) / 2 - visibleRect.minY
    }

    func reset() {
        query = ""
        scope = .all
        select(0)
        opens += 1
        lastHoverLocation = NSEvent.mouseLocation
    }

    func cycleScope(by offset: Int) {
        let all = HistoryScope.allCases
        let index = all.firstIndex(of: scope) ?? 0
        scope = all[(index + offset + all.count) % all.count]
    }

    func move(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        select(min(max(selection + offset, 0), count - 1))
    }

    private func select(_ index: Int) {
        selectedByHover = false
        selection = index
    }

    func hover(_ index: Int) {
        let location = NSEvent.mouseLocation
        guard location != lastHoverLocation else { return }
        lastHoverLocation = location
        if selection != index {
            selectedByHover = true
            selection = index
        }
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        inbox.togglePin(item.id)
        if let index = results.firstIndex(where: { $0.id == item.id }) { select(index) }
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        inbox.remove(item.id)
        select(min(selection, max(results.count - 1, 0)))
    }

    func clear() {
        inbox.clearUnpinned()
        select(0)
    }

    func cachedThumbnail(for item: CaptureItem) -> NSImage? {
        images.object(forKey: thumbnailKey(item))
    }

    func thumbnail(for item: CaptureItem) async -> NSImage? {
        if let cached = cachedThumbnail(for: item) { return cached }
        let key = thumbnailKey(item)
        let task: Task<CGImage?, Never>
        if let existing = decoding[key] {
            task = existing
        } else {
            guard let file = inbox.fileURL(for: item) else { return nil }
            let preview = inbox.previewURL(for: item.id)
            let maxPixelSize = 400
            task = Task.detached(priority: .userInitiated) {
                Self.downsample(preview, maxPixelSize: maxPixelSize) ?? Self.downsample(file, maxPixelSize: maxPixelSize)
            }
            decoding[key] = task
        }
        let interval = HistorySignpost.signposter.beginInterval("RowImage")
        let decoded = await task.value
        HistorySignpost.signposter.endInterval("RowImage", interval)
        decoding[key] = nil
        if let cached = cachedThumbnail(for: item) { return cached }
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: .zero)
        images.setObject(image, forKey: key)
        return image
    }

    static let warmRows = 40

    func keepThumbnailsWarm() {
        let items = withObservationTracking { inbox.items } onChange: { [weak self] in
            Task { @MainActor in self?.keepThumbnailsWarm() }
        }
        for item in items.prefix(Self.warmRows) where item.fileName != nil && cachedThumbnail(for: item) == nil {
            Task { _ = await thumbnail(for: item) }
        }
    }

    func previewImage(for item: CaptureItem) async -> NSImage? {
        let key = "\(item.id.uuidString)-\(item.contentHash)-preview" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let file = inbox.fileURL(for: item) else { return nil }
        let preview = inbox.previewURL(for: item.id)
        let maxPixelSize = Int(Metrics.previewMaxWidth * 2)
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodeForCard(preview, maxPixelSize: maxPixelSize) ?? Self.decodeForCard(file, maxPixelSize: maxPixelSize)
        }.value
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded.image, size: decoded.pointSize)
        images.setObject(image, forKey: key)
        return image
    }

    func appIcon(for item: CaptureItem) -> NSImage? {
        guard let bundleID = item.sourceBundleID else { return nil }
        if let cached = appIcons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundleID] = icon
        return icon
    }

    private func thumbnailKey(_ item: CaptureItem) -> NSString {
        "\(item.id.uuidString)-\(item.contentHash)-thumbnail" as NSString
    }

    private nonisolated static func thumbnailOptions(maxPixelSize: Int) -> CFDictionary {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return options as CFDictionary
    }

    private nonisolated static func downsample(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize: maxPixelSize))
    }

    private nonisolated static func decodeForCard(_ url: URL, maxPixelSize: Int) -> (image: CGImage, pointSize: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize: maxPixelSize))
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let dpiValue = dpi > 0 ? dpi : 72
        let thumbLong = Double(max(thumb.width, thumb.height))
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        var fullLong = thumbLong
        if let pixelWidth, let pixelHeight {
            fullLong = max(pixelWidth, pixelHeight) * 72 / dpiValue
        }
        let factor = fullLong / thumbLong
        let pointSize = CGSize(width: Double(thumb.width) * factor, height: Double(thumb.height) * factor)
        return (image: thumb, pointSize: pointSize)
    }
}
