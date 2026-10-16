import Foundation

/// Nikon constants, named after libgphoto2 `ptp.h` (`PTP_OC_NIKON_*`,
/// `PTP_DPC_NIKON_*`, `PTP_EC_NIKON_*`). VERIFY marks the unconfirmed ones.
public enum NikonCodes {
    public enum Op {
        public static let getProfileAllData = PTPOperationCode(0x9006)
        public static let changeApplicationMode = PTPOperationCode(0x9038) // VERIFY: Z-series gate; candidate from libgphoto2 PTP_OC_NIKON_ChangeApplicationMode
        public static let initiateCaptureRecInSdram = PTPOperationCode(0x90C0)
        public static let afDrive = PTPOperationCode(0x90C1)
        public static let changeCameraMode = PTPOperationCode(0x90C2) // VERIFY: libgphoto2 PTP_OC_NIKON_ChangeCameraMode; second gate candidate
        public static let deleteImagesInSdram = PTPOperationCode(0x90C3)
        public static let getLargeThumb = PTPOperationCode(0x90C4)
        public static let getEvent = PTPOperationCode(0x90C7)
        public static let deviceReady = PTPOperationCode(0x90C8)
        public static let setPreWBData = PTPOperationCode(0x90C9)
        public static let getVendorPropCodes = PTPOperationCode(0x90CA)
        public static let afCaptureSDRAM = PTPOperationCode(0x90CB)
        public static let getPictCtrlData = PTPOperationCode(0x90CC)
        public static let setPictCtrlData = PTPOperationCode(0x90CD)
        public static let getDevicePTPIPInfo = PTPOperationCode(0x90E0)
        public static let getPreviewImg = PTPOperationCode(0x9200)
        public static let startLiveView = PTPOperationCode(0x9201)
        public static let endLiveView = PTPOperationCode(0x9202)
        public static let getLiveViewImg = PTPOperationCode(0x9203)
        public static let mfDrive = PTPOperationCode(0x9204)
        public static let changeAfArea = PTPOperationCode(0x9205)
        public static let afDriveCancel = PTPOperationCode(0x9206)
        public static let initiateCaptureRecInMedia = PTPOperationCode(0x9207)
        public static let getVendorStorageIDs = PTPOperationCode(0x9209)
        public static let startMovieRecInCard = PTPOperationCode(0x920A)
        public static let endMovieRec = PTPOperationCode(0x920B)
        public static let terminateCapture = PTPOperationCode(0x920C)
        public static let getPartialObjectHiSpeed = PTPOperationCode(0x9400) // VERIFY
    }

    public enum Prop {
        public static let shutterSpeed = PTPDevicePropCode(0xD100)
        public static let externalFlashAttached = PTPDevicePropCode(0xD120)
        public static let liveViewStatus = PTPDevicePropCode(0xD1A2)
        public static let liveViewImageZoomRatio = PTPDevicePropCode(0xD1A3)
        public static let liveViewProhibitCondition = PTPDevicePropCode(0xD1A4)
        public static let liveViewImageSize = PTPDevicePropCode(0xD1AC) // VERIFY
        public static let exposureIndexEx = PTPDevicePropCode(0xD1C5)   // VERIFY
        public static let bulbShutter: UInt32 = 0xFFFF_FFFF
    }

    public enum Event {
        public static let objectAddedInSdram = PTPEventCode(0xC101)
        public static let captureCompleteRecInSdram = PTPEventCode(0xC102)
        public static let advancedTransfer = PTPEventCode(0xC103)
        public static let previewImageAdded = PTPEventCode(0xC104)
        public static let movieRecordInterrupted = PTPEventCode(0xC105)
        public static let firstCaptureComplete = PTPEventCode(0xC107) // VERIFY
        public static let mirrorUpAfterShoot = PTPEventCode(0xC108)   // VERIFY
    }

    /// Handle Nikon assigns to the image waiting in SDRAM.
    public static let sdramHandle: UInt32 = 0xFFFF_0001

    /// InitiateCaptureRecInMedia parameters. VERIFY: libgphoto2 passes
    /// (af ? 0 : 0xFFFFFFFF, sdram+card ? 1 : 0).
    public static let captureNoAF: UInt32 = 0xFFFF_FFFF

