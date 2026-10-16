import SwiftUI
import TetherCore

extension View {
    /// Presents whatever the dispatcher asked for (tag sheet, collection picker,
    /// export, palette, confirmations). Installed once at the root.
    func commandRequests() -> some View { modifier(CommandRequestsModifier()) }
}

private struct CommandRequestsModifier: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetBinding) { request in sheet(for: request) }
            .confirmationDialog("Delete from this device?", isPresented: deleteBinding, titleVisibility: .visible) {
                if case .delete(let ids)? = app.commands.request {
                    Button("Delete \(ids.count == 1 ? "photo" : "\(ids.count) photos")", role: .destructive) { app.commands.confirmDelete(ids); app.commands.request = nil }
                }
                Button("Keep", role: .cancel) { app.commands.request = nil }
            } message: {
                Text("The files leave the phone. Anything still on the card stays there.")
            }
    }

    /// Everything but `.delete` (a dialog) goes through one sheet.
    private var sheetBinding: Binding<CommandDispatcher.Request?> {
        Binding(get: {
            if case .delete? = app.commands.request { return nil }
            return app.commands.request
        }, set: { app.commands.request = $0 })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { if case .delete? = app.commands.request { return true }; return false },
                set: { if !$0 { app.commands.request = nil } })
    }

    @ViewBuilder private func sheet(for request: CommandDispatcher.Request) -> some View {
        switch request {
        case .tags(let ids): TagEditorSheet(ids: ids)
        case .addToCollection(let ids): CollectionPickerSheet(ids: ids)
        case .newCollection(let ids): CollectionEditor(draft: Collection(name: "", kind: .manual), library: app.library, pendingIDs: ids)
        case .saveSmart(let filter): CollectionEditor(draft: Collection(name: "", kind: .smart, rule: filter, symbol: "sparkles.rectangle.stack"), library: app.library)
        case .export(let ids, _): LibraryExportSheet(ids: ids)
        case .compare(let ids): LibraryLoupeView(model: app.library, compareIDs: ids)
        case .clientReview(let ids): LibraryClientReview(ids: ids)
        case .saveTemplate(let session): TemplateEditor(template: app.memory.template(from: session, name: session.name), isNew: true)
        case .palette: CommandPalette()
        case .delete: EmptyView()
        }
    }
}

/// Export for an arbitrary id set (library selection or a whole collection).
private struct LibraryExportSheet: View {
    @Environment(AppModel.self) private var app
    var ids: [String]

    var body: some View {
        let items = (try? app.store.captures(ids: ids)) ?? []
        ExportSheet(sessionID: nil, items: items, selectedID: nil, look: .none, selectionIDs: ids, collectionName: app.library.title)
    }
}

/// Client review over library frames: true black, image only, swipe.
private struct LibraryClientReview: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var ids: [String]
    @State private var selectedID: String?

    var body: some View {
        let items = ((try? app.store.captures(ids: ids)) ?? []).filter { $0.state.isReady }
        StoredLoupeView(items: items, selectedID: $selectedID)
            .onAppear { selectedID = items.first?.id }
            .forceDark()
    }
}
