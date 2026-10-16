import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP GET seam so discovery (Ricoh props, SSDP device description)
/// can be unit-tested with canned responses.
public protocol HTTPProbing: Sendable {
    /// Returns body and HTTP status. Throws on transport failure or timeout.
    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int)
}

public struct URLSessionProber: HTTPProbing {
    public init() {}

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req) { data, resp, err in
                if let err { cont.resume(throwing: err); return }
                guard let data, let resp else { cont.resume(throwing: URLError(.badServerResponse)); return }
                cont.resume(returning: (data, resp))
            }
            task.resume()
        }
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
