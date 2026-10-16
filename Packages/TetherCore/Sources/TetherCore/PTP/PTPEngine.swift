import Foundation

/// The transport-agnostic PTP engine. Owns the session, serialises
/// transactions (PTP permits one outstanding operation per session), and
/// offers typed helpers for the generic operations every vendor shares.
///
/// Vendor handlers call `execute` for their own opcodes; the capture loop
/// calls the typed helpers. Nothing here touches a database or the UI.
public actor PTPEngine {
    public let transport: PTPTransport
    public private(set) var sessionID: UInt32 = 0
    public private(set) var deviceInfo: PTPDeviceInfo?
    public private(set) var isSessionOpen = false

    /// Chunk size for GetPartialObject downloads. 1 MiB keeps USB and Wi-Fi
    /// progress callbacks responsive without flooding the camera.
    public var partialChunkSize: UInt32 = 1 << 20

    private var log: PTPLog?
    private var retryBusyAttempts = 6

    public init(transport: PTPTransport, log: PTPLog? = nil) {
        self.transport = transport
        self.log = log
    }

    public var kind: TransportKind { transport.kind }
    public var events: AsyncStream<PTPEvent> { transport.events }

    // MARK: Session

    /// Open the link and a PTP session, then read DeviceInfo.
    public func connect(sessionID: UInt32 = 1) async throws -> PTPDeviceInfo {
        try await transport.open()
        let info = try await getDeviceInfo()
        deviceInfo = info
        if info.supports(.openSession) {
            try await openSession(sessionID)
        }
        return info
    }

    public func openSession(_ id: UInt32) async throws {
        let r = try await execute(PTPRequest(.openSession, parameters: [id]))
        switch r.code {
        case .ok, .sessionAlreadyOpen:
            sessionID = id
            isSessionOpen = true
        default:
            throw PTPError.response(op: .openSession, code: r.code, parameters: r.parameters)
        }
    }

    public func closeSession() async {
        if isSessionOpen {
            _ = try? await execute(PTPRequest(.closeSession))
            isSessionOpen = false
        }
    }

    public func disconnect() async {
        await closeSession()
        await transport.close()
    }

    // MARK: Raw transactions

    /// Execute a request, retrying `DeviceBusy` with backoff. Logs every
    /// transaction when a `PTPLog` is attached.
    public func execute(_ request: PTPRequest) async throws -> PTPResponse {
        var attempt = 0
        while true {
            let started = Date()
            let response: PTPResponse
            do {
                response = try await transport.execute(request)
            } catch {
                log?.record(.init(request: request, response: nil, error: "\(error)", duration: Date().timeIntervalSince(started)))
                throw error
            }
            log?.record(.init(request: request, response: response, error: nil, duration: Date().timeIntervalSince(started)))
            if response.code == .deviceBusy, attempt < retryBusyAttempts {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(50_000_000) << UInt64(min(attempt, 5)))
                continue
            }
            return response
        }
    }

    /// Execute and require OK.
    @discardableResult
    public func run(_ code: PTPOperationCode, _ parameters: [UInt32] = [], dataOut: Data? = nil,
                    expectsLargeData: Bool = false, timeout: TimeInterval = 10) async throws -> PTPResponse {
        let r = try await execute(PTPRequest(code, parameters: parameters, dataOut: dataOut,
                                             expectsLargeData: expectsLargeData, timeout: timeout))
        return try r.checked(code)
    }

    // MARK: Typed generic operations

    public func getDeviceInfo() async throws -> PTPDeviceInfo {
        let r = try await run(.getDeviceInfo)
        let info = try PTPDeviceInfo(parsing: r.dataIn)
        deviceInfo = info
        return info
    }

    public func getStorageIDs() async throws -> [UInt32] {
        var b = ByteBuffer(try await run(.getStorageIDs).dataIn)
        return try b.readUInt32Array()
    }

    public func getStorageInfo(_ id: UInt32) async throws -> PTPStorageInfo {
        try PTPStorageInfo(parsing: try await run(.getStorageInfo, [id]).dataIn)
    }

    /// All handles in `storage` (0xFFFFFFFF = every store), optionally filtered
    /// by format and parent (0xFFFFFFFF = root, 0 = everything).
    public func getObjectHandles(storage: UInt32 = 0xFFFF_FFFF, format: PTPObjectFormat? = nil, parent: UInt32 = 0) async throws -> [UInt32] {
        var params: [UInt32] = [storage, UInt32(format?.rawValue ?? 0)]
        if parent != 0 { params.append(parent) }
        var b = ByteBuffer(try await run(.getObjectHandles, params).dataIn)
        return try b.readUInt32Array()
    }

    public func getObjectInfo(_ handle: UInt32) async throws -> PTPObjectInfo {
        try PTPObjectInfo(parsing: try await run(.getObjectInfo, [handle]).dataIn)
    }

    public func getThumb(_ handle: UInt32) async throws -> Data {
        try await run(.getThumb, [handle], expectsLargeData: true, timeout: 30).dataIn
    }

    /// Whole object in one transaction.
    public func getObject(_ handle: UInt32, timeout: TimeInterval = 120) async throws -> Data {
        try await run(.getObject, [handle], expectsLargeData: true, timeout: timeout).dataIn
    }

    /// Chunked download with progress. Uses GetPartialObject when supported,
    /// otherwise falls back to GetObject. Vendors with their own partial
    /// opcode (Canon GetPartialObjectEx) override through the handler.
    public func download(_ handle: UInt32, size: UInt32?, progress: (@Sendable (Int, Int?) -> Void)? = nil) async throws -> Data {
        let supportsPartial = deviceInfo?.supports(.getPartialObject) ?? true
        guard supportsPartial, let total = size, total > 0 else {
            let d = try await getObject(handle)
            progress?(d.count, d.count)
            return d
        }
        var out = Data()
        out.reserveCapacity(Int(total))
        var offset: UInt32 = 0
        while offset < total {
            try Task.checkCancellation()
            let want = min(partialChunkSize, total - offset)
            let r = try await run(.getPartialObject, [handle, offset, want], expectsLargeData: true, timeout: 60)
            if r.dataIn.isEmpty { throw PTPError.malformed("GetPartialObject returned no data at \(offset)") }
            out.append(r.dataIn)
            offset += UInt32(r.dataIn.count)
            progress?(out.count, Int(total))
            if r.dataIn.count < Int(want) && offset < total {
                // Camera handed back less than asked; keep going from where it stopped.
                continue
            }
        }
        return out
    }

    public func deleteObject(_ handle: UInt32) async throws {
        try await run(.deleteObject, [handle, 0])
    }

    public func getDevicePropDesc(_ code: PTPDevicePropCode) async throws -> PTPDevicePropDesc {
        try PTPDevicePropDesc(parsing: try await run(.getDevicePropDesc, [UInt32(code.rawValue)]).dataIn)
    }

    public func getDevicePropValue(_ code: PTPDevicePropCode, type: PTPDataType) async throws -> PTPValue {
        var b = ByteBuffer(try await run(.getDevicePropValue, [UInt32(code.rawValue)]).dataIn)
        return try PTPValue.read(type, from: &b)
    }

    public func setDevicePropValue(_ code: PTPDevicePropCode, _ value: PTPValue) async throws {
        try await run(.setDevicePropValue, [UInt32(code.rawValue)], dataOut: value.encoded)
    }

    /// Generic capture (PTP 1.1 §10.4.14). Vendors with two-stage shutters
    /// do not use this.
    public func initiateCapture(storage: UInt32 = 0, format: PTPObjectFormat? = nil) async throws {
        try await run(.initiateCapture, [storage, UInt32(format?.rawValue ?? 0)], timeout: 30)
    }

    public func initiateOpenCapture(storage: UInt32 = 0) async throws -> UInt32 {
        let r = try await run(.initiateOpenCapture, [storage, 0], timeout: 30)
        return r.transactionID
    }

    public func terminateOpenCapture(transactionID: UInt32) async throws {
        try await run(.terminateOpenCapture, [transactionID])
    }

    public func setLog(_ log: PTPLog?) { self.log = log }
}

/// In-memory ring of recent transactions for the diagnostics screen.
public final class PTPLog: @unchecked Sendable {
    public struct Entry: Sendable {
        public let at = Date()
        public let request: PTPRequest
        public let response: PTPResponse?
        public let error: String?
        public let duration: TimeInterval

        public init(request: PTPRequest, response: PTPResponse?, error: String?, duration: TimeInterval) {
            self.request = request
            self.response = response
            self.error = error
            self.duration = duration
        }

        public var line: String {
            let params = request.parameters.map { String(format: "0x%08x", $0) }.joined(separator: ",")
            let out = request.dataOut.map { " out=\($0.count)B" } ?? ""
            let result: String
            if let e = error { result = "ERR \(e)" }
            else if let r = response { result = "\(r.code)" + (r.dataIn.isEmpty ? "" : " in=\(r.dataIn.count)B") }
            else { result = "?" }
            return String(format: "%@(%@)%@ → %@ %.0fms", "\(request.code)", params, out, result, duration * 1000)
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    public let capacity: Int

    public init(capacity: Int = 500) { self.capacity = capacity }

    public func record(_ e: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(e)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public var recent: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}
