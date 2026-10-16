import XCTest
@testable import TetherCore

final class CubeLUTTests: XCTestCase {
    func testIdentityRoundTripAndSampling() throws {
        let id = CubeLUT.identity(size: 9)
        let text = id.serialized()
        XCTAssertTrue(text.contains("LUT_3D_SIZE 9"))
        let parsed = try CubeLUT(parsing: text)
        XCTAssertEqual(parsed.size, 9)
        XCTAssertEqual(parsed.title, "Identity")
        for v: Float in [0, 0.1, 0.37, 0.5, 0.99, 1] {
            let s = parsed.sample(SIMD3(v, v / 2, 1 - v))
            XCTAssertEqual(s.x, v, accuracy: 1e-5)
            XCTAssertEqual(s.y, v / 2, accuracy: 1e-5)
            XCTAssertEqual(s.z, 1 - v, accuracy: 1e-5)
        }
    }

    func testParseRejectsBadInput() {
        XCTAssertThrowsError(try CubeLUT(parsing: "TITLE x\n0 0 0\n"))
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n"))
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0\n" + String(repeating: "0 0 0\n", count: 7)))
    }

    func testBlendAndApply() throws {
        // A LUT that inverts everything.
        var t = [Float]()
        for b in 0 ..< 2 { for g in 0 ..< 2 { for r in 0 ..< 2 { t += [1 - Float(r), 1 - Float(g), 1 - Float(b)] } } }
        let inv = try CubeLUT(size: 2, title: "Invert", table: t)
        XCTAssertEqual(inv.sample(SIMD3(0.25, 0.5, 1)).x, 0.75, accuracy: 1e-5)
        let half = inv.blended(strength: 0.5)
        XCTAssertEqual(half.sample(SIMD3(0, 0, 0)).x, 0.5, accuracy: 1e-5)
        var px: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255]
        inv.apply(toRGBA8: &px)
        XCTAssertEqual(px, [255, 255, 255, 255, 0, 0, 0, 255])
        XCTAssertEqual(inv.colorCubeData.count, 8 * 4 * 4)
    }

    func testLookStackNeutral() {
        XCTAssertTrue(LookStack().isNeutral)
        XCTAssertTrue(LookStack(lookID: "neutral").isNeutral)
        XCTAssertTrue(LookStack(lookID: "film", strength: 0).isNeutral)
        XCTAssertFalse(LookStack(lookID: "film", strength: 0.5).isNeutral)
        XCTAssertEqual(LookStack(lookID: "x", strength: 7).strength, 1)
    }

    func testResolverUsesCacheThenFetch() async throws {
        let store = try SessionStore.inMemory()
        let desc = LookDescriptor(id: "film", name: "Film", family: "film", sha256: "abc", cubeURL: "/v1/looks/film.cube")
        try store.saveLook(desc, cube: nil)
        let counter = Counter()
        let resolver = LookResolver(store: store) { _ in
            counter.increment()
            return CubeLUT.identity(size: 2).serialized().data(using: .utf8)!
        }
        let a = try await resolver.lut(for: LookStack(lookID: "film"))
        let b = try await resolver.lut(for: LookStack(lookID: "film", strength: 0.5))
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertEqual(counter.value, 1)
        XCTAssertNotNil(try store.cube(for: "film"))
        let none = try await resolver.lut(for: .none)
        XCTAssertNil(none)
    }
}

