import XCTest
@testable import TetherCore

final class ByteBufferTests: XCTestCase {
    func testScalarRoundTrip() throws {
        var b = ByteBuffer()
        b.write(UInt8(0x12)); b.write(UInt16(0x3456)); b.write(UInt32(0x789A_BCDE)); b.write(UInt64(0x0102_0304_0506_0708))
        b.write(Int16(-2)); b.write(Int32(-3))
        XCTAssertEqual(b.bytes.prefix(3), [0x12, 0x56, 0x34])
        var r = ByteBuffer(b.bytes)
        XCTAssertEqual(try r.readUInt8(), 0x12)
        XCTAssertEqual(try r.readUInt16(), 0x3456)
        XCTAssertEqual(try r.readUInt32(), 0x789A_BCDE)
        XCTAssertEqual(try r.readUInt64(), 0x0102_0304_0506_0708)
        XCTAssertEqual(try r.readInt16(), -2)
        XCTAssertEqual(try r.readInt32(), -3)
        XCTAssertTrue(r.isAtEnd)
        XCTAssertThrowsError(try r.readUInt8())
    }

    func testPTPString() throws {
        var b = ByteBuffer()
        b.writePTPString("Canon EOS R5")
        b.writePTPString("")
        XCTAssertEqual(b.bytes[0], 13) // 12 chars + NUL
        var r = ByteBuffer(b.bytes)
        XCTAssertEqual(try r.readPTPString(), "Canon EOS R5")
        XCTAssertEqual(try r.readPTPString(), "")
    }

    func testPTPStringWithoutTerminator() throws {
        // Some firmware omits the NUL: count 2, two chars.
        var r = ByteBuffer([2, 0x41, 0x00, 0x42, 0x00])
        XCTAssertEqual(try r.readPTPString(), "AB")
    }

    func testArrays() throws {
        var b = ByteBuffer()
        b.write(uint16Array: [0x1001, 0x1002])
        b.write(uint32Array: [1, 2, 3])
        var r = ByteBuffer(b.bytes)
        XCTAssertEqual(try r.readUInt16Array(), [0x1001, 0x1002])
        XCTAssertEqual(try r.readUInt32Array(), [1, 2, 3])
    }
}

final class DataSetTests: XCTestCase {
    func testDeviceInfoRoundTrip() throws {
        let info = ScriptedTransport.genericInfo
        let parsed = try PTPDeviceInfo(parsing: info.encoded)
        XCTAssertEqual(parsed, info)
        XCTAssertTrue(parsed.supports(.initiateCapture))
        XCTAssertEqual(CameraVendor.detect(parsed), .generic)
    }

    func testObjectInfoRoundTripAndKinds() throws {
        var o = PTPObjectInfo(objectFormat: .exifJPEG, objectCompressedSize: 1234, imagePixWidth: 6000, imagePixHeight: 4000,
                              filename: "IMG_0001.JPG", captureDate: "20261016T101500")
        let p = try PTPObjectInfo(parsing: o.encoded)
        XCTAssertEqual(p, o)
        XCTAssertEqual(p.mediaKind, .jpeg)
        XCTAssertNotNil(p.captureDateValue)
        o.objectFormat = .undefined; o.filename = "DSC_0001.NEF"
        XCTAssertEqual(o.mediaKind, .raw)
        o.filename = "A.CR3"; o.objectFormat = .canonCR3
        XCTAssertEqual(o.mediaKind, .raw)
        o.filename = "clip.MP4"; o.objectFormat = .undefined
        XCTAssertEqual(o.mediaKind, .video)
    }

    func testDevicePropDescEnumAndRange() throws {
        let e = PTPDevicePropDesc(code: .fNumber, dataType: .uint16, isWritable: true, factoryDefault: .uint16(280),
                                  current: .uint16(400), form: .enumeration([.uint16(280), .uint16(400), .uint16(560)]))
        let pe = try PTPDevicePropDesc(parsing: e.encoded)
        XCTAssertEqual(pe, e)
        XCTAssertEqual(pe.enumerationValues?.count, 3)
        let r = PTPDevicePropDesc(code: .exposureBiasCompensation, dataType: .int16, isWritable: true, factoryDefault: .int16(0),
                                  current: .int16(-333), form: .range(min: .int16(-5000), max: .int16(5000), step: .int16(333)))
        XCTAssertEqual(try PTPDevicePropDesc(parsing: r.encoded), r)
    }

