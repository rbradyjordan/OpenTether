import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HTTP seam

/// The HTTP/WebSocket surface the Ricoh handler needs. `URLSessionRicohHTTP`
/// is the real one; tests inject a fake.
public protocol RicohHTTP: AnyObject, Sendable {
    /// One request; returns the body and HTTP status.
    func send(_ request: URLRequest) async throws -> (Data, Int)
    /// A long-lived response body (multipart live view) delivered in chunks.
    /// Returns a handle that stops the stream.
    func stream(_ request: URLRequest, onChunk: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) -> RicohStreamHandle
    /// A WebSocket for `/v1/changes`, or nil when the platform has none
    /// (the handler then polls `/v1/photos`).
    func webSocket(_ url: URL) -> RicohWebSocket?
}

public protocol RicohStreamHandle: AnyObject, Sendable {
    func cancel()
}

public protocol RicohWebSocket: AnyObject, Sendable {
    /// Next text message. Throws when the socket closes.
    func receiveText() async throws -> String
    func cancel()
}

/// URLSession-backed implementation. VERIFY: endpoint shapes come from the
/// community notes on the GR II/III Wi-Fi API, not from Ricoh documentation.
public final class URLSessionRicohHTTP: RicohHTTP, @unchecked Sendable {
    private let session: URLSession
    private let streamSession: URLSession
    private let streamDelegate: StreamDelegate

    public init(session: URLSession = .shared) {
        self.session = session
        streamDelegate = StreamDelegate()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 24
        streamSession = URLSession(configuration: cfg, delegate: streamDelegate, delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error { cont.resume(throwing: error); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                cont.resume(returning: (data ?? Data(), status))
            }
            task.resume()
        }
    }

    public func stream(_ request: URLRequest, onChunk: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) -> RicohStreamHandle {
        let task = streamSession.dataTask(with: request)
        streamDelegate.register(task.taskIdentifier, onChunk: onChunk, onEnd: onEnd)
        task.resume()
        return TaskHandle { task.cancel() }
    }

    public func webSocket(_ url: URL) -> RicohWebSocket? {
        #if canImport(Darwin)
        let task = session.webSocketTask(with: url)
        task.resume()
        return DarwinWebSocket(task: task)
        #else
        return nil
        #endif
    }

    final class TaskHandle: RicohStreamHandle, @unchecked Sendable {
        private let onCancel: @Sendable () -> Void
        init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }

    final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var chunk: [Int: @Sendable (Data) -> Void] = [:]
        private var end: [Int: @Sendable (Error?) -> Void] = [:]

        func register(_ id: Int, onChunk: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) {
            lock.lock(); chunk[id] = onChunk; end[id] = onEnd; lock.unlock()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); let cb = chunk[dataTask.taskIdentifier]; lock.unlock()
            cb?(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let cb = end[task.taskIdentifier]
            chunk[task.taskIdentifier] = nil
            end[task.taskIdentifier] = nil
            lock.unlock()
            cb?(error)
        }
    }

    #if canImport(Darwin)
    final class DarwinWebSocket: RicohWebSocket, @unchecked Sendable {
        let task: URLSessionWebSocketTask
        init(task: URLSessionWebSocketTask) { self.task = task }
        func receiveText() async throws -> String {
            while true {
                let m = try await task.receive()
                switch m {
                case .string(let s): return s
                case .data(let d): if let s = String(data: d, encoding: .utf8) { return s }
                @unknown default: continue
                }
            }
        }
        func cancel() { task.cancel(with: .goingAway, reason: nil) }
    }
    #endif
}

// MARK: - Wire helpers

/// Splits a `multipart/x-mixed-replace` MJPEG body into JPEG frames. Feed
/// chunks as they arrive; frames come out whole. Handles `Content-Length`
/// parts and, when the header lacks it, parts delimited by the next boundary.
public struct MJPEGFrameSplitter: Sendable {
    private var buffer = Data()
    private var boundary: Data?
    public private(set) var framesEmitted = 0

    public init(boundary: String? = nil) {
        if let b = boundary { self.boundary = Data(("--" + b.replacingOccurrences(of: "--", with: "", options: .anchored)).utf8) }
    }

    private static let crlf = Data([0x0D, 0x0A])
    private static let headerEnd = Data([0x0D, 0x0A, 0x0D, 0x0A])

