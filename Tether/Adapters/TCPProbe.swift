import Darwin
import Foundation

/// Non-blocking TCP connect with a timeout, for the wireless diagnostic
/// ("does the camera answer on 15740 / 80?"). POSIX so no Network framework.
enum TCPProbe {
    static func reachable(host: String, port: UInt16, timeout: TimeInterval = 2) async -> Bool {
        await Task.detached(priority: .utility) { connectBlocking(host: host, port: port, timeout: timeout) }.value
    }

    private static func connectBlocking(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                defer { close(fd) }
                let flags = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                if rc == 0 { return true }
                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&pfd, 1, Int32(timeout * 1000))
                    if ready > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 { return true }
                    }
                }
            }
            info = ai.pointee.ai_next
        }
        return false
    }
}