final class StoreTests: XCTestCase {
    func testSessionsAndCapturesPersist() throws {
        let store = try SessionStore.inMemory()
        var s = ShootSession(name: "Studio A", destination: .host)
        try store.save(s)
        XCTAssertEqual(try store.sessions().count, 1)
        XCTAssertEqual(try store.session(s.id)?.destination, .host)

        var c = CaptureItem(sessionID: s.id, sequence: 1, handle: 0x10, filename: "IMG_0001.CR3", kind: .raw, bytes: 100, source: .usb)
        try store.save(c)
        var j = CaptureItem(sessionID: s.id, sequence: 2, handle: 0x11, filename: "IMG_0001.JPG", kind: .jpeg, bytes: 50, source: .usb)
        j.state = .ready; j.flag = .pick; j.rating = 4
        try store.save(j)
        XCTAssertEqual(try store.captures(in: s.id).map(\.filename), ["IMG_0001.CR3", "IMG_0001.JPG"])
        XCTAssertEqual(j.pairKey, c.pairKey)
        XCTAssertEqual(try store.nextSequence(in: s.id), 3)
        let counts = try store.counts(in: s.id)
        XCTAssertEqual(counts.total, 2); XCTAssertEqual(counts.ready, 1); XCTAssertEqual(counts.picks, 1); XCTAssertEqual(counts.rated, 1)

        c.state = .downloading(received: 10, total: 100)
        try store.save(c)
        XCTAssertEqual(try store.capture(c.id)?.state, .downloading(received: 10, total: 100))

        // Recovery: active sessions become interrupted on relaunch.
        try store.markInterruptedSessions()
        XCTAssertEqual(try store.interruptedSessions().first?.status, .interrupted)
        s.status = .ended
        try store.save(s)
        XCTAssertTrue(try store.interruptedSessions().isEmpty)

        try store.deleteSession(s.id)
        XCTAssertTrue(try store.captures(in: s.id).isEmpty, "cascade delete")
    }

    func testExportJobsLooksSettingsAndCameras() throws {
        let store = try SessionStore.inMemory()
        let job = ExportJob(sessionID: "s", destination: .photos, options: ExportOptions(), look: .none,
                            items: [ExportJob.Item(id: "a", filename: "a.jpg", kind: .jpeg, bytes: 1)])
        try store.save(job)
        XCTAssertEqual(try store.pendingExportJobs().count, 1)
        var done = job; done.status = .completed
        try store.save(done)
        XCTAssertEqual(try store.pendingExportJobs().count, 0)
        XCTAssertEqual(try store.exportJobs(sessionID: "s").count, 1)

        store.setSetting("cloud.url", "http://x")
        XCTAssertEqual(store.setting("cloud.url"), "http://x")
        store.setSetting("cloud.url", nil)
        XCTAssertNil(store.setting("cloud.url"))

        let cam = CameraIdentity(id: "canon-1", vendor: .canon, manufacturer: "Canon", model: "EOS R5", serialNumber: "1", firmware: "1.8", transport: .ptpip, capabilities: [.remoteCapture])
        try store.rememberCamera(cam, host: "192.168.1.2")
        try store.rememberCamera(cam, host: nil)
        let known = try store.knownCameras()
        XCTAssertEqual(known.count, 1)
        XCTAssertEqual(known[0].host, "192.168.1.2", "nil host keeps the previous one")

        let d = StoredFTPDestination(name: "Studio NAS", host: "10.0.0.5", username: "brady")
        try store.save(d)
        XCTAssertEqual(try store.ftpDestinations().first?.passwordKeychainKey, "ftp.\(d.id)")
    }
}

final class CacheProxyTests: XCTestCase {
    func makeCache() -> CaptureCacheProxy {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-tests-\(UUID().uuidString)")
        return CaptureCacheProxy(storageRoot: dir, memoryBudget: 1024)
    }

    func testPathsAreValidatedAndRelative() throws {
        let cache = makeCache()
        XCTAssertThrowsError(try cache.url(for: "../etc/passwd"))
        XCTAssertThrowsError(try cache.url(for: "/abs"))
        XCTAssertThrowsError(try cache.url(for: "a//b"))
        XCTAssertNoThrow(try cache.url(for: "s/originals/a.jpg"))
        let s = ShootSession(name: "x")
        XCTAssertEqual(cache.originalPath(session: s, filename: "../../IMG.JPG"), "\(s.directoryName)/originals/IMG.JPG")
        XCTAssertEqual(cache.proxyPath(session: s, filename: "IMG_1.CR3"), "\(s.directoryName)/proxies/IMG_1.jpg")
    }

