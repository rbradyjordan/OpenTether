import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the device token lives (Keychain on device; memory in tests).
public protocol TokenStoring: Sendable {
    func token() -> String?
    func setToken(_ token: String?)
}

public final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func token() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    public func setToken(_ token: String?) { lock.lock(); value = token; lock.unlock() }
}

public enum CloudError: Error, Equatable, CustomStringConvertible {
    case notRegistered
    case http(status: Int, code: String, message: String)
    case decoding(String)
    case insufficientCredits
    case offline

    public var description: String {
        switch self {
        case .notRegistered: return "This device is not registered with the Tether cloud yet."
        case .http(let s, let c, let m): return m.isEmpty ? "\(c) (HTTP \(s))" : m
        case .decoding(let s): return "Unexpected response: \(s)"
        case .insufficientCredits: return "You are out of credits."
        case .offline: return "No connection to the Tether cloud."
        }
    }
}

/// The HTTP contract in backend/API.md, typed. All calls are plain
/// request/response; batch uploads stream from disk.
public final class TetherCloudClient: @unchecked Sendable {
    public struct Me: Codable, Sendable {
        public struct Credits: Codable, Sendable {
            public var balance: Int
            public var monthlyGrant: Int
            public var renewsAt: Date?
            enum CodingKeys: String, CodingKey { case balance, monthlyGrant = "monthly_grant", renewsAt = "renews_at" }
        }
        public var accountID: String
        public var tier: String
        public var credits: Credits
        public var watermarkRequired: Bool?
        enum CodingKeys: String, CodingKey { case accountID = "account_id", tier, credits, watermarkRequired = "watermark_required" }

        public var state: CreditsState {
            CreditsState(tier: CreditsState.Tier(rawValue: tier) ?? .free, balance: credits.balance,
                         monthlyGrant: credits.monthlyGrant, renewsAt: credits.renewsAt)
        }
    }

    public struct Registration: Codable, Sendable {
        public var token: String
        public var accountID: String
        public var tier: String
        public var credits: Me.Credits
        enum CodingKeys: String, CodingKey { case token, accountID = "account_id", tier, credits }
    }

    public struct ColorMatchResult: Codable, Sendable {
        public var lutID: String
        public var cubeURL: String
        public var sha256: String
        public var creditsCharged: Int
        public var creditsRemaining: Int
        enum CodingKeys: String, CodingKey { case lutID = "lut_id", cubeURL = "cube_url", sha256, creditsCharged = "credits_charged", creditsRemaining = "credits_remaining" }
    }

    public struct BatchItemRequest: Codable, Sendable {
        public var clientID: String, filename: String, kind: String, bytes: Int
        enum CodingKeys: String, CodingKey { case clientID = "client_id", filename, kind, bytes }
        public init(clientID: String, filename: String, kind: String, bytes: Int) {
            self.clientID = clientID; self.filename = filename; self.kind = kind; self.bytes = bytes
        }
    }

    public struct Batch: Codable, Sendable {
        public struct Item: Codable, Sendable {
            public var clientID: String, itemID: String, putURL: String, watermark: Bool
            enum CodingKeys: String, CodingKey { case clientID = "client_id", itemID = "item_id", putURL = "put_url", watermark }
        }
        public var batchID: String
        public var items: [Item]
        public var creditsCharged: Int
        public var creditsRemaining: Int
        enum CodingKeys: String, CodingKey { case batchID = "batch_id", items, creditsCharged = "credits_charged", creditsRemaining = "credits_remaining" }
    }

    public struct BatchStatus: Codable, Sendable {
        public struct Item: Codable, Sendable {
            public var itemID: String, clientID: String, filename: String, bytesExpected: Int, bytesStored: Int, watermark: Bool
            enum CodingKeys: String, CodingKey { case itemID = "item_id", clientID = "client_id", filename, bytesExpected = "bytes_expected", bytesStored = "bytes_stored", watermark }
        }
        public var batchID: String, sessionName: String, status: String
        public var items: [Item]
        public var downloadURL: String?
        public var expiresAt: Date?
        enum CodingKeys: String, CodingKey { case batchID = "batch_id", sessionName = "session_name", status, items, downloadURL = "download_url", expiresAt = "expires_at" }
    }

    public struct Purchase: Codable, Sendable {
        public var tier: String
        public var credits: Me.Credits
        public var replayed: Bool
    }

    public struct TestedCamera: Codable, Hashable, Sendable, Identifiable {
        public var vendor: String, model: String, transports: [String], status: String, notes: String
        public var id: String { "\(vendor)/\(model)" }
        public init(vendor: String, model: String, transports: [String], status: String, notes: String) {
            self.vendor = vendor; self.model = model; self.transports = transports; self.status = status; self.notes = notes
        }
    }

