import SwiftUI
import TetherCore

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var showNew = false

    var body: some View {
        List {
            if !app.interrupted.isEmpty {
                Section {
                    ForEach(app.interrupted) { s in ResumeBanner(session: s).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
            }
            Section {
                if app.sessions.isEmpty {
                    EmptyState(systemImage: "rectangle.stack", title: "No sessions yet",
                               message: "A session groups one shoot's frames, ratings and exports.", actionTitle: "New session") { showNew = true }
                        .listRowBackground(Color.clear)
                }
                ForEach(app.sessions) { session in
                    if app.shoot?.shootSession.id == session.id {
                        Button { app.selectedTab = .shoot } label: {
                            SessionRow(session: session, counts: app.counts[session.id] ?? SessionStore.SessionCounts())
                        }
                        .tint(.primary)
                    } else {
                        NavigationLink(value: AppRoute.sessionDetail(session.id)) {
                            SessionRow(session: session, counts: app.counts[session.id] ?? SessionStore.SessionCounts())
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { app.deleteSession(app.sessions[i]) }
                }
            } header: { Text("Sessions") }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Sessions")
        .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { showNew = true } label: { Label("New session", systemImage: "plus") } }
        }
        .sheet(isPresented: $showNew) { NewSessionSheet() }
        .onAppear { app.reloadSessions() }
    }
}
