import Foundation

/// Review metadata that round-trips to the gallery layer later.
public enum CaptureFlag: String, Codable, Sendable, CaseIterable { case none, pick, reject }

public enum ColorLabel: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, red, yellow, green, blue, purple
    public var id: String { rawValue }
}

/// One frame received from the camera (or pushed over FTP). RAW+JPEG pairs
/// are two items sharing a `pairKey`.
public struct CaptureItem: Identifiable, Codable, Hashable, Sendable {
    public enum State: Codable, Hashable, Sendable {
        case announced
        case downloading(received: Int, total: Int?)
        case ready
        case failed(String)

        public var isReady: Bool { if case .ready = self { return true }; return false }
        public var isFailed: Bool { if case .failed = self { return true }; return false }
        public var progress: Double? {
            if case .downloading(let r, let t) = self, let t, t > 0 { return Double(r) / Double(t) }
            return nil
        }
    }

    public var id: String
    public var sessionID: String
    public var sequence: Int
    public var handle: UInt32
    public var filename: String
    public var kind: MediaKind
    public var bytes: Int
    public var width: Int
    public var height: Int
    public var capturedAt: Date
    public var receivedAt: Date
    /// Relative path under the session directory (never absolute; see §7 of the spec).
    public var relativePath: String?
    /// JPEG proxy for RAW files (camera-embedded preview or our own render).
    public var proxyRelativePath: String?
    public var thumbnailRelativePath: String?
    public var rating: Int
    public var flag: CaptureFlag
    public var colorLabel: ColorLabel
    public var state: State
    public var pairKey: String
    public var source: TransportKind
    public var lookID: String?
    public var exposure: ExposureSummary?

    public init(id: String = UUID().uuidString, sessionID: String, sequence: Int, handle: UInt32, filename: String,
                kind: MediaKind, bytes: Int, width: Int = 0, height: Int = 0, capturedAt: Date = Date(),
                receivedAt: Date = Date(), relativePath: String? = nil, proxyRelativePath: String? = nil,
                thumbnailRelativePath: String? = nil, rating: Int = 0, flag: CaptureFlag = .none,
                colorLabel: ColorLabel = .none, state: State = .announced, pairKey: String? = nil,
                source: TransportKind, lookID: String? = nil, exposure: ExposureSummary? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.handle = handle
        self.filename = filename
        self.kind = kind
        self.bytes = bytes
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.receivedAt = receivedAt
        self.relativePath = relativePath
        self.proxyRelativePath = proxyRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.rating = max(0, min(5, rating))
        self.flag = flag
        self.colorLabel = colorLabel
        self.state = state
        self.pairKey = pairKey ?? CaptureItem.pairKey(for: filename)
        self.source = source
        self.lookID = lookID
        self.exposure = exposure
    }

    /// `IMG_0001.CR3` and `IMG_0001.JPG` share `IMG_0001`.
    public static func pairKey(for filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return base.isEmpty ? filename : base.uppercased()
    }

    public var isRAW: Bool { kind == .raw }
    public var displayName: String { filename }

    /// The file to show: a JPEG proxy for RAW when we have one, else the original.
    public var previewRelativePath: String? { proxyRelativePath ?? (kind == .raw ? nil : relativePath) }
}

/// Exposure read from the camera at capture time (not EXIF; that comes later).
public struct ExposureSummary: Codable, Hashable, Sendable {
    public var aperture: String?
    public var shutter: String?
    public var iso: String?
    public var compensation: String?
    public var whiteBalance: String?

    public init(aperture: String? = nil, shutter: String? = nil, iso: String? = nil, compensation: String? = nil, whiteBalance: String? = nil) {
        self.aperture = aperture
        self.shutter = shutter
        self.iso = iso
        self.compensation = compensation
        self.whiteBalance = whiteBalance
    }

    public init(from descriptors: [PropertyDescriptor]) {
        func v(_ p: TetherProperty) -> String? { descriptors.first { $0.property == p }?.display }
        self.init(aperture: v(.aperture), shutter: v(.shutterSpeed), iso: v(.iso), compensation: v(.exposureCompensation), whiteBalance: v(.whiteBalance))
    }

    public var line: String {
        [shutter, aperture, iso.map { "ISO \($0)" }, compensation.flatMap { $0 == "0" ? nil : "\($0) EV" }]
            .compactMap { $0 }.joined(separator: "  ")
    }
}

/// A shoot. Created before connecting; survives relaunch for mid-shoot recovery.
public struct ShootSession: Identifiable, Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case active, interrupted, ended }

    public var id: String
    public var name: String
    public var createdAt: Date
    public var endedAt: Date?
    public var status: Status
    public var camera: CameraIdentity?
    public var transport: TransportKind?
    /// For PTP/IP reconnects after backgrounding.
    public var lastHost: String?
    public var destination: CaptureDestination
    public var routing: RoutingRules
    public var lookID: String?
    public var lookStrength: Double
    public var showNewestCapture: Bool
    /// Optional reference to the booking/client in the workflow platform.
    public var workflowTag: String?
    public var captureCount: Int

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), endedAt: Date? = nil,
                status: Status = .active, camera: CameraIdentity? = nil, transport: TransportKind? = nil,
                lastHost: String? = nil, destination: CaptureDestination = .both, routing: RoutingRules = RoutingRules(),
                lookID: String? = nil, lookStrength: Double = 1, showNewestCapture: Bool = true,
                workflowTag: String? = nil, captureCount: Int = 0) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.status = status
        self.camera = camera
        self.transport = transport
        self.lastHost = lastHost
        self.destination = destination
        self.routing = routing
        self.lookID = lookID
        self.lookStrength = lookStrength
        self.showNewestCapture = showNewestCapture
        self.workflowTag = workflowTag
        self.captureCount = captureCount
    }

    /// Directory name under the storage root. Validated: no separators.
    public var directoryName: String { id.replacingOccurrences(of: "/", with: "_") }
}

/// Where each media kind goes on export (JPEG → Photos, RAW → Files by default).
public struct RoutingRules: Codable, Hashable, Sendable {
    public enum Target: String, Codable, Sendable, CaseIterable, Identifiable {
        case photos, files, cloud, ftp, none
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .photos: return "Photos"
            case .files: return "Files (on My iPhone)"
            case .cloud: return "Cloud batch"
            case .ftp: return "FTP server"
            case .none: return "Keep in session only"
            }
        }
    }

    public var jpeg: Target
    public var raw: Target
    public var video: Target
    public var autoExportPicks: Bool
    public var ftpDestinationID: String?

    public init(jpeg: Target = .photos, raw: Target = .files, video: Target = .files, autoExportPicks: Bool = false, ftpDestinationID: String? = nil) {
        self.jpeg = jpeg
        self.raw = raw
        self.video = video
        self.autoExportPicks = autoExportPicks
        self.ftpDestinationID = ftpDestinationID
    }

    public func target(for kind: MediaKind) -> Target {
        switch kind {
        case .jpeg, .heif, .jpegXL: return jpeg
        case .raw: return raw
        case .video: return video
        case .other: return .files
        }
    }
}
