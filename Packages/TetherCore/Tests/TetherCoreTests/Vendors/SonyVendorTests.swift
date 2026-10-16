import XCTest
@testable import TetherCore

final class SonyVendorTests: XCTestCase {
    static func dump(focus: Int64 = 3, objectInMemory: UInt16 = 0, twoLists: Bool = true) -> Data {
        let settable: [PTPValue]? = twoLists ? [.uint32(1 << 16 | 125), .uint32(1 << 16 | 250)] : nil
        return SonyPropDesc.encodeAll([
            SonyPropDesc(code: .fNumber, dataType: .uint16, isWritable: true, factoryDefault: .uint16(280), current: .uint16(280),
                         form: .enumeration([.uint16(280), .uint16(400)]), settable: twoLists ? [.uint16(280), .uint16(400)] : nil),
            SonyPropDesc(code: SonyCodes.Prop.shutterSpeed, dataType: .uint32, isWritable: true, factoryDefault: .uint32(1 << 16 | 250), current: .uint32(1 << 16 | 250),
                         form: .enumeration([.uint32(1 << 16 | 125), .uint32(1 << 16 | 250), .uint32(1 << 16 | 500)]), settable: settable),
            SonyPropDesc(code: SonyCodes.Prop.iso, dataType: .uint32, isWritable: true, isEnabled: false, factoryDefault: .uint32(SonyCodes.Prop.isoAuto),
                         current: .uint32(SonyCodes.Prop.isoAuto), form: .enumeration([.uint32(SonyCodes.Prop.isoAuto), .uint32(100), .uint32(6400)]),
                         settable: twoLists ? [] : nil),
            SonyPropDesc(code: .exposureBiasCompensation, dataType: .int16, isWritable: true, factoryDefault: .int16(0), current: .int16(-700),
                         form: .range(min: .int16(-5000), max: .int16(5000), step: .int16(300))),
            SonyPropDesc(code: .whiteBalance, dataType: .uint16, isWritable: true, factoryDefault: .uint16(2), current: .uint16(0x8011),
                         form: .enumeration([.uint16(2), .uint16(4), .uint16(0x8011)]), settable: twoLists ? [.uint16(2), .uint16(4), .uint16(0x8011)] : nil),
            SonyPropDesc(code: SonyCodes.Prop.batteryLevel, dataType: .uint8, isWritable: false, factoryDefault: .uint8(0), current: .uint8(65), form: .none),
            SonyPropDesc(code: SonyCodes.Prop.focusFound, dataType: .uint8, isWritable: false, factoryDefault: .uint8(0), current: .uint8(UInt8(focus)), form: .none),
            SonyPropDesc(code: SonyCodes.Prop.objectInMemory, dataType: .uint16, isWritable: false, factoryDefault: .uint16(0), current: .uint16(objectInMemory), form: .none),
        ])
    }

    func testCapabilitiesDeriveFromSDIOOperations() {
        let t = ScriptedTransport(deviceInfo: VendorFixtures.sony)
        let h = SonyHandler(engine: PTPEngine(transport: t), info: VendorFixtures.sony)
        XCTAssertEqual(h.vendor, .sony)
        for c in [CameraCapabilities.remoteCapture, .sdramCapture, .cardCapture, .liveView, .propertyControl, .autofocus, .partialTransfer, .thumbnails] {
            XCTAssertTrue(h.capabilities.contains(c), "\(c)")
        }
        let ms = SonyHandler(engine: PTPEngine(transport: t), info: VendorFixtures.sonyMassStorage)
        XCTAssertFalse(ms.capabilities.contains(.remoteCapture))
        XCTAssertFalse(ms.capabilities.contains(.propertyControl))
    }

    func testPrepareRunsSDIOConnectSequence() async throws {
        let rig = try await VendorRig(VendorFixtures.sony)
        rig.transport.okAll()
        rig.transport.on(SonyCodes.Op.sdioGetAllExtDevicePropInfo) { _ in .ok(Self.dump()) }
        let h = SonyHandler(engine: rig.engine, info: rig.info)
        try await h.prepare()
        XCTAssertEqual(rig.codes, [SonyCodes.Op.sdioConnect, SonyCodes.Op.sdioConnect, SonyCodes.Op.sdioGetExtDeviceInfo, SonyCodes.Op.sdioConnect, SonyCodes.Op.sdioGetAllExtDevicePropInfo])
        XCTAssertEqual(rig.requests.prefix(4).map(\.parameters), [[1, 0, 0], [2, 0, 0], [0x12C], [3, 0, 0]])
    }

