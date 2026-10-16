import Foundation

/// A collection is either a hand-picked set of captures or a saved query.
/// Smart collections evaluate in SQL, so they stay instant at tens of
/// thousands of frames and update the moment a rating changes.
public struct Collection: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case manual, smart }

    public var id: String
    public var name: String
    public var kind: Kind
    public var rule: CaptureFilter?        // smart only
    public var symbol: String              // SF Symbol name
    public var tint: ColorLabel            // accent for the sidebar dot; .none = neutral
    public var isPinned: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// Built-ins (All, Picks, Today…) cannot be deleted or renamed.
    public var isBuiltIn: Bool

    public init(id: String = UUID().uuidString, name: String, kind: Kind, rule: CaptureFilter? = nil,
                symbol: String = "rectangle.stack", tint: ColorLabel = .none, isPinned: Bool = false,
                sortOrder: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date(), isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rule = rule
        self.symbol = symbol
        self.tint = tint
        self.isPinned = isPinned
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isBuiltIn = isBuiltIn
    }

    public static func smart(_ name: String, _ rule: CaptureFilter, symbol: String, id: String? = nil, builtIn: Bool = false) -> Collection {
        Collection(id: id ?? UUID().uuidString, name: name, kind: .smart, rule: rule, symbol: symbol, isBuiltIn: builtIn)
    }

    /// The library's fixed shelves. Seeded once; their rules can't change.
    public static let builtIns: [Collection] = [
        .smart("All photos", CaptureFilter(), symbol: "photo.on.rectangle", id: "builtin.all", builtIn: true),
        .smart("Picks", CaptureFilter(flags: [.pick]), symbol: "flag.fill", id: "builtin.picks", builtIn: true),
        .smart("Five stars", CaptureFilter(minRating: 5), symbol: "star.fill", id: "builtin.5", builtIn: true),
        .smart("Unrated", CaptureFilter(maxRating: 0, flags: [.none]), symbol: "circle.dashed", id: "builtin.unrated", builtIn: true),
        .smart("Today", CaptureFilter(dateRange: .today), symbol: "sun.max", id: "builtin.today", builtIn: true),
        .smart("Rejects", CaptureFilter(flags: [.reject]), symbol: "xmark.bin", id: "builtin.rejects", builtIn: true),
    ]
}

/// A query over the library. Every field is optional; empty means "any".
/// Translates to one SQL WHERE clause (`sql()`), so it is also the filter
/// bar's model and the smart-collection rule.
public struct CaptureFilter: Codable, Hashable, Sendable {
    public enum DateRange: Codable, Hashable, Sendable {
        case today, last7Days, last30Days
        case between(Date, Date)
    }

    public var minRating: Int?
    public var maxRating: Int?
    public var flags: Set<CaptureFlag>?
    public var colors: Set<ColorLabel>?
    public var kinds: Set<MediaKind>?
    public var sessionIDs: Set<String>?
    public var cameraIDs: Set<String>?
    public var tagsAll: Set<String>?       // must carry every tag
    public var tagsAny: Set<String>?       // must carry at least one
    public var dateRange: DateRange?
    public var text: String?               // filename / session name / tag contains
    public var readyOnly: Bool
    public var hasLook: Bool?
    public var exportedTo: ExportDestinationKey?

    /// `never` rather than `none` so `exportedTo: .none` can't be mistaken for nil.
    public enum ExportDestinationKey: String, Codable, Hashable, Sendable { case photos, files, ftp, cloud, any, never }

    public init(minRating: Int? = nil, maxRating: Int? = nil, flags: Set<CaptureFlag>? = nil, colors: Set<ColorLabel>? = nil,
                kinds: Set<MediaKind>? = nil, sessionIDs: Set<String>? = nil, cameraIDs: Set<String>? = nil,
                tagsAll: Set<String>? = nil, tagsAny: Set<String>? = nil, dateRange: DateRange? = nil, text: String? = nil,
                readyOnly: Bool = true, hasLook: Bool? = nil, exportedTo: ExportDestinationKey? = nil) {
        self.minRating = minRating
        self.maxRating = maxRating
        self.flags = flags
        self.colors = colors
        self.kinds = kinds
        self.sessionIDs = sessionIDs
        self.cameraIDs = cameraIDs
        self.tagsAll = tagsAll
        self.tagsAny = tagsAny
        self.dateRange = dateRange
        self.text = text
        self.readyOnly = readyOnly
        self.hasLook = hasLook
        self.exportedTo = exportedTo
    }

