import AppKit
import Observation

enum StrokeSize: Double, CaseIterable {
    case small = 2, medium = 4, large = 8

    var title: String {
        switch self {
        case .small: "Thin"
        case .medium: "Medium"
        case .large: "Thick"
        }
    }
}

@MainActor
@Observable
final class AnnotateModel {
    struct Snapshot {
        let base: CGImage
        let document: AnnotationDocument
        let placement: ScreenPlacement?
    }

    struct TextEdit {
        var point: CGPoint
        var text: String
        var id: UUID?
    }

    private(set) var base: CGImage
    private(set) var document: AnnotationDocument
    private(set) var placement: ScreenPlacement?
    let scale: CGFloat
    var tool: AnnotationTool = .arrow {
        didSet {
            if tool != .select { selection = nil }
            if tool != .crop { cropRect = nil }
            commitText()
            if tool == .text, oldValue != .text { startText(at: hoverPoint ?? defaultTextPoint) }
            render()
        }
    }

    var color: RGBA = .red {
        didSet { if !isSyncingStyle { restyleSelection() } }
    }

    var strokeSize: StrokeSize = .medium {
        didSet { if !isSyncingStyle { restyleSelection() } }
    }

    private(set) var selection: UUID? {
        didSet { syncStyleToSelection() }
    }
    private(set) var cropRect: CGRect?
    var textEdit: TextEdit? {
        didSet { render() }
    }
    private(set) var rendered: CGImage?
    private(set) var patch: AnnotationRenderer.Patch?
    @ObservationIgnored private var renderedMarks: [Annotation]?
    @ObservationIgnored private var renderedBase: CGImage?

