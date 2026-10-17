import Foundation

/// A freshly announced object on the camera (ObjectAdded or vendor equivalent).
public struct NewObject: Equatable, Sendable {
    public var handle: UInt32
    public var storageID: UInt32
    public var info: PTPObjectInfo?
    /// True when the object lives in the camera's RAM buffer and must be
    /// fetched now (SDRAM handles are transient).
    public var inSDRAM: Bool

    public init(handle: UInt32, storageID: UInt32 = 0, info: PTPObjectInfo? = nil, inSDRAM: Bool = false) {
        self.handle = handle
        self.storageID = storageID
        self.info = info
        self.inSDRAM = inSDRAM
    }
}

/// Vendor-neutral events the capture loop consumes.
public enum CameraEvent: Equatable, Sendable {
    case objectAdded(NewObject)
    case objectRemoved(handle: UInt32)
    case propertyChanged(TetherProperty?)
    case captureComplete
    case storageChanged
    case cameraBusy(Bool)
    case shutterPressed
    case warning(String)
    case disconnected
    case raw(PTPEvent)
}

/// Per-vendor behaviour on top of the generic PTP engine. One instance per
/// connected camera. Implementations live in `Vendors/`.
///
/// The handler owns the vendor gates (Canon PC mode + two-stage shutter,
/// Nikon ChangeApplicationMode, Sony SDIO connect, Fuji tether mode), the
/// mapping from `TetherProperty` to vendor codes, event polling for vendors
/// that do not push events, and live view.
public protocol VendorHandler: AnyObject, Sendable {
    var vendor: CameraVendor { get }
    var capabilities: CameraCapabilities { get }

    /// Interval for `pollEvents` when the camera does not push events.
    var eventPollInterval: TimeInterval { get }

    /// Run the vendor gate and put the body into remote-control mode.
    func prepare() async throws
    func teardown() async

    func setCaptureDestination(_ destination: CaptureDestination) async throws
    /// Trigger a still capture. Two-stage vendors handle AF inside.
    func capture(autofocus: Bool) async throws

    /// For polled vendors: ask the camera what happened since last time.
    func pollEvents() async throws -> [CameraEvent]
    /// For pushed events: translate a transport event. nil = ignore.
    func translate(_ event: PTPEvent) async -> CameraEvent?

    func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor]
    func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws

    /// Download one object (ObjectInfo + bytes). Vendors with SDRAM-only
    /// handles or their own partial-object opcode override this.
    func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data)

    func startLiveView(quality: LiveViewQuality) async throws
    func stopLiveView() async
    /// Next frame, or nil when none is ready yet.
    func nextLiveViewFrame() async throws -> LiveViewFrame?

    /// Write a star rating back to the camera when it supports it.
    func setRating(handle: UInt32, stars: Int) async throws
    /// Focus at a point of the live-view image, 0…1 from the top left.
    func focus(atNormalizedX x: Double, y: Double) async throws
}

/// Default behaviours shared by every handler.
public extension VendorHandler {
    var eventPollInterval: TimeInterval { 0.25 }
    func pollEvents() async throws -> [CameraEvent] { [] }
    func setRating(handle: UInt32, stars: Int) async throws { throw PTPError.unsupported("Rating is not supported on this camera.") }
    func focus(atNormalizedX x: Double, y: Double) async throws { throw PTPError.unsupported("Touch focus is not available on this camera.") }
    func startLiveView(quality: LiveViewQuality) async throws { throw PTPError.unsupported("Live view is not available on this camera.") }
    func stopLiveView() async {}
    func nextLiveViewFrame() async throws -> LiveViewFrame? { nil }
}

/// Generic PTP: watch for ObjectAdded, download, and InitiateCapture when the
/// camera advertises it. This is the safe baseline for every brand without
/// a dedicated handler (Hasselblad, Sigma, Pentax, Samsung, compacts) and for
/// bodies whose vendor mode is off: new files are found from the camera's
/// own events and, as a safety net, by polling the card.
public final class GenericPTPHandler: VendorHandler, @unchecked Sendable {
    public let engine: PTPEngine
    public let info: PTPDeviceInfo
    public let vendor: CameraVendor
    public let capabilities: CameraCapabilities
    private var propTypes: [PTPDevicePropCode: PTPDataType] = [:]
    private let differ = ObjectHandleDiffer()
    /// Shown once on connect, e.g. "set USB mode to PC Remote for full control".
    private var setupHint: String?

