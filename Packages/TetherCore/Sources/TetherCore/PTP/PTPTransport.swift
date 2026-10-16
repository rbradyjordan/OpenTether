import Foundation

/// How the engine reached the camera. Drives UI copy and capability gating.
public enum TransportKind: String, Codable, Sendable, CaseIterable {
    case usb        // ImageCaptureCore (requestSendPTPCommand)
    case ptpip      // in-house PTP/IP over TCP
    case ricohHTTP  // Ricoh GR / Theta HTTP + WebSocket controller
    case ftpPush    // camera pushes files to the on-device FTP server
    case http       // GoPro / Open Spherical Camera HTTP APIs on the camera's Wi-Fi

    public var displayName: String {
        switch self {
        case .usb: return "USB-C"
        case .ptpip: return "Wi-Fi (PTP/IP)"
        case .ricohHTTP: return "Wi-Fi (Ricoh)"
        case .ftpPush: return "FTP push"
        case .http: return "Wi-Fi"
        }
    }
}

/// The one seam between the PTP engine and the wire. ImageCaptureCore and
/// PTP/IP are both thin implementations of this protocol; everything above
/// it (datasets, vendor handlers, capture loop) is transport-agnostic.
public protocol PTPTransport: AnyObject, Sendable {
    var kind: TransportKind { get }
    var isOpen: Bool { get }

    /// Establish the link (USB session open / PTP/IP handshake). Idempotent.
    func open() async throws
    func close() async

    /// Run one transaction. Implementations assign the transaction ID.
    func execute(_ request: PTPRequest) async throws -> PTPResponse

    /// Asynchronous events pushed by the camera (interrupt pipe / event channel).
    /// Vendors that only expose polled events (Canon GetEvent, Nikon GetEvent)
    /// get them synthesised by their handler, not by the transport.
    var events: AsyncStream<PTPEvent> { get }
}

/// Transport-level diagnostics surfaced on the cable/power screen.
public struct TransportHealth: Equatable, Sendable {
    public var roundTripMillis: Double?
    public var bytesIn: Int
    public var bytesOut: Int
    public var reconnects: Int
    public var lastError: String?

    public init(roundTripMillis: Double? = nil, bytesIn: Int = 0, bytesOut: Int = 0, reconnects: Int = 0, lastError: String? = nil) {
        self.roundTripMillis = roundTripMillis
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.reconnects = reconnects
        self.lastError = lastError
    }
}
