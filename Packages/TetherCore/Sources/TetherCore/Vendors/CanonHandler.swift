import Foundation

/// Every Canon EOS constant lives here so a wrong one is fixed in one place.
/// Names follow libgphoto2 `ptp.h` (`PTP_OC_CANON_EOS_*`, `PTP_DPC_CANON_EOS_*`,
/// `PTP_EC_CANON_EOS_*`). Values marked VERIFY have not been checked against
/// a body from this code base.
public enum CanonCodes {
    public enum Op {
        public static let getStorageIDs = PTPOperationCode(0x9101)
        public static let getStorageInfo = PTPOperationCode(0x9102)
        public static let getObjectInfo = PTPOperationCode(0x9103)
        public static let getObject = PTPOperationCode(0x9104)
        public static let deleteObject = PTPOperationCode(0x9105)
        public static let formatStore = PTPOperationCode(0x9106)
        public static let getPartialObjectEx = PTPOperationCode(0x9107)
        public static let setObjectAttributes = PTPOperationCode(0x9108)
        public static let getObjectTime = PTPOperationCode(0x9109)
        public static let setObjectTime = PTPOperationCode(0x910A)
        public static let remoteRelease = PTPOperationCode(0x910F)
        public static let setDevicePropValueEx = PTPOperationCode(0x9110)
        public static let getRemoteMode = PTPOperationCode(0x9113)
        public static let setRemoteMode = PTPOperationCode(0x9114)
        public static let setEventMode = PTPOperationCode(0x9115)
        public static let getEvent = PTPOperationCode(0x9116)
        public static let transferComplete = PTPOperationCode(0x9117)
        public static let cancelTransfer = PTPOperationCode(0x9118)
        public static let resetTransfer = PTPOperationCode(0x9119)
        public static let pcHDDCapacity = PTPOperationCode(0x911A)
        public static let setUILock = PTPOperationCode(0x911B)
        public static let resetUILock = PTPOperationCode(0x911C)
        public static let keepDeviceOn = PTPOperationCode(0x911D)
        public static let requestDevicePropValue = PTPOperationCode(0x9127)
        public static let remoteReleaseOn = PTPOperationCode(0x9128)
        public static let remoteReleaseOff = PTPOperationCode(0x9129)
        public static let getViewFinderData = PTPOperationCode(0x9153)
        public static let doAf = PTPOperationCode(0x9154)
        public static let driveLens = PTPOperationCode(0x9155)
        public static let afCancel = PTPOperationCode(0x9160)
        public static let getPartialObjectEx64 = PTPOperationCode(0x9187) // VERIFY: libgphoto2 PTP_OC_CANON_EOS_GetPartialObjectEx64
    }

    public enum Prop {
        public static let aperture: UInt32 = 0xD101
        public static let shutterSpeed: UInt32 = 0xD102
        public static let iso: UInt32 = 0xD103
        public static let expCompensation: UInt32 = 0xD104
        public static let autoExposureMode: UInt32 = 0xD105
        public static let driveMode: UInt32 = 0xD106
        public static let meteringMode: UInt32 = 0xD107
        public static let focusMode: UInt32 = 0xD108
        public static let whiteBalance: UInt32 = 0xD109
        public static let colorTemperature: UInt32 = 0xD10A
        public static let pictureStyle: UInt32 = 0xD110
        public static let batteryPower: UInt32 = 0xD111
        public static let batterySelect: UInt32 = 0xD112
        public static let availableShots: UInt32 = 0xD11B
        public static let captureDestination: UInt32 = 0xD11C
        public static let lensName: UInt32 = 0xD1C0 // VERIFY: libgphoto2 PTP_DPC_CANON_EOS_LensName
        public static let evfOutputDevice: UInt32 = 0xD1B0
        public static let evfMode: UInt32 = 0xD1B3
        public static let evfWhiteBalance: UInt32 = 0xD1B4
        public static let evfZoom: UInt32 = 0xD1BC

        /// CaptureDestination values. VERIFY: libgphoto2 "capturetarget" uses
        /// 1 = memory card, 4 = internal RAM; 6 (card + RAM) is the EDSDK
        /// "both" value as observed in sniffs, not from libgphoto2.
        public static let destinationCard: UInt32 = 1
        public static let destinationHost: UInt32 = 4
        public static let destinationBoth: UInt32 = 6

        public static let evfOutputPC: UInt32 = 2
        public static let evfOutputOff: UInt32 = 0
    }

