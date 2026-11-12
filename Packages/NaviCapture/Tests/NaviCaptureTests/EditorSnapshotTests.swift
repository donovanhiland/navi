import AppKit
import SwiftUI
import Testing

@testable import NaviCapture

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAVI_SNAPSHOTS"] != nil))
struct EditorSnapshotTests {
    @Test(arguments: [760, 1000, 1400])
    func editor(width: Int) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CGContext(
            data: nil, width: 1200, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.55, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 700))
        let model = AnnotateModel(base: context.makeImage()!, scale: 2)
        model.tool = .rectangle
        model.pointerDown(at: CGPoint(x: 200, y: 150))
        model.pointerDragged(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 700, y: 450))
        model.pointerUp(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 700, y: 450))

        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let tips = TooltipCenter(activeID: Tip(title: AnnotationTool.rectangle.title, shortcut: "R").id)
            let view = NSHostingView(rootView: AnnotateView(model: model, tips: tips, onDone: {}, onCancel: {}))
            view.appearance = NSAppearance(named: appearance)
            view.frame = CGRect(x: 0, y: 0, width: width, height: 420)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: "editor-\(width)-\(name).png"))
        }
    }

    @Test func textToolOpensABox() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CGContext(
            data: nil, width: 1200, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.55, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 700))
        let model = AnnotateModel(base: context.makeImage()!, scale: 2)
        for (step, text) in [("open", ""), ("typed", "Typed with no click")] {
            model.tool = .select
            model.tool = .text
            model.textEdit?.text = text
            let view = NSHostingView(rootView: AnnotateView(model: model, onDone: {}, onCancel: {}))
            view.appearance = NSAppearance(named: .darkAqua)
            view.frame = CGRect(x: 0, y: 0, width: 1000, height: 420)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: "text-tool-\(step).png"))
        }
    }

    static let areas: [String: CGRect] = [
        "middle": CGRect(x: 420, y: 180, width: 560, height: 360),
        "bottom": CGRect(x: 300, y: 480, width: 640, height: 400),
        "full": CGRect(x: 0, y: 0, width: 1440, height: 900),
    ]

    @Test(arguments: ["middle", "bottom", "full"])
    func editAfterCapture(place: String) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["NAVI_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screen = CGSize(width: 1440, height: 900)
        let backdrop = try Self.backdrop(size: CGSize(width: screen.width * 2, height: screen.height * 2))
        let area = try #require(Self.areas[place])
        let pixels = CGRect(x: area.minX * 2, y: area.minY * 2, width: area.width * 2, height: area.height * 2)
        let placement = ScreenPlacement(origin: area.origin, source: pixels, scale: 2)
        let model = AnnotateModel(base: try #require(backdrop.cropping(to: pixels)), scale: 2, placement: placement)
        model.tool = .arrow
        model.pointerDown(at: CGPoint(x: 140, y: 560))
        model.pointerDragged(from: CGPoint(x: 140, y: 560), to: CGPoint(x: 520, y: 240))
        model.pointerUp(from: CGPoint(x: 140, y: 560), to: CGPoint(x: 520, y: 240))
        model.tool = .rectangle
        model.pointerDown(at: CGPoint(x: 560, y: 120))
        model.pointerDragged(from: CGPoint(x: 560, y: 120), to: CGPoint(x: 1020, y: 380))
        model.pointerUp(from: CGPoint(x: 560, y: 120), to: CGPoint(x: 1020, y: 380))

        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let view = NSHostingView(rootView: InPlaceAnnotateView(
                model: model, backdrop: backdrop, area: area, onDone: {}, onSave: {}, onStash: {}, onCancel: {}
            ))
            view.appearance = NSAppearance(named: appearance)
            view.frame = CGRect(origin: .zero, size: screen)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: "edit-after-capture-\(place)-\(name).png"))
        }
    }

    static func backdrop(size: CGSize) throws -> CGImage {
        if let path = ProcessInfo.processInfo.environment["NAVI_BACKDROP"],
           let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let colors = [CGColor(srgbRed: 0.18, green: 0.32, blue: 0.62, alpha: 1), CGColor(srgbRed: 0.55, green: 0.3, blue: 0.6, alpha: 1)]
        let gradient = try #require(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: size.width * 0.2, y: size.height * 0.15, width: size.width * 0.6, height: size.height * 0.7))
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.86, blue: 0.9, alpha: 1))
        for row in 0..<8 {
            let y = size.height * 0.75 - CGFloat(row) * size.height * 0.07
            context.fill(CGRect(x: size.width * 0.25, y: y, width: size.width * (row.isMultiple(of: 2) ? 0.45 : 0.3), height: size.height * 0.025))
        }
        return try #require(context.makeImage())
    }
}
