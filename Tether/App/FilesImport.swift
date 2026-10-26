import Foundation
import TetherCore

/// Import from the Files app: single files or whole folders (iCloud Drive,
/// servers, USB-C drives…). Each photo is copied out of its security scope
/// together with its XMP sidecar, so ratings, labels and keywords set in
/// Lightroom, Capture One or Photo Mechanic come along. The user's folder is
/// never modified.
extension AppModel {
    /// Imports into the live shoot when there is one (and no other target is
    /// given), else into `target`, else into a new "Import" session. Returns
    /// how many frames were imported.
    @discardableResult
    func importFromFiles(_ picked: [URL], into target: ShootSession? = nil) async -> Int {
        var files: [URL] = []
        var scopes: [URL] = []
        for url in picked {
            if url.startAccessingSecurityScopedResource() { scopes.append(url) }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                files += FileImportPlan.files(under: url)
            } else {
                files.append(url)
            }
        }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        let plan = FileImportPlan(files: files)
        guard !plan.entries.isEmpty else {
            toast = ToastMessage(text: "No photos found there", systemImage: "questionmark.folder")
            return 0
        }

        let ingest: (URL, URL?) async -> Void
        var detached: TetherSession?
        if let shoot, target == nil || target?.id == shoot.shootSession.id {
            ingest = { file, sidecar in await shoot.session.ingestFile(at: file, from: "Files", sidecar: sidecar) }
        } else {
            let session = target ?? ShootSession(name: "Import \(Date().formatted(date: .abbreviated, time: .shortened))")
            try? store.save(session)
            let tether = TetherSession(session: session, identity: session.camera, handler: nil, engine: nil,
                                       store: store, cache: cache, previews: services.previews)
            detached = tether
            ingest = { file, sidecar in await tether.ingestFile(at: file, from: "Files", sidecar: sidecar) }
        }

        var imported = 0
        for entry in plan.entries {
            // Private copy (file + sidecar side by side); ingest consumes it.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let copy = tmp.appendingPathComponent(entry.file.lastPathComponent)
                try coordinatedCopy(entry.file, to: copy)
                var sidecarCopy: URL?
                if let sidecar = entry.sidecar {
                    let dest = tmp.appendingPathComponent(sidecar.lastPathComponent)
                    if (try? coordinatedCopy(sidecar, to: dest)) != nil { sidecarCopy = dest }
                }
                await ingest(copy, sidecarCopy)
                imported += 1
            } catch {
                toast = ToastMessage(text: "Could not read \(entry.file.lastPathComponent)", systemImage: "exclamationmark.triangle")
            }
            try? FileManager.default.removeItem(at: tmp)
        }
        if let detached { await detached.stop(ended: true) }
        reloadSessions()
        library.reload()
        toast = ToastMessage(text: "Imported \(imported) frame\(imported == 1 ? "" : "s")", systemImage: "square.and.arrow.down")
        return imported
    }

    /// Reads through a file coordinator so iCloud / server files are
    /// downloaded and consistent before copying.
    private func coordinatedCopy(_ source: URL, to destination: URL) throws {
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) } catch { thrown = error }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
    }
}

// MARK: - Hot folder

extension AppModel {
    /// Copy a frame that just landed into the session's hot folder (if one is
    /// set), through the export queue so naming, layout and sidecars match
    /// every other export. Hot-folder copies are always the originals.
    func sendToHotFolder(_ item: CaptureItem, session: ShootSession) {
        guard let folderID = session.routing.liveFolderID, item.kind.isStill || item.kind == .video,
              let folder = try? store.folderDestination(folderID) else { return }
        Task {
            let job = await exportQueue.makeJob(session: session, captures: [item], destination: .folder(destinationID: folder.id),
                                                options: HotFolder.options(for: folder), look: .none)
            try? await exportQueue.enqueue(job)
        }
    }

    /// Rewrite a frame's sidecar in the hot folder after it was re-rated,
    /// picked or labelled here, so Capture One / Lightroom see the change.
    func refreshHotFolderSidecar(_ item: CaptureItem, session: ShootSession) {
        guard let folderID = session.routing.liveFolderID, let folder = try? store.folderDestination(folderID) else { return }
        Task {
            let job = await exportQueue.makeJob(session: session, captures: [item], destination: .folder(destinationID: folder.id),
                                                options: HotFolder.options(for: folder, metadataOnly: true), look: .none)
            try? await exportQueue.enqueue(job)
        }
    }

    func setHotFolder(_ folderID: String?, for session: ShootSession) {
        var s = session
        s.routing.liveFolderID = folderID
        try? store.save(s)
        if shoot?.shootSession.id == s.id { shoot?.updateRouting(s.routing) }
        reloadSessions()
    }
}
