import Foundation

public enum DiscoveryMethod: String, Codable, Sendable {
    case ssdp, bonjour, fujiUDP, ricohHTTP, httpProbe, manual
    /// Found by probing PTP/IP's port on the local network (no multicast needed).
    case portScan
}

/// A camera seen on the network but not yet connected. `id` is the dedupe
/// key: UUID/USN for SSDP, service name for Bonjour, host for Fuji, Ricoh and
/// manual entries.
public struct DiscoveredCamera: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var vendor: CameraVendor?
    public var host: String
    public var port: UInt16
    public var method: DiscoveryMethod
    public var transport: TransportKind
    public var lastSeen: Date
    public var details: [String: String]

    public init(id: String, name: String, vendor: CameraVendor?, host: String, port: UInt16,
                method: DiscoveryMethod, transport: TransportKind, lastSeen: Date = Date(),
                details: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.host = host
        self.port = port
        self.method = method
        self.transport = transport
        self.lastSeen = lastSeen
        self.details = details
    }

    /// True when we implement a wireless protocol for this brand.
    public var isControllable: Bool { vendor?.supportsWirelessControl ?? false }
}

/// One discovery source. `cameras` yields the source's full current list and
/// re-emits it whenever it changes; every call gets its own stream.
public protocol CameraDiscovering: AnyObject, Sendable {
    var cameras: AsyncStream<[DiscoveredCamera]> { get }
    func start() async throws
    func stop() async
}

/// Shared state keeper for discoverers: a keyed list plus the broadcaster.
final class DiscoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: DiscoveredCamera] = [:]
    private let broadcaster = ValueBroadcaster<[DiscoveredCamera]>(initial: [])
    private(set) var lastError: String?

    var stream: AsyncStream<[DiscoveredCamera]> { broadcaster.stream() }

    var snapshot: [DiscoveredCamera] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.id < $1.id }
    }

    func upsert(_ camera: DiscoveredCamera) {
        lock.lock()
        entries[camera.id] = camera
        let list = entries.values.sorted { $0.id < $1.id }
        lock.unlock()
        broadcaster.send(list)
    }

    func remove(where predicate: (DiscoveredCamera) -> Bool) {
        lock.lock()
        let before = entries.count
        entries = entries.filter { !predicate($0.value) }
        let changed = before != entries.count
        let list = entries.values.sorted { $0.id < $1.id }
        lock.unlock()
        if changed { broadcaster.send(list) }
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        broadcaster.send([])
    }

    func fail(_ message: String) {
        lock.lock(); lastError = message; lock.unlock()
    }
}