    public enum Event {
        public static let requestGetEvent: UInt32 = 0xC101
        public static let objectAddedEx: UInt32 = 0xC181
        public static let objectRemoved: UInt32 = 0xC182
        public static let requestGetObjectInfoEx: UInt32 = 0xC183
        public static let storageStatusChanged: UInt32 = 0xC184
        public static let storageInfoChanged: UInt32 = 0xC185
        public static let requestObjectTransfer: UInt32 = 0xC186
        public static let objectInfoChangedEx: UInt32 = 0xC187
        public static let objectContentChanged: UInt32 = 0xC188
        public static let propValueChanged: UInt32 = 0xC189 // VERIFY: libgphoto2 PTP_EC_CANON_EOS_PropValueChanged; some notes list 0xC186
        public static let availListChanged: UInt32 = 0xC18A // VERIFY: libgphoto2 PTP_EC_CANON_EOS_AvailListChanged; some notes list 0xC189
        public static let cameraStatusChanged: UInt32 = 0xC18B // VERIFY: libgphoto2 PTP_EC_CANON_EOS_CameraStatusChanged; some notes list 0xC18A
        public static let willSoonShutdown: UInt32 = 0xC18D // VERIFY: libgphoto2 PTP_EC_CANON_EOS_WillSoonShutdown; some notes list 0xC18B
        public static let shutdownTimerUpdated: UInt32 = 0xC18E
        public static let requestCancelTransfer: UInt32 = 0xC18F
        public static let requestObjectTransferDT: UInt32 = 0xC190
        public static let storeAdded: UInt32 = 0xC192
        public static let storeRemoved: UInt32 = 0xC193
        public static let bulbExposureTime: UInt32 = 0xC194
        public static let recordingTime: UInt32 = 0xC195
        public static let afResult: UInt32 = 0xC1A3
        public static let objectAddedEx64: UInt32 = 0xC1A7 // VERIFY: libgphoto2 PTP_EC_CANON_EOS_ObjectAddedEx64
        public static let objectAddedUnknown64: UInt32 = 0xC1A8 // VERIFY: libgphoto2 PTP_EC_CANON_EOS_ObjectAddedUnknown64
    }

    /// Offsets inside an ObjectAddedEx record (from the record start).
    /// VERIFY: libgphoto2 `PTP_ece_OA_*`.
    public enum ObjectAddedLayout {
        public static let handle = 8
        public static let storageID = 0x0C
        public static let format = 0x10
        public static let size = 0x1C
        public static let parent = 0x20
        public static let name = 0x28
        /// ObjectAddedEx64: 64-bit size, everything after shifts by 4.
        /// VERIFY: libgphoto2 `PTP_ece2_OA_*`.
        public static let size64 = 0x1C
        public static let parent64 = 0x24
        public static let name64 = 0x2C
    }

    /// GetViewFinderData record types.
    public static let viewFinderJPEGRecord: UInt32 = 1
    public static let viewFinderParam: UInt32 = 0x0010_0000 // VERIFY: libgphoto2 uses 0x00100000; newer bodies accept 0x00200000

    // MARK: Value tables (libgphoto2 camlibs/ptp2/config.c). All VERIFY.

    /// EOS aperture code → f-number. VERIFY: libgphoto2 `canon_aperture`.
    public static let apertures: [UInt32: Double] = [
        0x08: 1.0, 0x0B: 1.1, 0x0C: 1.2, 0x0D: 1.2, 0x10: 1.4, 0x13: 1.6, 0x14: 1.8, 0x15: 1.8,
        0x18: 2.0, 0x1B: 2.2, 0x1C: 2.5, 0x1D: 2.5, 0x20: 2.8, 0x23: 3.2, 0x24: 3.5, 0x25: 3.5,
        0x28: 4.0, 0x2B: 4.5, 0x2C: 4.5, 0x2D: 5.0, 0x30: 5.6, 0x33: 6.3, 0x34: 6.7, 0x35: 7.1,
        0x38: 8.0, 0x3B: 9.0, 0x3C: 9.5, 0x3D: 10, 0x40: 11, 0x43: 13, 0x44: 13, 0x45: 14,
        0x48: 16, 0x4B: 18, 0x4C: 19, 0x4D: 20, 0x50: 22, 0x53: 25, 0x54: 27, 0x55: 29,
        0x58: 32, 0x5B: 36, 0x5C: 38, 0x5D: 40, 0x60: 45, 0x63: 51, 0x64: 54, 0x65: 57,
        0x68: 64, 0x6B: 72, 0x6C: 76, 0x6D: 80, 0x70: 91,
    ]