    func testStorageInfoRoundTrip() throws {
        let s = PTPStorageInfo(storageType: 4, filesystemType: 2, accessCapability: 0, maxCapacity: 64 << 30,
                               freeSpaceInBytes: 10 << 30, freeSpaceInImages: 500, storageDescription: "SD1", volumeLabel: "EOS_DIGITAL")
        XCTAssertEqual(try PTPStorageInfo(parsing: s.encoded), s)
        XCTAssertTrue(s.isRemovableCard)
    }

    func testDateTimeParsing() {
        XCTAssertNotNil(PTPDateTime.parse("20261016T101500"))
        XCTAssertNotNil(PTPDateTime.parse("20261016T101500.5Z"))
        XCTAssertNotNil(PTPDateTime.parse("20261016T101500+0200"))
        XCTAssertNil(PTPDateTime.parse("garbage"))
        let d = PTPDateTime.parse("20261016T101500Z")!
        XCTAssertEqual(PTPDateTime.format(d, timeZone: TimeZone(secondsFromGMT: 0)!), "20261016T101500")
    }

    func testFormatters() {
        XCTAssertEqual(PropertyFormat.aperture(hundredths: 280), "ƒ/2.8")
        XCTAssertEqual(PropertyFormat.aperture(hundredths: 800), "ƒ/8")
        XCTAssertEqual(PropertyFormat.shutter(tenThousandths: 40), "1/250")
        XCTAssertEqual(PropertyFormat.shutter(tenThousandths: 20000), "2\"")
        XCTAssertEqual(PropertyFormat.shutter(numerator: 1, denominator: 8000), "1/8000")
        XCTAssertEqual(PropertyFormat.exposureCompensation(thousandths: -667), "-0.7")
        XCTAssertEqual(PropertyFormat.exposureCompensation(thousandths: 1000), "+1")
        XCTAssertEqual(PropertyFormat.iso(0xFFFF), "Auto")
        XCTAssertEqual("\(PTPOperationCode.getObject)", "GetObject")
        XCTAssertEqual("\(PTPOperationCode(0x9128))", "Op(0x9128)")
    }

    func testJPEGPayloadExtraction() {
        var framed = Data(repeating: 0xAA, count: 64)
        framed.append(Data.fakeJPEG(size: 100))
        framed.append(Data(repeating: 0xBB, count: 8))
        let jpeg = framed.jpegPayload()!
        XCTAssertEqual(jpeg.first, 0xFF)
        XCTAssertEqual(jpeg[1], 0xD8)
        XCTAssertEqual(jpeg.suffix(2), Data([0xFF, 0xD9]))
        XCTAssertEqual(jpeg.count, 100)
    }
}

final class PTPEngineTests: XCTestCase {
    func testConnectReadsDeviceInfoAndOpensSession() async throws {
        let t = ScriptedTransport()
        let engine = PTPEngine(transport: t)
        let info = try await engine.connect()
        XCTAssertEqual(info.model, "PTP-1")
        XCTAssertEqual(t.requests.map(\.code), [.getDeviceInfo, .openSession])
        let open = await engine.isSessionOpen
        XCTAssertTrue(open)
    }

    func testPartialDownloadChunksAndReportsProgress() async throws {
        let t = ScriptedTransport()
        let payload = Data((0 ..< 2500).map { UInt8($0 & 0xFF) })
        t.on(.getPartialObject) { req in
            let off = Int(req.parameters[1]), want = Int(req.parameters[2])
            let end = min(payload.count, off + want)
            return .ok(payload[off ..< end])
        }
        let engine = PTPEngine(transport: t)
        _ = try await engine.connect()
        await engine.setChunk(1000)
        let seen = Progress()
        let data = try await engine.download(0x42, size: UInt32(payload.count)) { done, total in seen.add(done, total) }
        XCTAssertEqual(data, payload)
        XCTAssertEqual(t.requests(for: .getPartialObject).count, 3)
        XCTAssertEqual(seen.values.last?.0, 2500)
    }

    func testDeviceBusyIsRetried() async throws {
        let t = ScriptedTransport()
        let counter = Counter()
        t.on(.getStorageIDs) { _ in
            counter.increment()
            if counter.value < 3 { return .fail(.deviceBusy) }
            var b = ByteBuffer(); b.write(uint32Array: [0x0001_0001]); return .ok(b.data)
        }
        let engine = PTPEngine(transport: t)
        _ = try await engine.connect()
        let ids = try await engine.getStorageIDs()
        XCTAssertEqual(ids, [0x0001_0001])
        XCTAssertEqual(counter.value, 3)
    }

