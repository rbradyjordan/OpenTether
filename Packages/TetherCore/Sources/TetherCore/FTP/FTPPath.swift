import Foundation

/// Virtual-path sandboxing for the on-device FTP server. Clients see a
/// "/"-rooted tree; every path is normalized lexically and any attempt to
/// climb above the root is rejected (nil → 550).
public enum FTPPath {
    /// Resolves `argument` against `cwd` (both virtual, "/"-rooted).
    public static func resolve(_ argument: String, cwd: String) -> String? {
        var stack: [String] = argument.hasPrefix("/") ? [] : components(of: cwd)
        for raw in argument.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(raw)
            if part == "." { continue }
            if part == ".." {
                if stack.isEmpty { return nil }
                stack.removeLast()
                continue
            }
            if part.contains("\0") || part.contains("\\") { return nil }
            stack.append(part)
        }
        return "/" + stack.joined(separator: "/")
    }

    public static func components(of virtual: String) -> [String] {
        virtual.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Parent of a virtual path ("/" for top-level entries).
    public static func parent(of virtual: String) -> String {
        var c = components(of: virtual)
        guard !c.isEmpty else { return "/" }
        c.removeLast()
        return "/" + c.joined(separator: "/")
    }

    public static func name(of virtual: String) -> String { components(of: virtual).last ?? "" }

    /// On-disk URL for a *resolved* virtual path.
    public static func fileURL(root: URL, virtual: String) -> URL {
        var url = root
        for c in components(of: virtual) { url.appendPathComponent(c) }
        return url
    }
}

/// `ls -l`-style lines for LIST, and the bare names for NLST.
public enum FTPListing {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var isDirectory: Bool
        public var size: Int
        public var modified: Date
        public init(name: String, isDirectory: Bool, size: Int, modified: Date) {
            self.name = name; self.isDirectory = isDirectory; self.size = size; self.modified = modified
        }
    }

    private static let recent: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM dd HH:mm"
        return f
    }()

    private static let old: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM dd  yyyy"
        return f
    }()

    private static let mdtm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    public static func line(for e: Entry, now: Date = Date()) -> String {
        let perms = e.isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
        let sixMonths: TimeInterval = 182 * 24 * 3600
        let stamp = abs(now.timeIntervalSince(e.modified)) < sixMonths ? recent.string(from: e.modified) : old.string(from: e.modified)
        let size = String(e.size)
        let padded = String(repeating: " ", count: max(0, 12 - size.count)) + size
        return "\(perms) 1 tether tether \(padded) \(stamp) \(e.name)"
    }

    /// `YYYYMMDDhhmmss` in UTC, as MDTM wants.
    public static func mdtmString(_ date: Date) -> String { mdtm.string(from: date) }

    public static func entries(in directory: URL) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mod = attrs[.modificationDate] as? Date ?? Date()
            return Entry(name: name, isDirectory: isDir, size: size, modified: mod)
        }
    }

    /// Parses one of our own lines back (used by tests and the client's SIZE fallback).
    public static func parse(line: String) -> (name: String, isDirectory: Bool, size: Int)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9, let first = parts.first else { return nil }
        guard let size = Int(parts[4]) else { return nil }
        let name = parts[8...].joined(separator: " ")
        return (name, first.hasPrefix("d"), size)
    }
}