    public var eventPollInterval: TimeInterval { 1.5 }

    public init(engine: PTPEngine, info: PTPDeviceInfo, setupHint: String? = nil) {
        self.engine = engine
        self.info = info
        self.setupHint = setupHint
        self.vendor = CameraVendor.detect(info)
        var caps: CameraCapabilities = [.eventPush, .importOnly]
        if info.supports(.initiateCapture) { caps.insert(.remoteCapture); caps.insert(.cardCapture); caps.remove(.importOnly) }
        if info.supports(.getPartialObject) { caps.insert(.partialTransfer) }
        if info.supports(.getThumb) { caps.insert(.thumbnails) }
        if info.supports(.getDevicePropDesc), !info.devicePropertiesSupported.isEmpty { caps.insert(.propertyControl) }
        self.capabilities = caps
    }

    public func prepare() async throws {
        if info.supports(.getObjectHandles) { await differ.seed(engine: engine) }
    }

    public func teardown() async {}

    /// Card polling catches bodies that never send ObjectAdded; duplicates of
    /// pushed events are dropped by the session.
    public func pollEvents() async throws -> [CameraEvent] {
        var out: [CameraEvent] = []
        if let hint = setupHint { out.append(.warning(hint)); setupHint = nil }
        if info.supports(.getObjectHandles), differ.isSeeded { out += try await differ.poll(engine: engine) }
        return out
    }

    public func setCaptureDestination(_ destination: CaptureDestination) async throws {
        if destination != .card { throw PTPError.unsupported("This camera can only capture to its card.") }
    }

    public func capture(autofocus: Bool) async throws {
        guard info.supports(.initiateCapture) else { throw PTPError.unsupported("This camera does not support remote capture over PTP.") }
        try await engine.initiateCapture()
    }

    public func translate(_ event: PTPEvent) async -> CameraEvent? {
        switch event.code {
        case .objectAdded, .requestObjectTransfer:
            guard let h = event.parameters.first, h != 0 else { return nil }
            return .objectAdded(NewObject(handle: h))
        case .objectRemoved:
            return event.parameters.first.map { .objectRemoved(handle: $0) }
        case .devicePropChanged:
            return .propertyChanged(event.parameters.first.flatMap { Self.standardProperty(PTPDevicePropCode(UInt16(truncatingIfNeeded: $0))) })
        case .captureComplete: return .captureComplete
        case .storeAdded, .storeRemoved, .storageInfoChanged, .storeFull: return .storageChanged
        case .deviceReset: return .disconnected
        default: return .raw(event)
        }
    }

    public static func standardProperty(_ code: PTPDevicePropCode) -> TetherProperty? {
        switch code {
        case .fNumber: return .aperture
        case .exposureTime: return .shutterSpeed
        case .exposureIndex: return .iso
        case .exposureBiasCompensation: return .exposureCompensation
        case .whiteBalance: return .whiteBalance
        case .exposureProgramMode: return .exposureProgram
        case .stillCaptureMode: return .driveMode
        case .exposureMeteringMode: return .meteringMode
        case .focusMode: return .focusMode
        case .compressionSetting: return .imageQuality
        case .imageSize: return .imageSize
        case .batteryLevel: return .batteryLevel
        case .flashMode: return .flashMode
        default: return nil
        }
    }

    public static func standardCode(_ p: TetherProperty) -> PTPDevicePropCode? {
        switch p {
        case .aperture: return .fNumber
        case .shutterSpeed: return .exposureTime
        case .iso: return .exposureIndex
        case .exposureCompensation: return .exposureBiasCompensation
        case .whiteBalance: return .whiteBalance
        case .exposureProgram: return .exposureProgramMode
        case .driveMode: return .stillCaptureMode
        case .meteringMode: return .exposureMeteringMode
        case .focusMode: return .focusMode
        case .imageQuality: return .compressionSetting
        case .imageSize: return .imageSize
        case .batteryLevel: return .batteryLevel
        case .flashMode: return .flashMode
        default: return nil
        }
    }

    /// Display formatting for the standard PTP encodings.
    public static func format(_ p: TetherProperty, _ v: PTPValue) -> String {
        guard let n = v.intValue else { return v.stringValue ?? v.description }
        switch p {
        case .aperture: return PropertyFormat.aperture(hundredths: n)
        case .shutterSpeed: return PropertyFormat.shutter(tenThousandths: n)
        case .iso: return PropertyFormat.iso(n)
        case .exposureCompensation: return PropertyFormat.exposureCompensation(thousandths: n)
        case .whiteBalance: return PropertyFormat.whiteBalance(standard: n)
        case .batteryLevel: return PropertyFormat.battery(percent: n)
        default: return "\(n)"
        }
    }

