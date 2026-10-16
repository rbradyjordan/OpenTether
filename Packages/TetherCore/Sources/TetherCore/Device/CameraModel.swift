import Foundation

public enum CameraVendor: String, Codable, Sendable, CaseIterable, Identifiable {
    case canon, nikon, sony, fujifilm, ricoh, leica, olympus, panasonic, hasselblad, generic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .canon: return "Canon"
        case .nikon: return "Nikon"
        case .sony: return "Sony"
        case .fujifilm: return "Fujifilm"
        case .ricoh: return "Ricoh"
        case .leica: return "Leica"
        case .olympus: return "OM System / Olympus"
        case .panasonic: return "Panasonic Lumix"
        case .hasselblad: return "Hasselblad"
        case .generic: return "Generic PTP camera"
        }
    }

    /// Resolved from DeviceInfo, never from a model allowlist.
    public static func detect(_ info: PTPDeviceInfo) -> CameraVendor {
        let m = (info.manufacturer + " " + info.model + " " + info.vendorExtensionDesc).lowercased()
        if m.contains("canon") { return .canon }
        if m.contains("nikon") { return .nikon }
        if m.contains("sony") { return .sony }
        if m.contains("fuji") { return .fujifilm }
        if m.contains("ricoh") || m.contains("pentax") { return .ricoh }
        if m.contains("leica") { return .leica }
        if m.contains("olympus") || m.contains("om digital") || m.contains("om system") { return .olympus }
        if m.contains("panasonic") || m.contains("lumix") { return .panasonic }
        if m.contains("hasselblad") { return .hasselblad }
        switch PTPVendorExtensionID(rawValue: info.vendorExtensionID) {
        case .canon?: return .canon
        case .nikon?: return .nikon
        case .sony?: return .sony
        case .fuji?: return .fujifilm
        case .panasonic?: return .panasonic
        case .olympus?: return .olympus
        case .leica?: return .leica
        default: return .generic
        }
    }

    /// USB vendor IDs, used only to pre-filter the ICDeviceBrowser list.
    public var usbVendorID: UInt16? {
        switch self {
        case .canon: return 0x04A9
        case .nikon: return 0x04B0
        case .sony: return 0x054C
        case .fujifilm: return 0x04CB
        case .ricoh: return 0x25FB
        case .leica: return 0x1A98
        case .olympus: return 0x07B4
        case .panasonic: return 0x04DA
        case .hasselblad: return 0x2A5F
        case .generic: return nil
        }
    }

    /// Wireless control is limited to the brands whose protocols we implement.
    public var supportsWirelessControl: Bool {
        switch self {
        case .canon, .nikon, .sony, .fujifilm, .ricoh: return true
        default: return false
        }
    }

    public var supportsWiredControl: Bool { self != .ricoh && self != .hasselblad }
}

/// Runtime capability flags. Assigned by the vendor handler from DeviceInfo
/// (operations/properties supported), never from a per-model table.
public struct CameraCapabilities: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let remoteCapture      = CameraCapabilities(rawValue: 1 << 0)
    public static let sdramCapture       = CameraCapabilities(rawValue: 1 << 1)  // bSupportNoSdcard
    public static let cardCapture        = CameraCapabilities(rawValue: 1 << 2)
    public static let liveView           = CameraCapabilities(rawValue: 1 << 3)
    public static let propertyControl    = CameraCapabilities(rawValue: 1 << 4)
    public static let partialTransfer    = CameraCapabilities(rawValue: 1 << 5)
    public static let rating             = CameraCapabilities(rawValue: 1 << 6)  // bSupportRating
    public static let reducedImage       = CameraCapabilities(rawValue: 1 << 7)  // bSupportReduceImage (camera-side JPEG proxy)
    public static let wireless           = CameraCapabilities(rawValue: 1 << 8)  // supportWireless
    public static let autofocus          = CameraCapabilities(rawValue: 1 << 9)
    public static let bulbCapture        = CameraCapabilities(rawValue: 1 << 10)
    public static let thumbnails         = CameraCapabilities(rawValue: 1 << 11)
    public static let eventPush          = CameraCapabilities(rawValue: 1 << 12) // events arrive without polling
    public static let importOnly         = CameraCapabilities(rawValue: 1 << 13) // generic PTP: watch + download only

    public var summary: [String] {
        var out = [String]()
        if contains(.remoteCapture) { out.append("Remote capture") }
        if contains(.sdramCapture) { out.append("Capture without card") }
        if contains(.liveView) { out.append("Live view") }
        if contains(.propertyControl) { out.append("Exposure control") }
        if contains(.autofocus) { out.append("Autofocus") }
        if contains(.partialTransfer) { out.append("Resumable transfer") }
        if contains(.rating) { out.append("Rating sync") }
        if contains(.importOnly) { out.append("Import only") }
        return out
    }
}

/// Where the camera writes a capture. `host` = SDRAM only (nothing on the
/// card); `both` = card plus a copy to us.
public enum CaptureDestination: String, Codable, Sendable, CaseIterable, Identifiable {
    case card, host, both
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .card: return "Card only"
        case .host: return "iPhone only (no card)"
        case .both: return "Card + iPhone"
        }
    }
    public var wantsTransfer: Bool { self != .card }
}

/// A connected camera as the app shows it.
public struct CameraIdentity: Codable, Hashable, Sendable, Identifiable {
    public var id: String                 // stable: serial when known, else transport-provided id
    public var vendor: CameraVendor
    public var manufacturer: String
    public var model: String
    public var serialNumber: String
    public var firmware: String
    public var transport: TransportKind
    public var capabilities: CameraCapabilities

    public init(id: String, vendor: CameraVendor, manufacturer: String, model: String, serialNumber: String,
                firmware: String, transport: TransportKind, capabilities: CameraCapabilities) {
        self.id = id
        self.vendor = vendor
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.transport = transport
        self.capabilities = capabilities
    }

    public init(info: PTPDeviceInfo, transport: TransportKind, capabilities: CameraCapabilities, fallbackID: String) {
        let vendor = CameraVendor.detect(info)
        self.init(id: info.serialNumber.isEmpty ? fallbackID : "\(vendor.rawValue)-\(info.serialNumber)",
                  vendor: vendor, manufacturer: info.manufacturer, model: info.model,
                  serialNumber: info.serialNumber, firmware: info.deviceVersion,
                  transport: transport, capabilities: capabilities)
    }

    public var displayName: String { model.isEmpty ? vendor.displayName : model }
}

/// One live-view frame from the camera.
public struct LiveViewFrame: Sendable {
    public var jpeg: Data
    public var sequence: UInt64
    public var timestamp: Date
    public var width: Int?
    public var height: Int?

    public init(jpeg: Data, sequence: UInt64, timestamp: Date = Date(), width: Int? = nil, height: Int? = nil) {
        self.jpeg = jpeg
        self.sequence = sequence
        self.timestamp = timestamp
        self.width = width
        self.height = height
    }
}

public enum LiveViewQuality: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

public extension Data {
    /// Finds the first JPEG SOI marker; vendor live-view payloads prefix the
    /// image with a header of varying length.
    func jpegPayload() -> Data? {
        guard count >= 4 else { return nil }
        let bytes = [UInt8](self)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0xFF, bytes[i + 1] == 0xD8 {
                var end = bytes.count
                var j = bytes.count - 2
                while j > i {
                    if bytes[j] == 0xFF, bytes[j + 1] == 0xD9 { end = j + 2; break }
                    j -= 1
                }
                return Data(bytes[i ..< end])
            }
            i += 1
        }
        return nil
    }
}
