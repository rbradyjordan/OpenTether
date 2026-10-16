import XCTest
@testable import TetherCore

final class NikonVendorTests: XCTestCase {
    static func events(_ pairs: [(UInt16, UInt32)]) -> Data {
        var b = ByteBuffer()
        b.write(UInt16(pairs.count))
        for (c, p) in pairs { b.write(c); b.write(p) }
        return b.data
    }

    func testCapabilitiesDeriveFromOperations() {
        let t = ScriptedTransport(deviceInfo: VendorFixtures.nikonZ)
        let h = NikonHandler(engine: PTPEngine(transport: t), info: VendorFixtures.nikonZ)
        XCTAssertEqual(h.vendor, .nikon)
        for c in [CameraCapabilities.remoteCapture, .sdramCapture, .cardCapture, .liveView, .propertyControl, .partialTransfer, .autofocus, .thumbnails, .bulbCapture] {
            XCTAssertTrue(h.capabilities.contains(c), "\(c)")
        }
        let plain = NikonHandler(engine: PTPEngine(transport: t), info: VendorFixtures.info("Nikon", "Coolpix", ops: [0x100E]))
        XCTAssertTrue(plain.capabilities.contains(.cardCapture))
        XCTAssertFalse(plain.capabilities.contains(.sdramCapture))
        XCTAssertFalse(plain.capabilities.contains(.liveView))
    }

    func testPrepareSwitchesApplicationModeThenWaitsForDeviceReady() async throws {
        let rig = try await VendorRig(VendorFixtures.nikonZ)
        rig.transport.okAll()
        let h = NikonHandler(engine: rig.engine, info: rig.info)
        try await h.prepare()
        XCTAssertEqual(rig.codes, [NikonCodes.Op.changeApplicationMode, NikonCodes.Op.deviceReady])
        XCTAssertEqual(rig.requests[0].parameters, [1])
        // A DSLR advertising ChangeCameraMode uses that instead.
        let rig2 = try await VendorRig(VendorFixtures.nikonD)
        rig2.transport.okAll()
        try await NikonHandler(engine: rig2.engine, info: rig2.info).prepare()
        XCTAssertEqual(rig2.codes.first, NikonCodes.Op.changeCameraMode)
    }

    func testCaptureToSDRAMAndToCard() async throws {
        let rig = try await VendorRig(VendorFixtures.nikonZ)
        rig.transport.okAll()
        let h = NikonHandler(engine: rig.engine, info: rig.info)
        try await h.setCaptureDestination(.host)
        try await h.capture(autofocus: true)
        XCTAssertEqual(rig.codes, [NikonCodes.Op.afCaptureSDRAM, NikonCodes.Op.deviceReady])
        let rig2 = try await VendorRig(VendorFixtures.nikonZ)
        rig2.transport.okAll()
        let h2 = NikonHandler(engine: rig2.engine, info: rig2.info)
        try await h2.setCaptureDestination(.host)
        try await h2.capture(autofocus: false)
        XCTAssertEqual(rig2.codes.first, NikonCodes.Op.initiateCaptureRecInSdram)
        let rig3 = try await VendorRig(VendorFixtures.nikonZ)
        rig3.transport.okAll()
        let h3 = NikonHandler(engine: rig3.engine, info: rig3.info)
        try await h3.setCaptureDestination(.both)
        try await h3.capture(autofocus: false)
        XCTAssertEqual(rig3.codes.first, NikonCodes.Op.initiateCaptureRecInMedia)
        XCTAssertEqual(rig3.requests.first?.parameters, [0xFFFF_FFFF, 1])
        try await h3.setCaptureDestination(.card)
        try await h3.capture(autofocus: true)
        XCTAssertEqual(rig3.requests[2].parameters, [0, 0])
    }

    func testGetEventPairsBecomeCameraEvents() async throws {
        let rig = try await VendorRig(VendorFixtures.nikonZ)
        rig.transport.on(NikonCodes.Op.getEvent) { _ in
            .ok(Self.events([(0xC101, 0xFFFF_0001), (0x4006, 0x5007), (0xC102, 0), (0x4002, 0x0000_1234), (0x4006, 0xD100)]))
        }
        let h = NikonHandler(engine: rig.engine, info: rig.info)
        let events = try await h.pollEvents()
        XCTAssertEqual(events, [
            .objectAdded(NewObject(handle: 0xFFFF_0001, inSDRAM: true)),
            .propertyChanged(.aperture),
            .captureComplete,
            .objectAdded(NewObject(handle: 0x1234)),
            .propertyChanged(.shutterSpeed),
        ])
        XCTAssertEqual(try NikonHandler.parseEvents(Data()), [])
    }

