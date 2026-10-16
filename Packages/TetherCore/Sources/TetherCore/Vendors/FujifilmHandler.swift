import Foundation

/// Fujifilm constants (libgphoto2 `PTP_DPC_FUJI_*`). Fuji control is mostly
/// standard PTP; the extras are properties. VERIFY marks the unconfirmed ones.
public enum FujifilmCodes {
    public enum Op {
        public static let getObjectInfoEx = PTPOperationCode(0x900C)  // VERIFY: libgphoto2 PTP_OC_FUJI_GetDeviceInfo neighbours
        public static let getDeviceInfo = PTPOperationCode(0x900C)    // VERIFY
    }

    public enum Prop {
        public static let filmSimulation = PTPDevicePropCode(0xD001)      // VERIFY: libgphoto2 PTP_DPC_FUJI_FilmSimulation
        public static let imageQuality = PTPDevicePropCode(0xD018)        // VERIFY: libgphoto2 PTP_DPC_FUJI_Quality
        public static let releaseMode = PTPDevicePropCode(0xD201)         // VERIFY
        public static let priorityMode = PTPDevicePropCode(0xD207)        // VERIFY: libgphoto2 PTP_DPC_FUJI_PriorityMode
        public static let currentState = PTPDevicePropCode(0xD212)        // VERIFY: libgphoto2 PTP_DPC_FUJI_CurrentState (event list)
        public static let shutterSpeed2 = PTPDevicePropCode(0xD240)       // VERIFY: libgphoto2 PTP_DPC_FUJI_ShutterSpeed2
        public static let captureRemaining = PTPDevicePropCode(0xD229)    // VERIFY
        public static let batteryInfo = PTPDevicePropCode(0xD36A)         // VERIFY

        /// PriorityMode value that hands exposure control to the host. VERIFY: 2 = "PC/USB".
        public static let priorityPC: UInt16 = 2
    }

    /// Film simulations. VERIFY: libgphoto2 `fuji_filmsimulation`.
    public static let filmSimulations: [Int64: String] = [
        1: "Provia", 2: "Velvia", 3: "Astia", 4: "Monochrome", 5: "Sepia", 6: "Pro Neg. Hi", 7: "Pro Neg. Std",
        8: "Monochrome + Ye", 9: "Monochrome + R", 10: "Monochrome + G", 11: "Classic Chrome", 12: "Acros",
        13: "Acros + Ye", 14: "Acros + R", 15: "Acros + G", 16: "Eterna", 17: "Classic Negative",
        18: "Eterna Bleach Bypass", 19: "Nostalgic Neg.", 20: "Reala Ace",
    ]

    /// Fuji white balance adds its own codes. VERIFY: libgphoto2 `fuji_whitebalance`.
    public static func whiteBalanceDisplay(_ v: Int64) -> String {
        switch v {
        case 0x8001: return "Fluorescent (daylight)"
        case 0x8002: return "Fluorescent (warm white)"
        case 0x8003: return "Fluorescent (cool white)"
        case 0x8006: return "Shade"
        case 0x8008: return "Underwater"
        case 0x8010: return "Color temperature"
        case 0x8020: return "Custom 1"
        case 0x8021: return "Custom 2"
        case 0x8022: return "Custom 3"
        default: return PropertyFormat.whiteBalance(standard: v)
        }
    }

    public static func code(for p: TetherProperty) -> PTPDevicePropCode? {
        switch p {
        case .pictureStyle: return Prop.filmSimulation
        case .imageQuality: return Prop.imageQuality
        default: return GenericPTPHandler.standardCode(p)
        }
    }

    public static func property(for code: PTPDevicePropCode) -> TetherProperty? {
        switch code {
        case Prop.filmSimulation: return .pictureStyle
        case Prop.imageQuality: return .imageQuality
        default: return GenericPTPHandler.standardProperty(code)
        }
    }

    public static func display(_ p: TetherProperty, _ v: PTPValue) -> String {
        switch p {
        case .pictureStyle: return filmSimulations[v.intValue ?? -1] ?? "Film \(v.intValue ?? 0)"
        case .whiteBalance: return whiteBalanceDisplay(v.intValue ?? 0)
        case .shutterSpeed:
            // VERIFY: Fuji ExposureTime is the standard 1/10 000 s on X-T bodies.
            return GenericPTPHandler.format(p, v)
        default: return GenericPTPHandler.format(p, v)
        }
    }
}

