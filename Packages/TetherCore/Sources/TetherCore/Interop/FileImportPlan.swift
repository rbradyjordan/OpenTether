import Foundation

/// Turns a pile of files (picked one by one, or every file under a folder)
/// into captures to import, each with its XMP sidecar when one sits beside
/// it. Both sidecar spellings are matched: `IMG_0001.xmp` (Lightroom,
/// Capture One, Photo Mechanic) and `IMG_0001.CR3.xmp` (darktable, some
/// DAMs). Hidden files, manifests, catalogs and anything that is not a
/// still or a video are left out.
public struct FileImportPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var file: URL
        public var sidecar: URL?
    }

    public var entries: [Entry]
    /// Files that were neither importable media nor a matched sidecar.
    public var skipped: [URL]

    public init(files: [URL]) {
        var sidecars: [String: URL] = [:]
        var media: [URL] = []
        var skipped: [URL] = []
        for url in files {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "xmp" {
                // Key by the full stem, which for "IMG.CR3.xmp" is "IMG.CR3".
                sidecars[Self.key(url.deletingPathExtension())] = url
                continue
            }
            let kind = PTPObjectInfo(objectFormat: .undefined, filename: name).mediaKind
            if kind == .other { skipped.append(url) } else { media.append(url) }
        }
        var used = Set<URL>()
        var entries: [Entry] = []
        for url in media.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let sidecar = sidecars[Self.key(url)] ?? sidecars[Self.key(url.deletingPathExtension())]
            if let sidecar { used.insert(sidecar) }
            entries.append(Entry(file: url, sidecar: sidecar))
        }
        skipped += sidecars.values.filter { !used.contains($0) }
        self.entries = entries
        self.skipped = skipped
    }

    /// Every regular file under `folder` (recursively), for a folder import.
    public static func files(under folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .isPackageKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { out.append(url) }
        }
        return out
    }

    private static func key(_ url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.path + "/" + url.lastPathComponent.uppercased()
    }
}