    func testStoreLoadCollisionAndLRU() throws {
        let cache = makeCache()
        let s = ShootSession(name: "x")
        let p1 = try cache.store(Data([1, 2, 3]), at: cache.originalPath(session: s, filename: "A.JPG"))
        let p2 = try cache.store(Data([4]), at: cache.originalPath(session: s, filename: "A.JPG"))
        XCTAssertNotEqual(p1, p2)
        XCTAssertTrue(p2.hasSuffix("A-1.JPG"))
        XCTAssertEqual(try cache.load(p1), Data([1, 2, 3]))
        XCTAssertEqual(cache.size(p2), 1)
        // Memory budget 1024 → a 300-byte file is cached, a 2 KiB one is not.
        _ = try cache.store(Data(repeating: 7, count: 2048), at: "\(s.directoryName)/originals/big.bin")
        XCTAssertLessThanOrEqual(cache.cachedBytes, 1024)
        XCTAssertEqual(cache.sessionBytes(s), 3 + 1 + 2048)
        cache.removeSession(s)
        XCTAssertFalse(cache.exists(p1))
        XCTAssertThrowsError(try cache.load(p1))
    }

    func testStreamingWriter() throws {
        let cache = makeCache()
        let w = try cache.writer(at: "s/originals/stream.bin")
        try w.append(Data([1, 2])); try w.append(Data([3]))
        try w.finish()
        XCTAssertEqual(try cache.load("s/originals/stream.bin"), Data([1, 2, 3]))
        XCTAssertFalse(cache.exists("s/originals/stream.bin.part"))
    }
}

final class TetherSessionTests: XCTestCase {
    func makeEnvironment() throws -> (ScriptedTransport, PTPEngine, SessionStore, CaptureCacheProxy) {
        let t = ScriptedTransport()
        let payload = Data.fakeJPEG(size: 5000)
        t.on(.getObjectInfo) { req in
            let info = PTPObjectInfo(objectFormat: .exifJPEG, objectCompressedSize: UInt32(payload.count), imagePixWidth: 600, imagePixHeight: 400,
                                     filename: "IMG_\(String(format: "%04d", req.parameters[0])).JPG", captureDate: "20261016T120000")
            return .ok(info.encoded)
        }
        t.on(.getPartialObject) { req in
            let off = Int(req.parameters[1]), want = Int(req.parameters[2])
            return .ok(payload[off ..< min(payload.count, off + want)])
        }
        t.on(.getDevicePropDesc) { req in
            let code = PTPDevicePropCode(UInt16(req.parameters[0]))
            return .ok(PTPDevicePropDesc(code: code, dataType: .uint16, isWritable: true, factoryDefault: .uint16(400), current: .uint16(400),
                                         form: .enumeration([.uint16(280), .uint16(400)])).encoded)
        }
        t.on(.initiateCapture) { _ in .ok() }
        let engine = PTPEngine(transport: t)
        let store = try SessionStore.inMemory()
        let cache = CaptureCacheProxy(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("tether-session-\(UUID().uuidString)"))
        return (t, engine, store, cache)
    }

