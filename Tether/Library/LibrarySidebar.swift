import SwiftUI
import TetherCore

/// Library sources with counts. In compact width each row pushes the grid; in
/// regular width rows select the source the content column shows.
struct LibrarySidebar: View {
    enum Mode { case compact, regular }

    @Environment(AppModel.self) private var app
    var mode: Mode
    var selected: Binding<RegularRootView.SidebarItem?>? = nil

    @State private var editing: Collection?
    @State private var newKind: Collection.Kind?
    @State private var renaming: Collection?
    @State private var renameText = ""
    @State private var pendingDelete: Collection?

    private var library: LibraryModel { app.library }

    var body: some View {
        List {
            if mode == .regular { shootSection }
            section("Library", library.builtIns)
            if !library.pinned.isEmpty { section("Pinned", library.pinned) }
            mySection
            if !library.smart.isEmpty { section("Smart collections", library.smart) }
            sessionsSection
            if !library.cameras.isEmpty { camerasSection }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(TetherColor.surface1)
        .sheet(item: $editing) { c in CollectionEditor(draft: c, library: library) }
        .sheet(item: $newKind) { kind in CollectionEditor(draft: newDraft(kind), library: library) }
        .alert("Rename collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if var c = renaming, !renameText.isEmpty { c.name = renameText; library.save(c) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this collection?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete collection", role: .destructive) { if let c = pendingDelete { library.delete(c) }; pendingDelete = nil }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: { Text("Photos stay in the library; only the collection goes.") }
        .onAppear { library.reloadSources() }
    }

    // MARK: Sections

    private var shootSection: some View {
        Section("Shoot") {
            Button {
                if app.shoot != nil { app.showShoot() } else { selected?.wrappedValue = .connect }
            } label: {
                Label(app.shoot == nil ? "Connect a camera" : "Live · \(app.shoot?.cameraName ?? "")",
                      systemImage: app.shoot == nil ? "cable.connector" : "camera.aperture")
                    .foregroundStyle(app.shoot == nil ? TetherColor.ink0 : TetherColor.accent)
            }
            .listRowBackground(selected?.wrappedValue == .connect ? TetherColor.accentSoft : nil)
        }
    }

    private func section(_ title: String, _ list: [Collection]) -> some View {
        Section(title) {
            ForEach(list) { c in row(.collection(c.id), name: c.name, symbol: c.symbol, tint: c.tint).modifier(CollectionRowActions(collection: c, onPin: { library.togglePin(c) }, onRename: { renameText = c.name; renaming = c }, onEdit: { editing = c }, onDelete: { pendingDelete = c })) }
        }
    }

    private var mySection: some View {
        Section {
            ForEach(library.manual) { c in
                row(.collection(c.id), name: c.name, symbol: c.symbol, tint: c.tint)
                    .modifier(CollectionRowActions(collection: c, onPin: { library.togglePin(c) }, onRename: { renameText = c.name; renaming = c }, onEdit: { editing = c }, onDelete: { pendingDelete = c }))
            }
            .onMove { library.moveManual(from: $0, to: $1) }
            Button { newKind = .manual } label: { Label("New collection", systemImage: "plus") }
            Button { newKind = .smart } label: { Label("New smart collection from current filter", systemImage: "sparkles") }
        } header: {
            HStack { Text("My collections"); Spacer(); if !library.manual.isEmpty { EditButton().font(TetherFont.hud) } }
        }
    }

    private var sessionsSection: some View {
        Section("Sessions") {
            ForEach(library.sessions.prefix(30)) { s in row(.session(s.id), name: s.name, symbol: "rectangle.stack", tint: .none) }
        }
    }

    private var camerasSection: some View {
        Section("Cameras") {
            ForEach(library.cameras) { c in row(.camera(c.id), name: c.displayName, symbol: "camera", tint: .none) }
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ source: LibraryModel.Source, name: String, symbol: String, tint: TetherCoreColorLabel) -> some View {
        let label = SourceRow(name: name, symbol: symbol, tint: tint, count: library.count(for: source))
        switch mode {
        case .compact:
            NavigationLink(value: source) { label }
        case .regular:
            Button { library.select(source); selected?.wrappedValue = .library } label: { label }
                .listRowBackground(library.source == source && selected?.wrappedValue != .connect ? TetherColor.accentSoft : nil)
        }
    }

    private func newDraft(_ kind: Collection.Kind) -> Collection {
        switch kind {
        case .manual: return Collection(name: "", kind: .manual)
        case .smart: return Collection(name: "", kind: .smart, rule: library.effectiveFilter, symbol: "sparkles.rectangle.stack")
        }
    }
}

extension Collection.Kind: Identifiable { public var id: String { rawValue } }

/// Symbol, tinted dot, name, count.
struct SourceRow: View {
    var name: String
    var symbol: String
    var tint: TetherCoreColorLabel
    var count: Int

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            Image(systemName: symbol).foregroundStyle(tint == .none ? TetherColor.ink1 : ColorLabelStyle.color(for: tint)).frame(width: 24)
            Text(name.isEmpty ? "Untitled" : name).font(TetherFont.body).foregroundStyle(TetherColor.ink0).lineLimit(1)
            Spacer()
            Text("\(count)").font(TetherFont.hud).foregroundStyle(TetherColor.ink2).contentTransition(.numericText())
        }
        .frame(minHeight: TetherHit.min)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(count) photos")
    }
}

/// Swipe and context actions for one collection row; built-ins only pin.
private struct CollectionRowActions: ViewModifier {
    var collection: Collection
    var onPin: () -> Void
    var onRename: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) { Button(action: onPin) { Label(collection.isPinned ? "Unpin" : "Pin", systemImage: collection.isPinned ? "pin.slash" : "pin") }.tint(TetherColor.warn) }
            .swipeActions(edge: .trailing) {
                if !collection.isBuiltIn {
                    Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    Button(action: onRename) { Label("Rename", systemImage: "pencil") }.tint(TetherColor.ink1)
                }
            }
            .contextMenu {
                Button(action: onPin) { Label(collection.isPinned ? "Unpin" : "Pin", systemImage: collection.isPinned ? "pin.slash" : "pin") }
                if !collection.isBuiltIn {
                    Button(action: onRename) { Label("Rename…", systemImage: "pencil") }
                    Button(action: onEdit) { Label(collection.kind == .smart ? "Edit rule…" : "Edit…", systemImage: "slider.horizontal.3") }
                    Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                }
            }
    }
}