    public var isEmpty: Bool {
        minRating == nil && maxRating == nil && flags == nil && colors == nil && kinds == nil && sessionIDs == nil
            && cameraIDs == nil && tagsAll == nil && tagsAny == nil && dateRange == nil && (text ?? "").isEmpty
            && hasLook == nil && exportedTo == nil
    }

    /// Human summary for chips: "4★+ · Picks · red, blue · #hero".
    public var summary: String {
        var parts = [String]()
        if let r = minRating, r > 0 { parts.append("\(r)★+") }
        if let r = maxRating, r == 0 { parts.append("unrated") }
        if let f = flags, !f.isEmpty { parts.append(f.map(\.rawValue).sorted().map { $0.capitalized }.joined(separator: "/")) }
        if let c = colors, !c.isEmpty { parts.append(c.map(\.rawValue).sorted().joined(separator: ", ")) }
        if let k = kinds, !k.isEmpty { parts.append(k.map { $0.rawValue.uppercased() }.sorted().joined(separator: "/")) }
        if let t = tagsAll, !t.isEmpty { parts.append(t.sorted().map { "#\($0)" }.joined(separator: " ")) }
        if let t = tagsAny, !t.isEmpty { parts.append("any of " + t.sorted().map { "#\($0)" }.joined(separator: " ")) }
        switch dateRange {
        case .today?: parts.append("today")
        case .last7Days?: parts.append("last 7 days")
        case .last30Days?: parts.append("last 30 days")
        case .between?: parts.append("date range")
        case nil: break
        }
        if let s = sessionIDs, !s.isEmpty { parts.append(s.count == 1 ? "1 session" : "\(s.count) sessions") }
        if let c = cameraIDs, !c.isEmpty { parts.append(c.count == 1 ? "1 camera" : "\(c.count) cameras") }
        if let t = text, !t.isEmpty { parts.append("“\(t)”") }
        if let e = exportedTo { parts.append(e == .never ? "not exported" : "exported\(e == .any ? "" : " to \(e.rawValue)")") }
        return parts.isEmpty ? "Everything" : parts.joined(separator: " · ")
    }