    func testCaptureFlowDownloadsAndPersists() async throws {
        let (t, engine, store, cache) = try makeEnvironment()
        let info = try await engine.connect()
        let handler = GenericPTPHandler(engine: engine, info: info)
        var shoot = ShootSession(name: "Test", destination: .both)
        shoot.transport = .usb
        try store.save(shoot)
        let identity = CameraIdentity(info: info, transport: .usb, capabilities: handler.capabilities, fallbackID: "x")
        let session = TetherSession(session: shoot, identity: identity, handler: handler, engine: engine, store: store, cache: cache)
        try await session.start()
        var snap = await session.snapshot
        XCTAssertEqual(snap.status, .ready)
        XCTAssertFalse(snap.properties.isEmpty)

        try await session.capture()
        XCTAssertEqual(t.requests(for: .initiateCapture).count, 1)
        t.push(PTPEvent(code: .objectAdded, parameters: [0x21]))
        t.push(PTPEvent(code: .objectAdded, parameters: [0x21])) // duplicate (push + poll) is ignored

        var ready: CaptureItem?
        for await ev in session.events {
            if case .capture(let c) = ev, c.state.isReady { ready = c; break }
        }
        let item = try XCTUnwrap(ready)
        XCTAssertEqual(item.filename, "IMG_0033.JPG")
        XCTAssertEqual(item.kind, .jpeg)
        XCTAssertEqual(item.width, 600)
        XCTAssertEqual(item.bytes, 5000)
        XCTAssertNotNil(item.exposure?.aperture)
        XCTAssertEqual(try cache.load(item.relativePath!).count, 5000)
        XCTAssertEqual(try store.captures(in: shoot.id).count, 1)
        snap = await session.snapshot
        XCTAssertEqual(snap.selectedItemID, item.id, "show newest selects the new frame")
        XCTAssertEqual(snap.session.captureCount, 1)

        // Review state round-trips through the store and the pair.
        await session.rate(item.id, stars: 5)
        await session.flag(item.id, .pick)
        await session.label(item.id, .red)
        let stored = try XCTUnwrap(try store.capture(item.id))
        XCTAssertEqual(stored.rating, 5); XCTAssertEqual(stored.flag, .pick); XCTAssertEqual(stored.colorLabel, .red)
        await session.flag(item.id, .pick)
        XCTAssertEqual(try store.capture(item.id)?.flag, CaptureFlag.none, "toggling clears")

        // Keep current selection: a new frame does not steal focus.
        await session.setShowNewestCapture(false)
        t.push(PTPEvent(code: .objectAdded, parameters: [0x22]))
        for await ev in session.events { if case .capture(let c) = ev, c.state.isReady, c.handle == 0x22 { break } }
        snap = await session.snapshot
        XCTAssertEqual(snap.items.count, 2)
        XCTAssertEqual(snap.selectedItemID, item.id)

        await session.stop(ended: true)
        XCTAssertEqual(try store.session(shoot.id)?.status, .ended)
        let open = await engine.isSessionOpen
        XCTAssertFalse(open)
    }

    func testPropertyWriteAndDisconnect() async throws {
        let (t, engine, store, cache) = try makeEnvironment()
        t.on(.setDevicePropValue) { _ in .ok() }
        let info = try await engine.connect()
        let handler = GenericPTPHandler(engine: engine, info: info)
        let shoot = ShootSession(name: "Test")
        try store.save(shoot)
        let session = TetherSession(session: shoot, identity: nil, handler: handler, engine: engine, store: store, cache: cache)
        try await session.start()
        try await session.setProperty(.aperture, raw: .uint16(280))
        let snap = await session.snapshot
        XCTAssertEqual(snap.properties.first { $0.property == .aperture }?.display, "ƒ/2.8")
        await session.handle(.disconnected)
        let after = await session.snapshot
        XCTAssertEqual(after.status, .disconnected("The camera disconnected."))
        XCTAssertEqual(try store.session(shoot.id)?.status, .interrupted)
        do { try await session.capture(); XCTFail() } catch { XCTAssertEqual(error as? PTPError, .notConnected) }
    }