    /// LiveViewProhibitCondition bits → why live view is refused.
    /// VERIFY: libgphoto2 `_get_Nikon_LiveViewProhibitCondition`.
    public static let prohibitReasons: [Int: String] = [
        0: "Recording destination is the card",
        2: "Sequence error",
        4: "Shutter button fully pressed",
        5: "Aperture ring is not set to minimum",
        6: "Bulb exposure warning",
        7: "Mirror is up",
        8: "Battery exhausted",
        9: "TTL error",
        11: "Mode dial is not on a shooting mode",
        12: "Minimum aperture warning",
        14: "Capture in progress",
        15: "Sensor cleaning",
        16: "Camera temperature too high",
        17: "No lens attached",
    ]

    public static func prohibitDescription(_ bits: UInt32) -> String {
        var reasons = [String]()
        for bit in 0 ..< 32 where bits & (1 << UInt32(bit)) != 0 {
            reasons.append(prohibitReasons[bit] ?? "Condition bit \(bit)")
        }
        return reasons.isEmpty ? "Live view is blocked by the camera." : "Live view is blocked: " + reasons.joined(separator: "; ") + "."
    }

    /// Nikon ShutterSpeed 0xD100: UInt32 numerator << 16 | denominator; 0xFFFFFFFF = bulb.
    public static func shutterDisplay(_ v: UInt32) -> String {
        if v == Prop.bulbShutter { return "Bulb" }
        return PropertyFormat.shutter(numerator: Int64(v >> 16), denominator: Int64(v & 0xFFFF))
    }

    /// Nikon WhiteBalance extends the standard codes with 0x8010+.
    /// VERIFY: libgphoto2 `nikon_whitebalance`.
    public static func whiteBalanceDisplay(_ v: Int64) -> String {
        switch v {
        case 0x8010: return "Cloudy"
        case 0x8011: return "Shade"
        case 0x8012: return "Color temperature"
        case 0x8013: return "Preset"
        case 0x8014: return "Natural light auto"
        default: return PropertyFormat.whiteBalance(standard: v)
        }
    }
}

/// Nikon: DeviceReady gate (Z bodies also need the application-mode switch),
/// polled GetEvent, SDRAM capture on 0xFFFF0001, live view with the
/// prohibit-condition check.
public final class NikonHandler: VendorHandler, @unchecked Sendable {
    public let engine: PTPEngine
    public let info: PTPDeviceInfo
    public let vendor: CameraVendor = .nikon
    public let capabilities: CameraCapabilities
    public let eventPollInterval: TimeInterval = 0.25

    private let generic: GenericPTPHandler
    private var destination: CaptureDestination = .card
    private var liveViewOn = false
    private var frameSequence: UInt64 = 0
    private let sdramCapable: Bool
    /// DeviceReady retries before giving up (each waits 100 ms).
    public var readyAttempts = 50

    public init(engine: PTPEngine, info: PTPDeviceInfo) {
        self.engine = engine
        self.info = info
        self.generic = GenericPTPHandler(engine: engine, info: info)
        let sdram = info.supports(NikonCodes.Op.initiateCaptureRecInSdram) || info.supports(NikonCodes.Op.afCaptureSDRAM)
        let card = info.supports(.initiateCapture) || info.supports(NikonCodes.Op.initiateCaptureRecInMedia)
        sdramCapable = sdram
        var caps = CameraCapabilities()
        if sdram || card { caps.insert(.remoteCapture) }
        if sdram { caps.insert(.sdramCapture) }
        if card { caps.insert(.cardCapture) }
        if info.supports(NikonCodes.Op.startLiveView), info.supports(NikonCodes.Op.getLiveViewImg) { caps.insert(.liveView) }
        if info.supports(.setDevicePropValue), !info.devicePropertiesSupported.isEmpty { caps.insert(.propertyControl) }
        if info.supports(.getPartialObject) { caps.insert(.partialTransfer) }
        if info.supports(NikonCodes.Op.afCaptureSDRAM) || info.supports(NikonCodes.Op.afDrive) { caps.insert(.autofocus) }
        if info.supports(.getThumb) || info.supports(NikonCodes.Op.getLargeThumb) { caps.insert(.thumbnails) }
        if info.supports(NikonCodes.Prop.shutterSpeed) { caps.insert(.bulbCapture) }
        if sdram { destination = .host }
        capabilities = caps
    }

    /// The application-mode opcode this body advertises, if any.
    var applicationModeOp: PTPOperationCode? {
        if info.supports(NikonCodes.Op.changeApplicationMode) { return NikonCodes.Op.changeApplicationMode }
        if info.supports(NikonCodes.Op.changeCameraMode) { return NikonCodes.Op.changeCameraMode }
        return nil
    }

