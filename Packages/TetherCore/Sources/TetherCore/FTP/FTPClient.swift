import Foundation

// SFTP requires linking libssh2; intentionally absent. `FTPSecurity` has no
// SFTP case on purpose so the UI cannot offer it.
public enum FTPSecurity: String, Codable, Hashable, Sendable, CaseIterable {
    case plain
    /// `AUTH TLS` on the normal control port (21).
    case explicitTLS
    /// TLS from the first byte, conventionally port 990.
    case implicitTLS
}

public struct FTPDestination: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String
    public var security: FTPSecurity
    public var passive: Bool
    public var remoteDirectory: String

    public init(host: String, port: UInt16 = 21, username: String = "anonymous", password: String = "",
                security: FTPSecurity = .plain, passive: Bool = true, remoteDirectory: String = "/") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.security = security
        self.passive = passive
        self.remoteDirectory = remoteDirectory
    }
}

public protocol FTPUploading: Sendable {
    /// Uploads `data` to `remotePath` (relative to the destination's
    /// `remoteDirectory` unless absolute), creating directories as needed and
    /// resuming when the server already holds a prefix of the file.
    func upload(_ data: Data, to remotePath: String, progress: (@Sendable (Int, Int) -> Void)?) async throws
    /// Connects, logs in and returns the banner plus FEAT summary.
    func test() async throws -> String
}

public enum FTPClientError: Error, CustomStringConvertible, Equatable {
    case unexpectedReply(code: Int, text: String)
    case connectionFailed(String)
    case tlsUnsupported
    case malformedReply(String)
    case directoryUnavailable(String)

    public var description: String {
        switch self {
        case .unexpectedReply(let code, let text): return "FTP server said \(code) \(text)"
        case .connectionFailed(let s): return "Could not connect to \(s)."
        case .tlsUnsupported: return "FTPS is not available with this client; use the system client."
        case .malformedReply(let s): return "Malformed FTP reply: \(s)"
        case .directoryUnavailable(let s): return "Could not enter or create \(s)."
        }
    }
}

public struct FTPReply: Equatable, Sendable {
    public var code: Int
    public var lines: [String]
    public var text: String { lines.joined(separator: "\n") }
    public var isPositive: Bool { (200 ..< 400).contains(code) }
    public var isPreliminary: Bool { (100 ..< 200).contains(code) }

    /// `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)`
    public static func parsePASV(_ text: String) -> (host: String, port: UInt16)? {
        guard let open = text.lastIndex(of: "("), let close = text[open...].firstIndex(of: ")") else {
            return parsePASVNumbers(text)
        }
        return parsePASVNumbers(String(text[text.index(after: open) ..< close]))
    }

    private static func parsePASVNumbers(_ s: String) -> (host: String, port: UInt16)? {
        let nums = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 6 else { return nil }
        let n = Array(nums.suffix(6))
        guard n.allSatisfy({ (0 ... 255).contains($0) }) else { return nil }
        return ("\(n[0]).\(n[1]).\(n[2]).\(n[3])", UInt16(n[4] << 8 | n[5]))
    }

    /// `229 Entering Extended Passive Mode (|||port|)`
    public static func parseEPSV(_ text: String) -> UInt16? {
        guard let open = text.lastIndex(of: "("), let close = text[open...].firstIndex(of: ")") else { return nil }
        let inner = text[text.index(after: open) ..< close]
        guard let delim = inner.first else { return nil }
        let parts = inner.split(separator: delim, omittingEmptySubsequences: false)
        guard parts.count >= 4, let port = UInt16(parts[3]) else { return nil }
        return port
    }
}

// MARK: - Wire abstraction (plain sockets here, NSStream+TLS on Apple)

protocol FTPWire: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
    /// Upgrades the live connection to TLS (explicit FTPS after AUTH TLS).
    func startTLS() async throws
    var localHost: String? { get }
}

protocol FTPWireFactory: Sendable {
    var supportsTLS: Bool { get }
    func open(host: String, port: UInt16, tls: Bool, timeout: TimeInterval) async throws -> FTPWire
}

