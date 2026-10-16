import Foundation

// Reading Lightroom Classic and Capture One catalogs back, read-only.
//
// Writing into a live catalog is not done (and cannot be done safely from a
// phone): they are undocumented SQLite databases the desktop app keeps open
// and migrates between versions. What does work is the reverse direction:
// open a copy of the catalog read-only and bring the culling decisions made
// on the desktop (stars, pick/reject, colour labels, keywords) back onto the
// captures here, matched by file name.

/// One photo's culling state as a catalog records it.
public struct CatalogEntry: Equatable, Sendable {
    public var filename: String
    public var folder: String?
    /// 0...5; nil when the catalog has no rating column for it.
    public var rating: Int?
    public var flag: CaptureFlag?
    public var label: ColorLabel?
    public var keywords: [String]

    public init(filename: String, folder: String? = nil, rating: Int? = nil, flag: CaptureFlag? = nil,
                label: ColorLabel? = nil, keywords: [String] = []) {
        self.filename = filename
        self.folder = folder
        self.rating = rating
        self.flag = flag
        self.label = label
        self.keywords = keywords
    }
}

public enum CatalogKind: String, Sendable {
    case lightroom
    case captureOne

    public var displayName: String {
        switch self {
        case .lightroom: return "Lightroom Classic catalog"
        case .captureOne: return "Capture One catalog"
        }
    }

    /// `.lrcat` → Lightroom; `.cocatalogdb` / `.cosessiondb` (or a
    /// `.cocatalog` package holding one) → Capture One.
    public static func detect(_ url: URL) -> CatalogKind? {
        switch url.pathExtension.lowercased() {
        case "lrcat": return .lightroom
        case "cocatalogdb", "cosessiondb", "cocatalog": return .captureOne
        default: return nil
        }
    }

    /// The SQLite file inside a `.cocatalog` package (or the URL itself).
    public static func databaseFile(in url: URL) -> URL {
        guard url.pathExtension.lowercased() == "cocatalog" else { return url }
        let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return inside.first { $0.pathExtension.lowercased() == "cocatalogdb" } ?? url
    }

    /// Lightroom leaves `<name>.lrcat-lock` (and a WAL) beside a catalog it
    /// has open: what we read is then the last state Lightroom saved.
    public static func isOpenElsewhere(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path + "-lock") || fm.fileExists(atPath: url.path + "-wal")
    }
}

public enum CatalogError: Error, CustomStringConvertible {
    case unsupported(String)
    case unrecognisedSchema(String)

    public var description: String {
        switch self {
        case .unsupported(let name): return "\(name) is not a Lightroom or Capture One catalog."
        case .unrecognisedSchema(let what): return "This \(what) uses a layout Open Tether does not recognise yet."
        }
    }
}

public enum CatalogReader {
    /// Read every photo's culling state from a catalog file (read-only).
    public static func entries(at url: URL) throws -> [CatalogEntry] {
        guard let kind = CatalogKind.detect(url) else { throw CatalogError.unsupported(url.lastPathComponent) }
        var snapshotDir: URL?
        defer { if let snapshotDir { try? FileManager.default.removeItem(at: snapshotDir) } }
        // Scoped so the snapshot connection closes before its folder is removed.
        return try {
            let db = try SQLiteDatabase.snapshot(of: CatalogKind.databaseFile(in: url).path)
            snapshotDir = URL(fileURLWithPath: db.path).deletingLastPathComponent()
            switch kind {
            case .lightroom: return try lightroom(db)
            case .captureOne: return try captureOne(db)
            }
        }()
    }

    // MARK: Lightroom Classic (.lrcat)

