import Foundation

/// Panasonic Lumix constants (libgphoto2 `PTP_OC_PANASONIC_*`,
/// `PTP_DPC_PANASONIC_*`). Property codes are 32-bit. All VERIFY.
public enum PanasonicCodes {
    public enum Op {
        public static let getProperty = PTPOperationCode(0x9402)      // VERIFY: libgphoto2 PTP_OC_PANASONIC_GetProperty
        public static let setProperty = PTPOperationCode(0x9403)      // VERIFY: libgphoto2 PTP_OC_PANASONIC_SetProperty
        public static let initiateCapture = PTPOperationCode(0x9404)  // VERIFY: libgphoto2 PTP_OC_PANASONIC_InitiateCapture
        public static let listProperty = PTPOperationCode(0x9108)     // VERIFY: libgphoto2 PTP_OC_PANASONIC_ListProperty
        public static let liveview = PTPOperationCode(0x9412)         // VERIFY: libgphoto2 PTP_OC_PANASONIC_Liveview
        public static let liveviewImage = PTPOperationCode(0x9706)    // VERIFY: libgphoto2 PTP_OC_PANASONIC_LiveviewImage
        public static let getCaptureTarget = PTPOperationCode(0x9405) // VERIFY
    }

    public enum Prop {
        public static let whiteBalance: UInt32 = 0x0200_0010 // VERIFY
        public static let iso: UInt32 = 0x0200_0020          // VERIFY
        public static let shutterSpeed: UInt32 = 0x0200_0030 // VERIFY
        public static let aperture: UInt32 = 0x0200_0040     // VERIFY
        public static let exposure: UInt32 = 0x0200_0050     // VERIFY
        public static let afMode: UInt32 = 0x0200_0080       // VERIFY
        public static let battery: UInt32 = 0x1600_0010      // VERIFY: no libgphoto2 reference; placeholder, only read when GetProperty answers
    }

    public enum Event {
        public static let objectAdded = PTPEventCode(0xC102)  // VERIFY: libgphoto2 PTP_EC_PANASONIC_ObjectAdded
        public static let objectAddedSDRAM = PTPEventCode(0xC103) // VERIFY
    }

    public static let captureParam: UInt32 = 0x0300_0011     // VERIFY: libgphoto2 ptp_panasonic_capture
    public static let liveviewStart: UInt32 = 0x0D00_0010    // VERIFY
    public static let liveviewStop: UInt32 = 0x0D00_0011     // VERIFY

    /// Shutter: 0xFFFFFFFF = bulb; high bit set → seconds × 1000; else 1/(v/1000).
    /// VERIFY: libgphoto2 `_get_Panasonic_Shutter`.
    public static func shutterDisplay(_ v: UInt32) -> String {
        if v == 0xFFFF_FFFF { return "Bulb" }
        if v & 0x8000_0000 != 0 { return PropertyFormat.shutter(seconds: Double(v & 0x7FFF_FFFF) / 1000) }
        guard v != 0 else { return "?" }
        return "1/\(v / 1000)"
    }

    /// Aperture is f-number × 10. VERIFY: libgphoto2 `_get_Panasonic_FNumber`.
    public static func apertureDisplay(_ v: UInt32) -> String { PropertyFormat.aperture(hundredths: Int64(v) * 10) }

    /// Exposure compensation in 1/3 EV steps (signed). VERIFY: libgphoto2 `_get_Panasonic_Exposure`.
    public static func exposureDisplay(_ v: UInt32) -> String {
        let thirds = Int32(bitPattern: v)
        return PropertyFormat.exposureCompensation(thousandths: Int64(thirds) * 1000 / 3)
    }

    /// VERIFY: libgphoto2 `_get_Panasonic_Whitebalance`.
    public static let whiteBalances: [UInt32: String] = [
        2: "Auto", 4: "Daylight", 0x8008: "Cloudy", 0x8009: "Shade", 6: "Tungsten", 7: "Flash",
        0x8020: "White set 1", 0x8021: "White set 2", 0x8022: "White set 3", 0x8023: "White set 4",
        0x8010: "Color temperature 1", 0x8011: "Color temperature 2", 0x8012: "Color temperature 3", 0x8013: "Color temperature 4",
        0x8002: "Auto (cool)", 0x8003: "Auto (warm)",
    ]

