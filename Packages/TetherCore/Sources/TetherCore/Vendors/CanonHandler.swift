import Foundation
#if canImport(os)
import os

private let canonLogger = Logger(subsystem: "com.bradyjordan.tether", category: "canon")
/// Console trail for Canon transfers (filter Xcode's console on "[Canon]").
func canonLog(_ message: String) { canonLogger.notice("[Canon] \(message, privacy: .public)") }
#else
func canonLog(_ message: String) {}
#endif

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
        /// 3 args: type, x, y (libgphoto2 ptp.h); x/y in the AF coordinate
        /// space FocusInfoEx reports.
        public static let touchAfPosition = PTPOperationCode(0x915B)
        public static let driveLens = PTPOperationCode(0x9155)
        public static let afCancel = PTPOperationCode(0x9160)
        /// Turns on OLCInfoChanged events (libgphoto2 sends mask 0x1FFF when preparing to capture).
        public static let setRequestOLCInfoGroup = PTPOperationCode(0x913D)
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
        /// Layout version of OLCInfoChanged records (libgphoto2 PTP_DPC_CANON_EOS_OLCInfoVersion).
        public static let olcInfoVersion: UInt32 = 0xD199
        public static let whiteBalance: UInt32 = 0xD109
        public static let colorTemperature: UInt32 = 0xD10A
        public static let pictureStyle: UInt32 = 0xD110
        public static let batteryPower: UInt32 = 0xD111
        public static let batterySelect: UInt32 = 0xD112
        public static let availableShots: UInt32 = 0xD11B
        public static let captureDestination: UInt32 = 0xD11C
        public static let lensName: UInt32 = 0xD1C0 // VERIFY: libgphoto2 PTP_DPC_CANON_EOS_LensName
        public static let evfOutputDevice: UInt32 = 0xD1B0
        /// FocusInfoEx: AF points plus the AF coordinate space (width, height).
        public static let focusInfoEx: UInt32 = 0xD1D3
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
        /// On-screen info changes, incl. the live AF state (libgphoto2 PTP_EC_CANON_EOS_OLCInfoChanged).
        public static let olcInfoChanged: UInt32 = 0xC1A5
        public static let objectAddedEx64: UInt32 = 0xC1A7 // VERIFY: libgphoto2 PTP_EC_CANON_EOS_ObjectAddedEx64
        public static let objectAddedUnknown64: UInt32 = 0xC1A8 // VERIFY: libgphoto2 PTP_EC_CANON_EOS_ObjectAddedUnknown64
        public static let requestObjectTransfer64: UInt32 = 0xC1A9
        /// Newer bodies (R-series): same as above with no filename. libgphoto2 PTP_EC_CANON_EOS_RequestObjectTransfer64LFN.
        public static let requestObjectTransfer64LFN: UInt32 = 0xC1B8
    }

    /// Offsets inside a RequestObjectTransfer record (libgphoto2 `PTP_cee_OI_*`);
    /// the 64-bit variant uses the same ones, the LFN variant has no name.
    public enum TransferRequestLayout {
        public static let handle = 8
        public static let format = 0x0C
        public static let size = 0x14
        public static let name = 0x1C
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

    /// FocusMode (0xD108) values (libgphoto2 eos_focusmodes): 0 One Shot,
    /// 1 AI Servo, 2 AI Focus, 3 Manual.
    public static let focusModeOneShot: UInt32 = 0
    public static let focusModeServo: UInt32 = 1
    public static let focusModeAIFocus: UInt32 = 2

    /// OLCInfoChanged field sizes per layout version, for mask bits 0x1…0x1000
    /// (libgphoto2 ptp-pack.c `olcsizes`; 0x14 confirmed there on R8, R10, R5 Mark II).
    public static let olcSizes: [[Int]] = [
        [], [], [], [], [], [], [],
        [2, 6, 5, 4, 4, 6, 7, 4, 6, 5, 5, 8, 1],  // 0x07
        [2, 6, 5, 4, 4, 6, 7, 4, 6, 7, 7, 8, 1],  // 0x08
        [2, 6, 5, 4, 4, 6, 7, 4, 6, 7, 7, 8, 1],  // 0x09
        [2, 6, 5, 4, 4, 6, 7, 4, 6, 7, 7, 8, 1],  // 0x0A
        [2, 6, 5, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1],  // 0x0B
        [2, 6, 5, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1],  // 0x0C
        [2, 6, 5, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1],  // 0x0D
        [2, 6, 5, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1],  // 0x0E
        [2, 7, 6, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1],  // 0x0F
        [2, 7, 6, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1],  // 0x10
        [2, 7, 6, 6, 4, 6, 8, 4, 6, 5, 5, 9, 8],  // 0x11 EOS R
        [2, 7, 9, 6, 4, 6, 8, 5, 7, 5, 5, 9, 8],  // 0x12
        [2, 7, 9, 7, 4, 6, 8, 5, 7, 5, 5, 9, 8],  // 0x13 R5, R5 C
        [2, 9, 9, 7, 4, 6, 8, 5, 7, 5, 5, 9, 8],  // 0x14 R8, R10, R5 Mark II
    ]
    /// OLC field carrying the AF state.
    public static let olcFocusInfoMask: UInt16 = 0x0100

    /// GetViewFinderData record types.
    public static let viewFinderJPEGRecord: UInt32 = 1
    /// TouchAfPosition `type` argument. VERIFY on hardware: libgphoto2
    /// leaves it to the caller; 0 is assumed to mean "move the AF frame".
    public static let touchAfType: UInt32 = 0

    /// Canon "not ready" (live view still starting).
    public static let notReady = PTPResponseCode(0xA102)
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
    /// AF coordinate space from FocusInfoEx, once the body has sent it.
    private(set) var afCoordinateSpace: (width: Int, height: Int)?
    private var liveViewStarted = Date.distantPast
    private var liveViewHasFrame = false
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
        if info.supports(CanonCodes.Op.touchAfPosition), info.supports(CanonCodes.Op.getViewFinderData) { caps.insert(.touchAutofocus) }
        capabilities = caps
    }

    // MARK: Gate

    public func prepare() async throws {
        guard info.supports(CanonCodes.Op.setRemoteMode) else {
            throw PTPError.vendorGate("This Canon does not offer PC remote mode over this connection.")
        }
        try await engine.run(CanonCodes.Op.setRemoteMode, [1])
        if info.supports(CanonCodes.Op.setEventMode) { try await engine.run(CanonCodes.Op.setEventMode, [1]) }
        // OLC events carry the live AF state touch focus waits on.
        if info.supports(CanonCodes.Op.setRequestOLCInfoGroup) {
            _ = try? await engine.execute(PTPRequest(CanonCodes.Op.setRequestOLCInfoGroup, parameters: [0x1FFF]))
        }
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
        try await reportHostCapacity()
    }

    /// With captures going to the host, the body needs to hear how much room
    /// the host has; without it, it assumes none, shows "PC full" and refuses
    /// to fire (DeviceBusy). libgphoto2 sends the same fixed, large figure.
    private func reportHostCapacity() async throws {
        guard destination != .card, info.supports(CanonCodes.Op.pcHDDCapacity) else { return }
        try await engine.run(CanonCodes.Op.pcHDDCapacity, [0x0FFF_FFFF, 0x0000_1000, 0x0000_0001])
    }

    public func capture(autofocus: Bool) async throws {
        await restoreFocusModeAfterTouch()
        if info.supports(CanonCodes.Op.remoteReleaseOn) {
            // VERIFY: libgphoto2 camera_canon_eos_capture — RemoteReleaseOn(1,0)
            // half-press, (2,0) full press, RemoteReleaseOff(2) then (1).
            // Without AF libgphoto2 sends 3 (full press, no AF) on both.
            // Drain queued events first: EOS bodies report busy while their
            // event queue is full (common right after connecting).
            _ = try? await fetchEvents().forEach { pending.append($0) }
            // Re-assert the phone's free space: bodies forget it (sleep, card swap).
            try? await reportHostCapacity()
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
                    // Card copies while shooting to the phone arrive again as a
                    // transfer request; only one of the two is downloaded.
                    if obj.inSDRAM || destination == .card { out.append(.objectAdded(obj)) }
                }
            case CanonCodes.Event.requestObjectTransfer, CanonCodes.Event.requestObjectTransfer64, CanonCodes.Event.requestObjectTransfer64LFN:
                // A capture waiting in the body's memory; it holds the card
                // and stays busy until we take it.
                if let obj = Self.transferRequest(rec, hasName: rec.type != CanonCodes.Event.requestObjectTransfer64LFN) {
                    out.append(.objectAdded(obj))
                }
            case CanonCodes.Event.olcInfoChanged:
                if let state = Self.olcFocusState(rec, version: values[CanonCodes.Prop.olcInfoVersion] ?? 0) {
                    noteAFState(state)
                }
            case CanonCodes.Event.objectRemoved:
                if let h = rec.u32(at: 8) { out.append(.objectRemoved(handle: h)) }
            case CanonCodes.Event.propValueChanged:
                guard let prop = rec.u32(at: 8) else { continue }
                if rec.bytes.count >= 16, let v = rec.u32(at: 12) { values[prop] = v }
                if prop == CanonCodes.Prop.focusInfoEx {
                    if let space = Self.afCoordinateSpace(fromFocusInfoRecord: rec) { afCoordinateSpace = space }
                    if Self.focusInfoHasFocusedPoints(rec) { focusInfoReportedFocus = true }
                }
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

    /// FocusInfoEx blob (starts at byte 12 of the record): u32 size, u16
    /// halfsize, u16 version, u16 points, u16 in use, u16 sizeX, u16 sizeY…
    /// (libgphoto2 ptp_unpack_EOS_FocusInfoEx).
    static func afCoordinateSpace(fromFocusInfoRecord rec: CanonEventRecord) -> (width: Int, height: Int)? {
        guard let w = rec.u16(at: 12 + 12), let h = rec.u16(at: 12 + 14), w > 0, h > 0 else { return nil }
        return (Int(w), Int(h))
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
        let inRAM = storage == 0 || (storage & 0xFFFF_0000) == 0x8000_0000
        return NewObject(handle: handle, storageID: storage, info: info, inSDRAM: inRAM)
    }

    static func transferRequest(_ rec: CanonEventRecord, hasName: Bool) -> NewObject? {
        typealias L = CanonCodes.TransferRequestLayout
        guard let handle = rec.u32(at: L.handle), handle != 0 else { return nil }
        let format = PTPObjectFormat(rec.u16(at: L.format) ?? 0)
        let size = rec.u32(at: L.size) ?? 0
        var name = hasName ? rec.cString(at: L.name) : ""
        if name.isEmpty { name = String(format: "IMG_%04X.%@", handle & 0xFFFF, Self.fileExtension(for: format)) }
        let info = PTPObjectInfo(storageID: 0, objectFormat: format, objectCompressedSize: size, parentObject: 0, filename: name)
        return NewObject(handle: handle, storageID: 0, info: info, inSDRAM: true)
    }

    /// Extension for a nameless capture, from its object format (libgphoto2 PTP_OFC_CANON_*).
    static func fileExtension(for format: PTPObjectFormat) -> String {
        switch format.rawValue {
        case 0xB108: return "CR3"
        case 0xB101, 0xB103: return "CR2"
        case 0xB10A, 0xB110: return "HIF" // VERIFY: Canon HEIF format code
        case 0x3801: return "JPG"
        default: return "JPG"
        }
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? {
        switch UInt32(event.code.rawValue) {
        case CanonCodes.Event.requestGetEvent:
            // The camera asks us to poll; the next pollEvents does.
            return nil
        case CanonCodes.Event.requestObjectTransfer, CanonCodes.Event.requestObjectTransfer64, CanonCodes.Event.requestObjectTransfer64LFN:
            return event.parameters.first.map { .objectAdded(NewObject(handle: $0, inSDRAM: true)) }
        case CanonCodes.Event.objectAddedEx, CanonCodes.Event.objectAddedEx64:
            guard destination == .card else { return nil }
            return event.parameters.first.map { .objectAdded(NewObject(handle: $0, inSDRAM: false)) }
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
        if oi == nil || oi?.objectCompressedSize == 0 {
            // Memory objects often refuse GetObjectInfo; a short timeout keeps
            // a refusal from stalling the queue.
            if let fetched = try? PTPObjectInfo(parsing: try await engine.execute(PTPRequest(.getObjectInfo, parameters: [object.handle], timeout: 5)).dataIn) {
                oi = fetched
            }
        }
        guard let infoOut = oi, infoOut.objectCompressedSize > 0 else {
            await finishTransfer(object.handle)
            throw PTPError.malformed("The camera didn't say how big capture \(object.handle) is.")
        }
        let total = infoOut.objectCompressedSize
        canonLog("transfer \(String(object.handle, radix: 16)) \(infoOut.filename) \(total) bytes")
        do {
            let data = try await downloadFromMemory(object.handle, total: total, progress: progress)
            await finishTransfer(object.handle)
            canonLog("transfer \(String(object.handle, radix: 16)) done")
            return (infoOut, data)
        } catch {
            // Even a failed transfer must be closed, or the body holds the
            // card and stays busy until it is switched off.
            canonLog("transfer \(String(object.handle, radix: 16)) failed: \(error)")
            await finishTransfer(object.handle)
            throw error
        }
    }

    /// 1 MB GetPartialObject reads, as libgphoto2 does: "the EOS R does not
    /// like 5MB", and Canon's own 0x9107 is suspected of crashing newer bodies.
    /// 0x9107 is kept only for bodies without the standard operation.
    private func downloadFromMemory(_ handle: UInt32, total: UInt32, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> Data {
        let op: PTPOperationCode = info.supports(.getPartialObject) ? .getPartialObject : CanonCodes.Op.getPartialObjectEx
        let chunk: UInt32 = 1 << 20
        var out = Data()
        out.reserveCapacity(Int(total))
        var offset: UInt32 = 0
        while offset < total {
            try Task.checkCancellation()
            let want = min(chunk, total - offset)
            let r = try await engine.run(op, [handle, offset, want], expectsLargeData: true, timeout: 20)
            if r.dataIn.isEmpty { throw PTPError.malformed("The camera sent no data at byte \(offset) of \(total).") }
            out.append(r.dataIn)
            offset += UInt32(r.dataIn.count)
            progress?(out.count, Int(total))
        }
        return out
    }

    private func finishTransfer(_ handle: UInt32) async {
        guard info.supports(CanonCodes.Op.transferComplete) else { return }
        _ = try? await engine.execute(PTPRequest(CanonCodes.Op.transferComplete, parameters: [handle], timeout: 5))
    }

    // MARK: Live view

    public func startLiveView(quality: LiveViewQuality) async throws {
        guard capabilities.contains(.liveView) else { throw PTPError.unsupported("Live view is not available on this camera.") }
        try await setEOSProperty(CanonCodes.Prop.evfMode, 1)
        try await setEOSProperty(CanonCodes.Prop.evfOutputDevice, CanonCodes.Prop.evfOutputPC)
        liveViewOn = true
        liveViewStarted = Date()
        liveViewHasFrame = false
        // Ask for FocusInfoEx so touch AF knows the coordinate space.
        if afCoordinateSpace == nil, info.supports(CanonCodes.Op.requestDevicePropValue) {
            _ = try? await engine.execute(PTPRequest(CanonCodes.Op.requestDevicePropValue, parameters: [CanonCodes.Prop.focusInfoEx]))
            if let events = try? await fetchEvents() { pending.append(contentsOf: events) }
        }
    }

    /// Touch AF: move the AF point to the tapped spot, then focus there.
    // MARK: Touch AF
    //
    // How Canon's own software handles AF: EOS Utility has AF ON / OFF
    // buttons and AF "continues until you click OFF"; Camera Connect's AF
    // button is a half-press. Servo never "finishes" (bodies don't even
    // confirm focus in Servo), so nothing here guesses with a timer:
    //  - a tap focuses once and stops on the camera's own lock / fail
    //    report (OLCInfoChanged focus info; FocusInfoEx in-focus points as
    //    a fallback). In Servo / AI Focus the tap runs in One Shot so there
    //    is a lock to wait for; the user's mode comes back as soon as it lands.
    //  - press and hold tracks in the user's own mode (AF ON) until the
    //    finger lifts (AF OFF), like EOS Utility.

    /// AF state from OLC focus info, latched per touch: libgphoto2 traces
    /// show success as 00-01 → 01-01 → 00-00 (R8 skips straight from 01-01
    /// to 00-00) and failure as 00-01 → 02-01 → 02-00 → 00-00 (R5 Mark II).
    public enum AFState: Equatable, Sendable { case idle, running, focused, failed }

    private var afOutcome: FocusResult?
    private var afSawRunning = false
    private var focusInfoReportedFocus = false
    private var trackingFocus = false

    private func noteAFState(_ state: AFState) {
        switch state {
        case .running: afSawRunning = true
        case .focused: if afOutcome == nil { afOutcome = .focused }
        case .failed: if afOutcome == nil { afOutcome = .failed }
        case .idle: break
        }
    }

    /// The body reports AF state through OLC events (needs the request op
    /// and a known layout version).
    var olcFocusAvailable: Bool {
        info.supports(CanonCodes.Op.setRequestOLCInfoGroup) && (values[CanonCodes.Prop.olcInfoVersion] ?? 0) >= 7
    }

    public func focus(atNormalizedX nx: Double, y ny: Double) async throws -> FocusResult {
        guard capabilities.contains(.touchAutofocus) else { throw PTPError.unsupported("Touch focus is not available on this camera.") }
        if trackingFocus { await stopTrackingFocus() }
        await useOneShotForTouchAF()
        do {
            try await moveAFPoint(nx, ny)
            guard info.supports(CanonCodes.Op.doAf) else {
                await restoreFocusModeAfterTouch()
                return .unconfirmed
            }
            let result = try await runAFUntilReported()
            canonLog("touch AF: \(result)")
            // Still tracking (the switch to One Shot was refused): stop it now
            // that the camera has had its say, so the lens doesn't keep hunting.
            if focusModeBeforeTouch == nil, tracksContinuously, info.supports(CanonCodes.Op.afCancel) {
                _ = try? await engine.execute(PTPRequest(CanonCodes.Op.afCancel, timeout: 5))
            }
            await restoreFocusModeAfterTouch()
            return result
        } catch {
            await restoreFocusModeAfterTouch()
            throw error
        }
    }

    /// AF ON at a point, in the user's own AF mode, until `stopTrackingFocus`.
    public func startTrackingFocus(atNormalizedX nx: Double, y ny: Double) async throws {
        guard capabilities.contains(.touchAutofocus), info.supports(CanonCodes.Op.doAf) else {
            throw PTPError.unsupported("Touch focus is not available on this camera.")
        }
        await restoreFocusModeAfterTouch()
        try await moveAFPoint(nx, ny)
        try await engine.run(CanonCodes.Op.doAf, timeout: 10)
        trackingFocus = true
        canonLog("touch AF: tracking")
    }

    /// AF OFF.
    public func stopTrackingFocus() async {
        guard trackingFocus else { return }
        trackingFocus = false
        if info.supports(CanonCodes.Op.afCancel) {
            _ = try? await engine.execute(PTPRequest(CanonCodes.Op.afCancel, timeout: 5))
        }
        canonLog("touch AF: tracking stopped")
    }

    private var tracksContinuously: Bool {
        let mode = values[CanonCodes.Prop.focusMode]
        return mode == CanonCodes.focusModeServo || mode == CanonCodes.focusModeAIFocus
    }

    private func moveAFPoint(_ nx: Double, _ ny: Double) async throws {
        // VERIFY: fallback space when the body has not sent FocusInfoEx yet
        // (EOS R full-sensor AF coordinates).
        let space = afCoordinateSpace ?? (8192, 5464)
        let x = UInt32(max(0, min(1, nx)) * Double(space.width - 1))
        let y = UInt32(max(0, min(1, ny)) * Double(space.height - 1))
        try await engine.run(CanonCodes.Op.touchAfPosition, [CanonCodes.touchAfType, x, y])
    }

    /// DoAf, then poll until the body says focused or failed. The limit only
    /// covers a body that never reports; it doesn't decide focus.
    private func runAFUntilReported() async throws -> FocusResult {
        if let events = try? await fetchEvents() { pending.append(contentsOf: events) }   // stale state out
        afOutcome = nil
        afSawRunning = false
        focusInfoReportedFocus = false
        try await engine.run(CanonCodes.Op.doAf, timeout: 10)
        let olc = olcFocusAvailable
        let limit = olc ? Self.touchAfReportTimeout : Self.touchAfFallbackTime
        let started = Date()
        while Date().timeIntervalSince(started) < limit {
            if let events = try? await fetchEvents() { pending.append(contentsOf: events) }
            if let outcome = afOutcome { return outcome }
            // Without OLC, FocusInfoEx listing in-focus points is libgphoto2's cue.
            if !olc, focusInfoReportedFocus { return .focused }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return .unconfirmed
    }

    /// Longest wait for the body's AF report (slow lenses in low light take
    /// several seconds; libgphoto2 allows up to 8 s for a half-press).
    static let touchAfReportTimeout: TimeInterval = 8
    /// Bodies with no AF report: how long to show "focusing".
    static let touchAfFallbackTime: TimeInterval = 2.5

    /// OLC focus info: byte 4 is the result (1 focused, 2 failed), byte 5 is
    /// "AF running" (libgphoto2 ptp-pack.c, mask 0x0100).
    static func olcFocusState(_ rec: CanonEventRecord, version: UInt32) -> AFState? {
        guard version >= 7 else { return nil }
        let row = CanonCodes.olcSizes[min(Int(version), CanonCodes.olcSizes.count - 1)]
        guard row.count == 13, let mask = rec.u16(at: 12), mask & CanonCodes.olcFocusInfoMask != 0 else { return nil }
        var offset = 16
        for bit in 0 ..< 8 where mask & (1 << bit) != 0 { offset += row[bit] }
        guard offset + 5 < rec.bytes.count else { return nil }
        let result = rec.bytes[offset + 4], running = rec.bytes[offset + 5]
        switch result {
        case 1: return .focused
        case 2: return .failed
        default: return running != 0 ? .running : .idle
        }
    }

    /// FocusInfoEx (blob at record byte 12): after the point table comes a
    /// bitmask of the points AF settled on; libgphoto2 reads "none" as not
    /// in focus.
    static func focusInfoHasFocusedPoints(_ rec: CanonEventRecord) -> Bool {
        let base = 12
        guard let inStruct = rec.u16(at: base + 8), let inUse = rec.u16(at: base + 10),
              inStruct > 0, inUse > 0, inUse <= inStruct else { return false }
        let maskStart = base + 20 + Int(inStruct) * 8
        for i in 0 ..< Int(inUse) {
            let byte = maskStart + i / 8
            guard byte < rec.bytes.count else { return false }
            if rec.bytes[byte] & UInt8(1 << (i % 8)) != 0 { return true }
        }
        return false
    }

    /// The user's AF mode while a tap has the body in One Shot.
    private var focusModeBeforeTouch: UInt32?

    private func useOneShotForTouchAF() async {
        guard let mode = values[CanonCodes.Prop.focusMode],
              mode == CanonCodes.focusModeServo || mode == CanonCodes.focusModeAIFocus,
              capabilities.contains(.propertyControl) else { return }
        do {
            try await setEOSProperty(CanonCodes.Prop.focusMode, CanonCodes.focusModeOneShot)
            if focusModeBeforeTouch == nil { focusModeBeforeTouch = mode }
            canonLog("touch AF: One Shot for the tap (was \(mode))")
        } catch {
            // Body won't switch (mode locked): the tap runs in Servo and is
            // stopped once the camera has reported.
            canonLog("touch AF: couldn't switch to One Shot: \(error)")
        }
    }

    /// Puts the user's AF mode back, unless they changed it on the body meanwhile.
    func restoreFocusModeAfterTouch() async {
        guard let mode = focusModeBeforeTouch else { return }
        focusModeBeforeTouch = nil
        guard values[CanonCodes.Prop.focusMode] == CanonCodes.focusModeOneShot else { return }
        _ = try? await setEOSProperty(CanonCodes.Prop.focusMode, mode)
        canonLog("touch AF: restored AF mode \(mode)")
    }

    /// Without a first frame by then, the body is not going to send one.
    static let liveViewStartTimeout: TimeInterval = 8

    public func stopLiveView() async {
        guard liveViewOn else { return }
        liveViewOn = false
        await stopTrackingFocus()
        await restoreFocusModeAfterTouch()
        _ = try? await setEOSProperty(CanonCodes.Prop.evfOutputDevice, CanonCodes.Prop.evfOutputOff)
    }

    public func nextLiveViewFrame() async throws -> LiveViewFrame? {
        guard liveViewOn else { return nil }
        let r = try await engine.execute(PTPRequest(CanonCodes.Op.getViewFinderData, parameters: [CanonCodes.viewFinderParam],
                                                    expectsLargeData: true, timeout: 5, retriesBusy: false))
        switch r.code {
        case .ok: break
        case .deviceBusy, .accessDenied, CanonCodes.notReady:
            // Frame not ready yet; but a body that never sends one gets a reason, not an endless spinner.
            if !liveViewHasFrame, Date().timeIntervalSince(liveViewStarted) > Self.liveViewStartTimeout {
                throw PTPError.vendorGate("The camera isn't sending live view. Check a lens is attached and the camera is on its shooting screen, not a menu or playback.")
            }
            return nil
        default: throw PTPError.response(op: CanonCodes.Op.getViewFinderData, code: r.code, parameters: r.parameters)
        }
        guard let jpeg = Self.viewFinderJPEG(r.dataIn) else { return nil }
        liveViewHasFrame = true
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
