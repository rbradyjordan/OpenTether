import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Cameras controlled over HTTP on their own Wi-Fi access point, built on the
// same seam as the Ricoh GR handler (`RicohHTTP`): GoPro (Open GoPro API) and
// 360° cameras that speak Google's Open Spherical Camera API (Ricoh Theta,
// Insta360 and others). Both find new photos by listing the card and diffing,
// and download them by path.

/// A camera handler reached over HTTP (no PTP engine). The connection
/// builder asks it who it is before starting a session.
public protocol HTTPCameraHandler: VendorHandler {
    func probeIdentity() async throws -> CameraIdentity
}

extension RicohHandler: HTTPCameraHandler {}

/// Shared plumbing: requests, the "new file" diff and path ↔ handle mapping.
public class HTTPFileCamera: @unchecked Sendable {
    public let baseURL: URL
    public let http: RicohHTTP
    public let handles = RicohHandleMap()
    let lock = NSLock()
    private var known: Set<String>?
    private var names: [String: String] = [:]

    init(baseURL: URL, http: RicohHTTP) {
        self.baseURL = baseURL
        self.http = http
    }

    func url(_ path: String) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) ?? baseURL }
        var s = baseURL.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + path) ?? baseURL
    }

    func request(_ method: String, _ path: String, json: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let json {
            req.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        let (data, status) = try await http.send(req)
        guard (200 ..< 300).contains(status) else { throw PTPError.unsupported("The camera answered HTTP \(status) to \(path).") }
        return data
    }

    /// Diff a full listing (path → display file name) against the last one.
    /// The first listing only seeds, so photos already on the card are not
    /// imported.
    func announce(_ listing: [(path: String, name: String)]) -> [CameraEvent] {
        lock.lock(); defer { lock.unlock() }
        for item in listing { names[item.path] = item.name }
        let paths = listing.map(\.path)
        guard let seen = known else { known = Set(paths); return [] }
        known = seen.union(paths)
        return paths.filter { !seen.contains($0) }.map { path in
            .objectAdded(NewObject(handle: handles.handle(for: path), storageID: 0x0001_0001,
                                   info: Self.objectInfo(name: names[path] ?? (path as NSString).lastPathComponent)))
        }
    }

    func download(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        guard let path = handles.path(for: object.handle) else { throw PTPError.unsupported("Unknown photo \(object.handle).") }
        let data = try await request("GET", path, timeout: 120)
        progress?(data.count, data.count)
        let name = lock.withLock { names[path] } ?? (path as NSString).lastPathComponent
        var info = Self.objectInfo(name: name)
        info.objectCompressedSize = UInt32(clamping: data.count)
        return (info, data)
    }

    static func objectInfo(name: String) -> PTPObjectInfo {
        let ext = (name as NSString).pathExtension.lowercased()
        let format: PTPObjectFormat = (ext == "jpg" || ext == "jpeg") ? .exifJPEG : .undefined
        return PTPObjectInfo(storageID: 0x0001_0001, objectFormat: format, filename: name)
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - GoPro

/// GoPro HERO9 and later through the Open GoPro HTTP API on the camera's
/// access point (http://10.5.5.9:8080). Turn on the camera's Wi-Fi from its
/// Connections menu (or once from GoPro Quik), join it on the phone, then
/// connect. Stills (JPEG and GoPro RAW .GPR) arrive as they are taken.
public final class GoProHandler: HTTPFileCamera, HTTPCameraHandler, VendorHandler, @unchecked Sendable {
    public static let defaultHost = "10.5.5.9:8080"
    public let vendor: CameraVendor = .gopro
    public let capabilities: CameraCapabilities = [.remoteCapture, .cardCapture, .wireless]
    public let eventPollInterval: TimeInterval = 1.0
    private var lastKeepAlive = Date.distantPast

    public override init(baseURL: URL = URL(string: "http://\(GoProHandler.defaultHost)")!, http: RicohHTTP = URLSessionRicohHTTP()) {
        super.init(baseURL: baseURL, http: http)
    }

    enum Path {
        static let info = "/gopro/camera/info"
        static let mediaList = "/gopro/media/list"
        static let shutterStart = "/gopro/camera/shutter/start"
        static let photoGroup = "/gopro/camera/presets/set_group?id=1001"
        static let externalControl = "/gopro/camera/control/set_ui_controller?p=2"
        static let keepAlive = "/gopro/camera/keep_alive"
        static let media = "/videos/DCIM/"
    }

    public func probeIdentity() async throws -> CameraIdentity {
        let root = Self.json(try await request("GET", Path.info)) ?? [:]
        let info = (root["info"] as? [String: Any]) ?? root
        let model = info["model_name"] as? String ?? "GoPro"
        let serial = info["serial_number"] as? String ?? ""
        return CameraIdentity(id: serial.isEmpty ? "gopro-\(baseURL.host ?? "camera")" : "gopro-\(serial)",
                              vendor: .gopro, manufacturer: "GoPro", model: model, serialNumber: serial,
                              firmware: info["firmware_version"] as? String ?? "", transport: .http, capabilities: capabilities)
    }

    /// True when `host` answers the camera-info endpoint with a model name.
    public static func probe(body: Data) -> Bool {
        guard let root = json(body) else { return false }
        let info = (root["info"] as? [String: Any]) ?? root
        return info["model_name"] != nil
    }

    public func prepare() async throws {
        // Newer bodies want an external controller claim; older ones ignore it.
        _ = try? await request("GET", Path.externalControl)
        _ = try? await request("GET", Path.photoGroup)
        _ = announce(try await listStills())
    }

    public func teardown() async {}

    public func setCaptureDestination(_ destination: CaptureDestination) async throws {
        if destination != .card { throw PTPError.unsupported("GoPro saves to its card; frames are downloaded from there.") }
    }

    public func capture(autofocus: Bool) async throws {
        _ = try await request("GET", Path.shutterStart)
    }

    public func pollEvents() async throws -> [CameraEvent] {
        if Date().timeIntervalSince(lastKeepAlive) > 3 {
            lastKeepAlive = Date()
            _ = try? await request("GET", Path.keepAlive, timeout: 3)
        }
        return announce(try await listStills())
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? { nil }
    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] { [] }
    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        throw PTPError.unsupported("Change settings on the GoPro itself.")
    }

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        try await download(object, progress: progress)
    }

    func listStills() async throws -> [(path: String, name: String)] {
        Self.stills(fromMediaList: try await request("GET", Path.mediaList))
    }

    /// `{"media":[{"d":"100GOPRO","fs":[{"n":"GOPR0001.JPG"}]}]}` → still paths.
    public static func stills(fromMediaList data: Data) -> [(path: String, name: String)] {
        guard let root = json(data), let media = root["media"] as? [[String: Any]] else { return [] }
        var out: [(String, String)] = []
        for dir in media {
            guard let d = dir["d"] as? String else { continue }
            for file in (dir["fs"] as? [[String: Any]]) ?? [] {
                guard let n = file["n"] as? String else { continue }
                let ext = (n as NSString).pathExtension.lowercased()
                guard ["jpg", "jpeg", "gpr"].contains(ext) else { continue }
                out.append((Path.media + d + "/" + n, n))
            }
        }
        return out
    }
}