    public static func display(_ p: TetherProperty, _ v: UInt32) -> String {
        switch p {
        case .shutterSpeed: return shutterDisplay(v)
        case .aperture: return apertureDisplay(v)
        case .iso: return PropertyFormat.iso(Int64(v))
        case .exposureCompensation: return exposureDisplay(v)
        case .whiteBalance: return whiteBalances[v] ?? "WB \(v)"
        case .batteryLevel: return PropertyFormat.battery(percent: Int64(v))
        default: return "\(v)"
        }
    }

    public static func code(for p: TetherProperty) -> UInt32? {
        switch p {
        case .aperture: return Prop.aperture
        case .shutterSpeed: return Prop.shutterSpeed
        case .iso: return Prop.iso
        case .exposureCompensation: return Prop.exposure
        case .whiteBalance: return Prop.whiteBalance
        case .focusMode: return Prop.afMode
        case .batteryLevel: return Prop.battery
        default: return nil
        }
    }

    public static func property(for code: UInt32) -> TetherProperty? {
        switch code {
        case Prop.aperture: return .aperture
        case Prop.shutterSpeed: return .shutterSpeed
        case Prop.iso: return .iso
        case Prop.exposure: return .exposureCompensation
        case Prop.whiteBalance: return .whiteBalance
        case Prop.afMode: return .focusMode
        case Prop.battery: return .batteryLevel
        default: return nil
        }
    }
}

/// A Panasonic GetProperty answer: `UInt32 code, UInt32 size, value`.
public struct PanasonicPropertyValue: Equatable, Sendable {
    public var code: UInt32
    public var value: UInt32
    public var raw: Data

    public init(code: UInt32, value: UInt32) {
        self.code = code
        self.value = value
        var b = ByteBuffer()
        b.write(value)
        raw = b.data
    }

    public init(parsing data: Data) throws {
        var b = ByteBuffer(data)
        code = try b.readUInt32()
        let size = Int(try b.readUInt32())
        guard size <= b.remaining else { throw PTPError.malformed("Panasonic property size \(size) exceeds payload") }
        raw = try b.readData(size)
        var v = ByteBuffer(raw)
        switch size {
        case 1: value = UInt32(try v.readUInt8())
        case 2: value = UInt32(try v.readUInt16())
        case 4: value = try v.readUInt32()
        default: value = (try? v.readUInt32()) ?? 0
        }
    }

    /// SetProperty payload: same layout as the GetProperty answer.
    public var encoded: Data {
        var b = ByteBuffer()
        b.write(code); b.write(UInt32(raw.count)); b.write(raw)
        return b.data
    }
}

/// Panasonic Lumix (wired only): vendor property get/set, vendor capture,
/// live view, object-handle diff for new files.
public final class PanasonicHandler: VendorHandler, @unchecked Sendable {
    public let engine: PTPEngine
    public let info: PTPDeviceInfo
    public let vendor: CameraVendor = .panasonic
    public let capabilities: CameraCapabilities
    public let eventPollInterval: TimeInterval = 0.5

    private let generic: GenericPTPHandler
    public let differ = ObjectHandleDiffer()
    private var liveViewOn = false
    private var frameSequence: UInt64 = 0

    public init(engine: PTPEngine, info: PTPDeviceInfo) {
        self.engine = engine
        self.info = info
        self.generic = GenericPTPHandler(engine: engine, info: info)
        var caps = CameraCapabilities()
        if info.supports(PanasonicCodes.Op.initiateCapture) || info.supports(.initiateCapture) { caps.insert(.remoteCapture); caps.insert(.cardCapture) }
        if info.supports(PanasonicCodes.Op.initiateCapture) { caps.insert(.autofocus) }
        if info.supports(PanasonicCodes.Op.liveview), info.supports(PanasonicCodes.Op.liveviewImage) { caps.insert(.liveView) }
        if info.supports(PanasonicCodes.Op.getProperty), info.supports(PanasonicCodes.Op.setProperty) { caps.insert(.propertyControl) }
        if info.supports(.getPartialObject) { caps.insert(.partialTransfer) }
        if info.supports(.getThumb) { caps.insert(.thumbnails) }
        capabilities = caps
    }

    public func prepare() async throws {
        await differ.seed(engine: engine)
    }

