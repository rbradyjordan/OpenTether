import SwiftUI
import TetherCore

/// Sessions as large cards, resume banner on top.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showNew = false
    @State private var pendingDelete: ShootSession?
    @State private var renaming: ShootSession?
    @State private var newName = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: TetherSpace.m) {
                ForEach(app.interrupted) { s in ResumeBanner(session: s) }
                ContinueCard()
                if app.sessions.isEmpty {
                    EmptyState(systemImage: "rectangle.stack", title: "No sessions yet",
                               message: "A session groups one shoot's frames, ratings and exports.",
                               actionTitle: "New session") { showNew = true }
                        .padding(.top, TetherSpace.xxl)
                }
                ForEach(app.sessions) { session in
                    card(session)
                        .contextMenu {
                            Button { newName = session.name; renaming = session } label: { Label("Rename…", systemImage: "pencil") }
                            Button(role: .destructive) { pendingDelete = session } label: { Label("Delete session", systemImage: "trash") }
                        }
                }
            }
            .padding(TetherSpace.l)
            .animation(Motion.spring(TetherMotion.arrive, reduce: reduceMotion), value: app.sessions.count)
        }
        .tetherScreen()
        .navigationTitle("Sessions")
        .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { showNew = true } label: { Label("New session", systemImage: "plus") } }
        }
        .sheet(isPresented: $showNew) { NewSessionSheet() }
        .confirmationDialog("Delete this session?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = pendingDelete { app.deleteSession(s) }
                pendingDelete = nil
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Frames, ratings and exports in this session are removed from the phone.")
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let s = renaming { app.renameSession(s, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onAppear { app.reloadSessions() }
    }

    @ViewBuilder private func card(_ session: ShootSession) -> some View {
        let counts = app.counts[session.id] ?? SessionStore.SessionCounts()
        let live = app.shoot?.shootSession.id == session.id
        if live {
            Button { app.selectedTab = .shoot } label: {
                SessionCard(session: session, counts: counts, isLive: true)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.sessionDetail(session.id)) {
                SessionCard(session: session, counts: counts)
            }
            .buttonStyle(.plain)
        }
    }
}

/// "Continue where you left off": the last library view, plus "Export like
/// last time" with the remembered destination and scope.
struct ContinueCard: View {
    @Environment(AppModel.self) private var app

    private var lastKey: String { app.memory.get(WorkspaceMemory.lastCollectionID) }
    private var source: LibraryModel.Source { .from(memoryKey: lastKey) }
    private var state: WorkspaceMemory.ViewState { app.memory.viewState(for: lastKey) }
    private var title: String {
        switch source {
        case .collection(let id): return app.library.collection(id)?.name ?? "All photos"
        case .session(let id): return app.sessions.first { $0.id == id }?.name ?? "Session"
        case .camera(let id): return app.library.cameras.first { $0.id == id }?.displayName ?? "Camera"
        }
    }
    private var lastExport: WorkspaceMemory.ExportMemory { app.memory.get(WorkspaceMemory.lastExport) }

    var body: some View {
        if app.library.count(for: source) > 0 {
            SectionCard(title: "Continue where you left off", systemImage: "arrow.uturn.forward") {
                Button { open() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                            Text("\(app.library.count(for: source)) photos · \(state.filter.summary) · \(state.sort.displayName) · \(GridMath.zoomTitle(state.columns))")
                                .font(TetherFont.hud).foregroundStyle(TetherColor.ink1).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(TetherColor.ink2)
                    }
                    .frame(minHeight: TetherHit.min)
                }
                .buttonStyle(.plain)
                Button { exportLikeLastTime() } label: {
                    Label("Export like last time · \(lastExport.destination.displayName)", systemImage: "arrow.uturn.up")
                        .frame(minHeight: TetherHit.min)
                }
                .buttonStyle(.tetherSecondary)
                .accessibilityHint("Exports this view's \(lastExport.scope) with the remembered settings")
            }
        }
    }

    private func open() {
        app.library.select(source)
        app.selectedTab = .library
    }

    /// Uses the remembered scope over the last view: picks, rated, or everything.
    private func exportLikeLastTime() {
        app.library.select(source)
        let scope = ExportScope.from(memory: lastExport.scope, selectionCount: 0, inCollection: true) ?? .all
        let ids = scope.filter(app.library.items, selectedID: nil).map(\.id)
        app.commands.exportAgain(ids)
    }
}