// MARK: - Open Spherical Camera (Ricoh Theta, Insta360…)

/// Google's Open Spherical Camera API (level 2): `/osc/info`,
/// `camera.takePicture`, `camera.listFiles`, files by `fileUrl`. Ricoh Theta
/// answers at http://192.168.1.1 on its own access point; Insta360 bodies
/// that implement OSC usually at http://192.168.42.1.
public final class OSCHandler: HTTPFileCamera, HTTPCameraHandler, VendorHandler, @unchecked Sendable {
    public static let defaultHosts = ["192.168.1.1", "192.168.42.1"]
    public let vendor: CameraVendor = .osc
    public let capabilities: CameraCapabilities = [.remoteCapture, .cardCapture, .wireless]
    public let eventPollInterval: TimeInterval = 1.0

    public override init(baseURL: URL = URL(string: "http://192.168.1.1")!, http: RicohHTTP = URLSessionRicohHTTP()) {
        super.init(baseURL: baseURL, http: http)
    }

    func execute(_ name: String, _ parameters: [String: Any] = [:]) async throws -> [String: Any] {
        var body: [String: Any] = ["name": name]
        if !parameters.isEmpty { body["parameters"] = parameters }
        let root = Self.json(try await request("POST", "/osc/commands/execute", json: body)) ?? [:]
        if let error = root["error"] as? [String: Any] {
            throw PTPError.unsupported("The camera refused \(name): \(error["message"] as? String ?? "\(error["code"] ?? "error")")")
        }
        return root
    }