final class SocketWire: FTPWire, @unchecked Sendable {
    private let socket: FTPSocket
    init(fd: Int32, reading: Bool = true) { socket = FTPSocket(fd: fd, reading: reading) }
    func send(_ data: Data) async throws { try await socket.send(data) }
    func receive() async throws -> Data { try await socket.receive() }
    func close() { socket.close() }
    func startTLS() async throws { throw FTPClientError.tlsUnsupported }
    var localHost: String? { socket.localHost }
}

struct SocketWireFactory: FTPWireFactory {
    var supportsTLS: Bool { false }
    func open(host: String, port: UInt16, tls: Bool, timeout: TimeInterval) async throws -> FTPWire {
        try await open(host: host, port: port, tls: tls, timeout: timeout, reading: true)
    }
    func open(host: String, port: UInt16, tls: Bool, timeout: TimeInterval, reading: Bool) async throws -> FTPWire {
        if tls { throw FTPClientError.tlsUnsupported }
        let fd = try await Task.detached(priority: .userInitiated) {
            try SocketConnector.blockingConnect(host: host, port: port, timeout: timeout)
        }.value
        return SocketWire(fd: fd, reading: reading)
    }
}

// MARK: - Protocol driver shared by every wire

final class FTPClientCore: @unchecked Sendable {
    let destination: FTPDestination
    let factory: FTPWireFactory
    let timeout: TimeInterval
    private let lock = NSLock()
    private var inbox = Data()
    private var control: FTPWire?
    private var protectData = false

    init(destination: FTPDestination, factory: FTPWireFactory, timeout: TimeInterval) {
        self.destination = destination
        self.factory = factory
        self.timeout = timeout
    }

    // MARK: Session

    func connectAndLogin() async throws -> FTPReply {
        if destination.security != .plain, !factory.supportsTLS { throw FTPClientError.tlsUnsupported }
        let implicit = destination.security == .implicitTLS
        let wire = try await factory.open(host: destination.host, port: destination.port, tls: implicit, timeout: timeout)
        lock.withLock { control = wire; inbox = Data(); protectData = implicit }
        let banner = try expect(try await readReply(), in: 200 ..< 300)
        if destination.security == .explicitTLS {
            _ = try await command("AUTH TLS", expecting: 200 ..< 300)
            try await wire.startTLS()
            _ = try await command("PBSZ 0", expecting: 200 ..< 300)
            _ = try await command("PROT P", expecting: 200 ..< 300)
            lock.withLock { protectData = true }
        }
        let u = try await command("USER \(destination.username)", expecting: 200 ..< 400)
        if u.code / 100 == 3 {
            _ = try await command("PASS \(destination.password)", expecting: 200 ..< 300)
        }
        _ = try await command("TYPE I", expecting: 200 ..< 300)
        return banner
    }

