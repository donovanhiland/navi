import AppKit

struct MarkupResult: Sendable {
    let flat: CGImage
    let base: CGImage
    let document: AnnotationDocument
    let pointSize: CGSize

    var flatImage: NSImage { flat.asNSImage(pointSize: pointSize) }

    func encoded() -> EncodedMarkup? {
        guard let png = ImageOps.png(flat, pointSize: pointSize) else { return nil }
        return EncodedMarkup(flat: png, base: MarkupStore.encodeBase(base))
    }
}

struct EncodedMarkup: Sendable {
    let flat: Data
    let base: Data?
}
