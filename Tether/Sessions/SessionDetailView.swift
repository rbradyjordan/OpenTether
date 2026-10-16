import SwiftUI
import TetherCore

/// Ended (or paused) session: grid, loupe, export.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var app
    var sessionID: String

    @State private var session: ShootSession?
    @State private var items: [CaptureItem] = []
    @State private var selectedID: String?
    @State private var showExport = false
    @State private var showLoupe = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        ScrollView {
            if let session {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCard(title: nil) {
                        Text(session.name).font(.title2.weight(.semibold))
                        Text("\(items.count) frames · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))\(session.camera.map { " · \($0.displayName)" } ?? "")")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                        HStack {
                            if session.status != .ended {
                                Button { app.resume(session) } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                            }
                            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                                .disabled(items.filter { $0.state.isReady }.isEmpty)
                            NavigationLink(value: AppRoute.exportProgress(sessionID: session.id)) { Label("Exports", systemImage: "list.bullet") }.buttonStyle(.bordered)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 4)], spacing: 4) {
                        ForEach(items) { item in
                            ZStack(alignment: .bottomLeading) {
                                AsyncImageView(cache: app.cache, relativePath: item.thumbnailRelativePath ?? item.previewRelativePath, contentMode: .fill, maxPixelSize: 320)
                                    .frame(height: 100).clipped()
                                HStack(spacing: 3) {
                                    if item.flag == .pick { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Theme.success) }
                                    RatingDots(rating: item.rating)
                                }
                                .padding(4)
                            }
                            .cornerRadius(6)
                            .onTapGesture { selectedID = item.id; showLoupe = true }
                            .accessibilityLabel("\(item.filename), \(item.rating) stars")
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                .padding(16)
            } else {
                EmptyState(systemImage: "questionmark.folder", title: "Session not found", message: "")
            }
        }
        .background(Theme.background)
        .navigationTitle(session?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newName = session?.name ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            }
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                guard var s = session, !newName.isEmpty else { return }
                s.name = newName
                try? app.store.save(s)
                session = s
                app.reloadSessions()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showExport) {
            if let session {
                ExportSheet(sessionID: session.id, items: items, selectedID: selectedID, look: LookStack(lookID: session.lookID, strength: session.lookStrength))
            }
        }
        .fullScreenCover(isPresented: $showLoupe) { StoredLoupeView(items: items.filter { $0.state.isReady }, selectedID: $selectedID) }
        .onAppear(perform: load)
    }

    private func load() {
        session = try? app.store.session(sessionID)
        items = (try? app.store.captures(in: sessionID)) ?? []
    }
}

/// Loupe for stored sessions (no live session to round-trip through).
struct StoredLoupeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var items: [CaptureItem]
    @Binding var selectedID: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selectedID) {
                ForEach(items) { item in
                    AsyncImageView(cache: app.cache, relativePath: item.previewRelativePath, maxPixelSize: 4096)
                        .tag(String?.some(item.id))
                        .accessibilityLabel(item.filename)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.title3).padding(10).background(.black.opacity(0.5), in: Circle()) }
                        .accessibilityLabel("Close")
                    Spacer()
                }
                .padding()
                Spacer()
                if let item = items.first(where: { $0.id == selectedID }) {
                    VStack(spacing: 2) {
                        Text(item.filename).font(.subheadline.weight(.semibold))
                        if let line = item.exposure?.line, !line.isEmpty { Text(line).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                    }
                    .padding(12).background(.black.opacity(0.6))
                }
            }
        }
        .statusBarHidden(true)
    }
}