    /// Takes the control wire out of the core first so a later
    /// `connectAndLogin` on the same instance can never be hit by this QUIT.
    func quit() async {
        guard let wire = lock.withLock({ () -> FTPWire? in defer { control = nil; inbox = Data() }; return control }) else { return }
        try? await wire.send(Data("QUIT\r\n".utf8))
        _ = await withTimeout(seconds: 1) { try? await wire.receive() }
        wire.close()
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Runs `body` on a logged-in session and always QUITs afterwards.
    private func withSession<T>(_ body: (FTPReply) async throws -> T) async throws -> T {
        let banner = try await connectAndLogin()
        do {
            let result = try await body(banner)
            await quit()
            return result
        } catch {
            await quit()
            throw error
        }
    }

    func test() async throws -> String {
        try await withSession { banner in try await self.testBody(banner) }
    }

    private func testBody(_ banner: FTPReply) async throws -> String {
        let feat = try? await command("FEAT", expecting: 200 ..< 300)
        let syst = try? await command("SYST", expecting: 200 ..< 300)
        var parts = ["\(banner.code) \(banner.text)"]
        if let syst { parts.append(syst.text) }
        if let feat {
            let features = feat.lines.dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            if !features.isEmpty { parts.append("Features: " + features.joined(separator: ", ")) }
        }
        return parts.joined(separator: "\n")
    }

    func upload(_ data: Data, to remotePath: String, progress: (@Sendable (Int, Int) -> Void)?) async throws {
        try await withSession { _ in try await self.uploadBody(data, to: remotePath, progress: progress) }
    }

    private func uploadBody(_ data: Data, to remotePath: String, progress: (@Sendable (Int, Int) -> Void)?) async throws {
        let full = remotePath.hasPrefix("/") ? remotePath : joined(destination.remoteDirectory, remotePath)
        let dir = FTPPath.parent(of: full)
        let name = FTPPath.name(of: full)
        try await ensureDirectory(dir)

        var offset = 0
        if let size = try await remoteSize(name) {
            if size == data.count {
                progress?(data.count, data.count)
                return
            }
            if size > 0, size < data.count {
                let r = try await command("REST \(size)", expecting: 300 ..< 400)
                if r.code == 350 { offset = size }
            }
        }
        let dataWire = try await openDataConnection()
        let stor = try await command("STOR \(name)", expecting: 100 ..< 200)
        _ = stor
        let channel = try await dataWire()
        var sent = offset
        progress?(sent, data.count)
        do {
            var cursor = offset
            while cursor < data.count {
                let end = min(data.count, cursor + 256 * 1024)
                try await channel.send(data.subdata(in: cursor ..< end))
                cursor = end
                sent = cursor
                progress?(sent, data.count)
            }
        } catch {
            channel.close()
            throw error
        }
        channel.close()
        _ = try expect(try await readReply(), in: 200 ..< 300)
    }

    // MARK: Helpers

    private func joined(_ base: String, _ rel: String) -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        return (b.isEmpty ? "" : (b.hasPrefix("/") ? b : "/" + b)) + "/" + rel
    }

    private func ensureDirectory(_ dir: String) async throws {
        let comps = FTPPath.components(of: dir)
        _ = try await command("CWD /", expecting: 200 ..< 300)
        for c in comps {
            if let r = try? await command("CWD \(c)", expecting: 200 ..< 300), r.isPositive { continue }
            _ = try? await command("MKD \(c)", expecting: 200 ..< 300)
            guard (try? await command("CWD \(c)", expecting: 200 ..< 300)) != nil else {
                throw FTPClientError.directoryUnavailable(dir)
            }
        }
    }

