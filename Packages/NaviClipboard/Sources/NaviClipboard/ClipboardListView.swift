import NaviCore
import SwiftUI

struct ClipboardListView: View {
    @Bindable var model: ClipboardModel
    let onChoose: (CaptureItem) -> Void
    let onQuit: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            header
            list(results)
                .frame(height: model.listHeight)
            footer
        }
        .frame(width: Metrics.width, height: model.contentHeight, alignment: .top)
        .font(.system(size: 13))
        .onAppear { searchFocused = true }
        .onChange(of: model.opens) { searchFocused = true }
    }

    private var header: some View {
        VStack(spacing: 0) {
            search
            scopes
        }
        .frame(height: Metrics.headerHeight)
    }

    private var search: some View {
        HStack(spacing: 10) {
            Text("Navi")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("type to search...", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.searchHeight)
    }

    private var scopes: some View {
        HStack(spacing: 4) {
            ForEach(HistoryScope.allCases, id: \.self) { scope in
                let selected = model.scope == scope
                Text(scope.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(selected ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { model.scope = scope }
            }
            Spacer()
            Text("⇥")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .frame(height: Metrics.scopeHeight)
    }

    @ViewBuilder
    private func list(_ results: [CaptureItem]) -> some View {
        if results.isEmpty {
            Text(model.query.isEmpty && model.scope == .all ? "Copy something to start." : "No matches.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            ClipboardRow(model: model, item: item, index: index)
                            .frame(height: Metrics.rowHeight(for: item))
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { model.hover(index) } }
                            .onTapGesture { onChoose(item) }
                        }
                    }
                    .padding(Metrics.listPadding)
                    .id(SelectionFollower.listID)
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, visible in
                    model.visibleRect = visible
                }
                .background(SelectionFollower(model: model, results: results, proxy: proxy))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 10)
            FooterRow(title: "Clear", shortcut: "⌥⌘⌫") { model.clear() }
            FooterRow(title: "Quit", shortcut: "⌘Q", action: onQuit)
        }
        .padding(.vertical, Metrics.listPadding)
        .padding(.horizontal, Metrics.listPadding)
    }
}

private struct SelectionFollower: View {
    let model: ClipboardModel
    let results: [CaptureItem]
    let proxy: ScrollViewProxy
    static let listID = "list"

    var body: some View {
        Color.clear
            .onChange(of: model.selection) { _, selection in
                guard !model.selectedByHover, let anchor = model.scrollAnchor(for: selection, in: results) else { return }
                if selection == 0 || selection == results.count - 1 {
                    proxy.scrollTo(Self.listID, anchor: anchor)
                } else {
                    proxy.scrollTo(results[selection].id, anchor: anchor)
                }
            }
            .onChange(of: model.opens) { proxy.scrollTo(Self.listID, anchor: .top) }
    }
}

private struct ClipboardRow: View {
    let model: ClipboardModel
    let item: CaptureItem
    let index: Int

    var body: some View {
        ClipboardRowContent(model: model, item: item, index: index, isSelected: model.selection == index)
            .equatable()
    }
}

private struct ClipboardRowContent: View, @MainActor Equatable {
    let model: ClipboardModel
    let item: CaptureItem
    let index: Int
    let isSelected: Bool
    @State private var loaded: NSImage?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.index == rhs.index && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 6) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            content
            Spacer(minLength: 12)
            if index < 9 {
                Text("⌘ \(index + 1)")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .task(id: item.contentHash) {
            if item.fileName != nil { loaded = await model.thumbnail(for: item) }
        }
    }

    @ViewBuilder private var content: some View {
        if item.fileName != nil {
            if let image = model.cachedThumbnail(for: item) ?? loaded {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: Metrics.imageRowHeight - 10, alignment: .leading)
            }
        } else {
            Text(Self.preview(item.text ?? ""))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    static func preview(_ text: String) -> String {
        String(text.prefix(400))
            .replacingOccurrences(of: "\r\n", with: "⏎")
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

private struct FooterRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut).foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.footerRowHeight)
        .foregroundStyle(hovering ? Color.white : Color.primary)
        .background(hovering ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

struct ClipboardPreview: View {
    let item: CaptureItem
    let image: NSImage?
    let appIcon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: Metrics.previewMaxWidth, maxHeight: Metrics.previewMaxHeight, alignment: .leading)
            } else {
                Text(String((item.text ?? "").prefix(3000)))
                    .lineLimit(24)
                    .frame(maxWidth: Metrics.previewMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                if let app = item.sourceApp {
                    HStack(spacing: 4) {
                        Text("Application:")
                        if let icon = appIcon {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                        }
                        Text(app)
                    }
                }
                Text("First copy time: \(item.createdAt.formatted(date: .long, time: .shortened))")
                Text("Last copy time: \(item.lastUsedAt.formatted(date: .long, time: .shortened))")
                Text("Number of copies: \(item.copyCount)")
            }
            VStack(alignment: .leading, spacing: 2) {
                if item.kind.isImage { Text("Press ⌘E to mark up.") }
                Text("Press ⌥P to (un)pin.")
                Text("Press ⌥⌫ to delete.")
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .fixedSize()
    }
}
