import NaviDictation
import SwiftUI

enum VocabularyMetrics {
    static let listHeight: CGFloat = 112
    static let rowHeight: CGFloat = 20
    static let fieldInset: CGFloat = 6
}

struct VocabularyRows: View {
    let store: VocabularyStore
    @State private var draft = ""
    @FocusState private var isTyping: Bool

    var body: some View {
        MenuRow {
            TextField("Add a name or word", text: $draft)
                .textFieldStyle(.plain)
                .focused($isTyping)
                .onSubmit(add)
                .padding(.horizontal, VocabularyMetrics.fieldInset)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.06)))
            Button("Add", action: add)
                .controlSize(.mini)
                .disabled(draft.trimmingCharacters(in: .whitespaces).count < Vocabulary.minTermLength)
        }
        MenuRow {
            words
                .frame(height: VocabularyMetrics.listHeight)
        }
        MenuRow {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var words: some View {
        let terms = store.added + store.learned
        if terms.isEmpty {
            Text("Words you add or copy often show up here")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(terms) { term in
                        WordRow(term: term) { store.remove(term.id) }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var summary: String {
        let added = store.added.count
        let learned = store.learned.count
        return "\(added) added, \(learned) learned; Parakeet uses \(store.boostedCount) of \(Vocabulary.engineLimit)"
    }

    private func add() {
        guard store.add(draft) else { return }
        draft = ""
        isTyping = true
    }
}

private struct WordRow: View {
    let term: VocabularyTerm
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(term.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if term.source == .learned {
                Text("learned")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help(term.source == .learned ? "Remove; Navi will not learn it again" : "Remove")
            .accessibilityLabel("Remove \(term.text)")
        }
        .font(.system(size: 12))
        .frame(height: VocabularyMetrics.rowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
