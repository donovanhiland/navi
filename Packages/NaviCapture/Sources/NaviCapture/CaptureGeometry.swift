import CoreGraphics
import Foundation

public enum CaptureGeometry {
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public static func moved(_ rect: CGRect, by offset: CGVector, within bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: offset.dx, dy: offset.dy)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        return moved
    }

    public static func oppositeCorner(of rect: CGRect, near point: CGPoint, tolerance: CGFloat) -> CGPoint? {
        let corners = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)),
        ]
        return corners.first { hypot($0.0.x - point.x, $0.0.y - point.y) <= tolerance }?.1
    }

    public enum FrameHandle: Sendable, CaseIterable {
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

        var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
        var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }

    public static func frameHandle(of rect: CGRect, near point: CGPoint, tolerance: CGFloat) -> FrameHandle? {
        let grab = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard grab.contains(point) else { return nil }
        let left = abs(point.x - rect.minX) <= tolerance
        let right = !left && abs(point.x - rect.maxX) <= tolerance
        let top = abs(point.y - rect.minY) <= tolerance
        let bottom = !top && abs(point.y - rect.maxY) <= tolerance
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (true, _, _, true): return .bottomLeft
        case (_, true, true, _): return .topRight
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    public static func resized(
        _ rect: CGRect, handle: FrameHandle, to point: CGPoint, within bounds: CGRect, minSize: CGFloat
    ) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = min(max(point.x, bounds.minX), maxX - minSize) }
        if handle.movesRight { maxX = max(min(point.x, bounds.maxX), minX + minSize) }
        if handle.movesTop { minY = min(max(point.y, bounds.minY), maxY - minSize) }
        if handle.movesBottom { maxY = max(min(point.y, bounds.maxY), minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func pixelRect(forSelection selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        let left = (selection.minX * sx).rounded(.down)
        let right = (selection.maxX * sx).rounded(.down) + 1
        let top = ((viewSize.height - selection.maxY) * sy).rounded(.down)
        let bottom = ((viewSize.height - selection.minY) * sy).rounded(.down) + 1
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        return rect.intersection(CGRect(origin: .zero, size: imageSize))
    }

    public static func viewRect(forPixels pixels: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let sx = viewSize.width / imageSize.width
        let sy = viewSize.height / imageSize.height
        return CGRect(
            x: pixels.minX * sx,
            y: viewSize.height - pixels.maxY * sy,
            width: pixels.width * sx,
            height: pixels.height * sy
        )
    }

    public static func pixel(at point: CGPoint, viewSize: CGSize, imageSize: CGSize) -> (x: Int, y: Int) {
        guard viewSize.width > 0, viewSize.height > 0 else { return (0, 0) }
        let x = Int((point.x * imageSize.width / viewSize.width).rounded(.down))
        let y = Int(((viewSize.height - point.y) * imageSize.height / viewSize.height).rounded(.down))
        return (min(max(x, 0), Int(imageSize.width) - 1), min(max(y, 0), Int(imageSize.height) - 1))
    }

    public static func snap(_ value: CGFloat, to edges: [CGFloat], tolerance: CGFloat) -> CGFloat {
        var best = value
        var bestDistance = tolerance
        for edge in edges {
            let distance = abs(edge - value)
            if distance <= bestDistance {
                best = edge
                bestDistance = distance
            }
        }
        return best
    }

    public static func snap(_ point: CGPoint, toWindows windows: [CGRect], bounds: CGRect, tolerance: CGFloat) -> CGPoint {
        func covered(_ edgePoint: CGPoint, before index: Int) -> Bool {
            windows[..<index].contains { front in
                front.minX < edgePoint.x && edgePoint.x < front.maxX && front.minY < edgePoint.y && edgePoint.y < front.maxY
            }
        }
        var xs: [CGFloat] = [bounds.minX, bounds.maxX]
        var ys: [CGFloat] = [bounds.minY, bounds.maxY]
        for (index, frame) in windows.enumerated() {
            if frame.minY - tolerance <= point.y, point.y <= frame.maxY + tolerance {
                let y = min(max(point.y, frame.minY), frame.maxY)
                xs += [frame.minX, frame.maxX].filter { !covered(CGPoint(x: $0, y: y), before: index) }
            }
            if frame.minX - tolerance <= point.x, point.x <= frame.maxX + tolerance {
                let x = min(max(point.x, frame.minX), frame.maxX)
                ys += [frame.minY, frame.maxY].filter { !covered(CGPoint(x: x, y: $0), before: index) }
            }
        }
        return CGPoint(x: snap(point.x, to: xs, tolerance: tolerance), y: snap(point.y, to: ys, tolerance: tolerance))
    }

    public static func fileName(for date: Date, fileExtension: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Navi \(formatter.string(from: date)).\(fileExtension)"
    }

    public static func uniqueURL(in folder: URL, name: String, exists: (URL) -> Bool) -> URL {
        let first = folder.appending(path: name)
        guard exists(first) else { return first }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = folder.appending(path: ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    public static func isClick(from press: CGPoint, to point: CGPoint, threshold: CGFloat) -> Bool {
        hypot(point.x - press.x, point.y - press.y) <= threshold
    }

    public static func interpolate(_ a: CGRect, _ b: CGRect, progress: CGFloat) -> CGRect {
        let t = min(max(progress, 0), 1)
        return CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    public static func easeOut(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    public static func toolbarOrigin(below area: CGRect, toolbar: CGSize, in screen: CGSize, gap: CGFloat, margin: CGFloat) -> CGPoint {
        let centered = area.midX - toolbar.width / 2
        let x = min(max(centered, margin), max(margin, screen.width - toolbar.width - margin))
        let below = area.maxY + gap
        if below + toolbar.height <= screen.height - margin { return CGPoint(x: x, y: below) }
        let above = area.minY - gap - toolbar.height
        if above >= margin { return CGPoint(x: x, y: above) }
        let inside = min(area.maxY, screen.height - margin) - gap - toolbar.height
        return CGPoint(x: x, y: max(margin, inside))
    }
}
