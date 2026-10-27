import Foundation

/// Filename / folder / caption templates with the tokens pros expect from
/// Capture One and Photo Mechanic style renamers.
///
/// Tokens: `{orig}` original base name · `{ext}` extension · `{session}` ·
/// `{date}` yyyy-MM-dd · `{time}` HHmmss · `{year}` `{month}` `{day}` ·
/// `{seq}` or `{seq:4}` zero-padded sequence · `{camera}` · `{rating}` ·
/// `{label}` · `{pick}` ("pick"/"reject"/"") · `{kind}` (jpeg/raw) ·
/// `{tag}` first tag · `{client}` workflow tag · `{room}` the room the frame
/// was shot in (real estate shot lists) · `{bracket}` its exposure bracket
/// ("b0012", from the first frame's sequence). Unknown tokens are kept.
public struct NamingTemplate: Codable, Hashable, Sendable {
    public var pattern: String
    public init(_ pattern: String) { self.pattern = pattern }

    public static let original = NamingTemplate("{orig}")
    public static let sessionSequence = NamingTemplate("{session}_{seq:4}")
    public static let dated = NamingTemplate("{date}_{session}_{seq:4}")
    /// Real estate delivery: `123-Main-St_Kitchen_03.jpg`.
    public static let listing = NamingTemplate("{session}_{room}_{seq:2}")
    public static let presets: [NamingTemplate] = [.original, .sessionSequence, .dated, NamingTemplate("{client}_{date}_{seq:3}"), .listing]

    public func render(capture: CaptureItem, sessionName: String?, index: Int, camera: String? = nil, tags: [String] = [],
                       client: String? = nil, now: Date? = nil) -> String {
        let d = now ?? capture.capturedAt
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        func fmt(_ s: String) -> String { f.dateFormat = s; return f.string(from: d) }
        var out = pattern
        let seqRegex = try! NSRegularExpression(pattern: "\\{seq(?::(\\d+))?\\}")
        let ns = out as NSString
        for m in seqRegex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            let width = m.range(at: 1).location != NSNotFound ? Int(ns.substring(with: m.range(at: 1))) ?? 4 : 4
            out = (out as NSString).replacingCharacters(in: m.range, with: String(format: "%0\(width)d", index))
        }
        let base = (capture.filename as NSString).deletingPathExtension
        let pairs: [(String, String)] = [
            ("{orig}", base), ("{ext}", (capture.filename as NSString).pathExtension.lowercased()),
            ("{session}", Self.safe(sessionName ?? "Session")), ("{date}", fmt("yyyy-MM-dd")), ("{time}", fmt("HHmmss")),
            ("{year}", fmt("yyyy")), ("{month}", fmt("MM")), ("{day}", fmt("dd")),
            ("{camera}", Self.safe(camera ?? "")), ("{rating}", capture.rating > 0 ? "\(capture.rating)" : "0"),
            ("{label}", capture.colorLabel == .none ? "" : capture.colorLabel.rawValue),
            ("{pick}", capture.flag == .pick ? "pick" : (capture.flag == .reject ? "reject" : "")),
            ("{kind}", capture.kind == .raw ? "raw" : "jpeg"), ("{client}", Self.safe(client ?? "")),
            ("{room}", Self.safe(RoomShotList.roomSlug(in: tags).map(RoomShotList.displayName(fromSlug:)) ?? "")),
            ("{bracket}", BracketDetector.bracketID(in: tags).flatMap { Int($0) }.map { String(format: "b%04d", $0) } ?? ""),
            // Plain tags only: room / bracket markers are not "the first tag".
            ("{tag}", Self.safe(tags.first { !$0.hasPrefix(RoomShotList.tagPrefix) && !$0.hasPrefix(BracketDetector.tagPrefix) } ?? "")),
        ]
        for (k, v) in pairs { out = out.replacingOccurrences(of: k, with: v) }
        return Self.safe(out, keepSeparators: true).isEmpty ? base : Self.safe(out, keepSeparators: true)
    }

    /// Filesystem-safe: strips path separators and control characters,
    /// collapses doubles, trims dots so Finder/Windows both accept it.
    public static func safe(_ s: String, keepSeparators: Bool = false) -> String {
        let bad = CharacterSet(charactersIn: keepSeparators ? "\\:*?\"<>|\0" : "/\\:*?\"<>|\0").union(.controlCharacters)
        var out = s.components(separatedBy: bad).joined(separator: "_")
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
    }
}