    public mutating func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames = [Data]()
        while let frame = nextFrame() { frames.append(frame) }
        return frames
    }

    private mutating func nextFrame() -> Data? {
        // Locate the boundary line.
        if boundary == nil {
            guard let dash = buffer.range(of: Data("--".utf8)) else { return nil }
            guard let eol = buffer.range(of: Self.crlf, in: dash.lowerBound ..< buffer.endIndex) else { return nil }
            boundary = buffer.subdata(in: dash.lowerBound ..< eol.lowerBound)
        }
        guard let b = boundary, let bRange = buffer.range(of: b) else { return nil }
        guard let headerEnd = buffer.range(of: Self.headerEnd, in: bRange.upperBound ..< buffer.endIndex) else { return nil }
        let headerText = String(decoding: buffer.subdata(in: bRange.upperBound ..< headerEnd.lowerBound), as: UTF8.self)
        let bodyStart = headerEnd.upperBound
        var length: Int?
        // "\r\n" is one Character in Swift, so split on scalars, not Characters.
        for line in headerText.components(separatedBy: CharacterSet.newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let frame: Data
        let consumedEnd: Int
        if let n = length {
            guard buffer.count - bodyStart >= n else { return nil }
            frame = buffer.subdata(in: bodyStart ..< bodyStart + n)
            consumedEnd = bodyStart + n
        } else {
            guard let next = buffer.range(of: b, in: bodyStart ..< buffer.endIndex) else { return nil }
            var end = next.lowerBound
            if end >= 2, buffer[end - 2] == 0x0D, buffer[end - 1] == 0x0A { end -= 2 }
            frame = buffer.subdata(in: bodyStart ..< end)
            consumedEnd = next.lowerBound
        }
        buffer.removeSubrange(0 ..< consumedEnd)
        framesEmitted += 1
        return frame.jpegPayload() ?? frame
    }
}

/// Parses the JSON messages `/v1/changes` pushes. VERIFY: message shape
/// (`{"changed":["storage"], ...}` with photo paths somewhere inside) is
/// from community notes; we therefore collect every photo-looking path.
public enum RicohChangeMessage {
    public static let photoExtensions: Set<String> = ["jpg", "jpeg", "dng", "mov", "mp4"]

    public struct Parsed: Equatable, Sendable {
        public var photoPaths: [String]
        public var cameraChanged: Bool
        public var storageChanged: Bool
    }

    public static func parse(_ text: String) -> Parsed? {
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var paths = [String]()
        collectPaths(json, into: &paths)
        var camera = false, storage = false
        if let dict = json as? [String: Any] {
            let changed = (dict["changed"] as? [String]) ?? (dict["changed"] as? String).map { [$0] } ?? []
            camera = changed.contains { $0.lowercased().contains("camera") || $0.lowercased().contains("param") }
            storage = changed.contains { $0.lowercased().contains("storage") || $0.lowercased().contains("photo") }
            if dict["camera"] != nil { camera = true }
            if dict["storage"] != nil || dict["photos"] != nil || dict["photo"] != nil { storage = true }
        }
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        return Parsed(photoPaths: unique, cameraChanged: camera, storageChanged: storage || !unique.isEmpty)
    }

    static func isPhotoPath(_ s: String) -> Bool {
        guard s.contains("/"), !s.hasPrefix("http") else { return false }
        let ext = (s as NSString).pathExtension.lowercased()
        return photoExtensions.contains(ext)
    }

    private static func collectPaths(_ value: Any, into out: inout [String]) {
        if let s = value as? String {
            if isPhotoPath(s) { out.append(s.hasPrefix("/") ? String(s.dropFirst()) : s) }
        } else if let a = value as? [Any] {
            for v in a { collectPaths(v, into: &out) }
        } else if let d = value as? [String: Any] {
            for (_, v) in d { collectPaths(v, into: &out) }
        }
    }
}

/// Stable UInt32 handles for photo paths (FNV-1a, never 0).
public final class RicohHandleMap: @unchecked Sendable {
    private let lock = NSLock()
    private var pathToHandle: [String: UInt32] = [:]
    private var handleToPath: [UInt32: String] = [:]

    public init() {}

