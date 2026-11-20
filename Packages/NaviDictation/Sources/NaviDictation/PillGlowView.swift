import AppKit
import SwiftUI

struct PillGlowView: View {
    let bands: [Float]
    let style: PillGlowStyle
    let isThinking: Bool
    var time: Double?

    var body: some View {
        if let time {
            canvas(at: time)
        } else {
            TimelineView(.animation) { context in
                canvas(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func canvas(at time: Double) -> some View {
        let palette = GlowLayout.Palette(style: style, accentHue: Self.accentHue)
        return Canvas { context, size in
            let dots = isThinking
                ? GlowLayout.thinking(size: size, time: time, palette: palette)
                : GlowLayout.listening(bands: bands, size: size, time: time, palette: palette)
                    + (style.hasEmbers ? GlowLayout.embers(bands: bands, size: size, time: time, palette: palette) : [])
            for dot in dots {
                let rect = CGRect(
                    x: dot.center.x - dot.size / 2, y: dot.center.y - dot.size / 2,
                    width: dot.size, height: dot.size
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: dot.size * 0.3),
                    with: .color(Color(hue: dot.hue, saturation: dot.saturation, brightness: 1, opacity: dot.opacity))
                )
            }
        }
        .accessibilityHidden(true)
    }

    private static var accentHue: Double {
        Double(NSColor.controlAccentColor.usingColorSpace(.sRGB)?.hueComponent ?? 0.64)
    }
}
