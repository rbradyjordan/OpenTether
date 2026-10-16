import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Small, platform-neutral BSD-socket helpers shared by discovery (UDP
/// multicast/broadcast, Fuji dial-back listener) and the FTP server/client.
/// Everything here is synchronous; callers run it on their own threads or in
/// detached tasks.
enum POSIXNet {
    static var streamType: Int32 {
        #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    static var datagramType: Int32 {
        #if canImport(Glibc)
        return Int32(SOCK_DGRAM.rawValue)
        #else
        return SOCK_DGRAM
        #endif
    }

    static func closeFD(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }

    static func setReuseAddress(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNoSigpipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// IPv4 socket address for a dotted-quad host (or "0.0.0.0").
    static func inet4(_ host: String, port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let rc = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard rc == 1 else { return nil }
        return addr
    }

    /// Numeric host + port from a generic sockaddr (AF_INET / AF_INET6).
    static func describe(_ sa: UnsafePointer<sockaddr>) -> (host: String, port: UInt16)? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                var a = p.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { return nil }
                return (String(cString: buf), UInt16(bigEndian: p.pointee.sin_port))
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var a = p.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return nil }
                return (String(cString: buf), UInt16(bigEndian: p.pointee.sin6_port))
            }
        default:
            return nil
        }
    }

    static func localAddress(of fd: Int32) -> (host: String, port: UInt16)? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { return nil }
        return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { describe($0) } }
    }

    static func peerAddress(of fd: Int32) -> (host: String, port: UInt16)? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        guard rc == 0 else { return nil }
        return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { describe($0) } }
    }

    /// Waits for readability. Returns >0 ready, 0 timeout, <0 error.
    static func waitReadable(_ fd: Int32, timeoutMillis: Int32) -> Int32 {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, timeoutMillis)
    }

    static func sendAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { p -> Int in
                #if canImport(Glibc)
                return Glibc.send(fd, p.baseAddress, p.count, Int32(MSG_NOSIGNAL))
                #else
                return Darwin.send(fd, p.baseAddress, p.count, 0)
                #endif
            }
            if n <= 0 {
                if errno == EINTR { continue }
                throw ChannelError.writeFailed(errno)
            }
            offset += n
        }
    }
}

// MARK: - TCP listener

/// A bound, listening IPv4 TCP socket. `accept` polls in short slices so a
/// concurrent `close()` is noticed within ~250 ms on every platform.
public final class TCPListener: @unchecked Sendable {
    public let fd: Int32
    public let port: UInt16
    public let address: String
    private let lock = NSLock()
    private var closed = false

    /// Binds `address:port` (port 0 = ephemeral) and listens.
    public init(address: String = "0.0.0.0", port: UInt16, backlog: Int32 = 16) throws {
        let fd = socket(AF_INET, POSIXNet.streamType, 0)
        guard fd >= 0 else { throw ChannelError.connectFailed("socket", errno) }
        POSIXNet.setReuseAddress(fd)
        guard var addr = POSIXNet.inet4(address, port: port) else {
            POSIXNet.closeFD(fd)
            throw ChannelError.resolveFailed(address)
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, backlog) == 0 else {
            let e = errno
            POSIXNet.closeFD(fd)
            throw ChannelError.connectFailed("bind \(address):\(port)", e)
        }
        self.fd = fd
        self.address = address
        self.port = POSIXNet.localAddress(of: fd)?.port ?? port
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// Accepts one connection. `nil` on timeout; throws `ChannelError.closed`
    /// once the listener is closed.
    public func accept(timeout: TimeInterval) throws -> (fd: Int32, peer: String)? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isClosed { throw ChannelError.closed }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            let slice = Int32(min(remaining, 0.25) * 1000) + 1
            let pr = POSIXNet.waitReadable(fd, timeoutMillis: slice)
            if pr < 0 {
                if errno == EINTR { continue }
                throw ChannelError.closed
            }
            if pr == 0 { continue }
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let cfd = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.accept(fd, $0, &len) }
            }
            if cfd < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw ChannelError.closed
            }
            POSIXNet.setNoSigpipe(cfd)
            let peer = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { POSIXNet.describe($0)?.host }
            } ?? "?"
            return (cfd, peer)
        }
    }

    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        shutdown(fd, Int32(SHUT_RDWR))
        POSIXNet.closeFD(fd)
    }

    deinit { close() }
}

// MARK: - UDP socket

/// IPv4 UDP socket for SSDP (multicast) and Fuji (broadcast) discovery.
final class UDPSocket: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var closed = false

    init(bindPort: UInt16, broadcast: Bool = false) throws {
        let fd = socket(AF_INET, POSIXNet.datagramType, 0)
        guard fd >= 0 else { throw ChannelError.connectFailed("socket", errno) }
        POSIXNet.setReuseAddress(fd)
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        if broadcast {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = POSIXNet.inet4("0.0.0.0", port: bindPort)!
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            POSIXNet.closeFD(fd)
            throw ChannelError.connectFailed("bind udp :\(bindPort)", e)
        }
        self.fd = fd
        self.port = POSIXNet.localAddress(of: fd)?.port ?? bindPort
    }

    func joinMulticast(group: String) throws {
        var mreq = ip_mreq()
        guard group.withCString({ inet_pton(AF_INET, $0, &mreq.imr_multiaddr) }) == 1 else {
            throw ChannelError.resolveFailed(group)
        }
        mreq.imr_interface.s_addr = 0 // INADDR_ANY
        let rc = setsockopt(fd, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        guard rc == 0 else { throw ChannelError.connectFailed("join \(group)", errno) }
        var ttl: UInt8 = 2
        setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
    }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        guard var addr = POSIXNet.inet4(host, port: port) else { throw ChannelError.resolveFailed(host) }
        let n = data.withUnsafeBytes { p -> Int in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, p.baseAddress, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if n < 0 { throw ChannelError.writeFailed(errno) }
    }

    /// `nil` on timeout; throws once closed.
    func receive(timeout: TimeInterval) throws -> (data: Data, host: String, port: UInt16)? {
        if isClosed { throw ChannelError.closed }
        let pr = POSIXNet.waitReadable(fd, timeoutMillis: Int32(max(1, timeout * 1000)))
        if pr == 0 { return nil }
        if pr < 0 { if errno == EINTR { return nil }; throw ChannelError.closed }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = buf.withUnsafeMutableBytes { b in
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) }
            }
        }
        if n < 0 { if errno == EINTR { return nil }; throw ChannelError.closed }
        let from = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { POSIXNet.describe($0) } }
        return (Data(buf[0 ..< Int(n)]), from?.host ?? "?", from?.port ?? 0)
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        shutdown(fd, Int32(SHUT_RDWR))
        POSIXNet.closeFD(fd)
    }

    deinit { close() }
}

// MARK: - Multi-consumer async stream

/// Fan-out for `AsyncStream`: every call to `stream()` gets its own stream
/// that receives all later values (and, optionally, the latest one first).
final class ValueBroadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private(set) var latest: Value?

    init(initial: Value? = nil) { latest = initial }

    func stream(replayLatest: Bool = true) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let replay = replayLatest ? latest : nil
            lock.unlock()
            if let replay { continuation.yield(replay) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func send(_ value: Value) {
        lock.lock()
        latest = value
        let targets = Array(continuations.values)
        lock.unlock()
        for c in targets { c.yield(value) }
    }

    func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in targets { c.finish() }
    }
}
