import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Finds PTP/IP cameras without multicast: a TCP probe of port 15740 on
/// every address of the phone's local IPv4 networks (a /24 at most), then the
/// camera's own UPnP description for its name.
///
/// Why: iOS only lets an app send or receive multicast (SSDP, Fuji's UDP
/// broadcast) with Apple's `com.apple.developer.networking.multicast`
/// entitlement, so without it a Canon's SSDP announcement never arrives.
/// Unicast TCP only needs the local network permission. In camera access
/// point mode the camera is the network's router, so it turns up at once.
public final class PTPIPScanner: CameraDiscovering, @unchecked Sendable {
    public var interval: TimeInterval = 12
    /// Per-address connect timeout. Cameras on the same Wi-Fi answer in a few ms.
    public var probeTimeout: TimeInterval = 0.4
    public var concurrency = 48

    private let state = DiscoveryState()
    private let probe: TCPPortProbing
    private let prober: HTTPProbing
    private let interfaces: @Sendable () -> [NetworkInterfaces.Interface]
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    /// Hosts that answered last sweep, so one dropped probe doesn't remove a camera.
    private var lastSeen: [String: Date] = [:]

    public init(probe: TCPPortProbing = POSIXPortProbe(), prober: HTTPProbing = URLSessionProber(),
                interfaces: @escaping @Sendable () -> [NetworkInterfaces.Interface] = { NetworkInterfaces.ipv4Interfaces() }) {
        self.probe = probe
        self.prober = prober
        self.interfaces = interfaces
    }

    public var cameras: AsyncStream<[DiscoveredCamera]> { state.stream }
    public var lastError: String? { state.lastError }
    public var current: [DiscoveredCamera] { state.snapshot }

    public func start() async throws {
        lock.withLock {
            if task != nil { return }
            task = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.sweepOnce()
                    try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                }
            }
        }
    }

    public func stop() async {
        let t = lock.withLock { () -> Task<Void, Never>? in defer { task = nil }; return task }
        t?.cancel()
    }

    /// Addresses to probe: the likely camera addresses first (the router,
    /// i.e. the camera in access point mode, then .2 and .100), then the rest.
    public static func targets(for interfaces: [NetworkInterfaces.Interface]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for ifc in interfaces where !ifc.isLoopback && IPAddressFilter.isUsable(ifc.address) {
            guard let a = IPAddressFilter.ipv4Octets(ifc.address), let m = IPAddressFilter.ipv4Octets(ifc.netmask) else { continue }
            // Wider masks (a /16 on some routers) are clamped to our own /24.
            let prefix = "\(a[0]).\(a[1]).\(a[2])."
            let lastMask: UInt8 = m[2] == 255 ? m[3] : 0
            let first = Int(a[3] & lastMask) + 1
            let last = Int((a[3] & lastMask) | ~lastMask) - 1
            guard first <= last else { continue }
            let priority = [1, 2, 100, 254].filter { $0 >= first && $0 <= last }
            for host in priority + Array(first ... last) where host != Int(a[3]) {
                let ip = prefix + String(host)
                if seen.insert(ip).inserted { out.append(ip) }
            }
        }
        return out
    }

    /// One sweep: probe every target, identify the ones that answer.
    public func sweepOnce() async {
        let targets = Self.targets(for: interfaces())
        guard !targets.isEmpty else { return }
        var open: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                guard let host = iterator.next() else { return }
                group.addTask { [probe, probeTimeout] in (host, await probe.isOpen(host: host, port: PTPIPPacket.standardPort, timeout: probeTimeout)) }
            }
            for _ in 0 ..< min(concurrency, targets.count) { addNext() }
            while let (host, isOpen) = await group.next() {
                if isOpen { open.append(host) }
                addNext()
            }
        }
        let now = Date()
        for host in open {
            if var known = state.snapshot.first(where: { $0.host == host }) {
                known.lastSeen = now
                state.upsert(known)
            } else {
                state.upsert(await identify(host))
            }
        }
        let gone: [String] = lock.withLock {
            for host in open { lastSeen[host] = now }
            let stale = lastSeen.filter { now.timeIntervalSince($0.value) > interval * 2.5 }.map(\.key)
            stale.forEach { lastSeen[$0] = nil }
            return stale
        }
        if !gone.isEmpty { state.remove { gone.contains($0.host) } }
    }

    /// Name and brand from the camera's UPnP description when it has one
    /// (Canon: `:49152/upnp/CameraDevDesc.xml`); otherwise a generic entry
    /// that DeviceInfo will name once connected.
    func identify(_ host: String) async -> DiscoveredCamera {
        for path in Self.descriptionURLs(host) {
            guard let url = URL(string: path),
                  let (body, status) = try? await prober.get(url, timeout: 1.5), (200 ..< 300).contains(status),
                  let desc = SSDPDeviceDescription.parse(xml: body) else { continue }
            let vendor = Self.vendor(manufacturer: desc.manufacturer, model: desc.modelName)
            let name = [desc.modelName, desc.friendlyName].first { !$0.isEmpty } ?? "Camera"
            return DiscoveredCamera(id: "ptpip-\(host)", name: name, vendor: vendor, host: host, port: PTPIPPacket.standardPort,
                                    method: .portScan, transport: .ptpip, lastSeen: Date(),
                                    details: ["location": path, "manufacturer": desc.manufacturer, "model": desc.modelName])
        }
        return DiscoveredCamera(id: "ptpip-\(host)", name: "Camera at \(host)", vendor: nil, host: host,
                                port: PTPIPPacket.standardPort, method: .portScan, transport: .ptpip, lastSeen: Date())
    }

    /// Where makers serve their UPnP device description.
    static func descriptionURLs(_ host: String) -> [String] {
        ["http://\(host):49152/upnp/CameraDevDesc.xml",   // Canon EOS (WFT)
         "http://\(host):64321/DmsDescPush.xml",          // Sony
         "http://\(host):8080/description.xml"]
    }

    static func vendor(manufacturer: String, model: String) -> CameraVendor? {
        let m = (manufacturer + " " + model).lowercased()
        if m.contains("canon") { return .canon }
        if m.contains("nikon") { return .nikon }
        if m.contains("sony") { return .sony }
        if m.contains("fuji") { return .fujifilm }
        if m.contains("panasonic") || m.contains("lumix") { return .panasonic }
        if m.contains("olympus") || m.contains("om digital") { return .olympus }
        return nil
    }
}

// MARK: - TCP probe

/// "Does anything accept a TCP connection here?" Injected so tests run
/// without a network.
public protocol TCPPortProbing: Sendable {
    func isOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool
}

/// Non-blocking connect with a poll timeout; closes straight away, sending
/// nothing, so a camera in pairing mode sees no half-made connection.
public struct POSIXPortProbe: TCPPortProbing {
    public init() {}

    public func isOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: Self.probe(host, port, timeout)) }
        }
    }

    static func probe(_ host: String, _ port: UInt16, _ timeout: TimeInterval) -> Bool {
        guard var addr = POSIXNet.inet4(host, port: port) else { return false }
        let fd = socket(AF_INET, POSIXNet.streamType, 0)
        guard fd >= 0 else { return false }
        defer { POSIXNet.closeFD(fd) }
        POSIXNet.setNoSigpipe(fd)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}
