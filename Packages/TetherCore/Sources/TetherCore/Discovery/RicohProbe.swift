import Foundation

/// Ricoh GR / Theta expose an HTTP API on their own access point at a fixed
/// address. We poll `/v1/props` and accept any 200 whose JSON names a model.
public final class RicohProbe: CameraDiscovering, @unchecked Sendable {
    public static let defaultHost = "192.168.0.1"
    public static let defaultURL = URL(string: "http://192.168.0.1/v1/props")!
    public var interval: TimeInterval = 10
    public var timeout: TimeInterval = 2

    private let state = DiscoveryState()
    private let prober: HTTPProbing
    private let url: URL
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(prober: HTTPProbing = URLSessionProber(), url: URL = RicohProbe.defaultURL) {
        self.prober = prober
        self.url = url
    }

    public var cameras: AsyncStream<[DiscoveredCamera]> { state.stream }
    public var lastError: String? { state.lastError }
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

    /// One GET; emits or removes the entry.
    public func probeOnce() async {
        do {
            let (body, status) = try await prober.get(url, timeout: timeout)
            guard status == 200, let cam = RicohProbe.camera(fromProps: body, host: url.host ?? RicohProbe.defaultHost) else {
                state.remove { _ in true }
                return
            }
            state.upsert(cam)
        } catch {
            state.fail("Ricoh probe: \(error)")
            // No reply: the camera AP isn't the current network. Drop stale entries.
            state.remove { _ in true }
        }
    }

    /// Pure: builds the entry from a `/v1/props` body. Requires a `model`.
    public static func camera(fromProps body: Data, host: String) -> DiscoveredCamera? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        guard let model = (obj["model"] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        var details: [String: String] = ["model": model]
        for key in ["serialNumber", "firmwareVersion", "manufacturer", "batteryLevel", "channel", "ssid"] {
            if let v = obj[key] { details[key] = "\(v)" }
        }
        return DiscoveredCamera(id: host, name: model, vendor: .ricoh, host: host, port: 80,
                                method: .ricohHTTP, transport: .ricohHTTP, lastSeen: Date(), details: details)
    }
}
