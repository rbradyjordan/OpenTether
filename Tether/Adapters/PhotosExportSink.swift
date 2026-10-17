import Foundation
import Photos
import TetherCore

/// Saves into an album named after the session (created on first use).
final class PhotosExportSink: ExportSink, @unchecked Sendable {
    private let store: SessionStore
    init(store: SessionStore) { self.store = store }

    func deliver(fileURL: URL, item: ExportJob.Item, destination: ExportDestination) async throws -> String? {
        // Sidecars and manifests have no place in Photos.
        if item.isCompanion { return nil }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotosSinkError.notAuthorized }
        // Add-only access can save photos but can't see or create albums, so
        // the session album is a bonus when full access was already granted
        // (never asked for here), and a failure there never fails the export.
        var album: PHAssetCollection?
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            album = try? await ensureAlbum(named: sessionName(for: item) ?? "Open Tether")
        }
        var localID: String?
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL) else { return }
            localID = request.placeholderForCreatedAsset?.localIdentifier
            if let album, let placeholder = request.placeholderForCreatedAsset,
               let albumChange = PHAssetCollectionChangeRequest(for: album) {
                albumChange.addAssets([placeholder] as NSArray)
            }
        }
        return localID
    }

    private func sessionName(for item: ExportJob.Item) -> String? {
        guard let capture = try? store.capture(item.id), let session = try? store.session(capture.sessionID) else { return nil }
        return session.name
    }

    private func ensureAlbum(named name: String) async throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject {
            return existing
        }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            placeholderID = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil).firstObject
    }
}

enum PhotosSinkError: Error, CustomStringConvertible {
    case notAuthorized
    var description: String { "Open Tether is not allowed to add to your photo library. Enable it in Settings → Privacy → Photos." }
}
