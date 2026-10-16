import XCTest
@testable import TetherCore

final class RicohProbeTests: XCTestCase {
    static let props = Data(#"{"errCode":200,"errMsg":"OK","model":"RICOH GR IIIx","firmwareVersion":"1.50","serialNumber":"1234567","batteryLevel":80}"#.utf8)

    func testCameraFromProps() throws {
        let cam = try XCTUnwrap(RicohProbe.camera(fromProps: Self.props, host: "192.168.0.1"))
        XCTAssertEqual(cam.name, "RICOH GR IIIx")
        XCTAssertEqual(cam.vendor, .ricoh)
        XCTAssertEqual(cam.transport, .ricohHTTP)
        XCTAssertEqual(cam.method, .ricohHTTP)
        XCTAssertEqual(cam.port, 80)
        XCTAssertEqual(cam.id, "192.168.0.1")
        XCTAssertEqual(cam.details["firmwareVersion"], "1.50")
        XCTAssertEqual(cam.details["batteryLevel"], "80")
        XCTAssertNil(RicohProbe.camera(fromProps: Data(#"{"errCode":200}"#.utf8), host: "x"))
        XCTAssertNil(RicohProbe.camera(fromProps: Data("<html>".utf8), host: "x"))
    }

    func testProbeEmitsAndClears() async throws {
        let prober = FakeProber(responses: [RicohProbe.defaultURL.absoluteString: (Self.props, 200)])
        let p = RicohProbe(prober: prober)
        await p.probeOnce()
        XCTAssertEqual(p.current.count, 1)
        XCTAssertEqual(p.current.first?.name, "RICOH GR IIIx")
        // Camera goes away (timeout) → list empties, error recorded.
        prober.error = URLError(.timedOut)
        await p.probeOnce()
        XCTAssertEqual(p.current.count, 0)
        XCTAssertNotNil(p.lastError)
        // A 200 without a model is not a camera.
        prober.error = nil
        prober.set(RicohProbe.defaultURL.absoluteString, Data("{}".utf8), 200)
        await p.probeOnce()
        XCTAssertEqual(p.current.count, 0)
    }
}

/// Scripted discovery source for aggregator tests.
final class FakeDiscoverySource: CameraDiscovering, @unchecked Sendable {
    let state = DiscoveryState()
    var failStart: Error?
    private(set) var started = false
    private(set) var stopped = false
    var cameras: AsyncStream<[DiscoveredCamera]> { state.stream }
    func start() async throws { started = true; if let failStart { throw failStart } }
    func stop() async { stopped = true }
    func emit(_ cams: [DiscoveredCamera]) { state.clear(); cams.forEach { state.upsert($0) } }
}

final class CameraDiscovererTests: XCTestCase {
    func cam(_ id: String, vendor: CameraVendor?, host: String = "192.168.1.5", method: DiscoveryMethod = .bonjour) -> DiscoveredCamera {
        DiscoveredCamera(id: id, name: id, vendor: vendor, host: host, port: 15740, method: method, transport: .ptpip)
    }

    func testMergesDedupesAndFlagsControllable() async throws {
        let a = FakeDiscoverySource(), b = FakeDiscoverySource()
        let agg = CameraDiscoverer(sources: [a, b], expiry: 30, sweepInterval: 60)
        try await agg.start()
        defer { Task { await agg.stop() } }
        a.emit([cam("bonjour:EOS R5", vendor: .canon), cam("bonjour:LUMIX", vendor: .panasonic)])
        try await Task.sleep(nanoseconds: 150_000_000)
        b.emit([cam("bonjour:EOS R5", vendor: .canon, host: "192.168.1.6")])
        try await Task.sleep(nanoseconds: 150_000_000)
        let list = agg.current
        XCTAssertEqual(list.count, 2, "\(list)")
        let eos = try XCTUnwrap(list.first { $0.id == "bonjour:EOS R5" })
        XCTAssertEqual(eos.host, "192.168.1.6", "later sighting refreshes the address")
        XCTAssertEqual(eos.details["controllable"], "true")
        XCTAssertEqual(list.first { $0.id == "bonjour:LUMIX" }?.details["controllable"], "false")
        XCTAssertEqual(list.first?.id, "bonjour:EOS R5", "controllable cameras sort first")
        XCTAssertTrue(a.started && b.started)
    }

    func testExpiresStaleEntries() async throws {
        let a = FakeDiscoverySource()
        let agg = CameraDiscoverer(sources: [a], expiry: 0.3, sweepInterval: 0.1)
        try await agg.start()
        defer { Task { await agg.stop() } }
        a.emit([cam("x", vendor: .nikon)])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(agg.current.count, 1)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(agg.current.count, 0)
    }

    func testManualEntriesAndStreamUpdates() async throws {
        let agg = CameraDiscoverer(sources: [], expiry: 0.2, sweepInterval: 0.1)
        try await agg.start()
        defer { Task { await agg.stop() } }
        var it = agg.cameras.makeAsyncIterator()
        _ = await it.next()
        agg.addManual(host: "192.168.1.77", vendor: .sony)
        let list = await withTimeout(seconds: 3) { await it.next() ?? [] }
        XCTAssertEqual(list?.count, 1)
        let m = try XCTUnwrap(list?.first)
        XCTAssertEqual(m.method, .manual)
        XCTAssertEqual(m.id, "manual:192.168.1.77:15740")
        XCTAssertEqual(m.port, 15740)
        XCTAssertEqual(m.transport, .ptpip)
        XCTAssertEqual(m.details["controllable"], "true")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(agg.current.count, 1, "manual entries never expire")
        agg.addManual(host: "192.168.0.1", port: 80, vendor: .ricoh)
        XCTAssertEqual(agg.current.first { $0.vendor == .ricoh }?.transport, .ricohHTTP)
        agg.removeManual(id: m.id)
        XCTAssertEqual(agg.current.count, 1)
    }

    func testSourceStartFailureIsRecordedNotFatal() async throws {
        let bad = FakeDiscoverySource()
        bad.failStart = ChannelError.connectFailed("bind", 98)
        let good = FakeDiscoverySource()
        let agg = CameraDiscoverer(sources: [bad, good], expiry: 30, sweepInterval: 60)
        try await agg.start()
        good.emit([cam("ok", vendor: .fujifilm)])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(agg.current.count, 1)
        XCTAssertEqual(agg.lastErrors.count, 1)
        XCTAssertTrue(agg.lastErrors.values.first?.contains("bind") ?? false)
        await agg.stop()
        XCTAssertTrue(bad.stopped && good.stopped)
        XCTAssertEqual(agg.current.count, 0)
    }

    func testDefaultSourcesConstruct() {
        let agg = CameraDiscoverer()
        XCTAssertEqual(agg.expiry, 30)
        XCTAssertEqual(agg.current.count, 0)
    }
}

final class SSIDTests: XCTestCase {
    func testCameraNetworkHints() {
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("EOSR5_123-456_Canon0A"), .canon)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("Canon EOS R6"), .canon)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("Nikon Z 6_2"), .nikon)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("DIRECT-xyz:ILCE-7M4"), .sony)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("FUJIFILM-X-T5-ABCD"), .fujifilm)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("GR_ABC123"), .ricoh)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("RICOH GR IIIx"), .ricoh)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("Leica SL2-S"), .leica)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("OM-1-ABC"), .olympus)
        XCTAssertEqual(CameraWiFiHints.looksLikeCameraNetwork("LUMIX-S5II"), .panasonic)
        XCTAssertNil(CameraWiFiHints.looksLikeCameraNetwork("HomeWiFi-5G"))
        XCTAssertNil(CameraWiFiHints.looksLikeCameraNetwork(""))
    }

    func testProviders() async {
        let s = StaticSSIDProvider(ssid: "GR_1234", state: .authorized)
        let ssid = await s.currentSSID()
        XCTAssertEqual(ssid, "GR_1234")
        let denied = StaticSSIDProvider(ssid: "GR_1234", state: .denied)
        let none = await denied.currentSSID()
        XCTAssertNil(none)
        #if !canImport(Darwin)
        let m = CoreLocationSSIDMonitor()
        let state = await m.authorizationState
        XCTAssertEqual(state, .unavailable)
        await m.requestAuthorization()
        let current = await m.currentSSID()
        XCTAssertNil(current)
        #endif
    }
}
