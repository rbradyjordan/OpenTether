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
    @State private var templateDraft: WorkspaceMemory.SessionTemplate?
    @State private var manifestURLs: [URL]?

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
                                Button { app.resume(session) } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.tetherPrimary)
                            }
                            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.buttonStyle(.tetherSecondary)
                                .disabled(items.filter { $0.state.isReady }.isEmpty)
                            NavigationLink(value: AppRoute.exportProgress(sessionID: session.id)) { Label("Exports", systemImage: "list.bullet") }.buttonStyle(.tetherSecondary)
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
                            .clipShape(RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous))
                            .opacity(item.flag == .reject ? 0.4 : 1)
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
        .tetherScreen()
        .navigationTitle(session?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { newName = session?.name ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    if let session {
                        Button { templateDraft = app.memory.template(from: session, name: session.name) } label: { Label("Save as template", systemImage: "doc.badge.plus") }
                        Button { shareManifest(session) } label: { Label("Share manifest", systemImage: "doc.text") }
                        Button { app.library.select(.session(session.id)); app.selectedTab = .library } label: { Label("Open in Library", systemImage: "photo.on.rectangle.angled") }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $templateDraft) { t in TemplateEditor(template: t, isNew: true) }
        .sheet(isPresented: Binding(get: { manifestURLs != nil }, set: { if !$0 { manifestURLs = nil } })) {
            if let urls = manifestURLs { ShareSheet(items: urls) }
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                guard var s = session, !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                app.renameSession(s, to: newName)
                s.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                session = s
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showExport) {
            if let session {
                ExportSheet(sessionID: session.id, items: items, selectedID: selectedID, look: LookStack(lookID: session.lookID, strength: session.lookStrength))
            }
        }
        .fullScreenCover(isPresented: $showLoupe) { StoredLoupeView(items: items.filter { $0.state.isReady }, selectedID: $selectedID).forceDark() }
        .onAppear(perform: load)
    }

    private func load() {
        session = try? app.store.session(sessionID)
        items = (try? app.store.captures(in: sessionID)) ?? []
    }

    /// JSON + CSV manifest of the session (files, ratings, tags, collections) to the share sheet.
    private func shareManifest(_ session: ShootSession) {
        var tags: [String: [String]] = [:]
        var collections: [String: [String]] = [:]
        let names = Dictionary(uniqueKeysWithValues: app.library.collections.map { ($0.id, $0.name) })
        for item in items {
            tags[item.id] = (try? app.store.tags(for: item.id)) ?? []
            collections[item.id] = ((try? app.store.collectionIDs(containing: item.id)) ?? []).compactMap { names[$0] }
        }
        let manifest = SessionManifest(session: session, captures: items, tags: tags, collections: collections)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(session.directoryName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = session.name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        let json = dir.appendingPathComponent("\(base).json")
        let csv = dir.appendingPathComponent("\(base).csv")
        do {
            try manifest.json().write(to: json)
            try manifest.csv().write(to: csv, atomically: true, encoding: .utf8)
            manifestURLs = [json, csv]
        } catch { app.toast = ToastMessage(text: "\(error)", systemImage: "exclamationmark.triangle") }
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
                        Text(item.filename).font(TetherFont.hud).foregroundStyle(TetherColor.ink0)
                        if let line = item.exposure?.line, !line.isEmpty { Text(line).font(TetherFont.hud).foregroundStyle(TetherColor.ink1) }
                    }
                    .padding(12).background(.black.opacity(0.6))
                }
            }
        }
        .statusBarHidden(true)
    }
}
