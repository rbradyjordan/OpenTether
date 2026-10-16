import Foundation

/// Brand from what a camera calls itself on mDNS. Canon advertises
/// `_ptp._tcp` with hostnames like `EOSR5-xxxx.local` / `nicname.canon.com`,
/// Nikon `_ptp._tcp`/`_lnp._tcp` (`NIKON Z 6_2`), Sony `ILCE-7M4`, Fuji
/// `X-T5` / `GFX100`, Leica `LEICA SL2`, OM `OM-1`, Lumix `LUMIX S5`.
public enum BonjourBrandMapper {
    public static let serviceTypes = ["_ptp._tcp.", "_lnp._tcp.", "_bonjour._tcp."]

    public static func vendor(forHost host: String?, serviceName: String?) -> CameraVendor? {
        let hay = ((host ?? "") + " " + (serviceName ?? "")).lowercased()
        if hay.isEmpty { return nil }
        if hay.contains("canon") || hay.contains("nicname.canon.com") || hay.contains("eos") { return .canon }
        if hay.contains("nikon") { return .nikon }
        if hay.contains("sony") || hay.contains("ilce") || hay.contains("dsc-") || hay.contains("ilme") || hay.contains("zv-") { return .sony }
        if hay.contains("fuji") || hay.contains("x-t") || hay.contains("gfx") || hay.contains("x-h") || hay.contains("x-pro") || hay.contains("x-s") || hay.contains("x100") { return .fujifilm }
        if hay.contains("leica") { return .leica }
        if hay.contains("olympus") || hay.contains("om-") || hay.contains("om system") || hay.contains("e-m") { return .olympus }
        if hay.contains("lumix") || hay.contains("panasonic") || hay.contains("dc-") { return .panasonic }
        if hay.contains("hasselblad") { return .hasselblad }
        if hay.contains("ricoh") || hay.contains("pentax") { return .ricoh }
        return nil
    }
}

#if canImport(Darwin)
/// NetServiceBrowser-based discovery on a dedicated run-loop thread. Each
/// found service is resolved; the first usable IPv4 address wins.
public final class BonjourDiscoverer: NSObject, CameraDiscovering, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let state = DiscoveryState()
    private let lock = NSLock()
    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var thread: Thread?
    private var runLoop: RunLoop?
    private var running = false

    public override init() { super.init() }

    public var cameras: AsyncStream<[DiscoveredCamera]> { state.stream }
    public var lastError: String? { state.lastError }
    public var current: [DiscoveredCamera] { state.snapshot }

    public func start() async throws {
        let already = lock.withLock { () -> Bool in
            if running { return true }
            running = true
            return false
        }
        if already { return }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            self.runLoop = RunLoop.current
            // Keep the loop alive with a port even when no browser is scheduled.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            for type in BonjourBrandMapper.serviceTypes {
                let b = NetServiceBrowser()
                b.delegate = self
                b.schedule(in: .current, forMode: .default)
                b.searchForServices(ofType: type, inDomain: "local.")
                self.lock.lock(); self.browsers.append(b); self.lock.unlock()
            }
            ready.signal()
            while self.isRunning {
                if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25)) { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        t.name = "tether.bonjour"
        lock.withLock { thread = t }
        t.start()
        ready.wait()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func stop() async {
        let (bs, ss) = lock.withLock { () -> ([NetServiceBrowser], [String: NetService]) in
            running = false
            defer { browsers = []; services = [:] }
            return (browsers, services)
        }
        runLoop?.perform {
            bs.forEach { $0.stop() }
            ss.values.forEach { $0.stop() }
        }
        state.clear()
    }

    // MARK: NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = service.type + service.name
        lock.lock(); services[key] = service; lock.unlock()
        service.delegate = self
        service.schedule(in: .current, forMode: .default)
        service.resolve(withTimeout: 10)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = service.type + service.name
        lock.lock(); services[key] = nil; lock.unlock()
        state.remove { $0.id == BonjourDiscoverer.identifier(for: service) }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        state.fail("Bonjour browse failed: \(errorDict)")
    }

    // MARK: NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        let addresses = (sender.addresses ?? []).compactMap { data -> String? in
            data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                return POSIXNet.describe(base.assumingMemoryBound(to: sockaddr.self))?.host
            }
        }
        guard let host = IPAddressFilter.preferred(addresses) else { return }
        var txt: [String: String] = [:]
        if let data = sender.txtRecordData() {
            for (k, v) in NetService.dictionary(fromTXTRecord: data) { txt[k] = String(data: v, encoding: .utf8) ?? "" }
        }
        let cam = BonjourDiscoverer.camera(serviceName: sender.name, serviceType: sender.type, hostName: sender.hostName,
                                           host: host, port: sender.port > 0 ? UInt16(sender.port) : PTPIPPacket.standardPort, txt: txt)
        state.upsert(cam)
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        state.fail("Bonjour resolve failed for \(sender.name): \(errorDict)")
    }

    static func identifier(for service: NetService) -> String { "bonjour:" + service.name }
}
#else
/// Linux stub: there is no mDNS browser on the test host. Compiles and emits
/// an empty list so the aggregator's wiring is identical on both platforms.
public final class BonjourDiscoverer: CameraDiscovering, @unchecked Sendable {
    private let state = DiscoveryState()
    public init() {}
    public var cameras: AsyncStream<[DiscoveredCamera]> { state.stream }
    public var lastError: String? { "Bonjour browsing is unavailable on this platform." }
    public var current: [DiscoveredCamera] { [] }
    public func start() async throws {}
    public func stop() async {}
}
#endif

public extension BonjourDiscoverer {
    /// Pure mapping from a resolved service to an entry (shared by both builds).
    static func camera(serviceName: String, serviceType: String, hostName: String?, host: String, port: UInt16,
                       txt: [String: String] = [:]) -> DiscoveredCamera {
        let vendor = BonjourBrandMapper.vendor(forHost: hostName, serviceName: serviceName)
            ?? BonjourBrandMapper.vendor(forHost: txt["ty"], serviceName: txt["model"])
        var details: [String: String] = ["serviceType": serviceType]
        if let hostName { details["hostname"] = hostName }
        for (k, v) in txt { details["txt." + k] = v }
        if let model = txt["ty"] ?? txt["model"] { details["model"] = model }
        return DiscoveredCamera(id: "bonjour:" + serviceName, name: serviceName, vendor: vendor, host: host, port: port,
                                method: .bonjour, transport: .ptpip, lastSeen: Date(), details: details)
    }
}
