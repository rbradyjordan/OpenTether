import Foundation

/// Leica constants (libgphoto2 `PTP_OC_LEICA_*`). All VERIFY.
public enum LeicaCodes {
    public enum Op {
        public static let setCameraSettings = PTPOperationCode(0x9001) // VERIFY: libgphoto2 PTP_OC_LEICA_SetCameraSettings
        public static let getCameraSettings = PTPOperationCode(0x9002) // VERIFY: libgphoto2 PTP_OC_LEICA_GetCameraSettings
        public static let getLensParameter = PTPOperationCode(0x9003)  // VERIFY: libgphoto2 PTP_OC_LEICA_GetLensParameter
        public static let releaseStage = PTPOperationCode(0x9004)      // VERIFY: libgphoto2 PTP_OC_LEICA_LEReleaseStage
        public static let openLESession = PTPOperationCode(0x9005)     // VERIFY: libgphoto2 PTP_OC_LEICA_LEOpenSession
        public static let closeLESession = PTPOperationCode(0x9006)    // VERIFY: libgphoto2 PTP_OC_LEICA_LECloseSession
        public static let requestObjectErase = PTPOperationCode(0x9007) // VERIFY
        public static let requestObjectSaveAs = PTPOperationCode(0x9008) // VERIFY
        public static let requestObjectDownload = PTPOperationCode(0x9009) // VERIFY
    }

    /// ReleaseStage parameters. VERIFY: 1 = half press, 2 = full press, 0 = release.
    public static let halfPress: UInt32 = 1
    public static let fullPress: UInt32 = 2
    public static let releaseAll: UInt32 = 0
    /// LEOpenSession parameter. VERIFY: libgphoto2 passes the session id (1).
    public static let leSession: UInt32 = 1
}

/// Leica SL / Q / M (wired only): LE session gate, ReleaseStage capture,
/// standard properties, object-handle diff for new files.
public final class LeicaHandler: VendorHandler, @unchecked Sendable {
    public let engine: PTPEngine
    public let info: PTPDeviceInfo
    public let vendor: CameraVendor = .leica
    public let capabilities: CameraCapabilities
    public let eventPollInterval: TimeInterval = 0.5

    private let generic: GenericPTPHandler
    public let differ = ObjectHandleDiffer()
    private var leSessionOpen = false

    public init(engine: PTPEngine, info: PTPDeviceInfo) {
        self.engine = engine
        self.info = info
        self.generic = GenericPTPHandler(engine: engine, info: info)
        var caps = CameraCapabilities()
        if info.supports(LeicaCodes.Op.releaseStage) || info.supports(.initiateCapture) { caps.insert(.remoteCapture); caps.insert(.cardCapture) }
        if info.supports(LeicaCodes.Op.releaseStage) { caps.insert(.autofocus) }
        if info.supports(.setDevicePropValue), !info.devicePropertiesSupported.isEmpty { caps.insert(.propertyControl) }
        if info.supports(.getPartialObject) { caps.insert(.partialTransfer) }
        if info.supports(.getThumb) { caps.insert(.thumbnails) }
        capabilities = caps
    }

    public func prepare() async throws {
        if info.supports(LeicaCodes.Op.openLESession) {
            try await engine.run(LeicaCodes.Op.openLESession, [LeicaCodes.leSession])
            leSessionOpen = true
        }
        await differ.seed(engine: engine)
    }

    public func teardown() async {
        if leSessionOpen, info.supports(LeicaCodes.Op.closeLESession) {
            _ = try? await engine.execute(PTPRequest(LeicaCodes.Op.closeLESession, parameters: [LeicaCodes.leSession]))
        }
        leSessionOpen = false
    }

    public func setCaptureDestination(_ destination: CaptureDestination) async throws {
        if destination != .card { throw PTPError.unsupported("Leica bodies write to the card; the file is copied over afterwards.") }
    }

    public func capture(autofocus: Bool) async throws {
        if info.supports(LeicaCodes.Op.releaseStage) {
            if autofocus { try await engine.run(LeicaCodes.Op.releaseStage, [LeicaCodes.halfPress], timeout: 15) }
            try await engine.run(LeicaCodes.Op.releaseStage, [LeicaCodes.fullPress], timeout: 15)
            try await engine.run(LeicaCodes.Op.releaseStage, [LeicaCodes.releaseAll])
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
        if event.code == .objectAdded, let h = event.parameters.first { _ = differ.diff([h]) }
        return await generic.translate(event)
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
}