    private var undoStack = UndoStack<Snapshot>()
    @ObservationIgnored private let renderer = AnnotationRenderer()
    @ObservationIgnored private var draft: Annotation?
    @ObservationIgnored private var dragOrigin: Annotation?
    @ObservationIgnored private var resizing: Annotation.Handle?
    @ObservationIgnored private var isSyncingStyle = false
    @ObservationIgnored private var clickedSelectedText: UUID?
    @ObservationIgnored private var hoverPoint: CGPoint?

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }
    var pixelSize: CGSize { CGSize(width: base.width, height: base.height) }
    var pointSize: CGSize { CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale) }

    init(base: CGImage, document: AnnotationDocument = AnnotationDocument(), scale: CGFloat, placement: ScreenPlacement? = nil) {
        self.base = base
        self.document = document
        self.placement = placement
        self.scale = max(scale, 1)
        render()
        renderer.prewarmEffects(for: base)
    }

    func pointerMoved(to point: CGPoint?) {
        hoverPoint = point
    }

    private func startText(at point: CGPoint) {
        textEdit = TextEdit(point: point, text: "")
    }

    private var defaultTextPoint: CGPoint {
        CGPoint(x: pixelSize.width / 4, y: max(0, (pixelSize.height - fontSize) / 2))
    }

    func pointerDown(at point: CGPoint) {
        clickedSelectedText = nil
        if let edit = textEdit, edit.id != nil || !edit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           document.hit(point, tolerance: 4 * scale)?.kind != .text {
            finishText()
            render()
            return
        }
        commitText()
        if let selected = selectedMark, let handle = selected.handle(at: point, tolerance: 10 * scale) {
            resizing = handle
            dragOrigin = selected
            recordUndo()
            return
        }
        if tool != .select { selection = nil }
        switch tool {
        case .select:
            if let hit = document.hit(point, tolerance: 6 * scale) {
                if hit.kind == .text, hit.id == selection { clickedSelectedText = hit.id }
                selection = hit.id
                dragOrigin = hit
                recordUndo()
            } else {
                selection = nil
            }
        case .crop:
            cropRect = CGRect(origin: point, size: .zero)
        case .text:
            if let hit = document.hit(point, tolerance: 4 * scale), hit.kind == .text {
                selection = hit.id
                dragOrigin = hit
                recordUndo()
            }
        case .counter:
            break
        default:
            guard let kind = Annotation.Kind(rawValue: tool.rawValue) else { return }
            draft = Annotation(
                kind: kind, start: point, end: point, points: [point], color: color,
                lineWidth: strokeSize.rawValue * scale, fontSize: fontSize
            )
        }
        render()
    }

    func pointerDragged(from start: CGPoint, to point: CGPoint) {
        if let handle = resizing, let origin = dragOrigin,
           let index = document.annotations.firstIndex(where: { $0.id == origin.id }) {
            document.annotations[index] = origin.resized(handle, to: point)
            render()
            return
        }
        switch tool {
        case .select, .text:
            guard let origin = dragOrigin, let index = document.annotations.firstIndex(where: { $0.id == origin.id }) else { return }
            document.annotations[index] = origin.moved(by: CGVector(dx: point.x - start.x, dy: point.y - start.y))
        case .crop:
            cropRect = CaptureGeometry.rect(from: start, to: point).intersection(CGRect(origin: .zero, size: pixelSize))
        default:
            draft?.end = point
            draft?.points.append(point)
        }
        render()
    }

    func pointerUp(from start: CGPoint, to point: CGPoint) {
        let moved = hypot(point.x - start.x, point.y - start.y) > 3 * scale
        if resizing != nil {
            resizing = nil
            dragOrigin = nil
            render()
            return
        }
        switch tool {
        case .select:
            dragOrigin = nil
            if !moved, let id = clickedSelectedText, let mark = document.annotations.first(where: { $0.id == id }) {
                textEdit = TextEdit(point: mark.start, text: mark.text ?? "", id: id)
            }
            clickedSelectedText = nil
        case .crop:
            if !moved { cropRect = nil }
        case .text:
            if let origin = dragOrigin {
                dragOrigin = nil
                if moved {
                    tool = .select
                    selection = origin.id
                } else if let mark = document.annotations.first(where: { $0.id == origin.id }) {
                    textEdit = TextEdit(point: mark.start, text: mark.text ?? "", id: mark.id)
                }
            } else {
                textEdit = TextEdit(point: point, text: "")
            }
        case .counter:
            recordUndo()
            let counter = Annotation(
                kind: .counter, start: point, end: point, color: color, lineWidth: 0,
                number: document.nextCounter, fontSize: fontSize
            )
            document.annotations.append(counter)
            document.nextCounter += 1
            selection = counter.id
        default:
            if var mark = draft, moved || mark.kind == .pencil || mark.kind == .highlighter {
                mark.end = point
                recordUndo()
                document.annotations.append(mark)
                tool = .select
                selection = mark.id
            }
            draft = nil
        }
        render()
    }

    func deleteSelection() {
        guard let selection else { return }
        recordUndo()
        document.annotations.removeAll { $0.id == selection }
        self.selection = nil
        render()
    }

    func commitText() {
        guard let edit = textEdit else { return }
        textEdit = nil
        let text = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = edit.id, let index = document.annotations.firstIndex(where: { $0.id == id }) {
            recordUndo()
            if text.isEmpty { document.annotations.remove(at: index) } else { document.annotations[index].text = text }
        } else if !text.isEmpty {
            recordUndo()
            document.annotations.append(Annotation(
                kind: .text, start: edit.point, end: edit.point, color: color, lineWidth: 0, text: text, fontSize: fontSize
            ))
        }
        render()
    }

    func finishText() {
        let editedID = textEdit?.id
        let count = document.annotations.count
        commitText()
        let id = editedID ?? (document.annotations.count > count ? document.annotations.last?.id : nil)
        guard let id, document.annotations.contains(where: { $0.id == id }) else { return }
        tool = .select
        selection = id
        render()
    }

    enum Pointer: Equatable {
        case arrow, openHand, closedHand, iBeam, crosshair
        case resize(NSCursor.FrameResizePosition)

        var cursor: NSCursor {
            switch self {
            case .arrow: .arrow
            case .openHand: .openHand
            case .closedHand: .closedHand
            case .iBeam: .iBeam
            case .crosshair: .crosshair
            case let .resize(position): .frameResize(position: position, directions: .all)
            }
        }
    }

    func pointer(at point: CGPoint) -> Pointer {
        if let mark = selectedMark, let handle = mark.handle(at: point, tolerance: 10 * scale) {
            return Self.resizePointer(handle, of: mark)
        }
        switch tool {
        case .select:
            return document.hit(point, tolerance: 6 * scale) == nil ? .arrow : .openHand
        case .text:
            return .iBeam
        default:
            return .crosshair
        }
    }

    func dragPointer(at point: CGPoint) -> Pointer {
        if let resizing, let mark = selectedMark { return Self.resizePointer(resizing, of: mark) }
        if dragOrigin != nil { return .closedHand }
        if draft != nil || (tool == .crop && cropRect != nil) { return .crosshair }
        return pointer(at: point)
    }

    var hoverPointer: Pointer? {
        hoverPoint.map(pointer(at:))
    }

    private static func resizePointer(_ handle: Annotation.Handle, of mark: Annotation) -> Pointer {
        switch handle {
        case .top: return .resize(.top)
        case .bottom: return .resize(.bottom)
        case .left: return .resize(.left)
        case .right: return .resize(.right)
        default:
            guard mark.isBox else { return .crosshair }
            let point = mark.point(of: handle)
            let box = mark.box
            let top = point.y <= box.midY, left = point.x <= box.midX
            return switch (top, left) {
            case (true, true): .resize(.topLeft)
            case (true, false): .resize(.topRight)
            case (false, true): .resize(.bottomLeft)
            case (false, false): .resize(.bottomRight)
            }
        }
    }

    func applyCrop() {
        guard let rect = cropRect, rect.width > 2, rect.height > 2 else { return }
        cropRect = nil
        apply(.crop(rect.integral))
    }

    func cancelCrop() {
        cropRect = nil
        render()
    }

    func apply(_ edit: ImageEdit) {
        commitText()
        guard let image = ImageOps.apply(edit, to: base) else { return }
        recordUndo()
        let (transform, _) = edit.transform(for: pixelSize)
        document.apply(transform, scale: edit.markScale)
        base = image
        placement = placement?.after(edit)
        render()
    }

    func beginReframe() {
        commitText()
        cropRect = nil
        recordUndo()
    }

    func reframe(to frame: CGRect, screen: CGImage) {
        let pixels = CGSize(width: screen.width, height: screen.height)
        guard let (next, shift) = placement?.reframed(to: frame, screenPixels: pixels),
              let source = next.source, let image = screen.cropping(to: source)
        else { return }
        document.apply(CGAffineTransform(translationX: shift.dx, y: shift.dy))
        base = image
        placement = next
        render()
    }

    func addImage(_ image: CGImage) {
        guard let png = ImageOps.png(image, pointSize: CGSize(width: image.width, height: image.height)) else { return }
        let fit = min(1, min(pixelSize.width / 2 / CGFloat(image.width), pixelSize.height / 2 / CGFloat(image.height)))
        let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
        let origin = CGPoint(x: (pixelSize.width - size.width) / 2, y: (pixelSize.height - size.height) / 2)
        recordUndo()
        var mark = Annotation(
            kind: .image, start: origin, end: CGPoint(x: origin.x + size.width, y: origin.y + size.height),
            color: color, lineWidth: 0
        )
        mark.imagePNG = png
        document.annotations.append(mark)
        tool = .select
        selection = mark.id
        render()
    }

    func undo() {
        commitText()
        guard let snapshot = undoStack.undo(current: Snapshot(base: base, document: document, placement: placement)) else { return }
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = undoStack.redo(current: Snapshot(base: base, document: document, placement: placement)) else { return }
        restore(snapshot)
    }

    func flatten() -> CGImage? {
        commitText()
        return renderer.render(base: base, marks: document.annotations)
    }

    private var fontSize: Double { (8 + strokeSize.rawValue * 3) * scale }

    var selectedMark: Annotation? {
        guard let selection else { return nil }
        return document.annotations.first { $0.id == selection }
    }

    private func restyleSelection() {
        guard let selection, let index = document.annotations.firstIndex(where: { $0.id == selection }) else { return }
        var mark = document.annotations[index]
        mark.color = color
        if mark.usesFontSize { mark.fontSize = fontSize } else if mark.lineWidth > 0 { mark.lineWidth = strokeSize.rawValue * scale }
        guard mark != document.annotations[index] else { return }
        recordUndo()
        document.annotations[index] = mark
        render()
    }

    private func syncStyleToSelection() {
        guard let mark = selectedMark else { return }
        isSyncingStyle = true
        defer { isSyncingStyle = false }
        if mark.kind != .image, mark.kind != .blur, mark.kind != .pixelate, mark.kind != .spotlight { color = mark.color }
        let size = mark.usesFontSize ? (mark.fontSize / scale - 8) / 3 : mark.lineWidth / scale
        if let nearest = StrokeSize.allCases.min(by: { abs($0.rawValue - size) < abs($1.rawValue - size) }), size > 0 {
            strokeSize = nearest
        }
    }

    private func recordUndo() {
        undoStack.record(Snapshot(base: base, document: document, placement: placement))
    }

    private func restore(_ snapshot: Snapshot) {
        base = snapshot.base
        document = snapshot.document
        placement = snapshot.placement
        selection = nil
        render()
    }

    var textPreview: Annotation? {
        guard let edit = textEdit, !edit.text.isEmpty else { return nil }
        let original = edit.id.flatMap { id in document.annotations.first { $0.id == id } }
        return Annotation(
            kind: .text, start: edit.point, end: edit.point, color: original?.color ?? color, lineWidth: 0,
            text: edit.text, fontSize: original?.fontSize ?? fontSize
        )
    }

    var textEditFontSize: Double {
        let original = textEdit?.id.flatMap { id in document.annotations.first { $0.id == id } }
        return original?.fontSize ?? fontSize
    }

    private func render() {
        var all = document.annotations
        if let editing = textEdit?.id { all.removeAll { $0.id == editing } }
        var live: [Annotation] = []
        if let id = dragOrigin?.id, let mark = all.first(where: { $0.id == id }) { live.append(mark) }
        if let preview = textPreview {
            all.append(preview)
            live.append(preview)
        }
        if let draft {
            all.append(draft)
            live.append(draft)
        }
        let single = live.count == 1 && live[0].kind != .spotlight ? live[0] : nil
        let committed = single.map { mark in all.filter { $0.id != mark.id } } ?? all
        if committed != renderedMarks || base !== renderedBase || rendered == nil {
            rendered = committed.isEmpty ? base : renderer.render(base: base, marks: committed)
            renderedMarks = committed
            renderedBase = base
        }
        if let single, rendered != nil {
            patch = renderer.patch(base: base, marks: all, live: single)
        } else if patch != nil {
            patch = nil
        }
    }
}

enum MarkupStore {
    static func save(base: CGImage, document: AnnotationDocument, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: folder.appending(path: "document.json"), options: .atomic)
        guard let png = ImageOps.png(base, pointSize: CGSize(width: base.width, height: base.height)) else { return }
        try png.write(to: folder.appending(path: "base.png"), options: .atomic)
    }

    static func load(from folder: URL) -> (CGImage, AnnotationDocument)? {
        guard let json = try? Data(contentsOf: folder.appending(path: "document.json")),
              let document = try? JSONDecoder().decode(AnnotationDocument.self, from: json),
              let source = CGImageSourceCreateWithURL(folder.appending(path: "base.png") as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (base, document)
    }
}
