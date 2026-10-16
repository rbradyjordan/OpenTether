import SwiftUI
import TetherCore
import UniformTypeIdentifiers

extension UTType {
    /// Lightroom Classic catalog (declared in Info.plist as an imported type).
    static let lightroomCatalog = UTType(importedAs: "com.adobe.lightroom.catalog", conformingTo: .data)
    /// Capture One catalog package and session database.
    static let captureOneCatalog = UTType(importedAs: "com.captureone.catalog", conformingTo: .package)
    static let captureOneCatalogDatabase = UTType(importedAs: "com.captureone.catalogdb", conformingTo: .data)
    static let captureOneSession = UTType(importedAs: "com.captureone.session", conformingTo: .data)

    static let catalogTypes: [UTType] = [.lightroomCatalog, .captureOneCatalog, .captureOneCatalogDatabase, .captureOneSession]
}

/// Brings culling done in Lightroom Classic or Capture One back here: reads
/// a catalog (read-only, through a private copy), shows what would change,
/// and applies it through the review editor so it is one undoable step.
struct CatalogSyncSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var catalogURL: URL

    @State private var kind: CatalogKind?
    @State private var changes: [CatalogChange] = []
    @State private var unmatched: [String] = []
    @State private var openElsewhere = false
    @State private var error: String?
    @State private var loading = true
    @State private var applying = false

    private var counts: (ratings: Int, flags: Int, labels: Int, keywords: Int) {
        (changes.filter { $0.rating != nil }.count, changes.filter { $0.flag != nil }.count,
         changes.filter { $0.label != nil }.count, changes.reduce(0) { $0 + $1.newKeywords.count })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: TetherSpace.m) {
                        IconTile(systemImage: kind == .captureOne ? "camera.aperture" : "books.vertical", active: true, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catalogURL.deletingPathExtension().lastPathComponent).font(TetherFont.headline)
                            Text(kind?.displayName ?? "Catalog").font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
                        }
                    }
                    if openElsewhere {
                        Label("Lightroom has this catalog open. Showing everything it has saved so far.", systemImage: "info.circle")
                            .font(TetherFont.callout).foregroundStyle(TetherColor.warn)
                    }
                    if kind == .captureOne {
                        Label("Capture One support is experimental: ratings and colour tags are read; keywords are not.", systemImage: "flask")
                            .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                    }
                }
                if loading {
                    Section { HStack { ProgressView(); Text("Reading the catalog…").foregroundStyle(TetherColor.ink1) } }
                } else if let error {
                    Section { Text(error).foregroundStyle(TetherColor.danger) }
                } else if changes.isEmpty {
                    Section {
                        Label("Everything already matches.", systemImage: "checkmark.circle.fill").foregroundStyle(TetherColor.ok)
                    } footer: { unmatchedFooter }
                } else {
                    Section {
                        summaryRow("Star ratings", counts.ratings, "star.fill")
                        summaryRow("Picks and rejects", counts.flags, "flag.fill")
                        summaryRow("Colour labels", counts.labels, "circle.fill")
                        summaryRow("New keywords", counts.keywords, "tag.fill")
                    } header: { Text("\(changes.count) frame\(changes.count == 1 ? "" : "s") will change") } footer: { unmatchedFooter }
                    Section("Frames") {
                        ForEach(changes.prefix(200), id: \.captureID) { change in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.filename).font(TetherFont.callout.weight(.medium))
                                Text(describe(change)).font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
                            }
                        }
                    }
                }
            }
            .tetherList()
            .navigationTitle("Sync from catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await apply() } }
                        .disabled(changes.isEmpty || applying)
                }
            }
            .task { await load() }
        }
    }

    private func summaryRow(_ title: String, _ count: Int, _ symbol: String) -> some View {
        LabeledContent { Text("\(count)").monospacedDigit().foregroundStyle(TetherColor.ink1) } label: {
            Label(title, systemImage: symbol)
        }
    }

    @ViewBuilder private var unmatchedFooter: some View {
        if !unmatched.isEmpty {
            Text("\(unmatched.count) photo\(unmatched.count == 1 ? "" : "s") in the catalog are not in Open Tether and were left alone.")
        }
    }

    private func describe(_ c: CatalogChange) -> String {
        var parts: [String] = []
        if let r = c.rating { parts.append(r == 0 ? "no stars" : "\(r)★") }
        if let f = c.flag { parts.append(f == .pick ? "pick" : (f == .reject ? "reject" : "unflagged")) }
        if let l = c.label { parts.append(l == .none ? "no label" : l.rawValue) }
        if !c.newKeywords.isEmpty { parts.append(c.newKeywords.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        kind = CatalogKind.detect(catalogURL)
        let url = catalogURL
        let store = app.store
        let result: Result<([CatalogChange], [String], Bool), Error> = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                var entries: [CatalogEntry] = []
                var thrown: Error?
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { readable in
                    do { entries = try CatalogReader.entries(at: readable) } catch { thrown = error }
                }
                if let coordError { throw coordError }
                if let thrown { throw thrown }
                let captures = try store.captures(matching: CaptureFilter())
                let matched = CatalogMatcher.changes(entries: entries, captures: captures,
                                                     exportedNames: (try? store.exportedFilenames()) ?? [:],
                                                     tags: { (try? store.tags(for: $0)) ?? [] })
                return .success((matched.changes, matched.unmatched, CatalogKind.isOpenElsewhere(url)))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let (c, u, open)): changes = c; unmatched = u; openElsewhere = open
        case .failure(let e): error = (e as? CatalogError)?.description ?? e.localizedDescription
        }
        loading = false
    }

    /// Grouped by value so each kind of change is one editor call (and one undo step).
    private func apply() async {
        applying = true
        defer { applying = false }
        let editor = app.editor
        do {
            for (stars, group) in Dictionary(grouping: changes.filter { $0.rating != nil }, by: { $0.rating! }) {
                try await editor.rate(group.map(\.captureID), stars: stars)
            }
            for (flag, group) in Dictionary(grouping: changes.filter { $0.flag != nil }, by: { $0.flag! }) {
                try await editor.flag(group.map(\.captureID), flag)
            }
            for (label, group) in Dictionary(grouping: changes.filter { $0.label != nil }, by: { $0.label! }) {
                try await editor.label(group.map(\.captureID), label)
            }
            for change in changes where !change.newKeywords.isEmpty {
                try await editor.addTags(change.newKeywords, to: [change.captureID])
            }
            app.library.reload()
            app.toast = ToastMessage(text: "Synced \(changes.count) frame\(changes.count == 1 ? "" : "s") from \(kind == .captureOne ? "Capture One" : "Lightroom")",
                                     systemImage: "arrow.triangle.2.circlepath")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