    public static func hash(_ path: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for byte in path.utf8 {
            h ^= UInt32(byte)
            h = h &* 0x0100_0193
        }
        return h == 0 ? 1 : h
    }

    public func handle(for path: String) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        if let h = pathToHandle[path] { return h }
        var h = Self.hash(path)
        while handleToPath[h] != nil { h = h &+ 1; if h == 0 { h = 1 } }
        pathToHandle[path] = h
        handleToPath[h] = path
        return h
    }

    public func path(for handle: UInt32) -> String? {
        lock.lock(); defer { lock.unlock() }
        return handleToPath[handle]
    }
}

/// The subset of `/v1/props` we use. VERIFY: key names from GR II/III notes.
public struct RicohProps: Equatable, Sendable {
    public var model: String
    public var firmware: String
    public var serial: String
    public var batteryPercent: Int?
    /// Shooting parameters by API key (av, tv, sv, xv, WBMode, …).
    public var params: [String: String]
    /// Allowed values per API key (avList, tvList, …).
    public var lists: [String: [String]]

    public init(model: String = "", firmware: String = "", serial: String = "", batteryPercent: Int? = nil,
                params: [String: String] = [:], lists: [String: [String]] = [:]) {
        self.model = model; self.firmware = firmware; self.serial = serial; self.batteryPercent = batteryPercent
        self.params = params; self.lists = lists
    }

    public init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PTPError.malformed("Ricoh /v1/props is not a JSON object")
        }
        func str(_ keys: [String]) -> String {
            for k in keys { if let s = root[k] as? String { return s }; if let n = root[k] as? NSNumber { return n.stringValue } }
            return ""
        }
        model = str(["model"])
        firmware = str(["firmwareVersion", "firmware"])
        serial = str(["serialNo", "serialNumber", "serial"])
        if let n = root["battery"] as? NSNumber { batteryPercent = n.intValue }
        else if let s = root["battery"] as? String, let n = Int(s) { batteryPercent = n }
        else if let d = root["battery"] as? [String: Any], let n = (d["level"] as? NSNumber) ?? (d["percent"] as? NSNumber) { batteryPercent = n.intValue }
        else { batteryPercent = nil }
        var p = [String: String]()
        var l = [String: [String]]()
        for key in RicohCodes.paramKeys {
            if let s = root[key] as? String { p[key] = s } else if let n = root[key] as? NSNumber { p[key] = n.stringValue }
            if let arr = root[key + "List"] as? [Any] {
                l[key] = arr.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
            }
        }
        params = p
        lists = l
    }
}

/// All Ricoh endpoint paths and parameter keys in one place. VERIFY: every
/// path/key comes from community reverse-engineering of the GR II/III app.
public enum RicohCodes {
    public static let props = "/v1/props"                 // VERIFY
    public static let shoot = "/v1/camera/shoot"          // VERIFY
    public static let params = "/v1/params/camera"        // VERIFY
    public static let photos = "/v1/photos"               // VERIFY
    public static let liveview = "/v1/liveview"           // VERIFY
    public static let changes = "/v1/changes"             // VERIFY (WebSocket)
    public static let viewSizeQuery = "size=view"         // VERIFY: JPEG proxy for DNG originals

    public static let paramKeys = ["av", "tv", "sv", "xv", "WBMode", "shootMode", "exposureMode", "stillSize", "stillFormat"]

    public static func key(for p: TetherProperty) -> String? {
        switch p {
        case .aperture: return "av"
        case .shutterSpeed: return "tv"
        case .iso: return "sv"
        case .exposureCompensation: return "xv"
        case .whiteBalance: return "WBMode"
        case .exposureProgram: return "exposureMode"
        case .imageSize: return "stillSize"
        case .imageQuality: return "stillFormat"
        default: return nil
        }
    }

    public static func display(_ p: TetherProperty, _ s: String) -> String {
        switch p {
        case .aperture:
            if let f = Double(s) { return f == f.rounded() ? String(format: "ƒ/%.0f", f) : String(format: "ƒ/%.1f", f) }
            return s
        case .shutterSpeed:
            if s.contains("/") || s.lowercased() == "bulb" { return s }
            if let secs = Double(s) { return PropertyFormat.shutter(seconds: secs) }
            return s
        case .iso:
            return s.lowercased() == "auto" ? "Auto" : s
        case .exposureCompensation:
            guard let ev = Double(s) else { return s }
            return PropertyFormat.exposureCompensation(thousandths: Int64((ev * 1000).rounded()))
        case .whiteBalance:
            return s.replacingOccurrences(of: "_", with: " ").capitalized
        default:
            return s
        }
    }
}

