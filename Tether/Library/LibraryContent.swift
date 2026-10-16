import SwiftUI
import TetherCore
import UniformTypeIdentifiers

/// Filter bar + grid + batch bar for the current source. Serves as the pushed
/// screen on iPhone and the content column on iPad.
struct LibraryContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable var model: LibraryModel
    @State private var showInspectorSheet = false
    @State private var importing = false
    @State private var pickingCatalog = false
    @State private var catalogURL: URL?

    private var isCompact: Bool { sizeClass != .regular }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(model: model)
            LibraryGrid(model: model)
        }
        .tetherScreen()
        .safeAreaInset(edge: .bottom) { BatchBar(model: model) }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { LibraryToolbar(model: model, compact: isCompact, showInspector: $showInspectorSheet, importing: $importing, pickingCatalog: $pickingCatalog) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .image, .rawImage, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await app.importFromFiles(urls) } }
        }
        .background {
            // A second importer needs its own host view.
            Color.clear.fileImporter(isPresented: $pickingCatalog, allowedContentTypes: UTType.catalogTypes + [.data]) { result in
                if case .success(let url) = result { catalogURL = url }
            }
        }
        .sheet(item: Binding(get: { catalogURL.map(IdentifiedURL.init) }, set: { catalogURL = $0?.url })) { item in
            CatalogSyncSheet(catalogURL: item.url)
        }
        .librarySearch(model: model)
        .toolbarTitleMenu { titleMenu }
        .sheet(isPresented: $showInspectorSheet) {
            NavigationStack { InspectorView(model: model).navigationTitle("Inspector").navigationBarTitleDisplayMode(.inline) }
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: Binding(get: { model.loupeID != nil }, set: { if !$0 { model.loupeID = nil } })) {
            LibraryLoupeView(model: model)
        }
        .onChange(of: model.inspectorOpen) { _, open in if isCompact { showInspectorSheet = open } }
        .onChange(of: showInspectorSheet) { _, open in if isCompact, !open, model.inspectorOpen { model.inspectorOpen = false } }
        .onAppear { if isCompact, model.inspectorOpen { model.inspectorOpen = false } }
    }

    /// Long-press on the title (iPhone's palette entry point) and quick view switches.
    @ViewBuilder private var titleMenu: some View {
        Button { app.commands.request = .palette } label: { Label("Command palette", systemImage: "command") }
        Toggle(isOn: $model.stackPairs) { Label("Stack RAW + JPEG", systemImage: "square.2.layers.3d") }
        SortMenu(model: model)
        ZoomMenu(model: model)
    }
}

/// Toolbar: Select, undo/redo, inspector, sort/zoom (regular has room; compact folds into "More").
private struct LibraryToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel
    var compact: Bool
    @Binding var showInspector: Bool
    @Binding var importing: Bool
    @Binding var pickingCatalog: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(model.selectionMode ? "Done" : "Select") { model.selectionMode.toggle() }
                .accessibilityLabel(model.selectionMode ? "Leave selection mode" : "Select photos")
            if !compact {
                Menu {
                    Button { importing = true } label: { Label("Import photos or a folder…", systemImage: "square.and.arrow.down") }
                    Button { pickingCatalog = true } label: { Label("Sync ratings from a catalog…", systemImage: "arrow.triangle.2.circlepath") }
                } label: { Label("Import", systemImage: "square.and.arrow.down") }
                UndoRedoButtons(model: model)
                SortMenu(model: model)
                ZoomMenu(model: model)
            }
            Button {
                if compact { showInspector = true; model.inspectorOpen = true } else { model.inspectorOpen.toggle() }
            } label: { Label("Inspector", systemImage: model.inspectorOpen ? "sidebar.right" : "info.circle") }
            .disabled(model.inspectedItem == nil && !model.inspectorOpen)
            if compact {
                Menu {
                    Button { importing = true } label: { Label("Import photos or a folder…", systemImage: "square.and.arrow.down") }
                    Button { pickingCatalog = true } label: { Label("Sync ratings from a catalog…", systemImage: "arrow.triangle.2.circlepath") }
                    UndoRedoButtons(model: model)
                    SortMenu(model: model)
                    ZoomMenu(model: model)
                    Toggle(isOn: $model.stackPairs) { Label("Stack RAW + JPEG", systemImage: "square.2.layers.3d") }
                    Button { app.commands.request = .palette } label: { Label("Command palette", systemImage: "command") }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
    }
}

/// `URL` wrapper for `.sheet(item:)`.
struct IdentifiedURL: Identifiable {
    var url: URL
    var id: String { url.absoluteString }
}