    /// EOS shutter code → seconds (0 = bulb). VERIFY: libgphoto2 `canon_shutterspeed`.
    public static let shutters: [UInt32: Double] = [
        0x0C: 0, 0x10: 30, 0x13: 25, 0x14: 20, 0x15: 20, 0x18: 15, 0x1B: 13, 0x1C: 10, 0x1D: 10,
        0x20: 8, 0x23: 6, 0x24: 6, 0x25: 5, 0x28: 4, 0x2B: 3.2, 0x2C: 3, 0x2D: 2.5, 0x30: 2,
        0x33: 1.6, 0x34: 1.5, 0x35: 1.3, 0x38: 1, 0x3B: 0.8, 0x3C: 0.7, 0x3D: 0.6, 0x40: 0.5,
        0x43: 0.4, 0x44: 0.3, 0x45: 0.3, 0x48: 1.0 / 4, 0x4B: 1.0 / 5, 0x4C: 1.0 / 6, 0x4D: 1.0 / 6,
        0x50: 1.0 / 8, 0x53: 1.0 / 10, 0x54: 1.0 / 10, 0x55: 1.0 / 13, 0x58: 1.0 / 15, 0x5B: 1.0 / 20,
        0x5C: 1.0 / 20, 0x5D: 1.0 / 25, 0x60: 1.0 / 30, 0x63: 1.0 / 40, 0x64: 1.0 / 45, 0x65: 1.0 / 50,
        0x68: 1.0 / 60, 0x6B: 1.0 / 80, 0x6C: 1.0 / 90, 0x6D: 1.0 / 100, 0x70: 1.0 / 125, 0x73: 1.0 / 160,
        0x74: 1.0 / 180, 0x75: 1.0 / 200, 0x78: 1.0 / 250, 0x7B: 1.0 / 320, 0x7C: 1.0 / 350, 0x7D: 1.0 / 400,
        0x80: 1.0 / 500, 0x83: 1.0 / 640, 0x84: 1.0 / 750, 0x85: 1.0 / 800, 0x88: 1.0 / 1000, 0x8B: 1.0 / 1250,
        0x8C: 1.0 / 1500, 0x8D: 1.0 / 1600, 0x90: 1.0 / 2000, 0x93: 1.0 / 2500, 0x94: 1.0 / 3000, 0x95: 1.0 / 3200,
        0x98: 1.0 / 4000, 0x9B: 1.0 / 5000, 0x9C: 1.0 / 6000, 0x9D: 1.0 / 6400, 0xA0: 1.0 / 8000, 0xA3: 1.0 / 10000,
        0xA5: 1.0 / 12800, 0xA8: 1.0 / 16000,
    ]

    /// EOS ISO code → ISO (0 = Auto). VERIFY: libgphoto2 `canon_isospeed`.
    public static let isos: [UInt32: Int] = [
        0x00: 0, 0x28: 6, 0x30: 12, 0x38: 25, 0x40: 50, 0x43: 64, 0x45: 80, 0x48: 100, 0x4B: 125, 0x4D: 160,
        0x50: 200, 0x53: 250, 0x55: 320, 0x58: 400, 0x5B: 500, 0x5D: 640, 0x60: 800, 0x63: 1000, 0x65: 1250,
        0x68: 1600, 0x6B: 2000, 0x6D: 2500, 0x70: 3200, 0x73: 4000, 0x75: 5000, 0x78: 6400, 0x7B: 8000,
        0x7D: 10000, 0x80: 12800, 0x83: 16000, 0x85: 20000, 0x88: 25600, 0x8B: 32000, 0x8D: 40000,
        0x90: 51200, 0x93: 64000, 0x95: 80000, 0x98: 102400, 0xA0: 204800, 0xA8: 409600,
    ]

    /// EOS white balance. VERIFY: libgphoto2 `canon_whitebalance` (EOS column).
    public static let whiteBalances: [UInt32: String] = [
        0: "Auto", 1: "Daylight", 2: "Cloudy", 3: "Tungsten", 4: "Fluorescent", 5: "Flash", 6: "Manual",
        8: "Shade", 9: "Color temperature", 10: "Custom 1", 11: "Custom 2", 12: "Custom 3",
        15: "Manual 2", 16: "Manual 3", 18: "Manual 4", 19: "Manual 5", 20: "Custom 4", 21: "Custom 5",
        23: "Auto (white priority)",
    ]

    /// EOS BatteryPower levels. VERIFY: libgphoto2 `_get_Canon_EOS_BatteryLevel`.
    public static let batteryLevels: [UInt32: String] = [0: "Low", 1: "50%", 2: "100%", 4: "75%", 5: "25%"]

