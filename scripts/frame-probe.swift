import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct Options {
    var out = URL(fileURLWithPath: "/tmp/navi-frames")
    var keyCode: CGKeyCode = 0x15
    var flags: CGEventFlags = [.maskCommand, .maskShift]
    var seconds = 1.0
    var lead = 0.3
    var runs = 1
    var savePNG = true
    var escape = true

    init() {
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--out": out = URL(fileURLWithPath: args.next()!)
            case "--seconds": seconds = Double(args.next()!)!
            case "--runs": runs = Int(args.next()!)!
            case "--no-png": savePNG = false
            case "--no-escape": escape = false
            case "--key":
                let spec = args.next()!
                switch spec {
                case "4": keyCode = 0x15
                case "5": keyCode = 0x17
                case "3": keyCode = 0x14
                default: keyCode = CGKeyCode(spec)!
                }
            case "--alt": flags.insert(.maskAlternate)
            case "--ctrl": flags.insert(.maskControl)
            default: fatalError("unknown argument \(arg)")
            }
        }
    }
}

struct Frame {
    let hostTime: UInt64
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: Data
}

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Frame] = []
    var recording = true

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, recording,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer)
        else { return }
        let hostTime = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(pixels)!, count: bytesPerRow * height)
        lock.lock()
        frames.append(Frame(hostTime: hostTime, width: width, height: height, bytesPerRow: bytesPerRow, data: data))
        lock.unlock()
    }

    func take() -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        let taken = frames
        frames = []
        return taken
    }
}

let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func ms(from start: UInt64, to end: UInt64) -> Double {
    let delta = Int64(bitPattern: end &- start)
    return Double(delta) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

func press(_ key: CGKeyCode, flags: CGEventFlags) -> UInt64 {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)!
    let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)!
    down.flags = flags
    up.flags = flags
    let time = mach_absolute_time()
    down.post(tap: .cghidEventTap)
    usleep(30_000)
    up.post(tap: .cghidEventTap)
    return time
}

func diff(_ a: Frame, _ b: Frame, box: CGRect? = nil) -> Double {
    guard a.width == b.width, a.height == b.height else { return 1 }
    let step = 4
    var changed = 0
    var total = 0
    let x0 = Int(box?.minX ?? 0), x1 = Int(box?.maxX ?? CGFloat(a.width))
    let y0 = Int(box?.minY ?? 0), y1 = Int(box?.maxY ?? CGFloat(a.height))
    a.data.withUnsafeBytes { pa in
        b.data.withUnsafeBytes { pb in
            let ra = pa.bindMemory(to: UInt8.self)
            let rb = pb.bindMemory(to: UInt8.self)
            var y = max(0, y0)
            while y < min(a.height, y1) {
                var x = max(0, x0)
                while x < min(a.width, x1) {
                    let i = y * a.bytesPerRow + x * 4
                    let d = abs(Int(ra[i]) - Int(rb[i])) + abs(Int(ra[i + 1]) - Int(rb[i + 1])) + abs(Int(ra[i + 2]) - Int(rb[i + 2]))
                    if d > 24 { changed += 1 }
                    total += 1
                    x += step
                }
                y += step
            }
        }
    }
    return total == 0 ? 0 : Double(changed) / Double(total)
}

func image(_ frame: Frame) -> CGImage {
    let provider = CGDataProvider(data: frame.data as CFData)!
    return CGImage(
        width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let options = Options()
try? FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
let mouse = NSEvent.mouseLocation
let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
    print("no capturable display: unlock the screen and grant Screen Recording")
    exit(2)
}
let filter = SCContentFilter(display: display, excludingWindows: [])
let config = SCStreamConfiguration()
config.width = display.width
config.height = display.height
config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
config.queueDepth = 8
config.showsCursor = true
config.pixelFormat = kCVPixelFormatType_32BGRA
config.colorSpaceName = CGColorSpace.sRGB

let recorder = Recorder()
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe", qos: .userInteractive))
try await stream.startCapture()
try await Task.sleep(for: .seconds(0.5))

let cursorPoint = CGPoint(
    x: (mouse.x - screen.frame.minX) * CGFloat(display.width) / screen.frame.width,
    y: (screen.frame.maxY - mouse.y) * CGFloat(display.height) / screen.frame.height)
let cursorBox = CGRect(x: cursorPoint.x - 160, y: cursorPoint.y - 160, width: 320, height: 320)

var summary: [String] = []
for run in 0..<options.runs {
    _ = recorder.take()
    try await Task.sleep(for: .seconds(options.lead))
    let baselineFrames = recorder.take()
    let pressed = press(options.keyCode, flags: options.flags)
    try await Task.sleep(for: .seconds(options.seconds))
    let frames = recorder.take()
    if options.escape {
        _ = press(0x35, flags: [])
        try await Task.sleep(for: .seconds(0.6))
    }
    guard let baseline = baselineFrames.last ?? frames.first else { continue }
    let runDir = options.out.appendingPathComponent("run\(run)")
    try? FileManager.default.removeItem(at: runDir)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    print("run \(run): \(frames.count) frames, display \(display.width)x\(display.height), cursor \(Int(cursorPoint.x)),\(Int(cursorPoint.y))")
    print(String(format: "%9@ %9@ %9@ %9@", "t ms", "vs base", "vs prev", "cursor"))
    var previous = baseline
    var firstChange: Double?
    var lastChange: Double = 0
    for frame in frames {
        let t = ms(from: pressed, to: frame.hostTime)
        let vsBase = diff(baseline, frame)
        let vsPrev = diff(previous, frame)
        let nearCursor = diff(previous, frame, box: cursorBox)
        if vsPrev > 0.0005 || nearCursor > 0.002 {
            if firstChange == nil, vsBase > 0.0005 { firstChange = t }
            lastChange = t
        }
        print(String(format: "%9.1f %8.2f%% %8.2f%% %8.2f%%", t, vsBase * 100, vsPrev * 100, nearCursor * 100))
        if options.savePNG {
            let name = String(format: "%+06.0fms", t)
            writePNG(image(frame), to: runDir.appendingPathComponent("\(name).png"))
            if let crop = image(frame).cropping(to: cursorBox) {
                writePNG(crop, to: runDir.appendingPathComponent("\(name)-cursor.png"))
            }
        }
        previous = frame
    }
    let line = String(format: "run %d: first change %.1f ms, last change %.1f ms", run, firstChange ?? -1, lastChange)
    print(line)
    summary.append(line)
}
try await stream.stopCapture()
print(summary.joined(separator: "\n"))
