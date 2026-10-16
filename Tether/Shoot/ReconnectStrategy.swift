import Foundation
import TetherCore

/// How the live connection was made, kept so a dropped link can be re-opened
/// the same way.
enum ReconnectContext: Equatable, Sendable {
    case usb(deviceID: String, serial: String?)
    case ptpip(host: String, port: UInt16, vendor: CameraVendor?)
    case ricoh(host: String)
    /// GoPro or an OSC 360° camera over HTTP on its own Wi-Fi.
    case http(host: String, vendor: CameraVendor)
    case ftp
    case unknown

    /// Rebuilt from a stored session after a relaunch.
    static func from(session: ShootSession) -> ReconnectContext {
        switch session.transport {
        case .usb?: return .usb(deviceID: session.camera?.id ?? "", serial: session.camera?.serialNumber)
        case .ptpip?: return .ptpip(host: session.lastHost ?? "", port: PTPIPPacket.standardPort, vendor: session.camera?.vendor)
        case .ricohHTTP?: return .ricoh(host: session.lastHost ?? RicohProbe.defaultHost)
        case .ftpPush?: return .ftp
        case .http?:
            guard let host = session.lastHost, let vendor = session.camera?.vendor else { return .unknown }
            return .http(host: host, vendor: vendor)
        case nil: return .unknown
        }
    }
}

/// What the reconnect sheet should do. Pure so it is unit-tested.
enum ReconnectStrategy: Equatable, Sendable {
    /// Watch the USB browser until a camera with this serial (or any camera) returns.
    case waitForUSBDevice(serial: String?)
    case retryHost(host: String, port: UInt16, vendor: CameraVendor?)
    case retryRicoh(host: String)
    case retryHTTP(host: String, vendor: CameraVendor)
    /// FTP push: the server keeps listening; nothing to re-open.
    case nothingToDo
    /// No usable information: send the user back to Connect.
    case startFresh

    static func choose(for context: ReconnectContext) -> ReconnectStrategy {
        switch context {
        case .usb(_, let serial): return .waitForUSBDevice(serial: serial)
        case .ptpip(let host, let port, let vendor):
            return host.isEmpty ? .startFresh : .retryHost(host: host, port: port, vendor: vendor)
        case .ricoh(let host): return host.isEmpty ? .startFresh : .retryRicoh(host: host)
        case .http(let host, let vendor): return .retryHTTP(host: host, vendor: vendor)
        case .ftp: return .nothingToDo
        case .unknown: return .startFresh
        }
    }

    var title: String {
        switch self {
        case .waitForUSBDevice: return "Waiting for the cable"
        case .retryHost(let host, _, _): return "Reconnecting to \(host)"
        case .retryRicoh(let host): return "Reconnecting to the Ricoh at \(host)"
        case .retryHTTP(_, let vendor): return "Reconnecting to the \(vendor == .gopro ? "GoPro" : "camera")"
        case .nothingToDo: return "FTP receiver is still listening"
        case .startFresh: return "Connect again"
        }
    }

    var detail: String {
        switch self {
        case .waitForUSBDevice: return "Plug the camera back in. Open Tether reconnects as soon as it reappears and keeps every frame from this session."
        case .retryHost: return "Make sure the phone is still on the camera's Wi-Fi and the camera is in its PC / remote connection mode."
        case .retryRicoh: return "Stay on the camera's Wi-Fi network. The GR sleeps quickly; half-press the shutter to wake it."
        case .retryHTTP(_, let vendor):
            return vendor == .gopro ? "Keep the phone on the GoPro's Wi-Fi and the camera awake (press Mode to wake it)."
                                    : "Keep the phone on the camera's Wi-Fi network and the camera switched on."
        case .nothingToDo: return "Cameras push files whenever they want; the session keeps collecting them."
        case .startFresh: return "Open Tether does not know how this session was connected. Pick a connection method to continue it."
        }
    }
}