    /// Exposure compensation: signed 8-bit in 1/8 EV with 1/3-stop rounding
    /// (0x03 = +1/3, 0x04 = +1/2, 0x05 = +2/3, 0x08 = +1, 0xF8 = -1).
    /// VERIFY: libgphoto2 `canon_expcompensation`.
    public static func exposureCompensation(_ code: UInt32) -> String {
        let v = Int8(bitPattern: UInt8(truncatingIfNeeded: code))
        if v == 0 { return "0" }
        let sign = v < 0 ? "-" : "+"
        let eighths = Int(abs(Int(v)))
        let whole = eighths / 8
        let frac: String
        switch eighths % 8 {
        case 0: frac = ""
        case 3: frac = "1/3"
        case 4: frac = "1/2"
        case 5: frac = "2/3"
        default: frac = "\(eighths % 8)/8"
        }
        if whole == 0 { return sign + frac }
        return frac.isEmpty ? "\(sign)\(whole)" : "\(sign)\(whole) \(frac)"
    }

    public static func display(prop: UInt32, value: UInt32) -> String {
        switch prop {
        case Prop.aperture:
            // 0 = the lens reports no aperture (no lens, manual or adapted lens).
            if value == 0 { return "—" }
            guard let f = apertures[value] else { return String(format: "ƒ/?(0x%02X)", value) }
            return f == f.rounded() ? String(format: "ƒ/%.0f", f) : String(format: "ƒ/%.1f", f)
        case Prop.shutterSpeed:
            guard let s = shutters[value] else { return String(format: "?(0x%02X)", value) }
            return PropertyFormat.shutter(seconds: s)
        case Prop.iso:
            guard let i = isos[value] else { return String(format: "ISO ?(0x%02X)", value) }
            return i == 0 ? "Auto" : "\(i)"
        case Prop.expCompensation: return exposureCompensation(value)
        case Prop.whiteBalance: return whiteBalances[value] ?? "WB \(value)"
        case Prop.batteryPower: return batteryLevels[value] ?? "\(value)%"
        case Prop.captureDestination:
            switch value {
            case Prop.destinationCard: return CaptureDestination.card.displayName
            case Prop.destinationHost: return CaptureDestination.host.displayName
            case Prop.destinationBoth: return CaptureDestination.both.displayName
            default: return "Destination \(value)"
            }
        case Prop.colorTemperature: return "\(value) K"
        default: return "\(value)"
        }
    }

    public static func property(for prop: UInt32) -> TetherProperty? {
        switch prop {
        case Prop.aperture: return .aperture
        case Prop.shutterSpeed: return .shutterSpeed
        case Prop.iso: return .iso
        case Prop.expCompensation: return .exposureCompensation
        case Prop.whiteBalance: return .whiteBalance
        case Prop.colorTemperature: return .colorTemperature
        case Prop.autoExposureMode: return .exposureProgram
        case Prop.driveMode: return .driveMode
        case Prop.meteringMode: return .meteringMode
        case Prop.focusMode: return .focusMode
        case Prop.pictureStyle: return .pictureStyle
        case Prop.batteryPower: return .batteryLevel
        case Prop.availableShots: return .storageFreeImages
        case Prop.captureDestination: return .captureDestination
        case Prop.evfMode: return .liveViewEnabled
        case Prop.lensName: return .lensName
        default: return nil
        }
    }

    public static func code(for p: TetherProperty) -> UInt32? {
        switch p {
        case .aperture: return Prop.aperture
        case .shutterSpeed: return Prop.shutterSpeed
        case .iso: return Prop.iso
        case .exposureCompensation: return Prop.expCompensation
        case .whiteBalance: return Prop.whiteBalance
        case .colorTemperature: return Prop.colorTemperature
        case .exposureProgram: return Prop.autoExposureMode
        case .driveMode: return Prop.driveMode
        case .meteringMode: return Prop.meteringMode
        case .focusMode: return Prop.focusMode
        case .pictureStyle: return Prop.pictureStyle
        case .batteryLevel: return Prop.batteryPower
        case .storageFreeImages: return Prop.availableShots
        case .captureDestination: return Prop.captureDestination
        case .liveViewEnabled: return Prop.evfMode
        case .lensName: return Prop.lensName
        default: return nil
        }
    }

    /// Properties the camera never lets us write.
    public static let readOnly: Set<UInt32> = [Prop.batteryPower, Prop.availableShots, Prop.lensName]
}

/// One record of a Canon EOS GetEvent dump.
public struct CanonEventRecord: Equatable, Sendable {
    public var type: UInt32
    /// Raw record bytes including the 8-byte (size, type) header.
    public var bytes: [UInt8]