// MARK: - Handler

/// Ricoh GR III / Theta over HTTP + WebSocket. Not a PTP device: `prepare`
/// reads `/v1/props`, capture POSTs `/v1/camera/shoot`, new photos arrive
/// over `/v1/changes` (or by polling `/v1/photos`), and live view is the
/// MJPEG stream at `/v1/liveview`.
public final class RicohHandler: VendorHandler, @unchecked Sendable {
    public let vendor: CameraVendor = .ricoh
    public let capabilities: CameraCapabilities = [.remoteCapture, .cardCapture, .liveView, .propertyControl, .autofocus, .wireless, .reducedImage]
    public let eventPollInterval: TimeInterval = 0.5

    public let baseURL: URL
    public let http: RicohHTTP
    public let handles = RicohHandleMap()
    /// Interval for the `/v1/photos` polling fallback.
    public var photoPollInterval: TimeInterval = 1.0
    /// Fetch a JPEG proxy (`?size=view`) instead of the DNG original.
    public var preferViewProxyForRAW = true

    private let lock = NSLock()
    private var pending: [CameraEvent] = []
    private var knownPhotos: Set<String>?
    private var lastProps: RicohProps?
    private var eventTask: Task<Void, Never>?
    private var socket: RicohWebSocket?
    private var liveStream: RicohStreamHandle?
    private var splitter = MJPEGFrameSplitter()
    private var latestFrame: LiveViewFrame?
    private var frameSequence: UInt64 = 0
    private var liveViewError: Error?

    public init(baseURL: URL = URL(string: "http://192.168.0.1")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.http = URLSessionRicohHTTP(session: session)
    }

    public init(baseURL: URL = URL(string: "http://192.168.0.1")!, http: RicohHTTP) {
        self.baseURL = baseURL
        self.http = http
    }

    // MARK: Requests

    func url(_ path: String, query: String? = nil) -> URL {
        var s = baseURL.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        s += path
        if let q = query { s += "?" + q }
        return URL(string: s) ?? baseURL
    }

