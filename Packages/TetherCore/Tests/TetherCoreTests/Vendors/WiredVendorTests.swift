import XCTest
@testable import TetherCore

/// Olympus, Panasonic and Leica: wired-only brands built on the generic
/// handler plus a vendor capture opcode.
final class WiredVendorTests: XCTestCase {
    static func handles(_ h: [UInt32]) -> Data { var b = ByteBuffer(); b.write(uint32Array: h); return b.data }

    // MARK: Olympus

    func testOlympusCapabilitiesPrepareAndCapture() async throws {
        let rig = try await VendorRig(VendorFixtures.olympus)
        rig.transport.okAll()
        rig.transport.on(.getObjectHandles) { _ in .ok(Self.handles([1])) }
        let h = OlympusHandler(engine: rig.engine, info: rig.info)
        XCTAssertEqual(h.vendor, .olympus)
        XCTAssertTrue(h.capabilities.contains(.remoteCapture))
        XCTAssertTrue(h.capabilities.contains(.liveView))
        XCTAssertTrue(h.capabilities.contains(.autofocus))
        try await h.prepare()
        XCTAssertEqual(rig.codes, [.setDevicePropValue, .getObjectHandles])
        XCTAssertEqual(rig.requests[0].parameters, [0xD052])
        XCTAssertEqual(rig.requests[0].dataOut, PTPValue.uint8(1).encoded)
        try await h.capture(autofocus: true)
        XCTAssertEqual(Array(rig.codes.suffix(2)), [OlympusCodes.Op.capture, OlympusCodes.Op.capture])
        XCTAssertEqual(Array(rig.requests.suffix(2)).map(\.parameters), [[0x3], [0x6]])
        let plain = OlympusHandler(engine: rig.engine, info: VendorFixtures.info("OLYMPUS", "TG-6", ops: []))
        XCTAssertFalse(plain.capabilities.contains(.remoteCapture))
    }

    func testOlympusEventsFallBackToHandleDiff() async throws {
        let rig = try await VendorRig(VendorFixtures.olympus)
        let counter = Counter()
        rig.transport.on(.getObjectHandles) { _ in counter.increment(); return .ok(Self.handles(counter.value == 1 ? [1] : [1, 2])) }
        let h = OlympusHandler(engine: rig.engine, info: rig.info)
        let first = try await h.pollEvents()
        XCTAssertEqual(first, [])
        let second = try await h.pollEvents()
        XCTAssertEqual(second, [.objectAdded(NewObject(handle: 2))])
        let pc = await h.translate(PTPEvent(code: OlympusCodes.Event.propertyChanged, parameters: [0x500D]))
        XCTAssertEqual(pc, .propertyChanged(.shutterSpeed))
    }

    // MARK: Panasonic

    func testPanasonicCapabilitiesAndCapture() async throws {
        let rig = try await VendorRig(VendorFixtures.panasonic)
        rig.transport.okAll()
        rig.transport.on(.getObjectHandles) { _ in .ok(Self.handles([])) }
        let h = PanasonicHandler(engine: rig.engine, info: rig.info)
        XCTAssertEqual(h.vendor, .panasonic)
        for c in [CameraCapabilities.remoteCapture, .cardCapture, .liveView, .propertyControl, .autofocus] { XCTAssertTrue(h.capabilities.contains(c), "\(c)") }
        try await h.prepare()
        try await h.capture(autofocus: true)
        XCTAssertEqual(rig.codes, [.getObjectHandles, PanasonicCodes.Op.initiateCapture])
        XCTAssertEqual(rig.requests[1].parameters, [0x0300_0011])
        try await h.startLiveView(quality: .medium)
        XCTAssertEqual(rig.requests.last?.code, PanasonicCodes.Op.liveview)
        XCTAssertEqual(rig.requests.last?.parameters, [0x0D00_0010])
        await h.stopLiveView()
        XCTAssertEqual(rig.requests.last?.parameters, [0x0D00_0011])
    }