    /// Splits a GetEvent payload. Stops at the terminator (size 8, type 0)
    /// or when a size does not fit.
    public static func parse(_ data: Data) -> [CanonEventRecord] {
        var out = [CanonEventRecord]()
        let bytes = [UInt8](data)
        var pos = 0
        while pos + 8 <= bytes.count {
            var b = ByteBuffer(Array(bytes[pos ..< pos + 8]))
            let size = Int((try? b.readUInt32()) ?? 0)
            let type = (try? b.readUInt32()) ?? 0
            if size < 8 || pos + size > bytes.count { break }
            if size == 8, type == 0 { break }
            out.append(CanonEventRecord(type: type, bytes: Array(bytes[pos ..< pos + size])))
            pos += size
        }
        return out
    }

    func u32(at offset: Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for i in 0 ..< 4 { v |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
        return v
    }

    func u64(at offset: Int) -> UInt64? {
        guard offset + 8 <= bytes.count else { return nil }
        var v: UInt64 = 0
        for i in 0 ..< 8 { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        return v
    }

    func u16(at offset: Int) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /// ASCII NUL-terminated string at `offset`.
    func cString(at offset: Int) -> String {
        guard offset < bytes.count else { return "" }
        let slice = bytes[offset...]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[slice.startIndex ..< end], as: UTF8.self)
    }
}

/// Canon EOS: PC remote mode, polled GetEvent stream, EOS property codes,
/// two-stage shutter, SDRAM transfer and EVF live view.
public final class CanonHandler: VendorHandler, @unchecked Sendable {
    public let engine: PTPEngine
    public let info: PTPDeviceInfo
    public let vendor: CameraVendor = .canon
    public let capabilities: CameraCapabilities
    public let eventPollInterval: TimeInterval = 0.2

    private let generic: GenericPTPHandler
    /// Last known value per EOS property (filled from the event stream).
    private(set) var values: [UInt32: UInt32] = [:]
    /// Allowed values per EOS property (AvailListChanged).
    private(set) var available: [UInt32: [UInt32]] = [:]
    private var pending: [CameraEvent] = []
    private var destination: CaptureDestination = .card
    private var liveViewOn = false
    private var frameSequence: UInt64 = 0

    public init(engine: PTPEngine, info: PTPDeviceInfo) {
        self.engine = engine
        self.info = info
        self.generic = GenericPTPHandler(engine: engine, info: info)
        var caps = CameraCapabilities()
        let twoStage = info.supports(CanonCodes.Op.remoteReleaseOn)
        if twoStage || info.supports(CanonCodes.Op.remoteRelease) {
            caps.insert(.remoteCapture); caps.insert(.cardCapture)
        }
        if info.supports(CanonCodes.Op.getPartialObjectEx), info.supports(CanonCodes.Op.transferComplete) {
            caps.insert(.sdramCapture)
        }
        if info.supports(CanonCodes.Op.getPartialObjectEx) || info.supports(.getPartialObject) { caps.insert(.partialTransfer) }
        if info.supports(CanonCodes.Op.getViewFinderData) { caps.insert(.liveView) }
        if info.supports(CanonCodes.Op.setDevicePropValueEx) { caps.insert(.propertyControl) }
        if twoStage || info.supports(CanonCodes.Op.doAf) { caps.insert(.autofocus) }
        if info.supports(.getThumb) { caps.insert(.thumbnails) }
        if info.supports(CanonCodes.Op.remoteReleaseOn) { caps.insert(.bulbCapture) }
        capabilities = caps
    }

    // MARK: Gate

    public func prepare() async throws {
        guard info.supports(CanonCodes.Op.setRemoteMode) else {
            throw PTPError.vendorGate("This Canon does not offer PC remote mode over this connection.")
        }
        try await engine.run(CanonCodes.Op.setRemoteMode, [1])
        if info.supports(CanonCodes.Op.setEventMode) { try await engine.run(CanonCodes.Op.setEventMode, [1]) }
        // The first dump carries every property and its allowed values.
        _ = try await fetchEvents()
    }

    public func teardown() async {
        await stopLiveView()
        if info.supports(CanonCodes.Op.setEventMode) { _ = try? await engine.execute(PTPRequest(CanonCodes.Op.setEventMode, parameters: [0])) }
        _ = try? await engine.execute(PTPRequest(CanonCodes.Op.setRemoteMode, parameters: [0]))
    }

    // MARK: Capture

    public func setCaptureDestination(_ d: CaptureDestination) async throws {
        let value: UInt32
        switch d {
        case .card: value = CanonCodes.Prop.destinationCard
        case .host:
            guard capabilities.contains(.sdramCapture) else { throw PTPError.unsupported("This Canon cannot keep captures in memory for transfer.") }
            value = CanonCodes.Prop.destinationHost
        case .both:
            guard capabilities.contains(.sdramCapture) else { throw PTPError.unsupported("This Canon cannot keep captures in memory for transfer.") }
            value = CanonCodes.Prop.destinationBoth
        }
        try await setEOSProperty(CanonCodes.Prop.captureDestination, value)
        destination = d
    }

