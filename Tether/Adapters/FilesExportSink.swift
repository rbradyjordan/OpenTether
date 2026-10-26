import Foundation
import TetherCore

/// Copies into Documents/Exports/<session>/ (visible in Files thanks to
/// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace). `.share` goes
/// to Documents/Exports/<session>/Share/ so the progress screen can hand the
/// finished files to the share sheet.
final class FilesExportSink: ExportSink, @unchecked Sendable {
    private let store: SessionStore
    let exportsRoot: URL

    init(store: SessionStore, exportsRoot: URL? = nil) {
        self.store = store
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.exportsRoot = exportsRoot ?? docs.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Lays files out as the job's naming template and folder layout decided
    /// (`deliveredRelativePath`), creating nested directories; sidecars and
    /// manifests are companions and land beside their photos.
    func deliver(fileURL: URL, item: ExportJob.Item, destination: ExportDestination) async throws -> String? {
        let folder = sessionFolderName(for: item)
        var dir = exportsRoot.appendingPathComponent(folder, isDirectory: true)
        if case .share = destination { dir = dir.appendingPathComponent("Share", isDirectory: true) }
        let relative = item.deliveredRelativePath
        let subdir = (relative as NSString).deletingLastPathComponent
        if !subdir.isEmpty { dir = dir.appendingPathComponent(subdir, isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let preferred = (relative as NSString).lastPathComponent
        let target = uniqueURL(in: dir, preferred: preferred.isEmpty ? fileURL.lastPathComponent : preferred)
        try FileManager.default.copyItem(at: fileURL, to: target)
        return target.path
    }

    private func sessionFolderName(for item: ExportJob.Item) -> String {
        guard let capture = try? store.capture(item.id), let session = try? store.session(capture.sessionID) else { return "Open Tether" }
        let cleaned = session.name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
        return cleaned.isEmpty ? session.directoryName : cleaned
    }

    private func uniqueURL(in dir: URL, preferred: String) -> URL {
        var url = dir.appendingPathComponent(preferred)
        var n = 1
        let base = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            n += 1
        }
        return url
    }
}

/// Dispatches by destination; the queue only knows one sink.
struct RoutingExportSink: ExportSink {
    let photos: PhotosExportSink
    let files: FilesExportSink
    let folders: FolderExportSink

    func deliver(fileURL: URL, item: ExportJob.Item, destination: ExportDestination) async throws -> String? {
        switch destination {
        case .photos: return try await photos.deliver(fileURL: fileURL, item: item, destination: destination)
        case .files, .share: return try await files.deliver(fileURL: fileURL, item: item, destination: destination)
        case .folder: return try await folders.deliver(fileURL: fileURL, item: item, destination: destination)
        case .ftp: return nil // handled inside ExportQueue
        }
    }

    func prepareDirectories(_ directories: [String], destination: ExportDestination) async throws {
        if case .folder = destination { try await folders.prepareDirectories(directories, destination: destination) }
    }
}
