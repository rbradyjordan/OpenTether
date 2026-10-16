import Foundation

#if canImport(Darwin)
/// Apple-only wire over paired NSStreams. Supports implicit FTPS (TLS from
/// the first byte) and explicit FTPS (upgrade after `AUTH TLS`) by setting
/// `kCFStreamPropertySocketSecurityLevel` on the live streams.
final class StreamWire: NSObject, FTPWire, StreamDelegate, @unchecked Sendable {
    private let input: InputStream
    private let output: OutputStream
    private let lock = NSLock()
    private var pending: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var closed = false
    private var runLoop: RunLoop?
    private let host: String

    init(input: InputStream, output: OutputStream, host: String, tls: Bool) {
        self.input = input
        self.output = output
        self.host = host
        super.init()
        if tls {
            _ = input.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
            _ = output.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        }
        let t = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = RunLoop.current
            self.input.delegate = self
            self.output.delegate = self
            self.input.schedule(in: .current, forMode: .default)
            self.output.schedule(in: .current, forMode: .default)
            self.input.open()
            self.output.open()
            while !self.isClosed { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25)) }
        }
        t.name = "tether.ftp.stream"
        t.start()
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func waitUntilOpen(timeout: TimeInterval) async throws {
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

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            lock.lock()
            if input.streamStatus == .open, output.streamStatus == .open, let w = openWaiter {
                openWaiter = nil; lock.unlock(); w.resume()
            } else { lock.unlock() }
        case .hasBytesAvailable:
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
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

    func send(_ data: Data) async throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            if isClosed { throw PTPError.transportClosed }
            if !output.hasSpaceAvailable { try await Task.sleep(nanoseconds: 2_000_000); continue }
            let n = bytes[offset...].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if n < 0 { throw output.streamError ?? ChannelError.writeFailed(0) }
            offset += n
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !pending.isEmpty { let d = pending.removeFirst(); lock.unlock(); cont.resume(returning: d) }
            else if closed { lock.unlock(); cont.resume(throwing: PTPError.transportClosed) }
            else { waiter = cont; lock.unlock() }
        }
    }

    /// Explicit FTPS: after `234 AUTH TLS` the same socket switches to TLS.
    /// CFStream starts the handshake when the security level is set on an
    /// open stream. // VERIFY on a real FTPS server (some need kCFStreamSSLSettings as well).
    func startTLS() async throws {
        let ok1 = input.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        let ok2 = output.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        guard ok1, ok2 else { throw FTPClientError.tlsUnsupported }
        let settings: [String: Any] = [kCFStreamSSLPeerName as String: host]
        _ = input.setProperty(settings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
        _ = output.setProperty(settings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
    }

    var localHost: String? {
        // CFStream exposes the native socket handle; read its local address.
        guard let handleData = input.property(forKey: Stream.PropertyKey(kCFStreamPropertySocketNativeHandle as String)) as? Data else { return nil }
        var fd: Int32 = -1
        _ = withUnsafeMutableBytes(of: &fd) { handleData.copyBytes(to: $0) }
        guard fd >= 0 else { return nil }
        return POSIXNet.localAddress(of: fd)?.host
    }

    func close() {
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

struct StreamWireFactory: FTPWireFactory {
    var supportsTLS: Bool { true }
    func open(host: String, port: UInt16, tls: Bool, timeout: TimeInterval) async throws -> FTPWire {
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: host, port: Int(port), inputStream: &input, outputStream: &output)
        guard let i = input, let o = output else { throw FTPClientError.connectionFailed("\(host):\(port)") }
        let wire = StreamWire(input: i, output: o, host: host, tls: tls)
        try await wire.waitUntilOpen(timeout: timeout)
        return wire
    }
}

/// Apple client: plain FTP, explicit FTPS (AUTH TLS + PBSZ 0 + PROT P) and
/// implicit FTPS (port 990). Same protocol driver as `SocketFTPClient`.
public final class StreamFTPClient: FTPUploading, @unchecked Sendable {
    private let core: FTPClientCore
    public let destination: FTPDestination

    public init(destination: FTPDestination, timeout: TimeInterval = 15) {
        self.destination = destination
        self.core = FTPClientCore(destination: destination, factory: StreamWireFactory(), timeout: timeout)
    }

    public func upload(_ data: Data, to remotePath: String, progress: (@Sendable (Int, Int) -> Void)?) async throws {
        try await core.upload(data, to: remotePath, progress: progress)
    }

    public func test() async throws -> String { try await core.test() }
}
#endif
