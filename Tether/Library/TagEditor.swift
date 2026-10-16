import SwiftUI
import TetherCore

/// Tag chips with an entry field, autocomplete from `tagSuggestions` and the
/// recent tags as one-tap chips.
struct TagEditor: View {
    @Environment(AppModel.self) private var app
    var tags: [String]
    var suggestions: (String) -> [String]
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var recent: [String] { app.memory.get(WorkspaceMemory.recents).tags.filter { !tags.contains($0) } }
    private var matches: [String] { text.isEmpty ? [] : suggestions(text.replacingOccurrences(of: "#", with: "")).filter { !tags.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.s) {
            if !tags.isEmpty { chips(tags, remove: true) }
            HStack {
                TextField("Add tag", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { add(text) }
                    .frame(minHeight: TetherHit.min)
                    .accessibilityLabel("New tag")
                Button { add(text) } label: { Image(systemName: "plus.circle.fill").frame(width: TetherHit.min, height: TetherHit.min) }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add tag")
            }
            if !matches.isEmpty { chips(Array(matches.prefix(8)), remove: false) }
            else if !recent.isEmpty, focused || tags.isEmpty {
                Text("Recent").tetherCaption().foregroundStyle(TetherColor.ink2)
                chips(Array(recent.prefix(8)), remove: false)
            }
        }
    }

    private func chips(_ list: [String], remove: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TetherSpace.xs) {
                ForEach(list, id: \.self) { t in
                    Button { remove ? onRemove(t) : add(t) } label: {
                        Label("#\(t)", systemImage: remove ? "xmark" : "plus").labelStyle(TagChipLabelStyle())
                    }
                    .buttonStyle(ChipStyle(selected: remove))
                    .accessibilityLabel(remove ? "Remove tag \(t)" : "Add tag \(t)")
                }
            }
        }
    }

    private func add(_ raw: String) {
        let t = SessionStoreTag.normalize(raw)
        guard !t.isEmpty else { return }
        onAdd(t)
        text = ""
    }
}

/// Title first, glyph after, so chips read "#hero ×".
private struct TagChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: TetherSpace.xs) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

/// Mirror of the core's tag normalisation (lowercase, no `#`, hyphens for spaces).
enum SessionStoreTag {
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "-")
    }
}

/// Sheet form of the tag editor for a batch ("Add tags…" command).
struct TagEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var ids: [String]
    @State private var added: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Tags for \(ids.count == 1 ? "1 photo" : "\(ids.count) photos")") {
                    TagEditor(tags: added, suggestions: app.library.tagSuggestions(prefix:),
                              onAdd: { t in if !added.contains(t) { added.append(t) } },
                              onRemove: { t in added.removeAll { $0 == t } })
                }
            }
            .navigationTitle("Add tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { app.commands.addTags(added, to: ids); dismiss() }.disabled(added.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
