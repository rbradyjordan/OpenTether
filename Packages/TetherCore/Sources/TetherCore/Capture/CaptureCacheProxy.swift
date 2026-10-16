import Foundation

/// Owns the bytes of every capture: writes originals under
/// `<storageRoot>/<session>/originals/`, proxies under `proxies/`, thumbnails
/// under `thumbs/`, and keeps a small in-memory LRU of recently requested
/// files so the filmstrip and loupe never hit disk twice in a row.
///
/// All paths handed out are *relative* to the storage root and validated on
/// every read and write (no `..`, no absolute paths).
public final class CaptureCacheProxy: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable { case invalidPath(String), notFound(String) }

    public let storageRoot: URL
    private let lock = NSLock()
    private var lru: [String: Data] = [:]
    private var order: [String] = []
    private let memoryBudget: Int
    private var memoryUsed = 0

    public init(storageRoot: URL, memoryBudget: Int = 96 << 20) {
        self.storageRoot = storageRoot
        self.memoryBudget = memoryBudget
        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    // MARK: Paths

    public static func validate(_ relative: String) throws -> String {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }),
              !relative.contains("\0") else {
            throw Error.invalidPath(relative)
        }
        return relative
    }

    public func url(for relative: String) throws -> URL {
        storageRoot.appendingPathComponent(try Self.validate(relative))
    }

    public func originalPath(session: ShootSession, filename: String) -> String {
        "\(session.directoryName)/originals/\(Self.safeFilename(filename))"
    }
    public func proxyPath(session: ShootSession, filename: String) -> String {
        "\(session.directoryName)/proxies/\((Self.safeFilename(filename) as NSString).deletingPathExtension).jpg"
    }
    public func thumbnailPath(session: ShootSession, filename: String) -> String {
        "\(session.directoryName)/thumbs/\((Self.safeFilename(filename) as NSString).deletingPathExtension).jpg"
    }

    public static func safeFilename(_ name: String) -> String {
        var s = (name as NSString).lastPathComponent
        s = s.replacingOccurrences(of: "..", with: "_")
        if s.isEmpty || s == "." { s = "capture" }
        return s
    }

    // MARK: Writes

    /// Writes atomically; a name collision gets a numeric suffix so bursts
    /// from a reset camera counter never overwrite.
    @discardableResult
    public func store(_ data: Data, at relative: String) throws -> String {
        var path = try Self.validate(relative)
        var url = try self.url(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let ext = (path as NSString).pathExtension
            let base = (path as NSString).deletingPathExtension
            path = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            url = try self.url(for: path)
            n += 1
        }
        try data.write(to: url, options: .atomic)
        remember(path, data)
        return path
    }

    /// Streamed write for large originals: appends chunks to a `.part` file,
    /// then renames.
    public final class Writer {
        private let handle: FileHandle
        private let partURL: URL
        private let finalURL: URL
        public private(set) var bytes = 0
        private var finished = false

        fileprivate init(partURL: URL, finalURL: URL) throws {
            self.partURL = partURL
            self.finalURL = finalURL
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: partURL)
        }

        public func append(_ chunk: Data) throws {
            try handle.write(contentsOf: chunk)
            bytes += chunk.count
        }

        public func finish() throws {
            guard !finished else { return }
            finished = true
            try handle.close()
            if FileManager.default.fileExists(atPath: finalURL.path) { try FileManager.default.removeItem(at: finalURL) }
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        }

        public func abort() {
            finished = true
            try? handle.close()
            try? FileManager.default.removeItem(at: partURL)
        }
    }

    public func writer(at relative: String) throws -> Writer {
        let path = try Self.validate(relative)
        let url = try self.url(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try Writer(partURL: url.appendingPathExtension("part"), finalURL: url)
    }

    // MARK: Reads

    public func load(_ relative: String) throws -> Data {
        let path = try Self.validate(relative)
        lock.lock()
        if let d = lru[path] {
            touch(path)
            lock.unlock()
            return d
        }
        lock.unlock()
        let url = try self.url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Error.notFound(path) }
        let d = try Data(contentsOf: url)
        remember(path, d)
        return d
    }

    public func exists(_ relative: String) -> Bool {
        guard let url = try? url(for: relative) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func size(_ relative: String) -> Int? {
        guard let url = try? url(for: relative),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.size] as? Int
    }

    public func remove(_ relative: String) {
        guard let url = try? url(for: relative) else { return }
        try? FileManager.default.removeItem(at: url)
        lock.lock(); evict(relative); lock.unlock()
    }

    public func removeSession(_ session: ShootSession) {
        try? FileManager.default.removeItem(at: storageRoot.appendingPathComponent(session.directoryName))
        lock.lock()
        for k in lru.keys where k.hasPrefix(session.directoryName + "/") { evict(k) }
        lock.unlock()
    }

    public func sessionBytes(_ session: ShootSession) -> Int {
        let dir = storageRoot.appendingPathComponent(session.directoryName)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let u as URL in e {
            let values = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }

    // MARK: LRU

    private func remember(_ path: String, _ data: Data) {
        guard data.count <= memoryBudget / 4 else { return }
        lock.lock(); defer { lock.unlock() }
        evict(path)
        lru[path] = data
        order.append(path)
        memoryUsed += data.count
        while memoryUsed > memoryBudget, let oldest = order.first { evict(oldest) }
    }

    private func touch(_ path: String) {
        if let i = order.firstIndex(of: path) { order.remove(at: i); order.append(path) }
    }

    private func evict(_ path: String) {
        if let d = lru.removeValue(forKey: path) {
            memoryUsed -= d.count
            order.removeAll { $0 == path }
        }
    }

    public var cachedBytes: Int { lock.lock(); defer { lock.unlock() }; return memoryUsed }
}