    func testFTPIngestWithoutCamera() async throws {
        let store = try SessionStore.inMemory()
        let cache = CaptureCacheProxy(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("tether-ftp-\(UUID().uuidString)"))
        var shoot = ShootSession(name: "FTP")
        shoot.transport = .ftpPush
        try store.save(shoot)
        let session = TetherSession(session: shoot, identity: nil, handler: nil, engine: nil, store: store, cache: cache)
        try await session.start()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DSC_0001.NEF")
        try Data(repeating: 1, count: 10).write(to: tmp)
        await session.ingestFile(at: tmp, from: "192.168.1.9")
        let snap = await session.snapshot
        XCTAssertEqual(snap.items.first?.kind, .raw)
        XCTAssertEqual(snap.items.first?.source, .ftpPush)
        XCTAssertTrue(snap.items.first?.state.isReady ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "moved into the session")
    }

    func testRecoveryRefetchesCardObjectsAndFailsSDRAMOnes() async throws {
        let (t, engine, store, cache) = try makeEnvironment()
        let shoot = ShootSession(name: "Recover")
        try store.save(shoot)
        // Left behind by a crash: one card object half-downloaded, one SDRAM object.
        try store.save(CaptureItem(sessionID: shoot.id, sequence: 1, handle: 0x55, filename: "IMG_0085.JPG", kind: .jpeg, bytes: 0,
                                   state: .downloading(received: 10, total: 100), source: .usb))
        try store.save(CaptureItem(sessionID: shoot.id, sequence: 2, handle: 0xFFFF_0001, filename: "sdram", kind: .jpeg, bytes: 0,
                                   state: .announced, source: .usb))
        let info = try await engine.connect()
        let session = TetherSession(session: shoot, identity: nil, handler: GenericPTPHandler(engine: engine, info: info), engine: engine, store: store, cache: cache)
        try await session.start()
        for await ev in session.events { if case .capture(let c) = ev, c.state.isReady { break } }
        let items = try store.captures(in: shoot.id)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.handle == 0x55 && $0.state.isReady && $0.filename == "IMG_0085.JPG" })
        XCTAssertTrue(items.contains { $0.handle == 0xFFFF_0001 && $0.state.isFailed })
        _ = t
    }
}

final class ExportQueueTests: XCTestCase {
    final class FakeSink: ExportSink, @unchecked Sendable {
        let lock = NSLock()
        var delivered: [(String, ExportDestination)] = []
        var failFor: Set<String> = []
        func deliver(fileURL: URL, item: ExportJob.Item, destination: ExportDestination) async throws -> String? {
            lock.lock(); defer { lock.unlock() }
            if failFor.contains(item.id) { throw ExportError.renderFailed("nope") }
            delivered.append((item.id, destination))
            return "local-\(item.id)"
        }
    }

    func testJobRunsPersistsAndRetries() async throws {
        let store = try SessionStore.inMemory()
        let cache = CaptureCacheProxy(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("tether-export-\(UUID().uuidString)"))
        let shoot = ShootSession(name: "Export")
        try store.save(shoot)
        var caps = [CaptureItem]()
        for i in 1 ... 3 {
            var c = CaptureItem(sessionID: shoot.id, sequence: i, handle: UInt32(i), filename: "IMG_\(i).JPG", kind: .jpeg, bytes: 3, source: .usb)
            c.relativePath = try cache.store(Data([1, 2, 3]), at: cache.originalPath(session: shoot, filename: c.filename))
            c.state = .ready
            try store.save(c)
            caps.append(c)
        }
        var raw = CaptureItem(sessionID: shoot.id, sequence: 4, handle: 4, filename: "IMG_1.CR3", kind: .raw, bytes: 3, source: .usb)
        raw.state = .ready
        try store.save(raw)
        caps.append(raw)

        let sink = FakeSink()
        sink.failFor = [caps[1].id]
        let queue = ExportQueue(store: store, cache: cache, sink: sink, looks: LookResolver(store: store))
        let job = await queue.makeJob(session: shoot, captures: caps, destination: .photos, options: ExportOptions(includeRAW: false), look: .none)
        XCTAssertEqual(job.items.count, 3, "RAW excluded")
        try await queue.enqueue(job)

        var finished: ExportJob?
        for await ev in queue.events { if case .finished(let j) = ev { finished = j; break } }
        let f = try XCTUnwrap(finished)
        XCTAssertEqual(f.status.key, "failed")
        XCTAssertEqual(f.failedItems.count, 1)
        XCTAssertEqual(sink.delivered.count, 2)
        XCTAssertEqual(try store.exportJobs(sessionID: shoot.id).first?.status.key, "failed")

        sink.failFor = []
        try await queue.retry(job.id)
        for await ev in queue.events { if case .finished(let j) = ev { finished = j; break } }
        XCTAssertEqual(finished?.status.key, "completed")
        XCTAssertEqual(sink.delivered.count, 3, "only the failed item re-ran")
        XCTAssertEqual(finished?.progress, 1)
    }
}