/// Fujifilm X / GFX: tether priority gate, standard capture, CurrentState
/// property events, object-handle diff for new files (RAW+JPEG arrive as
/// two objects).
public final class FujifilmHandler: VendorHandler, @unchecked Sendable {
    public let engine: PTPEngine
    public let info: PTPDeviceInfo
    public let vendor: CameraVendor = .fujifilm
    public let capabilities: CameraCapabilities
    public let eventPollInterval: TimeInterval = 0.5

    private let generic: GenericPTPHandler
    public let differ = ObjectHandleDiffer()
    private var lastState: [PTPDevicePropCode: UInt32] = [:]

    public init(engine: PTPEngine, info: PTPDeviceInfo) {
        self.engine = engine
        self.info = info
        self.generic = GenericPTPHandler(engine: engine, info: info)
        var caps = CameraCapabilities()
        if info.supports(.initiateCapture) { caps.insert(.remoteCapture); caps.insert(.cardCapture); caps.insert(.autofocus) }
        if info.supports(.setDevicePropValue), !info.devicePropertiesSupported.isEmpty { caps.insert(.propertyControl) }
        if info.supports(.getPartialObject) { caps.insert(.partialTransfer) }
        if info.supports(.getThumb) { caps.insert(.thumbnails) }
        capabilities = caps
    }

    // MARK: Gate

    public func prepare() async throws {
        if info.supports(FujifilmCodes.Prop.priorityMode) {
            let desc = try await engine.getDevicePropDesc(FujifilmCodes.Prop.priorityMode)
            if desc.isWritable, desc.current.intValue != Int64(FujifilmCodes.Prop.priorityPC) {
                try await engine.setDevicePropValue(FujifilmCodes.Prop.priorityMode, PTPValue.make(desc.dataType, Int64(FujifilmCodes.Prop.priorityPC)))
            }
        }
        await differ.seed(engine: engine)
    }

    public func teardown() async {}

    // MARK: Capture

    public func setCaptureDestination(_ destination: CaptureDestination) async throws {
        if destination != .card { throw PTPError.unsupported("Fujifilm bodies write to the card; the file is copied over afterwards.") }
    }

    public func capture(autofocus: Bool) async throws {
        guard info.supports(.initiateCapture) else {
            throw PTPError.vendorGate("Set the camera to USB TETHER SHOOTING AUTO (or PC connection for Wi-Fi) and reconnect.")
        }
        try await engine.run(.initiateCapture, [0, 0], timeout: 30)
    }

    // MARK: Events

    /// CurrentState payload: UInt16 count, then (UInt16 code, UInt32 value).
    /// VERIFY: layout from libgphoto2's Fuji event handling.
    public static func parseCurrentState(_ data: Data) throws -> [(PTPDevicePropCode, UInt32)] {
        var b = ByteBuffer(data)
        guard b.remaining >= 2 else { return [] }
        let n = Int(try b.readUInt16())
        var out = [(PTPDevicePropCode, UInt32)]()
        for _ in 0 ..< n {
            guard b.remaining >= 6 else { break }
            out.append((PTPDevicePropCode(try b.readUInt16()), try b.readUInt32()))
        }
        return out
    }

    public func pollEvents() async throws -> [CameraEvent] {
        var out = [CameraEvent]()
        if info.supports(FujifilmCodes.Prop.currentState) {
            let data = try await engine.getRawPropValue(FujifilmCodes.Prop.currentState.rawValue)
            for (code, value) in try Self.parseCurrentState(data) where lastState[code] != value {
                lastState[code] = value
                if let p = FujifilmCodes.property(for: code) { out.append(.propertyChanged(p)) }
            }
        }
        out.append(contentsOf: try await differ.poll(engine: engine))
        return out
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? {
        if event.code == .objectAdded, let h = event.parameters.first {
            _ = differ.diff([h]) // keep the differ from re-announcing a pushed handle
        }
        return await generic.translate(event)
    }

    // MARK: Properties

    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] {
        var out = try await VendorProps.readStandard(engine: engine, info: info, properties, code: FujifilmCodes.code(for:), format: FujifilmCodes.display)
        if properties.contains(.captureDestination) {
            out.append(VendorProps.destinationDescriptor(current: .card, allowed: [.card], writable: false))
        }
        return out
    }

    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        guard let c = FujifilmCodes.code(for: property), info.supports(c) else {
            throw PTPError.unsupported("\(property.displayName) cannot be set on this camera.")
        }
        try await engine.setDevicePropValue(c, raw)
    }

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        try await generic.fetchObject(object, progress: progress)
    }
}
