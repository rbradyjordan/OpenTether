import XCTest
@testable import TetherCore

final class PTPIPScannerTests: XCTestCase {
    private func iface(_ address: String, _ mask: String = "255.255.255.0") -> NetworkInterfaces.Interface {
        NetworkInterfaces.Interface(name: "en0", address: address, netmask: mask, broadcast: "", isLoopback: false)
    }

    func testTargetsCoverTheSubnetLikelyAddressesFirst() {
        let targets = PTPIPScanner.targets(for: [iface("192.168.1.37")])
        XCTAssertEqual(Array(targets.prefix(4)), ["192.168.1.1", "192.168.1.2", "192.168.1.100", "192.168.1.254"])
        XCTAssertEqual(targets.count, 253, "every host but ourselves, once")
        XCTAssertFalse(targets.contains("192.168.1.37"))
        XCTAssertFalse(targets.contains("192.168.1.0"))
        XCTAssertFalse(targets.contains("192.168.1.255"))
        XCTAssertEqual(Set(targets).count, targets.count)
    }

    func testWideMasksClampToOurOwn24AndLoopbackIsSkipped() {
        let wide = PTPIPScanner.targets(for: [iface("10.0.5.9", "255.255.0.0")])
        XCTAssertEqual(wide.count, 253)
        XCTAssertTrue(wide.allSatisfy { $0.hasPrefix("10.0.5.") })
        var lo = iface("127.0.0.1"); lo.isLoopback = true
        XCTAssertTrue(PTPIPScanner.targets(for: [lo]).isEmpty)
        XCTAssertTrue(PTPIPScanner.targets(for: [iface("169.254.3.3")]).isEmpty, "APIPA means no network")
    }

    func testSmallSubnetAndTwoInterfaces() {
        let targets = PTPIPScanner.targets(for: [iface("192.168.1.5", "255.255.255.248"), iface("172.16.0.2")])
        XCTAssertEqual(targets.filter { $0.hasPrefix("192.168.1.") }, ["192.168.1.1", "192.168.1.2", "192.168.1.3", "192.168.1.4", "192.168.1.6"])
        XCTAssertEqual(targets.filter { $0.hasPrefix("172.16.0.") }.count, 253)
    }

    func testSweepFindsOpenPortsAndNamesACanonFromItsDescription() async throws {
        let probe = FakePortProbe(open: ["192.168.1.2", "192.168.1.77"])
        let canonXML = """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
        <friendlyName>Canon EOS R5m2</friendlyName><manufacturer>Canon</manufacturer><modelName>Canon EOS R5m2</modelName>
        <UDN>uuid:00000000-0000-0000-0001-60128B7CC240</UDN>
        <serviceList><service><serviceType>urn:schemas-canon-com:service:ICPO-WFTEOSSystemService:1</serviceType></service></serviceList>
        </device></root>
        """
        let http = FakeProber(responses: ["http://192.168.1.2:49152/upnp/CameraDevDesc.xml": (Data(canonXML.utf8), 200)])
        let scanner = PTPIPScanner(probe: probe, prober: http, interfaces: { [self.iface("192.168.1.37")] })
        scanner.probeTimeout = 0.01
        await scanner.sweepOnce()
        let found = scanner.current.sorted { $0.host < $1.host }
        XCTAssertEqual(found.map(\.host), ["192.168.1.2", "192.168.1.77"])
        XCTAssertEqual(found[0].vendor, .canon)
        XCTAssertEqual(found[0].name, "Canon EOS R5m2")
        XCTAssertEqual(found[0].method, .portScan)
        XCTAssertEqual(found[0].port, PTPIPPacket.standardPort)
        XCTAssertNil(found[1].vendor, "no description: DeviceInfo names it once connected")
        XCTAssertEqual(found[1].name, "Camera at 192.168.1.77")
        XCTAssertEqual(probe.count, 253, "every target probed once")
    }

    func testCameraStaysThroughOneMissedSweepThenGoes() async throws {
        let probe = FakePortProbe(open: ["192.168.1.2"])
        let scanner = PTPIPScanner(probe: probe, prober: FakeProber(responses: [:]), interfaces: { [self.iface("192.168.1.37")] })
        scanner.probeTimeout = 0.01
        scanner.interval = 0.02
        await scanner.sweepOnce()
        XCTAssertEqual(scanner.current.count, 1)
        probe.open = []
        await scanner.sweepOnce()
        XCTAssertEqual(scanner.current.count, 1, "one dropped probe doesn't remove a camera")
        try await Task.sleep(nanoseconds: 80_000_000)
        await scanner.sweepOnce()
        XCTAssertTrue(scanner.current.isEmpty)
    }

    func testRealProbeSeesAListeningLoopbackPortAndNotAClosedOne() async throws {
        let cam = try FakePTPIPCamera()
        cam.start()
        defer { cam.stop() }
        let probe = POSIXPortProbe()
        let open = await probe.isOpen(host: "127.0.0.1", port: cam.port, timeout: 1)
        XCTAssertTrue(open)
        let closed = await probe.isOpen(host: "127.0.0.1", port: 1, timeout: 1)
        XCTAssertFalse(closed)
    }
}

/// Scripted port probe: open hosts answer, everything else is closed.
final class FakePortProbe: TCPPortProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _open: Set<String>
    private var _count = 0
    var open: Set<String> { get { lock.withLock { _open } } set { lock.withLock { _open = newValue } } }
    var count: Int { lock.withLock { _count } }
    init(open: Set<String>) { _open = open }
    func isOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        lock.withLock { _count += 1; return _open.contains(host) }
    }
}

struct ScannerProber: HTTPProbing {
    var responses: [String: (Data, Int)]
    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) {
        if let r = responses[url.absoluteString] { return r }
        throw URLError(.cannotConnectToHost)
    }
}
