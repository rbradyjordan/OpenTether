import XCTest
@testable import TetherCore

final class FujifilmVendorTests: XCTestCase {
    static func handles(_ h: [UInt32]) -> Data { var b = ByteBuffer(); b.write(uint32Array: h); return b.data }

    func testCapabilitiesDeriveFromOperations() {
        let t = ScriptedTransport(deviceInfo: VendorFixtures.fuji)
        let h = FujifilmHandler(engine: PTPEngine(transport: t), info: VendorFixtures.fuji)
        XCTAssertEqual(h.vendor, .fujifilm)
        XCTAssertTrue(h.capabilities.contains(.remoteCapture))
        XCTAssertTrue(h.capabilities.contains(.propertyControl))
        XCTAssertFalse(h.capabilities.contains(.liveView))
        XCTAssertFalse(h.capabilities.contains(.sdramCapture))
        let noCapture = FujifilmHandler(engine: PTPEngine(transport: t), info: VendorFixtures.info("FUJIFILM", "X100V", ops: []))
        XCTAssertFalse(noCapture.capabilities.contains(.remoteCapture))
    }

    func testPrepareSetsPriorityModeAndSeedsDiffer() async throws {
        let rig = try await VendorRig(VendorFixtures.fuji)
        rig.transport.okAll()
        rig.transport.on(.getDevicePropDesc) { _ in .ok(propDesc(FujifilmCodes.Prop.priorityMode, type: .uint16, current: 1, choices: [1, 2])) }
        rig.transport.on(.getObjectHandles) { _ in .ok(Self.handles([1, 2])) }
        let h = FujifilmHandler(engine: rig.engine, info: rig.info)
        try await h.prepare()
        XCTAssertEqual(rig.codes, [.getDevicePropDesc, .setDevicePropValue, .getObjectHandles])
        XCTAssertEqual(rig.requests[1].parameters, [0xD207])
        XCTAssertEqual(rig.requests[1].dataOut, PTPValue.uint16(2).encoded)
        XCTAssertTrue(h.differ.isSeeded)
    }

    func testCaptureUsesInitiateCaptureWithZeroParams() async throws {
        let rig = try await VendorRig(VendorFixtures.fuji)
        rig.transport.okAll()
        try await FujifilmHandler(engine: rig.engine, info: rig.info).capture(autofocus: true)
        XCTAssertEqual(rig.codes, [.initiateCapture])
        XCTAssertEqual(rig.requests[0].parameters, [0, 0])
        await XCTAssertThrowsPTP(try await FujifilmHandler(engine: rig.engine, info: VendorFixtures.info("FUJIFILM", "X", ops: [])).capture(autofocus: true)) { e in
            guard case .vendorGate = e else { return XCTFail("\(e)") }
        }
    }

    func testPollEventsReadsCurrentStateAndDiffsHandles() async throws {
        let rig = try await VendorRig(VendorFixtures.fuji)
        let counter = Counter()
        rig.transport.on(.getObjectHandles) { _ in
            counter.increment()
            return .ok(Self.handles(counter.value == 1 ? [10, 11] : [10, 11, 12, 13]))
        }
        rig.transport.on(.getDevicePropValue) { _ in
            var b = ByteBuffer(); b.write(UInt16(2)); b.write(UInt16(0x5007)); b.write(UInt32(280)); b.write(UInt16(0xD001)); b.write(UInt32(11))
            return .ok(b.data)
        }
        let h = FujifilmHandler(engine: rig.engine, info: rig.info)
        let first = try await h.pollEvents()
        XCTAssertEqual(first, [.propertyChanged(.aperture), .propertyChanged(.pictureStyle)]) // first poll seeds the differ
        let second = try await h.pollEvents()
        XCTAssertEqual(second, [.objectAdded(NewObject(handle: 12)), .objectAdded(NewObject(handle: 13))]) // RAW+JPEG: two objects, no repeated prop changes
    }

    func testPropertyReadDisplayAndWrite() async throws {
        let rig = try await VendorRig(VendorFixtures.fuji)
        rig.transport.on(.getDevicePropDesc) { req in
            switch PTPDevicePropCode(UInt16(req.parameters[0])) {
            case .fNumber: return .ok(propDesc(.fNumber, type: .uint16, current: 200, choices: [200, 280, 400]))
            case .exposureTime: return .ok(propDesc(.exposureTime, type: .uint32, current: 40, choices: [40, 80, 10000]))
            case .exposureIndex: return .ok(propDesc(.exposureIndex, type: .uint32, current: 160, choices: [160, 320]))
            case FujifilmCodes.Prop.filmSimulation: return .ok(propDesc(FujifilmCodes.Prop.filmSimulation, type: .uint16, current: 11, choices: [1, 11, 12]))
            case .whiteBalance: return .ok(propDesc(.whiteBalance, type: .uint16, current: 0x8006, choices: [2, 0x8006]))
            default: return .fail(.devicePropNotSupported)
            }
        }
        rig.transport.on(.setDevicePropValue) { _ in .ok() }
        let h = FujifilmHandler(engine: rig.engine, info: rig.info)
        let props = try await h.readProperties([.aperture, .shutterSpeed, .iso, .pictureStyle, .whiteBalance, .captureDestination])
        let by = Dictionary(uniqueKeysWithValues: props.map { ($0.property, $0) })
        XCTAssertEqual(by[.aperture]?.display, "ƒ/2")
        XCTAssertEqual(by[.shutterSpeed]?.display, "1/250")
        XCTAssertEqual(by[.shutterSpeed]?.choices.map(\.display), ["1/250", "1/125", "1\""])
        XCTAssertEqual(by[.iso]?.display, "160")
        XCTAssertEqual(by[.pictureStyle]?.display, "Classic Chrome")
        XCTAssertEqual(by[.whiteBalance]?.display, "Shade")
        XCTAssertEqual(by[.captureDestination]?.isWritable, false)
        try await h.writeProperty(.iso, raw: by[.iso]!.choices[1].raw)
        let set = rig.transport.requests(for: .setDevicePropValue).last!
        XCTAssertEqual(set.parameters, [0x500F])
        XCTAssertEqual(set.dataOut, PTPValue.uint32(320).encoded)
    }

    func testObjectHandleDifferSeedsThenReportsNewHandlesOnly() {
        let d = ObjectHandleDiffer()
        XCTAssertFalse(d.isSeeded)
        XCTAssertEqual(d.diff([1, 2, 3]), [])
        XCTAssertTrue(d.isSeeded)
        XCTAssertEqual(d.diff([1, 2, 3, 9, 4]), [9, 4])
        XCTAssertEqual(d.diff([9, 4]), []) // removals are not reported
        XCTAssertEqual(d.diff([9, 4, 1]), [1]) // a handle that came back is new again
        d.reset()
        XCTAssertEqual(d.diff([100]), [])
    }
}