    func get(_ path: String, query: String? = nil) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        let (data, status) = try await http.send(req)
        guard (200 ..< 300).contains(status) else { throw PTPError.unsupported("Ricoh \(path) answered HTTP \(status).") }
        return data
    }

    func sendJSON(_ method: String, _ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, status) = try await http.send(req)
        guard (200 ..< 300).contains(status) else { throw PTPError.unsupported("Ricoh \(path) answered HTTP \(status).") }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = root["errCode"] as? NSNumber, code.intValue != 200 {
            throw PTPError.unsupported("Ricoh rejected \(path): \(root["errMsg"] as? String ?? "error \(code)")")
        }
        return data
    }

    public static func shootBody(autofocus: Bool) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["af": autofocus], options: [.sortedKeys])) ?? Data()
    }

    // MARK: Identity / gate

    public func fetchProps() async throws -> RicohProps {
        let p = try RicohProps(json: try await get(RicohCodes.props))
        lock.lock(); lastProps = p; lock.unlock()
        return p
    }

    public func probeIdentity() async throws -> CameraIdentity {
        let p = try await fetchProps()
        let id = p.serial.isEmpty ? "ricoh-\(baseURL.host ?? "camera")" : "ricoh-\(p.serial)"
        return CameraIdentity(id: id, vendor: .ricoh, manufacturer: "Ricoh", model: p.model, serialNumber: p.serial,
                              firmware: p.firmware, transport: .ricohHTTP, capabilities: capabilities)
    }

    /// True when `host` answers `/v1/props` with JSON that names a model.
    public static func probe(host: String, timeout: TimeInterval, http: RicohHTTP? = nil) async -> Bool {
        let base = host.hasPrefix("http") ? host : "http://\(host)"
        guard let url = URL(string: base + RicohCodes.props) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        let client: RicohHTTP = http ?? URLSessionRicohHTTP(session: Self.probeSession(timeout: timeout))
        guard let (data, status) = try? await client.send(req), status == 200 else { return false }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["model"] != nil
    }

    private static func probeSession(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        return URLSession(configuration: cfg)
    }

    public func prepare() async throws {
        _ = try await fetchProps()
        await seedPhotos()
        startEventStream()
    }

    public func teardown() async {
        eventTask?.cancel()
        eventTask = nil
        socket?.cancel()
        socket = nil
        await stopLiveView()
    }

    // MARK: Capture

    public func setCaptureDestination(_ destination: CaptureDestination) async throws {
        if destination != .card { throw PTPError.unsupported("Ricoh cameras write to the card; the file is copied over afterwards.") }
    }

    public func capture(autofocus: Bool) async throws {
        _ = try await sendJSON("POST", RicohCodes.shoot, body: ["af": autofocus])
    }

    // MARK: Events

    /// Lists `/v1/photos` as `dir/file` paths. VERIFY: `{"dirs":[{"name":..,"files":[..]}]}`.
    public static func photoPaths(from data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out = [String]()
        if let dirs = root["dirs"] as? [[String: Any]] {
            for d in dirs {
                guard let name = d["name"] as? String else { continue }
                for f in (d["files"] as? [String]) ?? [] { out.append("\(name)/\(f)") }
            }
        }
        if let flat = root["photos"] as? [String] { out.append(contentsOf: flat) }
        return out
    }

    func seedPhotos() async {
        guard let data = try? await get(RicohCodes.photos) else { return }
        lock.lock(); knownPhotos = Set(Self.photoPaths(from: data)); lock.unlock()
    }

    func startEventStream() {
        eventTask?.cancel()
        if let ws = http.webSocket(url(RicohCodes.changes).webSocketURL) {
            socket = ws
            eventTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self = self else { return }
                    do {
                        let text = try await ws.receiveText()
                        self.handleChange(text)
                    } catch {
                        if Task.isCancelled { return }
                        // Socket dropped: fall back to polling.
                        self.socket = nil
                        self.startPolling()
                        return
                    }
                }
            }
        } else {
            startPolling()
        }
    }

    private func startPolling() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.pollPhotosOnce()
                let ns = UInt64(max(0.1, self.photoPollInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    /// One `/v1/photos` poll; announces paths not seen before.
    public func pollPhotosOnce() async {
        guard let data = try? await get(RicohCodes.photos) else { return }
        announce(Self.photoPaths(from: data))
    }

    /// Feeds one `/v1/changes` message. Exposed for tests.
    public func handleChange(_ text: String) {
        guard let parsed = RicohChangeMessage.parse(text) else { return }
        var events = [CameraEvent]()
        if parsed.cameraChanged { events.append(.propertyChanged(nil)) }
        if !parsed.photoPaths.isEmpty { announce(parsed.photoPaths, extra: &events) }
        else if parsed.storageChanged { events.append(.storageChanged) }
        if !events.isEmpty { lock.lock(); pending.append(contentsOf: events); lock.unlock() }
    }

    private func announce(_ paths: [String]) {
        var events = [CameraEvent]()
        announce(paths, extra: &events)
        if !events.isEmpty { lock.lock(); pending.append(contentsOf: events); lock.unlock() }
    }

    private func announce(_ paths: [String], extra events: inout [CameraEvent]) {
        lock.lock()
        var known = knownPhotos ?? []
        let seeded = knownPhotos != nil
        var fresh = [String]()
        for p in paths where !known.contains(p) { known.insert(p); fresh.append(p) }
        knownPhotos = known
        lock.unlock()
        guard seeded else { return }
        for p in fresh {
            events.append(.objectAdded(NewObject(handle: handles.handle(for: p), storageID: 0x0001_0001, info: Self.objectInfo(path: p, size: 0))))
        }
    }

    public func pollEvents() async throws -> [CameraEvent] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending.removeAll()
        return out
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? { nil }

    // MARK: Properties

    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] {
        let p = try await fetchProps()
        return Self.descriptors(properties, from: p)
    }

    public static func descriptors(_ properties: [TetherProperty], from p: RicohProps) -> [PropertyDescriptor] {
        var out = [PropertyDescriptor]()
        for prop in properties {
            if prop == .batteryLevel {
                if let b = p.batteryPercent {
                    out.append(PropertyDescriptor(property: .batteryLevel, raw: .uint8(UInt8(clamping: b)), display: PropertyFormat.battery(percent: Int64(b)), isWritable: false, form: .other))
                }
                continue
            }
            if prop == .captureDestination {
                out.append(VendorProps.destinationDescriptor(current: .card, allowed: [.card], writable: false))
                continue
            }
            guard let key = RicohCodes.key(for: prop), let value = p.params[key] else { continue }
            let choices = (p.lists[key] ?? []).map { PropertyChoice(raw: .string($0), display: RicohCodes.display(prop, $0)) }
            out.append(PropertyDescriptor(property: prop, raw: .string(value), display: RicohCodes.display(prop, value),
                                          isWritable: true, form: choices.isEmpty ? .other : .choices(choices)))
        }
        return out
    }

    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        guard let key = RicohCodes.key(for: property) else { throw PTPError.unsupported("\(property.displayName) cannot be set on this camera.") }
        let value: String
        if let s = raw.stringValue { value = s } else if let n = raw.intValue { value = "\(n)" } else { throw PTPError.unsupported("Unsupported value for \(property.displayName).") }
        _ = try await sendJSON("PUT", RicohCodes.params, body: [key: value])
    }

    // MARK: Transfer

    static func objectInfo(path: String, size: Int) -> PTPObjectInfo {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let format: PTPObjectFormat = ext == "dng" ? .dng : (ext == "jpg" || ext == "jpeg") ? .exifJPEG : (ext == "mov" || ext == "mp4") ? .mp4 : .undefined
        return PTPObjectInfo(storageID: 0x0001_0001, objectFormat: format, objectCompressedSize: UInt32(clamping: size), filename: name)
    }

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        guard let path = handles.path(for: object.handle) ?? object.info?.filename.nilIfEmpty else {
            throw PTPError.unsupported("Unknown Ricoh photo handle \(object.handle).")
        }
        let isRAW = (path as NSString).pathExtension.lowercased() == "dng"
        let useProxy = isRAW && preferViewProxyForRAW
        let data = try await get(RicohCodes.photos + "/" + path, query: useProxy ? RicohCodes.viewSizeQuery : nil)
        var info = Self.objectInfo(path: path, size: data.count)
        if useProxy {
            info.objectFormat = .exifJPEG
            info.filename = ((info.filename as NSString).deletingPathExtension as NSString).appendingPathExtension("JPG") ?? info.filename
        }
        progress?(data.count, data.count)
        return (info, data)
    }

    /// The untouched original regardless of `preferViewProxyForRAW`.
    public func fetchOriginal(path: String) async throws -> Data {
        try await get(RicohCodes.photos + "/" + path)
    }

    // MARK: Live view

    public func startLiveView(quality: LiveViewQuality) async throws {
        await stopLiveView()
        lock.lock(); splitter = MJPEGFrameSplitter(); latestFrame = nil; liveViewError = nil; lock.unlock()
        var req = URLRequest(url: url(RicohCodes.liveview))
        req.httpMethod = "GET"
        liveStream = http.stream(req, onChunk: { [weak self] chunk in
            self?.ingestLiveView(chunk)
        }, onEnd: { [weak self] error in
            guard let self = self else { return }
            self.lock.lock(); self.liveViewError = error; self.lock.unlock()
        })
    }

    /// Feeds raw multipart bytes. Exposed for tests.
    public func ingestLiveView(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        for frame in splitter.feed(chunk) {
            frameSequence += 1
            latestFrame = LiveViewFrame(jpeg: frame, sequence: frameSequence)
        }
    }

    public func stopLiveView() async {
        liveStream?.cancel()
        liveStream = nil
    }

    public func nextLiveViewFrame() async throws -> LiveViewFrame? {
        lock.lock(); defer { lock.unlock() }
        if let e = liveViewError, latestFrame == nil { liveViewError = nil; throw e }
        let f = latestFrame
        latestFrame = nil
        return f
    }
}

private extension URL {
    var webSocketURL: URL {
        var s = absoluteString
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) } else if s.hasPrefix("http://") { s = "ws://" + s.dropFirst(7) }
        return URL(string: s) ?? self
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
