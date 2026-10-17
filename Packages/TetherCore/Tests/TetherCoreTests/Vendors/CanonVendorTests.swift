import XCTest
@testable import TetherCore

final class CanonVendorTests: XCTestCase {
    // MARK: Payload builders

    static func record(type: UInt32, body: [UInt8]) -> [UInt8] {
        var b = ByteBuffer()
        b.write(UInt32(8 + body.count)); b.write(type); b.write(body)
        return b.bytes
    }

    static func objectAddedEx(handle: UInt32, storage: UInt32, format: UInt16, size: UInt32, name: String) -> [UInt8] {
        var body = ByteBuffer()
        body.write(handle)            // 0x08
        body.write(storage)           // 0x0C
        body.write(format)            // 0x10
        body.write(UInt16(0)); body.write(UInt32(0)); body.write(UInt32(0)) // pad to 0x1C
        body.write(size)              // 0x1C
        body.write(UInt32(0x1234))    // 0x20 parent
        body.write(UInt32(0))         // 0x24 pad
        body.write(Array(name.utf8)); body.write(UInt8(0)) // 0x28 name
        return record(type: CanonCodes.Event.objectAddedEx, body: body.bytes)
    }

    static func propValueChanged(_ prop: UInt32, _ value: UInt32) -> [UInt8] {
        var b = ByteBuffer(); b.write(prop); b.write(value)
        return record(type: CanonCodes.Event.propValueChanged, body: b.bytes)
    }

    static func availList(_ prop: UInt32, _ values: [UInt32]) -> [UInt8] {
        var b = ByteBuffer(); b.write(prop); b.write(UInt32(3)); b.write(UInt32(values.count)); values.forEach { b.write($0) }
        return record(type: CanonCodes.Event.availListChanged, body: b.bytes)
    }

    static let terminator: [UInt8] = [8, 0, 0, 0, 0, 0, 0, 0]

    static func initialDump() -> Data {
        var bytes = [UInt8]()
        bytes += propValueChanged(CanonCodes.Prop.aperture, 0x28)
        bytes += propValueChanged(CanonCodes.Prop.shutterSpeed, 0x78)
        bytes += propValueChanged(CanonCodes.Prop.iso, 0x48)
        bytes += propValueChanged(CanonCodes.Prop.expCompensation, 0x03)
        bytes += propValueChanged(CanonCodes.Prop.whiteBalance, 1)
        bytes += propValueChanged(CanonCodes.Prop.batteryPower, 2)
        bytes += propValueChanged(CanonCodes.Prop.captureDestination, CanonCodes.Prop.destinationCard)
        bytes += availList(CanonCodes.Prop.aperture, [0x20, 0x28, 0x30])
        bytes += availList(CanonCodes.Prop.shutterSpeed, [0x70, 0x78, 0x80])
        bytes += availList(CanonCodes.Prop.iso, [0x48, 0x50])
        bytes += terminator
        return Data(bytes)
    }

    // MARK: Tests

    func testCapabilitiesDeriveFromOperations() {
        let t = ScriptedTransport(deviceInfo: VendorFixtures.canon)
        let h = CanonHandler(engine: PTPEngine(transport: t), info: VendorFixtures.canon)
        XCTAssertEqual(h.vendor, .canon)
        for c in [CameraCapabilities.remoteCapture, .sdramCapture, .cardCapture, .liveView, .propertyControl, .partialTransfer, .autofocus, .thumbnails] {
            XCTAssertTrue(h.capabilities.contains(c), "\(c)")
        }
        XCTAssertFalse(h.capabilities.contains(.rating))
        let old = CanonHandler(engine: PTPEngine(transport: t), info: VendorFixtures.canonOld)
        XCTAssertTrue(old.capabilities.contains(.remoteCapture))
        XCTAssertFalse(old.capabilities.contains(.liveView))
        XCTAssertFalse(old.capabilities.contains(.autofocus))
    }

