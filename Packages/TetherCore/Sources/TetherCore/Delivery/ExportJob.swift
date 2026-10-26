import Foundation

/// Where a set of selects goes.
public enum ExportDestination: Codable, Hashable, Sendable {
    case photos
    case files
    case share            // handed to the share sheet by the app
    case ftp(destinationID: String)
    /// A folder the user picked in Files (iCloud Drive, a server, an SSD…),
    /// kept as a security-scoped bookmark in `StoredFolderDestination`.
    case folder(destinationID: String)

    public var displayName: String {
        switch self {
        case .photos: return "Photos"
        case .files: return "Files"
        case .share: return "Share"
        case .ftp: return "FTP"
        case .folder: return "Folder"
        }
    }

    public var key: String {
        switch self {
        case .photos: return "photos"
        case .files: return "files"
        case .share: return "share"
        case .ftp: return "ftp"
        case .folder: return "folder"
        }
    }
}

/// What happens to RAW files on export (when `includeRAW`).
public enum RAWOutput: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// Byte-for-byte original (plus sidecar): for Lightroom / Capture One.
    case original
    /// Developed with the system RAW engine, then encoded.
    case jpeg, heif, tiff16

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .original: return "Original RAW"
        case .jpeg: return "JPEG"
        case .heif: return "HEIF"
        case .tiff16: return "16-bit TIFF"
        }
    }
    /// Extension the delivered file gets (nil = keep the RAW's own).
    public var fileExtension: String? {
        switch self {
        case .original: return nil
        case .jpeg: return "jpg"
        case .heif: return "heic"
        case .tiff16: return "tif"
        }
    }
}

public struct ExportOptions: Codable, Hashable, Sendable {
    public var applyLook: Bool
    public var maxLongEdge: Int?      // nil = full size
    public var jpegQuality: Double
    public var includeRAW: Bool
    public var filenamePrefix: String?
    /// Interop: how files are named and arranged, and what metadata rides along.
    public var naming: NamingTemplate
    public var layout: FolderLayout
    public var embedMetadata: Bool        // XMP packet inside exported JPEGs
    public var writeSidecars: Bool        // .xmp next to RAW (and JPEG when the profile asks)
    public var writeManifest: Bool        // session manifest JSON + CSV with the files
    /// Refresh only the XMP sidecars (ratings changed after the files were
    /// delivered, e.g. culling on the phone into a Capture One hot folder).
    public var metadataOnly: Bool
    /// RAW files: original, or developed to JPEG / HEIF / 16-bit TIFF.
    public var rawOutput: RAWOutput

    public init(applyLook: Bool = true, maxLongEdge: Int? = nil, jpegQuality: Double = 0.92,
                includeRAW: Bool = false, filenamePrefix: String? = nil, naming: NamingTemplate = .original,
                layout: FolderLayout = .flat, embedMetadata: Bool = true, writeSidecars: Bool = true, writeManifest: Bool = false,
                metadataOnly: Bool = false, rawOutput: RAWOutput = .original) {
        self.applyLook = applyLook
        self.maxLongEdge = maxLongEdge
        self.jpegQuality = jpegQuality
        self.includeRAW = includeRAW
        self.filenamePrefix = filenamePrefix
        self.naming = naming
        self.layout = layout
        self.embedMetadata = embedMetadata
        self.writeSidecars = writeSidecars
        self.writeManifest = writeManifest
        self.metadataOnly = metadataOnly
        self.rawOutput = rawOutput
    }

    /// Tolerate options saved before the interop fields existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applyLook = try c.decodeIfPresent(Bool.self, forKey: .applyLook) ?? true
        maxLongEdge = try c.decodeIfPresent(Int.self, forKey: .maxLongEdge)
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.92
        includeRAW = try c.decodeIfPresent(Bool.self, forKey: .includeRAW) ?? false
        filenamePrefix = try c.decodeIfPresent(String.self, forKey: .filenamePrefix)
        metadataOnly = try c.decodeIfPresent(Bool.self, forKey: .metadataOnly) ?? false
        rawOutput = try c.decodeIfPresent(RAWOutput.self, forKey: .rawOutput) ?? .original
        naming = try c.decodeIfPresent(NamingTemplate.self, forKey: .naming) ?? .original
        layout = try c.decodeIfPresent(FolderLayout.self, forKey: .layout) ?? .flat
        embedMetadata = try c.decodeIfPresent(Bool.self, forKey: .embedMetadata) ?? true
        writeSidecars = try c.decodeIfPresent(Bool.self, forKey: .writeSidecars) ?? true
        writeManifest = try c.decodeIfPresent(Bool.self, forKey: .writeManifest) ?? false
    }
}

