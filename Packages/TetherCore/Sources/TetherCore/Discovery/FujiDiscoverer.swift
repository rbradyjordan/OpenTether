import Foundation

/// Fujifilm "PC AutoSave"/wireless-tether discovery. The phone broadcasts a
/// DISCOVERY datagram; a camera on the same network answers by opening a TCP
/// connection *to the phone* and sending a text block that names itself.
public enum FujiConstants {
    /// UDP port the camera listens on for DISCOVERY. // VERIFY against a real X-series body (PCSS/1.0).
    public static let discoveryPort: UInt16 = 51562
    /// TCP port the camera dials back to on the phone. // VERIFY (PC AutoSave registration port).
    public static let dialBackPort: UInt16 = 51560
    public static let service = "PCSS/1.0"
    public static let clientName = "Tether"
    /// How long we wait for the dial-back text after the camera connects.
    public static let dialBackReadTimeout: TimeInterval = 5
}

/// Pure builders/parsers for the Fuji wire text.
public enum FujiDiscoveryMessage {
    public static func datagram(broadcast: String, name: String = FujiConstants.clientName,
                                mx: Int = 5, port: UInt16 = FujiConstants.discoveryPort) -> Data {
        let text = "DISCOVERY * HTTP/1.1\r\n" +
            "HOST: \(broadcast):\(port)\r\n" +
            "MX: \(mx)\r\n" +
            "SERVICE: \(FujiConstants.service)\r\n" +
            "DSCNAME: \(name)\r\n" +
            "\r\n"
        return Data(text.utf8)
    }

    /// Camera's dial-back block. Lenient: first non-empty line is the start
    /// line, then `Key: value` pairs (keys lower-cased), stops at a blank line.
    public struct DialBack: Equatable, Sendable {
        public var startLine: String
        public var headers: [String: String]

        public subscript(_ key: String) -> String? { headers[key.lowercased()] }
        /// DSCNAME, falling back to IMPORT/NAME/MODEL-style headers.
        public var cameraName: String? {
            for key in ["dscname", "name", "model", "import", "friendlyname", "camera"] {
                if let v = headers[key], !v.isEmpty { return v }
            }
            return nil
        }
        public var isNotify: Bool { startLine.uppercased().hasPrefix("NOTIFY") }
    }

    public static func parseDialBack(_ text: String) -> DialBack? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return nil }
        var headers: [String: String] = [:]
        var start = lines[firstIndex]
        var body = Array(lines[(firstIndex + 1)...])
        // Some firmware omits the start line: then the first line is already a header.
        if start.contains(":"), !start.uppercased().hasPrefix("NOTIFY"), !start.uppercased().hasPrefix("HTTP"), !start.contains(" * ") {
            body.insert(start, at: 0)
            start = ""
        }
        for line in body {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        guard !start.isEmpty || !headers.isEmpty else { return nil }
        return DialBack(startLine: start, headers: headers)
    }
}

public final class FujiDiscoverer: CameraDiscovering, @unchecked Sendable {
    public var broadcastInterval: TimeInterval = 5
    /// Nil = `NetworkInterfaces.broadcastAddresses()` at send time.
    public var broadcastAddresses: [String]?
    public var broadcastEnabled = true

    private let state = DiscoveryState()
    private let preferredPort: UInt16
    private let lock = NSLock()
    private var listener: TCPListener?
    private var udp: UDPSocket?
    private var acceptThread: Thread?
    private var broadcastTask: Task<Void, Never>?
    private var running = false

    public init(listenPort: UInt16 = FujiConstants.dialBackPort) { preferredPort = listenPort }

    public var cameras: AsyncStream<[DiscoveredCamera]> { state.stream }
    public var lastError: String? { state.lastError }
    public var current: [DiscoveredCamera] { state.snapshot }
    /// Port the dial-back listener actually bound (nil when stopped).
    public var listeningPort: UInt16? { lock.lock(); defer { lock.unlock() }; return listener?.port }

    public func start() async throws {
        let already = lock.withLock { () -> Bool in
            if running { return true }
            running = true
            return false
        }
        if already { return }
        let l: TCPListener
        do { l = try TCPListener(port: preferredPort) } catch {
            state.fail("Fuji port \(preferredPort) busy; using an ephemeral port (cameras expect \(FujiConstants.dialBackPort)).")
            l = try TCPListener(port: 0)
        }
        let t = Thread { [weak self] in self?.acceptLoop(l) }
        t.name = "tether.fuji.accept"
        lock.withLock { listener = l; acceptThread = t }
        t.start()
        guard broadcastEnabled else { return }
        let u = try UDPSocket(bindPort: 0, broadcast: true)
        lock.withLock { udp = u }
        let task = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.sendBroadcast()
                try? await Task.sleep(nanoseconds: UInt64(self.broadcastInterval * 1_000_000_000))
            }
        }
        lock.withLock { broadcastTask = task }
    }

    public func stop() async {
        let (l, u, t) = lock.withLock { () -> (TCPListener?, UDPSocket?, Task<Void, Never>?) in
            running = false
            defer { listener = nil; udp = nil; broadcastTask = nil; acceptThread = nil }
            return (listener, udp, broadcastTask)
        }
        t?.cancel()
        l?.close(); u?.close()
    }

    public func sendBroadcast() {
        lock.lock(); let u = udp; lock.unlock()
        guard let u else { return }
        let targets = broadcastAddresses ?? NetworkInterfaces.broadcastAddresses()
        for b in targets {
            do { try u.send(FujiDiscoveryMessage.datagram(broadcast: b), to: b, port: FujiConstants.discoveryPort) }
            catch { state.fail("Fuji broadcast to \(b) failed: \(error)") }
        }
    }

    private func acceptLoop(_ l: TCPListener) {
        while true {
            do {
                guard let (fd, peer) = try l.accept(timeout: 1) else { continue }
                let ch = SocketChannel(fd: fd)
                Task { [weak self] in await self?.handleDialBack(ch, peer: peer) }
            } catch { return }
        }
    }

    private func handleDialBack(_ ch: SocketChannel, peer: String) async {
        defer { ch.close() }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(FujiConstants.dialBackReadTimeout)
        while Date() < deadline, buffer.count < 64 * 1024 {
            let chunk: Data? = await withTaskGroup(of: Data?.self) { group in
                group.addTask { try? await ch.receive() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.05, deadline.timeIntervalSinceNow) * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let chunk else { break }
            buffer.append(chunk)
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") || text.contains("\n\n") { break }
        }
        guard !buffer.isEmpty else { return }
        let text = String(data: buffer, encoding: .utf8) ?? String(decoding: buffer, as: UTF8.self)
        ingest(text, from: peer)
        // Acknowledge so the camera settles; it then exposes PTP/IP on 15740. // VERIFY exact reply the camera expects
        try? await ch.send(Data("HTTP/1.1 200 OK\r\nSERVICE: \(FujiConstants.service)\r\nDSCNAME: \(FujiConstants.clientName)\r\n\r\n".utf8))
    }

    /// Pure-ish: records a dial-back text from `peer` as a camera.
    public func ingest(_ text: String, from peer: String) {
        guard let dial = FujiDiscoveryMessage.parseDialBack(text) else { return }
        var details = dial.headers
        details["startLine"] = dial.startLine
        let name = dial.cameraName ?? "Fujifilm camera"
        state.upsert(DiscoveredCamera(id: peer, name: name, vendor: .fujifilm, host: peer, port: PTPIPPacket.standardPort,
                                      method: .fujiUDP, transport: .ptpip, lastSeen: Date(), details: details))
    }
}
