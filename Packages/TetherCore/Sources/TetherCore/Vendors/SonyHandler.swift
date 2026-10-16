import Foundation

/// Sony constants, named after libgphoto2 `ptp.h` (`PTP_OC_SONY_*`,
/// `PTP_DPC_SONY_*`, `PTP_EC_SONY_*`). VERIFY marks the unconfirmed ones.
public enum SonyCodes {
    public enum Op {
        public static let sdioConnect = PTPOperationCode(0x9201)
        public static let sdioGetExtDeviceInfo = PTPOperationCode(0x9202)
        public static let sdioSetExtDevicePropValue = PTPOperationCode(0x9205)
        public static let sdioControlDevice = PTPOperationCode(0x9207)
        public static let sdioGetAllExtDevicePropInfo = PTPOperationCode(0x9209)
    }

    public enum Prop {
        public static let shutterSpeed = PTPDevicePropCode(0xD20D)
        public static let colorTemperature = PTPDevicePropCode(0xD20F)
        public static let aspectRatio = PTPDevicePropCode(0xD211)
        public static let focusFound = PTPDevicePropCode(0xD213)
        public static let objectInMemory = PTPDevicePropCode(0xD215)
        public static let batteryLevel = PTPDevicePropCode(0xD218) // VERIFY: libgphoto2 PTP_DPC_SONY_BatteryLevel
        public static let iso = PTPDevicePropCode(0xD21E)
        public static let liveViewStatus = PTPDevicePropCode(0xD221)
        public static let stillImageStoreDestination = PTPDevicePropCode(0xD222) // VERIFY: 0xD222 is "Capture (save) destination" in some sniffs; unused until confirmed
        public static let shutterHalfRelease = PTPDevicePropCode(0xD2C1)
        public static let shutterRelease = PTPDevicePropCode(0xD2C2)
        public static let afLock = PTPDevicePropCode(0xD2C3)
        public static let movie = PTPDevicePropCode(0xD2C8)
        public static let stillImage = PTPDevicePropCode(0xD2C7)

        public static let isoAuto: UInt32 = 0x00FF_FFFF
        /// ObjectInMemory >= this means an image is waiting.
        public static let objectWaitingThreshold: UInt16 = 0x8000
        /// Control values for the shutter properties. VERIFY: 2 = press, 1 = release.
        public static let press: UInt16 = 2
        public static let release: UInt16 = 1
        /// FocusFound values. VERIFY: libgphoto2 waits for 3 (locked); 1 = searching, 2 = failed.
        public static let focusLocked: Int64 = 3
    }

    public enum Event {
        public static let objectAdded = PTPEventCode(0xC201)
        public static let objectRemoved = PTPEventCode(0xC202)
        public static let propertyChanged = PTPEventCode(0xC203)
    }

    /// SDIOConnect phases and the extended-device-info version parameters.
    public static let connectPhases: [UInt32] = [1, 2, 3]
    public static let extDeviceInfoVersion: UInt32 = 0x12C // VERIFY: libgphoto2 tries 0x12C (300) then 0xC8 (200)
    public static let extDeviceInfoVersionFallback: UInt32 = 0xC8

    /// Fixed handles for the captured image and the live-view frame.
    public static let sdramHandle: UInt32 = 0xFFFF_C001
    public static let liveViewHandle: UInt32 = 0xFFFF_C002

    /// Sony white balance. VERIFY: libgphoto2 `sony_whitebalance`.
    public static let whiteBalances: [Int64: String] = [
        0x0002: "Auto", 0x0004: "Daylight", 0x0006: "Tungsten", 0x0007: "Flash",
        0x8001: "Fluorescent (warm white)", 0x8002: "Fluorescent (cool white)",
        0x8003: "Fluorescent (day white)", 0x8004: "Fluorescent (daylight)",
        0x8010: "Cloudy", 0x8011: "Shade", 0x8012: "Color temperature",
        0x8020: "Custom 1", 0x8021: "Custom 2", 0x8022: "Custom 3", 0x8023: "Custom",
        0x8030: "Underwater auto",
    ]

    public static func shutterDisplay(_ v: UInt32) -> String {
        if v == 0 || v == 0xFFFF_FFFF { return "Bulb" }
        return PropertyFormat.shutter(numerator: Int64(v >> 16), denominator: Int64(v & 0xFFFF))
    }

