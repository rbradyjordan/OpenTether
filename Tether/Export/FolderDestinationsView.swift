import SwiftUI
import TetherCore

/// Folders picked in Files that exports (and the Library import) can use:
/// iCloud Drive, "Connect to Server" shares, USB-C drives, any provider.
/// Each remembers what kind of folder it is so exports follow that tool.
struct FolderDestinationsView: View {
    @Environment(AppModel.self) private var app
    @State private var folders: [StoredFolderDestination] = []
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if folders.isEmpty {
                    Text("No folders yet. Add one from iCloud Drive, a server, a USB-C drive or any Files location.")
                        .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                }
                ForEach(folders) { folder in row(folder) }
                    .onDelete(perform: delete)
                Button { picking = true } label: { Label("Add a folder from Files…", systemImage: "folder.badge.plus") }
            } footer: {
                Text("Pick the root of a Capture One session and Open Tether writes straight into its Capture, Selects and Trash folders. Mark a folder as Lightroom Auto Import to keep it flat with sidecars written first.")
            }
            if let error { Section { Text(error).foregroundStyle(TetherColor.danger) } }
        }
        .tint(TetherColor.accent)
        .tetherList()
        .navigationTitle("Saved folders")
        .onAppear(perform: reload)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try app.store.save(try FolderAccess.destination(for: url))
                error = nil
                reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func row(_ folder: StoredFolderDestination) -> some View {
        VStack(alignment: .leading, spacing: TetherSpace.s) {
            HStack(spacing: TetherSpace.m) {
                IconTile(systemImage: Self.symbol(for: folder.kind), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                    if let path = folder.displayPath {
                        Text(path).font(TetherFont.hud).foregroundStyle(TetherColor.ink2).lineLimit(1)
                    }
                }
            }
            Picker("Kind", selection: Binding(get: { folder.kind }, set: { kind in
                var updated = folder
                updated.kind = kind
                try? app.store.save(updated)
                reload()
            })) {
                ForEach(StoredFolderDestination.Kind.allCases, id: \.self) { kind in Text(Self.title(for: kind)).tag(kind) }
            }
            .pickerStyle(.menu)
            .font(TetherFont.callout)
        }
        .padding(.vertical, TetherSpace.xs)
    }

    private func reload() { folders = (try? app.store.folderDestinations()) ?? [] }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { try? app.store.deleteFolderDestination(folders[i].id) }
        reload()
    }

    static func title(for kind: StoredFolderDestination.Kind) -> String {
        switch kind {
        case .plain: return "Folder"
        case .captureOneSession: return "Capture One session"
        case .lightroomAutoImport: return "Lightroom Auto Import"
        }
    }

    static func symbol(for kind: StoredFolderDestination.Kind) -> String {
        switch kind {
        case .plain: return "folder"
        case .captureOneSession: return "camera.aperture"
        case .lightroomAutoImport: return "square.and.arrow.down.on.square"
        }
    }
}