    // MARK: Gate

    public func prepare() async throws {
        if let op = applicationModeOp {
            try await engine.run(op, [1])
        }
        try await waitUntilReady()
    }

    /// DeviceReady until OK. The engine already retries DeviceBusy with
    /// backoff; this loop covers bodies that answer other transient codes.
    func waitUntilReady() async throws {
        guard info.supports(NikonCodes.Op.deviceReady) else { return }
        var attempt = 0
        while true {
            let r = try await engine.execute(PTPRequest(NikonCodes.Op.deviceReady))
            if r.isOK { return }
            attempt += 1
            if r.code != .deviceBusy || attempt >= readyAttempts {
                throw PTPError.response(op: NikonCodes.Op.deviceReady, code: r.code, parameters: r.parameters)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    public func teardown() async {
        await stopLiveView()
        if let op = applicationModeOp { _ = try? await engine.execute(PTPRequest(op, parameters: [0])) }
    }

    // MARK: Capture

    public func setCaptureDestination(_ d: CaptureDestination) async throws {
        switch d {
        case .card:
            guard capabilities.contains(.cardCapture) else { throw PTPError.unsupported("This Nikon can only capture to memory over PTP.") }
        case .host:
            guard sdramCapable else { throw PTPError.unsupported("This Nikon cannot capture to memory; use the card.") }
        case .both:
            guard sdramCapable, info.supports(NikonCodes.Op.initiateCaptureRecInMedia) else {
                throw PTPError.unsupported("This Nikon cannot record to card and memory at once.")
            }
        }
        destination = d
    }

    public func capture(autofocus: Bool) async throws {
        switch destination {
        case .host where sdramCapable:
            if autofocus, info.supports(NikonCodes.Op.afCaptureSDRAM) {
                try await engine.run(NikonCodes.Op.afCaptureSDRAM, timeout: 30)
            } else if info.supports(NikonCodes.Op.initiateCaptureRecInSdram) {
                try await engine.run(NikonCodes.Op.initiateCaptureRecInSdram, [0xFFFF_FFFF], timeout: 30)
            } else {
                try await engine.run(NikonCodes.Op.afCaptureSDRAM, timeout: 30)
            }
        default:
            if info.supports(NikonCodes.Op.initiateCaptureRecInMedia) {
                try await engine.run(NikonCodes.Op.initiateCaptureRecInMedia,
                                     [autofocus ? 0 : NikonCodes.captureNoAF, destination == .both ? 1 : 0], timeout: 30)
            } else if info.supports(.initiateCapture) {
                try await engine.initiateCapture()
            } else {
                throw PTPError.unsupported("This Nikon does not support remote capture over PTP.")
            }
        }
        try await waitUntilReady()
    }

    // MARK: Events

    public func pollEvents() async throws -> [CameraEvent] {
        guard info.supports(NikonCodes.Op.getEvent) else { return [] }
        let r = try await engine.run(NikonCodes.Op.getEvent)
        var out = [CameraEvent]()
        for ev in try Self.parseEvents(r.dataIn) {
            if let t = await translate(ev) { out.append(t) }
        }
        return out
    }

    /// GetEvent payload: UInt16 count, then (UInt16 code, UInt32 param) pairs.
    public static func parseEvents(_ data: Data) throws -> [PTPEvent] {
        var b = ByteBuffer(data)
        guard b.remaining >= 2 else { return [] }
        let count = Int(try b.readUInt16())
        var out = [PTPEvent]()
        for _ in 0 ..< count {
            guard b.remaining >= 6 else { break }
            let code = PTPEventCode(try b.readUInt16())
            let param = try b.readUInt32()
            out.append(PTPEvent(code: code, parameters: [param]))
        }
        return out
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? {
        switch event.code {
        case NikonCodes.Event.objectAddedInSdram:
            let h = event.parameters.first ?? NikonCodes.sdramHandle
            return .objectAdded(NewObject(handle: h == 0 ? NikonCodes.sdramHandle : h, inSDRAM: true))
        case NikonCodes.Event.captureCompleteRecInSdram, NikonCodes.Event.firstCaptureComplete:
            return .captureComplete
        case NikonCodes.Event.previewImageAdded, NikonCodes.Event.advancedTransfer:
            return nil
        case NikonCodes.Event.movieRecordInterrupted:
            return .warning("Movie recording was interrupted.")
        case .devicePropChanged:
            if let p = event.parameters.first, PTPDevicePropCode(UInt16(truncatingIfNeeded: p)) == NikonCodes.Prop.shutterSpeed {
                return .propertyChanged(.shutterSpeed)
            }
            return await generic.translate(event)
        default:
            return await generic.translate(event)
        }
    }

    // MARK: Properties

    func code(for p: TetherProperty) -> PTPDevicePropCode? {
        if p == .shutterSpeed, info.supports(NikonCodes.Prop.shutterSpeed) { return NikonCodes.Prop.shutterSpeed }
        if p == .liveViewEnabled { return NikonCodes.Prop.liveViewStatus }
        return GenericPTPHandler.standardCode(p)
    }

    static func format(_ p: TetherProperty, _ v: PTPValue, nikonShutter: Bool) -> String {
        switch p {
        case .shutterSpeed where nikonShutter:
            return NikonCodes.shutterDisplay(UInt32(truncatingIfNeeded: v.uintValue ?? 0))
        case .whiteBalance:
            return NikonCodes.whiteBalanceDisplay(v.intValue ?? 0)
        default:
            return GenericPTPHandler.format(p, v)
        }
    }

    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] {
        let nikonShutter = info.supports(NikonCodes.Prop.shutterSpeed)
        var out = try await VendorProps.readStandard(engine: engine, info: info, properties, code: code(for:)) { p, v in
            Self.format(p, v, nikonShutter: nikonShutter)
        }
        if properties.contains(.captureDestination) {
            var allowed: [CaptureDestination] = []
            if capabilities.contains(.cardCapture) { allowed.append(.card) }
            if sdramCapable { allowed.append(.host) }
            if sdramCapable, info.supports(NikonCodes.Op.initiateCaptureRecInMedia) { allowed.append(.both) }
            out.append(VendorProps.destinationDescriptor(current: destination, allowed: allowed, writable: allowed.count > 1))
        }
        return out
    }

    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        if property == .captureDestination {
            guard let d = VendorProps.destination(fromRaw: raw) else { throw PTPError.unsupported("Unknown capture destination.") }
            try await setCaptureDestination(d)
            return
        }
        guard let c = code(for: property), info.supports(c) else {
            throw PTPError.unsupported("\(property.displayName) cannot be set on this camera.")
        }
        try await engine.setDevicePropValue(c, raw)
    }

    // MARK: Transfer

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        guard object.inSDRAM || object.handle == NikonCodes.sdramHandle else {
            return try await generic.fetchObject(object, progress: progress)
        }
        // SDRAM objects: GetObjectInfo + GetObject. The object vanishes once
        // read, so DeleteImagesInSdram is not needed.
        let oi = try await engine.getObjectInfo(object.handle)
        let data = try await engine.getObject(object.handle)
        progress?(data.count, data.count)
        return (oi, data)
    }

    // MARK: Live view

    public func startLiveView(quality: LiveViewQuality) async throws {
        guard capabilities.contains(.liveView) else { throw PTPError.unsupported("Live view is not available on this camera.") }
        if info.supports(NikonCodes.Prop.liveViewProhibitCondition) {
            let v = try await engine.getDevicePropValue(NikonCodes.Prop.liveViewProhibitCondition, type: .uint32)
            if let bits = v.uintValue, bits != 0 {
                throw PTPError.vendorGate(NikonCodes.prohibitDescription(UInt32(truncatingIfNeeded: bits)))
            }
        }
        try await engine.run(NikonCodes.Op.startLiveView, timeout: 15)
        try await waitUntilReady()
        liveViewOn = true
    }

    public func stopLiveView() async {
        guard liveViewOn else { return }
        liveViewOn = false
        _ = try? await engine.execute(PTPRequest(NikonCodes.Op.endLiveView))
    }

    public func nextLiveViewFrame() async throws -> LiveViewFrame? {
        guard liveViewOn else { return nil }
        let r = try await engine.execute(PTPRequest(NikonCodes.Op.getLiveViewImg, expectsLargeData: true, timeout: 5))
        switch r.code {
        case .ok: break
        case .deviceBusy: return nil
        default: throw PTPError.response(op: NikonCodes.Op.getLiveViewImg, code: r.code, parameters: r.parameters)
        }
        // Header length varies (64/128/384 bytes by model); find the JPEG.
        guard let jpeg = r.dataIn.jpegPayload() else { return nil }
        frameSequence += 1
        return LiveViewFrame(jpeg: jpeg, sequence: frameSequence)
    }
}
