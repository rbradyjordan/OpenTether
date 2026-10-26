import Foundation

/// The library: every capture across every session, with tags, collections
/// and export history. All queries are SQL over indexed columns so a
/// 20 000-frame library answers in milliseconds.
public extension SessionStore {
    // MARK: Schema

    func migrateLibrary() throws {
        try addColumnIfMissing(table: "captures", column: "camera_id", type: "TEXT")
        try addColumnIfMissing(table: "captures", column: "look_id", type: "TEXT")
        try db.execute("CREATE INDEX IF NOT EXISTS captures_rating ON captures(state, rating)")
        try db.execute("CREATE INDEX IF NOT EXISTS captures_flag ON captures(state, flag)")
        try db.execute("CREATE INDEX IF NOT EXISTS captures_received ON captures(received_at)")
        try db.execute("CREATE INDEX IF NOT EXISTS captures_camera ON captures(camera_id)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS capture_tags (
            capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
            tag TEXT NOT NULL, added_at REAL NOT NULL,
            PRIMARY KEY (capture_id, tag)
        )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS capture_tags_tag ON capture_tags(tag)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS collections (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0, builtin INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL, json TEXT NOT NULL
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS collection_items (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
            position INTEGER NOT NULL, added_at REAL NOT NULL,
            PRIMARY KEY (collection_id, capture_id)
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS capture_exports (
            capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
            destination TEXT NOT NULL, job_id TEXT NOT NULL, remote_id TEXT, exported_at REAL NOT NULL,
            PRIMARY KEY (capture_id, destination, job_id)
        )
        """)
        try db.execute("CREATE TABLE IF NOT EXISTS tag_history (tag TEXT PRIMARY KEY, uses INTEGER NOT NULL, last_used REAL NOT NULL)")
        for (i, c) in Collection.builtIns.enumerated() {
            var seeded = c
            seeded.sortOrder = i
            try db.execute("INSERT INTO collections (id, name, kind, pinned, sort_order, builtin, updated_at, json) VALUES (?, ?, ?, ?, ?, 1, ?, ?) ON CONFLICT(id) DO NOTHING",
                           [.text(c.id), .text(c.name), .text(c.kind.rawValue), .init(true), .init(i), .init(Date()), .json(seeded)])
        }
    }

    internal func addColumnIfMissing(table: String, column: String, type: String) throws {
        let cols = try db.query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string }
        if !cols.contains(column) { try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
    }

    // MARK: Queries

    /// Captures matching a filter, in order. `limit`/`offset` page large grids.
    func captures(matching filter: CaptureFilter, sort: CaptureSort = .captureTimeDescending, limit: Int? = nil, offset: Int = 0) throws -> [CaptureItem] {
        let (w, p) = filter.sql()
        var sql = "SELECT c.json FROM captures c WHERE \(w) ORDER BY \(sort.orderBy)"
        var params = p
        if let limit { sql += " LIMIT ? OFFSET ?"; params += [.init(limit), .init(offset)] }
        return try db.query(sql, params).compactMap { $0["json"]?.decoded(CaptureItem.self) }
    }

    func count(matching filter: CaptureFilter) throws -> Int {
        let (w, p) = filter.sql()
        return try db.query("SELECT COUNT(*) AS n FROM captures c WHERE \(w)", p).first?["n"]?.int ?? 0
    }

    /// IDs only, for selection math ("select all in view") without decoding JSON.
    func captureIDs(matching filter: CaptureFilter, sort: CaptureSort = .captureTimeDescending) throws -> [String] {
        let (w, p) = filter.sql()
        return try db.query("SELECT c.id FROM captures c WHERE \(w) ORDER BY \(sort.orderBy)", p).compactMap { $0["id"]?.string }
    }

    func captures(ids: [String]) throws -> [CaptureItem] {
        guard !ids.isEmpty else { return [] }
        var out = [CaptureItem]()
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0 ..< min($0 + 400, ids.count)]) }) {
            let q = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            out += try db.query("SELECT json FROM captures WHERE id IN (\(q))", chunk.map { .text($0) }).compactMap { $0["json"]?.decoded(CaptureItem.self) }
        }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return out.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    // MARK: Collections

    func saveCollection(_ c: Collection) throws {
        var c = c
        c.updatedAt = Date()
        try db.execute("""
        INSERT INTO collections (id, name, kind, pinned, sort_order, builtin, updated_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, pinned=excluded.pinned, sort_order=excluded.sort_order, updated_at=excluded.updated_at, json=excluded.json
        """, [.text(c.id), .text(c.name), .text(c.kind.rawValue), .init(c.isPinned), .init(c.sortOrder), .init(c.isBuiltIn), .init(c.updatedAt), .json(c)])
    }

    func collections() throws -> [Collection] {
        try db.query("SELECT json FROM collections ORDER BY builtin DESC, pinned DESC, sort_order ASC, name COLLATE NOCASE ASC")
            .compactMap { $0["json"]?.decoded(Collection.self) }
    }

    func collection(_ id: String) throws -> Collection? {
        try db.query("SELECT json FROM collections WHERE id = ?", [.text(id)]).first?["json"]?.decoded(Collection.self)
    }

    func deleteCollection(_ id: String) throws {
        guard let c = try collection(id), !c.isBuiltIn else { throw LibraryError.builtInCollection }
        try db.execute("DELETE FROM collections WHERE id = ?", [.text(id)])
    }

    func add(_ captureIDs: [String], to collectionID: String) throws {
        guard let c = try collection(collectionID), c.kind == .manual else { throw LibraryError.notManual }
        let next = (try db.query("SELECT COALESCE(MAX(position), -1) AS m FROM collection_items WHERE collection_id = ?", [.text(collectionID)]).first?["m"]?.int ?? -1) + 1
        try db.transaction {
            for (i, id) in captureIDs.enumerated() {
                try db.execute("INSERT INTO collection_items (collection_id, capture_id, position, added_at) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING",
                               [.text(collectionID), .text(id), .init(next + i), .init(Date())])
            }
            try db.execute("UPDATE collections SET updated_at = ? WHERE id = ?", [.init(Date()), .text(collectionID)])
        }
    }

    func remove(_ captureIDs: [String], from collectionID: String) throws {
        for id in captureIDs {
            try db.execute("DELETE FROM collection_items WHERE collection_id = ? AND capture_id = ?", [.text(collectionID), .text(id)])
        }
    }

    func reorder(_ captureIDs: [String], in collectionID: String) throws {
        try db.transaction {
            for (i, id) in captureIDs.enumerated() {
                try db.execute("UPDATE collection_items SET position = ? WHERE collection_id = ? AND capture_id = ?", [.init(i), .text(collectionID), .text(id)])
            }
        }
    }

    /// Contents of any collection: smart ones run their rule, manual ones
    /// keep their hand order (optionally narrowed by an extra filter).
    func captures(in collection: Collection, narrowedBy extra: CaptureFilter? = nil, sort: CaptureSort? = nil,
                  limit: Int? = nil, offset: Int = 0) throws -> [CaptureItem] {
        switch collection.kind {
        case .smart:
            var rule = collection.rule ?? CaptureFilter()
            if let extra { rule = rule.merged(with: extra) }
            return try captures(matching: rule, sort: sort ?? .captureTimeDescending, limit: limit, offset: offset)
        case .manual:
            let (w, p) = (extra ?? CaptureFilter(readyOnly: false)).sql()
            let order = sort.map { $0.orderBy } ?? "ci.position ASC"
            var sql = "SELECT c.json FROM collection_items ci JOIN captures c ON c.id = ci.capture_id WHERE ci.collection_id = ? AND \(w) ORDER BY \(order)"
            var params: [SQLiteDatabase.Value] = [.text(collection.id)] + p
            if let limit { sql += " LIMIT ? OFFSET ?"; params += [.init(limit), .init(offset)] }
            return try db.query(sql, params).compactMap { $0["json"]?.decoded(CaptureItem.self) }
        }
    }

    func count(in collection: Collection) throws -> Int {
        switch collection.kind {
        case .smart: return try count(matching: collection.rule ?? CaptureFilter())
        case .manual: return try db.query("SELECT COUNT(*) AS n FROM collection_items WHERE collection_id = ?", [.text(collection.id)]).first?["n"]?.int ?? 0
        }
    }

    func collectionIDs(containing captureID: String) throws -> [String] {
        try db.query("SELECT collection_id FROM collection_items WHERE capture_id = ?", [.text(captureID)]).compactMap { $0["collection_id"]?.string }
    }

    // MARK: Tags

    func tags(for captureID: String) throws -> [String] {
        try db.query("SELECT tag FROM capture_tags WHERE capture_id = ? ORDER BY tag", [.text(captureID)]).compactMap { $0["tag"]?.string }
    }

    func addTags(_ tags: [String], to captureIDs: [String]) throws {
        let clean = tags.map(Self.normalizeTag).filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        try db.transaction {
            for id in captureIDs {
                for t in clean {
                    try db.execute("INSERT INTO capture_tags (capture_id, tag, added_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING", [.text(id), .text(t), .init(Date())])
                }
            }
            for t in clean {
                try db.execute("INSERT INTO tag_history (tag, uses, last_used) VALUES (?, 1, ?) ON CONFLICT(tag) DO UPDATE SET uses = uses + 1, last_used = excluded.last_used", [.text(t), .init(Date())])
            }
        }
    }

    func removeTags(_ tags: [String], from captureIDs: [String]) throws {
        for id in captureIDs {
            for t in tags.map(Self.normalizeTag) {
                try db.execute("DELETE FROM capture_tags WHERE capture_id = ? AND tag = ?", [.text(id), .text(t)])
            }
        }
    }

    /// Tags ranked by use, most recent first on ties. Drives autocompletion.
    func tagSuggestions(prefix: String = "", limit: Int = 12) throws -> [String] {
        let p = Self.normalizeTag(prefix)
        return try db.query("SELECT tag FROM tag_history WHERE tag LIKE ? ORDER BY uses DESC, last_used DESC LIMIT ?", [.text(p + "%"), .init(limit)])
            .compactMap { $0["tag"]?.string }
    }

    static func normalizeTag(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "-")
    }

    // MARK: Exports

    func recordExport(captureID: String, destination: CaptureFilter.ExportDestinationKey, jobID: String, remoteID: String?) throws {
        try db.execute("INSERT INTO capture_exports (capture_id, destination, job_id, remote_id, exported_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
                       [.text(captureID), .text(destination.rawValue), .text(jobID), .init(remoteID), .init(Date())])
    }

    func exportHistory(captureID: String) throws -> [(destination: String, at: Date, remoteID: String?)] {
        try db.query("SELECT destination, exported_at, remote_id FROM capture_exports WHERE capture_id = ? ORDER BY exported_at DESC", [.text(captureID)]).map {
            ($0["destination"]?.string ?? "", $0["exported_at"]?.date ?? Date(), $0["remote_id"]?.string)
        }
    }

    /// Exported file names (lowercased, no folder) → capture ID, so a catalog
    /// that only knows the exported names ("AW26_001.CR3") can be matched back.
    public func exportedFilenames() throws -> [String: String] {
        var out: [String: String] = [:]
        for row in try db.query("SELECT capture_id, remote_id FROM capture_exports WHERE remote_id IS NOT NULL ORDER BY exported_at") {
            guard let id = row["capture_id"]?.string, let remote = row["remote_id"]?.string else { continue }
            out[(remote as NSString).lastPathComponent.lowercased()] = id
        }
        return out
    }

    // MARK: Library stats

    struct LibraryStats: Equatable, Sendable {
        public var captures = 0, sessions = 0, picks = 0, rated = 0, bytes = 0, cameras = 0
    }

    func libraryStats() throws -> LibraryStats {
        var s = LibraryStats()
        let r = try db.query("""
        SELECT COUNT(*) AS n, SUM(CASE WHEN flag = 'pick' THEN 1 ELSE 0 END) AS picks, SUM(CASE WHEN rating > 0 THEN 1 ELSE 0 END) AS rated,
               COUNT(DISTINCT session_id) AS sessions, COUNT(DISTINCT camera_id) AS cameras FROM captures WHERE state = 'ready'
        """).first
        s.captures = r?["n"]?.int ?? 0
        s.picks = r?["picks"]?.int ?? 0
        s.rated = r?["rated"]?.int ?? 0
        s.sessions = r?["sessions"]?.int ?? 0
        s.cameras = r?["cameras"]?.int ?? 0
        return s
    }
}

public enum LibraryError: Error, Equatable, CustomStringConvertible {
    case builtInCollection, notManual, nothingSelected
    public var description: String {
        switch self {
        case .builtInCollection: return "Built-in collections can't be changed."
        case .notManual: return "Only your own collections take hand-picked photos; this one is a smart collection."
        case .nothingSelected: return "Nothing is selected."
        }
    }
}

public extension CaptureFilter {
    /// Intersection of two filters (both must hold).
    func merged(with other: CaptureFilter) -> CaptureFilter {
        var out = self
        out.minRating = [minRating, other.minRating].compactMap { $0 }.max()
        out.maxRating = [maxRating, other.maxRating].compactMap { $0 }.min()
        func inter<T: Hashable>(_ a: Set<T>?, _ b: Set<T>?) -> Set<T>? { if let a, let b { return a.intersection(b) }; return a ?? b }
        out.flags = inter(flags, other.flags)
        out.colors = inter(colors, other.colors)
        out.kinds = inter(kinds, other.kinds)
        out.sessionIDs = inter(sessionIDs, other.sessionIDs)
        out.cameraIDs = inter(cameraIDs, other.cameraIDs)
        out.tagsAll = (tagsAll ?? []).union(other.tagsAll ?? []).isEmpty ? nil : (tagsAll ?? []).union(other.tagsAll ?? [])
        out.tagsAny = inter(tagsAny, other.tagsAny)
        out.dateRange = other.dateRange ?? dateRange
        out.text = [text, other.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty
        out.readyOnly = readyOnly || other.readyOnly
        out.hasLook = other.hasLook ?? hasLook
        out.exportedTo = other.exportedTo ?? exportedTo
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