final class USBContainerTests: XCTestCase {
    func testCommandResponseEventFraming() throws {
        let cmd = PTPUSBContainer.command(.getObjectInfo, transactionID: 9, parameters: [0x1234])
        let enc = cmd.encode()
        XCTAssertEqual(enc.count, 16)
        XCTAssertEqual([UInt8](enc.prefix(4)), [16, 0, 0, 0])
        XCTAssertEqual(try PTPUSBContainer(parsing: enc), cmd)
        var b = ByteBuffer(); b.write(UInt32(16)); b.write(UInt16(3)); b.write(UInt16(0x2001)); b.write(UInt32(9)); b.write(UInt32(7))
        let resp = try PTPUSBContainer(parsing: b.data).asResponse!
        XCTAssertEqual(resp.code, .ok); XCTAssertEqual(resp.parameters, [7]); XCTAssertEqual(resp.transactionID, 9)
        var e = ByteBuffer(); e.write(UInt32(16)); e.write(UInt16(4)); e.write(UInt16(0x4002)); e.write(UInt32(0)); e.write(UInt32(0x42))
        let ev = try PTPUSBContainer(parsing: e.data).asEvent
        XCTAssertEqual(ev?.code, .objectAdded)
        XCTAssertEqual(ev?.parameters, [0x42])
        XCTAssertThrowsError(try PTPUSBContainer(parsing: Data([1, 2])))
    }

    func testAuthorizationAndCandidates() {
        XCTAssertTrue(USBAuthorizationState(control: .notRequired, contents: .granted).canSendPTP)
        XCTAssertFalse(USBAuthorizationState(control: .denied, contents: .granted).canSendPTP)
        let c = USBCameraCandidate(id: "u", name: "ILCE-7M4", usbVendorID: 0x054C, usbProductID: 0x0E79, serialNumber: nil)
        XCTAssertEqual(c.vendorGuess, .sony)
        XCTAssertEqual(USBCameraCandidate(id: "u", name: "?", usbVendorID: 0x1234, usbProductID: 1, serialNumber: nil).vendorGuess, .generic)
    }
}

final class DiagnosticsTests: XCTestCase {
    func testWiredChecklistStopsAtFirstFailure() async {
        let probes = WiredDiagnostics.Probes(
            deviceOnBus: { nil },
            authorization: { USBAuthorizationState(control: .granted, contents: .granted) },
            openSession: { .success(()) },
            deviceInfo: { .success(ScriptedTransport.genericInfo) },
            battery: { 80 }, powerSource: { nil })
        let report = await DiagnosticRunner(checks: WiredDiagnostics.checks(probes)).run()
        XCTAssertTrue(report.checks[0].outcome.isFailure)
        XCTAssertEqual(report.checks.filter { if case .skipped = $0.outcome { return true }; return false }.count, 4)
        XCTAssertEqual(report.firstFailure?.id, "bus")
        XCTAssertTrue(report.shareText.contains("✗ Camera on the cable"))
    }

