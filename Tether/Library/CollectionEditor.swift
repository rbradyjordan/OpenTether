import SwiftUI
import TetherCore

/// Create or edit a collection: name, symbol, tint; for smart collections the
/// rule is edited with the same chips as the grid, with a live count.
struct CollectionEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var draft: Collection
    var library: LibraryModel
    /// Captures to add once a new manual collection exists ("New collection from selection").
    var pendingIDs: [String] = []

    @State private var rule = CaptureFilter()
    @State private var count = 0

    static let symbols = ["rectangle.stack", "star", "heart", "flag", "person.crop.rectangle", "camera", "sparkles.rectangle.stack",
                          "folder", "tag", "sun.max", "moon", "paintpalette", "bolt", "leaf", "building.2", "airplane"]

    private var isNew: Bool { library.collection(draft.id) == nil }
    private var isSmart: Bool { draft.kind == .smart }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(isSmart ? "Smart collection" : "Collection", text: $draft.name)
                        .disabled(draft.isBuiltIn)
                }
                Section("Symbol and colour") {
                    SymbolPicker(selected: $draft.symbol)
                    ColorLabelPicker(current: draft.tint) { draft.tint = $0 }
                }
                if isSmart { ruleSection }
            }
            .tetherList()
            .navigationTitle(isNew ? (isSmart ? "New smart collection" : "New collection") : "Edit collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(isNew ? "Create" : "Save") { save() }.disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear { rule = draft.rule ?? CaptureFilter(); count = library.previewCount(for: rule) }
            .onChange(of: rule) { _, r in count = library.previewCount(for: r) }
        }
    }

    private var ruleSection: some View {
        Section {
            FilterChips(filter: $rule, sessions: library.sessions, cameras: library.cameras, suggestions: library.tagSuggestions(prefix:))
                .listRowInsets(EdgeInsets())
            Text(rule.summary).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
        } header: { Text("Rule") } footer: {
            Text("\(count) photo\(count == 1 ? "" : "s") match right now").contentTransition(.numericText())
        }
    }

    private func save() {
        var c = draft
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if isSmart { c.rule = rule }
        if isNew, !isSmart, !pendingIDs.isEmpty {
            app.commands.createCollection(named: c.name, with: pendingIDs, symbol: c.symbol, tint: c.tint)
        } else if isNew, isSmart {
            app.commands.saveSmartCollection(c)
        } else {
            library.save(c)
        }
        dismiss()
    }
}

/// A small fixed SF Symbol set; 44 pt cells.
struct SymbolPicker: View {
    @Binding var selected: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: TetherSpace.xs) {
            ForEach(CollectionEditor.symbols, id: \.self) { s in
                Button { selected = s } label: {
                    Image(systemName: s)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(selected == s ? TetherColor.accent : TetherColor.ink1)
                        .frame(width: TetherHit.min, height: TetherHit.min)
                        .background(selected == s ? TetherColor.accentSoft : .clear, in: RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(selected == s ? .isSelected : [])
            }
        }
    }
}
