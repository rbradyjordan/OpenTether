import SwiftUI
import TetherCore

/// "Add to collection…": recent collections first, then the rest, plus a
/// shortcut to create a new one holding the same captures.
struct CollectionPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var ids: [String]
    @State private var showNew = false

    private var manual: [Collection] { app.library.manual }
    private var recentIDs: [String] { app.memory.get(WorkspaceMemory.recents).collectionIDs }
    private var recent: [Collection] { recentIDs.compactMap { id in manual.first { $0.id == id } } }
    private var others: [Collection] { manual.filter { !recentIDs.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                if !recent.isEmpty { Section("Recent") { ForEach(recent) { row($0) } } }
                Section(recent.isEmpty ? "Collections" : "All") {
                    ForEach(others) { row($0) }
                    if manual.isEmpty {
                        Text("No collections yet. Smart collections fill themselves; create a plain one for hand picks.")
                            .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                    }
                }
                Section { Button { showNew = true } label: { Label("New collection with these \(ids.count == 1 ? "photo" : "\(ids.count) photos")", systemImage: "plus") } }
            }
            .tetherList()
            .navigationTitle("Add to collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showNew, onDismiss: { dismiss() }) {
                CollectionEditor(draft: Collection(name: "", kind: .manual), library: app.library, pendingIDs: ids)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ c: Collection) -> some View {
        Button {
            app.commands.add(ids, to: c.id)
            dismiss()
        } label: {
            SourceRow(name: c.name, symbol: c.symbol, tint: c.tint, count: app.library.count(for: .collection(c.id)))
        }
    }
}