    func testErrorsCarryTheResponseCode() async throws {
        let t = ScriptedTransport()
        t.on(.initiateCapture) { _ in .fail(.accessDenied) }
        let engine = PTPEngine(transport: t)
        _ = try await engine.connect()
        do {
            try await engine.initiateCapture()
            XCTFail("expected failure")
        } catch let e as PTPError {
            XCTAssertEqual(e.responseCode, .accessDenied)
            XCTAssertTrue("\(e)".contains("AccessDenied"))
        }
    }

    func testLogRecordsTransactions() async throws {
        let t = ScriptedTransport()
        t.on(.getStorageIDs) { _ in var b = ByteBuffer(); b.write(uint32Array: [1]); return .ok(b.data) }
        let log = PTPLog(capacity: 3)
        let engine = PTPEngine(transport: t, log: log)
        _ = try await engine.connect()
        _ = try await engine.getStorageIDs()
        _ = try await engine.getStorageIDs()
        XCTAssertEqual(log.recent.count, 3) // capped
        XCTAssertTrue(log.recent.last!.line.contains("GetStorageIDs"))
    }
}

extension PTPEngine {
    func setChunk(_ n: UInt32) { partialChunkSize = n }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    func increment() { lock.lock(); v += 1; lock.unlock() }
}

final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [(Int, Int?)] = []
    func add(_ a: Int, _ b: Int?) { lock.lock(); values.append((a, b)); lock.unlock() }
}

final class GenericHandlerTests: XCTestCase {
    func testCapabilitiesFromDeviceInfo() {
        let t = ScriptedTransport()
        let h = GenericPTPHandler(engine: PTPEngine(transport: t), info: ScriptedTransport.genericInfo)
        XCTAssertTrue(h.capabilities.contains(.remoteCapture))
        XCTAssertTrue(h.capabilities.contains(.partialTransfer))
        XCTAssertFalse(h.capabilities.contains(.importOnly))
        var info = ScriptedTransport.genericInfo
        info.operationsSupported.removeAll { $0 == .initiateCapture }
        let h2 = GenericPTPHandler(engine: PTPEngine(transport: t), info: info)
        XCTAssertTrue(h2.capabilities.contains(.importOnly))
    }

    func testTranslateEvents() async {
        let t = ScriptedTransport()
        let h = GenericPTPHandler(engine: PTPEngine(transport: t), info: ScriptedTransport.genericInfo)
        let added = await h.translate(PTPEvent(code: .objectAdded, parameters: [0x1234]))
        XCTAssertEqual(added, .objectAdded(NewObject(handle: 0x1234)))
        let prop = await h.translate(PTPEvent(code: .devicePropChanged, parameters: [0x5007]))
        XCTAssertEqual(prop, .propertyChanged(.aperture))
        let reset = await h.translate(PTPEvent(code: .deviceReset))
        XCTAssertEqual(reset, .disconnected)
    }

    func testReadAndWriteStandardProperties() async throws {
        let t = ScriptedTransport()
        t.on(.getDevicePropDesc) { req in
            let code = PTPDevicePropCode(UInt16(req.parameters[0]))
            let d = PTPDevicePropDesc(code: code, dataType: .uint16, isWritable: true, factoryDefault: .uint16(280),
                                      current: .uint16(400), form: .enumeration([.uint16(280), .uint16(400)]))
            return .ok(d.encoded)
        }
        t.on(.setDevicePropValue) { _ in .ok() }
        let engine = PTPEngine(transport: t)
        _ = try await engine.connect()
        let h = GenericPTPHandler(engine: engine, info: ScriptedTransport.genericInfo)
        let props = try await h.readProperties([.aperture, .colorTemperature])
        XCTAssertEqual(props.count, 1)
        XCTAssertEqual(props[0].display, "ƒ/4")
        XCTAssertEqual(props[0].choices.map(\.display), ["ƒ/2.8", "ƒ/4"])
        try await h.writeProperty(.aperture, raw: .uint16(280))
        XCTAssertEqual(t.requests(for: .setDevicePropValue).first?.dataOut, PTPValue.uint16(280).encoded)
    }

    func testRegistryFallsBackToGeneric() {
        let t = ScriptedTransport()
        var info = ScriptedTransport.genericInfo
        info.manufacturer = "Hasselblad"
        let h = VendorRegistry.makeHandler(engine: PTPEngine(transport: t), info: info, transport: .usb)
        XCTAssertTrue(h is GenericPTPHandler)
        XCTAssertEqual(h.vendor, .hasselblad)
    }
}