    func testWiredChecklistPasses() async {
        let probes = WiredDiagnostics.Probes(
            deviceOnBus: { USBCameraCandidate(id: "1", name: "EOS R5", usbVendorID: 0x04A9, usbProductID: 1, serialNumber: "s") },
            authorization: { USBAuthorizationState(control: .notRequired, contents: .granted) },
            openSession: { .success(()) },
            deviceInfo: { .success(ScriptedTransport.genericInfo) },
            battery: { 15 }, powerSource: { "USB-C PD" })
        let report = await DiagnosticRunner(checks: WiredDiagnostics.checks(probes)).run()
        XCTAssertNil(report.firstFailure)
        XCTAssertEqual(report.verdict, "Working, with warnings")
        XCTAssertTrue(report.checks[0].outcome.detail.contains("Canon"))
    }

    func testWirelessChecklist() async {
        let probes = WirelessDiagnostics.Probes(ssid: { "EOS-R5_Canon0A" }, localAddresses: { ["169.254.1.1", "192.168.1.5"] },
                                                reachable: { _, _ in true }, host: "192.168.1.1", port: 15740)
        let report = await DiagnosticRunner(checks: WirelessDiagnostics.checks(probes)).run()
        XCTAssertNil(report.firstFailure)
        XCTAssertTrue(report.checks[0].outcome.detail.contains("Canon"))
        XCTAssertEqual(report.checks[1].outcome.detail, "192.168.1.5")
    }
}

final class LookDescriptorTests: XCTestCase {
    func testLookDescriptorDecodesServerShape() throws {
        let json = #"{"id":"film-warm","name":"Film Warm","family":"film","version":1,"size":33,"sha256":"ab","cube_url":"/v1/looks/film-warm.cube","hint":{"warmth":0.3,"contrast":0.1,"saturation":-0.05}}"#
        let d = try JSONDecoder().decode(LookDescriptor.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(d.cubeURL, "/v1/looks/film-warm.cube")
        XCTAssertEqual(d.hint?.warmth, 0.3)
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testStrategiesAndBackoff() {
        var usb = ShootSession(name: "a"); usb.transport = .usb
        let id = CameraIdentity(id: "c", vendor: .canon, manufacturer: "Canon", model: "R5", serialNumber: "S1", firmware: "1", transport: .usb, capabilities: [])
        var p = ReconnectPolicy(session: usb, identity: id, usbCandidateID: "dev-1", maxAttempts: 3)
        XCTAssertEqual(p.strategy, .waitForUSBDevice(candidateID: "dev-1", serial: "S1"))
        XCTAssertTrue(p.matches(USBCameraCandidate(id: "dev-1", name: "", usbVendorID: 0, usbProductID: 0, serialNumber: nil)))
        XCTAssertTrue(p.matches(USBCameraCandidate(id: "other", name: "", usbVendorID: 0, usbProductID: 0, serialNumber: "S1")))
        XCTAssertFalse(p.matches(USBCameraCandidate(id: "other", name: "", usbVendorID: 0, usbProductID: 0, serialNumber: "S2")))
        XCTAssertEqual(p.nextDelay(), 0.5); XCTAssertEqual(p.nextDelay(), 1); XCTAssertEqual(p.nextDelay(), 2); XCTAssertNil(p.nextDelay())

        var wifi = ShootSession(name: "b"); wifi.transport = .ptpip; wifi.lastHost = "192.168.1.4"
        XCTAssertEqual(ReconnectPolicy(session: wifi, identity: nil).strategy, .redial(host: "192.168.1.4", port: 15740))
        wifi.lastHost = nil
        if case .askUser = ReconnectPolicy(session: wifi, identity: nil).strategy {} else { XCTFail() }
        var ftp = ShootSession(name: "c"); ftp.transport = .ftpPush
        XCTAssertEqual(ReconnectPolicy(session: ftp, identity: nil).strategy, .ftpPassive)
        var ricoh = ShootSession(name: "d"); ricoh.transport = .ricohHTTP
        XCTAssertEqual(ReconnectPolicy(session: ricoh, identity: nil).strategy, .redial(host: "192.168.0.1", port: 80))
    }
}