    public func readProperties(_ properties: [TetherProperty]) async throws -> [PropertyDescriptor] {
        var out = [PropertyDescriptor]()
        for p in properties {
            guard let code = Self.standardCode(p), info.supports(code) else { continue }
            let desc = try await engine.getDevicePropDesc(code)
            propTypes[code] = desc.dataType
            out.append(Self.descriptor(p, desc))
        }
        return out
    }

    public static func descriptor(_ p: TetherProperty, _ desc: PTPDevicePropDesc, format: ((TetherProperty, PTPValue) -> String)? = nil) -> PropertyDescriptor {
        let fmt = format ?? Self.format
        let form: PropertyDescriptor.Form
        switch desc.form {
        case .enumeration(let vals):
            form = .choices(vals.map { PropertyChoice(raw: $0, display: fmt(p, $0)) })
        case .range(let mn, let mx, let st):
            form = .range(min: Double(mn.intValue ?? 0), max: Double(mx.intValue ?? 0), step: Double(st.intValue ?? 1))
        case .none:
            form = .other
        }
        return PropertyDescriptor(property: p, raw: desc.current, display: fmt(p, desc.current), isWritable: desc.isWritable, form: form)
    }

    public func writeProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        guard let code = Self.standardCode(property), info.supports(code) else {
            throw PTPError.unsupported("\(property.displayName) cannot be set on this camera.")
        }
        try await engine.setDevicePropValue(code, raw)
    }

    public func fetchObject(_ object: NewObject, progress: (@Sendable (Int, Int?) -> Void)?) async throws -> (PTPObjectInfo, Data) {
        let info: PTPObjectInfo
        if let known = object.info { info = known } else { info = try await engine.getObjectInfo(object.handle) }
        let data = try await engine.download(object.handle, size: info.objectCompressedSize, progress: progress)
        return (info, data)
    }
}

/// Picks the handler for a camera. Vendor modules register themselves at
/// startup (`VendorRegistry.installBuiltIns()`); anything unregistered gets
/// the generic handler, so an unknown body still imports.
public enum VendorRegistry {
    public typealias Factory = @Sendable (PTPEngine, PTPDeviceInfo) -> VendorHandler

    private static let lock = NSLock()
    nonisolated(unsafe) private static var factories: [CameraVendor: Factory] = [:]

    public static func register(_ vendor: CameraVendor, _ factory: @escaping Factory) {
        lock.lock(); defer { lock.unlock() }
        factories[vendor] = factory
    }

    public static func makeHandler(engine: PTPEngine, info: PTPDeviceInfo, transport: TransportKind) -> VendorHandler {
        let vendor = CameraVendor.detect(info)
        lock.lock()
        let factory = factories[vendor]
        lock.unlock()
        // Brands without a dedicated handler (Hasselblad, Sigma, Pentax,
        // Samsung…) get the generic one: capture when the body offers
        // InitiateCapture, import otherwise. Wireless control is limited to
        // the brands whose protocols we ship.
        if transport == .ptpip, !vendor.supportsWirelessControl { return GenericPTPHandler(engine: engine, info: info) }
        // A body whose vendor control mode is off (or a compact without it)
        // still imports, with a hint, instead of refusing to connect.
        if let hint = vendorModeHint(vendor: vendor, info: info) {
            return GenericPTPHandler(engine: engine, info: info, setupHint: hint)
        }
        return factory?(engine, info) ?? GenericPTPHandler(engine: engine, info: info)
    }

    /// Nil when the vendor's control gate is available.
    static func vendorModeHint(vendor: CameraVendor, info: PTPDeviceInfo) -> String? {
        switch vendor {
        case .canon where !info.supports(CanonCodes.Op.setRemoteMode):
            return "This Canon offers import only over this connection. Photos you take arrive automatically."
        case .sony where !info.supports(SonyCodes.Op.sdioConnect):
            return "Importing only. For remote control set USB Connection to PC Remote on the camera and reconnect."
        default:
            return nil
        }
    }

    public static var registered: [CameraVendor] {
        lock.lock(); defer { lock.unlock() }
        return Array(factories.keys)
    }
}