    func testPropertyReadDisplayAndWrite() async throws {
        let rig = try await VendorRig(VendorFixtures.nikonZ)
        rig.transport.on(.getDevicePropDesc) { req in
            switch PTPDevicePropCode(UInt16(req.parameters[0])) {
            case .fNumber: return .ok(propDesc(.fNumber, type: .uint16, current: 280, choices: [280, 400, 560]))
            case NikonCodes.Prop.shutterSpeed:
                return .ok(propDesc(NikonCodes.Prop.shutterSpeed, type: .uint32, current: 1 << 16 | 250, choices: [1 << 16 | 125, 1 << 16 | 250, 20 << 16 | 10, 0xFFFF_FFFF]))
            case .exposureIndex: return .ok(propDesc(.exposureIndex, type: .uint16, current: 400, choices: [100, 400, 0xFFFF]))
            case .whiteBalance: return .ok(propDesc(.whiteBalance, type: .uint16, current: 0x8010, choices: [2, 4, 0x8010]))
            case .batteryLevel: return .ok(propDesc(.batteryLevel, type: .uint8, current: 80, choices: [], writable: false))
            default: return .fail(.devicePropNotSupported)
            }
        }
        rig.transport.on(.setDevicePropValue) { _ in .ok() }
        let h = NikonHandler(engine: rig.engine, info: rig.info)
        let props = try await h.readProperties([.aperture, .shutterSpeed, .iso, .whiteBalance, .batteryLevel, .captureDestination])
        let by = Dictionary(uniqueKeysWithValues: props.map { ($0.property, $0) })
        XCTAssertEqual(by[.aperture]?.display, "ƒ/2.8")
        XCTAssertEqual(by[.shutterSpeed]?.display, "1/250")
        XCTAssertEqual(by[.shutterSpeed]?.choices.map(\.display), ["1/125", "1/250", "2\"", "Bulb"])
        XCTAssertEqual(by[.iso]?.display, "400")
        XCTAssertEqual(by[.iso]?.choices.last?.display, "Auto")
        XCTAssertEqual(by[.whiteBalance]?.display, "Cloudy")
        XCTAssertEqual(by[.batteryLevel]?.display, "80%")
        XCTAssertEqual(by[.captureDestination]?.choices.count, 3)
        try await h.writeProperty(.shutterSpeed, raw: by[.shutterSpeed]!.choices[0].raw)
        let set = rig.transport.requests(for: .setDevicePropValue).last!
        XCTAssertEqual(set.parameters, [0xD100])
        XCTAssertEqual(set.dataOut, PTPValue.uint32(1 << 16 | 125).encoded)
        // Destination written through the descriptor's raw value.
        try await h.writeProperty(.captureDestination, raw: by[.captureDestination]!.choices.first { $0.display == CaptureDestination.host.displayName }!.raw)
        let after = try await h.readProperties([.captureDestination])
        XCTAssertEqual(after.first?.display, CaptureDestination.host.displayName)
    }

    func testLiveViewRefusedWhenProhibitConditionSet() async throws {
        let rig = try await VendorRig(VendorFixtures.nikonZ)
        rig.transport.okAll()
        rig.transport.on(.getDevicePropValue) { _ in .ok(PTPValue.uint32(1 << 0 | 1 << 16).encoded) }
        let h = NikonHandler(engine: rig.engine, info: rig.info)
        await XCTAssertThrowsPTP(try await h.startLiveView(quality: .medium)) { e in
            guard case .vendorGate(let msg) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(msg.contains("card"))
            XCTAssertTrue(msg.contains("temperature"))
        }
        XCTAssertFalse(rig.codes.contains(NikonCodes.Op.startLiveView))
    }

    func testLiveViewStartsAndFindsJPEGBehindHeader() async throws {
        let rig = try await VendorRig(VendorFixtures.nikonZ)
        rig.transport.okAll()
        rig.transport.on(.getDevicePropValue) { _ in .ok(PTPValue.uint32(0).encoded) }
        let jpeg = Data.fakeJPEG(size: 300)
        rig.transport.on(NikonCodes.Op.getLiveViewImg) { _ in .ok(Data(repeating: 0, count: 384) + jpeg) }
        let h = NikonHandler(engine: rig.engine, info: rig.info)
        try await h.startLiveView(quality: .high)
        XCTAssertTrue(rig.codes.contains(NikonCodes.Op.startLiveView))
        let f = try await h.nextLiveViewFrame()
        XCTAssertEqual(f?.jpeg, jpeg)
        await h.stopLiveView()
        XCTAssertEqual(rig.codes.last, NikonCodes.Op.endLiveView)
    }

    func testSDRAMFetchUsesGetObjectInfoAndGetObject() async throws {
        let rig = try await VendorRig(VendorFixtures.nikonZ)
        let payload = Data.fakeJPEG(size: 500)
        rig.transport.on(.getObjectInfo) { _ in .ok(PTPObjectInfo(objectCompressedSize: 500, filename: "DSC_0001.JPG").encoded) }
        rig.transport.on(.getObject) { _ in .ok(payload) }
        let h = NikonHandler(engine: rig.engine, info: rig.info)
        let (oi, data) = try await h.fetchObject(NewObject(handle: NikonCodes.sdramHandle, inSDRAM: true), progress: nil)
        XCTAssertEqual(oi.filename, "DSC_0001.JPG")
        XCTAssertEqual(data, payload)
        XCTAssertEqual(rig.codes, [.getObjectInfo, .getObject])
    }
}