/// How an export lays out folders. `captureOne` is the Capture One session
/// tree (Capture / Selects / Output / Trash) so a shoot drops straight into
/// a C1 session; `dated` suits Lightroom's import by date.
public enum FolderLayout: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case flat, dated, bySession, captureOne, byRating
    /// Straight into an existing Capture One session folder (no session
    /// sub-folder): Capture / Selects / Trash / Output.
    case captureOneSessionRoot

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .dated: return "By date (yyyy/yyyy-MM-dd)"
        case .bySession: return "By session"
        case .captureOne: return "Capture One session"
        case .captureOneSessionRoot: return "Into a Capture One session"
        case .byRating: return "By rating"
        }
    }

    /// Relative directory for one capture. Capture One: picks → Selects,
    /// rejects → Trash, everything else → Capture; sidecars ride along.
    public func directory(for capture: CaptureItem, sessionName: String?, date: Date? = nil) -> String {
        let d = date ?? capture.capturedAt
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        let session = NamingTemplate.safe(sessionName ?? "Session")
        switch self {
        case .flat: return ""
        case .dated:
            f.dateFormat = "yyyy"; let y = f.string(from: d)
            f.dateFormat = "yyyy-MM-dd"; return "\(y)/\(f.string(from: d))"
        case .bySession: return session
        case .captureOne:
            let sub = capture.flag == .pick ? "Selects" : (capture.flag == .reject ? "Trash" : "Capture")
            return "\(session)/\(sub)"
        case .byRating: return capture.rating > 0 ? "\(capture.rating) star\(capture.rating == 1 ? "" : "s")" : "Unrated"
        case .captureOneSessionRoot: return capture.flag == .pick ? "Selects" : (capture.flag == .reject ? "Trash" : "Capture")
        }
    }

    /// Where the manifest goes: Capture One's Output folder, else the root.
    public func manifestDirectory(sessionName: String?) -> String {
        switch self {
        case .captureOne: return "\(NamingTemplate.safe(sessionName ?? "Session"))/Output"
        case .captureOneSessionRoot: return "Output"
        default: return ""
        }
    }

    /// Folders every layout creates up front so the tree is recognisable
    /// even when a bucket is empty (Capture One expects all four).
    public func scaffold(sessionName: String?) -> [String] {
        let session = NamingTemplate.safe(sessionName ?? "Session")
        switch self {
        case .captureOne: return ["Capture", "Selects", "Output", "Trash"].map { "\(session)/\($0)" }
        case .captureOneSessionRoot: return ["Capture", "Selects", "Output", "Trash"]
        case .bySession: return [session]
        default: return []
        }
    }
}

/// A machine-readable record of a session or export for other tools and
/// for the business platform: JSON for software, CSV for Photo Mechanic,
/// Excel and client sign-off sheets.
public struct SessionManifest: Codable, Sendable {
    public struct Row: Codable, Sendable {
        public var filename: String
        public var exportedAs: String?
        public var kind: String
        public var rating: Int
        public var flag: String
        public var label: String
        public var tags: [String]
        public var collections: [String]
        public var capturedAt: Date
        public var camera: String?
        public var exposure: String?
        public var width: Int
        public var height: Int
        public var bytes: Int
        public var sha256: String?
    }

    public var generator = "Tether"
    public var version = 1
    public var session: String
    public var sessionID: String
    public var camera: String?
    public var createdAt: Date
    public var exportedAt = Date()
    public var workflowTag: String?
    public var rows: [Row]

    public init(session: ShootSession, captures: [CaptureItem], tags: [String: [String]], collections: [String: [String]], exportedNames: [String: String] = [:]) {
        self.session = session.name
        self.sessionID = session.id
        self.camera = session.camera?.displayName
        self.createdAt = session.createdAt
        self.workflowTag = session.workflowTag
        self.rows = captures.map { c in
            Row(filename: c.filename, exportedAs: exportedNames[c.id], kind: c.kind.rawValue, rating: c.rating, flag: c.flag.rawValue,
                label: c.colorLabel.rawValue, tags: tags[c.id] ?? [], collections: collections[c.id] ?? [], capturedAt: c.capturedAt,
                camera: session.camera?.displayName, exposure: c.exposure?.line, width: c.width, height: c.height, bytes: c.bytes, sha256: nil)
        }
    }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    /// RFC 4180 CSV with a header row; lists are `;`-joined.
    public func csv() -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let f = ISO8601DateFormatter()
        var out = "filename,exported_as,kind,rating,flag,label,tags,collections,captured_at,camera,exposure,width,height,bytes\r\n"
        for r in rows {
            out += [q(r.filename), q(r.exportedAs ?? ""), r.kind, "\(r.rating)", r.flag, r.label, q(r.tags.joined(separator: ";")),
                    q(r.collections.joined(separator: ";")), f.string(from: r.capturedAt), q(r.camera ?? ""), q(r.exposure ?? ""),
                    "\(r.width)", "\(r.height)", "\(r.bytes)"].joined(separator: ",") + "\r\n"
        }
        return out
    }
}
