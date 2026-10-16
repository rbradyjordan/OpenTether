import Foundation

/// Aggregates every discovery source into one deduplicated list. Entries not
/// re-seen within `expiry` disappear; a source that fails to start is logged
/// in `lastErrors` and the others keep going.
public final class CameraDiscoverer: CameraDiscovering, @unchecked Sendable {
    public let expiry: TimeInterval
    public let sweepInterval: TimeInterval

    private let sources: [CameraDiscovering]
    private let lock = NSLock()
    private var entries: [String: DiscoveredCamera] = [:]
    private var manual: [String: DiscoveredCamera] = [:]
    private let broadcaster = ValueBroadcaster<[DiscoveredCamera]>(initial: [])
    private var tasks: [Task<Void, Never>] = []
    private var running = false
    private var errors: [String: String] = [:]

    /// Default sources: SSDP (Sony), Bonjour (Canon/Nikon/…), Fuji dial-back, Ricoh probe.
    public convenience init(expiry: TimeInterval = 30) {
        self.init(sources: [SSDPDiscoverer(), BonjourDiscoverer(), FujiDiscoverer(), RicohProbe()], expiry: expiry)
    }

    public init(sources: [CameraDiscovering], expiry: TimeInterval = 30, sweepInterval: TimeInterval = 5) {
        self.sources = sources
        self.expiry = expiry
        self.sweepInterval = sweepInterval
    }

    public var cameras: AsyncStream<[DiscoveredCamera]> { broadcaster.stream() }
    public var current: [DiscoveredCamera] { lock.lock(); defer { lock.unlock() }; return merged() }
    /// Source type name → last start/run error.
    public var lastErrors: [String: String] { lock.lock(); defer { lock.unlock() }; return errors }

    public static func localIPv4Addresses() -> [String] { NetworkInterfaces.localIPv4Addresses() }
    public static func broadcastAddresses() -> [String] { NetworkInterfaces.broadcastAddresses() }

    public func start() async throws {
        let already = lock.withLock { () -> Bool in
            if running { return true }
            running = true
            return false
        }
        if already { return }
        for source in sources {
            let name = String(describing: type(of: source))
            do { try await source.start() } catch {
                lock.withLock { errors[name] = "\(error)" }
            }
            let t = Task { [weak self] in
                for await list in source.cameras {
                    guard let self else { return }
                    self.absorb(list, from: name)
                }
            }
            lock.withLock { tasks.append(t) }
        }
        let sweeper = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.sweepInterval * 1_000_000_000))
                self.sweep()
            }
        }
        lock.withLock { tasks.append(sweeper) }
    }

    public func stop() async {
        let ts = lock.withLock { () -> [Task<Void, Never>] in
            running = false
            let t = tasks; tasks = []
            return t
        }
        ts.forEach { $0.cancel() }
        for s in sources { await s.stop() }
        lock.withLock { entries.removeAll() }
        publish()
    }

    /// Adds (or refreshes) a user-entered camera. Manual entries never expire.
    public func addManual(host: String, port: UInt16 = PTPIPPacket.standardPort, vendor: CameraVendor?, name: String? = nil) {
        let transport: TransportKind = vendor == .ricoh ? .ricohHTTP : .ptpip
        let cam = DiscoveredCamera(id: "manual:\(host):\(port)", name: name ?? vendor?.displayName ?? host, vendor: vendor,
                                   host: host, port: port, method: .manual, transport: transport, lastSeen: Date(),
                                   details: ["controllable": String(vendor?.supportsWirelessControl ?? false)])
        lock.lock(); manual[cam.id] = cam; lock.unlock()
        publish()
    }

    public func removeManual(id: String) {
        lock.lock(); manual[id] = nil; lock.unlock()
        publish()
    }

    /// Drops every expired entry now (also runs on the sweep timer).
    public func sweep() {
        let cutoff = Date().addingTimeInterval(-expiry)
        lock.lock()
        let before = entries.count
        entries = entries.filter { $0.value.lastSeen >= cutoff }
        let changed = entries.count != before
        lock.unlock()
        if changed { publish() }
    }

    private func absorb(_ list: [DiscoveredCamera], from source: String) {
        lock.lock()
        for var cam in list {
            cam.details["controllable"] = String(cam.vendor?.supportsWirelessControl ?? false)
            cam.details["source"] = source
            if let existing = entries[cam.id] {
                // Keep the richer record but always refresh lastSeen and address.
                var merged = existing
                merged.host = cam.host
                merged.port = cam.port
                merged.lastSeen = max(cam.lastSeen, Date())
                merged.vendor = cam.vendor ?? existing.vendor
                merged.name = cam.name
                merged.details.merge(cam.details) { _, new in new }
                entries[cam.id] = merged
            } else {
                cam.lastSeen = Date()
                entries[cam.id] = cam
            }
        }
        lock.unlock()
        publish()
    }

    private func merged() -> [DiscoveredCamera] {
        var all = entries
        for (k, v) in manual where all[k] == nil { all[k] = v }
        return all.values.sorted { a, b in
            if a.isControllable != b.isControllable { return a.isControllable }
            return a.id < b.id
        }
    }

    private func publish() {
        lock.lock(); let list = merged(); lock.unlock()
        broadcaster.send(list)
    }
}