    /// Adobe_images (rating, pick, colorLabels) → AgLibraryFile (baseName,
    /// extension) → AgLibraryFolder / AgLibraryRootFolder; keywords through
    /// AgLibraryKeywordImage.
    static func lightroom(_ db: SQLiteDatabase) throws -> [CatalogEntry] {
        let tables = try tableNames(db)
        guard tables.contains("adobe_images"), tables.contains("aglibraryfile") else {
            throw CatalogError.unrecognisedSchema("Lightroom catalog")
        }
        let hasFolders = tables.contains("aglibraryfolder") && tables.contains("aglibraryrootfolder")
        let sql = """
        SELECT i.id_local AS id, i.rating AS rating, i.pick AS pick, i.colorLabels AS label,
               f.baseName AS base, f.extension AS ext\(hasFolders ? ", r.absolutePath AS root, d.pathFromRoot AS sub" : "")
        FROM Adobe_images i JOIN AgLibraryFile f ON f.id_local = i.rootFile
        \(hasFolders ? "LEFT JOIN AgLibraryFolder d ON d.id_local = f.folder LEFT JOIN AgLibraryRootFolder r ON r.id_local = d.rootFolder" : "")
        """
        var keywords: [Int64: [String]] = [:]
        if tables.contains("aglibrarykeywordimage"), tables.contains("aglibrarykeyword") {
            for row in try db.query("SELECT ki.image AS image, k.name AS name FROM AgLibraryKeywordImage ki JOIN AgLibraryKeyword k ON k.id_local = ki.tag") {
                if let image = row["image"]?.int64, let name = row["name"]?.string, !name.isEmpty { keywords[image, default: []].append(name) }
            }
        }
        return try db.query(sql).compactMap { row in
            guard let base = row["base"]?.string, !base.isEmpty else { return nil }
            let ext = row["ext"]?.string ?? ""
            let pick = row["pick"]?.double ?? 0
            let folder = [row["root"]?.string, row["sub"]?.string].compactMap { $0 }.joined()
            return CatalogEntry(filename: ext.isEmpty ? base : "\(base).\(ext)",
                                folder: folder.isEmpty ? nil : folder,
                                rating: Int((row["rating"]?.double ?? 0).rounded()),
                                flag: pick > 0 ? .pick : (pick < 0 ? .reject : CaptureFlag.none),
                                label: colorLabel(named: row["label"]?.string),
                                keywords: row["id"]?.int64.flatMap { keywords[$0] } ?? [])
        }
    }

    // MARK: Capture One (.cocatalogdb / .cosessiondb)

