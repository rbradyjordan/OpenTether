import Foundation

/// SQLite persistence for sessions, captures, review state, export jobs,
/// FTP destinations, the looks cache and small settings. The store is the
/// recovery journal: every capture is written as it is announced and updated
/// as it downloads, so a relaunch mid-shoot knows exactly what it has.
public final class SessionStore: @unchecked Sendable {
    public let db: SQLiteDatabase

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    public static func inMemory() throws -> SessionStore { try SessionStore(path: ":memory:") }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL, ended_at REAL,
            status TEXT NOT NULL, json TEXT NOT NULL
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS captures (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL, filename TEXT NOT NULL, kind TEXT NOT NULL, pair_key TEXT NOT NULL,
            rating INTEGER NOT NULL DEFAULT 0, flag TEXT NOT NULL DEFAULT 'none', color TEXT NOT NULL DEFAULT 'none',
            state TEXT NOT NULL, received_at REAL NOT NULL, json TEXT NOT NULL
        )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS captures_session ON captures(session_id, sequence)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS export_jobs (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
            status TEXT NOT NULL, json TEXT NOT NULL
        )
        """)
        try db.execute("CREATE TABLE IF NOT EXISTS ftp_destinations (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS looks (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, family TEXT NOT NULL, version INTEGER NOT NULL,
            sha256 TEXT NOT NULL, cube BLOB, fetched_at REAL, json TEXT NOT NULL
        )
        """)
        try db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS known_cameras (
            id TEXT PRIMARY KEY, last_seen REAL NOT NULL, host TEXT, json TEXT NOT NULL
        )
        """)
        try migrateLibrary()
    }

    // MARK: Sessions

    public func save(_ s: ShootSession) throws {
        try db.execute("""
        INSERT INTO sessions (id, name, created_at, ended_at, status, json) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, ended_at=excluded.ended_at, status=excluded.status, json=excluded.json
        """, [.text(s.id), .text(s.name), .init(s.createdAt), .init(s.endedAt), .text(s.status.rawValue), .json(s)])
    }

    public func session(_ id: String) throws -> ShootSession? {
        try db.query("SELECT json FROM sessions WHERE id = ?", [.text(id)]).first?["json"]?.decoded(ShootSession.self)
    }

    public func sessions(limit: Int = 200) throws -> [ShootSession] {
        try db.query("SELECT json FROM sessions ORDER BY created_at DESC LIMIT ?", [.init(limit)])
            .compactMap { $0["json"]?.decoded(ShootSession.self) }
    }

    /// Sessions that were active when the app last stopped: offered as "Resume".
    public func interruptedSessions() throws -> [ShootSession] {
        try db.query("SELECT json FROM sessions WHERE status IN ('active','interrupted') ORDER BY created_at DESC")
            .compactMap { $0["json"]?.decoded(ShootSession.self) }
    }

    public func markInterruptedSessions() throws {
        let rows = try db.query("SELECT json FROM sessions WHERE status = 'active'")
        for r in rows {
            guard var s = r["json"]?.decoded(ShootSession.self) else { continue }
            s.status = .interrupted
            try save(s)
        }
    }

    public func deleteSession(_ id: String) throws {
        try db.execute("DELETE FROM sessions WHERE id = ?", [.text(id)])
    }

    // MARK: Captures

    public func save(_ c: CaptureItem) throws {
        let stateKey: String
        switch c.state {
        case .announced: stateKey = "announced"
        case .downloading: stateKey = "downloading"
        case .ready: stateKey = "ready"
        case .failed: stateKey = "failed"
        }
        try db.execute("""
        INSERT INTO captures (id, session_id, sequence, filename, kind, pair_key, rating, flag, color, state, received_at, json, camera_id, look_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET filename=excluded.filename, kind=excluded.kind, pair_key=excluded.pair_key,
            rating=excluded.rating, flag=excluded.flag, color=excluded.color, state=excluded.state, received_at=excluded.received_at,
            json=excluded.json, camera_id=excluded.camera_id, look_id=excluded.look_id
        """, [.text(c.id), .text(c.sessionID), .init(c.sequence), .text(c.filename), .text(c.kind.rawValue), .text(c.pairKey),
              .init(c.rating), .text(c.flag.rawValue), .text(c.colorLabel.rawValue), .text(stateKey), .init(c.receivedAt), .json(c),
              .init(c.cameraID), .init(c.lookID)])
    }

    public func captures(in sessionID: String) throws -> [CaptureItem] {
        try db.query("SELECT json FROM captures WHERE session_id = ? ORDER BY sequence ASC", [.text(sessionID)])
            .compactMap { $0["json"]?.decoded(CaptureItem.self) }
    }

    public func capture(_ id: String) throws -> CaptureItem? {
        try db.query("SELECT json FROM captures WHERE id = ?", [.text(id)]).first?["json"]?.decoded(CaptureItem.self)
    }

    public func nextSequence(in sessionID: String) throws -> Int {
        (try db.query("SELECT COALESCE(MAX(sequence), 0) AS m FROM captures WHERE session_id = ?", [.text(sessionID)]).first?["m"]?.int ?? 0) + 1
    }

    public func deleteCapture(_ id: String) throws {
        try db.execute("DELETE FROM captures WHERE id = ?", [.text(id)])
    }

    public struct SessionCounts: Equatable, Sendable {
        public var total = 0, ready = 0, picks = 0, rejects = 0, rated = 0, failed = 0
        public init() {}
    }

    public func counts(in sessionID: String) throws -> SessionCounts {
        var c = SessionCounts()
        for r in try db.query("SELECT state, flag, rating FROM captures WHERE session_id = ?", [.text(sessionID)]) {
            c.total += 1
            if r["state"]?.string == "ready" { c.ready += 1 }
            if r["state"]?.string == "failed" { c.failed += 1 }
            if r["flag"]?.string == "pick" { c.picks += 1 }
            if r["flag"]?.string == "reject" { c.rejects += 1 }
            if (r["rating"]?.int ?? 0) > 0 { c.rated += 1 }
        }
        return c
    }

    // MARK: Export jobs

    public func save(_ j: ExportJob) throws {
        try db.execute("""
        INSERT INTO export_jobs (id, session_id, created_at, updated_at, status, json) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at, status=excluded.status, json=excluded.json
        """, [.text(j.id), .text(j.sessionID), .init(j.createdAt), .init(Date()), .text(j.status.key), .json(j)])
    }

    public func exportJobs(sessionID: String? = nil) throws -> [ExportJob] {
        let rows = sessionID == nil
            ? try db.query("SELECT json FROM export_jobs ORDER BY created_at DESC")
            : try db.query("SELECT json FROM export_jobs WHERE session_id = ? ORDER BY created_at DESC", [.text(sessionID!)])
        return rows.compactMap { $0["json"]?.decoded(ExportJob.self) }
    }

    public func pendingExportJobs() throws -> [ExportJob] {
        try db.query("SELECT json FROM export_jobs WHERE status IN ('queued','running','paused') ORDER BY created_at ASC")
            .compactMap { $0["json"]?.decoded(ExportJob.self) }
    }

    // MARK: Looks cache

    public func saveLook(_ look: LookDescriptor, cube: Data?) throws {
        try db.execute("""
        INSERT INTO looks (id, name, family, version, sha256, cube, fetched_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, family=excluded.family, version=excluded.version, sha256=excluded.sha256,
            cube=COALESCE(excluded.cube, looks.cube), fetched_at=excluded.fetched_at, json=excluded.json
        """, [.text(look.id), .text(look.name), .text(look.family), .init(look.version), .text(look.sha256), .init(cube), .init(Date()), .json(look)])
    }

    public func looks() throws -> [LookDescriptor] {
        try db.query("SELECT json FROM looks ORDER BY family, name").compactMap { $0["json"]?.decoded(LookDescriptor.self) }
    }

    public func cube(for lookID: String) throws -> Data? {
        try db.query("SELECT cube FROM looks WHERE id = ?", [.text(lookID)]).first?["cube"]?.data
    }

    // MARK: FTP destinations

    public func save(_ d: StoredFTPDestination) throws {
        try db.execute("INSERT INTO ftp_destinations (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", [.text(d.id), .json(d)])
    }

    public func ftpDestinations() throws -> [StoredFTPDestination] {
        try db.query("SELECT json FROM ftp_destinations").compactMap { $0["json"]?.decoded(StoredFTPDestination.self) }
    }

    public func deleteFTPDestination(_ id: String) throws {
        try db.execute("DELETE FROM ftp_destinations WHERE id = ?", [.text(id)])
    }

    // MARK: Known cameras (for the "reconnect" shortcut)

    public func rememberCamera(_ c: CameraIdentity, host: String?) throws {
        try db.execute("""
        INSERT INTO known_cameras (id, last_seen, host, json) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen, host=COALESCE(excluded.host, known_cameras.host), json=excluded.json
        """, [.text(c.id), .init(Date()), .init(host), .json(c)])
    }

    public func knownCameras() throws -> [(CameraIdentity, host: String?, lastSeen: Date)] {
        try db.query("SELECT json, host, last_seen FROM known_cameras ORDER BY last_seen DESC").compactMap { r in
            guard let c = r["json"]?.decoded(CameraIdentity.self) else { return nil }
            return (c, r["host"]?.string, r["last_seen"]?.date ?? Date())
        }
    }

    // MARK: Settings

    public func setting(_ key: String) -> String? {
        try? db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?["value"]?.string
    }

    public func setSetting(_ key: String, _ value: String?) {
        if let value {
            try? db.execute("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
        } else {
            try? db.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }
}

/// An FTP upload target the user saved (password kept in Keychain on device;
/// here only its reference).
public struct StoredFTPDestination: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var security: String   // "plain" | "explicitTLS" | "implicitTLS"
    public var passive: Bool
    public var remoteDirectory: String
    public var passwordKeychainKey: String

    public init(id: String = UUID().uuidString, name: String, host: String, port: UInt16 = 21, username: String,
                security: String = "explicitTLS", passive: Bool = true, remoteDirectory: String = "/",
                passwordKeychainKey: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.security = security
        self.passive = passive
        self.remoteDirectory = remoteDirectory
        self.passwordKeychainKey = passwordKeychainKey ?? "ftp.\(id)"
    }
}
