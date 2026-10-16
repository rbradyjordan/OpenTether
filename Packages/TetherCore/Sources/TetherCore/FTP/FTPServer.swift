import Foundation

public struct FTPServerConfiguration: Codable, Sendable {
    /// 0 = ephemeral. Default 2121 (unprivileged; cameras let you type any port).
    public var port: UInt16
    public var username: String
    public var password: String
    public var allowAnonymous: Bool
    public var rootDirectory: URL
    public var passivePortRange: ClosedRange<UInt16>
    /// Seconds without a command (or data) before a client is dropped.
    public var idleTimeout: TimeInterval

    public init(port: UInt16 = 2121, username: String = "tether", password: String = "tether",
                allowAnonymous: Bool = false, rootDirectory: URL,
                passivePortRange: ClosedRange<UInt16> = 40000 ... 40100, idleTimeout: TimeInterval = 300) {
        self.port = port
        self.username = username
        self.password = password
        self.allowAnonymous = allowAnonymous
        self.rootDirectory = rootDirectory
        self.passivePortRange = passivePortRange
        self.idleTimeout = idleTimeout
    }
}

public enum FTPServerEvent: Sendable {
    case started(port: UInt16, addresses: [String])
    case clientConnected(String)
    case clientDisconnected(String)
    case loginFailed(String)
    case transferStarted(path: String, from: String)
    case transferProgress(path: String, bytes: Int)
    case fileReceived(url: URL, bytes: Int, from: String, duration: TimeInterval)
    case rebound(addresses: [String])
    case error(String)
    case stopped
}

/// On-device FTP server that cameras push to. One accept thread; each
/// connection runs as its own task over a `SocketChannel`. PostgreSQL-style
/// rule from the rest of the app applies: nothing here is durable, files
/// land under `rootDirectory` and the app indexes them from `fileReceived`.
public final class FTPServer: @unchecked Sendable {
    public let configuration: FTPServerConfiguration
    /// How often idle clients are checked (tests lower it).
    public var heartbeatInterval: TimeInterval = 5

    private let lock = NSLock()
    private let broadcaster = ValueBroadcaster<FTPServerEvent>()
    private var listener: TCPListener?
    private var acceptThread: Thread?
    private var heartbeat: Task<Void, Never>?
    private var sessions: [ObjectIdentifier: FTPSession] = [:]
    private var passiveCursor: UInt16
    private var generation = 0

    public init(configuration: FTPServerConfiguration) {
        self.configuration = configuration
        self.passiveCursor = configuration.passivePortRange.lowerBound
    }

    public var events: AsyncStream<FTPServerEvent> { broadcaster.stream(replayLatest: false) }
    public private(set) var boundPort: UInt16?
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil }
    public var connectedClients: Int { lock.lock(); defer { lock.unlock() }; return sessions.count }
    public var advertisedAddresses: [String] { NetworkInterfaces.localIPv4Addresses() }

    public func start() throws {
        lock.lock()
        if listener != nil { lock.unlock(); return }
        lock.unlock()
        try FileManager.default.createDirectory(at: configuration.rootDirectory, withIntermediateDirectories: true)
        let l = try TCPListener(port: configuration.port, backlog: 8)
        boundPort = l.port
        installListener(l)
        let hb = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))
                self.dropIdleClients()
            }
        }
        lock.lock(); heartbeat = hb; lock.unlock()
        emit(.started(port: l.port, addresses: advertisedAddresses))
    }

    public func stop() {
        lock.lock()
        let l = listener; listener = nil
        let hb = heartbeat; heartbeat = nil
        let ss = Array(sessions.values); sessions.removeAll()
        acceptThread = nil
        lock.unlock()
        guard l != nil else { return }
        hb?.cancel()
        l?.close()
        ss.forEach { $0.close() }
        emit(.stopped)
    }

    /// Re-opens the listener on the same port after an IP change so PASV
    /// advertises the new address. Live sessions are untouched.
    public func rebind() {
        lock.lock()
        guard let old = listener, let port = boundPort else { lock.unlock(); return }
        listener = nil
        lock.unlock()
        old.close()
        do {
            let l = try TCPListener(port: port, backlog: 8)
            installListener(l)
            emit(.rebound(addresses: advertisedAddresses))
        } catch {
            // Port still in TIME_WAIT for a moment: retry once shortly after.
            Thread.sleep(forTimeInterval: 0.2)
            do {
                let l = try TCPListener(port: port, backlog: 8)
                installListener(l)
                emit(.rebound(addresses: advertisedAddresses))
            } catch {
                emit(.error("Rebind on port \(port) failed: \(error)"))
            }
        }
    }

    private func installListener(_ l: TCPListener) {
        lock.lock()
        listener = l
        generation += 1
        let gen = generation
        lock.unlock()
        let t = Thread { [weak self] in self?.acceptLoop(l, generation: gen) }
        t.name = "tether.ftp.accept"
        lock.lock(); acceptThread = t; lock.unlock()
        t.start()
    }

    private func acceptLoop(_ l: TCPListener, generation: Int) {
        while true {
            do {
                guard let (fd, peer) = try l.accept(timeout: 1) else { continue }
                let session = FTPSession(fd: fd, peer: peer, server: self)
                lock.lock(); sessions[ObjectIdentifier(session)] = session; lock.unlock()
                emit(.clientConnected(peer))
                Task { [weak self] in
                    await session.run()
                    self?.sessionEnded(session)
                }
            } catch {
                return
            }
        }
    }

    private func sessionEnded(_ s: FTPSession) {
        lock.lock()
        let known = sessions.removeValue(forKey: ObjectIdentifier(s)) != nil
        lock.unlock()
        if known { emit(.clientDisconnected(s.peer)) }
    }

    private func dropIdleClients() {
        lock.lock(); let ss = Array(sessions.values); lock.unlock()
        let cutoff = Date().addingTimeInterval(-configuration.idleTimeout)
        for s in ss where s.lastActivity < cutoff && !s.isTransferring {
            emit(.error("Dropping idle client \(s.peer)"))
            s.close()
        }
    }

    // MARK: Session support

    func emit(_ event: FTPServerEvent) { broadcaster.send(event) }

    /// Binds the next free passive port (rotating through the range);
    /// falls back to an ephemeral port when the range is exhausted.
    func makePassiveListener() throws -> TCPListener {
        let range = configuration.passivePortRange
        let count = Int(range.upperBound) - Int(range.lowerBound) + 1
        for _ in 0 ..< count {
            lock.lock()
            let port = passiveCursor
            passiveCursor = passiveCursor >= range.upperBound ? range.lowerBound : passiveCursor + 1
            lock.unlock()
            if let l = try? TCPListener(port: port, backlog: 1) { return l }
        }
        return try TCPListener(port: 0, backlog: 1)
    }
}