    public static func isoDisplay(_ v: Int64) -> String {
        if v == Int64(Prop.isoAuto) { return "Auto" }
        // Bit 24+ carries the multi-frame-NR flavour; the ISO is the low 24 bits.
        return PropertyFormat.iso(v & 0x00FF_FFFF)
    }

    public static func property(for code: PTPDevicePropCode) -> TetherProperty? {
        switch code {
        case Prop.shutterSpeed: return .shutterSpeed
        case Prop.iso: return .iso
        case Prop.batteryLevel: return .batteryLevel
        case Prop.colorTemperature: return .colorTemperature
        case Prop.liveViewStatus: return .liveViewEnabled
        default: return GenericPTPHandler.standardProperty(code)
        }
    }

    public static func code(for p: TetherProperty) -> PTPDevicePropCode? {
        switch p {
        case .shutterSpeed: return Prop.shutterSpeed
        case .iso: return Prop.iso
        case .batteryLevel: return Prop.batteryLevel
        case .colorTemperature: return Prop.colorTemperature
        case .liveViewEnabled: return Prop.liveViewStatus
        case .captureDestination: return nil
        default: return GenericPTPHandler.standardCode(p)
        }
    }

    public static func display(_ p: TetherProperty, _ v: PTPValue) -> String {
        switch p {
        case .shutterSpeed: return shutterDisplay(UInt32(truncatingIfNeeded: v.uintValue ?? 0))
        case .iso: return isoDisplay(v.intValue ?? 0)
        case .whiteBalance: return whiteBalances[v.intValue ?? -1] ?? PropertyFormat.whiteBalance(standard: v.intValue ?? 0)
        case .colorTemperature: return "\(v.intValue ?? 0) K"
        default: return GenericPTPHandler.format(p, v)
        }
    }
}

/// One Sony extended DevicePropDesc: the standard dataset plus an
/// `isEnabled` byte after get/set, and (on newer firmware) a second
/// enumeration list with the values the camera will accept for writing.
public struct SonyPropDesc: Equatable, Sendable {
    public var code: PTPDevicePropCode
    public var dataType: PTPDataType
    public var isWritable: Bool
    public var isEnabled: Bool
    public var factoryDefault: PTPValue
    public var current: PTPValue
    public var form: PTPDevicePropDesc.Form
    /// The set-able values when the camera sent a second list.
    public var settable: [PTPValue]?

    public var choices: [PTPValue]? {
        if let s = settable, !s.isEmpty { return s }
        return form.enumerationValues
    }

    /// Parses an SDIOGetAllExtDevicePropInfo payload: UInt64 count, then
    /// records. Tries the two-list layout first and falls back to the
    /// single-list layout when the buffer does not divide cleanly.
    /// VERIFY: libgphoto2 `ptp_unpack_Sony_DPD` / `ptp_sony_getalldevicepropdesc`.
    public static func parseAll(_ data: Data) throws -> [SonyPropDesc] {
        if let two = try? parseAll(data, twoLists: true) { return two }
        return try parseAll(data, twoLists: false)
    }

    static func parseAll(_ data: Data, twoLists: Bool) throws -> [SonyPropDesc] {
        var b = ByteBuffer(data)
        let count = Int(try b.readUInt64())
        var out = [SonyPropDesc]()
        for _ in 0 ..< count {
            out.append(try SonyPropDesc(reading: &b, twoLists: twoLists))
        }
        guard b.isAtEnd else { throw PTPError.malformed("Sony property dump has \(b.remaining) trailing bytes") }
        return out
    }

    public init(reading b: inout ByteBuffer, twoLists: Bool) throws {
        code = PTPDevicePropCode(try b.readUInt16())
        dataType = PTPDataType(try b.readUInt16())
        isWritable = try b.readUInt8() == 1
        isEnabled = try b.readUInt8() != 0
        factoryDefault = try PTPValue.read(dataType, from: &b)
        current = try PTPValue.read(dataType, from: &b)
        let formFlag = try b.readUInt8()
        switch formFlag {
        case 1:
            let mn = try PTPValue.read(dataType, from: &b)
            let mx = try PTPValue.read(dataType, from: &b)
            let st = try PTPValue.read(dataType, from: &b)
            form = .range(min: mn, max: mx, step: st)
            settable = nil
        case 2:
            let n = Int(try b.readUInt16())
            var vals = [PTPValue]()
            for _ in 0 ..< n { vals.append(try PTPValue.read(dataType, from: &b)) }
            form = .enumeration(vals)
            if twoLists {
                let n2 = Int(try b.readUInt16())
                var second = [PTPValue]()
                for _ in 0 ..< n2 { second.append(try PTPValue.read(dataType, from: &b)) }
                settable = second
            } else {
                settable = nil
            }
        default:
            form = .none
            settable = nil
        }
    }

