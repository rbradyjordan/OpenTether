import Foundation

/// Where a set of selects goes.
public enum ExportDestination: Codable, Hashable, Sendable {
    case photos
    case files
    case share            // handed to the share sheet by the app
    case ftp(destinationID: String)
    case cloudBatch

    public var displayName: String {
        switch self {
        case .photos: return "Photos"
        case .files: return "Files"
        case .share: return "Share"
        case .ftp: return "FTP"
        case .cloudBatch: return "Cloud batch"
        }
    }

    public var key: String {
        switch self {
        case .photos: return "photos"
        case .files: return "files"
        case .share: return "share"
        case .ftp: return "ftp"
        case .cloudBatch: return "cloud"
        }
    }
}

public struct ExportOptions: Codable, Hashable, Sendable {
    public var applyLook: Bool
    public var watermark: Bool
    public var maxLongEdge: Int?      // nil = full size
    public var jpegQuality: Double
    public var includeRAW: Bool
    public var filenamePrefix: String?

    public init(applyLook: Bool = true, watermark: Bool = false, maxLongEdge: Int? = nil, jpegQuality: Double = 0.92,
                includeRAW: Bool = false, filenamePrefix: String? = nil) {
        self.applyLook = applyLook
        self.watermark = watermark
        self.maxLongEdge = maxLongEdge
        self.jpegQuality = jpegQuality
        self.includeRAW = includeRAW
        self.filenamePrefix = filenamePrefix
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
        public var watermark: Bool
        public var state: State
        public var remoteID: String?    // cloud item id / Photos local identifier

        public init(id: String, filename: String, kind: MediaKind, bytes: Int, watermark: Bool = false, state: State = .pending, remoteID: String? = nil) {
            self.id = id
            self.filename = filename
            self.kind = kind
            self.bytes = bytes
            self.watermark = watermark
            self.state = state
            self.remoteID = remoteID
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
    public var creditsCharged: Int
    public var cloudBatchID: String?
    public var attempts: Int

    public init(id: String = UUID().uuidString, sessionID: String, destination: ExportDestination, options: ExportOptions,
                look: LookStack, createdAt: Date = Date(), status: Status = .queued, items: [Item], creditsCharged: Int = 0,
                cloudBatchID: String? = nil, attempts: Int = 0) {
        self.id = id
        self.sessionID = sessionID
        self.destination = destination
        self.options = options
        self.look = look
        self.createdAt = createdAt
        self.status = status
        self.items = items
        self.creditsCharged = creditsCharged
        self.cloudBatchID = cloudBatchID
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

/// Credits model mirrored from the server so the UI can show the cost before
/// asking: free tier pays 1 credit per JPEG export and gets a watermark when
/// the balance is gone; pro pays nothing. AI colour-match is 1 credit.
public struct CreditsState: Codable, Hashable, Sendable {
    public enum Tier: String, Codable, Sendable { case free, pro }
    public var tier: Tier
    public var balance: Int
    public var monthlyGrant: Int
    public var renewsAt: Date?
    public var fetchedAt: Date

    public init(tier: Tier = .free, balance: Int = 0, monthlyGrant: Int = 10, renewsAt: Date? = nil, fetchedAt: Date = Date()) {
        self.tier = tier
        self.balance = balance
        self.monthlyGrant = monthlyGrant
        self.renewsAt = renewsAt
        self.fetchedAt = fetchedAt
    }

    public var watermarkRequired: Bool { tier == .free && balance <= 0 }

    public struct Quote: Equatable, Sendable {
        public var credits: Int
        public var watermarkedItems: Int
        public var totalItems: Int
    }

    /// What exporting `items` would cost right now, and how many would carry a watermark.
    public func quote(for items: [ExportJob.Item], forceWatermark: Bool) -> Quote {
        if tier == .pro { return Quote(credits: 0, watermarkedItems: forceWatermark ? items.count : 0, totalItems: items.count) }
        var remaining = balance
        var credits = 0, watermarked = 0
        for i in items {
            if i.kind != .jpeg && i.kind != .heif && i.kind != .jpegXL { continue }
            if forceWatermark { watermarked += 1; continue }
            if remaining > 0 { remaining -= 1; credits += 1 } else { watermarked += 1 }
        }
        return Quote(credits: credits, watermarkedItems: watermarked, totalItems: items.count)
    }

    public static let colorMatchCost = 1
}

/// Credit packs sold through StoreKit; the server applies them.
public enum CreditProduct: String, CaseIterable, Codable, Sendable, Identifiable {
    case credits50 = "credits_50"
    case credits200 = "credits_200"
    case proMonthly = "pro_monthly"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .credits50: return "50 credits"
        case .credits200: return "200 credits"
        case .proMonthly: return "Pro monthly"
        }
    }
    public var detail: String {
        switch self {
        case .credits50: return "50 clean JPEG exports or AI colour matches"
        case .credits200: return "200 credits, best value"
        case .proMonthly: return "Unlimited clean exports, no watermark, every look"
        }
    }
}