    public func capture(autofocus: Bool) async throws {
        if info.supports(CanonCodes.Op.remoteReleaseOn) {
            // VERIFY: libgphoto2 camera_canon_eos_capture — RemoteReleaseOn(1,0)
            // half-press, (2,0) full press, RemoteReleaseOff(2) then (1).
            // Without AF libgphoto2 sends 3 (full press, no AF) on both.
            // Drain queued events first: EOS bodies report busy while their
            // event queue is full (common right after connecting).
            _ = try? await fetchEvents().forEach { pending.append($0) }
            do {
                if autofocus {
                    do {
                        try await press(1)
                    } catch let error where Self.isBusy(error) {
                        // AF could not start or lock (manual lens, nothing to
                        // focus on): fire without AF rather than not at all.
                        try await press(3)
                        return
                    }
                    do {
                        try await press(2)
                    } catch {
                        await release([1])   // don't leave it half-pressed
                        throw error
                    }
                    await release([2, 1])
                } else {
                    try await press(3)
                }
            } catch let error where Self.isBusy(error) {
                throw PTPError.vendorGate("The camera won't fire. Check a lens is attached and focused, the camera isn't showing a menu or playback, and the card isn't full.")
            }
        } else if info.supports(CanonCodes.Op.remoteRelease) {
            try await engine.run(CanonCodes.Op.remoteRelease, timeout: 15)
        } else {
            throw PTPError.unsupported("This Canon does not support remote capture over PTP.")
        }
    }

    /// One shutter stage; a failed press releases what it held.
    private func press(_ stage: UInt32) async throws {
        do {
            try await engine.run(CanonCodes.Op.remoteReleaseOn, [stage, 0], timeout: 15)
        } catch {
            await release([stage])
            throw error
        }
        if stage == 3 { await release([3]) }
    }

    /// Releases never throw: a stuck half-press is worse than a lost error.
    private func release(_ stages: [UInt32]) async {
        for stage in stages { _ = try? await engine.execute(PTPRequest(CanonCodes.Op.remoteReleaseOff, parameters: [stage])) }
    }

    static func isBusy(_ error: Error) -> Bool {
        if case .response(_, let code, _)? = error as? PTPError { return code == .deviceBusy }
        return false
    }

    // MARK: Events

    public func pollEvents() async throws -> [CameraEvent] {
        var out = pending
        pending.removeAll()
        out.append(contentsOf: try await fetchEvents())
        return out
    }

    private func fetchEvents() async throws -> [CameraEvent] {
        guard info.supports(CanonCodes.Op.getEvent) else { return [] }
        let r = try await engine.run(CanonCodes.Op.getEvent, expectsLargeData: true)
        return ingest(r.dataIn)
    }

    /// Parses a GetEvent dump, updates the property caches and returns the
    /// vendor-neutral events.
    @discardableResult
    func ingest(_ dump: Data) -> [CameraEvent] {
        var out = [CameraEvent]()
        for rec in CanonEventRecord.parse(dump) {
            switch rec.type {
            case CanonCodes.Event.objectAddedEx, CanonCodes.Event.objectAddedEx64, CanonCodes.Event.objectAddedUnknown64:
                if let obj = Self.objectAdded(rec, is64: rec.type != CanonCodes.Event.objectAddedEx, destination: destination) {
                    out.append(.objectAdded(obj))
                }
            case CanonCodes.Event.objectRemoved:
                if let h = rec.u32(at: 8) { out.append(.objectRemoved(handle: h)) }
            case CanonCodes.Event.propValueChanged:
                guard let prop = rec.u32(at: 8) else { continue }
                if rec.bytes.count >= 16, let v = rec.u32(at: 12) { values[prop] = v }
                out.append(.propertyChanged(CanonCodes.property(for: prop)))
            case CanonCodes.Event.availListChanged:
                guard let prop = rec.u32(at: 8), let count = rec.u32(at: 16) else { continue }
                var vals = [UInt32]()
                var off = 20
                for _ in 0 ..< min(Int(count), (rec.bytes.count - 20) / 4) {
                    if let v = rec.u32(at: off) { vals.append(v) }
                    off += 4
                }
                available[prop] = vals
                out.append(.propertyChanged(CanonCodes.property(for: prop)))
            case CanonCodes.Event.cameraStatusChanged:
                out.append(.cameraBusy((rec.u32(at: 8) ?? 0) != 0))
            case CanonCodes.Event.willSoonShutdown:
                out.append(.warning("The camera is about to power off."))
            case CanonCodes.Event.storeAdded, CanonCodes.Event.storeRemoved, CanonCodes.Event.storageInfoChanged, CanonCodes.Event.storageStatusChanged:
                out.append(.storageChanged)
            case CanonCodes.Event.bulbExposureTime, CanonCodes.Event.recordingTime, CanonCodes.Event.afResult,
                 CanonCodes.Event.shutdownTimerUpdated, CanonCodes.Event.requestGetEvent:
                continue
            default:
                out.append(.raw(PTPEvent(code: PTPEventCode(UInt16(truncatingIfNeeded: rec.type)), parameters: [rec.u32(at: 8) ?? 0])))
            }
        }
        return out
    }