    func testPrepareRetriesExtDeviceInfoWithFallbackVersion() async throws {
        let rig = try await VendorRig(VendorFixtures.sony)
        rig.transport.okAll()
        rig.transport.on(SonyCodes.Op.sdioGetExtDeviceInfo) { req in req.parameters == [0x12C] ? .fail(.invalidParameter) : .ok() }
        rig.transport.on(SonyCodes.Op.sdioGetAllExtDevicePropInfo) { _ in .ok(Self.dump()) }
        try await SonyHandler(engine: rig.engine, info: rig.info).prepare()
        XCTAssertEqual(rig.transport.requests(for: SonyCodes.Op.sdioGetExtDeviceInfo).map(\.parameters), [[0x12C], [0xC8]])
    }

    func testPrepareWithoutSDIOThrowsGateMessage() async throws {
        let rig = try await VendorRig(VendorFixtures.sonyMassStorage)
        await XCTAssertThrowsPTP(try await SonyHandler(engine: rig.engine, info: rig.info).prepare()) { e in
            guard case .vendorGate(let msg) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(msg.contains("PC Remote"))
        }
    }

    func testCaptureHalfPressWaitsForFocusThenFullPressAndRelease() async throws {
        let rig = try await VendorRig(VendorFixtures.sony)
        rig.transport.okAll()
        rig.transport.on(SonyCodes.Op.sdioGetAllExtDevicePropInfo) { _ in .ok(Self.dump(focus: 3)) }
        let h = SonyHandler(engine: rig.engine, info: rig.info)
        try await h.capture(autofocus: true)
        let controls = rig.transport.requests(for: SonyCodes.Op.sdioControlDevice)
        XCTAssertEqual(controls.map(\.parameters), [[0xD2C1], [0xD2C2], [0xD2C2], [0xD2C1]])
        XCTAssertEqual(controls.map { [UInt8]($0.dataOut!) }, [[2, 0], [2, 0], [1, 0], [1, 0]])
        XCTAssertEqual(rig.codes[1], SonyCodes.Op.sdioGetAllExtDevicePropInfo) // the focus poll
        let rig2 = try await VendorRig(VendorFixtures.sony)
        rig2.transport.okAll()
        try await SonyHandler(engine: rig2.engine, info: rig2.info).capture(autofocus: false)
        XCTAssertEqual(rig2.requests.map(\.parameters), [[0xD2C2], [0xD2C2]])
    }

    func testCaptureGivesUpWaitingForFocusAfterTimeout() async throws {
        let rig = try await VendorRig(VendorFixtures.sony)
        rig.transport.okAll()
        rig.transport.on(SonyCodes.Op.sdioGetAllExtDevicePropInfo) { _ in .ok(Self.dump(focus: 1)) }
        let h = SonyHandler(engine: rig.engine, info: rig.info)
        h.focusTimeout = 0.15
        h.focusPollInterval = 0.05
        try await h.capture(autofocus: true)
        XCTAssertGreaterThanOrEqual(rig.transport.requests(for: SonyCodes.Op.sdioGetAllExtDevicePropInfo).count, 2)
        XCTAssertEqual(rig.transport.requests(for: SonyCodes.Op.sdioControlDevice).count, 4)
    }

    func testObjectInMemoryPollEmitsSDRAMObject() async throws {
        let rig = try await VendorRig(VendorFixtures.sony)
        let counter = Counter()
        rig.transport.on(SonyCodes.Op.sdioGetAllExtDevicePropInfo) { _ in
            counter.increment()
            return .ok(Self.dump(objectInMemory: counter.value == 1 ? 0 : 0x8001))
        }
        let h = SonyHandler(engine: rig.engine, info: rig.info)
        let first = try await h.pollEvents()
        XCTAssertFalse(first.contains(.objectAdded(NewObject(handle: SonyCodes.sdramHandle, inSDRAM: true))))
        let second = try await h.pollEvents()
        XCTAssertTrue(second.contains(.objectAdded(NewObject(handle: SonyCodes.sdramHandle, inSDRAM: true))))
        let pushed = await h.translate(PTPEvent(code: SonyCodes.Event.objectAdded, parameters: [SonyCodes.sdramHandle]))
        XCTAssertEqual(pushed, .objectAdded(NewObject(handle: SonyCodes.sdramHandle, inSDRAM: true)))
        let prop = await h.translate(PTPEvent(code: SonyCodes.Event.propertyChanged, parameters: [0xD20D]))
        XCTAssertEqual(prop, .propertyChanged(.shutterSpeed))
    }

