import AppKit
import SwiftUI
import Testing

@testable import NaviDictation

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAVI_SNAPSHOTS"] != nil))
struct PillSnapshotTests {
    static let sentence = "So for the launch next week I want the pill to stay small, keep the newest words in view, and cut the oldest ones off at the start so it never gets in the way"
    static let typed = "So for the launch next week, I want the pill to stay small, keep the newest words in view, and cut the oldest ones off at the start so it never gets in the way."

    private var folder: URL {
        URL(filePath: ProcessInfo.processInfo.environment["NAVI_SNAPSHOTS"]!)
    }

    @Test func states() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let words = Self.sentence.split(separator: " ")
        let states: [(String, PillModel.Phase, Bool, String)] = [
            ("1-listening-no-words", .listening, true, ""),
            ("2-listening-few-words", .listening, true, words.prefix(5).joined(separator: " ")),
            ("3-listening-full-width", .listening, true, words.prefix(22).joined(separator: " ")),
            ("4-hold-to-talk", .listening, false, words.prefix(9).joined(separator: " ")),
            ("5-thinking", .thinking, true, Self.sentence),
        ]
        for (name, phase, locked, text) in states {
            let model = PillModel()
            model.phase = phase
            model.isLocked = locked
            model.liveText = text
            for _ in 0 ..< 6 { model.push(bands: Self.bands(at: 0.2)) }
            try Self.write(Scene(model: model, showsPill: true, fnDown: false, editorText: "", time: 0.2), to: folder.appending(path: "pill-\(name).png"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NAVI_PILL_FRAMES"] != nil))
    func demoFrames() throws {
        let frames = folder.appending(path: "frames")
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let words = Self.sentence.split(separator: " ")
        let fps = 30.0
        for index in 0 ..< Int(10 * fps) {
            let time = Double(index) / fps
            let model = PillModel()
            model.isLocked = true
            for back in stride(from: 0.2, through: 0, by: -1 / fps) { model.push(bands: Self.bands(at: time - back)) }
            let heard = max(0, min(words.count, Int((time - 1.0) / 0.24)))
            model.liveText = words.prefix(heard).joined(separator: " ")
            if time >= 7.6 { model.phase = .thinking }
            let fnDown = (0.6 ..< 0.72).contains(time) || (7.6 ..< 7.72).contains(time)
            let showsPill = (0.6 ..< 8.3).contains(time)
            let scene = Scene(model: model, showsPill: showsPill, fnDown: fnDown, editorText: time >= 8.3 ? Self.typed : "", time: time)
            try Self.write(scene, to: frames.appending(path: String(format: "%04d.png", index)))
        }
    }

    static func bands(at time: Double) -> [Float] {
        let loudness = max(0, sin(time * 7.3) * sin(time * 2.1 + 1))
        let formant = 0.3 + 0.15 * sin(time * 3.1)
        return (0 ..< SpectrumBands.count).map { band in
            let x = Double(band) / Double(SpectrumBands.count)
            let shape = exp(-pow((x - formant) / 0.18, 2)) + 0.5 * exp(-pow((x - formant - 0.3) / 0.12, 2))
            return Float(min(1, loudness * shape))
        }
    }

    static func write(_ scene: Scene, to url: URL) throws {
        let view = NSHostingView(rootView: scene)
        view.frame = CGRect(origin: .zero, size: Scene.size)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

struct Scene: View {
    static let size = CGSize(width: 960, height: 540)
    let model: PillModel
    let showsPill: Bool
    let fnDown: Bool
    let editorText: String
    var time: Double?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.20, blue: 0.36), Color(red: 0.42, green: 0.30, blue: 0.52)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 0) {
                editor
                    .padding(.top, 40)
                Spacer()
                PillView(model: model, time: time)
                    .opacity(showsPill ? 1 : 0)
                    .padding(.bottom, 4)
            }
            VStack {
                HStack {
                    Spacer()
                    fnKey
                }
                Spacer()
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .light)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 11, height: 11)
                }
                Spacer()
                Text("Notes").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            .background(Color(white: 0.93))
            VStack(alignment: .leading, spacing: 8) {
                Text("Launch notes").font(.system(size: 17, weight: .bold))
                (Text(editorText) + Text("|").foregroundColor(.accentColor))
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
        }
        .frame(width: 620, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var fnKey: some View {
        VStack(spacing: 2) {
            Image(systemName: "globe").font(.system(size: 13))
            Text("fn").font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .frame(width: 48, height: 44)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(fnDown ? 0.45 : 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .scaleEffect(fnDown ? 0.92 : 1)
    }
}