    static func objectAdded(_ rec: CanonEventRecord, is64: Bool, destination: CaptureDestination) -> NewObject? {
        typealias L = CanonCodes.ObjectAddedLayout
        guard let handle = rec.u32(at: L.handle), handle != 0 else { return nil }
        let storage = rec.u32(at: L.storageID) ?? 0
        let format = PTPObjectFormat(rec.u16(at: L.format) ?? 0)
        let size: UInt64
        let parent: UInt32
        let name: String
        if is64 {
            size = rec.u64(at: L.size64) ?? 0
            parent = rec.u32(at: L.parent64) ?? 0
            name = rec.cString(at: L.name64)
        } else {
            size = UInt64(rec.u32(at: L.size) ?? 0)
            parent = rec.u32(at: L.parent) ?? 0
            name = rec.cString(at: L.name)
        }
        var info = PTPObjectInfo(storageID: storage, objectFormat: format, objectCompressedSize: UInt32(truncatingIfNeeded: min(size, UInt64(UInt32.max))),
                                 parentObject: parent, filename: name)
        if format.rawValue == 0, !name.isEmpty { info.objectFormat = .undefined }
        // VERIFY: host-memory objects report storage 0 (or 0x8000xxxx on some bodies).
        let inRAM = storage == 0 || (storage & 0xFFFF_0000) == 0x8000_0000 || destination != .card
        return NewObject(handle: handle, storageID: storage, info: info, inSDRAM: inRAM)
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? {
        switch UInt32(event.code.rawValue) {
        case CanonCodes.Event.requestGetEvent:
            // The camera asks us to poll; the next pollEvents does.
            return nil
        case CanonCodes.Event.objectAddedEx, CanonCodes.Event.objectAddedEx64:
            return event.parameters.first.map { .objectAdded(NewObject(handle: $0, inSDRAM: destination != .card)) }
        case CanonCodes.Event.propValueChanged, CanonCodes.Event.availListChanged:
            return .propertyChanged(event.parameters.first.flatMap { CanonCodes.property(for: $0) })
        case CanonCodes.Event.cameraStatusChanged:
            return .cameraBusy((event.parameters.first ?? 0) != 0)
        case CanonCodes.Event.willSoonShutdown:
            return .warning("The camera is about to power off.")
        default:
            return await generic.translate(event)
        }
    }

    // MARK: Properties

    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] {
        // Refresh the caches; events seen here are handed to the next poll.
        pending.append(contentsOf: try await fetchEvents())
        var out = [PropertyDescriptor]()
        for p in properties {
            guard let code = CanonCodes.code(for: p), let v = values[code] else { continue }
            out.append(descriptor(p, code: code, value: v))
        }
        return out
    }

    /// Descriptor from the cache alone (no camera round trip).
    func descriptor(_ p: TetherProperty, code: UInt32, value: UInt32) -> PropertyDescriptor {
        let writable = capabilities.contains(.propertyControl) && !CanonCodes.readOnly.contains(code)
        var choices = (available[code] ?? []).map { PropertyChoice(raw: .uint32($0), display: CanonCodes.display(prop: code, value: $0)) }
        if code == CanonCodes.Prop.captureDestination, choices.isEmpty {
            var allowed = [CanonCodes.Prop.destinationCard]
            if capabilities.contains(.sdramCapture) { allowed += [CanonCodes.Prop.destinationHost, CanonCodes.Prop.destinationBoth] }
            choices = allowed.map { PropertyChoice(raw: .uint32($0), display: CanonCodes.display(prop: code, value: $0)) }
        }
        return PropertyDescriptor(property: p, raw: .uint32(value), display: CanonCodes.display(prop: code, value: value),
                                  isWritable: writable, form: choices.isEmpty ? .other : .choices(choices))
    }

    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        guard let code = CanonCodes.code(for: property), !CanonCodes.readOnly.contains(code) else {
            throw PTPError.unsupported("\(property.displayName) cannot be set on this camera.")
        }
        guard let v = raw.uintValue else { throw PTPError.unsupported("\(property.displayName) needs a numeric value.") }
        try await setEOSProperty(code, UInt32(truncatingIfNeeded: v))
        if code == CanonCodes.Prop.captureDestination {
            switch UInt32(truncatingIfNeeded: v) {
            case CanonCodes.Prop.destinationHost: destination = .host
            case CanonCodes.Prop.destinationBoth: destination = .both
            default: destination = .card
            }
        }
    }

