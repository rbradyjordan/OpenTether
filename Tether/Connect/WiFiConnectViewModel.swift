import Foundation
import Observation
import TetherCore

@Observable @MainActor
final class WiFiConnectViewModel {
    private(set) var cameras: [DiscoveredCamera] = []
    private(set) var ssid: String?
    private(set) var ssidAuthorization: SSIDAuthorization = .notDetermined
    private(set) var discoveryErrors: [String: String] = [:]
    var progress: ConnectProgress?
    var isConnecting = false
    var connectingID: String?

    private let discovery: CameraDiscoverer
    private let ssidProvider: any SSIDProviding
    private var task: Task<Void, Never>?
    private var ssidTask: Task<Void, Never>?

    init(discovery: CameraDiscoverer, ssid: any SSIDProviding) {
        self.discovery = discovery
        self.ssidProvider = ssid
    }

    var cameraNetworkVendor: CameraVendor? { ssid.flatMap { CameraWiFiHints.looksLikeCameraNetwork($0) } }

    /// Grouped by brand (unknown last), controllable first within a group.
    var groups: [(vendor: CameraVendor?, cameras: [DiscoveredCamera])] {
        var dict: [String: [DiscoveredCamera]] = [:]
        for c in cameras { dict[c.vendor?.rawValue ?? "~", default: []].append(c) }
        return dict.keys.sorted().map { key in
            (vendor: CameraVendor(rawValue: key), cameras: dict[key] ?? [])
        }
    }

    func start() {
        guard task == nil else { return }
        let stream = discovery.cameras
        task = Task { [weak self] in
            try? await self?.discovery.start()
            self?.discoveryErrors = self?.discovery.lastErrors ?? [:]
            for await list in stream {
                guard let self else { return }
                cameras = list
            }
        }
        ssidTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await refreshSSID()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        ssidTask?.cancel(); ssidTask = nil
        Task { await discovery.stop() }
    }

    func refreshSSID() async {
        ssidAuthorization = await ssidProvider.authorizationState
        ssid = await ssidProvider.currentSSID()
    }

    func requestSSIDAccess() {
        Task {
            await ssidProvider.requestAuthorization()
            await refreshSSID()
        }
    }

    func addManual(host: String, port: UInt16, vendor: CameraVendor?) {
        discovery.addManual(host: host, port: port, vendor: vendor)
    }

    func connect(_ camera: DiscoveredCamera, shoot: ShootSession, app: AppModel) {
        guard !isConnecting else { return }
        isConnecting = true
        connectingID = camera.id
        var p = ConnectProgress(transport: camera.transport)
        p.advance(to: .link)
        progress = p
        let report: ConnectionBuilder.Progress = { [weak self] step in self?.progress?.advance(to: step) }
        Task {
            defer { isConnecting = false; connectingID = nil }
            do {
                let connection: LiveConnection
                if camera.transport == .ricohHTTP || camera.vendor == .ricoh {
                    connection = try await ConnectionBuilder.connectRicoh(host: camera.host, shoot: shoot, services: app.services, progress: report)
                } else {
                    connection = try await ConnectionBuilder.connectPTPIP(host: camera.host, port: camera.port, vendorHint: camera.vendor,
                                                                          shoot: shoot, services: app.services, progress: report)
                }
                progress = nil
                app.activate(connection)
            } catch {
                progress?.fail("\(error)")
                HapticFeedback.error()
            }
        }
    }
}
