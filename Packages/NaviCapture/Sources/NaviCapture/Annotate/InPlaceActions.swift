import SwiftUI

struct InPlaceActions: View {
    let onCancel: () -> Void
    let onStash: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void

    static let buttonSize = CGSize(width: 22, height: 20)
    static let padding: CGFloat = 4
    static let spacing: CGFloat = 2
    static let cornerRadius: CGFloat = 10

    var body: some View {
        VStack(spacing: Self.spacing) {
            ActionButton(symbol: "xmark", tip: Tip(title: "Cancel", shortcut: "Esc"), action: onCancel)
            ActionButton(symbol: "clock.arrow.circlepath", tip: Tip(title: "Keep in History"), action: onStash)
            ActionButton(symbol: "square.and.arrow.down", tip: Tip(title: "Save", shortcut: "⌘S"), action: onSave)
            ActionButton(symbol: "doc.on.doc", tip: Tip(title: "Copy", shortcut: "↩"), isPrimary: true, action: onCopy)
        }
        .buttonStyle(.plain)
        .padding(Self.padding)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}

private struct ActionButton: View {
    let symbol: String
    let tip: Tip
    var isPrimary = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: InPlaceActions.buttonSize.width, height: InPlaceActions.buttonSize.height)
                .foregroundStyle(isPrimary ? Color.white : Color.primary.opacity(0.85))
                .background(RoundedRectangle(cornerRadius: 6).fill(background))
                .contentShape(Rectangle())
        }
        .onHover { isHovered = $0 }
        .tooltip(tip)
        .accessibilityLabel(Text(tip.title))
    }

    private var background: Color {
        if isPrimary { return isHovered ? Color.accentColor.opacity(0.85) : .accentColor }
        return .primary.opacity(isHovered ? 0.1 : 0)
    }
}
