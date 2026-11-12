import CoreGraphics
import Foundation

enum RecordingMath {
    static let maxVideoSide = 4096

    static func videoPixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var width = max(points.width * scale, 2)
        var height = max(points.height * scale, 2)
        let longest = max(width, height)
        if longest > CGFloat(maxVideoSide) {
            let factor = CGFloat(maxVideoSide) / longest
            width *= factor
            height *= factor
        }
        return (evenFloor(width), evenFloor(height))
    }

    private static func evenFloor(_ value: CGFloat) -> Int {
        max(Int(value.rounded(.down)) & ~1, 2)
    }

    static func videoBitRate(width: Int, height: Int, framesPerSecond: Int) -> Int {
        let rate = Double(width * height * framesPerSecond) * 0.07
        return Int(min(max(rate, 4_000_000), 60_000_000))
    }

    struct GIFPlan: Equatable {
        var times: [Double]
        var frameDelay: Double
        var width: Int
        var height: Int
    }

    static let gifFramesPerSecond = 15.0
    static let gifMaxWidth = 800.0

    static func gifPlan(
        duration: Double, naturalSize: CGSize,
        framesPerSecond: Double = gifFramesPerSecond, maxWidth: Double = gifMaxWidth
    ) -> GIFPlan {
        let delay = 1 / framesPerSecond
        let count = max(Int((max(duration, 0) * framesPerSecond).rounded(.up)), 1)
        let times = (0..<count).map { min((Double($0) + 0.5) * delay, max(duration - 0.001, 0)) }
        let scale = min(1, maxWidth / max(naturalSize.width, 1))
        let width = max(Int((naturalSize.width * scale).rounded()), 1)
        let height = max(Int((naturalSize.height * scale).rounded()), 1)
        return GIFPlan(times: times, frameDelay: delay, width: width, height: height)
    }

    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaRect(forLocal local: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + local.minX,
            y: displayFrame.maxY - local.maxY,
            width: local.width,
            height: local.height
        )
    }

    static func barFrame(region: CGRect, barSize: CGSize, visible: CGRect, gap: CGFloat = 12) -> CGRect {
        var x = region.midX - barSize.width / 2
        var y = region.minY - gap - barSize.height
        if y < visible.minY {
            y = region.maxY + gap
            if y + barSize.height > visible.maxY {
                y = region.minY + gap
            }
        }
        x = min(max(x, visible.minX + 8), visible.maxX - barSize.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - barSize.height - 8)
        return CGRect(origin: CGPoint(x: x, y: y), size: barSize)
    }

    static func resizedArea(
        _ area: CGRect, toPixelWidth width: Int, height: Int, scale: CGFloat, displaySize: CGSize
    ) -> CGRect {
        let w = min(max(CGFloat(width) / scale, 40), displaySize.width)
        let h = min(max(CGFloat(height) / scale, 40), displaySize.height)
        let x = min(max(area.minX, 0), displaySize.width - w)
        let y = min(max(area.minY, 0), displaySize.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func fileName(for date: Date, fileExtension: String, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "Navi %04d-%02d-%02d at %02d.%02d.%02d.%@",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, fileExtension
        )
    }
}

enum KeyLabel {
    private static let special: [Int64: String] = [
        36: "⏎", 76: "⌅", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func text(keyCode: Int64, flags: CGEventFlags, character: String?) -> String? {
        let name: String
        if let named = special[keyCode] {
            name = named
        } else if let character, !character.isEmpty, character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
            name = character.uppercased()
        } else {
            return nil
        }
        let hasCommandLike = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        guard hasCommandLike || special[keyCode] != nil else { return nil }
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        return text + name
    }
}
