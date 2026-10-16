import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A duplex byte channel. The PTP/IP transport opens two: command and event.
public protocol PTPIPChannel: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// Next chunk of bytes; throws `PTPError.transportClosed` at EOF.
    func receive() async throws -> Data
    func close()
}

public protocol PTPIPConnector: Sendable {
    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> PTPIPChannel
}

public enum ChannelError: Error, Equatable, CustomStringConvertible {
    case resolveFailed(String)
    case connectFailed(String, Int32)
    case timeout
    case writeFailed(Int32)
    case closed

    public var description: String {
        switch self {
        case .resolveFailed(let h): return "Could not resolve \(h)."
        case .connectFailed(let h, let e): return "Could not connect to \(h) (errno \(e))."
        case .timeout: return "Connection timed out."
        case .writeFailed(let e): return "Write failed (errno \(e))."
        case .closed: return "Connection closed."
        }
    }
}

// MARK: - POSIX socket channel (Linux + Apple; used by tests and the FTP server)

/// Plain BSD-socket channel. A reader thread pumps bytes into a continuation
/// so callers get an async API without Network.framework.
public final class SocketChannel: PTPIPChannel, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var pending: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var eof = false
    private var readError: Error?

    public init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "tether.socket.read"
        t.start()
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            lock.lock()
            if n > 0 {
                let d = Data(buf[0 ..< Int(n)])
                if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: d); continue }
                pending.append(d)
                lock.unlock()
            } else {
                eof = true
                if n < 0, errno != EINTR { readError = ChannelError.closed }
                let w = waiter; waiter = nil
                lock.unlock()
                w?.resume(throwing: PTPError.transportClosed)
                return
            }
        }
    }

    public func send(_ data: Data) async throws {
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

    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !pending.isEmpty {
                let d = pending.removeFirst()
                lock.unlock()
                cont.resume(returning: d)
            } else if eof || closed {
                lock.unlock()
                cont.resume(throwing: PTPError.transportClosed)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }

    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        shutdown(fd, Int32(SHUT_RDWR))
        #if canImport(Glibc)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
    }

    deinit { close() }
}

public struct SocketConnector: PTPIPConnector {
    public init() {}

    public func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> PTPIPChannel {
        let fd = try await Task.detached(priority: .userInitiated) { () throws -> Int32 in
            try SocketConnector.blockingConnect(host: host, port: port, timeout: timeout)
        }.value
        return SocketChannel(fd: fd)
    }

    /// Resolves and connects with a timeout (non-blocking connect + poll).
    public static func blockingConnect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw ChannelError.resolveFailed(host)
        }
        defer { freeaddrinfo(res) }
        var lastErr: Int32 = 0
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = Foundation.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen)
                if rc == 0 || errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let pr = poll(&pfd, 1, Int32(timeout * 1000))
                    if pr > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                        if err == 0 {
                            _ = fcntl(fd, F_SETFL, flags)
                            return fd
                        }
                        lastErr = err
                    } else if pr == 0 {
                        close(fd)
                        throw ChannelError.timeout
                    }
                } else {
                    lastErr = errno
                }
                close(fd)
            }
            ai = a.pointee.ai_next
        }
        throw ChannelError.connectFailed(host, lastErr)
    }
}

// MARK: - NSStream channel (Apple only)

#if canImport(Darwin)
/// Paired NSInputStream/NSOutputStream from `Stream.getStreamsToHost`, as the
/// blueprint prescribes for the wireless path (no NWConnection). Runs the
/// streams on a dedicated run-loop thread.
public final class StreamChannel: NSObject, PTPIPChannel, StreamDelegate, @unchecked Sendable {
    private let input: InputStream
    private let output: OutputStream
    private let thread: Thread
    private let lock = NSLock()
    private var pending: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var closed = false
    private var runLoop: RunLoop?

    public init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
        self.thread = Thread()
        super.init()
        let t = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = RunLoop.current
            self.input.delegate = self
            self.output.delegate = self
            self.input.schedule(in: .current, forMode: .default)
            self.output.schedule(in: .current, forMode: .default)
            self.input.open()
            self.output.open()
            while !self.closed { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25)) }
        }
        t.name = "tether.stream"
        t.start()
    }

    public func waitUntilOpen(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    self.lock.lock()
                    if self.input.streamStatus == .open && self.output.streamStatus == .open { self.lock.unlock(); c.resume(); return }
                    self.openWaiter = c
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ChannelError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            lock.lock()
            if input.streamStatus == .open, output.streamStatus == .open, let w = openWaiter {
                openWaiter = nil; lock.unlock(); w.resume()
            } else { lock.unlock() }
        case .hasBytesAvailable:
            var buf = [UInt8](repeating: 0, count: 128 * 1024)
            while input.hasBytesAvailable {
                let n = input.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                deliver(Data(buf[0 ..< n]))
            }
        case .errorOccurred, .endEncountered:
            fail(aStream.streamError ?? ChannelError.closed)
        default: break
        }
    }

    private func deliver(_ d: Data) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: d); return }
        pending.append(d)
        lock.unlock()
    }

    private func fail(_ error: Error) {
        lock.lock()
        closed = true
        let w = waiter; waiter = nil
        let o = openWaiter; openWaiter = nil
        lock.unlock()
        w?.resume(throwing: PTPError.transportClosed)
        o?.resume(throwing: error)
    }

    public func send(_ data: Data) async throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            if closed { throw PTPError.transportClosed }
            if !output.hasSpaceAvailable { try await Task.sleep(nanoseconds: 2_000_000); continue }
            let n = bytes[offset...].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if n < 0 { throw output.streamError ?? ChannelError.writeFailed(0) }
            offset += n
        }
    }

    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !pending.isEmpty { let d = pending.removeFirst(); lock.unlock(); cont.resume(returning: d) }
            else if closed { lock.unlock(); cont.resume(throwing: PTPError.transportClosed) }
            else { waiter = cont; lock.unlock() }
        }
    }

    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(throwing: PTPError.transportClosed)
        runLoop?.perform { [input, output] in
            input.close(); output.close()
            input.remove(from: .current, forMode: .default)
            output.remove(from: .current, forMode: .default)
        }
    }
}

public struct StreamConnector: PTPIPConnector {
    public init() {}

    public func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> PTPIPChannel {
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: host, port: Int(port), inputStream: &input, outputStream: &output)
        guard let i = input, let o = output else { throw ChannelError.connectFailed(host, 0) }
        let ch = StreamChannel(input: i, output: o)
        try await ch.waitUntilOpen(timeout: timeout)
        return ch
    }
}

public typealias DefaultPTPIPConnector = StreamConnector
#else
public typealias DefaultPTPIPConnector = SocketConnector
#endif
