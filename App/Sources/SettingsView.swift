import NaviDictation
import SwiftUI

@Observable
@MainActor
final class SettingsModel {
    struct Toggle: Identifiable {
        let id: String
        let title: String
        var detail: String?
        let get: @MainActor () -> Bool
        let set: @MainActor (Bool) -> Void
        var isEnabled: @MainActor () -> Bool = { true }
    }

    struct Permission: Identifiable {
        let id: String
        let title: String
        let isGranted: @MainActor () -> Bool
        let request: @MainActor () -> Void
    }

    var capture: [Toggle] = []
    var talkToType: [Toggle] = []
    var vocabulary: VocabularyStore?
    var permissions: [Permission] = []
    var historyShortcut: @MainActor () -> String = { "" }
    var changeHistoryShortcut: @MainActor () -> Void = {}
    var clearHistory: @MainActor () -> Void = {}
    var checkForUpdates: @MainActor () -> Void = {}
    private(set) var revision = 0

    func refresh() { revision += 1 }

    func binding(_ toggle: Toggle) -> Binding<Bool> {
        Binding(
            get: { [self] in _ = revision; return toggle.get() },
            set: { [self] value in toggle.set(value); refresh() }
        )
    }

    func isEnabled(_ toggle: Toggle) -> Bool {
        _ = revision
        return toggle.isEnabled()
    }

    func isGranted(_ permission: Permission) -> Bool {
        _ = revision
        return permission.isGranted()
    }
}

enum SettingsMetrics {
    static let width: CGFloat = 320
    static let cornerRadius: CGFloat = 10
    static let highlightInset: CGFloat = 5
    static let highlightRadius: CGFloat = 5
    static let textInset: CGFloat = 9
    static let rowMinHeight: CGFloat = 24
    static let rowVerticalPadding: CGFloat = 4
    static let verticalPadding: CGFloat = 5
    static let stateAnimation = Animation.easeOut(duration: 0.12)
    static let hoverAnimation = Animation.easeOut(duration: 0.08)
    static let clearedFeedback: Duration = .milliseconds(1200)
}

struct SettingsView: View {
    let model: SettingsModel
    @State private var showsCleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Capture") { toggles(model.capture) }
            separator
            section("Talk to Type") { toggles(model.talkToType) }
            separator
            if let vocabulary = model.vocabulary {
                section("Vocabulary") { VocabularyRows(store: vocabulary) }
                separator
            }
            section("History") { historyRows }
            separator
            section("Permissions") { permissionRows }
            separator
            footer
        }
        .padding(.vertical, SettingsMetrics.verticalPadding)
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, SettingsMetrics.highlightInset + SettingsMetrics.textInset)
                .padding(.top, 3)
                .padding(.bottom, 2)
            content()
        }
    }

    private var separator: some View {
        Divider()
            .padding(.horizontal, SettingsMetrics.highlightInset + SettingsMetrics.textInset)
            .padding(.vertical, 5)
    }

    @ViewBuilder private func toggles(_ toggles: [SettingsModel.Toggle]) -> some View {
        ForEach(toggles) { toggle in
            ToggleRow(toggle: toggle, isOn: model.binding(toggle), isEnabled: model.isEnabled(toggle))
        }
    }

    @ViewBuilder private var historyRows: some View {
        MenuRow {
            Text("Open History")
            Spacer()
            KeyHint(text: model.historyShortcut())
            Button("Change…", action: model.changeHistoryShortcut).controlSize(.mini)
        }
        MenuRow {
            Text("Clear History")
            Spacer()
            if showsCleared {
                Label("Cleared", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .transition(.opacity)
            } else {
                Button("Clear", action: clear).controlSize(.mini)
                    .help("Pinned items stay")
                    .transition(.opacity)
            }
        }
        .animation(SettingsMetrics.stateAnimation, value: showsCleared)
    }

    @ViewBuilder private var permissionRows: some View {
        ForEach(model.permissions) { permission in
            let granted = model.isGranted(permission)
            MenuRow {
                Text(permission.title)
                Spacer()
                if granted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else {
                    Button("Turn On…", action: permission.request).controlSize(.mini)
                        .transition(.opacity)
                }
            }
            .animation(SettingsMetrics.stateAnimation, value: granted)
        }
    }

    private func clear() {
        model.clearHistory()
        showsCleared = true
        Task { @MainActor in
            try? await Task.sleep(for: SettingsMetrics.clearedFeedback)
            showsCleared = false
        }
    }

    private var footer: some View {
        MenuRow {
            Text("Navi \(Self.version)").foregroundStyle(.secondary)
            Spacer()
            Button("Check for Updates…", action: model.checkForUpdates)
                .buttonStyle(.link)
        }
        .font(.system(size: 12))
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

struct MenuRow<Content: View>: View {
    var highlights = false
    var isEnabled = true
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, SettingsMetrics.textInset)
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowMinHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.highlightRadius, style: .continuous)
                    .fill(.primary.opacity(highlights && isHovered && isEnabled ? 0.1 : 0))
            )
            .padding(.horizontal, SettingsMetrics.highlightInset)
            .onHover { isHovered = $0 }
            .animation(SettingsMetrics.hoverAnimation, value: isHovered)
    }
}

private struct ToggleRow: View {
    let toggle: SettingsModel.Toggle
    let isOn: Binding<Bool>
    let isEnabled: Bool

    var body: some View {
        MenuRow(highlights: true, isEnabled: isEnabled) {
            VStack(alignment: .leading, spacing: 1) {
                Text(toggle.title)
                if let detail = toggle.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            MiniSwitch(isOn: isOn.wrappedValue)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            withAnimation(SettingsMetrics.stateAnimation) { isOn.wrappedValue.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toggle.title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { if isEnabled { isOn.wrappedValue.toggle() } }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(SettingsMetrics.stateAnimation, value: isEnabled)
    }
}

private struct MiniSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.18)))
            .frame(width: 26, height: 15)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
                    .padding(1.5)
            }
    }
}

private struct KeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)))
    }
}