    func testPrepareSendsRemoteModeEventModeThenGetEvent() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        rig.transport.okAll()
        rig.transport.on(CanonCodes.Op.getEvent) { _ in .ok(Self.initialDump()) }
        let h = CanonHandler(engine: rig.engine, info: rig.info)
        try await h.prepare()
        XCTAssertEqual(rig.codes, [CanonCodes.Op.setRemoteMode, CanonCodes.Op.setEventMode, CanonCodes.Op.getEvent])
        XCTAssertEqual(rig.requests[0].parameters, [1])
        XCTAssertEqual(rig.requests[1].parameters, [1])
        XCTAssertEqual(h.values[CanonCodes.Prop.aperture], 0x28)
        XCTAssertEqual(h.available[CanonCodes.Prop.aperture], [0x20, 0x28, 0x30])
    }

    func testCaptureTwoStageWithAndWithoutAF() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        rig.transport.okAll()
        let h = CanonHandler(engine: rig.engine, info: rig.info)
        try await h.capture(autofocus: true)
        // Queued events are drained first (EOS bodies report busy otherwise).
        XCTAssertEqual(rig.codes, [CanonCodes.Op.getEvent, CanonCodes.Op.remoteReleaseOn, CanonCodes.Op.remoteReleaseOn,
                                   CanonCodes.Op.remoteReleaseOff, CanonCodes.Op.remoteReleaseOff])
        XCTAssertEqual(rig.requests.map(\.parameters), [[], [1, 0], [2, 0], [2], [1]])
        let rig2 = try await VendorRig(VendorFixtures.canon)
        rig2.transport.okAll()
        try await CanonHandler(engine: rig2.engine, info: rig2.info).capture(autofocus: false)
        XCTAssertEqual(rig2.requests.map(\.parameters), [[], [3, 0], [3]])
    }

    func testRefusedAutofocusFallsBackToFiringWithoutAF() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        rig.transport.okAll()
        rig.transport.on(CanonCodes.Op.remoteReleaseOn) { req in req.parameters == [1, 0] ? .fail(.deviceBusy) : .ok() }
        try await CanonHandler(engine: rig.engine, info: rig.info).capture(autofocus: true)
        let presses = rig.requests.filter { $0.code == CanonCodes.Op.remoteReleaseOn || $0.code == CanonCodes.Op.remoteReleaseOff }
        XCTAssertEqual(presses.last?.code, CanonCodes.Op.remoteReleaseOff)
        XCTAssertEqual(presses.last?.parameters, [3], "fired without AF and let go")
        XCTAssertTrue(presses.contains { $0.code == CanonCodes.Op.remoteReleaseOff && $0.parameters == [1] }, "the refused half-press is released")
    }

    func testCameraThatWillNotFireExplainsWhy() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        rig.transport.okAll()
        rig.transport.on(CanonCodes.Op.remoteReleaseOn) { _ in .fail(.deviceBusy) }
        do {
            try await CanonHandler(engine: rig.engine, info: rig.info).capture(autofocus: false)
            XCTFail("should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("lens"), "plain explanation, not DeviceBusy")
        }
        XCTAssertEqual(CanonCodes.display(prop: CanonCodes.Prop.aperture, value: 0), "—")
    }

    func testCaptureFallsBackToRemoteRelease() async throws {
        let rig = try await VendorRig(VendorFixtures.canonOld)
        rig.transport.okAll()
        try await CanonHandler(engine: rig.engine, info: rig.info).capture(autofocus: true)
        XCTAssertEqual(rig.codes, [CanonCodes.Op.remoteRelease])
    }

    func testGetEventParsingYieldsObjectAddedAndPropertyChanges() throws {
        let t = ScriptedTransport(deviceInfo: VendorFixtures.canon)
        let h = CanonHandler(engine: PTPEngine(transport: t), info: VendorFixtures.canon)
        var bytes = Self.objectAddedEx(handle: 0x0040_0001, storage: 0x0002_0001, format: 0x3801, size: 123_456, name: "IMG_0042.JPG")
        bytes += Self.propValueChanged(CanonCodes.Prop.iso, 0x50)
        bytes += Self.availList(CanonCodes.Prop.iso, [0x48, 0x50, 0x58])
        bytes += Self.record(type: CanonCodes.Event.cameraStatusChanged, body: [1, 0, 0, 0])
        bytes += Self.terminator
        bytes += Self.propValueChanged(CanonCodes.Prop.iso, 0x99) // after the terminator: ignored
        let events = h.ingest(Data(bytes))
        XCTAssertEqual(events.count, 4)
        guard case .objectAdded(let obj) = events[0] else { return XCTFail("expected objectAdded, got \(events[0])") }
        XCTAssertEqual(obj.handle, 0x0040_0001)
        XCTAssertEqual(obj.storageID, 0x0002_0001)
        XCTAssertEqual(obj.info?.filename, "IMG_0042.JPG")
        XCTAssertEqual(obj.info?.objectCompressedSize, 123_456)
        XCTAssertEqual(obj.info?.objectFormat, .exifJPEG)
        XCTAssertFalse(obj.inSDRAM)
        XCTAssertEqual(events[1], .propertyChanged(.iso))
        XCTAssertEqual(events[2], .propertyChanged(.iso))
        XCTAssertEqual(events[3], .cameraBusy(true))
        XCTAssertEqual(h.values[CanonCodes.Prop.iso], 0x50)
        XCTAssertEqual(h.available[CanonCodes.Prop.iso], [0x48, 0x50, 0x58])
    }

    static func transferRequest(handle: UInt32, format: UInt16, size: UInt32, name: String) -> [UInt8] {
        var body = ByteBuffer()
        body.write(handle)            // 0x08
        body.write(format)            // 0x0C
        body.write(UInt16(0)); body.write(UInt32(0)) // pad to 0x14
        body.write(size)              // 0x14
        body.write(UInt32(0)) // 0x18 pad
        body.write(Array(name.utf8) + [0])
        return record(type: CanonCodes.Event.requestObjectTransfer, body: body.bytes)
    }

    func testTransferRequestBecomesSDRAMObjectWithSizeAndName() {
        let t = ScriptedTransport(deviceInfo: VendorFixtures.canon)
        let h = CanonHandler(engine: PTPEngine(transport: t), info: VendorFixtures.canon)
        let events = h.ingest(Data(Self.transferRequest(handle: 0x9000_0001, format: 0x3801, size: 8_765_432, name: "IMG_0100.JPG") + Self.terminator))
        XCTAssertEqual(events.count, 1)
        guard case .objectAdded(let obj) = events[0] else { return XCTFail("expected objectAdded, got \(events)") }
        XCTAssertEqual(obj.handle, 0x9000_0001)
        XCTAssertTrue(obj.inSDRAM)
        XCTAssertEqual(obj.info?.objectCompressedSize, 8_765_432)
        XCTAssertEqual(obj.info?.filename, "IMG_0100.JPG")
        XCTAssertEqual(obj.info?.objectFormat, .exifJPEG)
    }

    func testNamelessTransferRequestGetsANameFromItsFormat() {
        let t = ScriptedTransport(deviceInfo: VendorFixtures.canon)
        let h = CanonHandler(engine: PTPEngine(transport: t), info: VendorFixtures.canon)
        var body = ByteBuffer()
        body.write(UInt32(0x0040_0012)); body.write(UInt16(0xB108)); body.write(UInt16(0)); body.write(UInt32(0))
        body.write(UInt32(45_000_000)); body.write(UInt32(0)); body.write(UInt8(0))
        let events = h.ingest(Data(Self.record(type: CanonCodes.Event.requestObjectTransfer64LFN, body: body.bytes) + Self.terminator))
        guard case .objectAdded(let obj)? = events.first else { return XCTFail("expected objectAdded, got \(events)") }
        XCTAssertTrue(obj.inSDRAM)
        XCTAssertEqual(obj.info?.objectCompressedSize, 45_000_000)
        XCTAssertEqual(obj.info?.filename, "IMG_0012.CR3")
    }

    func testSDRAMObjectIsFlaggedWhenStorageIsHost() {
        let rec = CanonEventRecord.parse(Data(Self.objectAddedEx(handle: 7, storage: 0, format: 0x3801, size: 10, name: "A.JPG") + Self.terminator))
        XCTAssertEqual(rec.count, 1)
        let obj = CanonHandler.objectAdded(rec[0], is64: false, destination: .card)
        XCTAssertEqual(obj?.inSDRAM, true)
    }

    func testPropertyReadDisplayAndWriteRoundTrip() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        rig.transport.okAll()
        rig.transport.on(CanonCodes.Op.getEvent) { _ in .ok(Self.initialDump()) }
        let h = CanonHandler(engine: rig.engine, info: rig.info)
        try await h.prepare()
        let props = try await h.readProperties([.aperture, .shutterSpeed, .iso, .exposureCompensation, .whiteBalance, .batteryLevel, .captureDestination])
        let byProp = Dictionary(uniqueKeysWithValues: props.map { ($0.property, $0) })
        XCTAssertEqual(byProp[.aperture]?.display, "ƒ/4")
        XCTAssertEqual(byProp[.aperture]?.choices.map(\.display), ["ƒ/2.8", "ƒ/4", "ƒ/5.6"])
        XCTAssertEqual(byProp[.shutterSpeed]?.display, "1/250")
        XCTAssertEqual(byProp[.shutterSpeed]?.choices.map(\.display), ["1/125", "1/250", "1/500"])
        XCTAssertEqual(byProp[.iso]?.display, "100")
        XCTAssertEqual(byProp[.exposureCompensation]?.display, "+1/3")
        XCTAssertEqual(byProp[.whiteBalance]?.display, "Daylight")
        XCTAssertEqual(byProp[.batteryLevel]?.display, "100%")
        XCTAssertEqual(byProp[.batteryLevel]?.isWritable, false)
        XCTAssertEqual(byProp[.captureDestination]?.choices.count, 3)
        // Write a choice's raw value straight back.
        let choice = byProp[.aperture]!.choices[0]
        try await h.writeProperty(.aperture, raw: choice.raw)
        let set = rig.transport.requests(for: CanonCodes.Op.setDevicePropValueEx).last!
        XCTAssertEqual([UInt8](set.dataOut!), [0x0C, 0, 0, 0, 0x01, 0xD1, 0, 0, 0x20, 0, 0, 0])
        XCTAssertEqual(h.values[CanonCodes.Prop.aperture], 0x20)
    }

    func testSetCaptureDestinationWritesEOSProperty() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        rig.transport.okAll()
        let h = CanonHandler(engine: rig.engine, info: rig.info)
        try await h.setCaptureDestination(.host)
        XCTAssertEqual(rig.requests.last?.dataOut, CanonHandler.setPropertyPayload(CanonCodes.Prop.captureDestination, CanonCodes.Prop.destinationHost))
        let old = CanonHandler(engine: rig.engine, info: VendorFixtures.canonOld)
        try await old.setCaptureDestination(.both) // old body lists 0x9107/0x9117 too
        await XCTAssertThrowsPTP(try await CanonHandler(engine: rig.engine, info: VendorFixtures.info("Canon", "EOS", ops: [0x9114, 0x910F])).setCaptureDestination(.host)) { e in
            XCTAssertTrue("\(e)".contains("memory"))
        }
    }

    func testSDRAMFetchUsesStandardPartialObjectThenTransferComplete() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        let payload = Data((0 ..< 3000).map { UInt8($0 & 0xFF) })
        rig.transport.on(.getPartialObject) { req in
            let off = Int(req.parameters[1]), want = Int(req.parameters[2])
            return .ok(payload[off ..< min(payload.count, off + want)])
        }
        rig.transport.on(CanonCodes.Op.transferComplete) { _ in .ok() }
        let h = CanonHandler(engine: rig.engine, info: rig.info)
        let info = PTPObjectInfo(storageID: 0, objectFormat: .exifJPEG, objectCompressedSize: UInt32(payload.count), filename: "IMG_0001.JPG")
        let (oi, data) = try await h.fetchObject(NewObject(handle: 0x42, storageID: 0, info: info, inSDRAM: true), progress: nil)
        XCTAssertEqual(data, payload)
        XCTAssertEqual(oi.filename, "IMG_0001.JPG")
        XCTAssertEqual(rig.transport.requests(for: .getPartialObject).first?.parameters, [0x42, 0, 3000])
        XCTAssertEqual(rig.transport.requests(for: CanonCodes.Op.getPartialObjectEx).count, 0)
        XCTAssertEqual(rig.codes.last, CanonCodes.Op.transferComplete)
        XCTAssertEqual(rig.requests.last?.parameters, [0x42])
    }

    func testFailedSDRAMFetchStillReleasesTheCamera() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        rig.transport.on(.getPartialObject) { _ in .ok(Data()) }
        rig.transport.on(CanonCodes.Op.transferComplete) { _ in .ok() }
        let h = CanonHandler(engine: rig.engine, info: rig.info)
        let info = PTPObjectInfo(storageID: 0, objectFormat: .exifJPEG, objectCompressedSize: 3000, filename: "IMG_0002.JPG")
        do {
            _ = try await h.fetchObject(NewObject(handle: 0x43, storageID: 0, info: info, inSDRAM: true), progress: nil)
            XCTFail("expected the empty read to fail")
        } catch {}
        XCTAssertEqual(rig.codes.last, CanonCodes.Op.transferComplete)
        XCTAssertEqual(rig.requests.last?.parameters, [0x43])
    }

    static let canonTouchAF = VendorFixtures.info("Canon Inc.", "Canon EOS R5m2",
        ops: [0x9114, 0x9115, 0x9116, 0x9110, 0x9128, 0x9129, 0x9107, 0x9117, 0x9153, 0x910F, 0x915B, 0x9154, 0x9160],
        extraStandardProps: false, vendorExtension: 0x0B)

    private func touchFocus(focusMode: UInt32) async throws -> [PTPOperationCode] {
        let rig = try await VendorRig(Self.canonTouchAF)
        rig.transport.okAll()
        let h = CanonHandler(engine: rig.engine, info: rig.info)
        h.ingest(Data(Self.propValueChanged(CanonCodes.Prop.focusMode, focusMode) + Self.terminator))
        try await h.focus(atNormalizedX: 0.5, y: 0.5)
        return rig.codes
    }

    func testOneShotTouchFocusIsNotCancelled() async throws {
        let codes = try await touchFocus(focusMode: 0)
        XCTAssertTrue(codes.contains(CanonCodes.Op.touchAfPosition))
        XCTAssertTrue(codes.contains(CanonCodes.Op.doAf))
        XCTAssertFalse(codes.contains(CanonCodes.Op.afCancel))
    }

    func testServoTouchFocusStopsAfterSettling() async throws {
        let codes = try await touchFocus(focusMode: CanonCodes.focusModeServo)
        XCTAssertEqual(codes.last, CanonCodes.Op.afCancel)
        XCTAssertLessThan(codes.firstIndex(of: CanonCodes.Op.doAf)!, codes.firstIndex(of: CanonCodes.Op.afCancel)!)
    }

    func testLiveViewSetsEvfAndExtractsJPEGRecord() async throws {
        let rig = try await VendorRig(VendorFixtures.canon)
        rig.transport.okAll()
        let jpeg = Data.fakeJPEG(size: 200)
        rig.transport.on(CanonCodes.Op.getViewFinderData) { _ in
            var b = ByteBuffer()
            b.write(UInt32(8 + 4)); b.write(UInt32(7)); b.write(UInt32(0xAAAA_AAAA)) // some other record
            b.write(UInt32(8 + jpeg.count)); b.write(UInt32(1)); b.write(jpeg)
            return .ok(b.data)
        }
        let h = CanonHandler(engine: rig.engine, info: rig.info)
        try await h.startLiveView(quality: .medium)
        XCTAssertEqual(rig.requests[0].dataOut, CanonHandler.setPropertyPayload(CanonCodes.Prop.evfMode, 1))
        XCTAssertEqual(rig.requests[1].dataOut, CanonHandler.setPropertyPayload(CanonCodes.Prop.evfOutputDevice, 2))
        let frame = try await h.nextLiveViewFrame()
        XCTAssertEqual(frame?.jpeg, jpeg)
        XCTAssertEqual(rig.transport.requests(for: CanonCodes.Op.getViewFinderData).first?.parameters, [0x0010_0000])
        await h.stopLiveView()
        XCTAssertEqual(rig.requests.last?.dataOut, CanonHandler.setPropertyPayload(CanonCodes.Prop.evfOutputDevice, 0))
    }

    func testValueTables() {
        XCTAssertEqual(CanonCodes.display(prop: CanonCodes.Prop.aperture, value: 0x20), "ƒ/2.8")
        XCTAssertEqual(CanonCodes.display(prop: CanonCodes.Prop.shutterSpeed, value: 0xA0), "1/8000")
        XCTAssertEqual(CanonCodes.display(prop: CanonCodes.Prop.shutterSpeed, value: 0x10), "30\"")
        XCTAssertEqual(CanonCodes.display(prop: CanonCodes.Prop.shutterSpeed, value: 0x0C), "Bulb")
        XCTAssertEqual(CanonCodes.display(prop: CanonCodes.Prop.iso, value: 0x00), "Auto")
        XCTAssertEqual(CanonCodes.display(prop: CanonCodes.Prop.iso, value: 0x80), "12800")
        XCTAssertEqual(CanonCodes.exposureCompensation(0xF8), "-1")
        XCTAssertEqual(CanonCodes.exposureCompensation(0x0D), "+1 2/3")
        XCTAssertEqual(CanonCodes.exposureCompensation(0xFC), "-1/2")
        XCTAssertEqual(CanonCodes.exposureCompensation(0), "0")
    }

    func testTranslatePushedEvents() async {
        let t = ScriptedTransport(deviceInfo: VendorFixtures.canon)
        let h = CanonHandler(engine: PTPEngine(transport: t), info: VendorFixtures.canon)
        let a = await h.translate(PTPEvent(code: PTPEventCode(UInt16(CanonCodes.Event.objectAddedEx)), parameters: [0x55]))
        XCTAssertEqual(a, .objectAdded(NewObject(handle: 0x55)))
        let p = await h.translate(PTPEvent(code: PTPEventCode(UInt16(CanonCodes.Event.propValueChanged)), parameters: [CanonCodes.Prop.shutterSpeed]))
        XCTAssertEqual(p, .propertyChanged(.shutterSpeed))
        let std = await h.translate(PTPEvent(code: .objectAdded, parameters: [0x66]))
        XCTAssertEqual(std, .objectAdded(NewObject(handle: 0x66)))
    }
}