/// A resumable, persisted export. Each item is attempted independently so a
/// backgrounded or killed app picks up exactly where it left off.
public struct ExportJob: Identifiable, Codable, Hashable, Sendable {
    public enum Status: Codable, Hashable, Sendable {
        case queued, running, paused, completed, failed(String)
        public var key: String {
            switch self {
            case .queued: return "queued"
            case .running: return "running"
            case .paused: return "paused"
            case .completed: return "completed"
            case .failed: return "failed"
            }
        }
        public var isTerminal: Bool { key == "completed" || key == "failed" }
    }

    public struct Item: Identifiable, Codable, Hashable, Sendable {
        public enum State: Codable, Hashable, Sendable { case pending, uploading(Double), done(String?), skipped(String), failed(String) }
        public var id: String           // capture id
        public var filename: String
        public var kind: MediaKind
        public var bytes: Int
        public var state: State
        public var remoteID: String?    // Photos local identifier / delivered path
        /// Interop: the name and relative folder the file is delivered under
        /// (set by the queue from `ExportOptions.naming` / `.layout`).
        public var exportFilename: String?
        public var exportDirectory: String?
        /// True for a generated companion (XMP sidecar, manifest), not a photo.
        public var isCompanion: Bool

        public init(id: String, filename: String, kind: MediaKind, bytes: Int, state: State = .pending, remoteID: String? = nil,
                    exportFilename: String? = nil, exportDirectory: String? = nil, isCompanion: Bool = false) {
            self.id = id
            self.filename = filename
            self.kind = kind
            self.bytes = bytes
            self.state = state
            self.remoteID = remoteID
            self.exportFilename = exportFilename
            self.exportDirectory = exportDirectory
            self.isCompanion = isCompanion
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            filename = try c.decode(String.self, forKey: .filename)
            kind = try c.decode(MediaKind.self, forKey: .kind)
            bytes = try c.decode(Int.self, forKey: .bytes)
            state = try c.decodeIfPresent(State.self, forKey: .state) ?? .pending
            remoteID = try c.decodeIfPresent(String.self, forKey: .remoteID)
            exportFilename = try c.decodeIfPresent(String.self, forKey: .exportFilename)
            exportDirectory = try c.decodeIfPresent(String.self, forKey: .exportDirectory)
            isCompanion = try c.decodeIfPresent(Bool.self, forKey: .isCompanion) ?? false
        }

        /// Final relative path under the destination root.
        public var deliveredRelativePath: String {
            let name = exportFilename ?? filename
            return (exportDirectory ?? "").isEmpty ? name : "\(exportDirectory!)/\(name)"
        }
        public var isDone: Bool { if case .done = state { return true }; if case .skipped = state { return true }; return false }
    }

    public var id: String
    public var sessionID: String
    public var destination: ExportDestination
    public var options: ExportOptions
    public var look: LookStack
    public var createdAt: Date
    public var status: Status
    public var items: [Item]
    public var attempts: Int

    public init(id: String = UUID().uuidString, sessionID: String, destination: ExportDestination, options: ExportOptions,
                look: LookStack, createdAt: Date = Date(), status: Status = .queued, items: [Item], attempts: Int = 0) {
        self.id = id
        self.sessionID = sessionID
        self.destination = destination
        self.options = options
        self.look = look
        self.createdAt = createdAt
        self.status = status
        self.items = items
        self.attempts = attempts
    }

    public var progress: Double {
        guard !items.isEmpty else { return 1 }
        let done = items.reduce(0.0) { acc, i in
            switch i.state {
            case .done, .skipped: return acc + 1
            case .uploading(let p): return acc + p
            default: return acc
            }
        }
        return done / Double(items.count)
    }

    public var pendingItems: [Item] { items.filter { !$0.isDone && { if case .failed = $0.state { return false }; return true }($0) } }
    public var failedItems: [Item] { items.filter { if case .failed = $0.state { return true }; return false } }
}

/// Options for the hot folder (`RoutingRules.liveFolderID`): originals kept
/// byte-for-byte under their camera names, RAW included, sidecars written
/// first, laid out the way the folder's tool expects.
public enum HotFolder {
    public static func options(for folder: StoredFolderDestination, metadataOnly: Bool = false) -> ExportOptions {
        ExportOptions(applyLook: false, includeRAW: true, naming: .original,
                      layout: folder.suggestedLayout ?? .flat, embedMetadata: true, writeSidecars: true, writeManifest: false,
                      metadataOnly: metadataOnly)
    }
}