    public var encoded: Data {
        var b = ByteBuffer()
        b.write(code.rawValue); b.write(dataType.rawValue); b.write(UInt8(isWritable ? 1 : 0)); b.write(UInt8(isEnabled ? 1 : 0))
        factoryDefault.write(to: &b); current.write(to: &b)
        switch form {
        case .none: b.write(UInt8(0))
        case .range(let mn, let mx, let st): b.write(UInt8(1)); mn.write(to: &b); mx.write(to: &b); st.write(to: &b)
        case .enumeration(let vals):
            b.write(UInt8(2)); b.write(UInt16(vals.count)); vals.forEach { $0.write(to: &b) }
            if let s = settable { b.write(UInt16(s.count)); s.forEach { $0.write(to: &b) } }
        }
        return b.data
    }

    public init(code: PTPDevicePropCode, dataType: PTPDataType, isWritable: Bool, isEnabled: Bool = true, factoryDefault: PTPValue,
                current: PTPValue, form: PTPDevicePropDesc.Form, settable: [PTPValue]? = nil) {
        self.code = code; self.dataType = dataType; self.isWritable = isWritable; self.isEnabled = isEnabled
        self.factoryDefault = factoryDefault; self.current = current; self.form = form; self.settable = settable
    }

    /// Encodes a whole dump (UInt64 count + records).
    public static func encodeAll(_ descs: [SonyPropDesc]) -> Data {
        var b = ByteBuffer()
        b.write(UInt64(descs.count))
        for d in descs { b.write(d.encoded) }
        return b.data
    }
}

extension PTPDevicePropDesc.Form {
    var enumerationValues: [PTPValue]? {
        if case .enumeration(let v) = self { return v }
        return nil
    }
}

/// Sony Alpha: SDIO connect gate, property dump via 0x9209, half/full
/// shutter through control properties, fixed SDRAM handle, live view object.
public final class SonyHandler: VendorHandler, @unchecked Sendable {
    public let engine: PTPEngine
    public let info: PTPDeviceInfo
    public let vendor: CameraVendor = .sony
    public let capabilities: CameraCapabilities
    public let eventPollInterval: TimeInterval = 0.2

    private let generic: GenericPTPHandler
    private(set) var props: [PTPDevicePropCode: SonyPropDesc] = [:]
    private var destination: CaptureDestination = .both
    private var liveViewOn = false
    private var frameSequence: UInt64 = 0
    /// How long capture waits for FocusFound after the half-press.
    public var focusTimeout: TimeInterval = 2.0
    public var focusPollInterval: TimeInterval = 0.1

    public init(engine: PTPEngine, info: PTPDeviceInfo) {
        self.engine = engine
        self.info = info
        self.generic = GenericPTPHandler(engine: engine, info: info)
        var caps = CameraCapabilities()
        let sdio = info.supports(SonyCodes.Op.sdioConnect)
        if sdio, info.supports(SonyCodes.Op.sdioControlDevice) {
            caps.insert(.remoteCapture); caps.insert(.cardCapture); caps.insert(.sdramCapture); caps.insert(.autofocus); caps.insert(.liveView)
        } else if info.supports(.initiateCapture) {
            caps.insert(.remoteCapture); caps.insert(.cardCapture)
        }
        if sdio, info.supports(SonyCodes.Op.sdioSetExtDevicePropValue) { caps.insert(.propertyControl) }
        if info.supports(.getPartialObject) { caps.insert(.partialTransfer) }
        if info.supports(.getThumb) { caps.insert(.thumbnails) }
        capabilities = caps
    }

    // MARK: Gate

