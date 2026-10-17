import Foundation
import TetherCore

/// Folders the user picked in Files: iCloud Drive, a server under "Connect to
/// Server", a USB-C drive or any file provider. Each is kept as a
/// security-scoped bookmark; every read or write happens inside the scope and
/// through `NSFileCoordinator`, so providers (iCloud, SMB) see consistent files.
enum FolderAccess {
    enum Failure: LocalizedError {
        case unavailable(String)
        case notAFolder

        var errorDescription: String? {
            switch self {
            case .unavailable(let name):
                return "\(name) is not reachable. Reconnect the drive or server, or pick the folder again."
            case .notAFolder:
                return "That isn't a folder."
            }
        }
    }

    // The Mac App Sandbox only keeps access across launches for app-scoped
    // security bookmarks; on iOS a plain bookmark carries the scope.
    #if targetEnvironment(macCatalyst)
    private static let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Make a bookmark for a folder returned by the system folder picker.
    static func bookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// A destination record for a freshly picked folder, recognising a Capture
    /// One session root (it holds a `.cosessiondb`).
    static func destination(for url: URL) throws -> StoredFolderDestination {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw Failure.notAFolder }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let bookmark = try url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        return StoredFolderDestination(name: url.lastPathComponent, bookmark: bookmark,
                                       kind: StoredFolderDestination.detectKind(entries: entries),
                                       displayPath: displayPath(for: url))
    }

    /// Resolve the bookmark and run `body` inside its security scope. A stale
    /// bookmark (moved folder, remounted drive) is refreshed and saved back.
    static func withFolder<T>(_ destination: StoredFolderDestination, store: SessionStore,
                              _ body: (URL) throws -> T) throws -> T {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: destination.bookmark, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw Failure.unavailable(destination.name)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.unavailable(destination.name) }
        if stale, let fresh = try? url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var updated = destination
            updated.bookmark = fresh
            updated.displayPath = displayPath(for: url)
            try? store.save(updated)
        }
        return try body(url)
    }

    /// Copy `source` to `relativePath` under `root`, replacing what is there
    /// (re-exports update files instead of piling up "-1" copies). The copy
    /// lands under a hidden temporary name first and is moved into place, so
    /// watched folders never see a half-written photo.
    static func place(_ source: URL, at relativePath: String, under root: URL) throws -> URL {
        let target = root.appendingPathComponent(relativePath)
        let dir = target.deletingLastPathComponent()
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { dest in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let temp = dir.appendingPathComponent(".\(dest.lastPathComponent).opentether-part")
                try? FileManager.default.removeItem(at: temp)
                try FileManager.default.copyItem(at: source, to: temp)
                if FileManager.default.fileExists(atPath: dest.path) {
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: dest)
                }
            } catch {
                thrown = error
            }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
        return target
    }

    static func makeDirectories(_ relativePaths: [String], under root: URL) {
        for path in relativePaths {
            let url = root.appendingPathComponent(path, isDirectory: true)
            var coordError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { dest in
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            }
        }
    }

    /// "iCloud Drive › Shoots › AW26" style path for display.
    static func displayPath(for url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if let i = parts.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + parts[(i + 1)...]).joined(separator: " › ")
        }
        if let i = parts.firstIndex(of: "Documents"), parts.contains("Application") || parts.contains("Containers") {
            return (["On My iPhone"] + parts[(i + 1)...]).joined(separator: " › ")
        }
        return parts.suffix(3).joined(separator: " › ")
    }
}

/// Exports into a saved Files folder (`ExportDestination.folder`), following
/// the job's naming and layout under the folder's root.
final class FolderExportSink: ExportSink, @unchecked Sendable {
    private let store: SessionStore

    init(store: SessionStore) { self.store = store }

    private func destination(_ d: ExportDestination) throws -> StoredFolderDestination {
        guard case .folder(let id) = d, let dest = try store.folderDestination(id) else {
            throw FolderAccess.Failure.unavailable("The export folder")
        }
        return dest
    }

    func deliver(fileURL: URL, item: ExportJob.Item, destination: ExportDestination) async throws -> String? {
        let dest = try self.destination(destination)
        let relative = item.deliveredRelativePath.isEmpty ? fileURL.lastPathComponent : item.deliveredRelativePath
        return try FolderAccess.withFolder(dest, store: store) { root in
            try FolderAccess.place(fileURL, at: relative, under: root).path
        }
    }

    func prepareDirectories(_ directories: [String], destination: ExportDestination) async throws {
        let dest = try self.destination(destination)
        try FolderAccess.withFolder(dest, store: store) { root in FolderAccess.makeDirectories(directories, under: root) }
    }
}