    /// WHERE clause over the `captures` table (aliased `c`) with bound values.
    /// Tags and exports use EXISTS sub-selects so the main query stays flat.
    public func sql(now: Date = Date()) -> (where: String, params: [SQLiteDatabase.Value]) {
        var clauses = [String]()
        var params = [SQLiteDatabase.Value]()
        if readyOnly { clauses.append("c.state = 'ready'") }
        if let r = minRating { clauses.append("c.rating >= ?"); params.append(.init(r)) }
        if let r = maxRating { clauses.append("c.rating <= ?"); params.append(.init(r)) }
        if let f = flags, !f.isEmpty { clauses.append(Self.inList("c.flag", f.count)); params += f.map { .text($0.rawValue) }.sorted(by: Self.textOrder) }
        if let c = colors, !c.isEmpty { clauses.append(Self.inList("c.color", c.count)); params += c.map { .text($0.rawValue) }.sorted(by: Self.textOrder) }
        if let k = kinds, !k.isEmpty { clauses.append(Self.inList("c.kind", k.count)); params += k.map { .text($0.rawValue) }.sorted(by: Self.textOrder) }
        if let s = sessionIDs, !s.isEmpty { clauses.append(Self.inList("c.session_id", s.count)); params += s.sorted().map { .text($0) } }
        if let cams = cameraIDs, !cams.isEmpty { clauses.append(Self.inList("c.camera_id", cams.count)); params += cams.sorted().map { .text($0) } }
        if let t = tagsAll, !t.isEmpty {
            for tag in t.sorted() { clauses.append("EXISTS (SELECT 1 FROM capture_tags t WHERE t.capture_id = c.id AND t.tag = ?)"); params.append(.text(tag)) }
        }
        if let t = tagsAny, !t.isEmpty {
            clauses.append("EXISTS (SELECT 1 FROM capture_tags t WHERE t.capture_id = c.id AND \(Self.inList("t.tag", t.count)))")
            params += t.sorted().map { .text($0) }
        }
        if let d = dateRange {
            let cal = Calendar.current
            let (from, to): (Date, Date?)
            switch d {
            case .today: (from, to) = (cal.startOfDay(for: now), nil)
            case .last7Days: (from, to) = (cal.date(byAdding: .day, value: -7, to: now) ?? now, nil)
            case .last30Days: (from, to) = (cal.date(byAdding: .day, value: -30, to: now) ?? now, nil)
            case .between(let a, let b): (from, to) = (a, b)
            }
            clauses.append("c.received_at >= ?"); params.append(.init(from))
            if let to { clauses.append("c.received_at <= ?"); params.append(.init(to)) }
        }
        if let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            clauses.append("(c.filename LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM sessions s WHERE s.id = c.session_id AND s.name LIKE ? ESCAPE '\\') OR EXISTS (SELECT 1 FROM capture_tags t WHERE t.capture_id = c.id AND t.tag LIKE ? ESCAPE '\\'))")
            let like = "%" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            params += [.text(like), .text(like), .text(like)]
        }
        if let h = hasLook { clauses.append(h ? "c.look_id IS NOT NULL" : "c.look_id IS NULL") }
        if let e = exportedTo {
            switch e {
            case .never: clauses.append("NOT EXISTS (SELECT 1 FROM capture_exports x WHERE x.capture_id = c.id)")
            case .any: clauses.append("EXISTS (SELECT 1 FROM capture_exports x WHERE x.capture_id = c.id)")
            default: clauses.append("EXISTS (SELECT 1 FROM capture_exports x WHERE x.capture_id = c.id AND x.destination = ?)"); params.append(.text(e.rawValue))
            }
        }
        return (clauses.isEmpty ? "1=1" : clauses.joined(separator: " AND "), params)
    }

    private static func inList(_ col: String, _ n: Int) -> String { "\(col) IN (\(Array(repeating: "?", count: n).joined(separator: ",")))" }
    private static func textOrder(_ a: SQLiteDatabase.Value, _ b: SQLiteDatabase.Value) -> Bool { (a.string ?? "") < (b.string ?? "") }
}

/// Sort for grids and filmstrips. Persisted per view in WorkspaceMemory.
public enum CaptureSort: String, Codable, Sendable, CaseIterable, Identifiable {
    case captureTimeAscending, captureTimeDescending, ratingDescending, filename, sessionThenTime

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .captureTimeAscending: return "Oldest first"
        case .captureTimeDescending: return "Newest first"
        case .ratingDescending: return "Rating"
        case .filename: return "Filename"
        case .sessionThenTime: return "Session"
        }
    }
    var orderBy: String {
        switch self {
        case .captureTimeAscending: return "c.received_at ASC, c.sequence ASC"
        case .captureTimeDescending: return "c.received_at DESC, c.sequence DESC"
        case .ratingDescending: return "c.rating DESC, c.received_at DESC"
        case .filename: return "c.filename COLLATE NOCASE ASC"
        case .sessionThenTime: return "c.session_id ASC, c.sequence ASC"
        }
    }
}

/// RAW+JPEG stacking: the grid shows one tile per pair with the JPEG on top.
public struct CaptureStack: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let items: [CaptureItem]
    public var top: CaptureItem { items.first { $0.kind != .raw } ?? items[0] }
    public var isPair: Bool { items.count > 1 }

    public static func stack(_ items: [CaptureItem]) -> [CaptureStack] {
        var order = [String]()
        var groups = [String: [CaptureItem]]()
        for i in items {
            let k = i.sessionID + "/" + i.pairKey
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        return order.map { CaptureStack(key: $0, items: groups[$0]!) }
    }
}
