import AppKit

let args = CommandLine.arguments
let out = URL(filePath: args.count > 1 ? args[1] : "icon.png")
let size = CGFloat(args.count > 2 ? Double(args[2])! : 1024)
let s = size / 1024

let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: CGColor(gray: 0, alpha: 0.35))
context.addPath(tilePath)
context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.5, alpha: 1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tilePath)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [
        CGColor(srgbRed: 0.33, green: 0.42, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.55, green: 0.30, blue: 0.95, alpha: 1),
        CGColor(srgbRed: 0.85, green: 0.35, blue: 0.80, alpha: 1),
    ] as CFArray,
    locations: [0, 0.6, 1]
)!
context.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1]
)!
context.drawRadialGradient(
    glow, startCenter: CGPoint(x: tile.midX, y: tile.maxY), startRadius: 0,
    endCenter: CGPoint(x: tile.midX, y: tile.maxY), endRadius: 620 * s, options: []
)
context.restoreGState()

let frame = tile.insetBy(dx: 190 * s, dy: 190 * s)
let arm = 120 * s
context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
context.setLineWidth(44 * s)
context.setLineCap(.round)
context.setLineJoin(.round)
for (corner, dx, dy) in [
    (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
    (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
] {
    context.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
    context.addLine(to: corner)
    context.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
}
context.strokePath()

func sparkle(center: CGPoint, radius: CGFloat, waist: CGFloat) {
    let path = CGMutablePath()
    for i in 0 ..< 4 {
        let angle = CGFloat(i) * .pi / 2
        let tip = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        let next = angle + .pi / 2
        let control = CGPoint(x: center.x + cos(angle + .pi / 4) * waist, y: center.y + sin(angle + .pi / 4) * waist)
        let nextTip = CGPoint(x: center.x + cos(next) * radius, y: center.y + sin(next) * radius)
        if i == 0 { path.move(to: tip) }
        path.addQuadCurve(to: nextTip, control: control)
    }
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
}
context.saveGState()
context.setShadow(offset: .zero, blur: 30 * s, color: CGColor(gray: 1, alpha: 0.6))
sparkle(center: CGPoint(x: tile.midX - 10 * s, y: tile.midY - 10 * s), radius: 150 * s, waist: 34 * s)
sparkle(center: CGPoint(x: tile.midX + 118 * s, y: tile.midY + 118 * s), radius: 46 * s, waist: 11 * s)
context.restoreGState()

let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
