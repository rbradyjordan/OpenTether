import SwiftUI
import TetherCore

/// Sessions as large cards, resume banner on top. Light scheme (system).
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showNew = false
    @State private var pendingDelete: ShootSession?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: TetherSpace.m) {
                ForEach(app.interrupted) { s in ResumeBanner(session: s) }
                if app.sessions.isEmpty {
                    EmptyState(systemImage: "rectangle.stack", title: "No sessions yet",
                               message: "A session groups one shoot's frames, ratings and exports.",
                               actionTitle: "New session") { showNew = true }
                        .padding(.top, TetherSpace.xxl)
                }
                ForEach(app.sessions) { session in
                    card(session)
                        .contextMenu {
                            Button(role: .destructive) { pendingDelete = session } label: { Label("Delete session", systemImage: "trash") }
                        }
                }
            }
            .padding(TetherSpace.l)
            .animation(Motion.spring(TetherMotion.arrive, reduce: reduceMotion), value: app.sessions.count)
        }
        .background(TetherColor.surface1)
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
