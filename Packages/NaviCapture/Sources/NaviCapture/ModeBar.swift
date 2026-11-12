import AppKit
import SwiftUI

final class ModeBarPanel: NSPanel {
    private let model: ModeBarModel

    @MainActor
    init(session: SelectionSession, screen: NSScreen) {
        model = ModeBarModel(session: session)
        let size = CGSize(width: 760, height: 52)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 90, width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = FirstMouseHostingView(rootView: ModeBarView(model: model))
    }

    override var canBecomeKey: Bool { false }

    @MainActor
    func refresh() { model.version += 1 }
}

@MainActor
@Observable
final class ModeBarModel {
    weak var session: SelectionSession?
    var version = 0

    init(session: SelectionSession) { self.session = session }
}

private struct ModeBarView: View {
    let model: ModeBarModel

    var body: some View {
        let _ = model.version
        let session = model.session
        HStack(spacing: 4) {
            item("Area", "rectangle.dashed", on: session?.purpose == .screenshot && session?.mode == .area) {
                session?.purpose = .screenshot
                session?.setMode(.area)
            }
            item("Window", "macwindow", on: session?.purpose == .screenshot && session?.mode == .window) {
                session?.purpose = .screenshot
                session?.setMode(.window)
            }
            item("Fullscreen", "rectangle.inset.filled", on: false) {
                if let screen = NSScreen.underMouse { session?.finish(.fullscreen(screen)) }
            }
            Divider().frame(height: 26)
            item("Scrolling", "arrow.up.and.down.text.horizontal", on: session?.purpose == .scroll) { session?.purpose = .scroll }
            item("Text", "text.viewfinder", on: session?.purpose == .text) { session?.purpose = .text }
            if session?.canRecord == true {
                item("Record", "record.circle", on: session?.purpose == .record) { session?.purpose = .record }
            }
            Divider().frame(height: 26)
            if session?.hasHeldSelection == true, let purpose = session?.purpose, purpose != .record {
                confirmButton(purpose) { session?.confirmHeldSelection() }
            }
            Menu {
                ForEach([0, 3, 5, 10], id: \.self) { seconds in
                    Button(seconds == 0 ? "No Timer" : "\(seconds) Seconds") {
                        session?.timer = seconds
                        model.version += 1
                    }
                }
            } label: {
                Label(session?.timer ?? 0 == 0 ? "Timer" : "\(session?.timer ?? 0)s", systemImage: "timer")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { session?.finish(.cancelled) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func confirmButton(_ purpose: SelectionSession.Purpose, action: @escaping () -> Void) -> some View {
        let (title, symbol, color): (String, String, Color) = switch purpose {
        case .screenshot: ("Capture", "camera.fill", .accentColor)
        case .record: ("Record", "record.circle.fill", .red)
        case .text: ("Copy Text", "doc.on.doc.fill", .accentColor)
        case .scroll: ("Start Scrolling", "arrow.up.and.down", .accentColor)
        }
        return Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) (Return)")
    }

    private func item(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 10))
            }
            .frame(width: 66, height: 42)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
