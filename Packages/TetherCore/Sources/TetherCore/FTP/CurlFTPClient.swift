import Foundation

#if canImport(CCurl)
import CCurl

/// libcurl-backed uploader for FTP / explicit FTPS / implicit FTPS on hosts
/// where `CCurl` is linked (macOS/Linux via `.systemLibrary(name: "CCurl",
/// pkgConfig: "libcurl")`; iOS would need a prebuilt libcurl xcframework).
///
/// libcurl's `curl_easy_setopt` is variadic and not callable from Swift, so
/// the `CCurl` shim must export these non-variadic wrappers:
///   long  tether_curl_setopt_long(CURL *, CURLoption, long);
///   long  tether_curl_setopt_string(CURL *, CURLoption, const char *);
///   long  tether_curl_setopt_pointer(CURL *, CURLoption, void *);
///   long  tether_curl_setopt_readfn(CURL *, CURLoption, curl_read_callback);
///   long  tether_curl_setopt_xferfn(CURL *, CURLoption, curl_xferinfo_callback);
/// (each a one-line `return curl_easy_setopt(h, opt, v);`).
public final class CurlFTPClient: FTPUploading, @unchecked Sendable {
    public let destination: FTPDestination
    private let timeout: TimeInterval

    public init(destination: FTPDestination, timeout: TimeInterval = 15) {
        self.destination = destination
        self.timeout = timeout
    }

    private final class UploadState {
        var data: Data
        var cursor = 0
        var progress: (@Sendable (Int, Int) -> Void)?
        init(data: Data, progress: (@Sendable (Int, Int) -> Void)?) { self.data = data; self.progress = progress }
    }

    private func baseURL(path: String) -> String {
        let scheme = destination.security == .implicitTLS ? "ftps" : "ftp"
        let dir = destination.remoteDirectory.hasPrefix("/") ? destination.remoteDirectory : "/" + destination.remoteDirectory
        let full = path.hasPrefix("/") ? path : (dir.hasSuffix("/") ? dir : dir + "/") + path
        let encoded = full.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? full
        return "\(scheme)://\(destination.host):\(destination.port)\(encoded)"
    }

    private func configure(_ h: UnsafeMutableRawPointer, url: String) {
        _ = tether_curl_setopt_string(h, CURLOPT_URL, url)
        _ = tether_curl_setopt_string(h, CURLOPT_USERNAME, destination.username)
        _ = tether_curl_setopt_string(h, CURLOPT_PASSWORD, destination.password)
        _ = tether_curl_setopt_long(h, CURLOPT_CONNECTTIMEOUT, Int(timeout))
        _ = tether_curl_setopt_long(h, CURLOPT_NOSIGNAL, 1)
        _ = tether_curl_setopt_long(h, CURLOPT_FTP_CREATE_MISSING_DIRS, 2) // CURLFTP_CREATE_DIR_RETRY
        if destination.security == .explicitTLS {
            _ = tether_curl_setopt_long(h, CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue))
        }
        if !destination.passive {
            _ = tether_curl_setopt_string(h, CURLOPT_FTPPORT, "-")
        }
    }

    public func test() async throws -> String {
        try await Task.detached(priority: .userInitiated) { [self] in
            guard let h = curl_easy_init() else { throw FTPClientError.connectionFailed(destination.host) }
            defer { curl_easy_cleanup(h) }
            configure(h, url: baseURL(path: "/"))
            _ = tether_curl_setopt_long(h, CURLOPT_NOBODY, 1)
            _ = tether_curl_setopt_long(h, CURLOPT_DIRLISTONLY, 1)
            let rc = curl_easy_perform(h)
            guard rc == CURLE_OK else { throw FTPClientError.connectionFailed(String(cString: curl_easy_strerror(rc))) }
            return "Connected to \(destination.host):\(destination.port) (\(destination.security.rawValue)) via libcurl"
        }.value
    }

    public func upload(_ data: Data, to remotePath: String, progress: (@Sendable (Int, Int) -> Void)?) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            guard let h = curl_easy_init() else { throw FTPClientError.connectionFailed(destination.host) }
            defer { curl_easy_cleanup(h) }
            configure(h, url: baseURL(path: remotePath))
            let state = UploadState(data: data, progress: progress)
            let unmanaged = Unmanaged.passRetained(state)
            defer { unmanaged.release() }
            _ = tether_curl_setopt_long(h, CURLOPT_UPLOAD, 1)
            _ = tether_curl_setopt_long(h, CURLOPT_INFILESIZE_LARGE, data.count)
            _ = tether_curl_setopt_pointer(h, CURLOPT_READDATA, unmanaged.toOpaque())
            _ = tether_curl_setopt_readfn(h, CURLOPT_READFUNCTION) { buffer, size, nitems, userdata in
                guard let buffer, let userdata else { return 0 }
                let st = Unmanaged<UploadState>.fromOpaque(userdata).takeUnretainedValue()
                let want = Int(size) * Int(nitems)
                let n = min(want, st.data.count - st.cursor)
                if n <= 0 { return 0 }
                st.data.withUnsafeBytes { raw in
                    _ = memcpy(buffer, raw.baseAddress!.advanced(by: st.cursor), n)
                }
                st.cursor += n
                st.progress?(st.cursor, st.data.count)
                return n
            }
            let rc = curl_easy_perform(h)
            guard rc == CURLE_OK else {
                let code = Int(tether_curl_response_code(h))
                throw FTPClientError.unexpectedReply(code: code, text: String(cString: curl_easy_strerror(rc)))
            }
        }.value
    }
}
#endif