    /// Capture One's schema is Core Data style (Z-prefixed tables) and not
    /// documented, so the reader looks for it rather than assuming: a table
    /// with an image file name, and a rating (and colour tag) either on that
    /// table or on a variant table pointing at it. Unverified against every
    /// Capture One version; treat as experimental.
    static func captureOne(_ db: SQLiteDatabase) throws -> [CatalogEntry] {
        var columns: [String: [String]] = [:]
        for table in try tableNames(db, original: true) {
            columns[table] = try db.query("PRAGMA table_info(\"\(table)\")").compactMap { $0["name"]?.string }
        }
        func find(_ cols: [String], _ patterns: [String]) -> String? {
            for p in patterns { if let c = cols.first(where: { $0.uppercased().contains(p) }) { return c } }
            return nil
        }
        // The image table: has a file-name column.
        let nameColumns = ["FILENAME", "DISPLAYNAME", "IMAGENAME"]
        guard let (imageTable, nameColumn) = columns.compactMap({ t, cols in find(cols, nameColumns).map { (t, $0) } })
            .sorted(by: { a, b in (a.0.uppercased() == "ZIMAGE" ? 0 : 1, a.0) < (b.0.uppercased() == "ZIMAGE" ? 0 : 1, b.0) })
            .first else { throw CatalogError.unrecognisedSchema("Capture One catalog") }

        let ratingPatterns = ["RATING"]
        let colorPatterns = ["COLORTAG", "COLORLABEL", "COLOURTAG"]
        // Rating on the image table itself, or on a table referencing it.
        var source: (table: String, rating: String, color: String?, join: String?)?
        if let r = find(columns[imageTable] ?? [], ratingPatterns) {
            source = (imageTable, r, find(columns[imageTable] ?? [], colorPatterns), nil)
        } else {
            let fkName = imageTable.uppercased()  // e.g. ZIMAGE column in ZVARIANT
            for (table, cols) in columns where table != imageTable {
                if let r = find(cols, ratingPatterns), let fk = cols.first(where: { $0.uppercased() == fkName }) {
                    source = (table, r, find(cols, colorPatterns), fk)
                    break
                }
            }
        }
        guard let source else { throw CatalogError.unrecognisedSchema("Capture One catalog") }
        let sql: String
        if let join = source.join {
            sql = "SELECT i.\"\(nameColumn)\" AS name, v.\"\(source.rating)\" AS rating\(source.color.map { ", v.\"\($0)\" AS color" } ?? "") FROM \"\(source.table)\" v JOIN \"\(imageTable)\" i ON i.Z_PK = v.\"\(join)\""
        } else {
            sql = "SELECT \"\(nameColumn)\" AS name, \"\(source.rating)\" AS rating\(source.color.map { ", \"\($0)\" AS color" } ?? "") FROM \"\(imageTable)\""
        }
        var seen = Set<String>()
        return try db.query(sql).compactMap { row in
            guard let name = row["name"]?.string, !name.isEmpty else { return nil }
            let rating = Int(row["rating"]?.double ?? 0)
            let entry = CatalogEntry(filename: (name as NSString).lastPathComponent,
                                     rating: max(0, min(5, rating)),
                                     flag: rating < 0 ? .reject : nil,
                                     label: captureOneColor(row["color"]?.int))
            // Several variants of one image: the first (primary) wins.
            return seen.insert(entry.filename.lowercased()).inserted ? entry : nil
        }
    }

    // MARK: Helpers

    private static func tableNames(_ db: SQLiteDatabase, original: Bool = false) throws -> [String] {
        try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { row in
            row["name"]?.string.map { original ? $0 : $0.lowercased() }
        }
    }

    static func colorLabel(named name: String?) -> ColorLabel? {
        switch name?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "", nil: return ColorLabel.none
        default: return nil   // custom label sets: leave ours alone
        }
    }

    /// Capture One colour tags: 0 none, 1 red, 2 orange, 3 yellow, 4 green,
    /// 5 blue, 6 pink, 7 purple. Orange and pink have no equivalent here.
    static func captureOneColor(_ value: Int?) -> ColorLabel? {
        switch value {
        case 0?: return ColorLabel.none
        case 1?: return .red
        case 3?: return .yellow
        case 4?: return .green
        case 5?: return .blue
        case 7?: return .purple
        default: return nil
        }
    }
}

/// What a catalog would change on one capture here.
public struct CatalogChange: Equatable, Sendable {
    public var captureID: String
    public var filename: String
    public var rating: Int?
    public var flag: CaptureFlag?
    public var label: ColorLabel?
    public var newKeywords: [String]

    public var isEmpty: Bool { rating == nil && flag == nil && label == nil && newKeywords.isEmpty }
}

public enum CatalogMatcher {
    /// Match catalog entries to captures by file name: the camera's own name
    /// first, then any name the frame was exported under. Only differences
    /// are returned. RAW+JPEG twins follow each other (as everywhere else).
    public static func changes(entries: [CatalogEntry], captures: [CaptureItem], exportedNames: [String: String],
                               tags: (String) -> [String] = { _ in [] }) -> (changes: [CatalogChange], unmatched: [String]) {
        let byName = Dictionary(captures.map { ($0.filename.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, $0) })
        var out: [String: CatalogChange] = [:]
        var unmatched: [String] = []
        for entry in entries {
            let key = entry.filename.lowercased()
            guard let capture = byName[key] ?? exportedNames[key].flatMap({ byID[$0] }) else {
                unmatched.append(entry.filename)
                continue
            }
            var change = out[capture.id] ?? CatalogChange(captureID: capture.id, filename: capture.filename, newKeywords: [])
            if let r = entry.rating, r != capture.rating { change.rating = r }
            if let f = entry.flag, f != capture.flag { change.flag = f }
            if let l = entry.label, l != capture.colorLabel { change.label = l }
            let existing = Set(tags(capture.id).map { $0.lowercased() })
            let fresh = entry.keywords.filter { !existing.contains($0.lowercased()) && !change.newKeywords.contains($0) }
            change.newKeywords += fresh
            out[capture.id] = change
        }
        let ordered = captures.compactMap { out[$0.id] }.filter { !$0.isEmpty }
        return (ordered, unmatched)
    }
}