    func testSDIOAllPropsParseBothLayouts() throws {
        let two = try SonyPropDesc.parseAll(Self.dump(twoLists: true))
        XCTAssertEqual(two.count, 8)
        let shutter = two.first { $0.code == SonyCodes.Prop.shutterSpeed }!
        XCTAssertEqual(shutter.form.enumerationValues?.count, 3)
        XCTAssertEqual(shutter.settable?.count, 2)
        XCTAssertEqual(shutter.choices?.count, 2) // the set-able list wins
        let iso = two.first { $0.code == SonyCodes.Prop.iso }!
        XCTAssertFalse(iso.isEnabled)
        XCTAssertEqual(iso.choices?.count, 3) // empty second list falls back to the first
        let one = try SonyPropDesc.parseAll(Self.dump(twoLists: false))
        XCTAssertEqual(one.count, 8)
        XCTAssertNil(one.first { $0.code == SonyCodes.Prop.shutterSpeed }!.settable)
        XCTAssertEqual(one.first { $0.code == SonyCodes.Prop.batteryLevel }!.current, .uint8(65))
    }

    func testPropertyReadDisplayAndWrite() async throws {
        let rig = try await VendorRig(VendorFixtures.sony)
        rig.transport.okAll()
        rig.transport.on(SonyCodes.Op.sdioGetAllExtDevicePropInfo) { _ in .ok(Self.dump()) }
        let h = SonyHandler(engine: rig.engine, info: rig.info)
        let props = try await h.readProperties([.aperture, .shutterSpeed, .iso, .exposureCompensation, .whiteBalance, .batteryLevel, .captureDestination])
        let by = Dictionary(uniqueKeysWithValues: props.map { ($0.property, $0) })
        XCTAssertEqual(by[.aperture]?.display, "ƒ/2.8")
        XCTAssertEqual(by[.shutterSpeed]?.display, "1/250")
        XCTAssertEqual(by[.shutterSpeed]?.choices.map(\.display), ["1/125", "1/250"])
        XCTAssertEqual(by[.iso]?.display, "Auto")
        XCTAssertEqual(by[.iso]?.isWritable, false) // isEnabled = false
        XCTAssertEqual(by[.exposureCompensation]?.display, "-0.7")
        XCTAssertEqual(by[.whiteBalance]?.display, "Shade")
        XCTAssertEqual(by[.batteryLevel]?.display, "65%")
        XCTAssertEqual(by[.captureDestination]?.choices.map(\.display), [CaptureDestination.card.displayName, CaptureDestination.both.displayName])
        try await h.writeProperty(.shutterSpeed, raw: by[.shutterSpeed]!.choices[0].raw)
        let set = rig.transport.requests(for: SonyCodes.Op.sdioSetExtDevicePropValue).last!
        XCTAssertEqual(set.parameters, [0xD20D])
        XCTAssertEqual(set.dataOut, PTPValue.uint32(1 << 16 | 125).encoded)
        await XCTAssertThrowsPTP(try await h.setCaptureDestination(.host)) { e in
            guard case .unsupported(let msg) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(msg.contains("Save Dest"))
        }
    }

    func testLiveViewFrameComesFromFixedHandle() async throws {
        let rig = try await VendorRig(VendorFixtures.sony)
        let jpeg = Data.fakeJPEG(size: 128)
        rig.transport.on(.getObjectInfo) { _ in .ok(PTPObjectInfo(objectCompressedSize: 128).encoded) }
        rig.transport.on(.getObject) { _ in .ok(Data([0, 0, 0, 0, 0, 0, 0, 0]) + jpeg) }
        let h = SonyHandler(engine: rig.engine, info: rig.info)
        try await h.startLiveView(quality: .low)
        let f = try await h.nextLiveViewFrame()
        XCTAssertEqual(f?.jpeg, jpeg)
        XCTAssertEqual(rig.requests.map(\.parameters), [[SonyCodes.liveViewHandle], [SonyCodes.liveViewHandle]])
    }
}