    public func teardown() async { await stopLiveView() }

    public func setCaptureDestination(_ destination: CaptureDestination) async throws {
        if destination != .card { throw PTPError.unsupported("Lumix bodies write to the card; the file is copied over afterwards.") }
    }

    public func capture(autofocus: Bool) async throws {
        if info.supports(PanasonicCodes.Op.initiateCapture) {
            try await engine.run(PanasonicCodes.Op.initiateCapture, [PanasonicCodes.captureParam], timeout: 30)
        } else if info.supports(.initiateCapture) {
            try await engine.initiateCapture()
        } else {
            throw PTPError.unsupported("This camera does not support remote capture over PTP.")
        }
    }

    public func pollEvents() async throws -> [CameraEvent] {
        try await differ.poll(engine: engine)
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? {
        switch event.code {
        case PanasonicCodes.Event.objectAdded, PanasonicCodes.Event.objectAddedSDRAM:
            guard let h = event.parameters.first, h != 0 else { return nil }
            _ = differ.diff([h])
            return .objectAdded(NewObject(handle: h, inSDRAM: event.code == PanasonicCodes.Event.objectAddedSDRAM))
        default:
            if event.code == .objectAdded, let h = event.parameters.first { _ = differ.diff([h]) }
            return await generic.translate(event)
        }
    }

    func getProperty(_ code: UInt32) async throws -> PanasonicPropertyValue {
        let r = try await engine.run(PanasonicCodes.Op.getProperty, [code])
        return try PanasonicPropertyValue(parsing: r.dataIn)
    }

    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] {
        guard info.supports(PanasonicCodes.Op.getProperty) else {
            var out = try await generic.readProperties(properties)
            if properties.contains(.captureDestination) { out.append(VendorProps.destinationDescriptor(current: .card, allowed: [.card], writable: false)) }
            return out
        }
        var out = [PropertyDescriptor]()
        for p in properties {
            if p == .captureDestination {
                out.append(VendorProps.destinationDescriptor(current: .card, allowed: [.card], writable: false))
                continue
            }
            guard let code = PanasonicCodes.code(for: p) else { continue }
            let r = try await engine.execute(PTPRequest(PanasonicCodes.Op.getProperty, parameters: [code]))
            guard r.isOK, let v = try? PanasonicPropertyValue(parsing: r.dataIn) else { continue }
            let writable = capabilities.contains(.propertyControl) && p != .batteryLevel
            out.append(PropertyDescriptor(property: p, raw: .uint32(v.value), display: PanasonicCodes.display(p, v.value),
                                          isWritable: writable, form: .other))
        }
        return out
    }

    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        guard info.supports(PanasonicCodes.Op.setProperty), let code = PanasonicCodes.code(for: property), property != .batteryLevel else {
            throw PTPError.unsupported("\(property.displayName) cannot be set on this camera.")
        }
        guard let v = raw.uintValue else { throw PTPError.unsupported("\(property.displayName) needs a numeric value.") }
        let payload = PanasonicPropertyValue(code: code, value: UInt32(truncatingIfNeeded: v))
        try await engine.run(PanasonicCodes.Op.setProperty, [code], dataOut: payload.encoded)
    }

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        try await generic.fetchObject(object, progress: progress)
    }

    public func startLiveView(quality: LiveViewQuality) async throws {
        guard capabilities.contains(.liveView) else { throw PTPError.unsupported("Live view is not available on this camera.") }
        try await engine.run(PanasonicCodes.Op.liveview, [PanasonicCodes.liveviewStart])
        liveViewOn = true
    }

    public func stopLiveView() async {
        guard liveViewOn else { return }
        liveViewOn = false
        _ = try? await engine.execute(PTPRequest(PanasonicCodes.Op.liveview, parameters: [PanasonicCodes.liveviewStop]))
    }

    public func nextLiveViewFrame() async throws -> LiveViewFrame? {
        guard liveViewOn else { return nil }
        let r = try await engine.execute(PTPRequest(PanasonicCodes.Op.liveviewImage, expectsLargeData: true, timeout: 5))
        guard r.isOK, let jpeg = r.dataIn.jpegPayload() else { return nil }
        frameSequence += 1
        return LiveViewFrame(jpeg: jpeg, sequence: frameSequence)
    }
}
