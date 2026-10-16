import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Async TCP socket for the FTP layer. Unlike `SocketChannel`, the reader
/// thread *owns* the descriptor: `close()` only shuts the socket down and the
/// thread closes the fd once its `recv` has returned. A descriptor is thus
/// never closed while a read on it may still start, which rules out the
/// fd-reuse race where a late reader steals bytes from a newly accepted
/// connection with the same number. Write-only sockets (`reading: false`,
/// used for LIST/RETR and uploads) have no reader and close immediately.
final class FTPSocket: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var pending: [Data] = []
        var waiter: CheckedContinuation<Data, Error>?
        var eof = false
        var closed = false
    }

    private let fd: Int32
    private let state = State()
    private let reading: Bool

    init(fd: Int32, reading: Bool = true) {
        self.fd = fd
        self.reading = reading
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        POSIXNet.setNoSigpipe(fd)
        if reading {
            let st = state
            let t = Thread { FTPSocket.readLoop(fd: fd, state: st) }
            t.name = "tether.ftp.read"
            t.start()
        }
    }

    private static func readLoop(fd: Int32, state: State) {
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0, errno == EINTR { continue }
            state.lock.lock()
            if n > 0 {
                let d = Data(buf[0 ..< Int(n)])
                if let w = state.waiter { state.waiter = nil; state.lock.unlock(); w.resume(returning: d); continue }
                state.pending.append(d)
                state.lock.unlock()
            } else {
                state.eof = true
                let w = state.waiter; state.waiter = nil
                state.lock.unlock()
                POSIXNet.closeFD(fd)
                w?.resume(throwing: PTPError.transportClosed)
                return
            }
        }
    }

    var localHost: String? { POSIXNet.localAddress(of: fd)?.host }
    var peerHost: String? { POSIXNet.peerAddress(of: fd)?.host }

    func send(_ data: Data) async throws {
        if isClosed { throw PTPError.transportClosed }
        try POSIXNet.sendAll(fd, data)
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            state.lock.lock()
            if !state.pending.isEmpty {
                let d = state.pending.removeFirst()
                state.lock.unlock()
                cont.resume(returning: d)
            } else if state.eof || state.closed || !reading {
                state.lock.unlock()
                cont.resume(throwing: PTPError.transportClosed)
            } else {
                state.waiter = cont
                state.lock.unlock()
            }
        }
    }

    var isClosed: Bool { state.lock.lock(); defer { state.lock.unlock() }; return state.closed }

    func close() {
        state.lock.lock()
        if state.closed { state.lock.unlock(); return }
        state.closed = true
        let w = state.waiter; state.waiter = nil
        state.lock.unlock()
        shutdown(fd, Int32(SHUT_RDWR))
        if !reading { POSIXNet.closeFD(fd) }
        w?.resume(throwing: PTPError.transportClosed)
    }

    deinit { close() }
}