    /// SetDevicePropValueEx payload: UInt32 size (12), UInt32 propCode, UInt32 value.
    public static func setPropertyPayload(_ code: UInt32, _ value: UInt32) -> Data {
        var b = ByteBuffer()
        b.write(UInt32(12)); b.write(code); b.write(value)
        return b.data
    }

    func setEOSProperty(_ code: UInt32, _ value: UInt32) async throws {
        guard info.supports(CanonCodes.Op.setDevicePropValueEx) else { throw PTPError.unsupported("This Canon does not allow setting properties over PTP.") }
        try await engine.run(CanonCodes.Op.setDevicePropValueEx, dataOut: Self.setPropertyPayload(code, value))
        values[code] = value
    }

    // MARK: Transfer

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        guard object.inSDRAM, info.supports(CanonCodes.Op.getPartialObjectEx) else {
            return try await generic.fetchObject(object, progress: progress)
        }
        var oi = object.info
        if oi == nil || oi?.objectCompressedSize == 0 { oi = try await engine.getObjectInfo(object.handle) }
        guard let infoOut = oi else { throw PTPError.malformed("No ObjectInfo for Canon SDRAM object") }
        let total = infoOut.objectCompressedSize
        var out = Data()
        out.reserveCapacity(Int(total))
        var offset: UInt32 = 0
        let chunk = await engine.partialChunkSize
        while offset < total {
            try Task.checkCancellation()
            let want = min(chunk, total - offset)
            let r = try await engine.run(CanonCodes.Op.getPartialObjectEx, [object.handle, offset, want], expectsLargeData: true, timeout: 60)
            if r.dataIn.isEmpty { throw PTPError.malformed("GetPartialObjectEx returned no data at \(offset)") }
            out.append(r.dataIn)
            offset += UInt32(r.dataIn.count)
            progress?(out.count, Int(total))
        }
        if info.supports(CanonCodes.Op.transferComplete) {
            try await engine.run(CanonCodes.Op.transferComplete, [object.handle])
        }
        return (infoOut, out)
    }

    // MARK: Live view

    public func startLiveView(quality: LiveViewQuality) async throws {
        guard capabilities.contains(.liveView) else { throw PTPError.unsupported("Live view is not available on this camera.") }
        try await setEOSProperty(CanonCodes.Prop.evfMode, 1)
        try await setEOSProperty(CanonCodes.Prop.evfOutputDevice, CanonCodes.Prop.evfOutputPC)
        liveViewOn = true
    }

    public func stopLiveView() async {
        guard liveViewOn else { return }
        liveViewOn = false
        _ = try? await setEOSProperty(CanonCodes.Prop.evfOutputDevice, CanonCodes.Prop.evfOutputOff)
    }

    public func nextLiveViewFrame() async throws -> LiveViewFrame? {
        guard liveViewOn else { return nil }
        let r = try await engine.execute(PTPRequest(CanonCodes.Op.getViewFinderData, parameters: [CanonCodes.viewFinderParam], expectsLargeData: true, timeout: 5))
        switch r.code {
        case .ok: break
        case .deviceBusy, .accessDenied: return nil // frame not ready yet
        default: throw PTPError.response(op: CanonCodes.Op.getViewFinderData, code: r.code, parameters: r.parameters)
        }
        guard let jpeg = Self.viewFinderJPEG(r.dataIn) else { return nil }
        frameSequence += 1
        return LiveViewFrame(jpeg: jpeg, sequence: frameSequence)
    }

    /// GetViewFinderData payload is a record stream (UInt32 size, UInt32 type,
    /// payload); the JPEG is the record of type 1. Falls back to scanning
    /// for the SOI marker.
    public static func viewFinderJPEG(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var pos = 0
        while pos + 8 <= bytes.count {
            var b = ByteBuffer(Array(bytes[pos ..< pos + 8]))
            let size = Int((try? b.readUInt32()) ?? 0)
            let type = (try? b.readUInt32()) ?? 0
            guard size >= 8, pos + size <= bytes.count else { break }
            if type == CanonCodes.viewFinderJPEGRecord {
                let payload = Data(bytes[(pos + 8) ..< (pos + size)])
                return payload.jpegPayload() ?? payload
            }
            pos += size
        }
        return data.jpegPayload()
    }
}
