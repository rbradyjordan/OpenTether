import Foundation

/// Olympus / OM System constants (libgphoto2 `PTP_OC_OLYMPUS_OMD_*`,
/// `PTP_DPC_OLYMPUS_*`). Everything here is VERIFY until a body confirms it.
public enum OlympusCodes {
    public enum Op {
        public static let capture = PTPOperationCode(0x9481)             // VERIFY: libgphoto2 PTP_OC_OLYMPUS_OMD_Capture
        public static let getIncreaseCapture = PTPOperationCode(0x9482)  // VERIFY
        public static let getLiveViewImage = PTPOperationCode(0x9484)    // VERIFY: libgphoto2 PTP_OC_OLYMPUS_GetLiveViewImage
        public static let mfDrive = PTPOperationCode(0x9487)             // VERIFY: libgphoto2 PTP_OC_OLYMPUS_OMD_MFDrive
        public static let setProperties = PTPOperationCode(0x9489)       // VERIFY: libgphoto2 PTP_OC_OLYMPUS_OMD_SetProperties
    }

    public enum Prop {
        public static let aperture = PTPDevicePropCode(0xD002)           // VERIFY: libgphoto2 PTP_DPC_OLYMPUS_Aperture (not used for display)
        public static let cameraControlMode = PTPDevicePropCode(0xD052)  // VERIFY: 1 = remote control
        public static let liveViewMode = PTPDevicePropCode(0xD06D)       // VERIFY: libgphoto2 PTP_DPC_OLYMPUS_LiveViewModeOM
        public static let controlModeRemote: UInt8 = 1
    }

    public enum Event {
        public static let propertyChanged = PTPEventCode(0xC008)         // VERIFY: libgphoto2 PTP_EC_Olympus_PropertyChanged
        public static let captureComplete = PTPEventCode(0xC003)         // VERIFY
    }

    /// Capture parameters. VERIFY: libgphoto2 sends 0x3 (press) then 0x6 (release).
    public static let capturePress: UInt32 = 0x3
    public static let captureRelease: UInt32 = 0x6
    /// Live view image parameter. VERIFY: libgphoto2 uses 0x00000001.
    public static let liveViewParam: UInt32 = 1
}

/// Olympus / OM System (wired only): control-mode gate, OMD capture,
/// standard properties, object-handle diff for new files.
public final class OlympusHandler: VendorHandler, @unchecked Sendable {
    public let engine: PTPEngine
    public let info: PTPDeviceInfo
    public let vendor: CameraVendor = .olympus
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
        if info.supports(OlympusCodes.Op.capture) || info.supports(.initiateCapture) { caps.insert(.remoteCapture); caps.insert(.cardCapture) }
        if info.supports(OlympusCodes.Op.capture) { caps.insert(.autofocus) }
        if info.supports(OlympusCodes.Op.getLiveViewImage) { caps.insert(.liveView) }
        if info.supports(.setDevicePropValue), !info.devicePropertiesSupported.isEmpty { caps.insert(.propertyControl) }
        if info.supports(.getPartialObject) { caps.insert(.partialTransfer) }
        if info.supports(.getThumb) { caps.insert(.thumbnails) }
        capabilities = caps
    }

    public func prepare() async throws {
        if info.supports(OlympusCodes.Prop.cameraControlMode) {
            try await engine.setDevicePropValue(OlympusCodes.Prop.cameraControlMode, .uint8(OlympusCodes.Prop.controlModeRemote))
        }
        await differ.seed(engine: engine)
    }

    public func teardown() async {
        await stopLiveView()
        if info.supports(OlympusCodes.Prop.cameraControlMode) {
            _ = try? await engine.setDevicePropValue(OlympusCodes.Prop.cameraControlMode, .uint8(0))
        }
    }

    public func setCaptureDestination(_ destination: CaptureDestination) async throws {
        if destination != .card { throw PTPError.unsupported("Olympus bodies write to the card; the file is copied over afterwards.") }
    }

    public func capture(autofocus: Bool) async throws {
        if info.supports(OlympusCodes.Op.capture) {
            try await engine.run(OlympusCodes.Op.capture, [OlympusCodes.capturePress], timeout: 30)
            try await engine.run(OlympusCodes.Op.capture, [OlympusCodes.captureRelease], timeout: 30)
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
        case OlympusCodes.Event.propertyChanged:
            return .propertyChanged(event.parameters.first.flatMap { GenericPTPHandler.standardProperty(PTPDevicePropCode(UInt16(truncatingIfNeeded: $0))) })
        case OlympusCodes.Event.captureComplete:
            return .captureComplete
        default:
            if event.code == .objectAdded, let h = event.parameters.first { _ = differ.diff([h]) }
            return await generic.translate(event)
        }
    }

    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] {
        var out = try await generic.readProperties(properties)
        if properties.contains(.captureDestination) {
            out.append(VendorProps.destinationDescriptor(current: .card, allowed: [.card], writable: false))
        }
        return out
    }

    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        try await generic.writeProperty(property, raw: raw)
    }

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        try await generic.fetchObject(object, progress: progress)
    }

    public func startLiveView(quality: LiveViewQuality) async throws {
        guard capabilities.contains(.liveView) else { throw PTPError.unsupported("Live view is not available on this camera.") }
        if info.supports(OlympusCodes.Prop.liveViewMode) {
            _ = try? await engine.setDevicePropValue(OlympusCodes.Prop.liveViewMode, .uint32(1))
        }
        liveViewOn = true
    }

    public func stopLiveView() async {
        guard liveViewOn else { return }
        liveViewOn = false
        if info.supports(OlympusCodes.Prop.liveViewMode) {
            _ = try? await engine.setDevicePropValue(OlympusCodes.Prop.liveViewMode, .uint32(0))
        }
    }

    public func nextLiveViewFrame() async throws -> LiveViewFrame? {
        guard liveViewOn else { return nil }
        let r = try await engine.execute(PTPRequest(OlympusCodes.Op.getLiveViewImage, parameters: [OlympusCodes.liveViewParam], expectsLargeData: true, timeout: 5))
        guard r.isOK, let jpeg = r.dataIn.jpegPayload() else { return nil }
        frameSequence += 1
        return LiveViewFrame(jpeg: jpeg, sequence: frameSequence)
    }
}