    private func remoteSize(_ name: String) async throws -> Int? {
        guard let r = try? await command("SIZE \(name)", expecting: 200 ..< 300) else { return nil }
        return Int(r.lines.first?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    /// Prepares the data channel. Passive: parses EPSV/PASV and returns a
    /// closure that connects. Active: listens and returns a closure that accepts.
    private func openDataConnection() async throws -> () async throws -> FTPWire {
        let tls = lock.withLock { protectData }
        if destination.passive {
            var host = destination.host
            var port: UInt16?
            if let e = try? await command("EPSV", expecting: 200 ..< 300), let p = FTPReply.parseEPSV(e.text) {
                port = p
            } else {
                let p = try await command("PASV", expecting: 200 ..< 300)
                guard let parsed = FTPReply.parsePASV(p.text) else { throw FTPClientError.malformedReply(p.text) }
                port = parsed.port
                // Servers behind NAT often advertise a private/zero address; trust the control host then.
                if parsed.host != "0.0.0.0", IPAddressFilter.isUsable(parsed.host) { host = parsed.host }
            }
            guard let port else { throw FTPClientError.malformedReply("no passive port") }
            let factory = self.factory, timeout = self.timeout, h = host
            return {
                if let sockets = factory as? SocketWireFactory {
                    return try await sockets.open(host: h, port: port, tls: tls, timeout: timeout, reading: false)
                }
                return try await factory.open(host: h, port: port, tls: tls, timeout: timeout)
            }
        } else {
            let listener = try TCPListener(port: 0, backlog: 1)
            let local = lock.withLock { control?.localHost } ?? "127.0.0.1"
            if IPAddressFilter.isIPv4(local) {
                let h = local.replacingOccurrences(of: ".", with: ",")
                _ = try await command("PORT \(h),\(listener.port >> 8),\(listener.port & 0xFF)", expecting: 200 ..< 300)
            } else {
                _ = try await command("EPRT |2|\(local)|\(listener.port)|", expecting: 200 ..< 300)
            }
            let timeout = self.timeout
            return {
                defer { listener.close() }
                let accepted = try await Task.detached { try listener.accept(timeout: timeout) }.value
                guard let (fd, _) = accepted else { throw ChannelError.timeout }
                if tls { throw FTPClientError.tlsUnsupported }
                return SocketWire(fd: fd, reading: false)
            }
        }
    }

    func command(_ line: String, expecting range: Range<Int>) async throws -> FTPReply {
        guard let wire = lock.withLock({ control }) else { throw FTPClientError.connectionFailed(destination.host) }
        try await wire.send(Data((line + "\r\n").utf8))
        return try expect(try await readReply(), in: range)
    }

    private func expect(_ reply: FTPReply, in range: Range<Int>) throws -> FTPReply {
        guard range.contains(reply.code) else { throw FTPClientError.unexpectedReply(code: reply.code, text: reply.text) }
        return reply
    }

    func readReply() async throws -> FTPReply {
        var lines: [String] = []
        var code: Int?
        while true {
            let line = try await readLine()
            if code == nil {
                guard line.count >= 3, let c = Int(line.prefix(3)) else { throw FTPClientError.malformedReply(line) }
                code = c
                let rest = line.count > 3 ? String(line.dropFirst(4)) : ""
                lines.append(rest)
                if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " { return FTPReply(code: c, lines: lines) }
            } else {
                if line.count >= 4, Int(line.prefix(3)) == code, line[line.index(line.startIndex, offsetBy: 3)] == " " {
                    lines.append(String(line.dropFirst(4)))
                    return FTPReply(code: code!, lines: lines)
                }
                lines.append(line)
            }
        }
    }

    private func readLine() async throws -> String {
        guard let wire = lock.withLock({ control }) else { throw FTPClientError.connectionFailed(destination.host) }
        while true {
            if let range = inbox.firstRange(of: Data([0x0A])) {
                var lineData = inbox.subdata(in: inbox.startIndex ..< range.lowerBound)
                inbox.removeSubrange(inbox.startIndex ... range.lowerBound)
                if lineData.last == 0x0D { lineData.removeLast() }
                return String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
            }
            let chunk = try await withThrowingTaskGroup(of: Data.self) { group -> Data in
                group.addTask { try await wire.receive() }
                group.addTask { [timeout] in
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw ChannelError.timeout
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            inbox.append(chunk)
        }
    }
}

/// Plain-FTP client over BSD sockets (Linux and Apple). TLS variants throw
/// `FTPClientError.tlsUnsupported`; the factory picks a TLS-capable client.
public final class SocketFTPClient: FTPUploading, @unchecked Sendable {
    private let core: FTPClientCore
    public let destination: FTPDestination

    public init(destination: FTPDestination, timeout: TimeInterval = 15) {
        self.destination = destination
        self.core = FTPClientCore(destination: destination, factory: SocketWireFactory(), timeout: timeout)
    }

    public func upload(_ data: Data, to remotePath: String, progress: (@Sendable (Int, Int) -> Void)?) async throws {
        try await core.upload(data, to: remotePath, progress: progress)
    }

    public func test() async throws -> String { try await core.test() }
}

public enum FTPClientFactory {
    /// Apple: NSStream client (TLS-capable). Elsewhere: libcurl when linked,
    /// otherwise plain sockets (TLS destinations fail with `tlsUnsupported`).
    public static func make(_ dest: FTPDestination, timeout: TimeInterval = 15) -> FTPUploading {
        #if canImport(Darwin)
        return StreamFTPClient(destination: dest, timeout: timeout)
        #elseif canImport(CCurl)
        if dest.security != .plain { return CurlFTPClient(destination: dest, timeout: timeout) }
        return SocketFTPClient(destination: dest, timeout: timeout)
        #else
        return SocketFTPClient(destination: dest, timeout: timeout)
        #endif
    }
}