    public func prepare() async throws {
        guard info.supports(SonyCodes.Op.sdioConnect) else {
            throw PTPError.vendorGate("Set USB Connection to PC Remote on the camera (Setup → USB Connection / PC Remote Function) and reconnect.")
        }
        try await engine.run(SonyCodes.Op.sdioConnect, [SonyCodes.connectPhases[0], 0, 0])
        try await engine.run(SonyCodes.Op.sdioConnect, [SonyCodes.connectPhases[1], 0, 0])
        if info.supports(SonyCodes.Op.sdioGetExtDeviceInfo) {
            let r = try await engine.execute(PTPRequest(SonyCodes.Op.sdioGetExtDeviceInfo, parameters: [SonyCodes.extDeviceInfoVersion]))
            if !r.isOK {
                try await engine.run(SonyCodes.Op.sdioGetExtDeviceInfo, [SonyCodes.extDeviceInfoVersionFallback])
            }
        }
        try await engine.run(SonyCodes.Op.sdioConnect, [SonyCodes.connectPhases[2], 0, 0])
        _ = try? await refreshProps()
    }

    public func teardown() async {
        await stopLiveView()
    }

    // MARK: Capture

    public func setCaptureDestination(_ d: CaptureDestination) async throws {
        if d == .host {
            // VERIFY: "Still Image Save Destination: PC only" may be 0xD222; until
            // confirmed we only offer card and card+host.
            throw PTPError.unsupported("Set “Still Img. Save Dest.” to PC only on the camera itself; this app can only choose Card or Card + iPhone here.")
        }
        destination = d
    }

    func control(_ code: PTPDevicePropCode, _ value: UInt16) async throws {
        try await engine.run(SonyCodes.Op.sdioControlDevice, [UInt32(code.rawValue)], dataOut: PTPValue.uint16(value).encoded)
    }

    public func capture(autofocus: Bool) async throws {
        guard info.supports(SonyCodes.Op.sdioControlDevice) else {
            if info.supports(.initiateCapture) { try await engine.initiateCapture(); return }
            throw PTPError.unsupported("This Sony does not support remote capture over PTP.")
        }
        if autofocus {
            try await control(SonyCodes.Prop.shutterHalfRelease, SonyCodes.Prop.press)
            try await waitForFocus()
        }
        try await control(SonyCodes.Prop.shutterRelease, SonyCodes.Prop.press)
        try await control(SonyCodes.Prop.shutterRelease, SonyCodes.Prop.release)
        if autofocus {
            try await control(SonyCodes.Prop.shutterHalfRelease, SonyCodes.Prop.release)
        }
    }

