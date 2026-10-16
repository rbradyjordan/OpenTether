import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Minimal, safe SQLite wrapper: prepared statements, typed binds, rows as
/// dictionaries. Serialised through one lock; SQLite itself is opened in
/// WAL mode with a busy timeout.
public final class SQLiteDatabase: @unchecked Sendable {
    public enum Error: Swift.Error, CustomStringConvertible {
        case open(String), prepare(String, String), step(String), bind(Int)
        public var description: String {
            switch self {
            case .open(let m): return "SQLite open failed: \(m)"
            case .prepare(let sql, let m): return "SQLite prepare failed: \(m) in \(sql)"
            case .step(let m): return "SQLite step failed: \(m)"
            case .bind(let i): return "SQLite bind failed at \(i)"
            }
        }
    }

    public enum Value: Equatable, Sendable {
        case null, integer(Int64), real(Double), text(String), blob(Data)

        public var int: Int? { if case .integer(let v) = self { return Int(v) }; return nil }
        public var int64: Int64? { if case .integer(let v) = self { return v }; return nil }
        public var double: Double? {
            switch self { case .real(let d): return d; case .integer(let i): return Double(i); default: return nil }
        }
        public var string: String? { if case .text(let s) = self { return s }; return nil }
        public var data: Data? { if case .blob(let d) = self { return d }; return nil }
        public var bool: Bool { (int ?? 0) != 0 }
        public var date: Date? { double.map { Date(timeIntervalSince1970: $0) } }
    }

    public typealias Row = [String: Value]

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw Error.open(msg)
        }
        db = h
        sqlite3_busy_timeout(h, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA synchronous=NORMAL")
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    public func execute(_ sql: String, _ params: [Value] = []) throws {
        _ = try query(sql, params)
    }

    @discardableResult
    public func query(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw Error.open("closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw Error.prepare(sql, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .null: rc = sqlite3_bind_null(s, idx)
            case .integer(let v): rc = sqlite3_bind_int64(s, idx, v)
            case .real(let v): rc = sqlite3_bind_double(s, idx, v)
            case .text(let v): rc = sqlite3_bind_text(s, idx, v, -1, Self.transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(s, idx, buf.baseAddress, Int32(buf.count), Self.transient)
                }
            }
            guard rc == SQLITE_OK else { throw Error.bind(i) }
        }
        var rows: [Row] = []
        let columnCount = Int(sqlite3_column_count(s))
        var names: [String] = []
        for c in 0 ..< columnCount { names.append(String(cString: sqlite3_column_name(s, Int32(c)))) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Error.step(String(cString: sqlite3_errmsg(db))) }
            var row: Row = [:]
            for c in 0 ..< columnCount {
                let ci = Int32(c)
                switch sqlite3_column_type(s, ci) {
                case SQLITE_INTEGER: row[names[c]] = .integer(sqlite3_column_int64(s, ci))
                case SQLITE_FLOAT: row[names[c]] = .real(sqlite3_column_double(s, ci))
                case SQLITE_TEXT: row[names[c]] = .text(String(cString: sqlite3_column_text(s, ci)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(s, ci))
                    row[names[c]] = .blob(n > 0 ? Data(bytes: sqlite3_column_blob(s, ci), count: n) : Data())
                default: row[names[c]] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try execute("COMMIT")
            return r
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return db.map { sqlite3_last_insert_rowid($0) } ?? 0
    }

    public var changes: Int {
        lock.lock(); defer { lock.unlock() }
        return db.map { Int(sqlite3_changes($0)) } ?? 0
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

public extension SQLiteDatabase.Value {
    init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    init(_ i: Int?) { self = i.map { .integer(Int64($0)) } ?? .null }
    init(_ d: Double?) { self = d.map { .real($0) } ?? .null }
    init(_ b: Bool) { self = .integer(b ? 1 : 0) }
    init(_ date: Date?) { self = date.map { .real($0.timeIntervalSince1970) } ?? .null }
    init(_ data: Data?) { self = data.map { .blob($0) } ?? .null }
    static func json<T: Encodable>(_ value: T) -> SQLiteDatabase.Value {
        (try? JSONEncoder().encode(value)).map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null
    }
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let s = string, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
}