    public let baseURL: URL
    public let tokens: TokenStoring
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: try dec.singleValueContainer(), debugDescription: "bad date \(s)")
        }
        return d
    }()

    public init(baseURL: URL, tokens: TokenStoring, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session
    }

    public var isRegistered: Bool { tokens.token() != nil }

    // MARK: Endpoints

    public func register(deviceID: String, appVersion: String) async throws -> Registration {
        let r: Registration = try await send("POST", "/v1/devices/register", json: ["device_id": deviceID, "platform": "ios", "app_version": appVersion], auth: false)
        tokens.setToken(r.token)
        return r
    }

    public func me() async throws -> Me { try await send("GET", "/v1/me") }

    public func looks() async throws -> [LookDescriptor] {
        struct R: Codable { var looks: [LookDescriptor] }
        let r: R = try await send("GET", "/v1/looks", auth: false)
        return r.looks
    }

    public func cube(_ look: LookDescriptor) async throws -> Data {
        let (data, resp) = try await raw("GET", look.cubeURL, body: nil, contentType: nil, auth: isRegistered)
        guard (200 ..< 300).contains(resp) else { throw CloudError.http(status: resp, code: "cube_failed", message: "Could not download the look.") }
        return data
    }

    public func colorMatch(reference: Data, target: Data, strength: Double, lutSize: Int = 33) async throws -> ColorMatchResult {
        let boundary = "tether-\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, _ filename: String?, _ type: String, _ data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            var disp = "Content-Disposition: form-data; name=\"\(name)\""
            if let filename { disp += "; filename=\"\(filename)\"" }
            body.append((disp + "\r\nContent-Type: \(type)\r\n\r\n").data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        part("reference", "reference.jpg", "image/jpeg", reference)
        part("target", "target.jpg", "image/jpeg", target)
        part("strength", nil, "text/plain", String(format: "%.3f", strength).data(using: .utf8)!)
        part("lut_size", nil, "text/plain", "\(lutSize)".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, status) = try await raw("POST", "/v1/tone/color-match", body: body, contentType: "multipart/form-data; boundary=\(boundary)", auth: true)
        return try decode(data, status)
    }

    public func createBatch(sessionName: String, watermark: Bool, lookID: String?, items: [BatchItemRequest]) async throws -> Batch {
        struct Req: Codable {
            var sessionName: String, watermark: Bool, lookID: String?, items: [BatchItemRequest]
            enum CodingKeys: String, CodingKey { case sessionName = "session_name", watermark, lookID = "look_id", items }
        }
        return try await send("POST", "/v1/exports/batch", body: Req(sessionName: sessionName, watermark: watermark, lookID: lookID, items: items))
    }

    /// Returns the number of bytes already stored for an item (0 when none).
    public func storedBytes(putURL: String) async throws -> Int {
        var req = try request("HEAD", putURL, auth: true)
        req.httpBody = nil
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.offline }
        if http.statusCode == 404 { return 0 }
        return Int(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? Int(http.expectedContentLength)
    }

    public func upload(fileURL: URL, to putURL: String, contentType: String) async throws {
        var req = try request("PUT", putURL, auth: true)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: req, fromFile: fileURL)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.offline }
        guard (200 ..< 300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
    }

    public func completeBatch(_ batchID: String) async throws -> BatchStatus {
        try await send("POST", "/v1/exports/\(batchID)/complete", json: [String: String]())
    }

    public func batchStatus(_ batchID: String) async throws -> BatchStatus {
        try await send("GET", "/v1/exports/\(batchID)")
    }

    public func purchase(product: CreditProduct, transactionID: String, signedTransaction: String?) async throws -> Purchase {
        var body: [String: String?] = ["product_id": product.rawValue, "transaction_id": transactionID]
        body["signed_transaction"] = signedTransaction
        return try await send("POST", "/v1/credits/purchase", json: body.compactMapValues { $0 })
    }

    public func testedCameras() async throws -> [TestedCamera] {
        struct R: Codable { var cameras: [TestedCamera] }
        let r: R = try await send("GET", "/v1/cameras/tested", auth: false)
        return r.cameras
    }

    public func health() async -> Bool {
        guard let (_, status) = try? await raw("GET", "/healthz", body: nil, contentType: nil, auth: false) else { return false }
        return status == 200
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String, auth: Bool) throws -> URLRequest {
        let url = path.hasPrefix("http") ? URL(string: path)! : baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        if auth {
            guard let t = tokens.token() else { throw CloudError.notRegistered }
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func raw(_ method: String, _ path: String, body: Data?, contentType: String?, auth: Bool) async throws -> (Data, Int) {
        var req = try request(method, path, auth: auth)
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw CloudError.offline }
            return (data, http.statusCode)
        } catch let e as CloudError { throw e } catch { throw CloudError.offline }
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B, auth: Bool = true) async throws -> T {
        let data = try JSONEncoder().encode(body)
        let (out, status) = try await raw(method, path, body: data, contentType: "application/json", auth: auth)
        return try decode(out, status)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, json: [String: String], auth: Bool = true) async throws -> T {
        try await send(method, path, body: json, auth: auth)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, auth: Bool = true) async throws -> T {
        let (out, status) = try await raw(method, path, body: nil, contentType: nil, auth: auth)
        return try decode(out, status)
    }

    private func decode<T: Decodable>(_ data: Data, _ status: Int) throws -> T {
        guard (200 ..< 300).contains(status) else { throw Self.error(from: data, status: status) }
        do { return try decoder.decode(T.self, from: data) } catch {
            throw CloudError.decoding(String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    static func error(from data: Data, status: Int) -> CloudError {
        struct E: Codable { var error: String; var message: String? }
        if let e = try? JSONDecoder().decode(E.self, from: data) {
            if e.error == "insufficient_credits" { return .insufficientCredits }
            return .http(status: status, code: e.error, message: e.message ?? "")
        }
        return .http(status: status, code: "http_\(status)", message: "")
    }
}