    /// Polls FocusFound until locked or the timeout passes (then shoots anyway).
    func waitForFocus() async throws {
        guard info.supports(SonyCodes.Op.sdioGetAllExtDevicePropInfo) else { return }
        let deadline = Date().addingTimeInterval(focusTimeout)
        repeat {
            let dump = try await refreshProps()
            if let f = dump[SonyCodes.Prop.focusFound]?.current.intValue, f == SonyCodes.Prop.focusLocked { return }
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: UInt64(focusPollInterval * 1_000_000_000))
        } while true
    }

    // MARK: Events

    @discardableResult
    func refreshProps() async throws -> [PTPDevicePropCode: SonyPropDesc] {
        let r = try await engine.run(SonyCodes.Op.sdioGetAllExtDevicePropInfo, expectsLargeData: true)
        let parsed = try SonyPropDesc.parseAll(r.dataIn)
        var map = [PTPDevicePropCode: SonyPropDesc]()
        for d in parsed { map[d.code] = d }
        props = map
        return map
    }

    public func pollEvents() async throws -> [CameraEvent] {
        guard info.supports(SonyCodes.Op.sdioGetAllExtDevicePropInfo) else { return [] }
        let before = props
        let now = try await refreshProps()
        var out = [CameraEvent]()
        if let waiting = now[SonyCodes.Prop.objectInMemory]?.current.uintValue, waiting >= UInt64(SonyCodes.Prop.objectWaitingThreshold) {
            out.append(.objectAdded(NewObject(handle: SonyCodes.sdramHandle, inSDRAM: true)))
        }
        for (code, desc) in now where before[code]?.current != desc.current {
            if let p = SonyCodes.property(for: code), p != .liveViewEnabled { out.append(.propertyChanged(p)) }
        }
        return out
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? {
        switch event.code {
        case SonyCodes.Event.objectAdded:
            let h = event.parameters.first ?? SonyCodes.sdramHandle
            return .objectAdded(NewObject(handle: h == 0 ? SonyCodes.sdramHandle : h, inSDRAM: h == SonyCodes.sdramHandle || h == 0))
        case SonyCodes.Event.objectRemoved:
            return event.parameters.first.map { .objectRemoved(handle: $0) }
        case SonyCodes.Event.propertyChanged:
            // Values changed; the next poll picks them up.
            return .propertyChanged(event.parameters.first.flatMap { SonyCodes.property(for: PTPDevicePropCode(UInt16(truncatingIfNeeded: $0))) })
        default:
            return await generic.translate(event)
        }
    }

    // MARK: Properties

    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] {
        let dump: [PTPDevicePropCode: SonyPropDesc]
        if info.supports(SonyCodes.Op.sdioGetAllExtDevicePropInfo) { dump = try await refreshProps() } else { dump = [:] }
        var out = [PropertyDescriptor]()
        for p in properties {
            if p == .captureDestination {
                out.append(VendorProps.destinationDescriptor(current: destination, allowed: [.card, .both], writable: true))
                continue
            }
            guard let code = SonyCodes.code(for: p), let desc = dump[code] else { continue }
            out.append(Self.descriptor(p, desc, writable: capabilities.contains(.propertyControl)))
        }
        return out
    }

    static func descriptor(_ p: TetherProperty, _ desc: SonyPropDesc, writable: Bool) -> PropertyDescriptor {
        let form: PropertyDescriptor.Form
        if let vals = desc.choices, !vals.isEmpty {
            form = .choices(vals.map { PropertyChoice(raw: $0, display: SonyCodes.display(p, $0)) })
        } else if case .range(let mn, let mx, let st) = desc.form {
            form = .range(min: Double(mn.intValue ?? 0), max: Double(mx.intValue ?? 0), step: Double(st.intValue ?? 1))
        } else {
            form = .other
        }
        return PropertyDescriptor(property: p, raw: desc.current, display: SonyCodes.display(p, desc.current),
                                  isWritable: writable && desc.isWritable && desc.isEnabled, form: form)
    }

    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        if property == .captureDestination {
            guard let d = VendorProps.destination(fromRaw: raw) else { throw PTPError.unsupported("Unknown capture destination.") }
            try await setCaptureDestination(d)
            return
        }
        guard let code = SonyCodes.code(for: property) else { throw PTPError.unsupported("\(property.displayName) cannot be set on this camera.") }
        guard info.supports(SonyCodes.Op.sdioSetExtDevicePropValue) else {
            try await engine.setDevicePropValue(code, raw)
            return
        }
        try await engine.run(SonyCodes.Op.sdioSetExtDevicePropValue, [UInt32(code.rawValue)], dataOut: raw.encoded)
    }

    // MARK: Transfer

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        guard object.inSDRAM || object.handle == SonyCodes.sdramHandle else {
            return try await generic.fetchObject(object, progress: progress)
        }
        let oi = try await engine.getObjectInfo(object.handle)
        let data = try await engine.getObject(object.handle)
        progress?(data.count, data.count)
        return (oi, data)
    }

    // MARK: Live view

    public func startLiveView(quality: LiveViewQuality) async throws {
        guard capabilities.contains(.liveView) else { throw PTPError.unsupported("Live view is not available on this camera.") }
        liveViewOn = true
    }

    public func stopLiveView() async { liveViewOn = false }

    public func nextLiveViewFrame() async throws -> LiveViewFrame? {
        guard liveViewOn else { return nil }
        let r = try await engine.execute(PTPRequest(.getObjectInfo, parameters: [SonyCodes.liveViewHandle]))
        guard r.isOK else { return nil } // not streaming yet
        let r2 = try await engine.execute(PTPRequest(.getObject, parameters: [SonyCodes.liveViewHandle], expectsLargeData: true, timeout: 5))
        guard r2.isOK, let jpeg = r2.dataIn.jpegPayload() else { return nil }
        frameSequence += 1
        return LiveViewFrame(jpeg: jpeg, sequence: frameSequence)
    }
}