    func testPanasonicPropertyPayloadsAndDisplay() async throws {
        let rig = try await VendorRig(VendorFixtures.panasonic)
        rig.transport.okAll()
        rig.transport.on(PanasonicCodes.Op.getProperty) { req in
            let code = req.parameters[0]
            let value: UInt32
            switch code {
            case PanasonicCodes.Prop.shutterSpeed: value = 125_000
            case PanasonicCodes.Prop.aperture: value = 28
            case PanasonicCodes.Prop.iso: value = 800
            case PanasonicCodes.Prop.exposure: value = UInt32(bitPattern: -2)
            case PanasonicCodes.Prop.whiteBalance: value = 0x8008
            default: return .fail(.devicePropNotSupported)
            }
            return .ok(PanasonicPropertyValue(code: code, value: value).encoded)
        }
        let h = PanasonicHandler(engine: rig.engine, info: rig.info)
        let props = try await h.readProperties([.aperture, .shutterSpeed, .iso, .exposureCompensation, .whiteBalance, .batteryLevel, .captureDestination])
        let by = Dictionary(uniqueKeysWithValues: props.map { ($0.property, $0) })
        XCTAssertEqual(by[.shutterSpeed]?.display, "1/125")
        XCTAssertEqual(by[.aperture]?.display, "ƒ/2.8")
        XCTAssertEqual(by[.iso]?.display, "800")
        XCTAssertEqual(by[.exposureCompensation]?.display, "-0.7")
        XCTAssertEqual(by[.whiteBalance]?.display, "Cloudy")
        XCTAssertNil(by[.batteryLevel]) // the body did not answer
        XCTAssertEqual(by[.captureDestination]?.isWritable, false)
        try await h.writeProperty(.aperture, raw: .uint32(40))
        let set = rig.transport.requests(for: PanasonicCodes.Op.setProperty).last!
        XCTAssertEqual(set.parameters, [PanasonicCodes.Prop.aperture])
        XCTAssertEqual([UInt8](set.dataOut!), [0x40, 0x00, 0x00, 0x02, 4, 0, 0, 0, 40, 0, 0, 0])
        XCTAssertEqual(PanasonicCodes.shutterDisplay(0x8000_0000 | 4000), "4\"")
        XCTAssertEqual(PanasonicCodes.shutterDisplay(0xFFFF_FFFF), "Bulb")
        let parsed = try PanasonicPropertyValue(parsing: Data([0x30, 0, 0, 0x02, 2, 0, 0, 0, 0x34, 0x12]))
        XCTAssertEqual(parsed.value, 0x1234)
    }

    // MARK: Leica

    func testLeicaSessionGateAndReleaseStageCapture() async throws {
        let rig = try await VendorRig(VendorFixtures.leica)
        rig.transport.okAll()
        rig.transport.on(.getObjectHandles) { _ in .ok(Self.handles([5])) }
        let h = LeicaHandler(engine: rig.engine, info: rig.info)
        XCTAssertEqual(h.vendor, .leica)
        XCTAssertTrue(h.capabilities.contains(.remoteCapture))
        XCTAssertTrue(h.capabilities.contains(.autofocus))
        try await h.prepare()
        XCTAssertEqual(rig.codes, [LeicaCodes.Op.openLESession, .getObjectHandles])
        XCTAssertEqual(rig.requests[0].parameters, [1])
        try await h.capture(autofocus: true)
        XCTAssertEqual(Array(rig.codes.suffix(3)), [LeicaCodes.Op.releaseStage, LeicaCodes.Op.releaseStage, LeicaCodes.Op.releaseStage])
        XCTAssertEqual(Array(rig.requests.suffix(3)).map(\.parameters), [[1], [2], [0]])
        try await h.capture(autofocus: false)
        XCTAssertEqual(Array(rig.requests.suffix(2)).map(\.parameters), [[2], [0]])
        await h.teardown()
        XCTAssertEqual(rig.codes.last, LeicaCodes.Op.closeLESession)
    }

    func testLeicaPropertiesAreStandardAndDestinationIsCardOnly() async throws {
        let rig = try await VendorRig(VendorFixtures.leica)
        rig.transport.on(.getDevicePropDesc) { req in
            let code = PTPDevicePropCode(UInt16(req.parameters[0]))
            return .ok(propDesc(code, type: .uint16, current: 560, choices: [400, 560]))
        }
        rig.transport.on(.setDevicePropValue) { _ in .ok() }
        let h = LeicaHandler(engine: rig.engine, info: rig.info)
        let props = try await h.readProperties([.aperture, .captureDestination])
        XCTAssertEqual(props.first?.display, "ƒ/5.6")
        XCTAssertEqual(props.last?.property, .captureDestination)
        try await h.writeProperty(.aperture, raw: props.first!.choices[0].raw)
        XCTAssertEqual(rig.transport.requests(for: .setDevicePropValue).last?.dataOut, PTPValue.uint16(400).encoded)
        await XCTAssertThrowsPTP(try await h.setCaptureDestination(.host)) { e in
            guard case .unsupported = e else { return XCTFail("\(e)") }
        }
    }
}