    public func probeIdentity() async throws -> CameraIdentity {
        let info = Self.json(try await request("GET", "/osc/info")) ?? [:]
        let maker = info["manufacturer"] as? String ?? ""
        let model = info["model"] as? String ?? "360° camera"
        let serial = info["serialNumber"] as? String ?? ""
        return CameraIdentity(id: serial.isEmpty ? "osc-\(baseURL.host ?? "camera")" : "osc-\(serial)",
                              vendor: .osc, manufacturer: maker, model: model, serialNumber: serial,
                              firmware: info["firmwareVersion"] as? String ?? "", transport: .http, capabilities: capabilities)
    }

    /// True when `/osc/info` names a model.
    public static func probe(body: Data) -> Bool { json(body)?["model"] != nil }

    public func prepare() async throws {
        // Level-1 Thetas need to be switched to API level 2 first; later ones ignore it.
        _ = try? await execute("camera.setOptions", ["options": ["clientVersion": 2]])
        _ = try? await execute("camera.setOptions", ["options": ["captureMode": "image"]])
        _ = announce(try await listImages())
    }

    public func teardown() async {}

    public func setCaptureDestination(_ destination: CaptureDestination) async throws {
        if destination != .card { throw PTPError.unsupported("360° cameras save to their storage; frames are downloaded from there.") }
    }

    public func capture(autofocus: Bool) async throws {
        _ = try await execute("camera.takePicture")
    }

    public func pollEvents() async throws -> [CameraEvent] { announce(try await listImages()) }
    public func translate(_ event: PTPEvent) async -> CameraEvent? { nil }
    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] { [] }
    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        throw PTPError.unsupported("Change settings on the camera itself.")
    }

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        try await download(object, progress: progress)
    }

    func listImages() async throws -> [(path: String, name: String)] {
        Self.images(fromListFiles: try await execute("camera.listFiles", ["fileType": "image", "entryCount": 100, "maxThumbSize": 0]))
    }

    /// `{"results":{"entries":[{"name":"R0010001.JPG","fileUrl":"http://…"}]}}`.
    public static func images(fromListFiles root: [String: Any]) -> [(path: String, name: String)] {
        guard let results = root["results"] as? [String: Any], let entries = results["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { e in
            guard let url = e["fileUrl"] as? String else { return nil }
            return (url, e["name"] as? String ?? (url as NSString).lastPathComponent)
        }
    }
}

// MARK: - Discovery

/// Probes the fixed addresses GoPro and OSC cameras use on their own access
/// point, so they show up in the Wi-Fi list without typing an address.
public final class HTTPCameraProbe: CameraDiscovering, @unchecked Sendable {
    public var interval: TimeInterval = 10
    public var timeout: TimeInterval = 2

    private let state = DiscoveryState()
    private let prober: HTTPProbing
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(prober: HTTPProbing = URLSessionProber()) { self.prober = prober }

    public var cameras: AsyncStream<[DiscoveredCamera]> { state.stream }
    public var current: [DiscoveredCamera] { state.snapshot }

    public func start() async throws {
        lock.withLock {
            if task != nil { return }
            task = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.probeOnce()
                    try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                }
            }
        }
    }

    public func stop() async {
        let t = lock.withLock { () -> Task<Void, Never>? in defer { task = nil }; return task }
        t?.cancel()
    }

    public func probeOnce() async {
        var found: [DiscoveredCamera] = []
        if let url = URL(string: "http://\(GoProHandler.defaultHost)\(GoProHandler.Path.info)"),
           let (body, status) = try? await prober.get(url, timeout: timeout), status == 200, GoProHandler.probe(body: body) {
            let root = HTTPFileCamera.json(body) ?? [:]
            let model = ((root["info"] as? [String: Any]) ?? root)["model_name"] as? String ?? "GoPro"
            found.append(DiscoveredCamera(id: GoProHandler.defaultHost, name: model, vendor: .gopro, host: GoProHandler.defaultHost,
                                          port: 8080, method: .httpProbe, transport: .http))
        }
        for host in OSCHandler.defaultHosts {
            guard let url = URL(string: "http://\(host)/osc/info"),
                  let (body, status) = try? await prober.get(url, timeout: timeout), status == 200, OSCHandler.probe(body: body) else { continue }
            let model = HTTPFileCamera.json(body)?["model"] as? String ?? "360° camera"
            found.append(DiscoveredCamera(id: host, name: model, vendor: .osc, host: host, port: 80, method: .httpProbe, transport: .http))
        }
        state.remove { cam in !found.contains { $0.id == cam.id } }
        for cam in found { state.upsert(cam) }
    }
}
